import AppKit
import Foundation
import Testing
@testable import MeetingVox

// MARK: - Fakes

@MainActor
final class FakePillPresenter: PillPresenting {
    private(set) var shows = 0
    private(set) var hides = 0
    private(set) var isShown = false
    func show(_ model: PillViewModel) { shows += 1; isShown = true }
    func hide() { hides += 1; isShown = false }
}

/// Timers fire only when the test says so.
@MainActor
final class FakePillScheduler: PillScheduling {
    final class Entry {
        let interval: TimeInterval
        let repeats: Bool
        let action: @MainActor () -> Void
        var cancelled = false
        init(interval: TimeInterval, repeats: Bool, action: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.repeats = repeats
            self.action = action
        }
    }

    private(set) var entries: [Entry] = []

    func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PillCancel {
        let entry = Entry(interval: interval, repeats: true, action: action)
        entries.append(entry)
        return { entry.cancelled = true }
    }

    func once(after interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PillCancel {
        let entry = Entry(interval: interval, repeats: false, action: action)
        entries.append(entry)
        return { entry.cancelled = true }
    }

    var activeRepeating: [Entry] { entries.filter { $0.repeats && !$0.cancelled } }
    var activeOnce: [Entry] { entries.filter { !$0.repeats && !$0.cancelled } }

    func tick() { for entry in activeRepeating { entry.action() } }

    func fireOnce() {
        for entry in activeOnce {
            entry.cancelled = true
            entry.action()
        }
    }
}

@MainActor
private final class PillRig {
    let presenter = FakePillPresenter()
    let scheduler = FakePillScheduler()
    let center = NotificationCenter()
    var uptime: TimeInterval = 1_000
    var wall = Date(timeIntervalSince1970: 1_800_000_000)
    var levels = LevelSnapshot(mic: .sample(nil), system: .sample(nil))
    private(set) var levelReads = 0
    var dismissals = 0
    var autoStops = 0
    var stops = 0
    var chosenTemplates: [String] = []
    var soundInputOpens = 0
    var settings = (pillEnabled: true, autoStop: true)
    var logs: [String] = []
    let controller: RecordingPillController

    init(pillEnabled: Bool = true) {
        let presenter = presenter, scheduler = scheduler
        var rigUptime: () -> TimeInterval = { 0 }
        var rigNow: () -> Date = { Date() }
        controller = RecordingPillController(
            presenter: presenter, scheduler: scheduler, pillEnabled: pillEnabled,
            uptime: { rigUptime() }, now: { rigNow() }, log: { _ in })
        rigUptime = { [unowned self] in self.uptime }
        rigNow = { [unowned self] in self.wall }
        controller.onDismiss = { [unowned self] in self.dismissals += 1 }
        controller.onAutoStop = { [unowned self] in self.autoStops += 1 }
        controller.startObservingWake(center: center)
        controller.startObservingConfig(center: center) { [unowned self] in self.settings }
    }

    var recording: PillRecording {
        PillRecording(
            startedAt: wall, templates: nil, selectedTemplate: nil, pillEnabled: settings.pillEnabled,
            levels: { [unowned self] in
                self.levelReads += 1
                return self.levels
            },
            onTemplate: { [unowned self] in self.chosenTemplates.append($0) },
            onStop: { [unowned self] in self.stops += 1 },
            openSoundInput: { [unowned self] in self.soundInputOpens += 1 })
    }

    func startRecording() {
        controller.prepareForRecording()
        controller.recordingStarted(recording)
    }

    /// The observers use `queue: .main`, which delivers on a later main-queue turn.
    func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func configChanged() async {
        center.post(name: .meetingVoxConfigDidChange, object: nil)
        await drain()
    }

