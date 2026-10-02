import Foundation
import Testing

@testable import MeetingVox

/// The config-dir migration is copy-only and must be safe to run at every
/// launch. Every test works in its own temporary "home": nothing here can
/// reach the real `~/.config`.
@Suite("ConfigMigration")
struct ConfigMigrationTests {
    private struct Fixture {
        let home: URL
        var legacy: URL { AppIdentity.legacyConfigDir(home: home) }
        var new: URL { AppIdentity.configDir(home: home) }
        var parent: URL { new.deletingLastPathComponent() }

        init() throws {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("meetingvox-migration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        func cleanup() { try? FileManager.default.removeItem(at: home) }

        func write(_ text: String, _ relative: String, in dir: URL) throws {
            let url = dir.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url)
        }

        func read(_ relative: String, in dir: URL) -> String? {
            try? String(contentsOf: dir.appendingPathComponent(relative), encoding: .utf8)
        }

        func exists(_ relative: String, in dir: URL) -> Bool {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(relative).path)
        }

        /// A realistic legacy dir: config, an edited template and its `.bak`.
        func seedLegacy() throws {
            try write(#"{"on_stop": "my-hook", "hindsight": {"bank": "meetingvox"}}"#, "config.json", in: legacy)
            try write("legacy general", "plantillas/general.md", in: legacy)
            try write("legacy general (old)", "plantillas/general.md.bak", in: legacy)
            try write("custom", "plantillas/mine.md", in: legacy)
        }

        /// Relative path → bytes of every file under `dir` (nil if absent).
        func snapshot(_ dir: URL) -> [String: Data]? {
            guard let walker = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { return nil }
            var result: [String: Data] = [:]
            for case let url as URL in walker {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard !isDir else { continue }
                let rel = String(url.path.dropFirst(dir.path.count + 1))
                result[rel] = try? Data(contentsOf: url)
            }
            return result
        }

        func siblings(prefix: String) -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            return names.filter { $0.hasPrefix(prefix) }.sorted()
        }
    }

    private struct Boom: Error {}

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Copy, marker, idempotence

