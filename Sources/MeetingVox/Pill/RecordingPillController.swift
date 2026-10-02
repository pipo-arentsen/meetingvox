import AppKit
import Foundation

/// Cancels a scheduled timer; calling it twice is harmless.
typealias PillCancel = @MainActor () -> Void

/// The pill window as the controller sees it. `show` orders the one persistent
/// window front (creating it on first use) and re-fits it to the model's face;
/// `hide` orders it out. Neither may activate the app or take key status.
@MainActor
protocol PillPresenting: AnyObject {
    func show(_ model: PillViewModel)
    func hide()
}

/// Timers behind a seam: the 10 Hz ticker and the detected prompt's timeout.
@MainActor
protocol PillScheduling: AnyObject {
    func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PillCancel
    func once(after interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PillCancel
}

/// `Timer` on `.common` modes, so a modal menu or panel run loop never stalls it.
@MainActor
final class TimerPillScheduler: PillScheduling {
    func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PillCancel {
        schedule(interval: interval, repeats: true, action)
    }

    func once(after interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PillCancel {
        schedule(interval: interval, repeats: false, action)
    }

    private func schedule(interval: TimeInterval, repeats: Bool, _ action: @escaping @MainActor () -> Void) -> PillCancel {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
            MainActor.assumeIsolated { action() }
        }
        // The 10 Hz ticker is cosmetic: let the system coalesce its wakeups.
        if repeats { timer.tolerance = 0.02 }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}

/// Everything the owner hands over when a recording starts: the controller
/// never reads `Config`, the Keychain or the recorder itself.
struct PillRecording {
    var startedAt: Date
    /// nil hides the picker (minutes disabled).
    var templates: [MinutesTemplate]?
    var selectedTemplate: String?
    var pillEnabled: Bool
    /// One swap-to-zero snapshot of both tracks; called by the ticker only.
    var levels: @MainActor () -> LevelSnapshot
    var onTemplate: @MainActor (String) -> Void
    var onStop: @MainActor () -> Void
    /// "Cambiar micrófono" (Sound > Input).
    var openSoundInput: @MainActor () -> Void
}

/// Owns the pill: the `PillState` reducer, the one persistent window, the 10 Hz
/// ticker (elapsed time, meters, auto-stop countdown) and the detected
/// prompt's 60 s timeout. It never records or stops on its own: buttons call
/// back into the owner, and the countdown ends in `onAutoStop`.
///
/// `isPromptVisible` is the prompt state, never window visibility: a recording
/// pill on screen must not make the detectors hold their prompts.
@MainActor
final class RecordingPillController {
    enum PromptKind: Equatable, Sendable {
        case start
        case end
    }

    static let promptTimeout: TimeInterval = 60
    static let tickInterval: TimeInterval = 0.1

    let model: PillViewModel

    /// A prompt (detected or ended) closed, whatever the reason: exactly once
    /// per prompt, never on hide, never when none was up. The owner uses it to
    /// let the detector re-evaluate held prompts.
    var onDismiss: (() -> Void)?
    /// The auto-stop countdown reached zero (once). The owner takes the same
    /// path as "Detener".
    var onAutoStop: (() -> Void)?

    private let presenter: PillPresenting
    private let scheduler: PillScheduling
    private let uptime: () -> TimeInterval
    private let now: () -> Date
    private let log: (String) -> Void

    private var state: PillState
    private var recording: PillRecording?
    private var countdown = AutoStopCountdown()
    private var micMeter = MeterReading()
    private var systemMeter = MeterReading()
    /// The first read after the meters become visible only drains the peaks
    /// written while hidden.
    private var isSampling = false
    private var windowShown = false

    private var tickCancel: PillCancel?
    private var timeoutCancel: PillCancel?
    private var onRecordHandler: ((String?) -> Void)?
    private var onIgnoreHandler: (() -> Void)?
    private var onEndStop: (() -> Void)?
    private var onEndContinue: (() -> Void)?
    private var wakeObserver: NSObjectProtocol?
    private var wakeCenter: NotificationCenter?
    private var configObserver: NSObjectProtocol?
    private var configCenter: NotificationCenter?

    init(
        presenter: PillPresenting,
        scheduler: PillScheduling,
        model: PillViewModel = PillViewModel(),
        pillEnabled: Bool = true,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        now: @escaping () -> Date = Date.init,
        log: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.presenter = presenter
        self.scheduler = scheduler
        self.model = model
        self.state = PillState(pillEnabled: pillEnabled)
        self.uptime = uptime
        self.now = now
        self.log = log
        model.onRecord = { [weak self] id in self?.recordTapped(id) }
        model.onIgnore = { [weak self] in self?.ignoreTapped() }
        model.onStop = { [weak self] in self?.stopTapped() }
        model.onContinue = { [weak self] in self?.continueTapped() }
        model.onHide = { [weak self] in self?.hideTapped() }
        model.onChangeMic = { [weak self] in self?.recording?.openSoundInput() }
    }

