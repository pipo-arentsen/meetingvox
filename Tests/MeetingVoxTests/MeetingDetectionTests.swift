import AppKit
import Foundation
import Testing
@testable import MeetingVox

// MARK: - Rule matching

@Suite struct MeetingAppMatchingTests {
    private func resolve(_ bundleID: String?, app: String? = nil) -> String? {
        MeetingApp.resolve(ProcessIdentity(pid: 100, bundleID: bundleID, appBundleID: app))?.id
    }

    @Test func exactBundleIDs() {
        #expect(resolve("com.microsoft.teams2") == "teams")
        #expect(resolve("com.microsoft.teams") == "teams")
        #expect(resolve("us.zoom.xos") == "zoom")
        #expect(resolve("net.whatsapp.WhatsApp") == "whatsapp")
        #expect(resolve("com.browseros.BrowserOS") == "browseros")
        #expect(resolve("com.brave.Browser") == "brave")
        #expect(resolve("com.apple.Safari") == "safari")
    }

    @Test func chromiumHelpersMatchByPrefix() {
        #expect(resolve("com.browseros.BrowserOS.helper") == "browseros")
        #expect(resolve("com.brave.Browser.helper.renderer") == "brave")
        #expect(resolve("com.microsoft.teams2.helper") == "teams")
        // Case-insensitive, like bundle ids themselves.
        #expect(resolve("COM.BRAVE.BROWSER.HELPER") == "brave")
    }

    @Test func prefixNeedsADotBoundary() {
        #expect(resolve("com.brave.BrowserBeta") == nil)
        #expect(resolve("us.zoom.xosfake") == nil)
    }

    @Test func unknownAppsAreIgnored() {
        #expect(resolve("com.google.Chrome.helper") == nil)
        #expect(resolve("com.apple.FaceTime") == nil)
        #expect(resolve(nil) == nil)
    }

    @Test func helperWithForeignIDResolvesThroughOwningApp() {
        #expect(resolve("com.microsoft.edgemac.helper", app: "com.microsoft.teams2") == "teams")
        #expect(resolve(nil, app: "com.browseros.BrowserOS") == "browseros")
    }

    @Test func webKitCaptureMapsToSafariWhenResolvedElseGenericBrowser() {
        #expect(resolve("com.apple.WebKit.GPU", app: "com.apple.Safari") == "safari")
        #expect(resolve("com.apple.WebKit.GPU") == "webkit")
        #expect(MeetingApp.webKit.label == "Llamada en el navegador")
    }

    @Test func webKitFallbackOnlyWhenOwnerUnresolved() {
        // A non-browser app embedding a WKWebView resolved to itself: not a call.
        #expect(resolve("com.apple.WebKit.GPU", app: "com.example.Notes") == nil)
        #expect(resolve("com.apple.WebKit.WebContent", app: "com.apple.Safari") == "safari")
    }

    @Test func ignoredByIDOrBundleIDCaseInsensitive() {
        #expect(MeetingApp.zoom.isIgnored(by: ["ZOOM"]))
        #expect(MeetingApp.teams.isIgnored(by: ["com.microsoft.Teams2"]))
        #expect(!MeetingApp.teams.isIgnored(by: ["zoom"]))
    }

    @Test func outermostAppBundleFromHelperPath() {
        let path = "/Applications/BrowserOS.app/Contents/Frameworks/BrowserOS Framework.framework/Versions/1/Helpers/"
            + "BrowserOS Helper.app/Contents/MacOS/BrowserOS Helper"
        #expect(AppResolver.outermostAppBundle(inExecutablePath: path) == "/Applications/BrowserOS.app")
        #expect(AppResolver.outermostAppBundle(
            inExecutablePath: "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        ) == nil)
    }

    @Test func labelsAndThresholds() {
        #expect(MeetingApp.teams.label == "Reunión Teams")
        #expect(MeetingApp.whatsApp.label == "Llamada de WhatsApp")
        #expect(MeetingApp.brave.label == "Llamada en Brave")
        #expect(Textos.Reuniones.detectada(MeetingApp.zoom.label) == "Reunión Zoom detectada")
        #expect(MeetingApp.whatsApp.threshold == 8)
        #expect(MeetingApp.all.filter { $0 != .whatsApp }.allSatisfy { $0.threshold == 3 })
        #expect(Set(MeetingApp.all.map(\.id)).count == MeetingApp.all.count)
    }
}

// MARK: - State machine

