import AppKit
import Foundation

extension Notification.Name {
    /// Posted (main thread) after quill itself writes config.json, so
    /// long-lived snapshots such as the meeting detector's refresh.
    static let meetingVoxConfigDidChange = AppIdentity.notificationName("configDidChange")
}

/// Drives both machines from a `MeetingProcessSource` (Core Audio events).
/// No polling when idle: the process list is scanned when Core Audio reports
/// a change, and a one-shot timer runs only while something waits on the
/// clock (an app crossing its start threshold, or the end grace).
///
/// One exception, while recording: Core Audio does not notify changes of a
/// process's `IsRunningInput` (only `IsRunning`, i.e. any I/O), and quill's
/// own capture keeps the input device running, so a meeting app releasing
/// the input while it still plays audio produces no event. While a meeting
/// app captures during a recording, the detector rescans every
/// `recordingRescanInterval`.
///
/// - Not recording: `MeetingDetectionMachine` asks whether to record.
/// - Recording with `prompt_on_end` on: the same listeners stay attached
///   (still on the background queue) and `MeetingEndMachine` asks whether to
///   stop once the meeting apps release the input; what captures meanwhile
///   is marked handled for the start machine.
/// - Recording with `prompt_on_end` off: no listeners and no timer at all.
///
/// When the recording stops, one resync marks what is still active as
/// handled (the same call must not prompt afterwards).
///
/// Sleep/wake: nothing is evaluated while asleep; on wake the end machine's
/// clocks restart and nothing is evaluated until a fresh scan lands, so a
/// grace that ran out during sleep never prompts at wake.
///
/// Config is a snapshot: read at start, after every Settings write
/// (`meetingVoxConfigDidChange`) and after each recording. Hand edits to
/// config.json apply at those points.
@MainActor
final class MeetingDetector {
    /// A prompt (start or end kind) is up: holds further prompts of either
    /// machine without consuming them. Prompt state, never window visibility:
    /// the recording pill on screen is not a prompt.
    var isPromptVisible: () -> Bool = { false }
    var onPrompt: ((MeetingDetectionMachine.Prompt) -> Void)?
    /// Recording, and the meeting apps released the input for the grace.
    var onEndPrompt: ((MeetingEndMachine.Prompt) -> Void)?
    /// The end prompt on screen no longer applies: a meeting app captures
    /// again, the feature was turned off, or its app is now ignored. The
    /// owner closes an end prompt (never stops anything).
    var onEndPromptWithdrawn: (() -> Void)?

    /// Current snapshot (the panel reads the minutes fields from it).
    private(set) var config = MeetingDetectionConfig()
    /// When the threshold timer will fire (nil = no timer). For tests.
    private(set) var deadline: Date?
    /// When the recording rescan will run (nil = none). For tests.
    private(set) var rescanDeadline: Date?

    /// Rescan cadence while recording and a meeting app captures (see the
    /// type doc). Adds at most this much to the end grace.
    nonisolated static let recordingRescanInterval: TimeInterval = 5

    private let source: MeetingProcessSource
    private let loadConfig: () -> MeetingDetectionConfig
    private let now: () -> Date
    private let notifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter

    private var machine = MeetingDetectionMachine()
    /// Fresh per recording.
    private var endMachine = MeetingEndMachine()
    private var observations: [MeetingDetectionMachine.Observation] = []
    private var started = false
    private var watching = false
    private var recording = false
    /// The next update is the resync after a recording.
    private var resyncAfterRecording = false
    private var timer: Timer?
    private var rescanTimer: Timer?
    private var configObserver: NSObjectProtocol?
    private var powerObservers: [NSObjectProtocol] = []
    private var asleep = false
    /// Woke up: observations are stale until the next scan.
    private var awaitingWakeScan = false
    private var loggedFormatError: String?

    init(
        source: MeetingProcessSource? = nil,
        loadConfig: @escaping () -> MeetingDetectionConfig = { MeetingDetectionConfig(Config.values()) },
        now: @escaping () -> Date = Date.init,
        notifications: NotificationCenter = .default,
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.source = source ?? CoreAudioProcessSource()
        self.loadConfig = loadConfig
        self.now = now
        self.notifications = notifications
        self.workspaceNotifications = workspaceNotifications
    }

