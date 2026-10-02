import Foundation

/// Optional user config at ~/.config/meetingvox/config.json (copied once from ~/.config/quill by
/// `ConfigMigration`, which `MeetingVoxMain` runs before anything reads this):
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook",
///       "minutes": { "enabled": false, "template": "general", "language": "español" },
///       "openrouter": { "model": "…", "deny_data_collection": true },
///       "glossary": ["Kubernetes", { "term": "MeetingVox", "variants": ["miting vox"] }],
///       "meeting_detection": { "enabled": true, "ignored_apps": ["whatsapp"], "prompt_on_end": true },
///       "hindsight": { "enabled": false, "auto_send": false, "base_url": "http://localhost:8888",
///                      "bank": "meetingvox", "owner_name": "",
///                      "owner_description": "", "since": "2026-09-24",
///                      "min_words": 150, "min_minutes": 2 }
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the minutes finish (success or final
/// failure) when minutes were requested for that session, otherwise after
/// the transcript is written, or right after recording when transcription
/// is disabled.
///
/// Reads go through `ConfigValues` (defaults live there, in one place);
/// writes go through `ConfigStore`, which preserves keys it doesn't know.
/// The OpenRouter API key and the Hindsight token are never stored here — see `Keychain`.
enum Config {
    /// A lazy static: the first access fixes it, so nothing may read `Config`
    /// before `MeetingVoxMain` has run the migration.
    static let path = AppIdentity.configDir(home: FileManager.default.homeDirectoryForCurrentUser)
        .appendingPathComponent("config.json")

    /// User-editable minutes templates (`<id>.md`). Lives next to the config
    /// file so everything the user customizes sits under one directory.
    static let templatesDir = path.deletingLastPathComponent()
        .appendingPathComponent("plantillas", isDirectory: true)

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? { values().recordingsDir }

    /// Shell command to spawn when a session is finished (see the type doc
    /// for when exactly), or nil.
    static func onStop() -> String? { values().onStop }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool { values().transcriptionEnabled }

    /// Configured engine name. Only "parakeet" ships today; the coordinator
    /// warns and falls back for anything else.
    static func transcriptionEngine() -> String { values().transcriptionEngine }

    /// See `ConfigValues.micVoiceProcessing`.
    static func micVoiceProcessing() -> Bool { values().micVoiceProcessing }

    /// See `ConfigValues.minutesEnabled`.
    static func minutesEnabled() -> Bool { values().minutesEnabled }

    /// See `ConfigValues.minutesTemplate`.
    static func minutesTemplate() -> String { values().minutesTemplate }

    /// See `ConfigValues.minutesLanguage`.
    static func minutesLanguage() -> String { values().minutesLanguage }

    /// See `ConfigValues.summaryEnabled`.
    static func summaryEnabled() -> Bool { values().summaryEnabled }

    /// See `ConfigValues.openRouterModel`.
    static func openRouterModel() -> String? { values().openRouterModel }

    /// See `ConfigValues.denyDataCollection`.
    static func denyDataCollection() -> Bool { values().denyDataCollection }

    /// See `ConfigValues.meetingDetectionEnabled`.
    static func meetingDetectionEnabled() -> Bool { values().meetingDetectionEnabled }

    /// See `ConfigValues.glossary`.
    static func glossary() -> [GlossaryEntry] { values().glossary }

    /// Fresh typed view of the file. Re-parsed on every call on purpose: the
    /// settings window and hand edits change the file while quill runs, and
    /// the file is tiny.
    static func values() -> ConfigValues { ConfigValues(raw: load() ?? [:]) }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
