import AppKit
import Foundation

/// Posts the one "reunión lista" notice per session, when the session
/// settles (`SessionSettlement`). Failure notices are not its business: they
/// are events, posted by the coordinators.
///
/// Evaluated after every stage callback, after each Hindsight attempt, when
/// the memory-wait deadline passes, when the Mac wakes and once per launch
/// (`evaluatePending`).
/// On the main actor, so evaluations run one at a time; the O_EXCL claim of
/// `listo.notificado` (taken *before* posting, never released) is what makes
/// it at-most-once across launches — a post that fails or is denied is not
/// retried.
@MainActor
final class SettlementNotifier {
    /// Everything it touches outside itself.
    struct Environment {
        var config: () -> ConfigValues
        /// Attributes-only Keychain check: safe on the main thread.
        var hasOpenRouterKey: () -> Bool
        /// Loaded lazily on the first evaluation, once (`NotificationCutoff`).
        var cutoff: () -> Date
        var now: () -> Date
        var readFacts: (_ dir: URL, _ config: ConfigValues, _ authPaused: Bool) -> SessionSettlement.Facts
        var claim: (_ dir: URL) -> SessionFiles.ClaimResult
        var post: (Notice) -> Void
        /// One-shot: run the action at the date, on the main actor.
        var schedule: (_ at: Date, _ action: @escaping @MainActor () -> Void) -> Void
        var log: (String) -> Void

        static func live() -> Environment {
            Environment(
                config: { Config.values() },
                hasOpenRouterKey: { Keychain.openRouter.hasAPIKey() },
                cutoff: {
                    NotificationCutoff.load(
                        at: AppIdentity.notificationCutoffFile(home: FileManager.default.homeDirectoryForCurrentUser),
                        now: Date()
                    )
                },
                now: { Date() },
                readFacts: { dir, config, authPaused in
                    SessionSettlement.Facts.read(dir, authPaused: authPaused, config: config)
                },
                claim: { SessionFiles.claim(SessionFiles.readyNotified, in: $0) },
                post: { Notifications.shared.post($0) },
                schedule: { date, action in
                    let timer = Timer(timeInterval: max(0, date.timeIntervalSinceNow), repeats: false) { _ in
                        Task { @MainActor in action() }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                },
                log: { NotificationLog.write($0) }
            )
        }
    }

    private let env: Environment
    /// Whether Hindsight sends are paused on a rejected token, so a paused
    /// token never leaves a session waiting for a send that cannot happen.
    /// `didAttempt` sets it from the coordinator's own state at the moment of
    /// the attempt; `AppController` also mirrors the coordinator's handler.
    var authPaused = false
    /// First use loads it: always before the first evaluation decides.
    private lazy var cutoff: Date = env.cutoff()
    /// Recheck deadlines already scheduled, so repeated evaluations of a
    /// waiting session don't stack timers.
    private var scheduled: [URL: Date] = [:]
    /// Sessions Hindsight already tried to send this run (any outcome). The
    /// first outcome is all a notice waits for; after a relaunch this is
    /// empty and the wait cap bounds it instead.
    private var attempted: Set<URL> = []
    private var wakeObserver: NSObjectProtocol?
    private weak var wakeCenter: NotificationCenter?

    /// Folder names sort chronologically, but a session's `started` can
    /// precede its folder-sorted neighbours slightly (a recording that began
    /// before midnight, clock adjustments): the launch sweep keeps going this
    /// far past the cutoff before deciding everything older is out of reach.
    private static let oldSessionSlack: TimeInterval = 86_400

    init(environment: Environment = .live()) {
        env = environment
    }

    /// Hindsight tried to send `dir` and got an answer (any outcome): from now
    /// on memory no longer holds the notice back. `authPaused` is the
    /// coordinator's value at that moment, carried here so this evaluation
    /// never races the separate auth-paused handler.
    func didAttempt(_ dir: URL, authPaused: Bool) {
        self.authPaused = authPaused
        attempted.insert(dir)
        evaluate(dir)
    }

    /// Look at every session that is waiting on a timer again — after the
    /// Mac woke up, when a deadline may have passed unnoticed.
    func reevaluateWaiting() {
        for dir in Array(scheduled.keys) { evaluate(dir) }
    }

