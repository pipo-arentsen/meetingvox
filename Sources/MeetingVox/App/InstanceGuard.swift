import AppKit
import Darwin
import Foundation

/// What the start-up probe observed. Plain values so the decision is pure.
struct InstanceFacts: Equatable {
    enum Lock: Equatable {
        /// This process holds the lock: it is the one instance.
        case acquired
        /// Another process holds it.
        case held
        /// The lock file is unusable, so it says nothing either way.
        case unavailable
    }

    /// Other running processes of this bundle id (this process excluded).
    var otherPIDs: [Int32]
    /// What the `flock` on the instance lock file said. Authoritative for
    /// "is there another instance" whenever it could be taken at all.
    var lock: Lock
    /// Other processes of this user running the legacy `/usr/local/bin/quill`
    /// executable (this process excluded).
    var legacyPIDs: [Int32]
}

/// Whether this `run` may start. Two recorders would fight over the mic and
/// the system tap, and the legacy quill agent may be recording right now;
/// starting next to it (or killing it) could cost a meeting.
enum InstanceDecision: Equatable {
    case proceed
    case refuse(Refusal)

    enum Cause: Equatable {
        case otherInstance(pids: [Int32])
        case lockHeld
    }

    /// Why a start is refused. Its own type so the code that reports a
    /// refusal can't be handed `.proceed`.
    enum Refusal: Equatable {
        case alreadyRunning(Cause)
        case legacyRunning(pids: [Int32])

        /// What blocks the start, without the outcome.
        var summary: String {
            switch self {
            case .alreadyRunning(.otherInstance(let pids)):
                return "another \(AppIdentity.displayName) is already running (pid \(Self.list(pids)))"
            case .alreadyRunning(.lockHeld):
                return "instance lock is held by another \(AppIdentity.displayName)"
            case .legacyRunning(let pids):
                return "legacy quill is running (pid \(Self.list(pids)))"
            }
        }

        /// The line logged when refusing. Names the cause.
        var logLine: String { summary + "; exiting" }

        private static func list(_ pids: [Int32]) -> String { pids.map(String.init).joined(separator: ", ") }
    }

    /// The `flock` is authoritative for duplicates. Holding it makes this the
    /// one instance, even if `NSRunningApplication` still lists another pid
    /// (a quitting or stale entry): otherwise two simultaneous launches could
    /// each see the other in the list, both wait and both exit, leaving no
    /// recorder. Only a lock held by someone else refuses; the pids, when
    /// listed, just make the cause more specific (a double-click most likely
    /// means it). With no usable lock file the list is the only evidence left
    /// and decides. The legacy process is checked either way.
    static func decide(_ facts: InstanceFacts) -> InstanceDecision {
        switch facts.lock {
        case .acquired:
            break
        case .held:
            if facts.otherPIDs.isEmpty { return .refuse(.alreadyRunning(.lockHeld)) }
            return .refuse(.alreadyRunning(.otherInstance(pids: facts.otherPIDs)))
        case .unavailable:
            if !facts.otherPIDs.isEmpty { return .refuse(.alreadyRunning(.otherInstance(pids: facts.otherPIDs))) }
        }
        if !facts.legacyPIDs.isEmpty { return .refuse(.legacyRunning(pids: facts.legacyPIDs)) }
        return .proceed
    }
}

/// The live probes behind `InstanceFacts`. Read-only except for the lock file:
/// nothing here signals, kills or otherwise touches another process.
enum InstanceGuard {
    enum LockResult: Equatable {
        /// The lock is ours for as long as this descriptor stays open.
        case acquired(Int32)
        /// Another open file description holds it.
        case held
        /// The file couldn't be created or opened; the reason is for the log.
        /// Not the same as held: an unusable path must not be mistaken for a
        /// second instance.
        case unavailable(String)
    }

    /// How long a blocker is waited out before refusing, and how often it is
    /// looked at again.
    static let maxWait: TimeInterval = 30
    static let pollInterval: TimeInterval = 2

    /// The descriptor of the lock file, kept open for the life of the process
    /// on purpose: closing it (or exiting) is what releases the flock. Once
    /// set, later probes report the lock as ours instead of trying a second
    /// `flock`, which a second open file description of the same file would
    /// lose to this one.
    nonisolated(unsafe) private static var heldDescriptor: Int32?

