import Foundation

/// Every dependency the headless snapshots need, built explicitly from one
/// temp root (VS-1, VS-2): the recordings root, a fake `config.json` and its
/// typed view, a templates folder holding the factory templates, a key store
/// with no key, a fixed clock, calendar and time zone. Nothing is defaulted
/// to `Config`, the Keychain or the home directory, so a render can neither
/// read nor write the real ones; `SnapshotHomeGuardTests` enforces both the
/// URLs and the source text.
struct SnapshotEnvironment {
    /// Fixed offset (UTC-3, Chile in spring) instead of a named zone: the
    /// same wall-clock on every machine and no tz-database dependency.
    static let timeZone = TimeZone(secondsFromGMT: -3 * 3600)!
    static let locale = Locale(identifier: "es_CL")

    /// The fixture "now": Tuesday 29 September 2026, 11:00 local.
    static func fixedNow() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 11, minute: 0))!
    }

    struct RefusedRoot: Error, CustomStringConvertible {
        let path: String
        var description: String { "refusing to use \(path): the snapshot temp root must not be inside the real home" }
    }

    let tempRoot: URL
    /// The fixture recordings root (what `MeetingsModel` scans).
    let recordingsRoot: URL
    let configURL: URL
    let templatesDir: URL
    let timeZone: TimeZone
    let calendar: Calendar
    let now: Date
    let keyStore: SnapshotKeyStore
    /// The typed view of the fake `config.json`, as written.
    let config: ConfigValues

    /// Every URL the environment exposes; the guard tests assert they all sit
    /// under `tempRoot`.
    var urls: [URL] { [tempRoot, recordingsRoot, configURL, templatesDir] }

    /// What `HindsightFacts.read` needs (owner, glossary, zone).
    var hindsightOptions: HindsightFacts.Options { HindsightFacts.Options(config: config, timeZone: timeZone) }
    var hindsightSettings: HindsightStatus.Settings { HindsightStatus.Settings(config: config) }

    /// Creates the folders, writes the fake config and installs the factory
    /// templates, all under `tempRoot`.
    ///
    /// - Parameter home: when given, a `tempRoot` inside it is refused before
    ///   anything is created (the diag route passes the real home; this file
    ///   does not look it up on purpose).
    static func make(tempRoot: URL, home: URL? = nil) throws -> SnapshotEnvironment {
        let root = tempRoot.standardizedFileURL
        if let home {
            let base = home.resolvingSymlinksInPath().standardizedFileURL.path
            let path = root.resolvingSymlinksInPath().standardizedFileURL.path
            if path == base || path.hasPrefix(base + "/") { throw RefusedRoot(path: root.path) }
        }
        let fm = FileManager.default
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        let configDir = root.appendingPathComponent("config", isDirectory: true)
        let templates = configDir.appendingPathComponent("plantillas", isDirectory: true)
        let configURL = configDir.appendingPathComponent("config.json")
        for dir in [recordings, configDir] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try TemplateStore.installFactoryTemplatesIfMissing(in: templates)

        let raw = configJSON(recordingsRoot: recordings)
        try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]).write(to: configURL)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return SnapshotEnvironment(
            tempRoot: root, recordingsRoot: recordings, configURL: configURL, templatesDir: templates,
            timeZone: timeZone, calendar: calendar, now: fixedNow(), keyStore: SnapshotKeyStore(),
            config: ConfigValues(raw: raw)
        )
    }

    /// A realistic configuration: minutes on with the commercial template,
    /// summaries on, memory integration configured (manual sends).
    private static func configJSON(recordingsRoot: URL) -> [String: Any] {
        [
            "recordings_dir": recordingsRoot.path,
            "transcription": ["enabled": true, "engine": "parakeet"],
            "minutes": ["enabled": true, "template": "general", "language": "español"],
            "summary": ["enabled": true],
            "openrouter": ["model": "provider/model", "deny_data_collection": true],
            "glossary": [
                ["term": "MeetingVox", "variants": ["miting vox", "mitin vox"]],
                "Grafana",
            ],
            "hindsight": [
                "enabled": true, "auto_send": false, "base_url": "http://localhost:8888", "bank": "meetingvox",
                "owner_name": "Usuario", "owner_description": "quien grabó la reunión",
                "min_words": 150, "min_minutes": 2,
            ],
        ]
    }

    /// The settings model the Glosario page edits: the fake `config.json`, the
    /// temp templates folder and the key store that holds nothing.
    @MainActor
    func makeSettingsModel() -> SettingsModel {
        SettingsModel(configURL: configURL, templatesDir: templatesDir, keychain: keyStore)
    }

    /// Biblioteca's editors over the temp folder. Nothing is listed yet:
    /// the states select a page (`LibraryModel.refresh(for:)`) like the window does.
    @MainActor
    func makeLibraryModel() -> LibraryModel {
        LibraryModel(templates: TemplateEditorModel(dir: templatesDir), glossary: makeSettingsModel())
    }

    /// A list engine over the fixture root with every input explicit (no
    /// `Config.values()` default, no real clock).
    @MainActor
    func makeMeetingsModel() -> MeetingsModel {
        let config = self.config
        let now = self.now
        return MeetingsModel(
            root: recordingsRoot, calendar: calendar, now: { now }, config: { config }, hindsightAuthPaused: { false }
        )
    }
}

