import Foundation

/// One session folder as the meeting index (and the main window
/// window) sees it: everything read from disk in one place, so both the
/// renderer and the window agree on what "unreadable" means. Never throws —
/// an unreadable `meta.json` or `resumen.json` degrades to nil fields rather
/// than failing the whole scan.
struct MeetingEntry: Sendable, Equatable, Identifiable {
    var id: URL { dir }

    let dir: URL
    /// From meta.json's `started`, or the folder name (`yyyy.MM.dd-HHmm[-N]`)
    /// when meta.json is missing/unreadable/missing that key. Nil only when
    /// neither source parses.
    let started: Date?
    let durationSeconds: Int?
    /// The `MeetingApp` rule id from meta.json's `meeting_app`, unvalidated
    /// (an id no longer in `MeetingApp.all` still passes through — the
    /// renderer/window fall back to showing the raw id).
    let app: String?
    let summary: MeetingSummary?
    let hasMinutes: Bool
    let hasTranscript: Bool
    /// `minuta.pendiente` on disk: an automatic minutes job requested and
    /// not yet finished (retries may have run out — it's still owed at
    /// next launch or "Reintentar minuta"). Only meaningful when
    /// `hasMinutes` is false.
    var minutesPending: Bool = false
    /// `minuta.error` on disk: the automatic job failed for good.
    var minutesFailed: Bool = false
    /// meta.json `ambito`; nil = "Sin clasificar" (also for an unknown value).
    var ambito: Ambito? = nil
    /// meta.json `ended`; nil when absent or unparsable (the list row
    /// then uses `started` + `durationSeconds`).
    var ended: Date? = nil
    /// meta.json `minutes_template`, trimmed, unvalidated — `MeetingType.of`
    /// decides whether it counts.
    var metaTemplateID: String? = nil
    /// The `template:` field of `minuta.md`'s provenance header
    /// (`MinutesCoordinator.provenance`); nil without `minuta.md` or header.
    var minutesTemplateID: String? = nil
    /// `resumen.json` / `.pendiente` / `.error` on disk, with the same
    /// precedence as `SessionSettlement.Facts` (pending > done > failed >
    /// absent). Read here, in the off-main scan, so the main window never
    /// calls `Facts.read` per row. Independent of `summary`, which is nil for
    /// a malformed `resumen.json` whose file still exists.
    var summaryState: SessionSettlement.MarkerState = .absent
    /// `resumen.json` is a readable JSON object, whether or not it decodes as a
    /// `MeetingSummary` — the tasks backfill's own notion of "has a summary".
    var summaryObjectReadable = false
    /// Its RAW object has a `tasks` key (a malformed one decodes as nil, so
    /// `summary?.tasks` cannot tell "never extracted" from "malformed").
    var summaryHasTasksKey = false
    /// `tareas.error` on disk: a tasks backfill failed for good.
    var tasksFailed = false
    /// The keys of meta.json `files` (`mic`, `system`): which tracks the
    /// session recorded. Empty when `files` is missing or malformed.
    var tracks: Set<String> = []
    /// meta.json `calendar_event` (the event this session was linked to, or
    /// nil: absent, unlinked or malformed). Written after a normal stop, so a
    /// session shows it a few seconds after it ends.
    var calendarEvent: CalendarEventRecord? = nil

    /// What "Reconstruir índice" looks at to decide whether it would extract
    /// this session's tasks (`TasksBackfill.isCandidate`), so the Tareas note
    /// counts exactly what a rebuild would queue.
    var tasksBackfillFacts: TasksBackfill.Facts {
        TasksBackfill.Facts(
            hasSummary: summaryObjectReadable, hasTasksKey: summaryHasTasksKey,
            summaryPending: summaryState == .pending, minutesPending: minutesPending, tasksError: tasksFailed
        )
    }

    /// The minutes markers with `Facts`' precedence: a pending marker wins (a
    /// retry in flight, or retries that ran out), then the output, and an
    /// error only counts without its output.
    var minutesState: SessionSettlement.MarkerState {
        if minutesPending { return .pending }
        if hasMinutes { return .done }
        if minutesFailed { return .failed }
        return .absent
    }