    @Test func copiesTheWholeTreeAndWritesTheMarker() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        guard case .migrated = outcome else { Issue.record("expected migrated, got \(outcome)"); return }
        #expect(f.read("config.json", in: f.new) == #"{"on_stop": "my-hook", "hindsight": {"bank": "meetingvox"}}"#)
        #expect(f.read("plantillas/general.md", in: f.new) == "legacy general")
        #expect(f.read("plantillas/general.md.bak", in: f.new) == "legacy general (old)")
        #expect(f.read("plantillas/mine.md", in: f.new) == "custom")
        let marker = try #require(f.read(AppIdentity.migrationMarker, in: f.new))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(marker.utf8)) as? [String: Any])
        #expect(json["source"] as? String == f.legacy.path)
        #expect(json["date"] as? String == ISO8601DateFormatter().string(from: now))
        #expect(f.siblings(prefix: "meetingvox.").isEmpty)
    }

    @Test func legacyTreeIsByteIdenticalAfterMigration() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        let before = try #require(f.snapshot(f.legacy))
        #expect(before.count == 4)

        _ = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        #expect(f.snapshot(f.legacy) == before)
    }

    @Test func secondLaunchIsANoOpAndNeverResyncsLegacy() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        _ = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)
        try f.write("edited after migration", "plantillas/general.md", in: f.new)
        try f.write("post-cutover legacy edit", "config.json", in: f.legacy)
        let markerBefore = f.read(AppIdentity.migrationMarker, in: f.new)

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now.addingTimeInterval(60))

        guard case .alreadyDone = outcome else { Issue.record("expected alreadyDone, got \(outcome)"); return }
        #expect(f.read("plantillas/general.md", in: f.new) == "edited after migration")
        #expect(f.read("config.json", in: f.new) == #"{"on_stop": "my-hook", "hindsight": {"bank": "meetingvox"}}"#)
        #expect(f.read(AppIdentity.migrationMarker, in: f.new) == markerBefore)
    }

    @Test func existingNewConfigWithoutMarkerIsMovedAsideAndLegacyIsMigrated() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        try f.write(#"{"mine": true}"#, "config.json", in: f.new)

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        guard case .migrated = outcome else { Issue.record("expected migrated, got \(outcome)"); return }
        #expect(f.read("config.json", in: f.new) == #"{"on_stop": "my-hook", "hindsight": {"bank": "meetingvox"}}"#)
        #expect(f.exists(AppIdentity.migrationMarker, in: f.new))
        let aside = f.siblings(prefix: "meetingvox.pre-migration-")
        #expect(aside.count == 1)
        let asideDir = f.parent.appendingPathComponent(try #require(aside.first))
        #expect(f.read("config.json", in: asideDir) == #"{"mine": true}"#)
    }

    @Test func aFailedRunIsNotAbandonedOnceTemplatesOrSettingsCreateANewConfig() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        let failing = MigrationFileOps(
            copy: { _, _ in throw Boom() },
            move: MigrationFileOps.live.move,
            remove: MigrationFileOps.live.remove
        )
        guard case .failed = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now, ops: failing) else {
            Issue.record("expected failed"); return
        }
        // The app went on: factory templates and a Settings write created a fresh config.
        try TemplateStore.installFactoryTemplatesIfMissing(in: f.new.appendingPathComponent("plantillas"))
        try f.write(#"{"fresh": true}"#, "config.json", in: f.new)

        let next = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now.addingTimeInterval(1))

        guard case .migrated = next else { Issue.record("expected migrated, got \(next)"); return }
        #expect(f.read("config.json", in: f.new) == #"{"on_stop": "my-hook", "hindsight": {"bank": "meetingvox"}}"#)
        #expect(f.read("plantillas/general.md", in: f.new) == "legacy general")
        let aside = f.siblings(prefix: "meetingvox.pre-migration-")
        #expect(aside.count == 1)
        let asideDir = f.parent.appendingPathComponent(try #require(aside.first))
        #expect(f.read("config.json", in: asideDir) == #"{"fresh": true}"#)
        #expect(f.exists("plantillas/daily.md", in: asideDir))
    }

    @Test func aNewConfigWithoutMarkerAndWithoutLegacyIsLeftAlone() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write(#"{"mine": true}"#, "config.json", in: f.new)
        let before = try #require(f.snapshot(f.new))

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        guard case .nothingToMigrate = outcome else { Issue.record("expected nothingToMigrate, got \(outcome)"); return }
        #expect(f.snapshot(f.new) == before)
        #expect(f.siblings(prefix: "meetingvox.pre-migration-").isEmpty)
    }

    @Test func noLegacyDirMeansNothingToMigrateAndNoMarker() throws {
        let f = try Fixture()
        defer { f.cleanup() }

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        guard case .nothingToMigrate = outcome else { Issue.record("expected nothingToMigrate, got \(outcome)"); return }
        #expect(!FileManager.default.fileExists(atPath: f.new.path))
    }

    // MARK: - Failure and recovery

    @Test func aCopyFailureLeavesNoTempNoNewDirAndLegacyIntact() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        let before = try #require(f.snapshot(f.legacy))
        // Copy half of the tree, then fail: the temp sibling must still be removed.
        let failing = MigrationFileOps(
            copy: { from, to in
                try FileManager.default.copyItem(at: from, to: to)
                throw Boom()
            },
            move: MigrationFileOps.live.move,
            remove: MigrationFileOps.live.remove
        )

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now, ops: failing)

        guard case .failed = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(!FileManager.default.fileExists(atPath: f.new.path))
        #expect(f.siblings(prefix: "meetingvox.").isEmpty)
        #expect(f.snapshot(f.legacy) == before)

        // The next launch self-heals.
        let retry = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)
        guard case .migrated = retry else { Issue.record("expected migrated on retry, got \(retry)"); return }
        #expect(f.read("plantillas/mine.md", in: f.new) == "custom")
    }

    @Test func aFailedFinalMoveRemovesTheTempAndRestoresTheAsideDir() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        try f.write("factory", "plantillas/general.md", in: f.new)
        // Moving the temp copy into place fails; moving the new dir aside (and back) works.
        let failing = MigrationFileOps(
            copy: MigrationFileOps.live.copy,
            move: { from, to in
                if from.lastPathComponent.contains(".migrating-") { throw Boom() }
                try MigrationFileOps.live.move(from, to)
            },
            remove: MigrationFileOps.live.remove
        )

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now, ops: failing)

        guard case .failed = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(f.read("plantillas/general.md", in: f.new) == "factory")
        #expect(f.siblings(prefix: "meetingvox.").isEmpty)
    }

    @Test func aRaceWhereTheDestinationAppearsCountsAsAlreadyDone() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        let racing = MigrationFileOps(
            copy: MigrationFileOps.live.copy,
            move: { _, to in
                // Another process won: the destination exists by the time we rename.
                try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
                try Data("theirs".utf8).write(to: to.appendingPathComponent("config.json"))
                throw Boom()
            },
            remove: MigrationFileOps.live.remove
        )

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now, ops: racing)

        guard case .alreadyDone = outcome else { Issue.record("expected alreadyDone, got \(outcome)"); return }
        #expect(f.read("config.json", in: f.new) == "theirs")
        #expect(f.siblings(prefix: "meetingvox.").isEmpty)
    }

    @Test func leftoverTempSiblingsAreSweptButOtherSiblingsAreNot() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        try f.write("half", "config.json", in: f.parent.appendingPathComponent("meetingvox.migrating-DEAD"))
        try f.write("keep", "x", in: f.parent.appendingPathComponent("meetingvox-other"))

        _ = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        #expect(f.siblings(prefix: "meetingvox.migrating-").isEmpty)
        #expect(f.exists("x", in: f.parent.appendingPathComponent("meetingvox-other")))
        #expect(f.read("config.json", in: f.new) == #"{"on_stop": "my-hook", "hindsight": {"bank": "meetingvox"}}"#)
    }

    @Test func leftoverTempIsAlsoSweptWhenThereIsNothingElseToDo() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write("half", "config.json", in: f.parent.appendingPathComponent("meetingvox.migrating-DEAD"))

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        guard case .nothingToMigrate = outcome else { Issue.record("expected nothingToMigrate, got \(outcome)"); return }
        #expect(f.siblings(prefix: "meetingvox.migrating-").isEmpty)
    }

    // MARK: - Order independence

    @Test func aNewDirWithOnlyFactoryTemplatesIsMovedAsideAndLegacyWins() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        try f.write("factory general", "plantillas/general.md", in: f.new)
        try f.write("factory daily", "plantillas/daily.md", in: f.new)

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        guard case .migrated = outcome else { Issue.record("expected migrated, got \(outcome)"); return }
        #expect(f.read("plantillas/general.md", in: f.new) == "legacy general")
        #expect(f.read("config.json", in: f.new) != nil)
        let aside = f.siblings(prefix: "meetingvox.pre-migration-")
        #expect(aside.count == 1)
        let asideDir = f.parent.appendingPathComponent(try #require(aside.first))
        #expect(f.read("plantillas/general.md", in: asideDir) == "factory general")
        #expect(f.read("plantillas/daily.md", in: asideDir) == "factory daily")
    }

    @Test func factoryTemplateInstallAfterMigrationKeepsLegacyTemplatesAndAddsMissingOnes() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        _ = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        try TemplateStore.installFactoryTemplatesIfMissing(in: f.new.appendingPathComponent("plantillas"))

        #expect(f.read("plantillas/general.md", in: f.new) == "legacy general")
        #expect(f.read("plantillas/mine.md", in: f.new) == "custom")
        #expect(f.exists("plantillas/familiar.md", in: f.new))
    }

    // MARK: - Symlinks

    /// Legacy dir as a symlink to a real dir; returns the real dir.
    private func symlinkedLegacyRoot(_ f: Fixture) throws -> URL {
        let real = f.home.appendingPathComponent("dotfiles/quill", isDirectory: true)
        try f.write(#"{"on_stop": "via-link"}"#, "config.json", in: real)
        try f.write("linked general", "plantillas/general.md", in: real)
        try FileManager.default.createDirectory(at: f.legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.legacy, withDestinationURL: real)
        return real
    }

    private func symlinks(under dir: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        var found: [String] = []
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                found.append(url.lastPathComponent)
            }
        }
        return found
    }

    @Test func aSymlinkedLegacyRootIsCopiedAsARealTreeAndNeverWrittenThrough() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let real = try symlinkedLegacyRoot(f)
        let before = try #require(f.snapshot(real))

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        guard case .migrated = outcome else { Issue.record("expected migrated, got \(outcome)"); return }
        #expect(f.read("config.json", in: f.new) == #"{"on_stop": "via-link"}"#)
        #expect(f.read("plantillas/general.md", in: f.new) == "linked general")
        #expect(f.exists(AppIdentity.migrationMarker, in: f.new))
        #expect(symlinks(under: f.new).isEmpty)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: f.new.path)) == nil)
        // Nothing was written into the legacy storage, not even the marker.
        #expect(f.snapshot(real) == before)
        #expect(!f.exists(AppIdentity.migrationMarker, in: real))
        // Editing the new tree leaves legacy alone.
        try f.write("edited", "config.json", in: f.new)
        #expect(f.snapshot(real) == before)
    }

    @Test func symlinkedChildrenAreReplacedByRealCopiesOfTheirTargets() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let elsewhere = f.home.appendingPathComponent("elsewhere", isDirectory: true)
        try f.write(#"{"linked": 1}"#, "config.json", in: elsewhere)
        try f.write("t1", "plantillas/general.md", in: elsewhere)
        try f.write("t2", "plantillas/nested/deep.md", in: elsewhere)
        try FileManager.default.createDirectory(at: f.legacy, withIntermediateDirectories: true)
        try f.write("plain", "notes.txt", in: f.legacy)
        try FileManager.default.createSymbolicLink(
            at: f.legacy.appendingPathComponent("config.json"),
            withDestinationURL: elsewhere.appendingPathComponent("config.json"))
        try FileManager.default.createSymbolicLink(
            at: f.legacy.appendingPathComponent("plantillas"),
            withDestinationURL: elsewhere.appendingPathComponent("plantillas"))
        let legacyBefore = try #require(f.snapshot(f.legacy))
        let elsewhereBefore = try #require(f.snapshot(elsewhere))

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        guard case .migrated = outcome else { Issue.record("expected migrated, got \(outcome)"); return }
        #expect(f.read("config.json", in: f.new) == #"{"linked": 1}"#)
        #expect(f.read("plantillas/general.md", in: f.new) == "t1")
        #expect(f.read("plantillas/nested/deep.md", in: f.new) == "t2")
        #expect(f.read("notes.txt", in: f.new) == "plain")
        #expect(symlinks(under: f.new).isEmpty)
        #expect(f.snapshot(f.legacy) == legacyBefore)
        #expect(f.snapshot(elsewhere) == elsewhereBefore)
        // The legacy links themselves are still links.
        #expect(symlinks(under: f.legacy).sorted() == ["config.json", "plantillas"])
    }

    @Test func aDanglingSymlinkIsDroppedFromTheCopy() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        try FileManager.default.createSymbolicLink(
            at: f.legacy.appendingPathComponent("gone.json"),
            withDestinationURL: f.home.appendingPathComponent("does-not-exist"))

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        guard case .migrated = outcome else { Issue.record("expected migrated, got \(outcome)"); return }
        #expect(!f.exists("gone.json", in: f.new))
        #expect(symlinks(under: f.new).isEmpty)
        #expect(f.read("config.json", in: f.new) != nil)
    }

    /// Dotfiles layout: the root and its child are RELATIVE links, and the
    /// child points outside the linked root (`../shared/config.json`), so it
    /// only resolves from the legacy tree's real location, not from wherever
    /// the copy sits while it is being materialized.
    @Test func aRelativeChildLinkEscapingASymlinkedRootResolvesFromItsOriginalLocation() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let dotfiles = f.parent.appendingPathComponent("dotfiles", isDirectory: true)
        try f.write(#"{"on_stop": "shared-hook"}"#, "shared/config.json", in: dotfiles)
        try f.write("t", "quill/plantillas/general.md", in: dotfiles)
        let realRoot = dotfiles.appendingPathComponent("quill")
        try FileManager.default.createSymbolicLink(
            atPath: realRoot.appendingPathComponent("config.json").path,
            withDestinationPath: "../shared/config.json")
        // ~/.config/quill -> dotfiles/quill
        try FileManager.default.createSymbolicLink(atPath: f.legacy.path, withDestinationPath: "dotfiles/quill")
        let dotfilesBefore = try #require(f.snapshot(dotfiles))

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        guard case .migrated = outcome else { Issue.record("expected migrated, got \(outcome)"); return }
        #expect(f.read("config.json", in: f.new) == #"{"on_stop": "shared-hook"}"#)
        #expect(f.read("plantillas/general.md", in: f.new) == "t")
        #expect(symlinks(under: f.new).isEmpty)
        // Legacy untouched: same bytes, links still links, no marker written through.
        #expect(f.snapshot(dotfiles) == dotfilesBefore)
        #expect(symlinks(under: dotfiles) == ["config.json"])
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: f.legacy.path)) == "dotfiles/quill")
        #expect(!f.exists(AppIdentity.migrationMarker, in: realRoot))
    }

    /// A relative link inside a directory that was itself a link is resolved
    /// against that directory's real location too.
    @Test func aRelativeLinkInsideALinkedChildDirResolvesFromTheLinkedDirsRealLocation() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        let store = f.home.appendingPathComponent("store", isDirectory: true)
        try f.write("real-a", "a.md", in: store.appendingPathComponent("tpl"))
        try f.write("shared-b", "common/b.md", in: store)
        try FileManager.default.createSymbolicLink(
            atPath: store.appendingPathComponent("tpl/b.md").path, withDestinationPath: "../common/b.md")
        try FileManager.default.removeItem(at: f.legacy.appendingPathComponent("plantillas"))
        try FileManager.default.createSymbolicLink(
            atPath: f.legacy.appendingPathComponent("plantillas").path, withDestinationPath: store.appendingPathComponent("tpl").path)

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        guard case .migrated = outcome else { Issue.record("expected migrated, got \(outcome)"); return }
        #expect(f.read("plantillas/a.md", in: f.new) == "real-a")
        #expect(f.read("plantillas/b.md", in: f.new) == "shared-b")
        #expect(symlinks(under: f.new).isEmpty)
    }

    @Test func droppingADanglingSymlinkIsLoggedWithItsName() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        try FileManager.default.createSymbolicLink(
            at: f.legacy.appendingPathComponent("gone.json"),
            withDestinationURL: f.home.appendingPathComponent("does-not-exist"))
        let lines = LockedLines()

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now, log: { lines.add($0) })

        guard case .migrated = outcome else { Issue.record("expected migrated, got \(outcome)"); return }
        let logged = lines.all
        #expect(logged.count == 1)
        #expect(logged.first?.contains("gone.json") == true)
        #expect(logged.first?.contains("dangling") == true)
    }

    @Test func noDanglingLinkMeansNoLogLine() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        let lines = LockedLines()

        _ = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now, log: { lines.add($0) })

        #expect(lines.all.isEmpty)
    }

    @Test func aSymlinkLoopFailsTheMigrationInsteadOfRecursingForever() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        try FileManager.default.createSymbolicLink(
            at: f.legacy.appendingPathComponent("loop"), withDestinationURL: f.legacy)

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        guard case .failed = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(!FileManager.default.fileExists(atPath: f.new.path))
        #expect(f.siblings(prefix: "meetingvox.").isEmpty)
    }

    // MARK: - Concurrency (exclusive lock)

    /// Ops whose lock is a recording seam.
    private func ops(
        lock: @escaping @Sendable (URL, TimeInterval) throws -> @Sendable () -> Void
    ) -> MigrationFileOps {
        MigrationFileOps(
            copy: MigrationFileOps.live.copy, move: MigrationFileOps.live.move,
            remove: MigrationFileOps.live.remove, acquireLock: lock
        )
    }

    @Test func theWholeRunHoldsTheLockAndReleasesItEvenOnFailure() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        let leftover = f.parent.appendingPathComponent("meetingvox.migrating-DEAD")
        try f.write("half", "config.json", in: leftover)
        let events = LockedLines()
        let seam = ops(lock: { url, timeout in
            // The lock is taken before the sweep touches anything.
            events.add("acquire \(url.lastPathComponent) leftoverStillThere=\(FileManager.default.fileExists(atPath: leftover.path)) timeout=\(timeout)")
            return { events.add("release") }
        })

        _ = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now, ops: seam)

        #expect(events.all == ["acquire .meetingvox-migration.lock leftoverStillThere=true timeout=10.0", "release"])
        #expect(!FileManager.default.fileExists(atPath: leftover.path))

        // And on a failed run.
        let g = try Fixture()
        defer { g.cleanup() }
        try g.seedLegacy()
        let failEvents = LockedLines()
        let failing = MigrationFileOps(
            copy: { _, _ in throw Boom() }, move: MigrationFileOps.live.move, remove: MigrationFileOps.live.remove,
            acquireLock: { _, _ in { failEvents.add("release") } }
        )
        guard case .failed = ConfigMigration.run(legacyDir: g.legacy, newDir: g.new, now: now, ops: failing) else {
            Issue.record("expected failed"); return
        }
        #expect(failEvents.all == ["release"])
    }

    @Test func aSecondProcessThatWaitedForTheLockFindsTheWorkDoneAndTouchesNothing() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        let winnerNow = now
        // While "we" wait for the lock, the other process runs the whole migration.
        let seam = ops(lock: { [f] _, _ in
            _ = ConfigMigration.run(
                legacyDir: f.legacy, newDir: f.new, now: winnerNow,
                ops: MigrationFileOps(
                    copy: MigrationFileOps.live.copy, move: MigrationFileOps.live.move,
                    remove: MigrationFileOps.live.remove, acquireLock: { _, _ in {} }
                )
            )
            return {}
        })

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now.addingTimeInterval(5), ops: seam)

        guard case .alreadyDone = outcome else { Issue.record("expected alreadyDone, got \(outcome)"); return }
        #expect(f.siblings(prefix: "meetingvox.pre-migration-").isEmpty)
        #expect(f.read("plantillas/mine.md", in: f.new) == "custom")
        let marker = try #require(f.read(AppIdentity.migrationMarker, in: f.new))
        #expect(marker.contains(ISO8601DateFormatter().string(from: winnerNow)))
    }

    @Test func aLockTimeoutTouchesNothingAndFailsUnlessTheMarkerAppeared() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        let leftover = f.parent.appendingPathComponent("meetingvox.migrating-LIVE")
        try f.write("someone else's copy in progress", "config.json", in: leftover)
        let timingOut = ops(lock: { _, _ in throw MigrationLockTimeout() })

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now, ops: timingOut)

        guard case .failed = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        // The holder's live temp dir was not swept, and nothing was created.
        #expect(f.exists("config.json", in: leftover))
        #expect(!FileManager.default.fileExists(atPath: f.new.path))

        // If the holder finished in the meantime, the marker is there: alreadyDone.
        _ = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)
        let again = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now, ops: timingOut)
        guard case .alreadyDone = again else { Issue.record("expected alreadyDone, got \(again)"); return }
    }

    @Test func theLiveLockExcludesASecondHolderUntilReleased() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let lockURL = f.parent.appendingPathComponent(".meetingvox-migration.lock")
        try FileManager.default.createDirectory(at: f.parent, withIntermediateDirectories: true)

        let release = try MigrationFileOps.live.acquireLock(lockURL, 1)
        #expect(throws: MigrationLockTimeout.self) { try MigrationFileOps.live.acquireLock(lockURL, 0.2) }

        release()
        let second = try MigrationFileOps.live.acquireLock(lockURL, 1)
        second()
    }

    // MARK: - Retirement markers survive the aside move

    @Test func keychainRetirementMarkersAreCarriedOverFromTheAsideDir() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        let hindsight = AppIdentity.keychainRetirementMarker(account: "hindsight_token")
        let openRouter = AppIdentity.keychainRetirementMarker(account: "openrouter_api_key")
        try f.write("", hindsight, in: f.new)
        try f.write("", openRouter, in: f.new)
        try f.write("factory", "plantillas/general.md", in: f.new)

        let outcome = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        guard case .migrated = outcome else { Issue.record("expected migrated, got \(outcome)"); return }
        #expect(FileLegacyKeyRetirement(marker: f.new.appendingPathComponent(hindsight)).isRetired)
        #expect(FileLegacyKeyRetirement(marker: f.new.appendingPathComponent(openRouter)).isRetired)
        #expect(f.read("plantillas/general.md", in: f.new) == "legacy general")
        let asideDir = f.parent.appendingPathComponent(try #require(f.siblings(prefix: "meetingvox.pre-migration-").first))
        #expect(f.exists(hindsight, in: asideDir)) // the aside dir keeps everything
    }

    @Test func onlyRetirementMarkersAreCarriedOver() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        try f.write("", AppIdentity.keychainRetirementMarker(account: "hindsight_token"), in: f.new)
        try f.write(#"{"fresh": true}"#, "config.json", in: f.new)
        try f.write("junk", "other.txt", in: f.new)

        _ = ConfigMigration.run(legacyDir: f.legacy, newDir: f.new, now: now)

        #expect(f.read("config.json", in: f.new) == #"{"on_stop": "my-hook", "hindsight": {"bank": "meetingvox"}}"#)
        #expect(!f.exists("other.txt", in: f.new))
    }

    // MARK: - Startup wiring

    @Test func startupMigrationUsesTheHomeAndLogsTheOutcome() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        let lines = LockedLines()

        let outcome = ConfigMigration.migrateAtStartup(home: f.home, now: now, log: { lines.add($0) })

        guard case .migrated = outcome else { Issue.record("expected migrated, got \(outcome)"); return }
        #expect(f.read("config.json", in: f.new) != nil)
        #expect(lines.all.count == 1)
        #expect(lines.all.first?.contains("migrated") == true)

        // A quiet second launch logs nothing.
        let again = LockedLines()
        _ = ConfigMigration.migrateAtStartup(home: f.home, now: now, log: { again.add($0) })
        #expect(again.all.isEmpty)
    }

    @Test func startupMigrationLogsWhereThePreviousNewDirWasKept() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        try f.write(#"{"fresh": true}"#, "config.json", in: f.new)
        let lines = LockedLines()

        _ = ConfigMigration.migrateAtStartup(home: f.home, now: now, log: { lines.add($0) })

        #expect(lines.all.count == 1)
        #expect(lines.all.first?.contains("kept at") == true)
        #expect(lines.all.first?.contains("meetingvox.pre-migration-") == true)
    }

    @Test func startupMigrationLogsFailures() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        let lines = LockedLines()
        let failing = MigrationFileOps(
            copy: { _, _ in throw Boom() },
            move: MigrationFileOps.live.move,
            remove: MigrationFileOps.live.remove
        )

        let outcome = ConfigMigration.migrateAtStartup(home: f.home, now: now, ops: failing, log: { lines.add($0) })

        guard case .failed = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(lines.all.count == 1)
        #expect(lines.all.first?.contains("failed") == true)
    }

    @Test func entryPointMigratesBeforeItLaunchesTheCommand() {
        let events = LockedLines()

        // A non-`run` route: no log redirect and no instance guard, so the
        // migration-then-launch order is the whole story here. (The full
        // start-up order is covered by EntryPointTests.)
        MeetingVoxMain.start(
            arguments: ["meetingvox", "doctor"], isBundled: false, stderrIsTTY: true,
            steps: MeetingVoxMain.Steps(
                redirectLog: { events.add("redirect") },
                decideInstance: { events.add("instance"); return .proceed },
                refuse: { _ in events.add("refuse") },
                rotateLog: { events.add("rotate") },
                migrate: { events.add("migrate") },
                launch: { _ in events.add("launch") }
            )
        )

        #expect(events.all == ["migrate", "launch"])
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func add(_ line: String) { lock.lock(); items.append(line); lock.unlock() }
}
