import AppKit
import Observation

/// State behind the settings window. Toggles and pickers are written to
/// config.json as soon as they change (no "Apply" button to forget); free-text
/// fields are written on submit / focus loss / window close so half-typed
/// values never land on disk. The API key is only written to the Keychain on
/// an explicit Save and is never read back into the UI.
@MainActor
@Observable
final class SettingsModel {
    enum ModelsState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    // MARK: Status

    /// Config load/write failure shown in the window's footer. Writes are
    /// refused while config.json is invalid, so this persists until fixed.
    private(set) var configError: String?
    /// config.json couldn't be read or parsed: the fields show defaults, not
    /// the user's values, so the view disables editing until a reload works.
    private(set) var configLoadFailed = false

    // MARK: OpenRouter

    /// Transient SecureField contents; cleared once saved.
    var apiKeyInput = ""
    private(set) var hasKey = false
    /// Where the key is (attributes only): the onboarding "Minutas" step
    /// offers "Migrar clave" for `.legacyOnly`.
    private(set) var keyPresence = KeyPresence.none
    private(set) var keyError: String?
    /// The legacy read (and its Keychain prompt) is in flight.
    private(set) var migratingKey = false

    /// Persisted by `commitModelID()`, not per keystroke.
    var modelID = ""
    /// The model as saved on disk (what the pipeline will use). Checkmarks
    /// and toggles read this, never a half-typed `modelID`.
    private(set) var savedModelID = ""
    private(set) var models: [OpenRouterModel] = []
    private(set) var modelsState = ModelsState.idle
    var modelSearch = ""

    private(set) var connectionResult: String?
    private(set) var connectionFailed = false
    private(set) var testingConnection = false

    // MARK: Minutes

    var minutesEnabled = false {
        didSet { save(minutesEnabled, "minutes", "enabled") }
    }
    var minutesTemplate = "general" {
        didSet { save(minutesTemplate, "minutes", "template") }
    }
    /// Persisted by `commitMinutesLanguage()`, not per keystroke.
    var minutesLanguage = ""
    private(set) var templates: [MinutesTemplate] = []

    // MARK: Summary

    var summaryEnabled = true {
        didSet { save(summaryEnabled, "summary", "enabled") }
    }

    // MARK: Recording

    private(set) var recordingsDir = ""
    /// Why the last chosen folder was refused, shown inline.
    private(set) var recordingsDirError: String?
    var micVoiceProcessing = false {
        didSet { save(micVoiceProcessing, "mic_voice_processing") }
    }
    var transcriptionEnabled = true {
        didSet { save(transcriptionEnabled, "transcription", "enabled") }
    }
    /// `recording_pill.enabled`: the floating pill while recording (prompts
    /// keep showing in its style when off).
    var recordingPillEnabled = true {
        didSet {
            updateSection("recording_pill", formatError: { $0.recordingPillFormatError }) {
                ConfigStore.set(recordingPillEnabled, at: ["enabled"], in: &$0)
            }
        }
    }

    // MARK: Meeting detection

    var meetingDetectionEnabled = true {
        didSet {
            updateMeetingDetection { ConfigStore.set(meetingDetectionEnabled, at: ["enabled"], in: &$0) }
        }
    }
    /// `meeting_detection.prompt_on_end`.
    var meetingPromptOnEnd = true {
        didSet {
            updateMeetingDetection { ConfigStore.set(meetingPromptOnEnd, at: ["prompt_on_end"], in: &$0) }
        }
    }
    /// `meeting_detection.auto_stop`: stop by itself 45 s after the end prompt
    /// shows. Off by default.
    var meetingAutoStop = false {
        didSet {
            updateMeetingDetection { ConfigStore.set(meetingAutoStop, at: ["auto_stop"], in: &$0) }
        }
    }
    /// Auto-stop is driven by the end prompt, which needs detection and
    /// `prompt_on_end`; the toggle is disabled (with a hint) otherwise.
    var autoStopAvailable: Bool { meetingDetectionEnabled && meetingPromptOnEnd }
    /// Entries of `meeting_detection.ignored_apps` as on disk.
    private(set) var ignoredApps: [String] = []
    /// `meeting_detection` on disk has an unexpected shape: the tab shows
    /// defaults and is read-only until the file is fixed by hand.
    private(set) var meetingDetectionInvalid = false
    /// A malformed `recording_pill` section: the toggle's writes are refused.
    private(set) var recordingPillInvalid = false

    // MARK: Glossary