    func wake() async {
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drain()
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

private let general = MinutesTemplate(id: "general", nombre: "General", descripcion: "", cuerpo: "")
private let other = MinutesTemplate(id: "otra", nombre: "Otra", descripcion: "", cuerpo: "")

// MARK: - Controller

@MainActor
@Suite struct RecordingPillControllerTests {
    // MARK: Prompts

    @Test func detectedPromptShowsTheWindowAndIgnoreClosesItOnce() {
        let rig = PillRig()
        var ignored = 0
        rig.controller.show(
            label: "Reunión Teams", templates: nil, defaultTemplate: "general",
            onRecord: { _ in }, onIgnore: { ignored += 1 })
        #expect(rig.presenter.isShown)
        #expect(rig.controller.isPromptVisible)
        #expect(rig.controller.promptKind == .start)
        #expect(rig.controller.model.face == .detected("Reunión Teams"))
        rig.controller.model.onIgnore()
        #expect(ignored == 1)
        #expect(rig.dismissals == 1)
        #expect(!rig.presenter.isShown)
        #expect(!rig.controller.isPromptVisible)
        #expect(rig.controller.promptKind == nil)
    }

    @Test func onDismissFiresOncePerPromptCloseAndNeverWithoutOne() {
        let rig = PillRig()
        rig.controller.dismiss() // nothing up
        #expect(rig.dismissals == 0)
        rig.controller.show(
            label: "Zoom", templates: nil, defaultTemplate: "general", onRecord: { _ in }, onIgnore: {})
        rig.controller.dismiss()
        rig.controller.dismiss()
        #expect(rig.dismissals == 1)
        rig.startRecording()
        rig.controller.model.onHide() // hide is not a prompt close
        #expect(rig.dismissals == 1)
    }

    @Test func detectedPromptTimesOutAfterSixtySeconds() {
        let rig = PillRig()
        rig.controller.show(
            label: "Teams", templates: nil, defaultTemplate: "general", onRecord: { _ in }, onIgnore: {})
        #expect(rig.scheduler.activeOnce.map(\.interval) == [60])
        rig.scheduler.fireOnce()
        #expect(!rig.presenter.isShown)
        #expect(!rig.controller.isPromptVisible)
        #expect(rig.dismissals == 1)
    }

    @Test func recordPassesTheChosenTemplateAndTheWindowBecomesTheRecordingPill() {
        let rig = PillRig()
        var chosen: [String?] = []
        rig.controller.show(
            label: "Teams", templates: [other, general], defaultTemplate: "otra",
            onRecord: { id in
                chosen.append(id)
                rig.startRecording() // what AppController.startSession does
            },
            onIgnore: {})
        #expect(rig.controller.model.selection == "otra")
        rig.controller.model.selection = "general"
        rig.controller.model.onRecord(rig.controller.model.selection)
        #expect(chosen == ["general"])
        #expect(rig.dismissals == 1) // prepareForRecording closed the prompt, once
        #expect(rig.presenter.hides == 0) // same window, no flicker
        #expect(rig.presenter.isShown)
        #expect(rig.controller.model.face == .recording)
        #expect(!rig.controller.isPromptVisible)
    }

    @Test func recordRefusedByTheOwnerClosesThePromptTheNormalWay() {
        let rig = PillRig()
        rig.controller.show(
            label: "Teams", templates: nil, defaultTemplate: "general",
            onRecord: { _ in /* session != nil: refused */ }, onIgnore: {})
        rig.controller.model.onRecord(nil)
        #expect(!rig.controller.isPromptVisible)
        #expect(!rig.presenter.isShown)
        #expect(rig.dismissals == 1)
    }

    @Test func prepareForRecordingClosesTheDetectedPromptWithoutTouchingTheWindow() {
        let rig = PillRig()
        rig.controller.show(
            label: "Teams", templates: nil, defaultTemplate: "general", onRecord: { _ in }, onIgnore: {})
        let hides = rig.presenter.hides, shows = rig.presenter.shows
        rig.controller.prepareForRecording()
        #expect(!rig.controller.isPromptVisible)
        #expect(rig.dismissals == 1)
        #expect(rig.presenter.hides == hides && rig.presenter.shows == shows)
        #expect(rig.presenter.isShown) // morphs on recordingStarted
    }

    @Test func prepareForRecordingWithNoPromptFiresNothing() {
        let rig = PillRig()
        rig.controller.prepareForRecording()
        #expect(rig.dismissals == 0)
    }

    @Test func recordingFailedOrdersTheWindowOut() {
        let rig = PillRig()
        rig.controller.show(
            label: "Teams", templates: nil, defaultTemplate: "general", onRecord: { _ in }, onIgnore: {})
        rig.controller.prepareForRecording()
        rig.controller.recordingFailed()
        #expect(!rig.presenter.isShown)
        #expect(rig.controller.model.face == .hidden)
    }

    // MARK: Recording face

    @Test func recordingFaceShowsAndStopRunsTheOwnersPath() {
        let rig = PillRig()
        rig.startRecording()
        #expect(rig.presenter.isShown)
        #expect(rig.controller.model.face == .recording)
        #expect(!rig.controller.isPromptVisible) // a recording pill is not a prompt
        rig.controller.model.onStop()
        #expect(rig.stops == 1)
        rig.controller.recordingStopped()
        #expect(!rig.presenter.isShown)
        #expect(rig.scheduler.activeRepeating.isEmpty)
    }

    @Test func pillDisabledNeverShowsTheRecordingFace() {
        let rig = PillRig(pillEnabled: false)
        rig.settings.pillEnabled = false
        rig.startRecording()
        #expect(!rig.presenter.isShown)
        #expect(rig.scheduler.activeRepeating.isEmpty)
        // A prompt still shows (pill style) and the end prompt rides on the recording.
        rig.controller.showEnd(title: "fin", autoStop: false, onStop: {}, onContinue: {})
        #expect(rig.presenter.isShown)
        rig.controller.model.onContinue()
        #expect(!rig.presenter.isShown)
    }

    @Test func elapsedAndTemplateAreShown() {
        let rig = PillRig()
        var recording = rig.recording
        recording.templates = [general, other]
        recording.selectedTemplate = "otra"
        rig.controller.prepareForRecording()
        rig.controller.recordingStarted(recording)
        #expect(rig.controller.model.templates == [general, other])
        #expect(rig.controller.model.selection == "otra")
        rig.wall = rig.wall.addingTimeInterval(65)
        rig.scheduler.tick()
        #expect(rig.controller.model.elapsed == "1:05")
        rig.controller.model.select("general")
        #expect(rig.chosenTemplates == ["general"])
        rig.controller.setTemplate("otra") // the menu's choice: no echo to the owner
        #expect(rig.controller.model.selection == "otra")
        #expect(rig.chosenTemplates == ["general"])
    }

    @Test func changeMicrophoneOpensSoundInput() {
        let rig = PillRig()
        rig.startRecording()
        rig.controller.model.onChangeMic()
        #expect(rig.soundInputOpens == 1)
    }

    // MARK: Ticker and meters

    @Test func tickerRunsOnlyWhileTheRecordingPillIsVisible() {
        let rig = PillRig()
        #expect(rig.scheduler.activeRepeating.isEmpty)
        rig.startRecording()
        #expect(rig.scheduler.activeRepeating.map(\.interval) == [0.1])
        rig.controller.model.onHide()
        #expect(rig.scheduler.activeRepeating.isEmpty)
        #expect(!rig.presenter.isShown)
        rig.controller.micSignal(.silent) // resurfaces
        #expect(rig.presenter.isShown)
        #expect(rig.scheduler.activeRepeating.count == 1)
        rig.controller.recordingStopped()
        #expect(rig.scheduler.activeRepeating.isEmpty)
    }

    @Test func hiddenPillNeverReadsTheMeters() {
        let rig = PillRig()
        rig.startRecording()
        rig.scheduler.tick()
        rig.controller.model.onHide()
        let reads = rig.levelReads
        rig.scheduler.tick() // no timer: nothing fires
        #expect(rig.levelReads == reads)
    }

    @Test func anUnchangedTickNeverNotifiesTheView() {
        let rig = PillRig()
        rig.startRecording()
        rig.scheduler.tick()
        rig.scheduler.tick() // meters now sampling; clock and levels unchanged below
        let model = rig.controller.model
        let changes = ChangeCounter()
        withObservationTracking {
            _ = model.elapsed
            _ = model.mic
            _ = model.system
        } onChange: { changes.bump() }
        rig.scheduler.tick()
        #expect(changes.value == 0)
        rig.wall = rig.wall.addingTimeInterval(1)
        rig.scheduler.tick()
        #expect(changes.value == 1)
    }

    @Test func firstSampleAfterBecomingVisibleIsDiscarded() {
        let rig = PillRig()
        rig.startRecording()
        rig.levels = LevelSnapshot(mic: .sample(0.5), system: .sample(0.5))
        rig.scheduler.tick() // the discarded read(s) may already have happened at start
        rig.scheduler.tick()
        guard case .level(let value) = rig.controller.model.mic else {
            Issue.record("expected a level, got \(rig.controller.model.mic)")
            return
        }
        #expect(value > 0.85 && value < 0.95) // -6 dBFS ≈ 0.90
        // Re-showing discards again: stale peaks from the hidden time never show.
        rig.controller.model.onHide()
        rig.levels = LevelSnapshot(mic: .sample(1), system: .sample(1))
        rig.controller.micSignal(.silent)
        #expect(rig.controller.model.mic == .level(0))
    }

    @Test func metersShowDashForUnavailableAndSilenceIsAnEmptyBar() {
        let rig = PillRig()
        rig.startRecording()
        rig.levels = LevelSnapshot(mic: .sample(0), system: .unavailable)
        rig.scheduler.tick()
        rig.scheduler.tick()
        #expect(rig.controller.model.mic == .level(0))
        #expect(rig.controller.model.system == .unavailable)
    }

    // MARK: Silent mic

    @Test func silentMicShowsTheFaceAndBackRestoresIt() {
        let rig = PillRig()
        rig.startRecording()
        rig.controller.micSignal(.silent)
        #expect(rig.controller.model.face == .silentMic)
        rig.controller.micSignal(.back)
        #expect(rig.controller.model.face == .recording)
    }

    @Test func silentMicDoesNotResurfaceWhenTheSettingIsOff() async {
        let rig = PillRig()
        rig.startRecording()
        rig.controller.model.onHide()
        rig.settings.pillEnabled = false
        await rig.configChanged()
        rig.controller.micSignal(.silent)
        #expect(!rig.presenter.isShown)
    }

    // MARK: Auto-stop

    @Test func endPromptStartsTheCountdownAndExpiryStopsExactlyOnce() {
        let rig = PillRig()
        rig.startRecording()
        var stopped = 0
        rig.controller.showEnd(title: "La reunión de Teams terminó", autoStop: true, onStop: { stopped += 1 }, onContinue: {})
        #expect(rig.controller.model.face == .ended("La reunión de Teams terminó"))
        #expect(rig.controller.model.countdown == "0:45")
        rig.uptime += 20
        rig.scheduler.tick()
        #expect(rig.controller.model.countdown == "0:25")
        #expect(rig.autoStops == 0)
        rig.uptime += 25
        rig.scheduler.tick()
        rig.scheduler.tick()
        #expect(rig.autoStops == 1)
        #expect(stopped == 0) // the owner's onAutoStop owns the stop path
    }

    @Test func noCountdownWithoutAutoStop() {
        let rig = PillRig()
        rig.startRecording()
        rig.controller.showEnd(title: "fin", autoStop: false, onStop: {}, onContinue: {})
        #expect(rig.controller.model.countdown == nil)
        rig.uptime += 600
        rig.scheduler.tick()
        #expect(rig.autoStops == 0)
    }

    @Test func continueWithdrawnAndStoppedCancelTheCountdown() {
        // Seguir grabando
        var rig = PillRig()
        rig.startRecording()
        rig.controller.showEnd(title: "fin", autoStop: true, onStop: {}, onContinue: {})
        rig.controller.model.onContinue()
        #expect(rig.controller.model.countdown == nil)
        rig.uptime += 100
        rig.scheduler.tick()
        #expect(rig.autoStops == 0)
        #expect(rig.controller.model.face == .recording)
        // Withdrawn by the detector
        rig = PillRig()
        rig.startRecording()
        rig.controller.showEnd(title: "fin", autoStop: true, onStop: {}, onContinue: {})
        rig.controller.dismiss()
        rig.uptime += 100
        rig.scheduler.tick()
        #expect(rig.autoStops == 0)
        // Manual stop (Detener on the pill or the menu)
        rig = PillRig()
        rig.startRecording()
        rig.controller.showEnd(title: "fin", autoStop: true, onStop: {}, onContinue: {})
        rig.controller.recordingStopped()
        #expect(rig.dismissals == 1) // the ended prompt closed with the recording
        rig.uptime += 100
        rig.scheduler.tick()
        #expect(rig.autoStops == 0)
    }

    @Test func detenerOnTheEndPromptClosesItAndRunsTheOwnersStop() {
        let rig = PillRig()
        rig.startRecording()
        var stopped = 0
        rig.controller.showEnd(title: "fin", autoStop: true, onStop: { stopped += 1 }, onContinue: {})
        rig.controller.model.onStop()
        #expect(stopped == 1)
        #expect(!rig.controller.isPromptVisible)
        rig.uptime += 100
        rig.scheduler.tick()
        #expect(rig.autoStops == 0)
    }

    @Test func autoStopTurnedOffMidCountdownCancelsItAndNoStopFires() async {
        let rig = PillRig()
        rig.startRecording()
        rig.controller.showEnd(title: "fin", autoStop: true, onStop: {}, onContinue: {})
        rig.uptime += 10
        rig.scheduler.tick()
        #expect(rig.controller.model.countdown == "0:35")
        rig.settings.autoStop = false
        await rig.configChanged()
        #expect(rig.controller.model.countdown == nil) // "se detiene sola" gone
        #expect(rig.controller.model.face == .ended("fin")) // still needs a click
        rig.uptime += 100
        rig.scheduler.tick()
        #expect(rig.autoStops == 0)
    }

    @Test func autoStopTurnedOnMidPromptDoesNotStartACountdown() async {
        let rig = PillRig()
        rig.settings.autoStop = false
        rig.startRecording()
        rig.controller.showEnd(title: "fin", autoStop: false, onStop: {}, onContinue: {})
        rig.settings.autoStop = true
        await rig.configChanged()
        #expect(rig.controller.model.countdown == nil)
    }

    @Test func wakeRestartsTheCountdownFromTheFullDuration() async {
        let rig = PillRig()
        rig.startRecording()
        rig.controller.showEnd(title: "fin", autoStop: true, onStop: {}, onContinue: {})
        rig.uptime += 25
        rig.scheduler.tick()
        #expect(rig.controller.model.countdown == "0:20")
        await rig.wake()
        #expect(rig.controller.model.countdown == "0:45")
    }

    @Test func wakeWithNoCountdownDoesNothing() async {
        let rig = PillRig()
        rig.startRecording()
        await rig.wake()
        #expect(rig.controller.model.countdown == nil)
    }

    // MARK: Config toggle

    @Test func settingTheToggleShowsOrHidesTheRecordingPillWithoutTouchingTheRecording() async {
        let rig = PillRig()
        rig.startRecording()
        #expect(rig.presenter.isShown)
        rig.settings.pillEnabled = false
        await rig.configChanged()
        #expect(!rig.presenter.isShown)
        #expect(rig.scheduler.activeRepeating.isEmpty)
        rig.settings.pillEnabled = true
        await rig.configChanged()
        #expect(rig.presenter.isShown)
        #expect(rig.controller.model.face == .recording)
        #expect(rig.stops == 0)
    }

    @Test func endPromptKindAndWithdrawalByKind() {
        let rig = PillRig()
        rig.startRecording()
        rig.controller.showEnd(title: "fin", autoStop: false, onStop: {}, onContinue: {})
        #expect(rig.controller.promptKind == .end)
        #expect(rig.controller.isPromptVisible)
        rig.controller.dismiss()
        #expect(rig.controller.promptKind == nil)
        #expect(rig.presenter.isShown) // the recording pill stays
        #expect(rig.dismissals == 1)
    }
}

// MARK: - Panel

@MainActor
@Suite struct RecordingPillPanelTests {
    @Test func panelNeverTakesTheKeyboard() {
        let panel = PromptPanel(
            contentRect: .zero, styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: true)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @Test func initialSelectionPrefersConfiguredThenGeneral() {
        #expect(RecordingPillPanel.initialSelection(templates: [other, general], configured: "otra") == "otra")
        #expect(RecordingPillPanel.initialSelection(templates: [other, general], configured: "nada") == "general")
        #expect(RecordingPillPanel.initialSelection(templates: [other], configured: "nada") == "otra")
        #expect(RecordingPillPanel.initialSelection(templates: nil, configured: "otra") == nil)
    }

    @Test func topRightAnchorKeepsTheCornerWhenTheSizeChanges() {
        let anchor = CGPoint(x: 1000, y: 800)
        let small = RecordingPillPanel.origin(anchor: anchor, size: CGSize(width: 320, height: 60))
        let tall = RecordingPillPanel.origin(anchor: anchor, size: CGSize(width: 320, height: 120))
        #expect(small == CGPoint(x: 680, y: 740))
        #expect(tall == CGPoint(x: 680, y: 680))
    }

    @Test func defaultAnchorIsTheTopRightCornerOfTheVisibleFrameWithAMargin() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(RecordingPillPanel.defaultAnchor(in: frame) == CGPoint(x: 1428, y: 863))
    }

    @Test func aDraggedAnchorOffEveryScreenFallsBackToTheDefault() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(RecordingPillPanel.clamped(CGPoint(x: 5000, y: 5000), screens: [screen]) == CGPoint(x: 1428, y: 863))
        #expect(RecordingPillPanel.clamped(CGPoint(x: 700, y: 500), screens: [screen]) == CGPoint(x: 700, y: 500))
    }
}

// MARK: - Detector wiring (AppController-style)

@MainActor
private final class WiringSource: MeetingProcessSource {
    private var onUpdate: (@MainActor ([ProcessIdentity]) -> Void)?
    /// What Core Audio reports right now; delivered on every (re)start, like a fresh scan.
    private var current: [ProcessIdentity] = []
    func start(onUpdate: @escaping @MainActor ([ProcessIdentity]) -> Void) {
        self.onUpdate = onUpdate
        onUpdate(current)
    }
    func stop() { onUpdate = nil }
    func emit(_ processes: [ProcessIdentity]) {
        current = processes
        onUpdate?(processes)
    }
}

@MainActor
@Suite struct RecordingPillWiringTests {
    private let teams = ProcessIdentity(pid: 800, bundleID: "com.microsoft.teams2.modulehost", appBundleID: nil)