    func start() {
        guard !started else { return }
        started = true
        configObserver = notifications.addObserver(forName: .meetingVoxConfigDidChange, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.configDidChange() }
        }
        powerObservers = [
            workspaceNotifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.systemWillSleep() }
            },
            workspaceNotifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidWake() }
            },
        ]
        reloadConfig()
        updateWatching()
    }

    func stop() {
        guard started else { return }
        started = false
        if let configObserver { notifications.removeObserver(configObserver) }
        configObserver = nil
        for observer in powerObservers { workspaceNotifications.removeObserver(observer) }
        powerObservers = []
        asleep = false
        awaitingWakeScan = false
        updateWatching()
    }

    /// quill started or stopped recording.
    func setRecording(_ isRecording: Bool) {
        guard isRecording != recording else { return }
        recording = isRecording
        resetEndMachine()
        cancelTimer()
        cancelRescan()
        if !isRecording {
            reloadConfig()
            resyncAfterRecording = started && config.enabled
        }
        let wasWatching = watching
        updateWatching()
        guard wasWatching, watching else { return }
        if isRecording {
            // The listeners kept `observations` current: what captures right
            // now is watched (a call already running when the menu started
            // the recording counts).
            evaluate()
        } else {
            // Kept watching through the recording: the resync must see the
            // state right after it.
            requestFreshScan()
        }
    }

    /// "Seguir grabando": don't ask again until a meeting app captures input
    /// (for its threshold, possibly while the panel was up) and releases it.
    func endPromptDismissed() {
        if endMachine.outstanding != nil { Self.log("meeting end: dismissed") }
        endMachine.dismissed()
        reevaluate()
    }

    /// Settings changed config.json: refresh the snapshot and apply it now
    /// (turning detection on mid-call starts watching immediately).
    func configDidChange() {
        reloadConfig()
        let wasWatching = watching
        updateWatching()
        if wasWatching && watching { evaluate() }
    }

    /// Re-run the machine on the last observations (e.g. the panel closed,
    /// so a held prompt may show now).
    func reevaluate() {
        guard watching else { return }
        evaluate()
    }

    /// Nothing is evaluated while asleep.
    func systemWillSleep() {
        asleep = true
        cancelTimer()
        cancelRescan()
    }

    /// Restart the end machine's clocks and wait for a fresh scan before
    /// evaluating (the last observations predate the sleep).
    func systemDidWake() {
        guard asleep else { return }
        asleep = false
        endMachine.clockResumed(at: now())
        guard watching else { return }
        awaitingWakeScan = true
        requestFreshScan()
    }

    nonisolated static func observations(_ processes: [ProcessIdentity]) -> [MeetingDetectionMachine.Observation] {
        processes.compactMap { identity in
            MeetingApp.resolve(identity).map { .init(pid: identity.pid, app: $0) }
        }
    }

    // MARK: - Internals

    /// The end machine runs (recording, detection and `prompt_on_end` on).
    private var tracksMeetingEnd: Bool { started && recording && config.enabled && config.promptOnEnd }

    /// Fresh end machine; an outstanding end prompt is withdrawn.
    private func resetEndMachine() {
        let hadPrompt = endMachine.outstanding != nil
        endMachine = MeetingEndMachine()
        if hadPrompt {
            Self.log("meeting end: withdrawn")
            onEndPromptWithdrawn?()
        }
    }

    /// The source is already started: this only triggers a rescan.
    private func requestFreshScan() {
        source.start { [weak self] processes in self?.update(processes) }
    }

    private func updateWatching() {
        let shouldWatch = started && config.enabled && (!recording || config.promptOnEnd)
        if !tracksMeetingEnd { resetEndMachine() }
        if shouldWatch, !watching {
            watching = true
            source.start { [weak self] processes in self?.update(processes) }
        } else if !shouldWatch, watching {
            watching = false
            source.stop()
            cancelTimer()
            cancelRescan()
            observations = []
        }
        if !shouldWatch {
            // Off (not just paused for a recording): forget per-app state so
            // re-enabling starts every threshold afresh.
            if !config.enabled || !started { machine = MeetingDetectionMachine() }
            if !recording { resyncAfterRecording = false }
        }
    }

    private func update(_ processes: [ProcessIdentity]) {
        guard watching else { return }
        observations = Self.observations(processes)
        awaitingWakeScan = false
        if resyncAfterRecording {
            resyncAfterRecording = false
            _ = machine.step(observations, makeContext(recording: true))
        }
        evaluate()
    }

    private func evaluate() {
        // Until the post-recording resync lands, `observations` is stale.
        guard !resyncAfterRecording, !asleep, !awaitingWakeScan else { return }
        // While recording the start machine only marks captures as handled.
        if let prompt = machine.step(observations, makeContext(recording: recording)) {
            Self.log("meeting detected: \(prompt.app.id) (pid \(prompt.pid))")
            onPrompt?(prompt)
        }
        if tracksMeetingEnd {
            let context = makeEndContext()
            let hadPrompt = endMachine.outstanding != nil
            let before = endMachine.status(context)
            let prompt = endMachine.step(observations, context)
            if let line = Self.endTransition(
                from: before, to: endMachine.status(context), released: endMachine.lastReleasedApp) {
                Self.log(line)
            }
            if let prompt {
                Self.log("meeting end: prompt \(prompt.app.id)")
                onEndPrompt?(prompt)
            } else if hadPrompt, endMachine.outstanding == nil {
                Self.log("meeting end: withdrawn")
                onEndPromptWithdrawn?()
            }
        }
        scheduleTimer()
        scheduleRescan()
    }

    /// One log line per end-tracking transition (never per evaluation).
    nonisolated static func endTransition(
        from before: MeetingEndMachine.Status, to after: MeetingEndMachine.Status, released: MeetingApp?
    ) -> String? {
        switch (before, after) {
        case (.grace, .capturing(let ids)):
            return "meeting end: grace cancelled (\(ids.joined(separator: ", ")) resumed)"
        case (_, .capturing(let ids)):
            let old: Set<String> = if case .capturing(let oldIDs) = before { Set(oldIDs) } else { [] }
            let new = ids.filter { !old.contains($0) }
            return new.isEmpty ? nil : "meeting end: watching \(new.joined(separator: ", "))"
        case (.grace, .grace):
            return nil
        case (_, .grace(_, let grace)):
            return "meeting end: \(released?.id ?? "meeting app") released, grace \(Int(grace)) s"
        default:
            return nil
        }
    }

    private func makeContext(recording: Bool = false) -> MeetingDetectionMachine.Context {
        MeetingDetectionMachine.Context(
            now: now(), recording: recording, enabled: config.enabled, ignored: config.ignored,
            promptVisible: isPromptVisible())
    }

    private func makeEndContext() -> MeetingEndMachine.Context {
        MeetingEndMachine.Context(
            now: now(), enabled: config.enabled && config.promptOnEnd, ignored: config.ignored,
            promptVisible: isPromptVisible())
    }

    /// One-shot timer at the earliest pending deadline (start threshold or
    /// end grace), or none.
    private func scheduleTimer() {
        cancelTimer()
        let endDeadline = tracksMeetingEnd ? endMachine.nextDeadline(makeEndContext()) : nil
        guard let next = [machine.nextDeadline(makeContext(recording: recording)), endDeadline]
            .compactMap({ $0 }).min()
        else { return }
        deadline = next
        // Small slack so the step at fire time is past the threshold.
        let interval = max(0, next.timeIntervalSince(now())) + 0.05
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
    }

    /// While recording and a meeting app captures, rescan every
    /// `recordingRescanInterval` (a running cadence: events don't postpone
    /// it). Otherwise none.
    private func scheduleRescan() {
        guard tracksMeetingEnd, endMachine.isTrackingCapture, !asleep else {
            cancelRescan()
            return
        }
        guard rescanTimer == nil else { return }
        rescanDeadline = now().addingTimeInterval(Self.recordingRescanInterval)
        rescanTimer = Timer.scheduledTimer(withTimeInterval: Self.recordingRescanInterval, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.rescanTimerFired() }
        }
    }

    /// The recording rescan is due (tests call it directly with a fake clock).
    /// The scan result re-enters through `update`, which schedules the next.
    func rescanTimerFired() {
        cancelRescan()
        guard watching, tracksMeetingEnd, !asleep else { return }
        requestFreshScan()
    }

    private func cancelRescan() {
        rescanTimer?.invalidate()
        rescanTimer = nil
        rescanDeadline = nil
    }

    /// The threshold timer fired (tests call it directly with a fake clock).
    /// Decides on a fresh scan, not on the last observations: a release
    /// Core Audio did not notify (see the type doc) must not count as
    /// capture time, or a brief mic probe would pass the threshold.
    func timerFired() {
        timer = nil
        deadline = nil
        guard watching else { return }
        requestFreshScan()
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
        deadline = nil
    }

    private func reloadConfig() {
        config = loadConfig()
        if let error = config.formatError {
            if error != loggedFormatError {
                Self.log("meeting detection: \(error) in config is malformed — using defaults")
            }
        }
        loggedFormatError = config.formatError
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
