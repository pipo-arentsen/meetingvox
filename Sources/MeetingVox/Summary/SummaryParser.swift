import Foundation

/// `resumen.json`'s schema. `source`, `model` and `generated_at` are set by
/// `SummaryCoordinator`, never by the model — `SummaryParser` only produces
/// the model-supplied `Fields`.
struct MeetingSummary: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable {
        case minutes
        case transcript
    }

    let title: String
    let summary: String
    let client: String?
    let topics: [String]
    let participants: [String]
    let source: Source
    let model: String
    let generatedAt: Date
    /// Action items. `nil` (key absent) = never extracted, which makes the
    /// session a backfill candidate; `[]` = extracted, none found.
    let tasks: [MeetingTask]?
    /// The client's country, only when the meeting says it explicitly.
    let country: String?

    private enum CodingKeys: String, CodingKey {
        case title, summary, client, topics, participants, source, model, tasks, country
        case generatedAt = "generated_at"
    }

    /// Custom encode: the schema is `client: string|null`, so a missing
    /// client is written as explicit JSON `null` rather than an omitted key
    /// (the compiler-synthesized `Encodable` would use `encodeIfPresent`
    /// and drop the key entirely). Decoding stays tolerant of either shape
    /// via the synthesized-equivalent `init(from:)` below.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encode(client, forKey: .client)
        try container.encode(topics, forKey: .topics)
        try container.encode(participants, forKey: .participants)
        try container.encode(source, forKey: .source)
        try container.encode(model, forKey: .model)
        try container.encode(generatedAt, forKey: .generatedAt)
        // Absent, not null: an absent `tasks` is what marks "never extracted".
        try container.encodeIfPresent(tasks, forKey: .tasks)
        try container.encodeIfPresent(country, forKey: .country)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        client = try container.decodeIfPresent(String.self, forKey: .client)
        topics = try container.decode([String].self, forKey: .topics)
        participants = try container.decode([String].self, forKey: .participants)
        source = try container.decode(Source.self, forKey: .source)
        model = try container.decode(String.self, forKey: .model)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        // A malformed `tasks`/`country` must never cost the whole summary.
        tasks = (try? container.decodeIfPresent([MeetingTask].self, forKey: .tasks)) ?? nil
        country = (try? container.decodeIfPresent(String.self, forKey: .country)) ?? nil
    }

    init(
        title: String, summary: String, client: String?, topics: [String], participants: [String],
        source: Source, model: String, generatedAt: Date,
        tasks: [MeetingTask]? = nil, country: String? = nil
    ) {
        self.title = title
        self.summary = summary
        self.client = client
        self.topics = topics
        self.participants = participants
        self.source = source
        self.model = model
        self.generatedAt = generatedAt
        self.tasks = tasks
        self.country = country
    }
}

/// Failures parsing the model's summary reply. Not an `OpenRouterError`, so
/// `MinutesRetryPolicy.decide` treats it as non-retryable — the coordinator
/// gives it its own one-shot retry with a stricter prompt instead.
enum SummaryError: Error, CustomStringConvertible, Equatable {
    case invalidJSON(String)

    var description: String {
        switch self {
        case .invalidJSON(let snippet): "model reply is not valid JSON: \(snippet)"
        }
    }
}

/// Pure parsing of the model's summary reply into clamped, validated fields.
/// The model is asked to reply with only a JSON object, but real replies
/// sometimes wrap it in a fenced code block or a sentence of prose — both are
/// tolerated.
enum SummaryParser {
    struct Fields: Sendable, Equatable {
        let title: String
        let summary: String
        let client: String?
        let topics: [String]
        let participants: [String]
        /// nil = the reply had no usable `tasks` array (never extracted).
        let tasks: [MeetingTask]?
        let country: String?
    }

    /// The reply of a tasks-only (backfill) request.
    struct TasksFields: Sendable, Equatable {
        let tasks: [MeetingTask]
        let country: String?
    }

    static let maxTitleCharacters = 80
    static let maxClientCharacters = 80
    static let maxSummaryLines = 2
    static let maxSummaryCharacters = 280
    static let maxTopics = 5
    static let maxTopicCharacters = 40
    static let maxParticipants = 10
    static let maxTasks = 20
    static let maxTaskWhatCharacters = 200
    static let maxTaskWhoCharacters = 60
    static let maxTaskWhenCharacters = 40
    static let maxCountryCharacters = 40

