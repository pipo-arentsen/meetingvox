import Foundation

/// Pure decision logic: fed with the matched processes using input at `now`,
/// says when to prompt. No Core Audio, no clock of its own — tests inject
/// both.
///
/// Per app: input must be in use continuously for the app's threshold. Once
/// prompted (whatever the answer, or a timeout) — or once seen while quill
/// records — the app is "handled" and won't prompt again until its input has
/// been idle for `rearmAfter` and starts again. A shorter pause is the same
/// call (muting, switching devices).
///
/// Steps happen on observation changes; between them the driver asks
/// `nextDeadline` when the clock alone would produce a prompt.
struct MeetingDetectionMachine {
    struct Observation: Sendable, Equatable {
        let pid: pid_t
        let app: MeetingApp
    }

    struct Context: Sendable {
        var now: Date
        /// quill is (or just was) recording: what is active counts as handled.
        var recording = false
        var enabled = true
        /// Rule ids or bundle ids from `meeting_detection.ignored_apps`.
        var ignored: Set<String> = []
        /// A prompt is already on screen: hold others until it's gone
        /// (without consuming them).
        var promptVisible = false
        var ownPID: pid_t = getpid()
    }

    struct Prompt: Sendable, Equatable {
        let app: MeetingApp
        let pid: pid_t
    }

    /// For `quill diag --mode processes`.
    enum AppStatus: Sendable, Equatable {
        case disabled
        case ignored
        case recording
        case waiting(elapsed: TimeInterval, threshold: TimeInterval)
        /// Already prompted (or recorded) for this continuous use.
        case handled
        case idle
    }

    static let rearmAfter: TimeInterval = 10

    private struct AppState {
        let app: MeetingApp
        var activeSince: Date?
        var idleSince: Date?
        var handled = false
    }

    private var states: [String: AppState] = [:]

    /// Advance to `context.now`. Returns at most one prompt per step.
    mutating func step(_ observations: [Observation], _ context: Context) -> Prompt? {
        let now = context.now
        var active: [String: Observation] = [:]
        for observation in observations where observation.pid != context.ownPID {
            if active[observation.app.id] == nil { active[observation.app.id] = observation }
        }

        // Idle transitions first, so every app's clock is current.
        for (id, var state) in states where active[id] == nil && state.activeSince != nil {
            state.activeSince = nil
            state.idleSince = now
            states[id] = state
        }

        var prompt: Prompt?
        // Stable order so simultaneous starts prompt deterministically.
        for id in active.keys.sorted() {
            guard let observation = active[id] else { continue }
            var state = states[id] ?? AppState(app: observation.app)
            if state.activeSince == nil {
                if state.handled, let idle = state.idleSince, now.timeIntervalSince(idle) >= Self.rearmAfter {
                    state.handled = false
                }
                state.activeSince = now
                state.idleSince = nil
            }
            if context.recording {
                state.handled = true
            } else if prompt == nil, isCandidate(state, context),
                      let since = state.activeSince,
                      now.timeIntervalSince(since) >= observation.app.threshold {
                state.handled = true
                prompt = Prompt(app: observation.app, pid: observation.pid)
            }
            states[id] = state
        }
        return prompt
    }

    /// When, with no change in observations, the next prompt would be due:
    /// the earliest threshold of an active app that could still prompt. Nil =
    /// nothing to time (no candidate, all handled or ignored, disabled,
    /// recording, or a prompt on screen holds them).
    func nextDeadline(_ context: Context) -> Date? {
        states.values
            .filter { isCandidate($0, context) }
            .compactMap { state in state.activeSince.map { $0.addingTimeInterval(state.app.threshold) } }
            .min()
    }

    /// What the machine thinks of `app` right now (call after `step`).
    func status(of app: MeetingApp, _ context: Context) -> AppStatus {
        guard context.enabled else { return .disabled }
        if app.isIgnored(by: context.ignored) { return .ignored }
        guard let state = states[app.id], let since = state.activeSince else { return .idle }
        if context.recording { return .recording }
        if state.handled { return .handled }
        return .waiting(elapsed: context.now.timeIntervalSince(since), threshold: app.threshold)
    }

    private func isCandidate(_ state: AppState, _ context: Context) -> Bool {
        state.activeSince != nil && !state.handled && context.enabled && !context.recording
            && !context.promptVisible && !state.app.isIgnored(by: context.ignored)
    }
}
