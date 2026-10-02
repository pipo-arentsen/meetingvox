import Foundation

/// Summary pipeline: a serial queue of session folders whose transcript (or
/// minutes, once available) is turned into `resumen.json` by an LLM through
/// OpenRouter, then folded into `indice.md`. Cloned from `MinutesCoordinator`
/// (filesystem queue, `MinutesRetryPolicy`, Keychain inside the actor) so a
/// slow or failing network call never blocks minutes or transcription.
///
/// The filesystem is the queue: `resumen.pendiente` marks a requested,
/// unfinished job, so `resumePending` picks it up after a crash or quit.
/// Only text (transcript or minutes) is sent — never audio.
actor SummaryCoordinator {
    enum Status: Sendable, Equatable {
        case idle
        case generating(session: String, queued: Int)
        case waitingRetry(session: String)
        case failed(session: String)
        /// A tasks backfill job is running or parked for a transient retry.
        /// Deliberately not `.generating`/`.waitingRetry`/`.failed`: those feed
        /// the Resumen pill and stepper, and a backfill must stay invisible to
        /// them (`StageEvent` maps this to "summary idle"; only the menu line
        /// shows it).
        case extractingTasks(session: String, queued: Int)
    }

    struct Job: Sendable {
        enum Kind: Sendable, Equatable {
            /// Write `resumen.json` (`resumen.pendiente`).
            case summary
            /// Merge `tasks`/`country` into an existing `resumen.json`
            /// (`tareas.pendiente`).
            case tasks
        }

        let dir: URL
        var kind: Kind = .summary
        var retries = 0
        var notBefore: Date?
        /// Whether the one allowed retry after an invalid-JSON reply already
        /// happened for this job.
        var invalidJSONRetried = false
        var partialNotes: [String] = []
        var partialPlan: String?
    }

    /// Everything the coordinator touches outside itself.
    struct Environment: Sendable {
        var backend: any MinutesBackend
        var keyStore: any APIKeyStore
        var config: @Sendable () -> ConfigValues
        var now: @Sendable () -> Date
        var sleep: @Sendable (TimeInterval) async throws -> Void
        /// Failures only; the settlement notifier posts the "ready" notice.
        var notify: @Sendable (Notice) -> Void
        var timeZone: TimeZone = .current
        /// Called after `resumen.json` changes on disk (a successful job) or
        /// after a `rebuild` pass, so a listener can regenerate `indice.md`.
        var indexDidChange: @Sendable () -> Void = {}
        /// Called with the session once its summary settles for good —
        /// `resumen.json` written or `resumen.error` — so the Hindsight
        /// export can look again (it waits while `resumen.pendiente` exists
        /// and carries the summary as metadata). Not called for exhausted
        /// transient retries: the marker stays and the export's 30-minute
        /// cap covers it. Must return quickly (enqueue only) — this actor
        /// awaits it directly, so a closure that itself awaits the Hindsight
        /// actor's turn would stall this queue on a slow or busy export.
        var didFinish: @Sendable (URL) async -> Void = { _ in }

        static let live = Environment(
            backend: OpenRouterClient(),
            keyStore: Keychain.openRouter,
            config: { Config.values() },
            now: { Date() },
            sleep: { try await Task.sleep(for: .seconds($0)) },
            notify: { Notifications.shared.post($0) }
        )

        /// `.live`, with `indexDidChange` wired to regenerate `indice.md` at
        /// `root` and notify listeners, and `didFinish` to the Hindsight
        /// export (`AppController`).
        static func live(
            indexDidChange: @escaping @Sendable () -> Void,
            didFinish: @escaping @Sendable (URL) async -> Void = { _ in }
        ) -> Environment {
            var env = live
            env.indexDidChange = indexDidChange
            env.didFinish = didFinish
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
    /// A separate cache from `MinutesCoordinator`'s: independent actors, and
    /// the cost of fetching it twice is negligible.
    private var contextLengths: [String: Int]?
    private var statusHandler: (@Sendable (Status) -> Void)?

    init(environment: Environment = .live) {
        env = environment
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    // MARK: - Requesting

    /// Request a summary for `dir`, unless the request gate says to skip it:
    /// summaries disabled, no transcript, no model,
    /// no API key, or a summary already exists and isn't eligible for the
    /// transcript → minutes upgrade. No marker is written when skipped.
    func request(_ dir: URL) {
        _ = admit(dir)
    }

    /// The request gate plus queueing; whether the session was queued.
    private func admit(_ dir: URL) -> Bool {
        let config = env.config()
        guard SummaryGate.applies(
            config: config, hasTranscript: SessionFiles.exists(SessionFiles.transcriptJSON, in: dir),
            hasAPIKey: env.keyStore.hasAPIKey()
        ) else { return false }
        if SessionFiles.exists(SessionFiles.summaryJSON, in: dir), !eligibleForUpgrade(dir) { return false }
        do {
            try SessionFiles.writeMarker(SessionFiles.summaryPending, in: dir)
        } catch {
            log(dir, "could not write \(SessionFiles.summaryPending): \(error)")
            return false
        }
        add(Job(dir: dir))
        return true
    }

    /// "Reintentar" on a failed-summary notice. A job parked for its next
    /// transient retry runs now; one already running is left alone; otherwise
    /// the normal request gate decides (so a summary the gate would refuse —
    /// disabled, no key — leaves `resumen.error` as it was) and, once
    /// admitted, `resumen.error` is cleared. Returns whether anything was
    /// (re)started.
    @discardableResult
    func retry(_ dir: URL) -> Bool {
        // Only a summary job counts: a queued or running tasks job for the
        // same session must neither swallow nor block a summary retry.
        if let index = queue.firstIndex(where: { $0.dir == dir && $0.kind == .summary }) {
            log(dir, "summary retry requested; running now")
            queue[index].notBefore = nil
            queue[index].retries = 0
            waiter?.cancel()
            drainIfIdle()
            return true
        }
        guard !(current?.dir == dir && current?.kind == .summary), admit(dir) else { return false }
        log(dir, "summary retry requested")
        let error = dir.appendingPathComponent(SessionFiles.summaryError)
        if SessionFiles.exists(SessionFiles.summaryError, in: dir) {
            do {
                try FileManager.default.removeItem(at: error)
            } catch {
                log(dir, "could not remove \(SessionFiles.summaryError): \(error)")
            }
        }
        return true
    }

    /// A transcript-sourced summary can be replaced once minutes exist —
    /// they make a strictly better source.
    private func eligibleForUpgrade(_ dir: URL) -> Bool {
        guard let existing = readSummary(dir), existing.source == .transcript else { return false }
        return SessionFiles.exists(SessionFiles.minutes, in: dir)
    }

    /// Every session under `root` holding `resumen.pendiente`, oldest first,
    /// then every one holding a stalled `tareas.pendiente` (a tasks backfill
    /// whose transient retries ran out or that a quit interrupted). Only
    /// "Reconstruir índice" creates new backfill jobs: a legacy summary with no
    /// marker is never touched at launch. A session that owes a summary skips
    /// its tasks job (the summary brings the tasks itself).
    func resumePending(root: URL) {
        let sessions = SessionFiles.sessions(in: root)
        let pending = sessions.filter { SessionFiles.exists(SessionFiles.summaryPending, in: $0) }.reversed()
        let stalledTasks = sessions
            .filter { SessionFiles.exists(SessionFiles.tasksPending, in: $0) }
            .reversed()
            .filter { dir in !pending.contains(dir) }
        if !pending.isEmpty { stderr("resuming \(pending.count) pending summary job(s)") }
        for dir in pending { add(Job(dir: dir)) }
        if !stalledTasks.isEmpty { stderr("resuming \(stalledTasks.count) stalled tasks job(s)") }
        for dir in stalledTasks { add(Job(dir: dir, kind: .tasks)) }
    }

    /// Menu → "Reconstruir índice": two kinds of summary candidate, oldest first,
    /// both routed through the same request gate (`request(dir)` is a no-op
    /// via `add`'s dedupe if the session is already queued or running):
    /// - fresh backfill — a transcript, no minutes pending, and no summary
    ///   marker yet at all (sessions recorded before this feature);
    /// - stalled retries — `resumen.pendiente` still on disk (transient
    ///   retries ran out earlier) but not currently queued/in-flight, so a
    ///   crash-free process would otherwise only resume it at next launch.
    /// (Summary jobs always run before tasks jobs, whatever the order queued.)
    /// Sessions with an existing `resumen.json` are the transcript→minutes
    /// upgrade path, requested directly once minutes finish — rebuild never
    /// touches those. A second pass then queues the tasks backfill for legacy
    /// summaries (`TasksBackfill.isCandidate`: no `tasks` key, nothing pending,
    /// no earlier `tareas.error`), oldest first, behind the summary jobs.
    /// Regenerates `indice.md` once immediately (covers sessions the gate
    /// skipped, or none at all) and again after each job that succeeds.
    func rebuild(root: URL) {
        let candidates = SessionFiles.sessions(in: root)
            .filter { dir in
                guard SessionFiles.exists(SessionFiles.transcriptJSON, in: dir) else { return false }
                if SessionFiles.exists(SessionFiles.summaryPending, in: dir) { return true }
                return !SessionFiles.exists(SessionFiles.minutesPending, in: dir)
                    && !SessionFiles.exists(SessionFiles.summaryJSON, in: dir)
                    && !SessionFiles.exists(SessionFiles.summaryError, in: dir)
            }
            .reversed()
        stderr("rebuild: \(candidates.count) summary job(s)")
        for dir in candidates { request(dir) }
        var backfill = 0
        for dir in SessionFiles.sessions(in: root).reversed() where TasksBackfill.isCandidate(.read(dir)) {
            if admitTasks(dir) { backfill += 1 }
        }
        stderr("rebuild: \(backfill) tasks backfill job(s)")
        env.indexDidChange()
    }

    /// Ask for `indice.md` to be regenerated without touching any summary.
    /// The calendar follow-up (a link written or removed) goes through here so
    /// this coordinator stays the index's only writer.
    func reindex() {
        env.indexDidChange()
    }

    /// The tasks request gate plus queueing; whether a job was queued. Same
    /// summary gate as a summary (key, model, `summary.enabled`, transcript),
    /// and nothing while a summary job for the session is queued or running:
    /// that job brings the tasks itself.
    private func admitTasks(_ dir: URL) -> Bool {
        guard SummaryGate.applies(
            config: env.config(), hasTranscript: SessionFiles.exists(SessionFiles.transcriptJSON, in: dir),
            hasAPIKey: env.keyStore.hasAPIKey()
        ) else { return false }
        guard !hasSummaryJob(for: dir) else { return false }
        do {
            try SessionFiles.writeMarker(SessionFiles.tasksPending, in: dir)
        } catch {
            log(dir, "tasks: could not write \(SessionFiles.tasksPending): \(error)")
            return false
        }
        add(Job(dir: dir, kind: .tasks))
        return true
    }

    private func hasSummaryJob(for dir: URL) -> Bool {
        ([current].compactMap { $0 } + queue).contains { $0.dir == dir && $0.kind == .summary }
    }

    private func add(_ job: Job) {
        // A tasks job never blocks a summary job of the same session (nor the
        // reverse): the queue is deduplicated per (session, kind).
        let duplicate = ([current].compactMap { $0 } + queue).contains { $0.dir == job.dir && $0.kind == job.kind }
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
            // A summary is what the user waits for; a backfill is bulk work, so
            // any ready summary job goes before every tasks job.
            let ready = queue.indices.filter { (queue[$0].notBefore ?? .distantPast) <= now }
            guard let index = ready.first(where: { queue[$0].kind == .summary }) ?? ready.first else {
                await waitForNextRetry(now: now)
                continue
            }
            var job = queue.remove(at: index)
            current = job
            let session = job.dir.lastPathComponent
            publish(job.kind == .tasks ? .extractingTasks(session: session, queued: queue.count) : .generating(session: session, queued: queue.count))
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
        // A tasks job waiting for its retry must not look like a summary waiting.
        publish(
            next.kind == .tasks
                ? .extractingTasks(session: next.dir.lastPathComponent, queued: queue.count - 1)
                : .waitingRetry(session: next.dir.lastPathComponent)
        )
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
        // Trashed while it waited (or between retries): drop it silently — no
        // notice, no failure state, no `didFinish`, nothing written into the path.
        guard SessionFiles.folderExists(dir) else {
            SessionFiles.logDroppedJob(job.kind == .tasks ? "tasks" : "summary", dir)
            return
        }
        if job.kind == .tasks { return await runTasks(&job) }
        let name = dir.lastPathComponent
        let started = env.now()
        log(dir, "summary start (attempt \(job.retries + 1))")
        do {
            let summary = try await attempt(&job)
            try writeSummary(summary, to: dir)
            removeMarkers(in: dir)
            let seconds = Int(env.now().timeIntervalSince(started))
            log(dir, "done in \(seconds)s")
            env.indexDidChange()
            await env.didFinish(dir)
        } catch {
            // The folder vanished mid-job (the write failed): not a failure.
            guard SessionFiles.folderExists(dir) else {
                SessionFiles.logDroppedJob("summary", dir)
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
                log(dir, "retries exhausted; summary stays pending")
                lastFailure = name
                env.notify(NoticeBuilder.stillPending(.summary, session: dir))
            case .fail:
                log(dir, "summary failed")
                lastFailure = name
                markFailed(in: dir)
                env.notify(NoticeBuilder.failed(.summary, session: dir))
                await env.didFinish(dir)
            }
        }
    }

    // MARK: - Generation

    /// What a model call returned and where it came from.
    private struct Reply {
        let raw: String
        let source: MeetingSummary.Source
        let model: String
    }

    /// Build the prompt, call the model, parse the reply. Source is minutes
    /// when `minuta.md` exists (strictly better than the raw transcript),
    /// else the transcript, chunked through `ChunkedReducer` when too long.
    /// An invalid-JSON reply gets exactly one retry with a stricter prompt.
    private func attempt(_ job: inout Job) async throws -> MeetingSummary {
        let glossary = env.config().glossary
        let reply = try await modelReply(&job, systemPrompt: SummaryPrompts.systemPrompt(glossary: glossary))

        let fields: SummaryParser.Fields
        do {
            fields = try SummaryParser.parse(reply.raw)
        } catch {
            guard !job.invalidJSONRetried else { throw error }
            job.invalidJSONRetried = true
            log(job.dir, "invalid JSON reply; retrying once with a stricter reminder")
            return try await attempt(&job)
        }

        return MeetingSummary(
            title: fields.title, summary: fields.summary, client: fields.client,
            topics: fields.topics, participants: fields.participants,
            source: reply.source, model: reply.model, generatedAt: env.now(),
            tasks: fields.tasks, country: fields.country
        )
    }

    /// Same call for the tasks-only backfill: its own system prompt and reply
    /// shape, the same source choice, chunking and one invalid-JSON retry.
    private func attemptTasks(_ job: inout Job) async throws -> SummaryParser.TasksFields {
        let glossary = env.config().glossary
        let reply = try await modelReply(&job, systemPrompt: SummaryPrompts.tareasSystemPrompt(glossary: glossary))
        do {
            return try SummaryParser.parseTasks(reply.raw)
        } catch {
            guard !job.invalidJSONRetried else { throw error }
            job.invalidJSONRetried = true
            log(job.dir, "tasks: invalid JSON reply; retrying once with a stricter reminder")
            return try await attemptTasks(&job)
        }
    }

    /// The model call shared by both job kinds: source selection, prompt
    /// assembly, single call or chunked map/reduce.
    private func modelReply(_ job: inout Job, systemPrompt base: String) async throws -> Reply {
        let dir = job.dir
        let config = env.config()
        guard let model = config.openRouterModel else { throw MinutesError.noModel }
        let apiKey = try readAPIKey()
        let name = dir.lastPathComponent
        let context = await contextLength(for: model)
        // Read now, at job time: a link written after this point reaches no
        // prompt of this run (accepted).
        let info = SessionInfo.read(from: dir)

        let source: MeetingSummary.Source
        let content: String
        var lines: [TranscriptLine] = []
        if SessionFiles.exists(SessionFiles.minutes, in: dir),
           let text = try? String(contentsOf: dir.appendingPathComponent(SessionFiles.minutes), encoding: .utf8) {
            source = .minutes
            content = text
        } else {
            source = .transcript
            let transcript: TranscriptInput
            do {
                transcript = try TranscriptInput.read(from: dir)
            } catch {
                throw MinutesError.transcriptUnreadable("\(error)")
            }
            lines = PromptBuilder.lines(from: transcript.segments, maxLineTokens: Chunker.chunkBudget(contextLength: context))
            guard !lines.isEmpty else { throw MinutesError.emptyTranscript }
            content = lines.map(\.rendered).joined(separator: "\n")
        }

        var systemPrompt = base
        if job.invalidJSONRetried { systemPrompt += "\n\n" + SummaryPrompts.recordatorioJSON }
        let userPrompt = SummaryPrompts.userPrompt(
            sessionName: name, content: content, calendarTitle: info.calendarTitle, invitees: info.invitees)
        let estimated = Chunker.estimateTokens(systemPrompt) + Chunker.estimateTokens(userPrompt)
        log(dir, "model \(model), source \(source.rawValue), ~\(estimated) tokens estimated (context \(context))")

        let deny = config.denyDataCollection
        let backend = env.backend
        let complete: ChunkedReducer.Complete = { messages, maxTokens in
            try await backend.complete(
                apiKey: apiKey, model: model, messages: messages, maxTokens: maxTokens, denyDataCollection: deny
            )
        }

        let raw: String
        let chunked = source == .transcript && Chunker.needsChunking(estimatedTokens: estimated, contextLength: context)
        if !chunked {
            raw = try await complete([.system(systemPrompt), .user(userPrompt)], Chunker.maxTokens(contextLength: context))
        } else {
            let p = ChunkedReducer.Prompting(
                info: info, finalSystem: systemPrompt,
                language: config.minutesLanguage, glossary: config.glossary,
                context: context, timeZone: env.timeZone,
                noteInstructions: SummaryPrompts.tareasNotasInstrucciones
            )
            raw = try await ChunkedReducer.run(
                lines: lines, p, notes: &job.partialNotes, plan: &job.partialPlan,
                finalMaxTokens: Chunker.maxTokens(contextLength: context),
                log: { self.log(dir, $0) }, complete
            )
        }
        return Reply(raw: raw, source: source, model: model)
    }

    // MARK: - Tasks backfill

    /// One tasks attempt, then success / re-queue / give-up bookkeeping. A
    /// backfill is bulk, invisible work: it never sets `lastFailure`, never
    /// notifies and never calls `didFinish`, so nothing that reads the summary
    /// state (pill, stepper, settlement, Hindsight readiness) can see it. A
    /// failure is only logged (`resumen.log`, "tasks:" prefix). Only a failure
    /// about the session's own content (`TasksBackfill.classify`) marks it
    /// `tareas.error`; key/model/account failures keep `tareas.pendiente`.
    private func runTasks(_ job: inout Job) async {
        let dir = job.dir
        // Re-check before spending a model call: the queue may have waited
        // for hours, and a summary job, the user or a launch may have changed
        // the session since it was queued.
        let config = env.config()
        guard SummaryGate.applies(
            config: config, hasTranscript: SessionFiles.exists(SessionFiles.transcriptJSON, in: dir),
            hasAPIKey: env.keyStore.hasAPIKey()
        ) else {
            log(dir, "tasks: skipped, the summary gate no longer applies (marker kept)")
            return
        }
        guard TasksBackfill.isCandidate(.read(dir)) else {
            log(dir, "tasks: skipped, the session is no longer a backfill candidate")
            removeTasksMarker(SessionFiles.tasksPending, in: dir)
            return
        }
        // A summary job for the session may have cleared the marker meanwhile.
        try? SessionFiles.writeMarker(SessionFiles.tasksPending, in: dir)

        let started = env.now()
        log(dir, "tasks: start (attempt \(job.retries + 1))")
        do {
            let result = try await attemptTasks(&job)
            try mergeTasks(result, into: dir)
            removeTasksMarker(SessionFiles.tasksPending, in: dir)
            removeTasksMarker(SessionFiles.tasksError, in: dir)
            log(dir, "tasks: done in \(Int(env.now().timeIntervalSince(started)))s")
            env.indexDidChange()
        } catch SummaryTasksMerge.MergeError.alreadyHasTasks {
            // Extracted by someone else while the model was working: nothing to add.
            log(dir, "tasks: resumen.json already has tasks; nothing to merge")
            removeTasksMarker(SessionFiles.tasksPending, in: dir)
        } catch {
            if TasksBackfill.classify(error) == .cancelled {
                // Not a failure of the session: keep `tareas.pendiente`, write
                // no `tareas.error`, never retry, and stop the pass.
                let dropped = queue.filter { $0.kind == .tasks }.count
                queue.removeAll { $0.kind == .tasks }
                log(dir, "tasks: cancelled, marker kept; \(dropped) queued tasks job(s) dropped until the next rebuild")
                return
            }
            log(dir, "tasks: attempt \(job.retries + 1) failed: \(error)")
            switch MinutesRetryPolicy.decide(error: error, retriesSoFar: job.retries) {
            case .retry(let delay):
                job.retries += 1
                job.notBefore = env.now().addingTimeInterval(delay)
                log(dir, "tasks: retry \(job.retries) of \(MinutesRetryPolicy.delays.count) scheduled in \(Int(delay))s")
                queue.append(job)
            case .exhausted:
                log(dir, "tasks: retries exhausted; tasks stay pending")
            case .fail:
                switch TasksBackfill.classify(error) {
                case .content:
                    log(dir, "tasks: failed for good")
                    markTasksFailed(in: dir)
                case .cancelled:
                    break  // handled before the retry policy; unreachable here
                case .environment:
                    // Key, model or account trouble says nothing about this
                    // session: keep its marker (a later rebuild or launch
                    // retries) and stop the pass instead of failing every
                    // queued job the same way.
                    let dropped = queue.filter { $0.kind == .tasks }.count
                    queue.removeAll { $0.kind == .tasks }
                    log(dir, "tasks: environment failure, marker kept; \(dropped) queued tasks job(s) dropped until the next rebuild")
                }
            }
        }
    }

    /// Merge into the file as it is NOW, not as it was when the job started:
    /// the model call can take minutes and the summary may have been
    /// regenerated meanwhile. Atomic; any other failure leaves it untouched.
    private func mergeTasks(_ result: SummaryParser.TasksFields, into dir: URL) throws {
        let url = dir.appendingPathComponent(SessionFiles.summaryJSON)
        let merged = try SummaryTasksMerge.merge(
            existing: Data(contentsOf: url), tasks: result.tasks, country: result.country
        )
        try merged.write(to: url, options: .atomic)
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

    private func writeSummary(_ summary: MeetingSummary, to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(summary).write(to: dir.appendingPathComponent(SessionFiles.summaryJSON), options: .atomic)
    }

    private func readSummary(_ dir: URL) -> MeetingSummary? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(SessionFiles.summaryJSON)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingSummary.self, from: data)
    }

    /// The model's context window from the OpenRouter catalog. Fetched once
    /// per process; an unreachable catalog or unknown model falls back to a
    /// conservative size (and the catalog is retried next job).
    private func contextLength(for model: String) async -> Int {
        if contextLengths == nil {
            do {
                let models = try await env.backend.models()
                contextLengths = Dictionary(
                    models.compactMap { m in m.contextLength.map { (m.id, $0) } },
                    uniquingKeysWith: { first, _ in first }
                )
            } catch {
                stderr("summary: model catalog unavailable (\(error)) — assuming \(Chunker.fallbackContextLength) tokens")
            }
        }
        guard let length = contextLengths?[model], length > 0 else { return Chunker.fallbackContextLength }
        return length
    }

    // MARK: - Markers

    private func removeMarkers(in dir: URL) {
        let fm = FileManager.default
        // A new summary carries its own tasks, so a backfill's markers go too.
        for name in [
            SessionFiles.summaryPending, SessionFiles.summaryError, SessionFiles.tasksPending, SessionFiles.tasksError,
        ] where SessionFiles.exists(name, in: dir) {
            do {
                try fm.removeItem(at: dir.appendingPathComponent(name))
            } catch {
                log(dir, "could not remove \(name): \(error)")
            }
        }
    }

    private func removeTasksMarker(_ name: String, in dir: URL) {
        guard SessionFiles.exists(name, in: dir) else { return }
        do {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        } catch {
            log(dir, "tasks: could not remove \(name): \(error)")
        }
    }

    /// `tareas.pendiente` → `tareas.error`: "Reconstruir índice" skips it like
    /// `resumen.error`, and a relaunch does not resume it. Nothing else changes.
    private func markTasksFailed(in dir: URL) {
        removeTasksMarker(SessionFiles.tasksPending, in: dir)
        do {
            try SessionFiles.writeMarker(SessionFiles.tasksError, in: dir)
        } catch {
            log(dir, "tasks: could not write \(SessionFiles.tasksError): \(error)")
        }
    }

    /// `resumen.pendiente` → `resumen.error`, so a relaunch doesn't retry a
    /// job that needs the user, and "Reconstruir índice" leaves it alone.
    private func markFailed(in dir: URL) {
        let fm = FileManager.default
        let pending = dir.appendingPathComponent(SessionFiles.summaryPending)
        let failed = dir.appendingPathComponent(SessionFiles.summaryError)
        do {
            if fm.fileExists(atPath: failed.path) { try fm.removeItem(at: failed) }
            if fm.fileExists(atPath: pending.path) {
                try fm.moveItem(at: pending, to: failed)
            } else {
                try SessionFiles.writeMarker(SessionFiles.summaryError, in: dir)
            }
        } catch {
            log(dir, "could not mark summary as failed: \(error)")
        }
    }

    // MARK: - Helpers

    private nonisolated func log(_ dir: URL, _ message: String) {
        SessionFiles.appendLog(message, to: SessionFiles.summaryLog, in: dir)
    }

    private func stderr(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}