    @MainActor private struct Harness {
        let rig = PillRig()
        let source = WiringSource()
        let detector: MeetingDetector
        let box = ClockBox()

        init() {
            let box = box
            detector = MeetingDetector(
                source: source, loadConfig: { MeetingDetectionConfig() },
                now: { box.now }, notifications: NotificationCenter(), workspaceNotifications: NotificationCenter())
            rig.controller.connect(to: detector)
        }
    }

    @MainActor final class ClockBox {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func aRecordingPillOnScreenIsNotAPromptSoTheEndPromptCanEmit() {
        let h = Harness()
        var endPrompts: [String] = []
        h.detector.onEndPrompt = { endPrompts.append($0.app.id) }
        h.detector.start()
        // The start sequence of AppController.startSession.
        h.rig.controller.prepareForRecording()
        h.detector.setRecording(true)
        h.rig.controller.recordingStarted(h.rig.recording)
        #expect(h.rig.presenter.isShown)
        #expect(!h.detector.isPromptVisible())
        // Teams captures past its threshold during the recording, then hangs up.
        h.source.emit([teams])
        h.box.now = h.box.now.addingTimeInterval(5)
        h.detector.timerFired()
        h.source.emit([])
        h.box.now = h.box.now.addingTimeInterval(MeetingEndMachine.grace)
        h.detector.timerFired()
        #expect(endPrompts == ["teams"])
    }