    private(set) var glossary: [GlossaryEntry] = []
    var newTerm = ""
    /// Comma-separated mis-transcriptions for `newTerm` (optional).
    var newVariants = ""
    /// Term whose variants are being edited (the edit sheet is up), or nil.
    private(set) var editingTerm: String?
    var editingVariants = ""

    // MARK: Privacy

    var denyDataCollection = true {
        didSet { save(denyDataCollection, "openrouter", "deny_data_collection") }
    }

    // MARK: Dependencies

    @ObservationIgnored let configURL: URL
    /// Injected so tests never list (or restore into) the real templates folder.
    @ObservationIgnored let templatesDir: URL
    @ObservationIgnored private let keychain: any APIKeyStore
    @ObservationIgnored private let client: OpenRouterClient
    /// Suppresses the `didSet` writes while fields are populated from disk.
    @ObservationIgnored private var isLoading = false
    /// Last values loaded from / written to disk, so a commit without an
    /// edit doesn't rewrite the file.
    @ObservationIgnored private var committedMinutesLanguage = ""

    /// In-flight network work. Each start bumps its generation; a result
    /// whose generation is stale (window reloaded, key changed) is dropped.
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = 0
    @ObservationIgnored private var modelsTask: Task<Void, Never>?
    @ObservationIgnored private var modelsGeneration = 0

    init(
        configURL: URL = Config.path,
        templatesDir: URL = Config.templatesDir,
        keychain: any APIKeyStore = Keychain.openRouter,
        client: OpenRouterClient = OpenRouterClient()
    ) {
        self.configURL = configURL
        self.templatesDir = templatesDir
        self.keychain = keychain
        self.client = client
        reload()
    }

    // MARK: - Loading

    /// Re-read config, templates and key presence. Called every time the
    /// window opens so hand edits made while quill runs show up.
    /// `preservingKeyInput`: the onboarding window reloads each time it
    /// becomes key, and a key pasted but not yet saved must survive that.
    func reload(preservingKeyInput: Bool = false) {
        // The same window-key reload must not eat a model ID typed but not
        // yet committed (it is committed on focus loss / Continuar).
        let pendingModelID = preservingKeyInput && modelID.trimmed != savedModelID ? modelID : nil
        loadValues()
        if let pendingModelID { modelID = pendingModelID }
        recordingsDirError = nil
        if !preservingKeyInput { apiKeyInput = "" }
        refreshKeyPresence()
        keyError = nil
        cancelConnectionTest()
        // A fetch interrupted by closing the window, or one that failed
        // (e.g. offline), is retried on reopen.
        switch modelsState {
        case .loading, .failed: loadModels(force: true)
        case .idle, .loaded: break
        }
        reloadTemplates()
    }

    /// Populate the config-backed fields from disk (no writes).
    private func loadValues() {
        isLoading = true
        defer { isLoading = false }

        let raw: [String: Any]
        do {
            raw = try ConfigStore.loadRaw(at: configURL)
            configError = nil
            configLoadFailed = false
        } catch {
            raw = [:]
            FileHandle.standardError.write(Data("settings: config read failed: \(error)\n".utf8))
            configError = Textos.Ajustes.errorLeer(error.localizedDescription)
            configLoadFailed = true
        }
        let values = ConfigValues(raw: raw)

        modelID = values.openRouterModel ?? ""
        savedModelID = modelID
        minutesEnabled = values.minutesEnabled
        minutesTemplate = values.minutesTemplate
        minutesLanguage = values.minutesLanguage
        committedMinutesLanguage = minutesLanguage
        summaryEnabled = values.summaryEnabled
        recordingsDir = ConfigStore.abbreviatingHome((values.recordingsDir ?? Config.defaultRoot).path)
        micVoiceProcessing = values.micVoiceProcessing
        transcriptionEnabled = values.transcriptionEnabled
        recordingPillEnabled = values.recordingPillEnabled
        glossary = values.glossary
        meetingDetectionEnabled = values.meetingDetectionEnabled
        ignoredApps = values.meetingDetectionIgnoredApps
        meetingPromptOnEnd = values.meetingDetectionPromptOnEnd
        meetingAutoStop = values.meetingDetectionAutoStop
        denyDataCollection = values.denyDataCollection

        meetingDetectionInvalid = false
        recordingPillInvalid = false
        if let key = values.meetingDetectionFormatError {
            let error = ConfigStore.StoreError.invalidValue(configURL, key: key)
            FileHandle.standardError.write(Data("settings: config read failed: \(error)\n".utf8))
            configError = Textos.Ajustes.errorLeer(error.localizedDescription)
            meetingDetectionInvalid = true
        }
        if let key = values.recordingPillFormatError {
            let error = ConfigStore.StoreError.invalidValue(configURL, key: key)
            FileHandle.standardError.write(Data("settings: config read failed: \(error)\n".utf8))
            configError = Textos.Ajustes.errorLeer(error.localizedDescription)
            recordingPillInvalid = true
        }
    }