@Suite struct MeetingDetectionMachineTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let ownPID: pid_t = 1

    private func ctx(_ seconds: TimeInterval, recording: Bool = false, enabled: Bool = true,
                     ignored: Set<String> = [], promptVisible: Bool = false) -> MeetingDetectionMachine.Context {
        MeetingDetectionMachine.Context(
            now: t0.addingTimeInterval(seconds), recording: recording, enabled: enabled,
            ignored: ignored, promptVisible: promptVisible, ownPID: ownPID)
    }

    private func obs(_ app: MeetingApp, pid: pid_t = 500) -> [MeetingDetectionMachine.Observation] {
        [.init(pid: pid, app: app)]
    }

    /// Feed `observations` once per second over `range`; returns the seconds
    /// at which a prompt fired.
    private func run(
        _ machine: inout MeetingDetectionMachine, _ range: ClosedRange<Int>,
        _ observations: [MeetingDetectionMachine.Observation],
        recording: Bool = false, ignored: Set<String> = [], promptVisible: Bool = false
    ) -> [Int] {
        range.compactMap { s in
            machine.step(observations, ctx(TimeInterval(s), recording: recording,
                                           ignored: ignored, promptVisible: promptVisible)) != nil ? s : nil
        }
    }

    @Test func promptsAfterThreeSecondsOfContinuousUse() {
        var machine = MeetingDetectionMachine()
        let prompt = machine.step(obs(.teams), ctx(0))
        #expect(prompt == nil)
        #expect(machine.step(obs(.teams), ctx(2)) == nil)
        #expect(machine.step(obs(.teams), ctx(3)) == .init(app: .teams, pid: 500))
    }

    @Test func whatsAppNeedsEightSeconds() {
        var machine = MeetingDetectionMachine()
        #expect(run(&machine, 0...10, obs(.whatsApp)) == [8])
    }

    @Test func shortVoiceNoteNeverPrompts() {
        var machine = MeetingDetectionMachine()
        #expect(run(&machine, 0...6, obs(.whatsApp)).isEmpty)
        #expect(run(&machine, 7...20, []).isEmpty)
    }

    @Test func interruptedUseRestartsTheThreshold() {
        var machine = MeetingDetectionMachine()
        #expect(run(&machine, 0...2, obs(.zoom)).isEmpty)
        #expect(run(&machine, 3...3, []).isEmpty)
        #expect(run(&machine, 4...10, obs(.zoom)) == [7])
    }

    @Test func noRepromptDuringContinuousUse() {
        var machine = MeetingDetectionMachine()
        #expect(run(&machine, 0...300, obs(.teams)) == [3])
    }

    @Test func shortPauseAfterPromptDoesNotRearm() {
        var machine = MeetingDetectionMachine()
        #expect(run(&machine, 0...5, obs(.teams)) == [3])
        #expect(run(&machine, 6...14, []).isEmpty) // idle 9 s
        #expect(run(&machine, 15...40, obs(.teams)).isEmpty)
    }

    @Test func idleTenSecondsRearms() {
        var machine = MeetingDetectionMachine()
        #expect(run(&machine, 0...5, obs(.teams)) == [3])
        #expect(run(&machine, 6...15, []).isEmpty) // idle since 6, back at 16 = 10 s
        #expect(run(&machine, 16...20, obs(.teams)) == [19])
    }

    @Test func ignoredAppsNeverPrompt() {
        var machine = MeetingDetectionMachine()
        #expect(run(&machine, 0...20, obs(.whatsApp), ignored: ["whatsapp"]).isEmpty)
        #expect(run(&machine, 0...20, obs(.teams), ignored: ["com.microsoft.teams2"]).isEmpty)
        // Other apps still prompt.
        #expect(run(&machine, 21...25, obs(.zoom), ignored: ["whatsapp"]) == [24])
    }

    @Test func disabledNeverPrompts() {
        var machine = MeetingDetectionMachine()
        let prompts = (0...10).compactMap { machine.step(obs(.teams), ctx(TimeInterval($0), enabled: false)) }
        #expect(prompts.isEmpty)
    }

    @Test func notWhileRecordingNorAfterForTheSameUse() {
        var machine = MeetingDetectionMachine()
        #expect(run(&machine, 0...10, obs(.teams), recording: true).isEmpty)
        // Recording stopped mid-call: same continuous use, no prompt.
        #expect(run(&machine, 11...30, obs(.teams)).isEmpty)
        // Call ends, a new one starts later: prompts again.
        #expect(run(&machine, 31...45, []).isEmpty)
        #expect(run(&machine, 46...50, obs(.teams)) == [49])
    }

    @Test func ownPIDIsExcluded() {
        var machine = MeetingDetectionMachine()
        #expect(run(&machine, 0...10, obs(.teams, pid: ownPID)).isEmpty)
    }

    @Test func visiblePromptHoldsOthersWithoutConsumingThem() {
        var machine = MeetingDetectionMachine()
        #expect(run(&machine, 0...5, obs(.zoom), promptVisible: true).isEmpty)
        #expect(run(&machine, 6...6, obs(.zoom)) == [6])
    }

    @Test func deadlineOnlyWhileACandidateWaits() {
        var machine = MeetingDetectionMachine()
        #expect(machine.nextDeadline(ctx(0)) == nil)
        _ = machine.step(obs(.whatsApp), ctx(1))
        #expect(machine.nextDeadline(ctx(1)) == t0.addingTimeInterval(9))
        // Ignored, disabled, recording or held by a visible prompt: no timer.
        #expect(machine.nextDeadline(ctx(2, ignored: ["whatsapp"])) == nil)
        #expect(machine.nextDeadline(ctx(2, enabled: false)) == nil)
        #expect(machine.nextDeadline(ctx(2, recording: true)) == nil)
        #expect(machine.nextDeadline(ctx(2, promptVisible: true)) == nil)
        #expect(machine.step(obs(.whatsApp), ctx(9)) != nil)
        // Prompted: handled, nothing left to time.
        #expect(machine.nextDeadline(ctx(9)) == nil)
    }

    @Test func statusForDiag() {
        var machine = MeetingDetectionMachine()
        _ = machine.step(obs(.teams), ctx(0))
        #expect(machine.status(of: .teams, ctx(1)) == .waiting(elapsed: 1, threshold: 3))
        _ = machine.step(obs(.teams), ctx(3))
        #expect(machine.status(of: .teams, ctx(3)) == .handled)
        #expect(machine.status(of: .zoom, ctx(3)) == .idle)
        #expect(machine.status(of: .teams, ctx(3, ignored: ["teams"])) == .ignored)
        #expect(machine.status(of: .teams, ctx(3, enabled: false)) == .disabled)
    }
}

// MARK: - End machine