    @Test func onDismissFiresOnceOnStartAndPromptStateIsNilWhenSetRecordingEvaluates() async {
        let h = Harness()
        h.detector.start()
        h.rig.controller.show(
            label: "Reunión Teams", templates: nil, defaultTemplate: "general", onRecord: { _ in }, onIgnore: {})
        #expect(h.detector.isPromptVisible())
        var seen: [Bool] = []
        let original = h.detector.isPromptVisible
        h.detector.isPromptVisible = {
            let value = original()
            seen.append(value)
            return value
        }
        h.rig.controller.prepareForRecording() // first line of startSession
        h.detector.setRecording(true) // `session = newSession`'s didSet
        h.rig.controller.recordingStarted(h.rig.recording)
        #expect(!seen.isEmpty)
        #expect(seen.allSatisfy { !$0 }) // the prompt state was already nil
        #expect(h.rig.dismissals == 1)
        await drainMainQueue() // the detector's re-evaluate hop must not blow up
        #expect(h.rig.dismissals == 1)
    }

    @Test func menuStartWithNoPromptFiresNoDismiss() async {
        let h = Harness()
        h.detector.start()
        h.rig.controller.prepareForRecording()
        h.detector.setRecording(true)
        h.rig.controller.recordingStarted(h.rig.recording)
        await drainMainQueue()
        #expect(h.rig.dismissals == 0)
    }