    /// Re-evaluate waiting sessions on wake. `center` is the workspace's
    /// notification center in the app.
    func startObservingWake(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        stopObservingWake()
        wakeCenter = center
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluateWaiting() }
        }
    }

    func stopObservingWake() {
        if let wakeObserver { wakeCenter?.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// A user-requested "Minuta lista" is about to be posted for `dir`: take
    /// the ready claim first, without posting, so the settlement check that
    /// follows the same success cannot post a second notice for the meeting.
    /// Same gates as a ready notice: nothing for a session already notified,
    /// started before the cutoff or without a start date (those never
    /// notify, so there is nothing to suppress and no marker to leave).
    func claimReadyNotice(_ dir: URL) {
        let cutoff = self.cutoff
        guard !SessionFiles.exists(SessionFiles.readyNotified, in: dir) else { return }
        guard let started = readFacts(dir, env.config()).started, started >= cutoff else { return }
        switch env.claim(dir) {
        case .claimed, .alreadyClaimed:
            return
        case .failed(let code):
            env.log("could not claim \(SessionFiles.readyNotified) in \(dir.lastPathComponent) (errno \(code)); a second ready notice is possible")
        }
    }

    /// Look at one session now.
    func evaluate(_ dir: URL) {
        let cutoff = self.cutoff
        guard !SessionFiles.exists(SessionFiles.readyNotified, in: dir) else { return }
        let config = env.config()
        settle(dir, readFacts(dir, config), config: config, cutoff: cutoff)
    }

    /// Launch sweep: sessions newest first, stopping at the first one more
    /// than a day before the cutoff (older ones can never notify, and folder
    /// names sort chronologically). Sessions without a start date are skipped.
    func evaluatePending(root: URL) {
        let cutoff = self.cutoff
        let config = env.config()
        for dir in SessionFiles.sessions(in: root) {
            // Already notified means it started after the cutoff (it could
            // not have been claimed otherwise) and there is nothing to decide.
            if SessionFiles.exists(SessionFiles.readyNotified, in: dir) { continue }
            // A permanent minutes failure already posted its own notice and
            // waits for a retry, which evaluates directly: not worth a read.
            if isInTerminalMinutesFailure(dir) { continue }
            let facts = readFacts(dir, config)
            guard let started = facts.started else { continue }
            if started < cutoff.addingTimeInterval(-Self.oldSessionSlack) { break }
            settle(dir, facts, config: config, cutoff: cutoff)
        }
    }

    private func isInTerminalMinutesFailure(_ dir: URL) -> Bool {
        SessionFiles.exists(SessionFiles.minutesError, in: dir)
            && !SessionFiles.exists(SessionFiles.minutesPending, in: dir)
            && !SessionFiles.exists(SessionFiles.minutes, in: dir)
    }

    private func readFacts(_ dir: URL, _ config: ConfigValues) -> SessionSettlement.Facts {
        var facts = env.readFacts(dir, config, authPaused)
        facts.memoryAttempted = attempted.contains(dir)
        return facts
    }

    private func settle(_ dir: URL, _ facts: SessionSettlement.Facts, config: ConfigValues, cutoff: Date) {
        guard let started = facts.started, started >= cutoff else { return }
        let applies = SummaryGate.applies(
            config: config, hasTranscript: facts.hasTranscript, hasAPIKey: env.hasOpenRouterKey()
        )
        switch SessionSettlement.derive(facts, summaryApplies: applies, now: env.now()) {
        case .inProgress(_, let recheckAt):
            if let recheckAt { scheduleRecheck(dir, at: recheckAt) }
        case .failed:
            return
        case .settled(let parts, let memoryAction, let failed):
            switch env.claim(dir) {
            case .claimed:
                env.post(NoticeBuilder.ready(
                    session: dir, label: facts.label, parts: parts, memoryAction: memoryAction, failed: failed
                ))
            case .alreadyClaimed:
                return
            case .failed(let code):
                env.log("could not claim \(SessionFiles.readyNotified) in \(dir.lastPathComponent) (errno \(code)); not notifying")
            }
        }
    }

    private func scheduleRecheck(_ dir: URL, at date: Date) {
        if let existing = scheduled[dir], existing >= date { return }
        scheduled[dir] = date
        env.schedule(date) { [weak self] in
            guard let self else { return }
            if self.scheduled[dir] == date { self.scheduled[dir] = nil }
            self.evaluate(dir)
        }
    }
}
