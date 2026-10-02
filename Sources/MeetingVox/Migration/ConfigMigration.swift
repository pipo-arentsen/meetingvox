import Foundation

struct MigrationLockTimeout: Error {}

/// The filesystem operations the migration performs, as closures so a test
/// can make one of them fail. Everything else it does (existence checks,
/// listing, the marker) goes straight to `FileManager` on the temp dirs a
/// test provides.
struct MigrationFileOps: Sendable {
    var copy: @Sendable (_ from: URL, _ to: URL) throws -> Void
    var move: @Sendable (_ from: URL, _ to: URL) throws -> Void
    var remove: @Sendable (_ url: URL) throws -> Void
    /// Takes an exclusive lock on `url` (created if needed), waiting up to
    /// `timeout` seconds; returns the release. Throws `MigrationLockTimeout`.
    var acquireLock: @Sendable (_ url: URL, _ timeout: TimeInterval) throws -> @Sendable () -> Void
        = MigrationFileOps.flockAcquire

    /// `flock(2)` on a file descriptor kept open until the release runs (or
    /// the process dies, which frees it too).
    static let flockAcquire: @Sendable (URL, TimeInterval) throws -> @Sendable () -> Void = { url, timeout in
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code != EWOULDBLOCK && code != EINTR {
                close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            if Date() >= deadline {
                close(fd)
                throw MigrationLockTimeout()
            }
            usleep(50_000)
        }
        return {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }

    static let live = MigrationFileOps(
        copy: { try FileManager.default.copyItem(at: $0, to: $1) },
        move: { try FileManager.default.moveItem(at: $0, to: $1) },
        remove: { try FileManager.default.removeItem(at: $0) }
    )
}

/// Copies `~/.config/quill` to `~/.config/meetingvox` the first time
/// MeetingVox runs.
///
/// It only ever copies: the legacy tree is never moved, written or deleted,
/// so the old `quill` keeps working and doubles as the backup. Symlinks in
/// the legacy tree (the root or any child, typical of dotfiles setups) are
/// resolved and copied as real files, so the new dir never shares storage
/// with the legacy one and nothing is ever written through a link. The copy
/// goes to a temp sibling, gets its marker, and is renamed into place, so no
/// half-copied directory is ever visible at the final path; an interrupted
/// run leaves only a `meetingvox.migrating-*` sibling that the next launch
/// sweeps. The whole run holds an exclusive lock, so two processes starting
/// together can neither sweep each other's live temp dir nor move aside a
/// freshly migrated one.
///
/// "Done" means the marker exists (or there is no legacy dir at all). A new
/// dir without the marker, whatever it holds (factory templates, or a config
/// written after a failed run), is moved aside to `meetingvox.pre-migration-*`
/// (never deleted) so the legacy copy takes its place; only the Keychain
/// retirement markers are carried over from it.
///
/// Must run before anything reads `Config` or touches `TemplateStore`
/// (`Config.path` is a lazy static): that is `MeetingVoxMain`'s job, and this
/// file deliberately never references `Config`.
enum ConfigMigration {
    enum Outcome {
        /// The legacy tree was copied and the marker written. `movedAside` is
        /// where the previous, marker-less new dir went, if there was one.
        case migrated(movedAside: URL?)
        /// The marker exists, or another process finished first. Nothing was touched.
        case alreadyDone
        /// No legacy dir: a fresh install.
        case nothingToMigrate
        case failed(Error)
    }

    struct SymlinkDepthExceeded: Error, CustomStringConvertible {
        var description: String { "symlinks nest too deeply (a loop?) in the legacy config dir" }
    }

    static let lockTimeout: TimeInterval = 10

    static let stderrLog: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    private static let migratingInfix = ".migrating-"
    private static let asideInfix = ".pre-migration-"
    private static let maxSymlinkDepth = 16

    static func run(
        legacyDir: URL, newDir: URL, now: Date = Date(), ops: MigrationFileOps = .live,
        log: (String) -> Void = ConfigMigration.stderrLog
    ) -> Outcome {
        let fm = FileManager.default
        let parent = newDir.deletingLastPathComponent()
        let name = newDir.lastPathComponent
        let marker = newDir.appendingPathComponent(AppIdentity.migrationMarker)

        let release: @Sendable () -> Void
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let lockURL = parent.appendingPathComponent(".\(name)-migration.lock")
            release = try ops.acquireLock(lockURL, lockTimeout)
        } catch is MigrationLockTimeout {
            // Someone else holds the lock: touch nothing. If they finished,
            // that is the same as us having done it.
            return exists(marker) ? .alreadyDone : .failed(MigrationLockTimeout())
        } catch {
            return .failed(error)
        }
        defer { release() }

        sweepLeftovers(in: parent, prefix: name + migratingInfix, ops: ops)

        if exists(marker) { return .alreadyDone }

