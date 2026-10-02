import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
///
/// When minutes are enabled, a finished transcript gets a `minuta.pendiente`
/// marker and is handed to the minutes pipeline, which then owns the
/// `on_stop` hook (it runs once the minutes finish). Otherwise the hook runs
/// here, right after the transcript.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    /// The session being transcribed right now (already out of `queue`).
    private var current: URL?
    private var draining = false
    private var engine: TranscriptionEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    private let config: @Sendable () -> ConfigValues
    private let makeEngine: @Sendable () -> any TranscriptionEngine
    private let minutesHandoff: (@Sendable (URL) async -> Void)?
    private let summaryHandoff: (@Sendable (URL) async -> Void)?
    private let hook: (@Sendable (URL) -> Void)?
    private let notify: @Sendable (Notice) -> Void

    /// - Parameters:
    ///   - minutesHandoff: receives sessions whose minutes were requested
    ///     (marker already written). Nil disables the minutes chain.
    ///   - summaryHandoff: receives sessions on the no-minutes branch, after
    ///     the `on_stop` hook. Sessions handed to `minutesHandoff` instead get
    ///     their summary requested by `MinutesCoordinator.onAutomaticFinished`
    ///     once minutes settle. Nil disables the summary request from here.
    ///   - hook: replaces the configured `on_stop` launch (tests).
    ///   - notify: failures only. A finished transcript posts nothing here:
    ///     the settlement notifier posts the one "reunión lista" when the
    ///     whole session is done.
    init(
        config: @escaping @Sendable () -> ConfigValues = { Config.values() },
        makeEngine: @escaping @Sendable () -> any TranscriptionEngine = { ParakeetEngine() },
        minutesHandoff: (@Sendable (URL) async -> Void)? = nil,
        summaryHandoff: (@Sendable (URL) async -> Void)? = nil,
        hook: (@Sendable (URL) -> Void)? = nil,
        notify: @escaping @Sendable (Notice) -> Void = { Notifications.shared.post($0) }
    ) {
        self.config = config
        self.makeEngine = makeEngine
        self.minutesHandoff = minutesHandoff
        self.summaryHandoff = summaryHandoff
        self.hook = hook
        self.notify = notify
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard config().transcriptionEnabled else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// "Reintentar" on a failed-transcription notice: queue the session again.
    /// Nothing happens (false) when transcription is disabled, the transcript
    /// exists already, or the session is queued or running — a second tap
    /// must not double the job. A session whose transcription failed leaves
    /// no marker, so the filesystem alone can't say "failed": the caller (the
    /// notice) is what asks.
    @discardableResult
    func retry(_ dir: URL) -> Bool {
        guard config().transcriptionEnabled, SessionFiles.folderExists(dir),
              !SessionFiles.exists(SessionFiles.transcriptJSON, in: dir),
              current != dir, !queue.contains(dir)
        else { return false }
        log(dir, "transcription retry requested")
        queue.append(dir)
        drainIfIdle()
        return true
    }

    /// The session is waiting in the queue or being transcribed right now.
    /// The filesystem cannot say this (a queued session has no marker, and a
    /// failed one looks the same), so "Mover a la papelera…" asks the actor.
    /// Paths compare standardized, so a trailing slash or `.` segment matches.
    func isQueuedOrRunning(_ dir: URL) -> Bool {
        let path = dir.standardizedFileURL.path
        if current?.standardizedFileURL.path == path { return true }
        return queue.contains { $0.standardizedFileURL.path == path }
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard config().transcriptionEnabled else { return }
        let pending = SessionFiles.sessions(in: root)
            .filter { !SessionFiles.exists(SessionFiles.transcriptJSON, in: $0) }
            .reversed()
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    /// "Aplicar glosario" (sessions menu and main window): reapply the current
    /// glossary to a finished transcript. Nil when it failed (logged).
    /// Never regenerates minutes or summaries — "Regenerar minuta" is the
    /// user's call.
    func applyGlossary(_ dir: URL) -> TranscriptGlossary.Outcome? {
        do {
            let outcome = try TranscriptGlossary.reapply(in: dir, glossary: config().glossary)
            switch outcome {
            case .unchanged:
                log(dir, "apply glossary: no change")
            case .rewritten(let replacements):
                log(dir, "apply glossary: \(replacements) replacement(s), transcript rewritten")
            }
            return outcome
        } catch {
            log(dir, "apply glossary failed: \(error)")
            return nil
        }
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            // Trashed while it waited: nothing to transcribe, nothing to report.
            guard SessionFiles.folderExists(dir) else {
                SessionFiles.logDroppedJob("transcription", dir)
                continue
            }
            current = dir
            defer { current = nil }
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                guard SessionFiles.folderExists(dir) else {
                    SessionFiles.logDroppedJob("transcription", dir)
                    continue
                }
                if let minutesHandoff, requestMinutes(for: dir) {
                    // The minutes pipeline runs the hook when it finishes.
                    await minutesHandoff(dir)
                } else {
                    runHook(for: dir)
                    if let summaryHandoff { await summaryHandoff(dir) }
                }
            } catch {
                guard SessionFiles.folderExists(dir) else {
                    SessionFiles.logDroppedJob("transcription", dir)
                    continue
                }
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notify(NoticeBuilder.failed(.transcription, session: dir))
            }
        }
        await engine?.release()
        engine = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine()

        var merged: [TranscriptDocument.Segment] = []
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map {
                TranscriptDocument.Segment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }

        // Correct the text before anything reads it (minutes,
        // summaries, on_stop, Hindsight); the original stays in text_raw.
        let corrected = TranscriptGlossary.apply(merged, glossary: config().glossary)
        let transcript = TranscriptDocument(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: corrected.segments
        )
        try transcript.write(to: dir)
        log(dir, "glossary: \(corrected.replacements) replacement(s)")
        log(dir, "done — \(merged.count) segments")
    }

    /// Write `minuta.pendiente` when minutes are enabled right now. The
    /// marker (not config at launch) is what recovery trusts, so it must
    /// exist before the job is handed over. If it can't be written the
    /// session is treated as "no minutes" and the hook runs as usual.
    private func requestMinutes(for dir: URL) -> Bool {
        guard config().minutesEnabled else { return false }
        do {
            try SessionFiles.writeMarker(SessionFiles.minutesPending, in: dir)
            log(dir, "minutes requested")
            return true
        } catch {
            log(dir, "could not write \(SessionFiles.minutesPending): \(error) — skipping minutes")
            return false
        }
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = config().transcriptionEngine
        if configured != "parakeet" {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — using parakeet\n".utf8
            ))
        }
        let engine = makeEngine()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Fires the `on_stop` hook (see `SessionHook`) after the transcript
    /// exists, or immediately after recording when transcription is disabled.
    /// Sessions with minutes requested get it from `MinutesCoordinator`.
    /// Guarded by `SessionHook.runOnce`, like the minutes side.
    private func runHook(for dir: URL) {
        let command = config().onStop
        SessionHook.runOnce(for: dir, log: { log(dir, $0) }) {
            if let hook {
                hook(dir)
            } else if let error = SessionHook.run(command: command, dir: dir) {
                log(dir, "on_stop hook failed to launch: \(error)")
            }
        }
    }

    private func log(_ dir: URL, _ message: String) {
        SessionFiles.appendLog(message, to: SessionFiles.transcribeLog, in: dir)
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent(SessionFiles.meta)
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks)
    }
}