@Suite struct MeetingEndMachineTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let ownPID: pid_t = 1
    private let grace = Int(MeetingEndMachine.grace)

    private func ctx(_ seconds: Int, enabled: Bool = true, ignored: Set<String> = [],
                     promptVisible: Bool = false) -> MeetingEndMachine.Context {
        MeetingEndMachine.Context(
            now: t0.addingTimeInterval(TimeInterval(seconds)), enabled: enabled, ignored: ignored,
            promptVisible: promptVisible, ownPID: ownPID)
    }

    private func obs(_ apps: MeetingApp..., pid: pid_t = 500) -> [MeetingDetectionMachine.Observation] {
        apps.map { .init(pid: pid, app: $0) }
    }

    /// Feed `observations` once per second over `range`; returns the seconds
    /// at which an end prompt fired.
    private func run(
        _ machine: inout MeetingEndMachine, _ range: ClosedRange<Int>,
        _ observations: [MeetingDetectionMachine.Observation],
        enabled: Bool = true, ignored: Set<String> = [], promptVisible: Bool = false
    ) -> [Int] {
        range.compactMap { s in
            machine.step(observations, ctx(s, enabled: enabled, ignored: ignored, promptVisible: promptVisible))
                != nil ? s : nil
        }
    }

    @Test func promptsAfterGraceOfAllWatchedIdle() {
        var machine = MeetingEndMachine()
        #expect(run(&machine, 0...30, obs(.teams)).isEmpty)
        // Released at 31 → asks at 31 + 15.
        #expect(run(&machine, 31...80, []) == [31 + grace])
        #expect(machine.step([], ctx(31 + grace)) == nil) // once
    }

    @Test func namesTheAppThatReleasedLast() {
        var machine = MeetingEndMachine()
        _ = run(&machine, 0...10, obs(.teams, .whatsApp))
        _ = run(&machine, 11...11, obs(.whatsApp)) // Teams released first
        let prompts = (12...40).compactMap { machine.step([], ctx($0)) }
        #expect(prompts == [.init(app: .whatsApp)])
        #expect(MeetingApp.whatsApp.endedTitle == "La llamada de WhatsApp terminó")
    }

    @Test func everyWatchedAppMustBeIdle() {
        var machine = MeetingEndMachine()
        _ = run(&machine, 0...5, obs(.teams, .zoom))
        #expect(run(&machine, 6...60, obs(.zoom)).isEmpty)
        #expect(run(&machine, 61...80, []) == [61 + grace])
    }

    @Test func resumeWithinGraceCancels() {
        var machine = MeetingEndMachine()
        _ = run(&machine, 0...5, obs(.teams))
        #expect(run(&machine, 6...(5 + grace), []).isEmpty) // idle 14 s
        #expect(run(&machine, (6 + grace)...60, obs(.teams)).isEmpty)
        #expect(machine.nextDeadline(ctx(60)) == nil)
        // A later, real end still asks, a full grace after it.
        #expect(run(&machine, 61...100, []) == [61 + grace])
    }

    @Test func keepRecordingSuppressesUntilNewCaptureAndRelease() {
        var machine = MeetingEndMachine()
        _ = run(&machine, 0...5, obs(.teams))
        #expect(run(&machine, 6...30, []) == [6 + grace])
        machine.dismissed()
        #expect(run(&machine, 31...200, []).isEmpty)
        #expect(machine.status(ctx(200)) == .disarmed)
        _ = run(&machine, 201...210, obs(.teams))
        #expect(run(&machine, 211...240, []) == [211 + grace])
    }

    @Test func keepRecordingWhileTheCallResumedStillAsksOnItsRelease() {
        var machine = MeetingEndMachine()
        _ = run(&machine, 0...5, obs(.teams))
        #expect(run(&machine, 6...30, []) == [6 + grace])
        // The call came back while the panel was up; the user then answers.
        _ = run(&machine, 31...40, obs(.teams), promptVisible: true)
        machine.dismissed()
        #expect(run(&machine, 41...70, []) == [41 + grace])
    }

    @Test func keepRecordingHonorsACaptureThatEndedWhileThePanelWasUp() {
        var machine = MeetingEndMachine()
        _ = run(&machine, 0...5, obs(.teams))
        #expect(run(&machine, 6...30, []) == [6 + grace])
        // Rejoined and hung up again, all while the panel was up.
        _ = run(&machine, 31...40, obs(.teams), promptVisible: true)
        #expect(run(&machine, 41...60, [], promptVisible: true).isEmpty)
        machine.dismissed() // nothing captures at click time
        #expect(run(&machine, 61...61, []) == [61])
    }

    @Test func briefCapturesAreNotWatched() {
        var machine = MeetingEndMachine()
        // A 2 s browser probe, then a 7 s WhatsApp voice note: never watched.
        _ = run(&machine, 0...1, obs(.brave))
        _ = run(&machine, 2...8, obs(.whatsApp))
        #expect(run(&machine, 9...60, []).isEmpty)
        #expect(machine.status(ctx(60)) == .notWatching)
        // A real WhatsApp call (8 s continuous) is watched.
        _ = run(&machine, 61...69, obs(.whatsApp))
        #expect(run(&machine, 70...90, []) == [70 + grace])
    }

    @Test func releaseSeenLateCountsOnlyUpToTheLastCapturingStep() {
        // Core Audio does not notify a release: a rescan sees it late, and
        // the unseen gap must not turn a probe into a watched capture.
        var machine = MeetingEndMachine()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let teams = MeetingApp.resolve(ProcessIdentity(pid: 800, bundleID: "com.microsoft.teams2.modulehost", appBundleID: nil))!
        _ = machine.step([.init(pid: 800, app: teams)], .init(now: t0))
        _ = machine.step([], .init(now: t0.addingTimeInterval(5)))
        #expect(machine.status(.init(now: t0.addingTimeInterval(5))) == .notWatching)
    }

    @Test func briefCaptureDoesNotRearmAfterAPrompt() {
        var machine = MeetingEndMachine()
        _ = run(&machine, 0...5, obs(.teams))
        #expect(run(&machine, 6...30, []) == [6 + grace])
        machine.dismissed()
        _ = run(&machine, 31...32, obs(.teams)) // mic probe, 2 s
        #expect(run(&machine, 33...100, []).isEmpty)
        _ = run(&machine, 101...104, obs(.teams)) // 3 s: counts
        #expect(run(&machine, 105...130, []) == [105 + grace])
    }

    @Test func qualifyingResumeWithdrawsTheOutstandingPrompt() {
        var machine = MeetingEndMachine()
        _ = run(&machine, 0...5, obs(.teams))
        #expect(run(&machine, 6...30, []) == [6 + grace])
        #expect(machine.outstanding == .init(app: .teams))
        _ = run(&machine, 31...32, obs(.teams), promptVisible: true)
        #expect(machine.outstanding != nil) // a blip is not a resume
        #expect(machine.nextDeadline(ctx(32, promptVisible: true)) == t0.addingTimeInterval(34))
        _ = run(&machine, 33...34, obs(.teams), promptVisible: true)
        #expect(machine.outstanding == nil)
    }

    @Test func ignoringTheNamedAppWithdrawsAndNeverNamesIt() {
        var machine = MeetingEndMachine()
        _ = run(&machine, 0...5, obs(.teams, .zoom))
        _ = run(&machine, 6...6, obs(.teams)) // Zoom released
        _ = run(&machine, 7...7, []) // then Teams: lastReleased = teams
        _ = run(&machine, 8...10, [], ignored: ["teams"])
        #expect(run(&machine, 11...40, [], ignored: ["teams"]) == [7 + grace])
        #expect(machine.outstanding == .init(app: .zoom))
        _ = machine.step([], ctx(41, ignored: ["teams", "zoom"]))
        #expect(machine.outstanding == nil)
    }

    @Test func ignoreChangeAloneDoesNotStartTheGrace() {
        var machine = MeetingEndMachine()
        _ = run(&machine, 0...10, obs(.teams, .whatsApp))
        _ = run(&machine, 11...20, obs(.teams)) // WhatsApp idle, Teams still in the call
        #expect(run(&machine, 21...21, [], ignored: ["teams"]) == [])
        #expect(run(&machine, 22...100, obs(.teams), ignored: ["teams"]).isEmpty)
        #expect(machine.nextDeadline(ctx(100, ignored: ["teams"])) == nil)
    }

    @Test func simultaneousReleasesNameTheSameAppEveryTime() {
        for _ in 0..<20 {
            var machine = MeetingEndMachine()
            _ = run(&machine, 0...5, obs(.zoom, .teams, .brave))
            let prompts = (6...30).compactMap { machine.step([], ctx($0)) }
            #expect(prompts == [.init(app: .zoom)]) // last in id order
        }
    }

    @Test func wakeRestartsTheGrace() {
        var machine = MeetingEndMachine()
        _ = run(&machine, 0...5, obs(.teams))
        _ = run(&machine, 6...10, [])
        machine.clockResumed(at: t0.addingTimeInterval(3600))
        #expect(machine.step([], ctx(3600)) == nil)
        #expect(machine.nextDeadline(ctx(3600)) == t0.addingTimeInterval(3600 + MeetingEndMachine.grace))
    }

    @Test func visiblePanelHoldsWithoutConsuming() {
        var machine = MeetingEndMachine()
        _ = run(&machine, 0...5, obs(.teams))
        #expect(run(&machine, 6...40, [], promptVisible: true).isEmpty)
        #expect(machine.nextDeadline(ctx(40, promptVisible: true)) == nil)
        #expect(run(&machine, 41...41, []) == [41])
    }

    @Test func disabledNeverPromptsAndForgets() {
        var machine = MeetingEndMachine()
        #expect(run(&machine, 0...5, obs(.teams), enabled: false).isEmpty)
        #expect(run(&machine, 6...60, [], enabled: false).isEmpty)
        #expect(machine.status(ctx(60, enabled: false)) == .disabled)
        // Watched while enabled, then disabled: state is dropped.
        _ = run(&machine, 61...65, obs(.teams))
        _ = run(&machine, 66...66, [], enabled: false)
        #expect(run(&machine, 67...120, []).isEmpty)
    }

    @Test func ignoredAppsAreNotWatched() {
        var machine = MeetingEndMachine()
        _ = run(&machine, 0...5, obs(.whatsApp), ignored: ["whatsapp"])
        #expect(run(&machine, 6...60, [], ignored: ["whatsapp"]).isEmpty)
        #expect(machine.status(ctx(60, ignored: ["whatsapp"])) == .notWatching)
        // Ignored mid-recording while it still captures: the others decide.
        _ = run(&machine, 61...65, obs(.teams, .zoom))
        #expect(run(&machine, 66...100, obs(.zoom), ignored: ["us.zoom.xos"]) == [66 + grace])
    }

    @Test func ownPIDIsNotWatched() {
        var machine = MeetingEndMachine()
        _ = run(&machine, 0...5, obs(.teams, pid: ownPID))
        #expect(run(&machine, 6...60, []).isEmpty)
    }

    @Test func appThatNeverCapturedDuringTheRecordingNeverTriggers() {
        var machine = MeetingEndMachine()
        #expect(run(&machine, 0...120, []).isEmpty)
        #expect(machine.status(ctx(120)) == .notWatching)
        #expect(machine.nextDeadline(ctx(120)) == nil)
    }

    @Test func deadlineAndStatusForDiag() {
        var machine = MeetingEndMachine()
        _ = machine.step(obs(.teams), ctx(0))
        #expect(machine.status(ctx(0)) == .notWatching)
        #expect(machine.nextDeadline(ctx(0)) == t0.addingTimeInterval(3)) // threshold
        _ = machine.step(obs(.teams), ctx(5))
        #expect(machine.status(ctx(5)) == .capturing(["teams"]))
        #expect(machine.nextDeadline(ctx(5)) == nil)
        _ = machine.step([], ctx(10))
        #expect(machine.nextDeadline(ctx(10)) == t0.addingTimeInterval(TimeInterval(10 + grace)))
        #expect(machine.status(ctx(17)) == .grace(elapsed: 7, grace: MeetingEndMachine.grace))
    }

    @Test func endedTitles() {
        #expect(MeetingApp.teams.endedTitle == "La reunión de Teams terminó")
        #expect(MeetingApp.zoom.endedTitle == "La reunión de Zoom terminó")
        #expect(MeetingApp.browserOS.endedTitle == "La llamada en BrowserOS terminó")
        #expect(MeetingApp.webKit.endedTitle == "La llamada en el navegador terminó")
    }
}