    /// The window closed: persist pending text edits (focus-loss may not
    /// fire) and drop any typed-but-unsaved key from memory.
    func windowDidClose() {
        commitModelID()
        commitMinutesLanguage()
        apiKeyInput = ""
    }

    func reloadTemplates() {
        templates = TemplateStore.list(in: templatesDir)
    }

    // MARK: - API key

    func saveAPIKey() {
        let key = apiKeyInput.trimmed
        guard !key.isEmpty else { return }
        cancelConnectionTest()
        do {
            try keychain.save(key)
            apiKeyInput = ""
            keyError = nil
        } catch {
            FileHandle.standardError.write(Data("settings: \(error)\n".utf8))
            keyError = error.localizedDescription
        }
        refreshKeyPresence()
    }

    func deleteAPIKey() {
        cancelConnectionTest()
        do {
            try keychain.delete()
            keyError = nil
        } catch {
            FileHandle.standardError.write(Data("settings: \(error)\n".utf8))
            keyError = error.localizedDescription
        }
        refreshKeyPresence()
    }

    /// "Migrar clave": the one place a click may raise the legacy item's
    /// "Always Allow" prompt. `MigratingKeyStore.read()` copies the legacy
    /// secret to MeetingVox's service (the legacy item stays untouched); the
    /// read runs off the main actor because the prompt is modal. A denied
    /// prompt reads as "missing", so success is judged by the presence
    /// afterwards, not by the return value. A no-op unless the key is
    /// `.legacyOnly`, so nothing prompts when there is nothing to migrate.
    func migrateLegacyKey() async {
        guard keyPresence == .legacyOnly, !migratingKey else { return }
        migratingKey = true
        defer { migratingKey = false }
        let keychain = self.keychain
        do {
            _ = try await Task.detached { try keychain.read() }.value
            refreshKeyPresence()
            keyError = keyPresence == .legacyOnly ? Textos.Onboarding.claveNoMigrada : nil
        } catch {
            FileHandle.standardError.write(Data("settings: \(error)\n".utf8))
            refreshKeyPresence()
            keyError = error.localizedDescription
        }
    }

    private func refreshKeyPresence() {
        keyPresence = keychain.presence()
        hasKey = keyPresence != .none
    }

    /// Uses the *saved* key, so a success proves what the minutes pipeline
    /// will actually use. The Keychain read runs off the main actor: it can
    /// show a modal prompt, and blocking the main run loop would freeze the
    /// menu-bar ticker and Stop during a live recording.
    func testConnection() {
        cancelConnectionTest()
        let generation = connectionGeneration
        let keychain = self.keychain
        let client = self.client
        testingConnection = true
        connectionTask = Task {
            let result: String
            let failed: Bool
            do {
                let key = try await Task.detached { try keychain.read() }.value
                if let key, !key.isEmpty {
                    result = try await client.testConnection(apiKey: key)
                    failed = false
                } else {
                    result = Textos.Ajustes.necesitaClave
                    failed = true
                }
            } catch let error as Keychain.KeychainError {
                FileHandle.standardError.write(Data("settings: \(error)\n".utf8))
                result = Textos.Ajustes.claveNoAccesible(error.status)
                failed = true
            } catch {
                result = error.localizedDescription
                failed = true
            }
            guard generation == connectionGeneration else { return }
            connectionResult = result
            connectionFailed = failed
            testingConnection = false
        }
    }

    /// Abandon any in-flight test and clear its result.
    private func cancelConnectionTest() {
        connectionTask?.cancel()
        connectionTask = nil
        connectionGeneration += 1
        testingConnection = false
        connectionResult = nil
    }

    // MARK: - Model catalog

    /// Fetch once per window lifetime unless `force` (the Reload button, or
    /// a retry on reopen), which supersedes any fetch still running.
    func loadModels(force: Bool = false) {
        guard force || modelsState == .idle else { return }
        modelsTask?.cancel()
        modelsGeneration += 1
        let generation = modelsGeneration
        let client = self.client
        modelsState = .loading
        modelsTask = Task {
            do {
                let list = try await client.listModels()
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                guard generation == modelsGeneration else { return }
                models = list
                modelsState = .loaded
            } catch {
                guard generation == modelsGeneration else { return }
                modelsState = .failed(error.localizedDescription)
            }
        }
    }

    /// A row picked from the catalog is a deliberate choice: persist now.
    func selectModel(_ id: String) {
        modelID = id
        commitModelID()
    }

