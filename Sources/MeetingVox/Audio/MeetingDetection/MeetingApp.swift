import Foundation

// MARK: - Known meeting apps

/// One app whose microphone use means "probably a meeting". Matching is by
/// bundle id: exact, or a `<id>.` prefix so Chromium/Electron helper
/// processes (`com.brave.Browser.helper`, …) — which report their own bundle
/// id to Core Audio — count as their app. Extend `all` to add apps.
///
/// Brand names (`name`) stay literal; only generic copy goes through `Textos`.
struct MeetingApp: Sendable, Equatable, Identifiable {
    /// Stable id stored in `meeting_detection.ignored_apps`.
    let id: String
    /// App name for the settings list.
    let name: String
    /// Prompt label ("Reunión Teams"); the panel title adds "detectada".
    let label: String
    /// End-panel title ("La reunión de Teams terminó"). Its own string, not
    /// derived from `label`: the article and preposition differ per app.
    let endedTitle: String
    /// How a list row names the app ("Teams"). Explicit per rule, so the
    /// row never depends on the shape of `label`'s Spanish wording.
    let shortName: String
    let bundleIDs: [String]
    /// Continuous input use required before prompting.
    var threshold: TimeInterval = defaultThreshold

    static let defaultThreshold: TimeInterval = 3

    private static func browser(id: String, name: String, bundleID: String) -> MeetingApp {
        MeetingApp(
            id: id, name: name, label: Textos.Reuniones.navegador(name),
            endedTitle: Textos.Reuniones.navegadorTermino(name), shortName: name, bundleIDs: [bundleID])
    }

    static let teams = MeetingApp(
        id: "teams", name: "Microsoft Teams", label: Textos.Reuniones.teams,
        endedTitle: Textos.Reuniones.teamsTermino, shortName: Textos.Reuniones.teamsCorto,
        bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"])
    static let zoom = MeetingApp(
        id: "zoom", name: "Zoom", label: Textos.Reuniones.zoom, endedTitle: Textos.Reuniones.zoomTermino,
        shortName: Textos.Reuniones.zoomCorto, bundleIDs: ["us.zoom.xos"])
    /// Longer threshold: recording a voice note also opens the mic.
    static let whatsApp = MeetingApp(
        id: "whatsapp", name: "WhatsApp", label: Textos.Reuniones.whatsApp,
        endedTitle: Textos.Reuniones.whatsAppTermino, shortName: Textos.Reuniones.whatsAppCorto,
        bundleIDs: ["net.whatsapp.WhatsApp"], threshold: 8)
    static let browserOS = browser(id: "browseros", name: "BrowserOS", bundleID: "com.browseros.BrowserOS")
    static let brave = browser(id: "brave", name: "Brave", bundleID: "com.brave.Browser")
    static let safari = browser(id: "safari", name: "Safari", bundleID: "com.apple.Safari")
    /// A WebKit capture process (`com.apple.WebKit.GPU`, …) whose owning app
    /// couldn't be resolved: almost always Safari, but we can't say which.
    static let webKit = MeetingApp(
        id: "webkit", name: Textos.Reuniones.otroNavegador, label: Textos.Reuniones.navegadorGenerico,
        endedTitle: Textos.Reuniones.navegadorGenericoTermino, shortName: Textos.Reuniones.navegadorGenericoCorto,
        bundleIDs: ["com.apple.WebKit"])

    /// Every rule, in settings-list order.
    static let all: [MeetingApp] = [teams, zoom, whatsApp, browserOS, brave, safari, webKit]

    /// Rules tried against a single bundle id (WebKit is only a last resort,
    /// see `resolve`).
    private static let specific: [MeetingApp] = all.filter { $0 != webKit }

    func matches(_ bundleID: String) -> Bool {
        let candidate = bundleID.lowercased()
        return bundleIDs.contains { id in
            let id = id.lowercased()
            return candidate == id || candidate.hasPrefix(id + ".")
        }
    }

    /// The rule for a process: its own bundle id first (covers helpers with
    /// prefixed ids), then the app that owns it. The generic WebKit rule
    /// applies only when the owning app couldn't be resolved — an app that
    /// embeds a WKWebView and resolved to itself is not a browser call.
    /// Nil = not a meeting app (ignored).
    static func resolve(_ identity: ProcessIdentity) -> MeetingApp? {
        let ids = [identity.bundleID, identity.appBundleID].compactMap { $0 }
        for id in ids {
            if let app = specific.first(where: { $0.matches(id) }) { return app }
        }
        guard identity.appBundleID == nil, let own = identity.bundleID else { return nil }
        return webKit.matches(own) ? webKit : nil
    }

    /// `ignored_apps` names this rule by id or by one of its bundle ids.
    func isIgnored(by ignored: Set<String>) -> Bool {
        ignoredKeys.contains { key in ignored.contains { $0.lowercased() == key } }
    }

    /// Lowercased keys that name this rule in `ignored_apps`.
    var ignoredKeys: Set<String> { Set(([id] + bundleIDs).map { $0.lowercased() }) }
}

// MARK: - Process identity

/// A process with audio input running, as Core Audio reports it plus the app
/// it belongs to. Only identity — quill never reads anyone else's audio.
struct ProcessIdentity: Sendable, Equatable {
    let pid: pid_t
    /// `kAudioProcessPropertyBundleID` (a helper reports its own id).
    let bundleID: String?
    /// The owning app's bundle id (see `AppResolver`), when it differs or
    /// Core Audio gave none.
    let appBundleID: String?
}

// MARK: - Config snapshot

/// The config the detector and its panel need, read once (startup, after a
/// Settings change, after a recording) instead of on every event.
struct MeetingDetectionConfig: Sendable, Equatable {
    var enabled = true
    /// Rule ids or bundle ids from `meeting_detection.ignored_apps`.
    var ignored: Set<String> = []
    /// `meeting_detection.prompt_on_end`: while recording, ask to stop when
    /// the meeting apps release the input (needs `enabled` too).
    var promptOnEnd = true
    /// `meeting_detection.auto_stop`: the end prompt's countdown stops the
    /// recording by itself. A snapshot field only: the machines never read it,
    /// the pill controller does.
    var autoStop = false
    /// Auto-stop only counts down from an end prompt, so it needs `promptOnEnd`.
    var autoStopActive: Bool { promptOnEnd && autoStop }
    /// Minutes on: the pill offers the template picker.
    var minutesEnabled = false
    var minutesTemplate = "general"
    /// `meeting_detection` is malformed (English, for stderr): the fields
    /// above are the defaults.
    var formatError: String?

    init(enabled: Bool = true, ignored: Set<String> = [], promptOnEnd: Bool = true,
         autoStop: Bool = false, minutesEnabled: Bool = false, minutesTemplate: String = "general") {
        self.enabled = enabled
        self.ignored = ignored
        self.promptOnEnd = promptOnEnd
        self.autoStop = autoStop
        self.minutesEnabled = minutesEnabled
        self.minutesTemplate = minutesTemplate
    }

    init(_ values: ConfigValues) {
        minutesEnabled = values.minutesEnabled
        minutesTemplate = values.minutesTemplate
        if let error = values.meetingDetectionFormatError {
            formatError = error
            return
        }
        enabled = values.meetingDetectionEnabled
        ignored = Set(values.meetingDetectionIgnoredApps)
        promptOnEnd = values.meetingDetectionPromptOnEnd
        autoStop = values.meetingDetectionAutoStop
    }
}