// MARK: - Config

@Suite struct MeetingDetectionConfigTests {
    @Test func defaults() {
        let v = ConfigValues(raw: [:])
        #expect(v.meetingDetectionEnabled == true)
        #expect(v.meetingDetectionIgnoredApps == [])
        #expect(v.meetingDetectionPromptOnEnd == true)
        #expect(MeetingDetectionConfig(v).promptOnEnd == true)
    }

    @Test func promptOnEndReadAndValidated() {
        let off = ConfigValues(raw: ["meeting_detection": ["prompt_on_end": false]])
        #expect(off.meetingDetectionPromptOnEnd == false)
        #expect(MeetingDetectionConfig(off).promptOnEnd == false)
        let bad = ConfigValues(raw: ["meeting_detection": ["prompt_on_end": "no"]])
        #expect(bad.meetingDetectionFormatError == "meeting_detection.prompt_on_end")
        #expect(MeetingDetectionConfig(bad).promptOnEnd == true)
    }

    @Test func readsValuesAndDropsJunk() {
        let v = ConfigValues(raw: [
            "meeting_detection": ["enabled": false, "ignored_apps": [" whatsapp ", "", 3, "us.zoom.xos"] as [Any]] as [String: Any],
        ])
        #expect(v.meetingDetectionEnabled == false)
        #expect(v.meetingDetectionIgnoredApps == ["whatsapp", "us.zoom.xos"])
    }