    static func parse(_ text: String) throws -> Fields {
        let candidate = extractJSONObject(from: text) ?? text
        guard
            let data = candidate.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SummaryError.invalidJSON(snippet(of: text))
        }
        guard
            let rawTitle = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawTitle.isEmpty
        else {
            throw SummaryError.invalidJSON(snippet(of: text))
        }
        guard
            let rawSummary = (json["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawSummary.isEmpty
        else {
            throw SummaryError.invalidJSON(snippet(of: text))
        }

        let client = (json["client"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Fields(
            title: String(rawTitle.prefix(maxTitleCharacters)),
            summary: clampSummary(rawSummary),
            client: (client?.isEmpty ?? true) ? nil : client.map { String($0.prefix(maxClientCharacters)) },
            topics: dedupedTopics(json["topics"] as? [Any] ?? []),
            participants: cleanedList(json["participants"] as? [Any] ?? [], limit: maxParticipants),
            tasks: (json["tasks"] as? [Any]).map(cleanedTasks),
            country: cleanedField(json["country"], limit: maxCountryCharacters)
        )
    }

    /// Reply of the tasks-only request: a `tasks` array is required (an empty
    /// one is a valid "none"), `country` is optional.
    static func parseTasks(_ text: String) throws -> TasksFields {
        let candidate = extractJSONObject(from: text) ?? text
        guard
            let data = candidate.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawTasks = json["tasks"] as? [Any]
        else {
            throw SummaryError.invalidJSON(snippet(of: text))
        }
        return TasksFields(
            tasks: cleanedTasks(rawTasks),
            country: cleanedField(json["country"], limit: maxCountryCharacters)
        )
    }

    /// Drop entries without a `what`, blank `who`/`when` become nil, clamp
    /// every field, cap the count.
    private static func cleanedTasks(_ raw: [Any]) -> [MeetingTask] {
        var result: [MeetingTask] = []
        for item in raw {
            guard
                let object = item as? [String: Any],
                let what = cleanedField(object["what"], limit: maxTaskWhatCharacters)
            else { continue }
            result.append(MeetingTask(
                who: cleanedField(object["who"], limit: maxTaskWhoCharacters), what: what,
                when: cleanedField(object["when"], limit: maxTaskWhenCharacters)
            ))
            if result.count == maxTasks { break }
        }
        return result
    }

    /// Trimmed, capped string; nil when missing, not a string, or blank.
    private static func cleanedField(_ value: Any?, limit: Int) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return String(s.prefix(limit))
    }

    /// A fenced ` ```json … ``` ` block if present, else the first `{…}`
    /// span in the text (tolerates a sentence of prose around the JSON).
    private static func extractJSONObject(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fenced = fencedJSON(in: trimmed) { return fenced }
        guard
            let open = trimmed.firstIndex(of: "{"),
            let close = trimmed.lastIndex(of: "}"),
            open < close
        else { return nil }
        return String(trimmed[open...close])
    }

    private static func fencedJSON(in text: String) -> String? {
        guard let startRange = text.range(of: "```") else { return nil }
        var afterFence = text[startRange.upperBound...]
        if afterFence.hasPrefix("json") { afterFence = afterFence.dropFirst(4) }
        guard let endRange = afterFence.range(of: "```") else { return nil }
        return String(afterFence[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keep at most `maxSummaryLines` lines, then cap the total length.
    private static func clampSummary(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").prefix(maxSummaryLines).joined(separator: "\n")
        return String(lines.prefix(maxSummaryCharacters))
    }

    /// Trim, drop blanks, cap each entry's length, dedupe case-insensitively
    /// (first occurrence wins), cap the count.
    private static func dedupedTopics(_ raw: [Any]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in raw {
            guard
                let s = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
            else { continue }
            let capped = String(s.prefix(maxTopicCharacters))
            guard seen.insert(capped.lowercased()).inserted else { continue }
            result.append(capped)
            if result.count == maxTopics { break }
        }
        return result
    }

    private static func cleanedList(_ raw: [Any], limit: Int) -> [String] {
        Array(
            raw.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(limit)
        )
    }

    private static func snippet(of text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }
}
