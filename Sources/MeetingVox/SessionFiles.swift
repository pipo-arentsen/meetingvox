import Foundation

/// File names inside a session folder and the filesystem queries built on
/// them. The filesystem is quill's queue and its state: these names are the
/// markers the coordinators and the menu agree on.
enum SessionFiles {
    static let meta = "meta.json"
    static let transcriptJSON = "transcript.json"
    static let transcriptMD = "transcript.md"
    static let transcribeLog = "transcribe.log"
    static let minutes = "minuta.md"
    static let minutesLog = "minuta.log"
    /// Minutes requested for this session and not finished yet. Created
    /// right after transcript.json when minutes are enabled; removed on
    /// success (or at launch with minutes disabled), renamed to
    /// `minutesError` on a non-retryable failure, kept when transient
    /// retries run out.
    static let minutesPending = "minuta.pendiente"
    static let minutesError = "minuta.error"
    /// The `minuta.md` a regeneration replaced (only the last one). Named
    /// with a dash so `templateID(ofMinutesFile:)` never reads it as a
    /// manual `minuta.<id>.md`.
    static let minutesPrevious = "minuta-anterior.md"
    /// The `on_stop` hook already ran for this session. Written atomically
    /// *before* the hook is launched, so no crash, relaunch or retry can run
    /// it a second time (see `SessionHook.runOnce`).
    static let hookRan = "hook.ejecutado"

    static let summaryJSON = "resumen.json"
    static let summaryLog = "resumen.log"
    /// Summary requested for this session and not finished yet. Mirrors
    /// `minutesPending`'s lifecycle: removed on success, renamed to
    /// `summaryError` on a non-retryable failure, kept when transient
    /// retries run out (resumed at next launch or by "Reconstruir índice").
    static let summaryPending = "resumen.pendiente"
    static let summaryError = "resumen.error"

    /// Tasks backfill of an existing `resumen.json` (`TasksBackfill`,
    /// merge-only). Own markers on purpose: settlement, Hindsight readiness,
    /// the pills and the stepper only look at `resumen.*`, so a backfill is
    /// invisible to them. `tasksPending` is kept when transient retries run
    /// out (resumed at launch or by "Reconstruir índice"); `tasksError` marks
    /// a permanent failure that a rebuild leaves alone.
    static let tasksPending = "tareas.pendiente"
    static let tasksError = "tareas.error"

    /// Last content Hindsight accepted for this session (v2: `document_id`
    /// `mv-<session>`, `content_hash`, `operation_id`, `sent_at`). A v1 file
    /// (`quill-…` ids) is legacy: ignored and replaced on the next send.
    static let hindsightSent = "hindsight.json"
    /// Hindsight rejected this content for good (409/422/other 4xx): status,
    /// short message and the rejected hash. Retried only when the hash changes.
    static let hindsightError = "hindsight.error"
    /// The user chose "No enviar a memoria": never sent while present.
    static let hindsightSkip = "hindsight.omitir"
    /// The user asked to send (or, with `{"force": true}`, to resend) this
    /// session to Hindsight. Removed after a successful send.
    static let hindsightRequested = "hindsight.solicitado"
    static let hindsightLog = "hindsight.log"

    /// The "reunión lista" notice was already claimed for this session
    /// (created with O_EXCL *before* posting, never removed): a relaunch, a
    /// resume or a concurrent evaluation cannot notify twice.
    static let readyNotified = "listo.notificado"

    /// The meeting index file, at the recordings root (not inside a session
    /// folder). Regenerated as a whole by `IndexWriter`, never edited by
    /// hand.
    static let index = "indice.md"

    /// meta.json key: template chosen for this session's automatic minutes
    /// (meeting prompt or the menu while recording). Absent = config default.
    static let metaMinutesTemplateKey = "minutes_template"

    /// meta.json key: the meeting app rule id (see `MeetingApp`) this session
    /// was started from, when it was started from the meeting prompt. Absent
    /// for manual recordings.
    static let metaMeetingAppKey = "meeting_app"

    /// meta.json key: the session's ámbito (`Ambito` raw value). Absent =
    /// "Sin clasificar". Written only from the main window.
    static let metaAmbitoKey = "ambito"

    /// meta.json key: when the recording stopped (ISO 8601), written by
    /// `RecordingSession.stop`.
    static let metaEndedKey = "ended"

    /// meta.json key: the calendar event this session was linked to
    /// (`CalendarEventRecord`, additive; absent = no link). Written once by
    /// the post-stop follow-up (never by `RecordingSession.stop`) and removed
    /// by "Quitar evento del calendario".
    static let metaCalendarEventKey = "calendar_event"

    /// Serializes every read-modify-write of a meta.json in this process:
    /// the main window (main actor) and `MinutesCoordinator.regenerate`
    /// (its own actor) can update the same file at once, and without it one
    /// write could drop the other's key.
    private static let metaLock = NSLock()

