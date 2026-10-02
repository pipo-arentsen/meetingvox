import Testing

@testable import MeetingVox

/// Finder, SMAppService and `open` add flags the CLI never declared
/// (`-psn_0_12345`, `-NSDocumentRevisionsDebugMode YES`). If they reached
/// ArgumentParser the app would print a usage error and exit instead of
/// running. The routing is a pure function over the whole argv.
@Suite("LaunchArguments")
struct LaunchArgumentsTests {
    // MARK: - sanitize

    @Test func finderLaunchKeepsOnlyArgv0() {
        #expect(LaunchArguments.sanitize(["MeetingVox", "-psn_0_12345"]) == ["MeetingVox"])
    }

    @Test func noArgumentsIsUntouched() {
        #expect(LaunchArguments.sanitize(["MeetingVox"]) == ["MeetingVox"])
    }

    @Test func realSubcommandsPassThrough() {
        #expect(LaunchArguments.sanitize(["meetingvox", "doctor"]) == ["meetingvox", "doctor"])
        #expect(LaunchArguments.sanitize(["meetingvox", "run", "--out", "/tmp/x"])
            == ["meetingvox", "run", "--out", "/tmp/x"])
    }

    @Test func appKitFlagsAreDroppedTogetherWithTheirValue() {
        #expect(LaunchArguments.sanitize(["MeetingVox", "-NSDocumentRevisionsDebugMode", "YES"]) == ["MeetingVox"])
        #expect(LaunchArguments.sanitize(["MeetingVox", "-AppleLanguages", "(es)", "run"]) == ["MeetingVox", "run"])
    }

    @Test func aFlagWithoutValueDoesNotSwallowTheNextFlag() {
        #expect(LaunchArguments.sanitize(["MeetingVox", "-NSFoo"]) == ["MeetingVox"])
        #expect(LaunchArguments.sanitize(["MeetingVox", "-NSFoo", "--out", "/x"]) == ["MeetingVox", "--out", "/x"])
    }

    @Test func mixedNoiseAroundARealCommandIsRemoved() {
        #expect(LaunchArguments.sanitize(["MeetingVox", "-psn_0_1", "-NSFoo", "YES", "doctor"])
            == ["MeetingVox", "doctor"])
    }

    @Test func aFlagNeverSwallowsAKnownSubcommand() {
        for command in ["run", "doctor", "install", "diag"] {
            #expect(LaunchArguments.sanitize(["meetingvox", "-NSFoo", command]) == ["meetingvox", command])
        }
        // Still flag + value when the value is not a subcommand.
        #expect(LaunchArguments.sanitize(["meetingvox", "-NSFoo", "YES", "doctor"]) == ["meetingvox", "doctor"])
    }

    @Test func emptyArgvStaysEmpty() {
        #expect(LaunchArguments.sanitize([]) == [])
    }

    // MARK: - isRunRoute

    @Test func noArgumentsAndAppKitNoiseRouteToRun() {
        #expect(LaunchArguments.isRunRoute(["MeetingVox"]))
        #expect(LaunchArguments.isRunRoute(["MeetingVox", "-psn_0_12345"]))
        #expect(LaunchArguments.isRunRoute(["MeetingVox", "-NSDocumentRevisionsDebugMode", "YES"]))
    }

    @Test func explicitRunAndItsOptionRouteToRun() {
        #expect(LaunchArguments.isRunRoute(["meetingvox", "run"]))
        #expect(LaunchArguments.isRunRoute(["meetingvox", "run", "--out", "/x"]))
        #expect(LaunchArguments.isRunRoute(["meetingvox", "--out", "/x"]))
    }

    @Test func otherSubcommandsAndHelpAreNotTheRunRoute() {
        #expect(!LaunchArguments.isRunRoute(["meetingvox", "doctor"]))
        #expect(!LaunchArguments.isRunRoute(["meetingvox", "install", "--status"]))
        #expect(!LaunchArguments.isRunRoute(["meetingvox", "diag", "--mode", "mic"]))
        #expect(!LaunchArguments.isRunRoute(["meetingvox", "--help"]))
    }

    @Test func helpOfRunIsNotTheRunRoute() {
        // `run -h` prints usage and exits: it must not redirect stderr nor
        // take the instance lock.
        #expect(!LaunchArguments.isRunRoute(["meetingvox", "run", "-h"]))
        #expect(!LaunchArguments.isRunRoute(["meetingvox", "run", "--help"]))
        #expect(!LaunchArguments.isRunRoute(["meetingvox", "--out", "/x", "--help"]))
        #expect(LaunchArguments.isRunRoute(["meetingvox", "run", "--out", "/x"]))
    }

    @Test func isRunRouteAcceptsRawArgvAndSanitizesItself() {
        #expect(LaunchArguments.isRunRoute(["MeetingVox", "-psn_0_1", "-NSFoo", "run"]))
        #expect(!LaunchArguments.isRunRoute(["MeetingVox", "-psn_0_1", "-NSFoo", "doctor"]))
    }
    // MARK: - isSnapshotRoute

    @Test func diagWithModeSnapshotIsTheSnapshotRoute() {
        #expect(LaunchArguments.isSnapshotRoute(["meetingvox", "diag", "--mode", "snapshot", "--out", "/x"]))
        #expect(LaunchArguments.isSnapshotRoute(["meetingvox", "diag", "--mode=snapshot"]))
        // The option order does not matter.
        #expect(LaunchArguments.isSnapshotRoute(["meetingvox", "diag", "--out", "/x", "--mode", "snapshot"]))
    }

    @Test func otherDiagModesAndOtherCommandsAreNotTheSnapshotRoute() {
        #expect(!LaunchArguments.isSnapshotRoute(["meetingvox", "diag", "--mode", "mic"]))
        #expect(!LaunchArguments.isSnapshotRoute(["meetingvox", "diag", "--mode=processes"]))
        #expect(!LaunchArguments.isSnapshotRoute(["meetingvox", "diag"]))
        #expect(!LaunchArguments.isSnapshotRoute(["meetingvox"]))
        #expect(!LaunchArguments.isSnapshotRoute(["meetingvox", "run", "--out", "/x"]))
        #expect(!LaunchArguments.isSnapshotRoute(["meetingvox", "doctor"]))
        // `snapshot` as some other option's value is not the mode.
        #expect(!LaunchArguments.isSnapshotRoute(["meetingvox", "diag", "--out", "snapshot"]))
        #expect(!LaunchArguments.isSnapshotRoute(["meetingvox", "run", "--mode", "snapshot"]))
    }

    @Test func theLastModeWinsAsArgumentParserResolvesIt() {
        #expect(!LaunchArguments.isSnapshotRoute(["meetingvox", "diag", "--mode", "snapshot", "--mode", "mic"]))
        #expect(LaunchArguments.isSnapshotRoute(["meetingvox", "diag", "--mode", "mic", "--mode=snapshot"]))
    }

    @Test func aBareModeFlagWithoutValueIsNotTheSnapshotRoute() {
        #expect(!LaunchArguments.isSnapshotRoute(["meetingvox", "diag", "--mode"]))
    }

    @Test func isSnapshotRouteSanitizesItsOwnArgv() {
        #expect(LaunchArguments.isSnapshotRoute(["MeetingVox", "-psn_0_1", "-NSFoo", "diag", "--mode", "snapshot"]))
        #expect(!LaunchArguments.isSnapshotRoute(["MeetingVox", "-psn_0_1", "diag", "--mode", "mic"]))
    }

    @Test func theSnapshotRouteIsNeverTheRunRoute() {
        // It must neither redirect stderr nor take the instance lock.
        #expect(!LaunchArguments.isRunRoute(["meetingvox", "diag", "--mode", "snapshot", "--out", "/x"]))
    }
}