    /// Persist the model ID field (submit, focus loss, window close). An
    /// empty field removes the key.
    func commitModelID() {
        let value = modelID.trimmed
        guard value != savedModelID else { return }
        if save(value.nilIfEmpty, "openrouter", "model") {
            savedModelID = value
        }
    }

    var filteredModels: [OpenRouterModel] {
        let query = modelSearch.trimmed
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Minutes

    /// Persist the language field (submit, focus loss, window close). An
    /// empty field removes the key so the default applies.
    func commitMinutesLanguage() {
        let value = minutesLanguage.trimmed
        guard value != committedMinutesLanguage else { return }
        if save(value.nilIfEmpty, "minutes", "language") {
            committedMinutesLanguage = value
        }
    }

    // MARK: - Recording

    /// Directory picker. The root is resolved once at startup, so the new
    /// folder takes effect after a restart (the UI says so).
    func chooseRecordingsDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(
            fileURLWithPath: (recordingsDir as NSString).expandingTildeInPath, isDirectory: true
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setRecordingsDir(url)
    }

    /// Persist the chosen folder (the picker's result). The running root
    /// is not touched: it applies after a restart.
    /// Refused (inline error, nothing saved) when it is not a writable
    /// folder or sits inside the app bundle (replaced on every update).
    func setRecordingsDir(_ url: URL, bundleURL: URL = Bundle.main.bundleURL) {
        if let problem = RecordingsFolderCheck.problem(url, bundleURL: bundleURL) {
            recordingsDirError = problem
            return
        }
        let path = ConfigStore.abbreviatingHome(url.path)
        if save(path, "recordings_dir") {
            recordingsDir = path
            recordingsDirError = nil
        }
    }

    // MARK: - Meeting detection

    /// Checkbox state: detected unless its rule id or one of its bundle ids
    /// is in `ignored_apps`.
    func isDetected(_ app: MeetingApp) -> Bool {
        !app.isIgnored(by: Set(ignoredApps))
    }

    /// Like the glossary, applied to the list as it is on disk now, so hand
    /// edits and entries for apps the UI doesn't list survive. Enabling
    /// removes the rule id and its bundle ids; disabling adds the rule id.
    func setDetected(_ app: MeetingApp, _ detected: Bool) {
        let written = updateMeetingDetection { section in
            var list = section["ignored_apps"] as? [Any] ?? []
            let keys = app.ignoredKeys
            list.removeAll { ($0 as? String).map { keys.contains($0.trimmed.lowercased()) } ?? false }
            if !detected { list.append(app.id) }
            section["ignored_apps"] = list
        }
        if let written {
            ignoredApps = ConfigValues(raw: written).meetingDetectionIgnoredApps
        }
    }

    /// Mutate the `meeting_detection` object as it is on disk now. A
    /// malformed section (not an object, `enabled` / `prompt_on_end` /
    /// `auto_stop` not a bool, `ignored_apps` not a list) is never replaced: the write is refused,
    /// like an invalid config.json.
    @discardableResult
    private func updateMeetingDetection(_ mutate: (inout [String: Any]) -> Void) -> [String: Any]? {
        updateSection("meeting_detection", formatError: { $0.meetingDetectionFormatError }, mutate)
    }

    /// Same refusal for any object section: never replace a malformed one.
    @discardableResult
    private func updateSection(
        _ name: String, formatError: @escaping (ConfigValues) -> String?, _ mutate: (inout [String: Any]) -> Void
    ) -> [String: Any]? {
        let url = configURL
        return update { json in
            if let key = formatError(ConfigValues(raw: json)) {
                throw ConfigStore.StoreError.invalidValue(url, key: key)
            }
            var section = json[name] as? [String: Any] ?? [:]
            mutate(&section)
            json[name] = section
        }
    }

    // MARK: - Glossary

    /// Glossary edits are applied to the array as it is on disk right now,
    /// not to the in-memory copy, so hand edits made while the window is
    /// open, malformed elements and unknown keys inside an entry survive.
    /// An entry is written as a plain string when it has no variants.
    func addTerm() {
        let term = newTerm.trimmed
        guard !term.isEmpty else { return }
        let variants = GlossaryEntry.variants(from: newVariants)
        newTerm = ""
        newVariants = ""
        mutateGlossary { list in
            if let i = list.firstIndex(where: { Self.matches($0, term) }) {
                // Existing term: merge the new variants into it.
                guard !variants.isEmpty, let existing = GlossaryEntry(json: list[i]) else { return }
                let merged = GlossaryEntry.clean(existing.variants + variants, term: existing.term)
                list[i] = Self.element(list[i], term: existing.term, variants: merged)
            } else {
                list.append(GlossaryEntry(term: term, variants: variants).jsonValue)
            }
        }
    }

    func removeTerm(_ term: String) {
        mutateGlossary { list in
            list.removeAll { Self.matches($0, term) }
        }
    }

    func beginEditing(_ entry: GlossaryEntry) {
        editingTerm = entry.term
        editingVariants = entry.variantsText
    }

    func cancelEditing() {
        editingTerm = nil
        editingVariants = ""
    }

    /// Replaces the variants of `editingTerm`. Later duplicates of the same
    /// term (merged into one row by `GlossaryEntry.parse`) are dropped, or
    /// their variants would come back.
    func saveEditing() {
        guard let term = editingTerm else { return }
        let text = editingVariants
        cancelEditing()
        mutateGlossary { list in
            guard let i = list.firstIndex(where: { Self.matches($0, term) }),
                  let existing = GlossaryEntry(json: list[i])
            else { return }
            let variants = GlossaryEntry.clean(GlossaryEntry.variants(from: text), term: existing.term)
            list[i] = Self.element(list[i], term: existing.term, variants: variants)
            for j in list.indices.reversed() where j > i && Self.matches(list[j], term) {
                list.remove(at: j)
            }
        }
    }

    /// "Corregir en la transcripción" for one row. Like the other glossary
    /// edits it works on the array as on disk: off writes
    /// `"transcript": false` (a plain string becomes an object), on removes
    /// the key and collapses the element back to a string once only `term`
    /// is left. Unknown keys inside an object survive. No-op (no write) for
    /// an unknown term or an unchanged flag.
    func setTranscript(_ term: String, _ enabled: Bool) {
        guard let current = glossary.first(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }),
              current.transcript != enabled
        else { return }
        mutateGlossary { list in
            guard let i = list.firstIndex(where: { Self.matches($0, term) }),
                  let existing = GlossaryEntry(json: list[i])
            else { return }
            var object = list[i] as? [String: Any] ?? ["term": existing.term]
            if enabled {
                object.removeValue(forKey: "transcript")
            } else {
                object["transcript"] = false
            }
            list[i] = object.keys.allSatisfy { $0 == "term" } ? existing.term : object
        }
    }