    private static let folderDateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func load(_ dir: URL) -> MeetingEntry {
        let meta = readJSONObject(dir.appendingPathComponent(SessionFiles.meta)) ?? [:]
        let iso = ISO8601DateFormatter()

        let started: Date?
        if let value = meta["started"] as? String, let date = iso.date(from: value) {
            started = date
        } else {
            started = dateFromFolderName(dir.lastPathComponent)
        }
        let hasMinutes = SessionFiles.exists(SessionFiles.minutes, in: dir)
        // One read of resumen.json feeds both the decoded summary and the raw-key facts.
        let summaryData = try? Data(contentsOf: dir.appendingPathComponent(SessionFiles.summaryJSON))
        let summaryObject = summaryData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

        return MeetingEntry(
            dir: dir,
            started: started,
            durationSeconds: meta["duration_seconds"] as? Int,
            app: meta[SessionFiles.metaMeetingAppKey] as? String,
            summary: summaryData.flatMap(decodeSummary),
            hasMinutes: hasMinutes,
            hasTranscript: SessionFiles.exists(SessionFiles.transcriptJSON, in: dir),
            minutesPending: SessionFiles.exists(SessionFiles.minutesPending, in: dir),
            minutesFailed: SessionFiles.exists(SessionFiles.minutesError, in: dir),
            ambito: Ambito(metaValue: meta[SessionFiles.metaAmbitoKey]),
            ended: (meta[SessionFiles.metaEndedKey] as? String).flatMap(iso.date(from:)),
            metaTemplateID: (meta[SessionFiles.metaMinutesTemplateKey] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 },
            minutesTemplateID: hasMinutes ? readMinutesHead(dir).flatMap(templateID(fromMinutesHeader:)) : nil,
            summaryState: markerState(
                output: SessionFiles.summaryJSON, pending: SessionFiles.summaryPending, error: SessionFiles.summaryError, in: dir
            ),
            summaryObjectReadable: summaryObject != nil,
            summaryHasTasksKey: summaryObject?["tasks"] != nil,
            tasksFailed: SessionFiles.exists(SessionFiles.tasksError, in: dir),
            tracks: Set((meta["files"] as? [String: Any])?.keys.map { $0 } ?? []),
            calendarEvent: CalendarEventRecord(jsonObject: meta[SessionFiles.metaCalendarEventKey])
        )
    }

    /// Same precedence as `SessionSettlement.Facts.state` (kept private
    /// there); `MeetingEntryTests` pins the two together.
    private static func markerState(output: String, pending: String, error: String, in dir: URL) -> SessionSettlement.MarkerState {
        if SessionFiles.exists(pending, in: dir) { return .pending }
        if SessionFiles.exists(output, in: dir) { return .done }
        if SessionFiles.exists(error, in: dir) { return .failed }
        return .absent
    }

    /// The `template:` field of a minutes file's first line when that line is
    /// quill's provenance header (`<!-- quill minutes · … · template: <id> ·
    /// … -->`); nil for anything else (hand-written first line, no field,
    /// blank id).
    static func templateID(fromMinutesHeader text: String) -> String? {
        guard let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              first.hasPrefix("<!-- quill minutes")
        else { return nil }
        for field in String(first).components(separatedBy: " · ") {
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("template:") else { continue }
            let id = trimmed.dropFirst("template:".count).trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : id
        }
        return nil
    }

    /// Only the start of `minuta.md`: the header is its first line, and this
    /// runs for every session on every scan.
    private static func readMinutesHead(_ dir: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: dir.appendingPathComponent(SessionFiles.minutes)) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func decodeSummary(_ data: Data) -> MeetingSummary? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingSummary.self, from: data)
    }

    /// Folder names are `yyyy.MM.dd-HHmm[-N]` (see `RecordingSession`); the
    /// optional `-N` collision suffix is ignored.
    private static func dateFromFolderName(_ name: String) -> Date? {
        let parts = name.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        return folderDateFormat.date(from: "\(parts[0])-\(parts[1])")
    }
}
