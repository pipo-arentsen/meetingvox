import Darwin
import Foundation
import Testing

@testable import MeetingVox

/// Two recorders on one Mac would fight over the mic and the system tap, so a
/// second `run` refuses to start. The decision is pure over injected facts;
/// the flock, the legacy-process match and the wait-before-refusing loop get
/// real-file or injected-clock tests.
@Suite("InstanceGuard")
struct InstanceGuardTests {
    private func facts(others: [Int32] = [], lock: InstanceFacts.Lock = .acquired, legacy: [Int32] = []) -> InstanceFacts {
        InstanceFacts(otherPIDs: others, lock: lock, legacyPIDs: legacy)
    }

    // MARK: - decide

    @Test func cleanStartProceeds() {
        #expect(InstanceDecision.decide(facts()) == .proceed)
    }

    @Test func anotherInstanceHoldingTheLockRefusesAndNamesItsPIDs() {
        #expect(InstanceDecision.decide(facts(others: [123, 456], lock: .held))
            == .refuse(.alreadyRunning(.otherInstance(pids: [123, 456]))))
    }

    @Test func aHeldLockRefuses() {
        #expect(InstanceDecision.decide(facts(lock: .held)) == .refuse(.alreadyRunning(.lockHeld)))
    }

    // The flock is the authority: the process that holds it is the one
    // instance, whatever NSRunningApplication still lists (a quitting or
    // stale entry, which the list can keep showing for a while).

    @Test func theLockWeHoldOutranksAStaleRunningApplicationEntry() {
        #expect(InstanceDecision.decide(facts(others: [9], lock: .acquired)) == .proceed)
        #expect(InstanceDecision.decide(facts(others: [9, 10], lock: .acquired)) == .proceed)
    }

    @Test func theLockWeHoldDoesNotHideALegacyQuill() {
        #expect(InstanceDecision.decide(facts(others: [9], lock: .acquired, legacy: [4242]))
            == .refuse(.legacyRunning(pids: [4242])))
    }

    @Test func withoutAUsableLockTheRunningApplicationListStillDecides() {
        // A lock file that can't exist says nothing about other instances.
        #expect(InstanceDecision.decide(facts(others: [9], lock: .unavailable))
            == .refuse(.alreadyRunning(.otherInstance(pids: [9]))))
        #expect(InstanceDecision.decide(facts(lock: .unavailable)) == .proceed)
        #expect(InstanceDecision.decide(facts(lock: .unavailable, legacy: [4242])) == .refuse(.legacyRunning(pids: [4242])))
    }

    @Test func aRunningLegacyQuillRefusesAndNamesItsPID() {
        #expect(InstanceDecision.decide(facts(legacy: [4242])) == .refuse(.legacyRunning(pids: [4242])))
    }

    @Test func ownInstanceOutranksTheOtherCauses() {
        #expect(InstanceDecision.decide(facts(others: [9], lock: .held, legacy: [4242]))
            == .refuse(.alreadyRunning(.otherInstance(pids: [9]))))
        #expect(InstanceDecision.decide(facts(lock: .held, legacy: [4242])) == .refuse(.alreadyRunning(.lockHeld)))
    }

    @Test func everyRefusalExplainsItsCauseInTheLog() {
        let dup = InstanceDecision.Refusal.alreadyRunning(.otherInstance(pids: [7, 8])).logLine
        #expect(dup.contains("7") && dup.contains("8") && dup.contains(AppIdentity.displayName))
        let lock = InstanceDecision.Refusal.alreadyRunning(.lockHeld).logLine
        #expect(lock.contains("lock") && lock.contains(AppIdentity.displayName))
        let legacy = InstanceDecision.Refusal.legacyRunning(pids: [4242]).logLine
        #expect(legacy.contains("4242") && legacy.contains("quill"))
        #expect(dup != lock && lock != legacy)
    }

    // MARK: - legacy process match

    private let legacyPath = "/usr/local/bin/quill"
    private let me: Int32 = 500
    private let myUID: UInt32 = 501

    @Test func onlyTheExactLegacyExecutableMatches() {
        let processes: [(pid: Int32, path: String, uid: UInt32)] = [
            (1, "/sbin/launchd", 0),
            (10, "/usr/local/bin/quill", 501),
            (11, "/usr/local/bin/quill-other", 501),
            (12, "/Users/x/quill/.build/release/quill", 501),
            (13, "/Applications/MeetingVox.app/Contents/MacOS/MeetingVox", 501),
            (14, "/usr/local/bin/quill", 501),
        ]
        #expect(InstanceGuard.legacyPIDs(in: processes, legacyPath: legacyPath, excludingPID: me, uid: myUID) == [10, 14])
        #expect(InstanceGuard.legacyPIDs(in: [], legacyPath: legacyPath, excludingPID: me, uid: myUID) == [])
    }

    @Test func theCurrentProcessIsNeverItsOwnLegacyBlocker() {
        // E.g. a MeetingVox binary installed at the legacy path: its own path
        // matches, but it must not refuse itself.
        let processes: [(pid: Int32, path: String, uid: UInt32)] = [
            (500, "/usr/local/bin/quill", 501),
            (777, "/usr/local/bin/quill", 501),
        ]
        #expect(InstanceGuard.legacyPIDs(in: processes, legacyPath: legacyPath, excludingPID: me, uid: myUID) == [777])
        #expect(InstanceGuard.legacyPIDs(in: [processes[0]], legacyPath: legacyPath, excludingPID: me, uid: myUID) == [])
    }

    @Test func aLegacyProcessOfAnotherUserDoesNotBlock() {
        let processes: [(pid: Int32, path: String, uid: UInt32)] = [
            (10, "/usr/local/bin/quill", 502),
            (11, "/usr/local/bin/quill", 501),
        ]
        #expect(InstanceGuard.legacyPIDs(in: processes, legacyPath: legacyPath, excludingPID: me, uid: myUID) == [11])
    }

    @Test func theLiveProcessListSeesThisProcessWithItsUIDAndPath() throws {
        // Exercises proc_listallpids + proc_pidpath + proc_pidinfo for real.
        let me = ProcessInfo.processInfo.processIdentifier
        let processes = InstanceGuard.runningProcesses()
        let mine = try #require(processes.first { $0.pid == me })
        #expect(!mine.path.isEmpty)
        #expect(mine.uid == getuid())
        // Matched by path, but excluded because it is this very process.
        #expect(InstanceGuard.legacyPIDs(in: processes, legacyPath: mine.path, excludingPID: -1, uid: getuid()).contains(me))
        #expect(!InstanceGuard.legacyPIDs(in: processes, legacyPath: mine.path, excludingPID: me, uid: getuid()).contains(me))
    }

    // MARK: - flock

    private func tempLock() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-lock-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("instance.lock")
    }

    @Test func theLockIsExclusiveUntilItsHolderLetsGo() throws {
        let url = tempLock()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }

        guard case .acquired(let first) = InstanceGuard.acquireLock(at: url) else {
            Issue.record("first acquire should succeed and create the parent dirs"); return
        }
        #expect(InstanceGuard.acquireLock(at: url) == .held)

        close(first)  // releases the flock
        guard case .acquired(let again) = InstanceGuard.acquireLock(at: url) else {
            Issue.record("acquire after release should succeed"); return
        }
        close(again)
    }

    @Test func anUnusableLockPathIsReportedNotHeldAndSaysWhy() {
        // A regular file where the parent dir should be: the lock can't exist,
        // which must not be mistaken for "another instance holds it".
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        FileManager.default.createFile(atPath: base.path, contents: Data("x".utf8))

        let result = InstanceGuard.acquireLock(at: base.appendingPathComponent("instance.lock"))

        guard case .unavailable(let reason) = result else { Issue.record("expected unavailable, got \(result)"); return }
        // The reason is the Cocoa error's own description, not a Cocoa code
        // printed as if it were an errno.
        #expect(!reason.isEmpty)
        #expect(!reason.hasPrefix("errno"))
    }

    @Test func aFailedOpenReportsItsErrno() {
        // A directory where the lock file should be: open(O_RDWR) fails EISDIR.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("instance.lock"), withIntermediateDirectories: true)

        guard case .unavailable(let reason) = InstanceGuard.acquireLock(at: dir.appendingPathComponent("instance.lock")) else {
            Issue.record("expected unavailable"); return
        }
        #expect(reason.hasPrefix("errno \(EISDIR)"))
    }

    // MARK: - awaitClear (transient blockers)

    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [InstanceFacts]
        private(set) var sleeps: [TimeInterval] = []
        private(set) var logs: [String] = []
        private(set) var probes = 0
        init(_ facts: [InstanceFacts]) { remaining = facts }
        func next() -> InstanceFacts {
            lock.lock(); defer { lock.unlock() }
            probes += 1
            return remaining.count > 1 ? remaining.removeFirst() : remaining[0]
        }
        func sleep(_ t: TimeInterval) { lock.lock(); sleeps.append(t); lock.unlock() }
        func log(_ s: String) { lock.lock(); logs.append(s); lock.unlock() }
    }

    private func waitForClear(_ script: Script) -> InstanceDecision {
        InstanceGuard.awaitClear(probe: { script.next() }, sleep: { script.sleep($0) }, log: { script.log($0) })
    }

    @Test func aCleanProbeProceedsWithoutWaiting() {
        let script = Script([facts()])
        #expect(waitForClear(script) == .proceed)
        #expect(script.sleeps.isEmpty)
        #expect(script.probes == 1)
    }

    @Test func aBlockerThatClearsWithinTheWindowLetsTheStartProceed() {
        // The lock of an instance that is still quitting, then a legacy agent
        // that exits: both are transient and must not cost a session.
        let script = Script([facts(lock: .held), facts(legacy: [4242]), facts()])
        #expect(waitForClear(script) == .proceed)
        #expect(script.sleeps == [2, 2])
        #expect(script.probes == 3)
        #expect(script.logs.count >= 1)
    }

    @Test func aStaleListedInstanceDoesNotDelayAProcessThatHoldsTheLock() {
        // Two launches at once: the one that wins the flock starts at once,
        // even if the running-application list still shows the other pid.
        let script = Script([facts(others: [9], lock: .acquired)])
        #expect(waitForClear(script) == .proceed)
        #expect(script.sleeps.isEmpty)
        #expect(script.probes == 1)
    }

    @Test func aStaleListedInstanceThatOnlyClearsLaterNeverCostsTheRecorder() {
        // The loser of the lock race waits, then gets the lock once the
        // winner (a quitting instance) is gone.
        let script = Script([facts(others: [9], lock: .held), facts(others: [9], lock: .held), facts(others: [9], lock: .acquired)])
        #expect(waitForClear(script) == .proceed)
        #expect(script.sleeps == [2, 2])
    }

    @Test func aDuplicateThatKeepsRunningIsRefusedAfterTheWholeWindow() {
        let script = Script([facts(others: [9], lock: .held)])
        #expect(waitForClear(script) == .refuse(.alreadyRunning(.otherInstance(pids: [9]))))
        #expect(script.sleeps.count == 15)
        #expect(script.sleeps.reduce(0, +) == 30)
        #expect(script.probes == 16)
    }

    @Test func aLegacyThatNeverExitsIsRefusedWithTheLastObservedCause() {
        let script = Script([facts(lock: .held), facts(legacy: [4242])])
        #expect(waitForClear(script) == .refuse(.legacyRunning(pids: [4242])))
        #expect(script.sleeps.count == 15)
    }

    // MARK: - probe reuses the lock this process already holds

    @Test func aSecondProbeInTheSameProcessDoesNotSeeItsOwnLockAsHeld() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let first = InstanceGuard.probe(home: home, log: { _ in })
        let second = InstanceGuard.probe(home: home, log: { _ in })

        #expect(first.lock == .acquired)
        #expect(second.lock == .acquired)
        // The descriptor stays open for the life of the test process, like
        // production: nothing else here probes.
    }
}