    // MARK: - State for the owner

    /// A prompt is up (never "a window is on screen").
    var isPromptVisible: Bool { state.isPromptVisible }

    var promptKind: PromptKind? {
        switch state.prompt {
        case .detected?: .start
        case .ended?: .end
        case nil: nil
        }
    }

    /// Hands the detector the prompt state and the re-evaluation hop. The hop
    /// is async on purpose: dismissal happens inside button handlers and
    /// `startSession`, and the detector must re-run once those have settled.
    func connect(to detector: MeetingDetector) {
        detector.isPromptVisible = { [weak self] in self?.isPromptVisible ?? false }
        let previous = onDismiss
        onDismiss = { [weak detector] in
            previous?()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { detector?.reevaluate() }
            }
        }
    }

    // MARK: - Prompts

    /// "Meeting detected — record?". Shown with the pill's style whatever the
    /// setting says; hides itself after `promptTimeout`; never records alone.
    /// - Parameters:
    ///   - templates: nil hides the picker (minutes disabled).
    ///   - onRecord: the chosen template id (nil without a picker). The owner's
    ///     start path clears this prompt through `prepareForRecording`.
    func show(
        label: String,
        templates: [MinutesTemplate]?,
        defaultTemplate: String,
        onRecord: @escaping (String?) -> Void,
        onIgnore: @escaping () -> Void
    ) {
        guard state.recording == nil else { return }
        closePrompt()
        onRecordHandler = onRecord
        onIgnoreHandler = onIgnore
        model.templates = templates
        model.selection = RecordingPillPanel.initialSelection(templates: templates, configured: defaultTemplate)
        model.onTemplateChanged = nil
        state.reduce(.promptDetected(label: label))
        render()
        timeoutCancel = scheduler.once(after: Self.promptTimeout) { [weak self] in
            guard let self, self.promptKind == .start else { return }
            self.log("meeting prompt timed out")
            self.closePrompt()
        }
    }

    /// "The meeting ended — stop?". No timeout. With `autoStop` a 45 s
    /// countdown starts and ends in `onAutoStop`.
    func showEnd(title: String, autoStop: Bool, onStop: @escaping () -> Void, onContinue: @escaping () -> Void) {
        closePrompt()
        onEndStop = onStop
        onEndContinue = onContinue
        state.reduce(.promptEnded(title: title))
        if autoStop {
            countdown.start(at: uptime())
            model.countdown = AutoStopCountdown.text(AutoStopCountdown.duration)
        } else {
            countdown.cancel()
            model.countdown = nil
        }
        render()
    }

    /// Closes whichever prompt is up (the recording face stays).
    func dismiss() {
        closePrompt()
    }

    // MARK: - Recording

    /// FIRST thing a recording start does, before the owner's session exists:
    /// the detector evaluates synchronously when `session` is assigned and
    /// reads `isPromptVisible`, so a detected prompt must already be gone. The
    /// window is NOT touched (`recordingStarted` morphs it: no flicker).
    func prepareForRecording() {
        guard case .detected? = state.prompt else { return }
        cancelTimeout()
        state.reduce(.promptClosed)
        onDismiss?()
    }

    func recordingStarted(_ recording: PillRecording) {
        self.recording = recording
        state.reduce(.recordingStarted(pillEnabled: recording.pillEnabled))
        countdown.cancel()
        model.countdown = nil
        model.templates = recording.templates
        model.selection = recording.selectedTemplate
        model.onTemplateChanged = { [weak self] id in self?.recording?.onTemplate(id) }
        model.elapsed = ElapsedText.format(0)
        resetMeters(keepSampling: false)
        render()
    }

    /// The start threw: nothing is recording and no prompt is left, so the
    /// window the prompt left up must go.
    func recordingFailed() {
        render()
    }

    func recordingStopped() {
        let hadEndPrompt = promptKind == .end
        state.reduce(.recordingStopped)
        recording = nil
        countdown.cancel()
        model.countdown = nil
        render()
        if hadEndPrompt { onDismiss?() }
    }

    /// The mic stopped delivering audio (`.silent`) or came back (`.back`).
    func micSignal(_ signal: MicSignal) {
        guard recording != nil else { return }
        state.reduce(signal == .silent ? .micSilent : .micBack)
        render()
    }

    /// The menu changed the session's template: reflect it without echoing.
    func setTemplate(_ id: String) {
        model.selection = id
    }

    // MARK: - Observers