    private static func matches(_ element: Any, _ term: String) -> Bool {
        GlossaryEntry(json: element)?.term.caseInsensitiveCompare(term) == .orderedSame
    }

    /// `element` with new variants: an object keeps any keys quill doesn't
    /// know and collapses to a plain string once only `term` is left.
    private static func element(_ element: Any, term: String, variants: [String]) -> Any {
        guard var object = element as? [String: Any] else {
            return GlossaryEntry(term: term, variants: variants).jsonValue
        }
        if variants.isEmpty {
            object.removeValue(forKey: "variants")
        } else {
            object["variants"] = variants
        }
        return object.keys.allSatisfy { $0 == "term" } ? term : object
    }

    private func mutateGlossary(_ change: (inout [Any]) -> Void) {
        let written = update { json in
            var list = json["glossary"] as? [Any] ?? []
            change(&list)
            json["glossary"] = list
        }
        if let written {
            glossary = ConfigValues(raw: written).glossary
        }
    }

    // MARK: - Persistence

    /// Write one key path; nil removes the key so the default applies.
    @discardableResult
    private func save(_ value: Any?, _ path: String...) -> Bool {
        update { ConfigStore.set(value, at: path, in: &$0) } != nil
    }

    /// Load → mutate → write. On failure the fields are reverted to what is
    /// actually on disk, so the window never shows values that weren't
    /// saved. Returns the written config, or nil.
    /// Successful writes post `meetingVoxConfigDidChange` so snapshots (the
    /// meeting detector) refresh.
    private func update(_ mutate: (inout [String: Any]) throws -> Void) -> [String: Any]? {
        guard !isLoading else { return nil }
        do {
            let written = try ConfigStore.update(at: configURL, mutate)
            // Other sections still save; the malformed-section notice stays.
            if !meetingDetectionInvalid && !recordingPillInvalid { configError = nil }
            configLoadFailed = false
            NotificationCenter.default.post(name: .meetingVoxConfigDidChange, object: nil)
            return written
        } catch {
            FileHandle.standardError.write(Data("settings: config write failed: \(error)\n".utf8))
            loadValues()
            // A malformed value already shows its read error from loadValues().
            if case ConfigStore.StoreError.invalidValue = error, configError != nil { return nil }
            configError = Textos.Ajustes.errorGuardar(error.localizedDescription)
            return nil
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