    @Test func onDismissReevaluatesTheDetectorAfterTheMainQueueTurns() async {
        let h = Harness()
        h.detector.start()
        h.source.emit([teams])
        h.rig.controller.show(
            label: "Teams", templates: nil, defaultTemplate: "general", onRecord: { _ in }, onIgnore: {})
        h.box.now = h.box.now.addingTimeInterval(10)
        h.rig.controller.dismiss()
        await drainMainQueue()
        #expect(h.rig.dismissals == 1)
    }
}

// MARK: - Start ordering guard

@Suite struct StartSessionOrderTests {
    /// `prepareForRecording()` must run before `session` is assigned: the
    /// assignment's `didSet` evaluates the detector, which reads the prompt state.
    @Test func startSessionClearsThePromptBeforeAnythingElse() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingVox/MeetingVoxCommand.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let marker = "private func startSession("
        let start = try #require(text.range(of: marker))
        // The method body only (it ends at the first 4-space-indented brace),
        // with `//` comment lines dropped so prose never satisfies a check.
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex
        let body = rest[..<end]
        let open = try #require(body.firstIndex(of: "{"))
        let afterOpen = body[body.index(after: open)...]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let first = afterOpen.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        #expect(first == "pill.prepareForRecording()")
        let prepare = try #require(afterOpen.range(of: "pill.prepareForRecording()"))
        let assign = try #require(afterOpen.range(of: "session = newSession"))
        #expect(prepare.lowerBound < assign.lowerBound)
        // The mic signal hook must be in place before the tracks start.
        let signal = try #require(afterOpen.range(of: "newSession.onMicSignal"))
        let begin = try #require(afterOpen.range(of: "try newSession.start()"))
        #expect(signal.lowerBound < begin.lowerBound)
        // The pill hears about the recording only once it exists, and about its
        // failure from the catch path.
        let started = try #require(afterOpen.range(of: "pill.recordingStarted("))
        #expect(assign.lowerBound < started.lowerBound)
        let caught = try #require(afterOpen.range(of: "catch {"))
        let failed = try #require(afterOpen.range(of: "pill.recordingFailed()"))
        #expect(caught.lowerBound < failed.lowerBound)
    }
}
