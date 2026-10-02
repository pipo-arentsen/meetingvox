import Foundation
import Testing

@testable import MeetingVox

/// The order at process start is the contract: log redirect first (so every
/// later line lands in the file, appending, never rotating), the
/// single-instance check next (a refused second instance must not rotate the
/// live log, migrate or start a recorder), rotation only once this process
/// holds the lock, the config migration before anything reads config, and
/// only then the command.
@Suite("Entry point")
struct EntryPointTests {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
        func add(_ e: String) { lock.lock(); items.append(e); lock.unlock() }
    }

    private func steps(_ events: Events, decision: InstanceDecision = .proceed) -> MeetingVoxMain.Steps {
        MeetingVoxMain.Steps(
            redirectLog: { events.add("redirect") },
            decideInstance: { events.add("instance"); return decision },
            refuse: { events.add("refuse:\($0.logLine)") },
            rotateLog: { events.add("rotate") },
            migrate: { events.add("migrate") },
            launch: { events.add("launch:\($0.joined(separator: " "))") }
        )
    }

    @Test func bundledRunRedirectsThenGuardsThenRotatesThenMigratesThenLaunches() {
        let events = Events()

        MeetingVoxMain.start(
            arguments: ["MeetingVox", "-psn_0_12345"], isBundled: true, stderrIsTTY: false, steps: steps(events)
        )

        #expect(events.all == ["redirect", "instance", "rotate", "migrate", "launch:"])
    }

    @Test func aRefusedSecondInstanceNeverRotatesMigratesOrLaunches() {
        let events = Events()
        let refusal = InstanceDecision.Refusal.alreadyRunning(.lockHeld)

        MeetingVoxMain.start(
            arguments: ["MeetingVox"], isBundled: true, stderrIsTTY: false,
            steps: steps(events, decision: .refuse(refusal))
        )

        // The refusal line is appended to the live log; the live log is not
        // rotated out from under the running instance.
        #expect(events.all == ["redirect", "instance", "refuse:" + refusal.logLine])
    }

    @Test func aRunningLegacyQuillIsRefusedTheSameWay() {
        let events = Events()

        MeetingVoxMain.start(
            arguments: ["MeetingVox"], isBundled: true, stderrIsTTY: false,
            steps: steps(events, decision: .refuse(.legacyRunning(pids: [4242])))
        )

        #expect(events.all.last?.contains("legacy quill is running (pid 4242)") == true)
        #expect(!events.all.contains("rotate"))
        #expect(!events.all.contains("migrate"))
        #expect(!events.all.contains { $0.hasPrefix("launch") })
    }

    @Test func doctorNeitherRedirectsGuardsNorRotatesButStillMigrates() {
        let events = Events()

        MeetingVoxMain.start(
            arguments: ["meetingvox", "doctor"], isBundled: true, stderrIsTTY: false, steps: steps(events)
        )

        #expect(events.all == ["migrate", "launch:doctor"])
    }

    @Test func runHelpTakesNeitherTheRedirectNorTheGuard() {
        let events = Events()

        MeetingVoxMain.start(
            arguments: ["meetingvox", "run", "--help"], isBundled: true, stderrIsTTY: false, steps: steps(events)
        )

        #expect(events.all == ["migrate", "launch:run --help"])
    }

    @Test func aTerminalRunKeepsItsStderrAndItsLogUntouchedButHonoursTheGuard() {
        let events = Events()

        MeetingVoxMain.start(
            arguments: ["meetingvox", "run", "--out", "/x"], isBundled: false, stderrIsTTY: true, steps: steps(events)
        )

        #expect(events.all == ["instance", "migrate", "launch:run --out /x"])
    }

    @Test func aRefusedDoctorIsImpossibleBecauseTheGuardIsRunOnly() {
        let events = Events()

        MeetingVoxMain.start(
            arguments: ["meetingvox", "doctor"], isBundled: false, stderrIsTTY: true,
            steps: steps(events, decision: .refuse(.legacyRunning(pids: [1])))
        )

        #expect(events.all == ["migrate", "launch:doctor"])
    }
    @Test func theSnapshotRouteSkipsTheConfigMigrationAndTheGuardButLaunches() {
        let events = Events()

        MeetingVoxMain.start(
            arguments: ["meetingvox", "diag", "--mode", "snapshot", "--out", "/x"],
            isBundled: true, stderrIsTTY: false, steps: steps(events)
        )

        // The migration would copy ~/.config/quill: a headless render must
        // never touch the real home.
        #expect(events.all == ["launch:diag --mode snapshot --out /x"])
    }

    @Test func otherDiagModesStillMigrate() {
        let events = Events()

        MeetingVoxMain.start(
            arguments: ["meetingvox", "diag", "--mode=processes"], isBundled: false, stderrIsTTY: true,
            steps: steps(events)
        )

        #expect(events.all == ["migrate", "launch:diag --mode=processes"])
    }

    @Test func theSnapshotRouteIsRecognizedThroughLauncherNoise() {
        let events = Events()

        MeetingVoxMain.start(
            arguments: ["meetingvox", "-NSFoo", "YES", "diag", "--mode=snapshot"],
            isBundled: false, stderrIsTTY: true, steps: steps(events)
        )

        #expect(events.all == ["launch:diag --mode=snapshot"])
    }
}
