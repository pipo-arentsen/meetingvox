import Foundation

// MARK: - Coordinator

/// Minutes pipeline: a serial queue of session folders whose transcript is
/// turned into `minuta.md` by an LLM through OpenRouter. Separate from
/// `TranscriptionCoordinator` so a slow or failing network call never keeps
/// the Parakeet model loaded or delays the next transcription.
///
/// The filesystem is the queue: `minuta.pendiente` marks a requested,
/// unfinished automatic job, so `resumePending` picks it up after a crash or
/// quit. Only transcript *text* is sent — never audio.
///
/// Transient OpenRouter failures are retried (see `MinutesRetryPolicy`) by
/// re-queueing the job with a not-before time, so a job waiting minutes for
/// its retry never holds up other sessions. When those retries run out the
/// request stays pending (next launch or "Reintentar minuta" resumes it);
/// only non-retryable failures end in `minuta.error`. Failures log to the
/// session's `minuta.log` and never block later jobs.
actor MinutesCoordinator {
    enum Status: Sendable, Equatable {
        case idle
        case generating(session: String, queued: Int)
        /// Every queued job is waiting for its retry delay.
        case waitingRetry(session: String)
        case failed(session: String)
    }

    enum Kind: Sendable, Equatable {
        /// After transcription (or "Reintentar minuta"), driven by
        /// `minuta.pendiente`; writes `minuta.md` and runs the `on_stop` hook
        /// (once per session) when finished.
        case automatic
        /// From the menu; writes `minuta.<id>.md`, never runs the hook.
        case manual(templateID: String)
        /// From the main window "Generar minuta": an explicit,
        /// after-the-fact request for a session that never asked for
        /// minutes. Writes `minuta.md` (same template resolution as
        /// `.automatic`) but is a pure in-memory job — no `minuta.pendiente`
        /// marker is ever written, so a crash/relaunch can never resume it
        /// as an automatic job, and it NEVER runs the `on_stop` hook (the
        /// user is asking long after the session ended). On success it
        /// still calls `onAutomaticFinished`, so the summary pipeline picks
        /// up the transcript → minutes upgrade, same as `.automatic`.
        case userRequested
        /// Menu / main window "Regenerar minuta con ▸": rewrite `minuta.md`
        /// with the template the user picked. Only on success the current
        /// `minuta.md` becomes `minuta-anterior.md` and meta.json records
        /// the template. Never writes `minuta.pendiente`, never runs the
        /// hook; on success calls `onAutomaticFinished` so the summary and
        /// Hindsight re-evaluate (Hindsight doesn't resend: its hash covers
        /// the transcript only).
        case regenerate(templateID: String)
    }

    struct Job: Sendable {
        let dir: URL
        let kind: Kind
        var retries = 0
        var notBefore: Date?
        /// Partial notes already produced for a chunked transcript, so a
        /// retry resumes at the failed chunk instead of paying for all again.
        var partialNotes: [String] = []
        /// The split those notes belong to (context length + chunk sizes).
        /// Notes from a different split would silently skip transcript.
        var partialPlan: String?
    }

    /// Everything the coordinator touches outside itself.
    struct Environment: Sendable {
        var backend: any MinutesBackend
        var keyStore: any APIKeyStore
        var config: @Sendable () -> ConfigValues
        var templatesDir: URL
        var now: @Sendable () -> Date
        /// Must honor task cancellation: an enqueue cancels a retry wait so
        /// new work isn't stuck behind it.
        var sleep: @Sendable (TimeInterval) async throws -> Void
        /// Failures, and the success of a minutes request the user made
        /// (manual, main window, regenerate). The automatic path's success posts
        /// nothing: the settlement notifier posts the one "ready" notice.
        var notify: @Sendable (Notice) -> Void
        /// Launches the `on_stop` command (from `config().onStop`) for a
        /// session; returns the launch error. The once-per-session guard
        /// (`SessionHook.runOnce`) wraps it, so fakes see real call counts.
        var launchHook: @Sendable (_ command: String?, _ dir: URL) -> Error?
        /// Writes minutes content to disk (atomic replace). A seam so tests
        /// can inject a failure at the file-write step — after the LLM call
        /// already succeeded — without needing a real read-only directory.
        var writeMinutesFile: @Sendable (_ data: Data, _ url: URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
        var timeZone: TimeZone = .current
        /// An automatic job settled (success, non-retryable failure, or
        /// dropped because minutes were disabled at resume), after the hook.
        /// Not called when retries are exhausted (still pending) or for
        /// manual jobs. Default no-op until `AppController` wires the summary
        /// pipeline.
        var onAutomaticFinished: @Sendable (_ dir: URL) async -> Void = { _ in }
        /// `minuta.md` was (re)written: automatic, `userRequested` (main window
        /// "Generar minuta") or `regenerate` succeeded — never `manual`
        /// (that writes `minuta.<id>.md`, not `minuta.md`) and never on
        /// failure. `onAutomaticFinished` alone doesn't cover this: it also
        /// fires for a non-retryable automatic failure, and its summary/
        /// Hindsight follow-up usually no-ops once minutes already exist
        /// (`resumen.json` with `source == .minutes`), so nothing else
        /// refreshes an open main window after a regenerate or
        /// after-the-fact "Generar minuta". Default no-op until
        /// `AppController` wires it to post `.meetingVoxMeetingIndexDidChange`.
        var onMinutesWritten: @Sendable (_ dir: URL) async -> Void = { _ in }
        /// A user-requested success (Minuta tab "Generar minuta", regenerate) is
        /// about to post its own "Minuta lista" and trigger a settlement check: take the session's ready claim first,
        /// so the settlement check that follows cannot post a second notice.
        /// Never called for the automatic path (its notice is the settlement
        /// check's), for manual jobs (an extra `minuta.<id>.md`, no settlement)
        /// nor on failure. Default no-op until `AppController` wires
        /// it to `SettlementNotifier.claimReadyNotice`.
        var claimReadyNotice: @Sendable (_ dir: URL) async -> Void = { _ in }

        static let live = Environment(
            backend: OpenRouterClient(),
            keyStore: Keychain.openRouter,
            config: { Config.values() },
            templatesDir: Config.templatesDir,
            now: { Date() },
            sleep: { try await Task.sleep(for: .seconds($0)) },
            notify: { Notifications.shared.post($0) },
            launchHook: { SessionHook.run(command: $0, dir: $1) }
        )

        /// `.live`, with the summary-pipeline and main-window-refresh seams
        /// wired in (`AppController`).
        static func live(
            onAutomaticFinished: @escaping @Sendable (URL) async -> Void,
            onMinutesWritten: @escaping @Sendable (URL) async -> Void = { _ in },
            claimReadyNotice: @escaping @Sendable (URL) async -> Void = { _ in }
        ) -> Environment {
            var env = live
            env.onAutomaticFinished = onAutomaticFinished
            env.onMinutesWritten = onMinutesWritten
            env.claimReadyNotice = claimReadyNotice
            return env
        }
    }

    private let env: Environment
    private var queue: [Job] = []
    private var current: Job?
    private var draining = false
    private var lastFailure: String?
    private var waiter: Task<Void, Never>?
    /// Model id → context length, fetched once per process on first need.
    private var contextLengths: [String: Int]?
    private var statusHandler: (@Sendable (Status) -> Void)?

    init(environment: Environment = .live) {
        env = environment
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    // MARK: - Enqueueing

    /// Queue automatic minutes for a session whose `minuta.pendiente` marker
    /// the caller already wrote.
    func enqueueAutomatic(_ dir: URL) {
        add(Job(dir: dir, kind: .automatic))
    }

    /// Queue minutes with a specific template (menu → "Generar minuta con…").
    func generate(_ dir: URL, templateID: String) {
        add(Job(dir: dir, kind: .manual(templateID: templateID)))
    }

    /// main window → "Generar minuta": request `minuta.md` for a
    /// session that never asked for it, without ever touching
    /// `minuta.pendiente` or the `on_stop` hook (see `Kind.userRequested`).
    /// Allowed regardless of `minutes.enabled` — this is an explicit user
    /// action, like "Generar minuta con…". No-op if `minuta.md` already
    /// exists, if an automatic job for this session is already
    /// pending/queued/running (that job already owns the file and the
    /// hook), or if `minuta.pendiente`/`minuta.error` exists on disk (a
    /// session still owed by, or already reported as failed by, an
    /// automatic request — the main window offers "Reintentar minuta"
    /// for those instead; this is defense in depth for a stale window state
    /// or a caller that skips that check).
    ///
    /// - Returns: whether the job was queued. A refusal tells the caller to
    ///   undo whatever it set up for the job (the window's template choice).
    @discardableResult
    func generateFromWindow(_ dir: URL) -> Bool {
        guard !SessionFiles.exists(SessionFiles.minutes, in: dir) else { return false }
        guard !SessionFiles.exists(SessionFiles.minutesPending, in: dir) else {
            log(dir, "generateFromWindow: minuta.pendiente exists — use \"Reintentar minuta\" instead")
            return false
        }
        guard !SessionFiles.exists(SessionFiles.minutesError, in: dir) else {
            log(dir, "generateFromWindow: minuta.error exists — use \"Reintentar minuta\" instead")
            return false
        }
        let automaticInFlight = ([current].compactMap { $0 } + queue)
            .contains { $0.dir == dir && $0.kind == .automatic }
        guard !automaticInFlight else { return false }
        add(Job(dir: dir, kind: .userRequested))
        return true
    }

    /// Menu / main window "Regenerar minuta con ▸ <plantilla>". No-op (logged)
    /// without a `minuta.md`: there is nothing to regenerate, and
    /// "Generar minuta" covers that case. Unlike `generateFromWindow`, this
    /// needs no in-flight-automatic-job guard: an automatic job never
    /// writes `minuta.md` until it succeeds, so `minuta.md` already existing
    /// means no automatic job still owns writing it.
    func regenerate(_ dir: URL, templateID: String) {
        guard SessionFiles.exists(SessionFiles.minutes, in: dir) else {
            log(dir, "regenerate: no minuta.md — use \"Generar minuta\" instead")
            return
        }
        add(Job(dir: dir, kind: .regenerate(templateID: templateID)))
    }

    /// Menu → "Reintentar minuta": re-request the automatic minutes of a
    /// session left pending (retries exhausted) or failed. A failed session
    /// goes back to `minuta.pendiente`, so a quit before it finishes still
    /// resumes at launch. A job already waiting for its retry runs now.
    func retry(_ dir: URL) {
        log(dir, "minutes retry requested from the menu")
        if SessionFiles.exists(SessionFiles.minutesError, in: dir) {
            do {
                try SessionFiles.writeMarker(SessionFiles.minutesPending, in: dir)
                try FileManager.default.removeItem(at: dir.appendingPathComponent(SessionFiles.minutesError))
            } catch {
                log(dir, "could not reset the minutes markers: \(error)")
            }
        }
        if let index = queue.firstIndex(where: { $0.dir == dir && $0.kind == .automatic }) {
            queue[index].notBefore = nil
            queue[index].retries = 0
            waiter?.cancel()
            drainIfIdle()
            return
        }
        add(Job(dir: dir, kind: .automatic))
    }

    /// Queue every session under `root` holding `minuta.pendiente`, oldest
    /// first. Sessions merely lacking minuta.md are never touched — the
    /// marker is the only request. With minutes now disabled, the requests
    /// are dropped (marker removed) and each session gets its `on_stop` hook,
    /// which the transcription side deferred to the minutes pipeline.
    func resumePending(root: URL) async {
        let pending = SessionFiles.sessions(in: root)
            .filter { SessionFiles.exists(SessionFiles.minutesPending, in: $0) }
            .reversed()
        guard !pending.isEmpty else { return }
        guard env.config().minutesEnabled else {
            stderr("minutes disabled — dropping \(pending.count) pending minutes request(s)")
            for dir in pending {
                log(dir, "minutes disabled; skipping")
                removeMarkers(in: dir)
                runHook(for: dir)
                await env.onAutomaticFinished(dir)
            }
            return
        }
        stderr("resuming \(pending.count) pending minutes job(s)")
        for dir in pending { add(Job(dir: dir, kind: .automatic)) }
    }

    private func add(_ job: Job) {
        let duplicate = ([current].compactMap { $0 } + queue)
            .contains { $0.dir == job.dir && $0.kind == job.kind }
        guard !duplicate else { return }
        queue.append(job)
        // Wake a drain loop that is sleeping until some retry is due.
        waiter?.cancel()
        drainIfIdle()
    }

    // MARK: - Queue

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let now = env.now()
            guard let index = queue.firstIndex(where: { ($0.notBefore ?? .distantPast) <= now }) else {
                await waitForNextRetry(now: now)
                continue
            }
            var job = queue.remove(at: index)
            current = job
            publish(.generating(session: job.dir.lastPathComponent, queued: queue.count))
            await run(&job)
            current = nil
        }
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        drainIfIdle()
    }

    /// Sleep until the earliest retry is due, or until an enqueue cancels
    /// the wait.
    private func waitForNextRetry(now: Date) async {
        guard let due = queue.compactMap(\.notBefore).min(),
              let next = queue.first(where: { $0.notBefore == due })
        else { return }
        publish(.waitingRetry(session: next.dir.lastPathComponent))
        let sleep = env.sleep
        let delay = max(0, due.timeIntervalSince(now))
        let task = Task { _ = try? await sleep(delay) }
        waiter = task
        await task.value
        waiter = nil
    }

    /// One attempt, then success / re-queue / give-up bookkeeping.
    private func run(_ job: inout Job) async {
        let dir = job.dir
        let name = dir.lastPathComponent
        // Trashed while it waited (or between retries): drop it silently — no
        // notice, no failure state, no hook, nothing written into the path.
        guard SessionFiles.folderExists(dir) else {
            SessionFiles.logDroppedJob("minutes", dir)
            return
        }
        let started = env.now()
        log(dir, "minutes start (\(describe(job.kind)), attempt \(job.retries + 1))")
        do {
            let output = try await attempt(&job)
            let seconds = Int(env.now().timeIntervalSince(started))
            log(dir, "done in \(seconds)s → \(output.path)")
            switch job.kind {
            case .automatic:
                await finishAutomatic(dir, failed: false)
                await env.onMinutesWritten(dir)
            case .userRequested, .regenerate:
                await env.claimReadyNotice(dir)
                env.notify(NoticeBuilder.minutesReady(session: dir, file: output.lastPathComponent))
                await env.onAutomaticFinished(dir)
                await env.onMinutesWritten(dir)
            case .manual:
                // No claim: it writes an extra `minuta.<id>.md` and triggers no
                // settlement, so it must not silence the pipeline's ready notice.
                env.notify(NoticeBuilder.minutesReady(session: dir, file: output.lastPathComponent))
            }
        } catch {
            // The folder vanished mid-job (the write failed): not a failure.
            guard SessionFiles.folderExists(dir) else {
                SessionFiles.logDroppedJob("minutes", dir)
                return
            }
            log(dir, "attempt \(job.retries + 1) failed: \(error)")
            switch MinutesRetryPolicy.decide(error: error, retriesSoFar: job.retries) {
            case .retry(let delay):
                job.retries += 1
                job.notBefore = env.now().addingTimeInterval(delay)
                log(dir, "retry \(job.retries) of \(MinutesRetryPolicy.delays.count) scheduled in \(Int(delay))s")
                queue.append(job)
            case .exhausted:
                // Transient (offline, provider outage): keep the request
                // pending for the next launch or "Reintentar minuta"; the
                // hook waits until the minutes really finish.
                log(dir, "retries exhausted; minutes stay pending")
                lastFailure = name
                switch job.kind {
                case .userRequested: env.notify(NoticeBuilder.minutesNotGeneratedFromMeetings(session: dir))
                case .regenerate: env.notify(NoticeBuilder.minutesNotRegenerated(session: dir))
                case .automatic, .manual: env.notify(NoticeBuilder.stillPending(.minutes, session: dir))
                }
            case .fail:
                log(dir, "minutes failed")
                lastFailure = name
                env.notify(NoticeBuilder.failed(.minutes, session: dir))
                if job.kind == .automatic { await finishAutomatic(dir, failed: true) }
            }
        }
    }

    /// The end of an automatic request, success or final failure: settle the
    /// markers, then the `on_stop` hook (at most once per session).
    private func finishAutomatic(_ dir: URL, failed: Bool) async {
        if failed { markFailed(in: dir) } else { removeMarkers(in: dir) }
        runHook(for: dir)
        await env.onAutomaticFinished(dir)
    }

    private func runHook(for dir: URL) {
        let command = env.config().onStop
        SessionHook.runOnce(for: dir, log: { log(dir, $0) }) {
            if let error = env.launchHook(command, dir) {
                log(dir, "on_stop hook failed to launch: \(error)")
            }
        }
    }

    // MARK: - Generation

    private typealias Complete = ChunkedReducer.Complete

    /// Build the prompt(s), call the model, write the output file. Returns
    /// the file written.
    private func attempt(_ job: inout Job) async throws -> URL {
        let dir = job.dir
        let config = env.config()
        guard let model = config.openRouterModel else { throw MinutesError.noModel }
        let apiKey = try readAPIKey()
        let template = try resolveTemplate(for: job.kind, config: config, dir: dir)

        let transcript: TranscriptInput
        do {
            transcript = try TranscriptInput.read(from: dir)
        } catch {
            throw MinutesError.transcriptUnreadable("\(error)")
        }
        let context = await contextLength(for: model)
        let lines = PromptBuilder.lines(
            from: transcript.segments, maxLineTokens: Chunker.chunkBudget(contextLength: context)
        )
        guard !lines.isEmpty else { throw MinutesError.emptyTranscript }

        let p = ChunkedReducer.Prompting(
            info: SessionInfo.read(from: dir),
            finalSystem: PromptBuilder.systemPrompt(
                template: template, language: config.minutesLanguage, glossary: config.glossary
            ),
            language: config.minutesLanguage,
            glossary: config.glossary,
            context: context,
            timeZone: env.timeZone
        )
        let user = PromptBuilder.userPrompt(info: p.info, lines: lines, timeZone: p.timeZone)
        let estimated = Chunker.estimateTokens(p.finalSystem) + Chunker.estimateTokens(user)
        log(dir, "model \(model), template \(template.id), ~\(estimated) tokens estimated (context \(context))")

        let deny = config.denyDataCollection
        let backend = env.backend
        let complete: Complete = { messages, maxTokens in
            try await backend.complete(
                apiKey: apiKey, model: model, messages: messages,
                maxTokens: maxTokens, denyDataCollection: deny
            )
        }

        let content: String
        let chunked = Chunker.needsChunking(estimatedTokens: estimated, contextLength: context)
        if !chunked {
            log(dir, "chunks: 1")
            content = try await complete([.system(p.finalSystem), .user(user)], Chunker.maxTokens(contextLength: context))
        } else {
            content = try await ChunkedReducer.run(
                lines: lines, p, notes: &job.partialNotes, plan: &job.partialPlan,
                finalMaxTokens: Chunker.maxTokens(contextLength: context),
                log: { self.log(dir, $0) }, complete
            )
        }

        if case .regenerate = job.kind {
            return try replaceMinutes(content, in: dir, model: model, templateID: template.id, chunked: chunked)
        }
        let fileName: String
        switch job.kind {
        case .automatic, .userRequested, .regenerate: fileName = SessionFiles.minutes
        case .manual: fileName = SessionFiles.minutes(templateID: template.id)
        }
        return try writeOutput(
            content, to: dir.appendingPathComponent(fileName), model: model, templateID: template.id, chunked: chunked
        )
    }

    /// A regeneration succeeded: the current `minuta.md` is kept as
    /// `minuta-anterior.md` (overwriting an older one), the new one replaces
    /// it, and meta.json remembers the template.
    ///
    /// The new content is written to a staging file *first*. Only once that
    /// succeeds do we touch `minuta.md`/`minuta-anterior.md` at all: back up
    /// the current minutes, then atomically replace `minuta.md` with the
    /// staging file. If anything fails before that replace (including the
    /// staging write itself — disk full, permissions), the staging file is
    /// removed and both `minuta.md` and `minuta-anterior.md` are left exactly
    /// as they were — the earlier "back up first, then write" order could
    /// overwrite a good `minuta-anterior.md` with a same-as-current copy
    /// right before the write that was supposed to replace it failed.
    private func replaceMinutes(
        _ content: String, in dir: URL, model: String, templateID: String, chunked: Bool
    ) throws -> URL {
        let fm = FileManager.default
        let current = dir.appendingPathComponent(SessionFiles.minutes)
        let previous = dir.appendingPathComponent(SessionFiles.minutesPrevious)
        let staging = dir.appendingPathComponent(".\(SessionFiles.minutes).regenerating-\(UUID().uuidString)")

        do {
            _ = try writeOutput(content, to: staging, model: model, templateID: templateID, chunked: chunked)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        do {
            if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
            try fm.copyItem(at: current, to: previous)
            _ = try fm.replaceItemAt(current, withItemAt: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        do {
            try SessionFiles.setChosenMinutesTemplate(templateID, in: dir)
        } catch {
            log(dir, "could not record minutes_template in meta.json: \(error)")
        }
        return current
    }

    /// Read the key here, inside the actor: off the main thread (a Keychain
    /// prompt blocks its caller) and only when actually needed.
    private func readAPIKey() throws -> String {
        do {
            guard let key = try env.keyStore.read(), !key.isEmpty else { throw MinutesError.noAPIKey }
            return key
        } catch let error as MinutesError {
            throw error
        } catch {
            throw MinutesError.keychain("\(error)")
        }
    }

    /// Provenance header + body, written atomically.
    private func writeOutput(_ content: String, to output: URL, model: String, templateID: String, chunked: Bool) throws -> URL {
        let header = Self.provenance(model: model, templateID: templateID, generatedAt: env.now(), chunked: chunked)
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        try env.writeMinutesFile(Data((header + "\n\n" + body + "\n").utf8), output)
        return output
    }

    /// First line of every minutes file: where it came from, as an HTML
    /// comment so Markdown viewers hide it.
    static func provenance(model: String, templateID: String, generatedAt: Date, chunked: Bool) -> String {
        let iso = ISO8601DateFormatter().string(from: generatedAt)
        return "<!-- quill minutes · model: \(model) · template: \(templateID) · generated_at: \(iso) · chunked: \(chunked ? "yes" : "no") -->"
    }

    /// Automatic jobs use the session's `minutes_template` from meta.json when
    /// valid and present, else the configured template; a missing or invalid one
    /// falls back to `general` (and failing that to the built-in copy), since
    /// nobody is there to pick another. Manual jobs use exactly the template
    /// the user picked, or fail.
    private func resolveTemplate(for kind: Kind, config: ConfigValues, dir: URL) throws -> MinutesTemplate {
        switch kind {
        case .manual(let id), .regenerate(let id):
            guard let template = TemplateStore.template(id: id, in: env.templatesDir) else {
                throw MinutesError.templateNotFound(id)
            }
            return template
        case .automatic, .userRequested:
            // A template picked for this session (meeting prompt / menu while
            // recording) wins over the config default, when it still exists.
            if let chosen = SessionFiles.chosenMinutesTemplate(in: dir) {
                if let template = TemplateStore.template(id: chosen, in: env.templatesDir) {
                    log(dir, "template \"\(chosen)\" from meta.json (chosen for this session)")
                    return template
                }
                let reason = TemplateStore.isValidID(chosen) ? "not found" : "is not a valid template id"
                log(dir, "session template \"\(chosen)\" from meta.json \(reason) — using the config default")
            }
            let id = config.minutesTemplate
            if let template = TemplateStore.template(id: id, in: env.templatesDir) {
                log(dir, "template \"\(id)\" from config")
                return template
            }
            let fallback = FactoryTemplates.general.id
            let reason = TemplateStore.isValidID(id) ? "not found" : "is not a valid template id"
            log(dir, "template \"\(id)\" \(reason) — using \"\(fallback)\"")
            return TemplateStore.template(id: fallback, in: env.templatesDir) ?? FactoryTemplates.general
        }
    }

    /// The model's context window from the OpenRouter catalog. The catalog
    /// is fetched once per process; an unreachable catalog or unknown model
    /// falls back to a conservative size (and the catalog is retried next job).
    private func contextLength(for model: String) async -> Int {
        if contextLengths == nil {
            do {
                let models = try await env.backend.models()
                contextLengths = Dictionary(
                    models.compactMap { m in m.contextLength.map { (m.id, $0) } },
                    uniquingKeysWith: { first, _ in first }
                )
            } catch {
                stderr("minutes: model catalog unavailable (\(error)) — assuming \(Chunker.fallbackContextLength) tokens")
            }
        }
        guard let length = contextLengths?[model], length > 0 else { return Chunker.fallbackContextLength }
        return length
    }

    // MARK: - Markers

    private func removeMarkers(in dir: URL) {
        let fm = FileManager.default
        for name in [SessionFiles.minutesPending, SessionFiles.minutesError] where SessionFiles.exists(name, in: dir) {
            do {
                try fm.removeItem(at: dir.appendingPathComponent(name))
            } catch {
                log(dir, "could not remove \(name): \(error)")
            }
        }
    }

    /// `minuta.pendiente` → `minuta.error`, so a relaunch doesn't retry a
    /// job that needs the user, and the menu can flag it.
    private func markFailed(in dir: URL) {
        let fm = FileManager.default
        let pending = dir.appendingPathComponent(SessionFiles.minutesPending)
        let failed = dir.appendingPathComponent(SessionFiles.minutesError)
        do {
            if fm.fileExists(atPath: failed.path) { try fm.removeItem(at: failed) }
            if fm.fileExists(atPath: pending.path) {
                try fm.moveItem(at: pending, to: failed)
            } else {
                try SessionFiles.writeMarker(SessionFiles.minutesError, in: dir)
            }
        } catch {
            log(dir, "could not mark minutes as failed: \(error)")
        }
    }

    // MARK: - Helpers

    private func describe(_ kind: Kind) -> String {
        switch kind {
        case .automatic: "automatic"
        case .userRequested: "user-requested (main window)"
        case .manual(let id): "manual, template \(id)"
        case .regenerate(let id): "regenerate, template \(id)"
        }
    }

    private nonisolated func log(_ dir: URL, _ message: String) {
        SessionFiles.appendLog(message, to: SessionFiles.minutesLog, in: dir)
    }

    private func stderr(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}