extension SnapshotEnvironment {
    /// The main window's model over the fixture root (or another folder under
    /// the temp root, for the empty state), with the fixed clock and zone.
    /// `library` swaps Biblioteca's editors for ones over a folder of their own.
    /// Nothing is loaded yet: `SnapshotEnvironment.load` scans it.
    @MainActor
    func makeMainWindowModel(
        store: PipelineStatusStore = PipelineStatusStore(), root: URL? = nil, library: LibraryModel? = nil,
        playback: PlaybackController? = nil, playbackTracks: [PlaybackTrackInfo]? = nil
    ) -> MainWindowModel {
        let config = self.config
        let now = self.now
        let meetings = MeetingsModel(
            root: root ?? recordingsRoot, calendar: calendar, now: { now }, config: { config },
            hindsightAuthPaused: { false }
        )
        meetings.listTemplates = { [templatesDir] in TemplateStore.list(in: templatesDir) }
        meetings.defaultBank = { [config] in config.hindsightBank }
        // The detail reads the fixture folder with the fixture's own options:
        // memory facts on, summaries possible, minutes possible.
        let inputs = SessionDetailInputs(
            options: hindsightOptions, summaryApplies: true, minutesUnavailableReason: nil,
            defaultTemplateID: config.minutesTemplate
        )
        // The fixtures have no audio files: a state that draws the player
        // hands it fake tracks instead of what `SessionTracks` finds on disk.
        let session = SessionDetailModel(inputs: { inputs }, load: { dir, inputs, previous in
            var data = SessionDetailData.load(dir, inputs, reusing: previous)
            if let playbackTracks { data.playbackTracks = playbackTracks }
            return data
        })
        return MainWindowModel(
            meetings: meetings, store: store, calendar: calendar, now: { now },
            session: session, library: library ?? makeLibraryModel(), playback: playback
        )
    }

    /// Reads the selected session's detail data, turning the run loop until
    /// it publishes (bounded, like `load`).
    @MainActor
    static func loadDetail(_ model: MainWindowModel, timeout: TimeInterval = 20) {
        guard let dir = model.meetings.selectedVisible.first else { return }
        let task = model.session.select(dir)
        var finished = false
        Task { @MainActor in
            await task.value
            finished = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !finished, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Scans synchronously from the harness's point of view: the scan is an
    /// async task on the main actor, so the run loop is turned until it
    /// publishes (bounded, so a hang cannot stall the diag).
    @MainActor
    static func load(_ model: MainWindowModel, timeout: TimeInterval = 20) {
        let task = model.reload()
        var finished = false
        Task { @MainActor in
            await task.value
            await model.meetings.factsTask?.value
            finished = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !finished, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Types `query` into the list search and turns the run loop until the
    /// debounced full-text answer for it has published (bounded).
    @MainActor
    static func search(_ model: MainWindowModel, _ query: String, timeout: TimeInterval = 20) {
        model.meetings.query = query
        let deadline = Date().addingTimeInterval(timeout)
        while !model.meetings.searchAnswered, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
