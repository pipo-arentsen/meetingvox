import Foundation

/// What launch may do directly when onboarding is about to show.
///
/// Each item below can raise a system prompt without a click: the mic
/// request (TCC), the Hindsight startup probe and bank refresh (Local
/// Network, plus a Keychain read for the token), the first sweep and the
/// scheduler (Local Network and, through a notice, UserNotifications
/// authorization), `settlement.evaluatePending` (notices), and resuming
/// pending minutes and summaries (`resumeAtLaunch`: they read the OpenRouter
/// key, which for a legacy-only user raises the Keychain prompt). While the
/// window is up they wait in `DeferredStarts`, so every prompt follows a
/// click in the window or the window's end.
struct StartupPlan: Equatable {
    var requestMicAtLaunch: Bool
    var probeHindsightAtLaunch: Bool
    var refreshBanksAtLaunch: Bool
    /// The Hindsight sweep and scheduler and `settlement.evaluatePending`.
    var deferBackground: Bool

    static func make(_ decision: OnboardingGate.Decision) -> StartupPlan {
        switch decision {
        case .skip:
            StartupPlan(
                requestMicAtLaunch: true, probeHindsightAtLaunch: true,
                refreshBanksAtLaunch: true, deferBackground: false
            )
        case .show:
            StartupPlan(
                requestMicAtLaunch: false, probeHindsightAtLaunch: false,
                refreshBanksAtLaunch: false, deferBackground: true
            )
        }
    }
}

extension StartupPlan {
    /// The kinds of automatic start the plan decides on.
    enum Start {
        case mic
        case hindsightProbe
        case banksRefresh
        /// The sweep/scheduler and `settlement.evaluatePending`.
        case background
        /// Resuming pending minutes and summaries at launch.
        case resumeKeychainJobs
    }

    func runsAtLaunch(_ start: Start) -> Bool {
        switch start {
        case .mic: requestMicAtLaunch
        case .hindsightProbe: probeHindsightAtLaunch
        case .banksRefresh: refreshBanksAtLaunch
        case .background: !deferBackground
        case .resumeKeychainJobs: !deferBackground
        }
    }

    /// Resumes what the filesystem queues left pending. Transcription is
    /// never held: it touches neither the Keychain nor the network. Pending
    /// minutes and summaries read the OpenRouter key inside their actors, and
    /// for a user who only has the legacy item that read raises the macOS
    /// "Always Allow" prompt, which must follow a click. They wait in
    /// `deferred` while onboarding is up (`keychainJobs` runs minutes, then
    /// summaries, once).
    @MainActor
    func resumeAtLaunch(
        transcription: () async -> Void,
        keychainJobs: @escaping @Sendable () async -> Void,
        through deferred: DeferredStarts
    ) async {
        await transcription()
        if runsAtLaunch(.resumeKeychainJobs) {
            await keychainJobs()
        } else {
            deferred.perform(.resumeKeychainJobs) { Task { await keychainJobs() } }
        }
    }

    /// Runs `action` now when the plan allows this start at launch, else
    /// hands it to `deferred` under `key` (it runs when onboarding releases
    /// it). Only automatic starts go through here; a click never does.
    @MainActor
    func launch(
        _ start: Start, key: DeferredStarts.Key, through deferred: DeferredStarts,
        _ action: @escaping @MainActor () -> Void
    ) {
        if runsAtLaunch(start) {
            action()
        } else {
            deferred.perform(key, action)
        }
    }
}

/// Where "open the app again" and "show the meetings" go. While onboarding
/// holds the starts, the main window would run the very reads that are being held
/// (banks, memory), so the onboarding window comes forward instead.
enum ReopenRoute: Equatable {
    case onboarding
    case meetings

    static func decide(startsHeld: Bool) -> ReopenRoute { startsHeld ? .onboarding : .meetings }
}