    /// A wake restarts a running countdown from the full 45 s: the Mac was not
    /// really "waiting" meanwhile. `center` is the workspace's in the app.
    func startObservingWake(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        stopObservingWake()
        wakeCenter = center
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    func stopObservingWake() {
        if let wakeObserver { wakeCenter?.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// `recording_pill.enabled` and `meeting_detection.auto_stop`, re-read on
    /// every `meetingVoxConfigDidChange` (the owner reads the config; the
    /// controller never does). Turning auto-stop off cancels a running
    /// countdown; the prompt stays and still needs a click.
    func startObservingConfig(
        center: NotificationCenter = .default,
        read: @escaping @MainActor @Sendable () -> (pillEnabled: Bool, autoStop: Bool)
    ) {
        if let configObserver { configCenter?.removeObserver(configObserver) }
        configCenter = center
        configObserver = center.addObserver(forName: .meetingVoxConfigDidChange, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.configChanged(read()) }
        }
    }

    // MARK: - Button handlers

    private func recordTapped(_ id: String?) {
        guard promptKind == .start, let handler = onRecordHandler else { return }
        handler(id)
        // Started: `prepareForRecording` already closed the prompt. Refused
        // (a recording exists): it closes the normal way.
        if promptKind == .start { closePrompt() }
    }

    private func ignoreTapped() {
        guard promptKind == .start else { return }
        let handler = onIgnoreHandler
        closePrompt()
        handler?()
    }

    private func stopTapped() {
        if promptKind == .end {
            let handler = onEndStop
            closePrompt()
            handler?()
        } else {
            recording?.onStop()
        }
    }

    private func continueTapped() {
        guard promptKind == .end else { return }
        let handler = onEndContinue
        closePrompt()
        handler?()
    }

    private func hideTapped() {
        state.reduce(.hideTapped)
        render()
    }

    // MARK: - Internals

    private func closePrompt() {
        guard state.prompt != nil else { return }
        cancelTimeout()
        countdown.cancel()
        model.countdown = nil
        state.reduce(.promptClosed)
        render()
        onDismiss?()
    }

    private func cancelTimeout() {
        timeoutCancel?()
        timeoutCancel = nil
    }

    private func configChanged(_ values: (pillEnabled: Bool, autoStop: Bool)) {
        // Every Settings write posts this: only a real change of the pill
        // setting may touch the state (re-enabling clears a user's hide).
        if values.pillEnabled != state.pillEnabled { state.reduce(.settingChanged(values.pillEnabled)) }
        if !values.autoStop {
            countdown.cancel()
            model.countdown = nil
        }
        render()
    }

    private func didWake() {
        guard countdown.isRunning else { return }
        let t = uptime()
        countdown.restart(at: t)
        if let left = countdown.remaining(at: t) { model.countdown = AutoStopCountdown.text(left) }
    }

    private func render() {
        model.face = state.face
        if state.isVisible {
            presenter.show(model)
            windowShown = true
        } else if windowShown {
            presenter.hide()
            windowShown = false
        }
        syncTicker()
    }

    /// Runs only while the window is up during a recording: a hidden pill
    /// reads no meters and swaps no cells.
    private func syncTicker() {
        let shouldRun = state.isVisible && recording != nil
        if shouldRun, tickCancel == nil {
            isSampling = false
            tickCancel = scheduler.repeating(every: Self.tickInterval) { [weak self] in self?.tick() }
            tick()
        } else if !shouldRun, let cancel = tickCancel {
            cancel()
            tickCancel = nil
            isSampling = false
        }
    }

    /// Zeroes both meters. `keepSampling` is true when the caller has just
    /// drained a read and wants the next ones shown.
    private func resetMeters(keepSampling: Bool) {
        micMeter = MeterReading()
        systemMeter = MeterReading()
        assignIfChanged(\.mic, .level(0))
        assignIfChanged(\.system, .level(0))
        isSampling = keepSampling
    }

    /// `@Observable` notifies on every set, so an unchanged value would still
    /// redraw the pill ten times a second.
    private func assignIfChanged<V: Equatable>(_ keyPath: ReferenceWritableKeyPath<PillViewModel, V>, _ value: V) {
        if model[keyPath: keyPath] != value { model[keyPath: keyPath] = value }
    }

    private func tick() {
        guard let recording else { return }
        let t = uptime()
        assignIfChanged(\.elapsed, ElapsedText.format(now().timeIntervalSince(recording.startedAt)))
        switch state.face {
        case .recording, .silentMic:
            let snapshot = recording.levels()
            if isSampling {
                assignIfChanged(\.mic, micMeter.update(snapshot.mic, now: t))
                assignIfChanged(\.system, systemMeter.update(snapshot.system, now: t))
            } else {
                // First read since the meters became visible: drained, not shown.
                resetMeters(keepSampling: true)
            }
        default:
            isSampling = false
        }
        guard let left = countdown.remaining(at: t) else { return }
        model.countdown = AutoStopCountdown.text(left)
        if countdown.isExpired(at: t) {
            countdown.cancel()
            model.countdown = nil
            onAutoStop?()
        }
    }
}