    @Test func roundTripPreservesUnknownKeys() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-meetings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"meeting_detection": {"futuro": 1}, "otra": true}"#.utf8).write(to: url)

        try ConfigStore.set(false, at: "meeting_detection", "enabled", url: url)
        try ConfigStore.set(["whatsapp"], at: "meeting_detection", "ignored_apps", url: url)

        let raw = try ConfigStore.loadRaw(at: url)
        let values = ConfigValues(raw: raw)
        #expect(values.meetingDetectionEnabled == false)
        #expect(values.meetingDetectionIgnoredApps == ["whatsapp"])
        #expect((raw["meeting_detection"] as? [String: Any])?["futuro"] as? Int == 1)
        #expect(raw["otra"] as? Bool == true)
    }
}

// MARK: - Live detector (fake source and clock)

@MainActor
private final class FakeSource: MeetingProcessSource {
    private(set) var starts = 0
    private(set) var stops = 0
    private var onUpdate: (@MainActor ([ProcessIdentity]) -> Void)?
    var isWatching: Bool { onUpdate != nil }
    /// What Core Audio reports right now; delivered on start (resync).
    var current: [ProcessIdentity] = []

    func start(onUpdate: @escaping @MainActor ([ProcessIdentity]) -> Void) {
        starts += 1
        self.onUpdate = onUpdate
        onUpdate(current)
    }

    func stop() {
        stops += 1
        onUpdate = nil
    }

    /// A Core Audio event (process list / IsRunningInput change). Dropped
    /// while stopped, like the real source.
    func emit(_ processes: [ProcessIdentity]) {
        current = processes
        onUpdate?(processes)
    }
}

/// Scans are delivered only when the test says so (a real rescan is async).
private final class GatedSource: MeetingProcessSource {
    private var onUpdate: (@MainActor ([ProcessIdentity]) -> Void)?
    func start(onUpdate: @escaping @MainActor ([ProcessIdentity]) -> Void) { self.onUpdate = onUpdate }
    func stop() { onUpdate = nil }
    func deliver(_ processes: [ProcessIdentity]) { onUpdate?(processes) }
}

@MainActor
@Suite final class MeetingDetectorTests {
    private let source = FakeSource()
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var config = MeetingDetectionConfig()
    private var prompts: [String] = []
    private var endPrompts: [String] = []
    private var promptVisible = false
    private var withdrawals = 0
    private let center = NotificationCenter()
    private let workspace = NotificationCenter()
    private lazy var detector: MeetingDetector = {
        let detector = MeetingDetector(
            source: source, loadConfig: { [unowned self] in self.config },
            now: { [unowned self] in self.clock }, notifications: center, workspaceNotifications: workspace)
        detector.onPrompt = { [unowned self] in self.prompts.append($0.app.id) }
        detector.onEndPrompt = { [unowned self] in self.endPrompts.append($0.app.id) }
        detector.onEndPromptWithdrawn = { [unowned self] in self.withdrawals += 1 }
        detector.isPromptVisible = { [unowned self] in self.promptVisible }
        return detector
    }()

    private let zoomOnUSBMic = ProcessIdentity(pid: 700, bundleID: "us.zoom.xos", appBundleID: nil)

    private func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    /// Advance to the scheduled deadline (if any) and fire the timer.
    private func fireTimer() {
        guard let deadline = detector.deadline else { return }
        clock = max(clock, deadline)
        detector.timerFired()
    }

    @Test func processEventAloneTriggersDetection() {
        // Zoom captures from a non-default device: the only signal is its
        // own IsRunningInput change, delivered as a process update.
        detector.start()
        source.emit([zoomOnUSBMic])
        #expect(detector.deadline == clock.addingTimeInterval(3))
        advance(1)
        detector.timerFired() // early fire: nothing yet, re-armed
        #expect(prompts.isEmpty)
        fireTimer()
        #expect(prompts == ["zoom"])
        #expect(detector.deadline == nil) // prompted: no timer
    }

    @Test func noTimerWithoutACandidate() {
        detector.start()
        source.emit([ProcessIdentity(pid: 9, bundleID: "com.apple.FaceTime", appBundleID: nil)])
        #expect(detector.deadline == nil)
        config.ignored = ["zoom"]
        detector.configDidChange()
        source.emit([zoomOnUSBMic])
        #expect(detector.deadline == nil)
    }

    @Test func recordingPausesScanningAndResyncsAfter() {
        config.promptOnEnd = false // nothing to watch while recording
        detector.start()
        source.emit([zoomOnUSBMic])
        detector.setRecording(true)
        #expect(!source.isWatching) // no listeners, no scans
        #expect(detector.deadline == nil) // no timer
        source.emit([zoomOnUSBMic]) // ignored while recording
        advance(600)
        detector.setRecording(false)
        #expect(source.isWatching)
        #expect(source.starts == 2) // one resync
        // Same call still active after the recording: handled, no prompt.
        #expect(detector.deadline == nil)
        fireTimer()
        #expect(prompts.isEmpty)
        // It ends, a new call starts later: prompts again.
        source.emit([])
        advance(10)
        source.emit([zoomOnUSBMic])
        fireTimer()
        #expect(prompts == ["zoom"])
    }

