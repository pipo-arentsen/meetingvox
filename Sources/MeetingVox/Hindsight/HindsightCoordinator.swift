import Foundation

/// Posted (on the main actor, by `AppController`) whenever the coordinator
/// writes or removes `hindsight.json`, `hindsight.error`, `hindsight.omitir`
/// or `hindsight.solicitado` — the main window observes it while open,
/// the same way it already observes `.meetingVoxMeetingIndexDidChange`.
extension Notification.Name {
    static let meetingVoxHindsightStatusDidChange = AppIdentity.notificationName("hindsightStatusDidChange")
}

/// Hindsight export: one item per session, the transcript as JSON
/// turns. Manual by default — a session goes out only after "Enviar a
/// memoria" (`hindsight.solicitado`) — or automatically with `auto_send`
/// (from `since` on, short sessions skipped). A session is **subscribed**
/// once requested or sent (v2 `hindsight.json`): sweeps keep retrying it
/// and resend it when its transcript changes, in either mode.
///
/// Serial queue like the other pipelines. Readiness and "already sent" are
/// derived from the folder on every look, so event triggers and sweeps are
/// idempotent and an outage just waits for the next sweep. The token is
/// read from the Keychain inside the actor right before a send and never
/// logged. Nothing is written into a session that isn't eligible.
actor HindsightCoordinator {
    enum Status: Sendable, Equatable {
        case idle
        case sending(session: String)
    }

    /// What `deleteFromMemory` did. Only `.deleted` and `.notInMemory` let
    /// the caller go on to trash the folder.
    enum DeleteResult: Sendable, Equatable {
        case deleted
        /// No v2 `hindsight.json`: this session never reached memory.
        case notInMemory
        /// Nothing was removed (or it is unknown); English reason, no token.
        case failed(String)
    }

    struct Environment: Sendable {
        var backend: any HindsightBackend
        var keyStore: any APIKeyStore
        var config: @Sendable () -> ConfigValues
        var now: @Sendable () -> Date
        var notify: @Sendable (Notice) -> Void
        var timeZone: TimeZone = .current
        /// Template id → display name; the builder only checks existence.
        var templateName: @Sendable (String) -> String? = { TemplateStore.template(id: $0, in: Config.templatesDir)?.nombre }
        /// Hindsight actually tried to send the session and got an answer —
        /// success, transient failure, token rejected or a definitive
        /// rejection — after its files were written; `authPaused` is the
        /// coordinator's value at that moment. The settlement notifier
        /// counts any of these as memory being settled for notification
        /// purposes (a transient failure is retried by a later sweep, but the
        /// ready notice does not wait for that). Not called when nothing was
        /// sent (not ready, already in memory, no token, no base URL or bank,
        /// paused): the notifier only waits for memory when a send can
        /// happen, and bounds the rest with a time cap. Must return quickly
        /// (enqueue only).
        var didAttempt: @Sendable (_ dir: URL, _ authPaused: Bool) -> Void = { _, _ in }

        static let live = Environment(
            backend: HindsightClient(),
            keyStore: Keychain.hindsight,
            config: { Config.values() },
            now: { Date() },
            notify: { Notifications.shared.post($0) }
        )
    }

    /// How long a summary still in flight (`resumen.pendiente`) may hold a
    /// ready session back, counted from its newest content file: long
    /// enough for the title to travel in the same send, short enough that a
    /// stuck summary never blocks the export.
    static let summaryWait: TimeInterval = 30 * 60

    private let env: Environment
    private var queue: [URL] = []
    private var draining = false
    /// 401/403 seen: every send waits for a new token or config change.
    private(set) var authPaused = false
    /// Bumped by every `resumeAuth()`. A send captures it before reading the
    /// token; if it changed by the time the response comes back, a stale
    /// `.unauthorized` for the *old* token must not re-pause sends — the
    /// session is just re-queued instead.
    private var authGeneration = 0
    private var statusHandler: (@Sendable (Status) -> Void)?
    private var authHandler: (@Sendable (Bool) -> Void)?
    /// Called after any Hindsight file of a session is written or removed —
    /// the main window's refresh hook.
    private var changeHandler: (@Sendable () -> Void)?
    /// Problems already reported this process ("<dir>|<key>"): they would
    /// otherwise repeat on every sweep.
    private var reported: Set<String> = []

    init(environment: Environment = .live) {
        env = environment
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Called with `true` when sends pause on a rejected token, `false` when
    /// they resume (the menu's "Token de Hindsight inválido" line).
    func setAuthPausedHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        authHandler = handler
    }

    func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        changeHandler = handler
    }

    // MARK: - Requests

    /// Consider `dir` for sending (event triggers, sweeps). Deduped against
    /// the waiting queue only — not the session being sent right now — so a
    /// change that lands mid-send is evaluated again afterwards.
    func request(_ dir: URL) {
        guard !queue.contains(dir) else { return }
        queue.append(dir)
        drainIfIdle()
    }

    /// Oldest first. With `auto_send`, every session; otherwise only the
    /// subscribed ones, so retries and re-transcriptions keep working for
    /// what the user chose without touching anything else. Queues nothing
    /// while disabled or paused (bank backfilling still runs — see below),
    /// so the 10-minute timer costs no network then.
    func sweep(root: URL) {
        let config = env.config()
        // Backfilling is pure local file stamping,
        // no network, no token — run it even while the integration is off
        // or paused, so a bank-less record is frozen at the first sweep
        // after upgrading regardless of either guard below.
        let sessions = SessionFiles.sessions(in: root).reversed()
        for dir in sessions {
            backfillBank(dir, defaultBank: config.hindsightBank)
        }
        guard config.hindsightEnabled, !authPaused else { return }
        for dir in sessions
        where config.hindsightAutoSend || HindsightFacts.readRequest(dir) != nil || HindsightFacts.readSent(dir) != nil {
            request(dir)
        }
    }

    /// A v2 `hindsight.json`/`hindsight.error`
    /// written before banks existed has no `bank` — it went to whatever the
    /// config default was *then*. Freezes that as the current default, once,
    /// on every sweep — before a later default change could otherwise make
    /// `targetBank` return a different bank for an already-sent session.
    /// Idempotent: only rewrites a record actually missing `bank`, so a
    /// second sweep is a no-op (no rewrite, no log line) once backfilled.
    private func backfillBank(_ dir: URL, defaultBank: String?) {
        guard let defaultBank else { return }
        if var sent = HindsightFacts.readSent(dir), sent.bank == nil {
            sent.bank = defaultBank
            do {
                try HindsightFacts.writeJSON(sent, dir, SessionFiles.hindsightSent)
                log(dir, "backfilled hindsight.json's bank → \(defaultBank)")
            } catch {
                log(dir, "could not backfill \(SessionFiles.hindsightSent)'s bank: \(error)")
            }
        }
        if var error = HindsightFacts.readError(dir), error.bank == nil {
            error.bank = defaultBank
            do {
                try HindsightFacts.writeJSON(error, dir, SessionFiles.hindsightError)
                log(dir, "backfilled hindsight.error's bank → \(defaultBank)")
            } catch {
                log(dir, "could not backfill \(SessionFiles.hindsightError)'s bank: \(error)")
            }
        }
    }

    /// main window / menu: "Enviar a memoria" and "Enviar igual" (`force`
    /// false), "Reenviar a memoria" (`force` true). `bank` is the one picked
    /// in "Enviar a memoria ▸" (nil = the default, written explicitly so a
    /// later default change doesn't move this request); a session already
    /// sent keeps its recorded bank whatever is passed. Writes
    /// `hindsight.solicitado` (lifting a "No enviar a memoria"), then
    /// evaluates the session; one not ready yet stays pending and a later
    /// sweep sends it. Ignores the cutoff and the short threshold.
    func send(_ dir: URL, force: Bool, bank: String? = nil) {
        let config = env.config()
        guard config.hindsightEnabled else {
            stderr("hindsight: send requested for \(dir.lastPathComponent) while the integration is off; ignored")
            return
        }
        let sent = HindsightFacts.readSent(dir)
        let target = sent != nil
            ? HindsightFacts.targetBank(sent: sent, request: nil, error: nil, defaultBank: config.hindsightBank)
            : bank ?? config.hindsightBank
        if sent != nil, let bank, bank != target {
            log(dir, "bank \(bank) ignored: the session was already sent, stays in \(target ?? "the default bank")")
        }
        do {
            try HindsightFacts.writeJSON(
                HindsightRequestMarker(force: force, requestedAt: env.now(), bank: target),
                dir, SessionFiles.hindsightRequested
            )
        } catch {
            log(dir, "could not write \(SessionFiles.hindsightRequested): \(error)")
            return
        }
        remove(SessionFiles.hindsightSkip, in: dir)
        log(dir, force ? "resend requested (forced)" : "send requested (bank \(target ?? "?"))")
        changeHandler?()
        request(dir)
    }

    /// A new token or a config change: sends may work again. Always bumps
    /// `authGeneration`, even if nothing was paused, so a send already in
    /// flight with the old token can tell its eventual `.unauthorized` is
    /// stale.
    ///
    /// - Returns: whether it actually unpaused something — `retryNow` uses
    ///   this to avoid a second `changeHandler?()` call for the same event.
    @discardableResult
    func resumeAuth() -> Bool {
        authGeneration += 1
        guard authPaused else { return false }
        authPaused = false
        stderr("hindsight: sends resumed")
        authHandler?(false)
        changeHandler?()
        return true
    }

    /// Menu "No enviar a memoria" (true) / lifting it (false).
    func setSkipped(_ dir: URL, _ skipped: Bool) {
        let url = dir.appendingPathComponent(SessionFiles.hindsightSkip)
        do {
            if skipped {
                try SessionFiles.writeMarker(SessionFiles.hindsightSkip, in: dir)
            } else {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                request(dir)
            }
            changeHandler?()
        } catch {
            stderr("hindsight: could not update \(SessionFiles.hindsightSkip) in \(dir.lastPathComponent): \(error)")
        }
    }

    /// main window / menu "Reintentar envío" (pending or error): clears a
    /// definitive rejection, writes a plain request marker for the
    /// session's bank (the rejected one — see `HindsightErrorRecord.bank`;
    /// a rejection removes the marker that led to it, so without this the
    /// session would be unsubscribed again in manual mode and `run` would
    /// return early), explicitly lifts a token pause, then re-evaluates the
    /// session. Fires `changeHandler?()` exactly once.
    func retryNow(_ dir: URL) {
        let bank = HindsightFacts.targetBank(
            sent: HindsightFacts.readSent(dir), request: HindsightFacts.readRequest(dir),
            error: HindsightFacts.readError(dir), defaultBank: env.config().hindsightBank
        )
        remove(SessionFiles.hindsightError, in: dir)
        do {
            try HindsightFacts.writeJSON(
                HindsightRequestMarker(force: false, requestedAt: env.now(), bank: bank),
                dir, SessionFiles.hindsightRequested
            )
        } catch {
            log(dir, "could not write \(SessionFiles.hindsightRequested): \(error)")
        }
        let unpaused = resumeAuth()
        if !unpaused { changeHandler?() }
        request(dir)
    }

    /// "Borrar también de la memoria (Hindsight)" in the Trash flow: deletes
    /// the session's document (`mv-<session>`, from its sent record) in the
    /// recorded bank, permanently. Opt-in per action; the caller passes only
    /// sessions it wants gone. Reads the token here, never logs it, drops any
    /// send still queued for `dir` (so the document is not re-created), and
    /// never pauses sends: a rejected token only fails this one call.
    func deleteFromMemory(_ dir: URL) async -> DeleteResult {
        guard let sent = HindsightFacts.readSent(dir) else { return .notInMemory }
        let name = dir.lastPathComponent
        // The record lives on disk: never trust it for a permanent delete. The
        // document must be this session's own (`mv-<folder>`).
        guard sent.documentID == "mv-" + name else {
            stderr("hindsight: delete \(name): record's document id does not match this session; nothing sent")
            return .failed("document id does not match this session")
        }
        let config = env.config()
        guard config.hindsightEnabled, let baseURL = config.hindsightBaseURL else {
            stderr("hindsight: delete \(name): integration off or no base_url")
            return .failed("integration off or no base_url")
        }
        guard let bank = HindsightFacts.targetBank(
            sent: sent, request: nil, error: nil, defaultBank: config.hindsightBank
        ) else {
            stderr("hindsight: delete \(name): no bank")
            return .failed("no bank")
        }
        // Both go into the URL path: no separators or dot segments.
        guard Self.isSafePathComponent(bank), Self.isSafePathComponent(sent.documentID) else {
            stderr("hindsight: delete \(name): bank or document id is not a safe path component; nothing sent")
            return .failed("unsafe bank or document id")
        }
        let token: String
        do {
            guard let stored = try env.keyStore.read(), !stored.isEmpty else {
                stderr("hindsight: delete \(name): no token")
                return .failed("no token")
            }
            token = stored
        } catch {
            stderr("hindsight: delete \(name): token unreadable: \(error)")
            return .failed("token unreadable")
        }
        queue.removeAll { $0 == dir }
        let outcome = await env.backend.deleteDocument(
            baseURL: baseURL, bank: bank, documentID: sent.documentID, token: token
        )
        stderr("hindsight: delete \(sent.documentID) from bank \(bank): \(outcome.logDescription)")
        if case .deleted = outcome { return .deleted }
        return .failed(outcome.logDescription)
    }

    /// A value that may sit in a URL path segment: non-blank, no `/`, not a
    /// dot segment, no `..` anywhere (so it cannot climb or re-route).
    nonisolated static func isSafePathComponent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.contains("/") && !value.contains("\\") && !value.contains("..") && value != "."
    }

    // MARK: - Queue

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            await run(queue.removeFirst())
        }
        draining = false
        statusHandler?(.idle)
    }

    // MARK: - One session

    private func run(_ dir: URL) async {
        // Trashed while it waited: drop it silently (nothing is written into
        // the missing path, no notice, no attempt).
        guard SessionFiles.folderExists(dir) else {
            SessionFiles.logDroppedJob("hindsight", dir)
            return
        }
        let config = env.config()
        guard config.hindsightEnabled, !authPaused, let baseURL = config.hindsightBaseURL else { return }
        guard !SessionFiles.exists(SessionFiles.hindsightSkip, in: dir), env.keyStore.hasAPIKey() else { return }

        var requested = HindsightFacts.readRequest(dir)
        // A forced marker without `requested_at` (malformed, or a very old
        // one) would otherwise call `env.now()` fresh on every run below,
        // giving a retried forced resend a new operation id each time.
        // Resolve it once and persist it, so a retry reuses the same value.
        if let r = requested, r.force, r.requestedAt == nil {
            let resolved = HindsightRequestMarker(force: true, requestedAt: env.now(), bank: r.bank)
            do {
                try HindsightFacts.writeJSON(resolved, dir, SessionFiles.hindsightRequested)
                requested = resolved
            } catch {
                log(dir, "could not persist \(SessionFiles.hindsightRequested)'s requested_at: \(error)")
            }
        }
        let sent = HindsightFacts.readSent(dir)
        let subscribed = requested != nil || sent != nil
        if !subscribed {
            // Automatic mode only, from the cutoff on (none → nothing).
            guard config.hindsightAutoSend, let since = config.hindsightSince else { return }
            guard let started = MeetingEntry.load(dir).started else {
                reportOnce(dir, "no start date (meta.json and folder name unreadable)", sessionLog: false)
                return
            }
            guard ConfigValues.hindsightDay(started, timeZone: env.timeZone) >= since else { return }
        }
        let error = HindsightFacts.readError(dir)
        // Recorded bank (sent → request → rejection), else the
        // default (automatic sends included). Checked only once the session
        // is otherwise eligible for this pass, so an unsubscribed session in
        // manual mode (already returned above) stays silent instead of
        // reporting a missing bank it was never going to send with.
        guard let bank = HindsightFacts.targetBank(
            sent: sent, request: requested, error: error, defaultBank: config.hindsightBank
        ) else {
            reportOnce(dir, "no bank configured", sessionLog: false)
            return
        }
        guard isReady(dir) else { return }

        let force = requested?.force == true
        let input: HindsightSessionInput
        let payload: HindsightPayload
        do {
            input = try HindsightSessionInput.read(from: dir)
            let options = HindsightBuildOptions(
                ownerName: config.hindsightOwnerName, ownerDescription: config.hindsightOwnerDescription,
                glossary: config.glossary, timeZone: env.timeZone,
                configTemplate: config.minutesTemplate, templateName: env.templateName,
                forcedAt: force ? (requested?.requestedAt ?? env.now()) : nil
            )
            guard let built = try HindsightPayloadBuilder.build(input, options) else {
                reportOnce(dir, "nothing to send (empty transcript)")
                return
            }
            payload = built
        } catch HindsightSessionInput.ReadError.transcriptMissing {
            return
        } catch HindsightSessionInput.ReadError.noStartDate {
            reportOnce(dir, "no start date (meta.json and folder name unreadable)", sessionLog: false)
            return
        } catch {
            reportOnce(dir, "cannot build the request: \(error)")
            return
        }

        if !subscribed {
            let words = HindsightFacts.words(in: input.segments)
            let seconds = HindsightFacts.duration(metaSeconds: input.durationSeconds, segments: input.segments)
            if HindsightFacts.isShort(
                words: words, durationSeconds: seconds,
                minWords: config.hindsightMinWords, minMinutes: config.hindsightMinMinutes
            ) {
                reportOnce(
                    dir, "short session (\(words) words, \((seconds ?? 0) / 60) min): not sent automatically",
                    key: "short:\(payload.contentHash)"
                )
                return
            }
        }
        if !force {
            if sent?.contentHash == payload.contentHash {
                // Already in memory: a plain request for it is satisfied.
                if requested != nil {
                    remove(SessionFiles.hindsightRequested, in: dir)
                    changeHandler?()
                }
                refreshMtimeIfStale(dir, record: SessionFiles.hindsightSent)
                return
            }
            if error?.hash == payload.contentHash {
                // Already rejected for this exact content: a plain request
                // is satisfied by that outcome — the main window's
                // "Reintentar envío" is how the user tries again, not
                // another identical, still-doomed send on every sweep.
                if requested != nil {
                    remove(SessionFiles.hindsightRequested, in: dir)
                    reportOnce(
                        dir, "request satisfied by the existing rejection; use \"Reintentar envío\" to try again",
                        key: "error-match:\(payload.contentHash)"
                    )
                    changeHandler?()
                }
                refreshMtimeIfStale(dir, record: SessionFiles.hindsightError)
                return
            }
        }

        let token: String
        let generation = authGeneration
        do {
            guard let stored = try env.keyStore.read(), !stored.isEmpty else { return }
            token = stored
        } catch {
            reportOnce(dir, "token unreadable: \(error)", sessionLog: false)
            return
        }

        let name = dir.lastPathComponent
        statusHandler?(.sending(session: name))
        log(dir, "sending \(payload.documentID) to bank \(bank) (operation \(payload.operationID)\(force ? ", forced resend" : ""))")
        let outcome = await env.backend.retain(baseURL: baseURL, bank: bank, token: token, body: payload.body)

        switch outcome {
        case .success:
            do {
                try HindsightFacts.writeJSON(
                    HindsightSentRecord(
                        documentID: payload.documentID, contentHash: payload.contentHash,
                        operationID: payload.operationID, sentAt: env.now(), bank: bank
                    ),
                    dir, SessionFiles.hindsightSent
                )
                remove(SessionFiles.hindsightError, in: dir)
                // Only the request this send answered: one written while it
                // was in flight (e.g. "Reenviar a memoria") must survive.
                if let requested, HindsightFacts.readRequest(dir) == requested {
                    remove(SessionFiles.hindsightRequested, in: dir)
                }
                changeHandler?()
                log(dir, "sent")
            } catch {
                // The next sweep resends the same body with the same
                // operation id, which the server treats as a retry.
                log(dir, "sent, but could not write \(SessionFiles.hindsightSent): \(error)")
            }
            env.didAttempt(dir, authPaused)
        case .transient:
            // Dedup by operation, not by message: an outage can report a
            // different transient reason on each sweep.
            reportOnce(
                dir, "not sent: \(outcome.logDescription); will retry on the next sweep",
                key: "transient:\(payload.operationID)"
            )
            env.didAttempt(dir, authPaused)
        case .unauthorized:
            guard generation == authGeneration else {
                log(dir, "not sent: \(outcome.logDescription) (stale token, already replaced); re-evaluating")
                request(dir)
                return
            }
            log(dir, "not sent: \(outcome.logDescription); pausing every send until the token or the config changes")
            authPaused = true
            stderr("hindsight: token rejected; sends paused")
            authHandler?(true)
            changeHandler?()
            env.didAttempt(dir, authPaused)
        case .rejected(let status, let message):
            log(dir, "not sent: \(outcome.logDescription)")
            do {
                try HindsightFacts.writeJSON(
                    HindsightErrorRecord(status: status, message: message, hash: payload.contentHash, bank: bank),
                    dir, SessionFiles.hindsightError
                )
                // Same rule as success: only the request this send answered
                // — a definitive rejection must not leave a (forced or
                // plain) request marker resending the same doomed content
                // forever; "Reintentar envío" is the way to try again.
                if let requested, HindsightFacts.readRequest(dir) == requested {
                    remove(SessionFiles.hindsightRequested, in: dir)
                }
                changeHandler?()
            } catch {
                log(dir, "could not write \(SessionFiles.hindsightError): \(error)")
            }
            env.notify(NoticeBuilder.failed(.memory, session: dir))
            env.didAttempt(dir, authPaused)
        }
    }

    /// Ready to send: a transcript; minutes resolved (written,
    /// failed for good, or never requested); and no summary in flight
    /// unless it has held the session for `summaryWait`.
    private func isReady(_ dir: URL) -> Bool {
        guard SessionFiles.exists(SessionFiles.transcriptJSON, in: dir) else { return false }
        let hasMinutes = SessionFiles.exists(SessionFiles.minutes, in: dir)
        if !hasMinutes,
           SessionFiles.exists(SessionFiles.minutesPending, in: dir),
           !SessionFiles.exists(SessionFiles.minutesError, in: dir) {
            return false
        }
        guard SessionFiles.exists(SessionFiles.summaryPending, in: dir) else { return true }
        let newest = dir.appendingPathComponent(hasMinutes ? SessionFiles.minutes : SessionFiles.transcriptJSON)
        guard let written = (try? newest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return true }
        return env.now().timeIntervalSince(written) >= Self.summaryWait
    }

    // MARK: - Files

    /// "Aplicar glosario" reapplying to a legacy
    /// transcript rewrites `transcript.json` (adds/refreshes `text_raw`)
    /// without changing the content hash, so the branch above never touches
    /// this record — but `HindsightFacts.readCheap` (mtime-based, used by
    /// the sessions menu) then shows the session stuck on "Pendiente"
    /// forever, since the record looks older than the transcript. Rewriting
    /// the record with its own bytes when the transcript is newer just
    /// catches its mtime up, atomically, so the cheap read agrees with the
    /// precise hash-based one again — the modification date is set to the
    /// injected clock explicitly (like every other timestamp here) rather
    /// than left to the filesystem's real one, so this stays deterministic.
    private func refreshMtimeIfStale(_ dir: URL, record name: String) {
        guard let transcriptModified = HindsightFacts.modified(dir, SessionFiles.transcriptJSON),
              let recordModified = HindsightFacts.modified(dir, name),
              recordModified < transcriptModified
        else { return }
        let url = dir.appendingPathComponent(name)
        do {
            let data = try Data(contentsOf: url)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: env.now()], ofItemAtPath: url.path)
        } catch {
            log(dir, "could not refresh \(name)'s modification date: \(error)")
        }
    }

    private func remove(_ name: String, in dir: URL) {
        guard SessionFiles.exists(name, in: dir) else { return }
        do {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        } catch {
            log(dir, "could not remove \(name): \(error)")
        }
    }

    // MARK: - Logging

    /// Once per process per session and `key` (the message itself, unless a
    /// distinct `key` is given). `sessionLog: false` sends it to stderr
    /// instead (problems that aren't about this session's content).
    private func reportOnce(_ dir: URL, _ message: String, key: String? = nil, sessionLog: Bool = true) {
        guard reported.insert("\(dir.path)|\(key ?? message)").inserted else { return }
        if sessionLog {
            log(dir, message)
        } else {
            stderr("hindsight: \(dir.lastPathComponent): \(message)")
        }
    }

    private nonisolated func log(_ dir: URL, _ message: String) {
        SessionFiles.appendLog(message, to: SessionFiles.hindsightLog, in: dir)
    }

    private nonisolated func stderr(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
