import Foundation

// MARK: - Typed view

/// Typed, defaulted view over a parsed config dictionary. Pure (no I/O), so
/// defaults are testable and live in exactly one place. Keys are snake_case
/// and grouped in nested objects like the existing `transcription`.
struct ConfigValues {
    let raw: [String: Any]

    // MARK: Recording

    /// The configured recordings root, or nil if the key is missing/empty.
    var recordingsDir: URL? {
        guard let dir = raw["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    var onStop: String? {
        guard let cmd = raw["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    var micVoiceProcessing: Bool { raw["mic_voice_processing"] as? Bool ?? false }

    // MARK: Transcription

    var transcriptionEnabled: Bool { section("transcription")["enabled"] as? Bool ?? true }

    var transcriptionEngine: String { section("transcription")["engine"] as? String ?? "parakeet" }

    // MARK: Minutes

    /// Default **off**: generating minutes sends transcript text to
    /// OpenRouter, so it must be an explicit opt-in.
    var minutesEnabled: Bool { section("minutes")["enabled"] as? Bool ?? false }

    /// Template id (filename stem in `Config.templatesDir`).
    var minutesTemplate: String { nonEmpty(section("minutes")["template"]) ?? "general" }

    static let defaultMinutesLanguage = "español"

    /// Output language for the minutes, as free text injected into the prompt.
    var minutesLanguage: String { nonEmpty(section("minutes")["language"]) ?? Self.defaultMinutesLanguage }

    // MARK: Summary

    /// Default **on** (unlike `minutesEnabled`): a short summary + the
    /// `indice.md` entry are the point of this feature, and once a model +
    /// key are configured most users want it. Because of this asymmetry, a
    /// user who only enabled minutes starts sending text for summaries too
    /// once a model and key exist; `summary.enabled: false` opts out.
    var summaryEnabled: Bool { section("summary")["enabled"] as? Bool ?? true }

    // MARK: OpenRouter

    var openRouterModel: String? { nonEmpty(section("openrouter")["model"]) }

    /// Ask OpenRouter to route only to providers that neither retain nor
    /// train on prompts. Default on — privacy is the safe default.
    var denyDataCollection: Bool {
        section("openrouter")["deny_data_collection"] as? Bool ?? true
    }

    // MARK: Meeting detection

    /// Prompt to record when a known meeting app starts using the mic.
    /// Default on: it only reads which process uses input, never audio, and
    /// never records without a click.
    var meetingDetectionEnabled: Bool { section("meeting_detection")["enabled"] as? Bool ?? true }

    /// Rule ids (`teams`, `whatsapp`, …, see `MeetingApp.all`) or bundle ids
    /// that never prompt. Non-string and blank entries are dropped.
    var meetingDetectionIgnoredApps: [String] {
        (section("meeting_detection")["ignored_apps"] as? [Any] ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// While recording, ask whether to stop once every meeting app that
    /// captured input has released it (15 s grace). Default on: it only
    /// asks, never stops by itself.
    var meetingDetectionPromptOnEnd: Bool { section("meeting_detection")["prompt_on_end"] as? Bool ?? true }

    /// While an end prompt is up, stop the recording by itself after a fixed
    /// 45 s unless the user answers. Default **off**: MeetingVox only ever
    /// stops a recording on a click unless this is switched on, and it needs
    /// `prompt_on_end` (the prompt is what starts the countdown).
    var meetingDetectionAutoStop: Bool { section("meeting_detection")["auto_stop"] as? Bool ?? false }

    /// The floating recording pill (levels, elapsed time, Detener) while a
    /// recording runs. Default on; prompts keep showing (in the pill's style)
    /// when it is off. A non-bool value counts as missing.
    var recordingPillEnabled: Bool {
        guard let value = section("recording_pill")["enabled"], !Self.isNumber(value) else { return true }
        return value as? Bool ?? true
    }

    /// Key path of the malformed `recording_pill` value (not an object, or
    /// `enabled` not a bool), else nil. The accessor falls back to on;
    /// Settings refuses to write over it, like `meetingDetectionFormatError`.
    var recordingPillFormatError: String? {
        guard let value = raw["recording_pill"] else { return nil }
        guard let section = value as? [String: Any] else { return "recording_pill" }
        if let enabled = section["enabled"], !(enabled is Bool) || Self.isNumber(enabled) {
            return "recording_pill.enabled"
        }
        return nil
    }

    /// Opt-in calendar linking (`calendar.enabled`): events are read, to name
    /// a session and give prompts context, only with this on AND the OS
    /// permission granted. Default **off**; a non-bool value counts as off.
    var calendarEnabled: Bool {
        guard let value = section("calendar")["enabled"], !Self.isNumber(value) else { return false }
        return value as? Bool ?? false
    }

    /// Key path of the malformed `calendar` value (not an object, or
    /// `enabled` not a bool), else nil. The accessor falls back to off;
    /// Settings refuses to write over it, like `recordingPillFormatError`.
    var calendarFormatError: String? {
        guard let value = raw["calendar"] else { return nil }
        guard let section = value as? [String: Any] else { return "calendar" }
        if let enabled = section["enabled"], !(enabled is Bool) || Self.isNumber(enabled) {
            return "calendar.enabled"
        }
        return nil
    }

    /// Key path of the malformed `meeting_detection` value (not an object,
    /// `enabled` / `prompt_on_end` / `auto_stop` not a bool, `ignored_apps` not a list), or nil when well
    /// formed or absent. The accessors above fall back to defaults for it;
    /// Settings refuses to write over it (see `ConfigStore.StoreError.invalidValue`).
    var meetingDetectionFormatError: String? {
        guard let value = raw["meeting_detection"] else { return nil }
        guard let section = value as? [String: Any] else { return "meeting_detection" }
        if let enabled = section["enabled"], !(enabled is Bool) || Self.isNumber(enabled) {
            return "meeting_detection.enabled"
        }
        if let promptOnEnd = section["prompt_on_end"], !(promptOnEnd is Bool) || Self.isNumber(promptOnEnd) {
            return "meeting_detection.prompt_on_end"
        }
        if let autoStop = section["auto_stop"], !(autoStop is Bool) || Self.isNumber(autoStop) {
            return "meeting_detection.auto_stop"
        }
        if let ignored = section["ignored_apps"], !(ignored is [Any]) { return "meeting_detection.ignored_apps" }
        return nil
    }

    /// JSONSerialization yields `NSNumber` for both `1` and `true`; only a
    /// CFBoolean is a real JSON bool.
    private static func isNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    /// A JSON integer ≥ 0 (not a bool, not a fraction), else nil.
    private static func nonNegativeInt(_ value: Any?) -> Int? {
        guard let value, let number = value as? NSNumber, isNumber(number) else { return nil }
        let int = number.intValue
        guard int >= 0, Double(int) == number.doubleValue else { return nil }
        return int
    }

    // MARK: Hindsight

    /// Default **off**: the integration is configured and the window/menu
    /// offer "Enviar a memoria". Nothing is sent to Hindsight without it.
    var hindsightEnabled: Bool { section("hindsight")["enabled"] as? Bool ?? false }

    /// Send every finished session on its own (from `since` on, short
    /// sessions skipped). Default **off**: the user picks what goes to
    /// memory.
    var hindsightAutoSend: Bool { section("hindsight")["auto_send"] as? Bool ?? false }

    /// `hindsight.base_url`, only when it is an http(s) URL with a host —
    /// anything else counts as missing (doctor warns, nothing is sent).
    var hindsightBaseURL: URL? {
        guard let text = nonEmpty(section("hindsight")["base_url"]),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty
        else { return nil }
        return url
    }

    var hindsightBank: String? { nonEmpty(section("hindsight")["bank"]) }

    static let defaultHindsightOwnerName = "Yo"

    /// Name that replaces the `me` speaker and names the memory's owner in
    /// the documents' `context`. Falls back to the transcript.md label.
    var hindsightOwnerName: String {
        nonEmpty(section("hindsight")["owner_name"]) ?? Self.defaultHindsightOwnerName
    }

    /// Who the mic track is, for the transcript `context` (e.g. the
    /// recorder's role). Empty = the context repeats `hindsightOwnerName`.
    var hindsightOwnerDescription: String { nonEmpty(section("hindsight")["owner_description"]) ?? "" }

    static let defaultHindsightMinWords = 150
    static let defaultHindsightMinMinutes = 2

    /// Short-session threshold: fewer words **or** fewer
    /// minutes than these. Negative, fractional or non-numeric values fall
    /// back to the defaults.
    var hindsightMinWords: Int {
        Self.nonNegativeInt(section("hindsight")["min_words"]) ?? Self.defaultHindsightMinWords
    }

    var hindsightMinMinutes: Int {
        Self.nonNegativeInt(section("hindsight")["min_minutes"]) ?? Self.defaultHindsightMinMinutes
    }

    /// Cutoff day (`yyyy-MM-dd`) for the **automatic** send only: sessions
    /// started that day or later. Nil when missing **or malformed**, and
    /// then nothing is sent automatically: a typo must never upload the
    /// whole recordings history. Manual sends ignore it.
    var hindsightSince: String? {
        guard let text = nonEmpty(section("hindsight")["since"]),
              Self.hindsightDate(fromDay: text, timeZone: TimeZone(identifier: "UTC")!) != nil
        else { return nil }
        return text
    }

    // MARK: Glossary

    /// Domain terms (with their usual mis-transcriptions) injected into the
    /// minutes and summary prompts so the LLM can fix transcription mistakes.
    /// Each element is a string or `{"term", "variants"}`; malformed and
    /// blank entries are dropped — see `GlossaryEntry.parse`.
    var glossary: [GlossaryEntry] { GlossaryEntry.parse(raw["glossary"]) }

    // MARK: Helpers

    private func section(_ key: String) -> [String: Any] {
        raw[key] as? [String: Any] ?? [:]
    }

    private func nonEmpty(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty
        else { return nil }
        return s
    }
}

extension ConfigValues {
    /// `yyyy-MM-dd` for `hindsight.since` and the session day compared with
    /// it. Strict: a string that doesn't round-trip (e.g. `2026-9-24`,
    /// `2026-02-30`) is rejected.
    private static func hindsightDayFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }

    static func hindsightDay(_ date: Date, timeZone: TimeZone) -> String {
        hindsightDayFormatter(timeZone).string(from: date)
    }

    static func hindsightDate(fromDay day: String, timeZone: TimeZone) -> Date? {
        let f = hindsightDayFormatter(timeZone)
        guard let date = f.date(from: day), f.string(from: date) == day else { return nil }
        return date
    }
}

// MARK: - Writing

/// Write path for `config.json`. Every write is load → mutate → atomic write
/// of the whole object, so keys quill doesn't know (hand-added, or from a
/// newer version) survive — including unknown keys inside nested sections.
enum ConfigStore {
    /// `description` is English for stderr; `errorDescription` is the
    /// Spanish copy shown in the settings window.
    enum StoreError: Error, CustomStringConvertible, LocalizedError {
        /// The file exists but can't be read (permissions, a directory…).
        case readFailed(URL, Error)
        /// The file exists but isn't a JSON object. Writing would clobber the
        /// user's hand edits, so we refuse and let them fix it.
        case invalidJSON(URL)
        /// A value quill is about to change has an unexpected type (e.g.
        /// `"ignored_apps": "whatsapp"`). Same policy as `invalidJSON`:
        /// refuse rather than replace the user's value.
        case invalidValue(URL, key: String)
        case writeFailed(URL, Error)

        var description: String {
            switch self {
            case .readFailed(let url, let error): "could not read \(url.path): \(error)"
            case .invalidJSON(let url): "\(url.path) is not a valid JSON object"
            case .invalidValue(let url, let key): "\(url.path): \(key) has an unexpected type"
            case .writeFailed(let url, let error): "could not write \(url.path): \(error)"
            }
        }

        var errorDescription: String? {
            switch self {
            case .readFailed(let url, _): Textos.Ajustes.configNoLegible(url.path)
            case .invalidJSON(let url): Textos.Ajustes.configInvalida(url.path)
            case .invalidValue(let url, let key): Textos.Ajustes.valorInvalido(key, url.path)
            case .writeFailed(let url, _): Textos.Ajustes.configNoEscrita(url.path)
            }
        }
    }

    /// The raw config dictionary. A missing or empty (whitespace-only) file
    /// is an empty config; an unreadable or invalid one throws rather than
    /// pretending to be empty.
    static func loadRaw(at url: URL = Config.path) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.readFailed(url, error)
        }
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [:]
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StoreError.invalidJSON(url)
        }
        return json
    }

    /// Load, apply `mutate`, and write back pretty-printed with sorted keys
    /// (stable diffs for users who keep dotfiles in git). Creates the parent
    /// directory if needed. Returns what was written. `mutate` may throw to
    /// refuse the write (nothing is written then).
    ///
    /// Symlinks are resolved first: an atomic write renames a temp file over
    /// the path, which would replace a stow/chezmoi symlink with a regular
    /// file and silently detach it from the dotfiles repo.
    @discardableResult
    static func update(at url: URL = Config.path, _ mutate: (inout [String: Any]) throws -> Void) throws -> [String: Any] {
        let target = url.resolvingSymlinksInPath()
        var json = try loadRaw(at: target)
        try mutate(&json)
        do {
            let data = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try (data + Data("\n".utf8)).write(to: target, options: .atomic)
        } catch {
            throw StoreError.writeFailed(target, error)
        }
        return json
    }

    /// Set (or, with nil, remove) the value at a nested key path, e.g.
    /// `["transcription", "enabled"]`. Sibling keys in intermediate objects
    /// are kept; a non-object in the way is replaced by an object.
    static func set(_ value: Any?, at path: [String], in json: inout [String: Any]) {
        guard let key = path.first else { return }
        if path.count == 1 {
            json[key] = value
            return
        }
        var child = json[key] as? [String: Any] ?? [:]
        set(value, at: Array(path.dropFirst()), in: &child)
        json[key] = child
    }

    /// Convenience: one value at one key path.
    static func set(_ value: Any?, at path: String..., url: URL = Config.path) throws {
        try update(at: url) { set(value, at: path, in: &$0) }
    }

    /// `/Users/me/Recordings` → `~/Recordings`, so the config stays portable
    /// across machines with different usernames. Paths outside home pass
    /// through unchanged.
    static func abbreviatingHome(
        _ path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        var home = home
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