    @Test func enablingMidCallAppliesImmediately() {
        config.enabled = false
        detector.start()
        #expect(!source.isWatching)
        source.current = [zoomOnUSBMic]
        advance(120)
        config.enabled = true
        center.post(name: .meetingVoxConfigDidChange, object: nil)
        #expect(source.isWatching)
        // Fresh threshold from now, not from before the toggle.
        #expect(detector.deadline == clock.addingTimeInterval(3))
        fireTimer()
        #expect(prompts == ["zoom"])
    }

    @Test func disablingForgetsStateSoReenableStartsFresh() {
        detector.start()
        source.emit([zoomOnUSBMic])
        advance(2)
        config.enabled = false
        detector.configDidChange()
        #expect(!source.isWatching && detector.deadline == nil)
        advance(60)
        config.enabled = true
        detector.configDidChange()
        #expect(detector.deadline == clock.addingTimeInterval(3))
    }

    @Test func ignoringMidWaitCancelsTheTimer() {
        detector.start()
        source.emit([zoomOnUSBMic])
        #expect(detector.deadline != nil)
        config.ignored = ["us.zoom.xos"]
        detector.configDidChange()
        #expect(detector.deadline == nil)
        fireTimer()
        #expect(prompts.isEmpty)
    }

    @Test func heldPromptShowsAfterPanelCloses() {
        detector.start()
        promptVisible = true
        source.emit([zoomOnUSBMic])
        #expect(detector.deadline == nil) // held
        advance(5)
        promptVisible = false
        detector.reevaluate()
        #expect(prompts == ["zoom"])
    }

    // MARK: Meeting end (while recording)

    private let teamsCall = ProcessIdentity(pid: 800, bundleID: "com.microsoft.teams2.modulehost", appBundleID: nil)
    private let quillItself = ProcessIdentity(pid: getpid(), bundleID: nil, appBundleID: nil)

    @Test func endPromptAfterGraceWhileRecording() {
        detector.start()
        source.emit([teamsCall])
        fireTimer()
        #expect(prompts == ["teams"])
        detector.setRecording(true)
        #expect(source.isWatching) // listeners stay while recording
        source.emit([teamsCall, quillItself])
        runTimers(until: clock.addingTimeInterval(20))
        source.emit([quillItself]) // hung up
        #expect(detector.deadline == clock.addingTimeInterval(MeetingEndMachine.grace))
        fireTimer()
        #expect(endPrompts == ["teams"])
        #expect(detector.deadline == nil)
        #expect(prompts == ["teams"]) // no start prompt while recording
    }

    @Test func resumeWithinGraceCancelsTheTimer() {
        detector.start()
        detector.setRecording(true)
        source.emit([teamsCall])
        runTimers(until: clock.addingTimeInterval(5))
        source.emit([])
        advance(10)
        source.emit([teamsCall])
        #expect(detector.deadline == clock.addingTimeInterval(3)) // threshold only, no grace
        fireTimer()
        #expect(detector.deadline == nil)
        advance(60)
        #expect(endPrompts.isEmpty)
    }

    @Test func recordingStartedFromMenuWatchesTheRunningCall() {
        detector.start()
        source.emit([zoomOnUSBMic])
        fireTimer() // prompt ignored; the user records from the menu later
        advance(120)
        detector.setRecording(true)
        runTimers(until: clock.addingTimeInterval(5)) // still in the call past its threshold
        source.emit([])
        fireTimer()
        #expect(endPrompts == ["zoom"])
    }

    /// Run every timer (threshold/grace and recording rescan) in time order
    /// until `limit`, with no Core Audio event in between.
    private func runTimers(until limit: Date) {
        while true {
            let next = [detector.deadline, detector.rescanDeadline].compactMap { $0 }.min()
            guard let next, next <= limit else { break }
            clock = max(clock, next)
            if detector.rescanDeadline == next { detector.rescanTimerFired() } else { detector.timerFired() }
        }
        clock = max(clock, limit)
    }

    /// Live repro (commit 10933dd): Teams in a call before the recording,
    /// "Grabar" clicked, then Core Audio stays silent: Teams keeps playing
    /// audio, so releasing the input changes only its `IsRunningInput`,
    /// which Core Audio does not notify, and quill's own capture keeps the
    /// input device running. The hang-up at +60 s is visible to a scan only.
    @Test func hangUpWithoutACoreAudioEventStillPrompts() {
        detector.start()
        source.emit([teamsCall])
        fireTimer()
        #expect(prompts == ["teams"])
        advance(4) // the user reads the panel, clicks Grabar
        let recordingStart = clock
        detector.setRecording(true)
        source.emit([teamsCall, quillItself]) // quill opened the mic
        runTimers(until: recordingStart.addingTimeInterval(60))
        source.current = [quillItself] // hung up: no event
        runTimers(until: recordingStart.addingTimeInterval(60 + MeetingEndMachine.grace
            + MeetingDetector.recordingRescanInterval))
        #expect(endPrompts == ["teams"])
        #expect(detector.rescanDeadline == nil) // nothing captures: no more rescans
    }

    /// Same, with the recording started from the menu long after the call
    /// began (start prompt ignored) and no scan at all after the start.
    @Test func menuRecordingOfARunningCallPromptsWithoutACoreAudioEvent() {
        detector.start()
        source.emit([teamsCall])
        fireTimer() // ignored
        advance(300)
        let recordingStart = clock
        detector.setRecording(true)
        runTimers(until: recordingStart.addingTimeInterval(60))
        source.current = []
        runTimers(until: recordingStart.addingTimeInterval(60 + MeetingEndMachine.grace
            + MeetingDetector.recordingRescanInterval))
        #expect(endPrompts == ["teams"])
    }

    @Test func rescansOnlyWhileRecordingAndAMeetingAppCaptures() {
        detector.start()
        source.emit([teamsCall])
        #expect(detector.rescanDeadline == nil) // not recording: events only
        fireTimer()
        detector.setRecording(true)
        #expect(detector.rescanDeadline == clock.addingTimeInterval(MeetingDetector.recordingRescanInterval))
        let starts = source.starts
        runTimers(until: clock.addingTimeInterval(12))
        #expect(source.starts == starts + 3) // the threshold's scan, then one per interval
        source.emit([quillItself]) // released: the grace timer takes over
        #expect(detector.rescanDeadline == nil)
        detector.setRecording(false)
        #expect(detector.rescanDeadline == nil)
    }