    /// `flock(LOCK_EX | LOCK_NB)` on `url`, creating its parent directories.
    static func acquireLock(at url: URL) -> LockResult {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            return .unavailable(error.localizedDescription)
        }
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable(describe(errno: errno)) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return .acquired(fd) }
        let code = errno
        close(fd)
        return code == EWOULDBLOCK ? .held : .unavailable(describe(errno: code))
    }

    private static func describe(errno code: Int32) -> String {
        "errno \(code): \(String(cString: strerror(code)))"
    }

    /// One running process: pid, executable path, owning user.
    typealias ProcessEntry = (pid: Int32, path: String, uid: UInt32)

    /// PIDs, other than `excludingPID`, of `uid`'s processes whose executable
    /// is exactly `legacyPath`. Exact on purpose: a development build under
    /// `.build/` or `quill-other` is not the agent. This process is excluded
    /// so a binary installed at the legacy path can't refuse itself; other
    /// users' processes can't be this user's recorder.
    static func legacyPIDs(
        in processes: [ProcessEntry],
        legacyPath: String, excludingPID: Int32, uid: UInt32
    ) -> [Int32] {
        processes
            .filter { $0.path == legacyPath && $0.pid != excludingPID && $0.uid == uid }
            .map(\.pid)
    }

    /// Every process's executable path and owner (`proc_listallpids`,
    /// `proc_pidpath`, `proc_pidinfo`). Processes we can't inspect are skipped.
    static func runningProcesses() -> [ProcessEntry] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        // Processes can start between the sizing call and the listing call:
        // twice the first answer is headroom for them.
        var pids = [pid_t](repeating: 0, count: Int(capacity) * 2)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var result: [ProcessEntry] = []
        var buffer = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
        for pid in pids.prefix(Int(count)) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
            result.append((pid, String(decoding: bytes, as: UTF8.self), info.pbi_uid))
        }
        return result
    }

    /// Takes the lock (kept for the process lifetime) and observes the rest.
    /// An unusable lock file is logged and reported as such: it is not a
    /// second instance, and the decision then falls back to the list.
    static func probe(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) -> InstanceFacts {
        let me = ProcessInfo.processInfo.processIdentifier
        func pids(of bundleID: String) -> [Int32] {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != me && !$0.isTerminated }
                .map(\.processIdentifier)
        }
        // The legacy bundle id is only a hint (the old binary is a bare
        // executable, so the path probe is what actually finds it).
        let legacy = Set(pids(of: AppIdentity.legacyBundleID)
            + legacyPIDs(
                in: runningProcesses(), legacyPath: AppIdentity.legacyExecutablePath,
                excludingPID: me, uid: getuid()
            ))

        var lock = InstanceFacts.Lock.acquired
        if heldDescriptor == nil {
            switch acquireLock(at: AppIdentity.lockFile(home: home)) {
            case .acquired(let fd): heldDescriptor = fd
            case .held: lock = .held
            case .unavailable(let reason):
                log("instance lock unavailable (\(reason)); relying on the running-application list")
                lock = .unavailable
            }
        }
        return InstanceFacts(otherPIDs: pids(of: AppIdentity.bundleID).sorted(), lock: lock, legacyPIDs: legacy.sorted())
    }

    /// Probe until the start is clear, for at most `maxWait`, then decide.
    /// Exit 0 on refusal is never retried by launchd (`KeepAlive` only
    /// restarts unsuccessful exits), so a blocker that is only transient (an
    /// instance still quitting, a legacy agent being booted out) would
    /// otherwise leave the user with no recorder until the next login. Every
    /// cause is waited on, and waiting costs nothing but a delay before a
    /// refusal. A process that wins the `flock` is not delayed by a stale
    /// `NSRunningApplication` entry (see `InstanceDecision.decide`), and the
    /// list may lag while this thread sleeps, so the lock is what is polled.
    /// The sleeper is injected, so the wait is instant in tests.
    static func awaitClear(
        maxWait: TimeInterval = InstanceGuard.maxWait,
        interval: TimeInterval = InstanceGuard.pollInterval,
        probe: () -> InstanceFacts,
        sleep: (TimeInterval) -> Void,
        log: (String) -> Void
    ) -> InstanceDecision {
        var waited: TimeInterval = 0
        var decision = InstanceDecision.decide(probe())
        var announced = false
        while case .refuse(let refusal) = decision, waited < maxWait {
            if !announced {
                log("\(refusal.summary); waiting up to \(Int(maxWait)) s")
                announced = true
            }
            sleep(interval)
            waited += interval
            decision = InstanceDecision.decide(probe())
        }
        return decision
    }
}