        // Follow a symlinked legacy root: the copy source is the real dir.
        let source = legacyDir.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .nothingToMigrate
        }

        var aside: URL?
        if exists(newDir) {
            let target = asideURL(for: newDir, now: now)
            do {
                try ops.move(newDir, target)
            } catch {
                return .failed(error)
            }
            aside = target
        }

        let temp = parent.appendingPathComponent(name + migratingInfix + UUID().uuidString, isDirectory: true)
        do {
            try ops.copy(source, temp)
            try materializeSymlinks(in: temp, original: source, depth: 0, ops: ops, log: log)
            if let aside { try carryOverRetirementMarkers(from: aside, to: temp, ops: ops) }
            try writeMarker(in: temp, source: legacyDir, now: now)
            try ops.move(temp, newDir)
            return .migrated(movedAside: aside)
        } catch {
            try? ops.remove(temp)
            if exists(newDir) {
                // Lost a race despite the lock (a foreign process): theirs wins.
                return .alreadyDone
            }
            if let aside { try? ops.move(aside, newDir) }
            return .failed(error)
        }
    }

    /// The call `MeetingVoxMain` makes: real home, real filesystem, one log
    /// line when something happened (silent on the common no-op launch).
    @discardableResult
    static func migrateAtStartup(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date(),
        ops: MigrationFileOps = .live,
        log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) -> Outcome {
        let legacy = AppIdentity.legacyConfigDir(home: home)
        let new = AppIdentity.configDir(home: home)
        let outcome = run(legacyDir: legacy, newDir: new, now: now, ops: ops, log: log)
        switch outcome {
        case let .migrated(movedAside):
            let aside = movedAside.map { "; the previous \(new.path) was kept at \($0.path)" } ?? ""
            log("config migrated: copied \(legacy.path) to \(new.path) (legacy left untouched)\(aside)")
        case let .failed(error):
            log("config migration failed, will retry next launch: \(error)")
        case .alreadyDone, .nothingToMigrate:
            break
        }
        return outcome
    }

    // MARK: - Helpers

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// `meetingvox.pre-migration-<yyyyMMdd-HHmmss>`, with a suffix if taken.
    private static func asideURL(for newDir: URL, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = newDir.deletingLastPathComponent()
            .appendingPathComponent(newDir.lastPathComponent + asideInfix + formatter.string(from: now))
        var candidate = base
        var n = 2
        while exists(candidate) {
            candidate = URL(fileURLWithPath: base.path + "-\(n)")
            n += 1
        }
        return candidate
    }

    /// Replaces every symlink under `dir` with a real copy of its target
    /// (a dangling one is dropped and logged), recursing into what it copied.
    /// Never writes through a link: the link is removed first.
    ///
    /// `original` is where `dir`'s contents really live in the legacy tree
    /// (the resolved source, or the target a link was copied from). A
    /// relative link such as `../shared/config.json` only means something
    /// from there: `dir` is a temp sibling, so resolving it in place would
    /// look in the wrong directory and drop a perfectly good link as dangling.
    private static func materializeSymlinks(
        in dir: URL, original: URL, depth: Int, ops: MigrationFileOps, log: (String) -> Void
    ) throws {
        guard depth <= maxSymlinkDepth else { throw SymlinkDepthExceeded() }
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: dir.path) {
            let url = dir.appendingPathComponent(name)
            var childOriginal = original.appendingPathComponent(name)
            let isLink = (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink ?? false
            if isLink {
                let target = childOriginal.resolvingSymlinksInPath()
                try ops.remove(url)
                guard fm.fileExists(atPath: target.path) else {
                    log("config migration: dropped dangling symlink \(childOriginal.path) (its target does not exist)")
                    continue
                }
                try ops.copy(target, url)
                childOriginal = target
            }
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                try materializeSymlinks(in: url, original: childOriginal, depth: depth + 1, ops: ops, log: log)
            }
        }
    }

    /// The Keychain retirement markers say "don't resurface this deleted
    /// secret"; losing them with the aside dir would bring one back.
    private static func carryOverRetirementMarkers(from aside: URL, to dir: URL, ops: MigrationFileOps) throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: aside.path)) ?? []
        for name in names where name.hasPrefix(AppIdentity.keychainRetirementMarkerPrefix) {
            let target = dir.appendingPathComponent(name)
            guard !exists(target) else { continue }
            try ops.copy(aside.appendingPathComponent(name), target)
        }
    }

    private static func writeMarker(in dir: URL, source: URL, now: Date) throws {
        let body: [String: String] = [
            "source": source.path,
            "date": ISO8601DateFormatter().string(from: now),
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent(AppIdentity.migrationMarker), options: .atomic)
    }

    private static func sweepLeftovers(in parent: URL, prefix: String, ops: MigrationFileOps) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? ops.remove(parent.appendingPathComponent(name))
        }
    }
}