    @Test func briefCaptureWhileRecordingStillNeverPrompts() {
        detector.start()
        detector.setRecording(true)
        source.emit([teamsCall])
        advance(1) // a mic probe, under the threshold
        source.current = [] // no event
        runTimers(until: clock.addingTimeInterval(120))
        #expect(endPrompts.isEmpty)
    }

    @Test func endTrackingLogsTransitionsOnly() {
        let teams = MeetingApp.resolve(teamsCall)!
        typealias S = MeetingEndMachine.Status
        let grace = S.grace(elapsed: 0, grace: 15)
        #expect(MeetingDetector.endTransition(from: .notWatching, to: .capturing(["teams"]), released: nil)
            == "meeting end: watching teams")
        #expect(MeetingDetector.endTransition(from: .capturing(["teams"]), to: .capturing(["teams"]), released: nil) == nil)
        #expect(MeetingDetector.endTransition(from: .capturing(["teams"]), to: grace, released: teams)
            == "meeting end: teams released, grace 15 s")
        #expect(MeetingDetector.endTransition(from: grace, to: .grace(elapsed: 5, grace: 15), released: teams) == nil)
        #expect(MeetingDetector.endTransition(from: grace, to: .capturing(["teams"]), released: teams)
            == "meeting end: grace cancelled (teams resumed)")
    }

    @Test func keepRecordingWaitsForANewCaptureAndRelease() {
        detector.start()
        detector.setRecording(true)
        source.emit([teamsCall])
        runTimers(until: clock.addingTimeInterval(5))
        source.emit([])
        fireTimer()
        #expect(endPrompts == ["teams"])
        promptVisible = false
        detector.endPromptDismissed()
        #expect(detector.deadline == nil)
        advance(300)
        detector.timerFired()
        #expect(endPrompts == ["teams"])
        source.emit([teamsCall])
        runTimers(until: clock.addingTimeInterval(5))
        source.emit([])
        fireTimer()
        #expect(endPrompts == ["teams", "teams"])
    }

    @Test func stoppingTheRecordingClearsEndState() {
        detector.start()
        detector.setRecording(true)
        source.emit([teamsCall])
        runTimers(until: clock.addingTimeInterval(5))
        source.emit([])
        #expect(detector.deadline != nil)
        detector.setRecording(false) // stopped from the menu
        #expect(detector.deadline == nil)
        advance(60)
        detector.timerFired()
        #expect(endPrompts.isEmpty)
        #expect(prompts.isEmpty) // the start machine stayed quiet through the resync
        // Next recording starts from scratch: nothing captured → nothing watched.
        detector.setRecording(true)
        advance(60)
        detector.timerFired()
        #expect(endPrompts.isEmpty && detector.deadline == nil)
    }

    @Test func promptOnEndOffStopsWatchingWhileRecording() {
        config.promptOnEnd = false
        detector.start()
        source.emit([teamsCall])
        detector.setRecording(true)
        #expect(!source.isWatching)
        // Turned on mid-recording: the running call is watched from now.
        config.promptOnEnd = true
        detector.configDidChange()
        #expect(source.isWatching)
        runTimers(until: clock.addingTimeInterval(5))
        source.emit([])
        fireTimer()
        #expect(endPrompts == ["teams"])
        // Off again: pending state dropped, no prompt.
        source.emit([teamsCall])
        runTimers(until: clock.addingTimeInterval(5))
        source.emit([])
        config.promptOnEnd = false
        detector.configDidChange()
        #expect(!source.isWatching && detector.deadline == nil)
    }

    /// Recording, Teams in a call for 5 s, then hung up and the end panel
    /// shown (visible from now on).
    private func showEndPanel() {
        detector.start()
        detector.setRecording(true)
        source.emit([teamsCall])
        runTimers(until: clock.addingTimeInterval(5))
        source.emit([])
        fireTimer()
        #expect(endPrompts == ["teams"])
        promptVisible = true
    }

    @Test func resumedCallWithdrawsTheEndPanel() {
        showEndPanel()
        source.emit([teamsCall])
        advance(1)
        detector.timerFired() // 1 s: a blip does not close it
        #expect(withdrawals == 0)
        fireTimer() // threshold reached with no new event
        #expect(withdrawals == 1)
        promptVisible = false // the controller closed it
        advance(30)
        source.emit([])
        fireTimer()
        #expect(endPrompts == ["teams", "teams"]) // the new release asks again
    }

    @Test func turningTheFeatureOffWithdrawsTheEndPanel() {
        showEndPanel()
        config.promptOnEnd = false
        detector.configDidChange()
        #expect(withdrawals == 1)
    }

    @Test func ignoringTheAppWithdrawsTheEndPanel() {
        showEndPanel()
        config.ignored = ["teams"]
        detector.configDidChange()
        #expect(withdrawals == 1)
    }

    @Test func keepRecordingAfterTheCallResumedAndEndedWhileHeld() {
        showEndPanel()
        // Panel still up (e.g. the controller has not closed it yet): the
        // call resumes past its threshold and ends again; the prompt is held.
        source.emit([teamsCall])
        runTimers(until: clock.addingTimeInterval(5))
        source.emit([])
        advance(30)
        detector.timerFired()
        #expect(endPrompts == ["teams"] && detector.deadline == nil)
        // "Seguir grabando" (as `showEnd` runs it): the panel closes, the
        // answer lands, then the async re-evaluation from `onDismiss`.
        promptVisible = false
        detector.endPromptDismissed()
        detector.reevaluate()
        #expect(endPrompts == ["teams", "teams"]) // asks once for the new release
    }

    @Test func noEndPromptAtWakeBeforeAFreshScan() {
        detector.start()
        detector.setRecording(true)
        source.emit([teamsCall])
        runTimers(until: clock.addingTimeInterval(5))
        source.emit([]) // lid closed: input stopped, grace starts
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(detector.deadline == nil)
        advance(3600)
        source.current = [teamsCall] // the call is back, not yet reported
        let starts = source.starts
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(source.starts == starts + 1) // asked for a fresh scan
        #expect(endPrompts.isEmpty)
        // The call really ended: the grace restarts from wake.
        source.emit([])
        #expect(detector.deadline == clock.addingTimeInterval(MeetingEndMachine.grace))
    }

    @Test func wakeWaitsForTheScanBeforeEvaluating() {
        let source = GatedSource()
        let detector = MeetingDetector(
            source: source, loadConfig: { MeetingDetectionConfig() },
            now: { [unowned self] in self.clock }, notifications: center, workspaceNotifications: workspace)
        var ended = 0
        detector.onEndPrompt = { _ in ended += 1 }
        detector.start()
        detector.setRecording(true)
        source.deliver([teamsCall])
        advance(5)
        source.deliver([])
        detector.systemWillSleep()
        advance(3600)
        detector.systemDidWake()
        detector.timerFired()
        detector.reevaluate()
        #expect(ended == 0 && detector.deadline == nil) // scan still pending
        source.deliver([teamsCall]) // the call is live
        advance(60)
        detector.timerFired()
        #expect(ended == 0)
    }

    @Test func malformedConfigUsesDefaults() {
        let values = ConfigValues(raw: ["meeting_detection": ["enabled": false, "ignored_apps": "zoom"] as [String: Any]])
        let snapshot = MeetingDetectionConfig(values)
        #expect(snapshot.formatError == "meeting_detection.ignored_apps")
        #expect(snapshot.enabled && snapshot.ignored.isEmpty)
        config = snapshot
        detector.start()
        source.emit([zoomOnUSBMic])
        fireTimer()
        #expect(prompts == ["zoom"])
    }
}