/// Holds launch-time starts (and, while the window is open, event-driven
/// Hindsight and settlement requests) until onboarding is out of the way,
/// then runs them once, in order.
///
/// Not deferring: every action runs at once and nothing is ever queued.
/// Deferring: actions queue under a `Key` (a repeated key keeps its first
/// position but the latest action, so a session requested three times replays
/// once) until the first `release`, which is idempotent. Releases come from the
/// window closing (with or without "Empezar"), the window failing to show, the
/// first recording, or a 30-minute safety timeout, so a stuck window can never
/// hold the pipeline forever. After a release, actions run at once, except
/// those performed *while* the queue is replaying: they go behind whatever is
/// still queued, so a replayed action never jumps ahead of the ones held
/// before it.
///
/// Dedupe contract: only automatic background starts and requests go through
/// here (launch starts, the sweep, event-driven `hindsight.request` and
/// `settlement.evaluate`), because a repeated key collapses to one run. A
/// user-initiated, forced or bank-specific send (a click on "Enviar a
/// memoria", "Reenviar", a chosen bank) must NOT be deferred: collapsing it
/// with an automatic request for the same session would drop the user's
/// force flag or bank choice. Those go straight to the coordinator.
@MainActor
final class DeferredStarts {
    /// The identity of a held action.
    struct Key: Hashable {
        let rawValue: String

        static let micPermission = Key(rawValue: "mic.permission")
        static let hindsightProbe = Key(rawValue: "hindsight.probe")
        static let banksRefresh = Key(rawValue: "hindsight.banks.refresh")
        static let hindsightScheduler = Key(rawValue: "hindsight.scheduler.start")
        static let settlementPending = Key(rawValue: "settlement.evaluatePending")
        static let resumeKeychainJobs = Key(rawValue: "minutes+summary.resumePending")
        /// Opening the main window on a session while onboarding is open: the
        /// latest request replays on release (see `MainWindowOpenRouter`).
        static let openSession = Key(rawValue: "window.open.session")

        /// The automatic handoff after a transcription (minutes request or
        /// summary request): one per session folder.
        static func pipelineHandoff(_ path: String) -> Key { Key(rawValue: "pipeline.handoff:\(path)") }
        /// `hindsight.request(dir)`: one per session folder.
        static func hindsightRequest(_ path: String) -> Key { Key(rawValue: "hindsight.request:\(path)") }
        /// `settlement.evaluate(dir)`: one per session folder.
        static func settlementEvaluate(_ path: String) -> Key { Key(rawValue: "settlement.evaluate:\(path)") }
    }

    enum Reason: Equatable {
        case windowClosed
        case windowFailed
        case firstRecording
        case timeout
    }

    /// Longest the window may hold the pipeline back.
    nonisolated static let safetyTimeout: Duration = .seconds(30 * 60)

    private var order: [Key] = []
    private var actions: [Key: @MainActor () -> Void] = [:]
    private var holding: Bool
    /// True while `release` is replaying, so nested `perform`s queue behind.
    private var replaying = false
    /// The pending safety timeout, exposed so a test can await it instead of sleeping.
    private(set) var timeoutTask: Task<Void, Never>?

    private(set) var releasedBecause: Reason?

    var isHolding: Bool { holding }
    var pendingCount: Int { order.count }

    /// `sleep` is injected so the timeout is tested without waiting; it
    /// must throw when cancelled. Arms the timeout only when deferring.
    init(
        deferring: Bool,
        timeout: Duration = DeferredStarts.safetyTimeout,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        holding = deferring
        guard deferring else { return }
        timeoutTask = Task { @MainActor [weak self] in
            do { try await sleep(timeout) } catch { return }
            self?.release(.timeout)
        }
    }

    func perform(_ key: Key, _ action: @escaping @MainActor () -> Void) {
        guard holding || replaying else {
            action()
            return
        }
        if actions[key] == nil { order.append(key) }
        actions[key] = action
    }

    /// The automatic step after a transcription finished for `dir` (the
    /// minutes request, or with minutes off the summary request). Both read the
    /// OpenRouter key from the Keychain, so while onboarding holds the starts
    /// the step waits (one per session) and runs on release; otherwise it is
    /// awaited in place, as before. Transcription itself is never held.
    func handoff(_ dir: URL, _ work: @escaping @Sendable () async -> Void) async {
        if holding {
            perform(.pipelineHandoff(dir.path)) { Task { await work() } }
        } else {
            await work()
        }
    }

    func windowClosed() { release(.windowClosed) }
    func windowFailed() { release(.windowFailed) }
    func recordingStarted() { release(.firstRecording) }

    /// Runs the queue once, in insertion order. Later calls, and calls when
    /// nothing was deferred, do nothing.
    func release(_ reason: Reason) {
        guard holding else { return }
        holding = false
        releasedBecause = reason
        timeoutTask?.cancel()
        timeoutTask = nil
        replaying = true
        defer { replaying = false }
        // Re-read the queue every turn: an action may append more.
        while !order.isEmpty {
            let key = order.removeFirst()
            guard let action = actions.removeValue(forKey: key) else { continue }
            action()
        }
    }
}
