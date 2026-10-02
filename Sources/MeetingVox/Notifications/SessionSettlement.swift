import Foundation

/// Where a session is on its way to "ready", derived from the markers on
/// disk only (the filesystem is the state). Pure `derive` plus one reader,
/// `Facts.read`, with no side effects, so any trigger — a stage callback, a
/// timer, the launch sweep — can ask at any time.
enum SessionSettlement: Equatable {
    /// What a ready session got.
    enum Part: Hashable, Sendable { case transcript, minutes, summary }

    /// One output's state, from its marker files.
    enum MarkerState: Equatable, Sendable {
        /// The output exists.
        case done
        /// Requested and not finished (also after transient retries ran out).
        case pending
        /// Failed for good and there is no output.
        case failed
        /// Never requested (or not applicable).
        case absent
    }

    /// Still on its way. `recheckAt`: the moment to look again when nothing
    /// else will trigger it (the Hindsight wait cap).
    case inProgress(Notice.Stage, recheckAt: Date?)
    /// Nothing more is coming. `memoryAction`: could still be sent to memory.
    /// `failed`: secondary stages that ended badly (a summary that failed for
    /// good, a rejected memory send) — terminal for notification purposes, so
    /// the ready notice still goes out and names them.
    case settled(ready: Set<Part>, memoryAction: Bool, failed: Set<Notice.Stage> = [])
    /// A permanent failure of the minutes (`minuta.error`): its failure notice
    /// is the meeting's only notice until a retry succeeds. Never claims.
    case failed(Set<Notice.Stage>)

    /// The most a settled session waits for the first Hindsight send outcome.
    /// A send normally happens within seconds of the content settling, but an
    /// unreachable server, a busy queue or a coordinator that never got to the
    /// session must not hold the meeting's notice back forever; ten minutes
    /// covers a slow send plus a retry without making the user wonder. The
    /// wait also applies only while a send can happen (`Facts.memoryCanSend`)
    /// and has not been attempted (`Facts.memoryAttempted`).
    static let memoryWait: TimeInterval = 600

    struct Facts: Equatable, Sendable {
        var started: Date? = nil
        /// `SessionLabel` of the session, for the notice body.
        var label: String = ""
        var hasTranscript = false
        var minutes: MarkerState = .absent
        var summary: MarkerState = .absent
        /// nil when the integration is off or there is no transcript.
        var memory: HindsightStatus? = nil
        /// The newest content file's modification date: where the memory
        /// wait is counted from.
        var contentSettledAt: Date? = nil
        /// A Hindsight send can actually happen for this session: token,
        /// `base_url` and a resolvable bank (the coordinator returns early
        /// without them, so no outcome would ever arrive). Only meaningful
        /// while `memory == .pending`.
        var memoryCanSend = true
        /// A send was already attempted this run (any outcome): the first
        /// outcome is all the notification waits for. Set by the notifier,
        /// which keeps that in memory only — after a relaunch the wait cap
        /// bounds it.
        var memoryAttempted = false

        /// Reads everything `derive` needs from `dir`. Cheap Hindsight facts
        /// (`readCheap`, mtime based), because this runs on every stage
        /// callback and at launch for many sessions. `hasHindsightToken` is
        /// an attributes-only Keychain check (no prompt), asked only while a
        /// send is pending.
        static func read(
            _ dir: URL, authPaused: Bool, config: ConfigValues,
            hasHindsightToken: () -> Bool = { Keychain.hindsight.hasAPIKey() }
        ) -> Facts {
            let entry = MeetingEntry.load(dir)
            let hasTranscript = SessionFiles.exists(SessionFiles.transcriptJSON, in: dir)
            var memory: HindsightStatus?
            var canSend = true
            if config.hindsightEnabled {
                let hindsightFacts = HindsightFacts.readCheap(dir)
                memory = HindsightStatus.derive(
                    facts: hindsightFacts, settings: .init(config: config),
                    timeZone: .current, authPaused: authPaused
                )
                if memory == .pending {
                    canSend = config.hindsightBaseURL != nil
                        && HindsightFacts.targetBank(
                            sent: hindsightFacts.sent, request: hindsightFacts.request,
                            error: HindsightFacts.readError(dir), defaultBank: config.hindsightBank
                        ) != nil
                        && hasHindsightToken()
                }
            }
            let newest = [SessionFiles.transcriptJSON, SessionFiles.minutes, SessionFiles.summaryJSON]
                .compactMap { HindsightFacts.modified(dir, $0) }
                .max()
            return Facts(
                started: entry.started,
                label: SessionLabel.text(
                    summaryTitle: entry.summary?.title, calendarTitle: entry.calendarEvent?.title,
                    started: entry.started, ended: entry.ended,
                    durationSeconds: entry.durationSeconds, folder: dir.lastPathComponent, timeZone: .current
                ),
                hasTranscript: hasTranscript,
                minutes: state(output: SessionFiles.minutes, pending: SessionFiles.minutesPending, error: SessionFiles.minutesError, in: dir),
                summary: state(output: SessionFiles.summaryJSON, pending: SessionFiles.summaryPending, error: SessionFiles.summaryError, in: dir),
                memory: memory,
                contentSettledAt: newest,
                memoryCanSend: canSend
            )
        }

        /// A pending marker wins (a retry in flight, or retries that ran
        /// out); then the output; an error only counts without its output.
        private static func state(output: String, pending: String, error: String, in dir: URL) -> MarkerState {
            if SessionFiles.exists(pending, in: dir) { return .pending }
            if SessionFiles.exists(output, in: dir) { return .done }
            if SessionFiles.exists(error, in: dir) { return .failed }
            return .absent
        }
    }

    /// Order: no transcript → transcription in progress; pending minutes;
    /// pending summary, or a summary still owed (absent and the gate says it
    /// applies); a permanent minutes failure → `.failed`; the Hindsight wait
    /// (only while a send can happen and none was attempted, capped at
    /// `memoryWait` after the content settled); otherwise settled, naming the
    /// summary/memory failures.
    static func derive(_ f: Facts, summaryApplies: Bool, now: Date) -> SessionSettlement {
        guard f.hasTranscript else { return .inProgress(.transcription, recheckAt: nil) }
        if f.minutes == .pending { return .inProgress(.minutes, recheckAt: nil) }
        if f.summary == .pending || (f.summary == .absent && summaryApplies) {
            return .inProgress(.summary, recheckAt: nil)
        }
        if f.minutes == .failed {
            return .failed(f.summary == .failed ? [.minutes, .summary] : [.minutes])
        }

        if f.memory == .pending, f.memoryCanSend, !f.memoryAttempted, let settledAt = f.contentSettledAt {
            let deadline = settledAt.addingTimeInterval(memoryWait)
            if now < deadline { return .inProgress(.memory, recheckAt: deadline) }
        }
        var ready: Set<Part> = [.transcript]
        if f.minutes == .done { ready.insert(.minutes) }
        if f.summary == .done { ready.insert(.summary) }
        var failed: Set<Notice.Stage> = []
        if f.summary == .failed { failed.insert(.summary) }
        if f.memory == .error { failed.insert(.memory) }
        let memoryAction = f.memory == .notSent || f.memory == .short
        return .settled(ready: ready, memoryAction: memoryAction, failed: failed)
    }
}