@Suite struct MeetingConfigFormatTests {
    @Test func detectsMalformedShapes() {
        #expect(ConfigValues(raw: [:]).meetingDetectionFormatError == nil)
        #expect(ConfigValues(raw: ["meeting_detection": "on"]).meetingDetectionFormatError == "meeting_detection")
        #expect(ConfigValues(raw: ["meeting_detection": ["ignored_apps": "whatsapp"]])
            .meetingDetectionFormatError == "meeting_detection.ignored_apps")
        #expect(ConfigValues(raw: ["meeting_detection": ["enabled": "yes"]])
            .meetingDetectionFormatError == "meeting_detection.enabled")
        #expect(ConfigValues(raw: ["meeting_detection": ["enabled": false, "ignored_apps": [] as [Any]] as [String: Any]])
            .meetingDetectionFormatError == nil)
    }

    @Test func jsonNumberIsNotABool() throws {
        let raw = try JSONSerialization.jsonObject(with: Data(#"{"meeting_detection": {"enabled": 1}}"#.utf8))
        #expect(ConfigValues(raw: raw as? [String: Any] ?? [:]).meetingDetectionFormatError == "meeting_detection.enabled")
        let ok = try JSONSerialization.jsonObject(with: Data(#"{"meeting_detection": {"enabled": true}}"#.utf8))
        #expect(ConfigValues(raw: ok as? [String: Any] ?? [:]).meetingDetectionFormatError == nil)
    }
}

// MARK: - Panel

// `RecordingPillPanelTests` (canBecomeKey, initialSelection, anchor geometry) lives in
// RecordingPillControllerTests.swift: the prompt panel became the recording pill.

// MARK: - Settings

@MainActor
@Suite final class MeetingSettingsTests {
    let root: URL
    let url: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-meeting-settings-\(UUID().uuidString)", isDirectory: true)
        url = root.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func checkboxesMapToIgnoredApps() throws {
        try Data(#"{"meeting_detection": {"ignored_apps": ["us.zoom.xos", "custom.app"]}}"#.utf8).write(to: url)
        let model = SettingsModel(configURL: url, templatesDir: root, keychain: NoKey())
        #expect(!model.isDetected(.zoom))
        #expect(model.isDetected(.teams))

        model.setDetected(.whatsApp, false)
        model.setDetected(.zoom, true)
        #expect(model.ignoredApps == ["custom.app", "whatsapp"])
        #expect(model.isDetected(.zoom))
        #expect(!model.isDetected(.whatsApp))

        #expect(model.meetingPromptOnEnd)
        model.meetingPromptOnEnd = false
        model.meetingDetectionEnabled = false
        let values = ConfigValues(raw: try ConfigStore.loadRaw(at: url))
        #expect(values.meetingDetectionPromptOnEnd == false)
        #expect(values.meetingDetectionEnabled == false)
        #expect(values.meetingDetectionIgnoredApps == ["custom.app", "whatsapp"])
    }

    @Test func malformedSectionIsNeverOverwritten() throws {
        let original = #"{"meeting_detection": {"enabled": true, "ignored_apps": "whatsapp"}}"#
        try Data(original.utf8).write(to: url)
        let model = SettingsModel(configURL: url, templatesDir: root, keychain: NoKey())
        #expect(model.meetingDetectionInvalid)
        #expect(model.configError?.contains("meeting_detection.ignored_apps") == true)

        model.setDetected(.zoom, false)
        model.meetingDetectionEnabled = false
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == original)
        #expect(model.meetingDetectionEnabled) // reverted to what is on disk
        #expect(model.configError?.contains("meeting_detection.ignored_apps") == true)
    }

    @Test func writesNotifyConfigChange() throws {
        try Data("{}".utf8).write(to: url)
        let model = SettingsModel(configURL: url, templatesDir: root, keychain: NoKey())
        let posted = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: .meetingVoxConfigDidChange, object: nil, queue: nil) { _ in posted.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        model.setDetected(.whatsApp, false)
        #expect(posted.value >= 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private struct NoKey: APIKeyStore {
    func hasAPIKey() -> Bool { false }
    func read() throws -> String? { nil }
    func save(_ secret: String) throws {}
    func delete() throws {}
}