    /// The session's chosen template id from meta.json, unvalidated (the
    /// minutes coordinator checks it), or nil when absent/blank/unreadable.
    static func chosenMinutesTemplate(in dir: URL) -> String? {
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent(meta)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = (json[metaMinutesTemplateKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !id.isEmpty
        else { return nil }
        return id
    }

    /// Record the template the session's `minuta.md` was (re)generated with.
    /// Load → set one key → atomic write, so every other meta.json key
    /// survives. Throws when meta.json is missing or not a JSON object.
    /// `nil` removes the key (back to "no choice"), which is how a refused
    /// request gives the previous state back.
    static func setChosenMinutesTemplate(_ id: String?, in dir: URL) throws {
        try updateMeta(in: dir) { json in
            if let id {
                json[metaMinutesTemplateKey] = id
            } else {
                json.removeValue(forKey: metaMinutesTemplateKey)
            }
        }
    }

    /// Set the session's ámbito, or with nil remove it ("Sin clasificar").
    /// Same load → set one key → atomic write as `setChosenMinutesTemplate`,
    /// so every other key survives; throws, writing nothing, when meta.json
    /// is missing or not a JSON object.
    static func setAmbito(_ ambito: Ambito?, in dir: URL) throws {
        try updateMeta(in: dir) { json in
            if let ambito {
                json[metaAmbitoKey] = ambito.rawValue
            } else {
                json.removeValue(forKey: metaAmbitoKey)
            }
        }
    }

    /// The session's linked calendar event from meta.json; nil when the key is
    /// absent, JSON null (unlinked), malformed or meta.json is unreadable
    /// (tolerant, never throws).
    static func calendarEvent(in dir: URL) -> CalendarEventRecord? {
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent(meta)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return CalendarEventRecord(jsonObject: json[metaCalendarEventKey])
    }

    /// Link (or with nil unlink) the session's calendar event. Same load → set
    /// one key → atomic write under `metaLock` as the other setters, so every
    /// other key survives. Unlinking writes an explicit JSON `null` instead of
    /// removing the key: with `ifAbsent` an existing key (a link or that null)
    /// is never overwritten, so the post-stop follow-up cannot re-link a
    /// session the user just unlinked. Returns whether meta.json was written; throws,
    /// writing nothing, when meta.json is missing or not a JSON object.
    @discardableResult
    static func setCalendarEvent(_ record: CalendarEventRecord?, in dir: URL, ifAbsent: Bool = false) throws -> Bool {
        try updateMetaIfChanged(in: dir) { json in
            if let record {
                if ifAbsent, json[metaCalendarEventKey] != nil { return false }
                json[metaCalendarEventKey] = record.jsonObject
            } else {
                json[metaCalendarEventKey] = NSNull()
            }
            return true
        }
    }

    /// Load meta.json, apply `mutate`, write it back atomically — all under
    /// `metaLock`. Unknown keys (nested too) pass through untouched.
    private static func updateMeta(in dir: URL, _ mutate: (inout [String: Any]) -> Void) throws {
        try updateMetaIfChanged(in: dir) { json in
            mutate(&json)
            return true
        }
    }

    /// `updateMeta` where `mutate` answers whether to write (false = leave the
    /// file untouched). Returns that answer.
    @discardableResult
    private static func updateMetaIfChanged(in dir: URL, _ mutate: (inout [String: Any]) -> Bool) throws -> Bool {
        try metaLock.withLock {
            let url = dir.appendingPathComponent(meta)
            guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard mutate(&json) else { return false }
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                .write(to: url, options: .atomic)
            return true
        }
    }

    /// `minuta.<templateId>.md` — manual generations never overwrite the
    /// automatic `minuta.md`.
    static func minutes(templateID: String) -> String { "minuta.\(templateID).md" }

    /// Template id of a `minuta.<id>.md` file name, nil for anything else
    /// (including the automatic `minuta.md`).
    static func templateID(ofMinutesFile name: String) -> String? {
        guard name.hasPrefix("minuta."), name.hasSuffix(".md") else { return nil }
        let id = name.dropFirst("minuta.".count).dropLast(".md".count)
        return id.isEmpty ? nil : String(id)
    }

    // MARK: - Markers

    /// Create an empty marker atomically (temp file + rename), so a crash
    /// never leaves a half-written file that some scan misreads.
    static func writeMarker(_ name: String, in dir: URL) throws {
        try Data().write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    /// Outcome of `claim`.
    enum ClaimResult: Equatable, Sendable {
        /// This call created the marker: the caller owns the action.
        case claimed
        /// It already existed: someone else owns the action.
        case alreadyClaimed
        /// Could not create it (the `errno`): the action must not run.
        case failed(Int32)
    }

    /// Atomically create an empty marker, failing if it exists (`O_EXCL`).
    /// Unlike `writeMarker` (temp file + rename, which silently replaces),
    /// exactly one caller ever gets `.claimed`.
    static func claim(_ name: String, in dir: URL) -> ClaimResult {
        let fd = open(dir.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if fd >= 0 {
            close(fd)
            return .claimed
        }
        return errno == EEXIST ? .alreadyClaimed : .failed(errno)
    }

    /// The session folder itself is still there (it may have been moved to the
    /// Trash while a job waited). Coordinators drop a job for a missing folder
    /// instead of failing it: no notice, no failure state, no hook.
    static func folderExists(_ dir: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The one stderr line a coordinator writes when it drops a job because
    /// its folder is gone (nothing is written inside the missing folder).
    static func logDroppedJob(_ kind: String, _ dir: URL) {
        FileHandle.standardError.write(Data(
            "\(kind): session folder \(dir.lastPathComponent) no longer exists; dropping the job\n".utf8
        ))
    }

    static func exists(_ name: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    // MARK: - Session log

    /// Append `<ISO8601> message` to a per-session log file (transcribe.log,
    /// minuta.log). Best-effort: logging must never fail a job.
    static func appendLog(_ message: String, to file: String, in dir: URL) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent(file)
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    // MARK: - Scans

    /// Every entry under `root`, newest name first, without looking inside
    /// any of them. Folder names are `yyyy.MM.dd-HHmm[-N]`, so a descending
    /// numeric-aware name sort is chronological (`-10` sorts after `-2`, and a
    /// `-N` folder after its base).
    static func candidateFolders(in root: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending
        }
    }

    /// Session folders (those with meta.json) under `root`, newest first.
    static func sessions(in root: URL) -> [URL] {
        let fm = FileManager.default
        return candidateFolders(in: root).filter { fm.fileExists(atPath: $0.appendingPathComponent(meta).path) }
    }
}
