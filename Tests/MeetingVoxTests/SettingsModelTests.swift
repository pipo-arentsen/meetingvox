import Foundation
import Testing
@testable import MeetingVox

/// In-memory stand-in for the login keychain.
private final class FakeKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secret: String?

    func hasAPIKey() -> Bool { lock.withLock { secret != nil } }
    func read() throws -> String? { lock.withLock { secret } }
    func save(_ secret: String) throws { lock.withLock { self.secret = secret } }
    func delete() throws { lock.withLock { secret = nil } }
}

/// A key store that starts with the key only under the legacy service. `read()`
/// stands in for `MigratingKeyStore.read()`: it copies forward (presence becomes
/// `.primary`), or, when the legacy ACL prompt is denied, finds nothing / throws.
private final class LegacyOnlyStore: APIKeyStore, @unchecked Sendable {
    enum Outcome { case copies, deniedAsMissing, throwsError }
    struct Denied: Error {}

    private let lock = NSLock()
    private var current: KeyPresence
    private let outcome: Outcome
    private var _reads = 0
    private var _presenceCalls = 0

    init(_ presence: KeyPresence = .legacyOnly, outcome: Outcome = .copies) {
        current = presence
        self.outcome = outcome
    }

    var reads: Int { lock.withLock { _reads } }

    func hasAPIKey() -> Bool { lock.withLock { current != .none } }
    func presence() -> KeyPresence { lock.withLock { current } }
    func read() throws -> String? {
        try lock.withLock {
            _reads += 1
            switch outcome {
            case .copies:
                current = .primary
                return "sk-legacy"
            case .deniedAsMissing: return nil
            case .throwsError: throw Denied()
            }
        }
    }
    func save(_ secret: String) throws { lock.withLock { current = .primary } }
    func delete() throws { lock.withLock { current = .none } }
}

@MainActor
@Suite final class SettingsModelTests {
    let root: URL
    let url: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-settings-\(UUID().uuidString)", isDirectory: true)
        url = root.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // Undo the read-only permission some tests set, then clean up.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: url)
    }

    private func readJSON() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func makeModel() -> SettingsModel {
        SettingsModel(configURL: url, templatesDir: root, keychain: FakeKeyStore())
    }

    @Test func reloadDoesNotWrite() throws {
        let text = "{\"minutes\":{\"enabled\":true},\"openrouter\":{\"model\":\"a/b\"}}"
        try write(text)
        let model = makeModel()
        model.reload()
        model.windowDidClose() // commits unchanged text fields: must be a no-op
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
        #expect(model.minutesEnabled)
        #expect(model.modelID == "a/b")
    }

    @Test func summaryEnabledDefaultsTrueAndPersistsOnToggle() throws {
        let model = makeModel()
        #expect(model.summaryEnabled)

        model.summaryEnabled = false
        let json = try readJSON()
        #expect((json["summary"] as? [String: Any])?["enabled"] as? Bool == false)
    }

    @Test func missingConfigIsNotCreatedByReload() {
        _ = makeModel()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func emptyModelIDRemovesKeyKeepingSiblings() throws {
        try write("{\"openrouter\":{\"model\":\"a/b\",\"deny_data_collection\":false,\"extra\":1}}")
        let model = makeModel()
        model.modelID = "  "
        model.commitModelID()
        let section = try #require(try readJSON()["openrouter"] as? [String: Any])
        #expect(section["model"] == nil)
        #expect(section["deny_data_collection"] as? Bool == false)
        #expect(section["extra"] as? Int == 1)
    }

    @Test func modelIDIsNotPersistedUntilCommitted() throws {
        try write("{}")
        let model = makeModel()
        model.modelID = "openai/g"
        #expect(try readJSON()["openrouter"] == nil)
        model.selectModel("openai/gpt-4o-mini")
        #expect(ConfigValues(raw: try readJSON()).openRouterModel == "openai/gpt-4o-mini")
    }

    @Test func failedSaveRevertsToDiskValues() throws {
        try write("{\"minutes\":{\"enabled\":false}}")
        let model = makeModel()
        // Read-only directory: the atomic write can't create its temp file.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        model.minutesEnabled = true
        #expect(model.minutesEnabled == false)
        #expect(model.configError != nil)
        #expect(!model.configLoadFailed)
    }

    @Test func invalidConfigDisablesEditingAndIsNotOverwritten() throws {
        let broken = "{ oops"
        try write(broken)
        let model = makeModel()
        #expect(model.configLoadFailed)
        #expect(model.configError == Textos.Ajustes.errorLeer(Textos.Ajustes.configInvalida(url.path)))
        model.minutesEnabled = true
        #expect(model.minutesEnabled == false)
        #expect(try String(contentsOf: url, encoding: .utf8) == broken)
    }

    @Test func glossaryEditsPreserveHandEditsAndNonStrings() throws {
        try write("{\"glossary\":[\"Grafana\",42]}")
        let model = makeModel()
        // Hand edit while the window is open.
        try write("{\"glossary\":[\"Grafana\",42,\"k8s\"]}")
        model.newTerm = "Parakeet"
        model.addTerm()
        model.removeTerm("Grafana")
        let list = try #require(try readJSON()["glossary"] as? [Any])
        #expect(list.count == 3)
        #expect(list[0] as? Int == 42)
        #expect(list.compactMap { $0 as? String } == ["k8s", "Parakeet"])
        #expect(model.glossary.map(\.term) == ["k8s", "Parakeet"])
    }

    @Test func addTermWritesStringWithoutVariantsAndObjectWithVariants() throws {
        try write("{\"glossary\":[],\"other\":{\"keep\":1}}")
        let model = makeModel()
        model.newTerm = "Kubernetes"
        model.addTerm()
        model.newTerm = " MeetingVox "
        model.newVariants = "miting vox, mitin vox"
        model.addTerm()
        let json = try readJSON()
        let list = try #require(json["glossary"] as? [Any])
        #expect(list[0] as? String == "Kubernetes")
        let object = try #require(list[1] as? [String: Any])
        #expect(object["term"] as? String == "MeetingVox")
        #expect(object["variants"] as? [String] == ["miting vox", "mitin vox"])
        #expect((json["other"] as? [String: Any])?["keep"] as? Int == 1)
        #expect(model.newTerm.isEmpty && model.newVariants.isEmpty)
        #expect(model.glossary == [
            GlossaryEntry(term: "Kubernetes"),
            GlossaryEntry(term: "MeetingVox", variants: ["miting vox", "mitin vox"]),
        ])
    }

    @Test func addingAnExistingTermMergesItsVariants() throws {
        try write("{\"glossary\":[\"Kafka\"]}")
        let model = makeModel()
        model.newTerm = "kafka"
        model.newVariants = "cafca"
        model.addTerm()
        let list = try #require(try readJSON()["glossary"] as? [Any])
        #expect(list.count == 1)
        let object = try #require(list[0] as? [String: Any])
        #expect(object["term"] as? String == "Kafka")
        #expect(object["variants"] as? [String] == ["cafca"])
    }

    @Test func editingVariantsRewritesOnlyThatEntry() throws {
        try write("{\"glossary\":[42,\"Kafka\",{\"term\":\"MeetingVox\",\"variants\":[\"miting vox\"],\"note\":\"x\"},{\"term\":\"Kubernetes\",\"variants\":[\"cubernetes\"]}]}")
        let model = makeModel()

        model.beginEditing(try #require(model.glossary.first { $0.term == "Kafka" }))
        #expect(model.editingTerm == "Kafka")
        #expect(model.editingVariants == "")
        model.editingVariants = "cafca, kafca"
        model.saveEditing()
        #expect(model.editingTerm == nil)

        // Clearing the variants of a plain {term, variants} object collapses it to a string;
        // an object with keys quill doesn't know stays an object.
        model.beginEditing(try #require(model.glossary.first { $0.term == "Kubernetes" }))
        model.editingVariants = " "
        model.saveEditing()
        model.beginEditing(try #require(model.glossary.first { $0.term == "MeetingVox" }))
        #expect(model.editingVariants == "miting vox")
        model.editingVariants = ""
        model.saveEditing()

        let list = try #require(try readJSON()["glossary"] as? [Any])
        #expect(list.count == 4)
        #expect(list[0] as? Int == 42)
        let kafka = try #require(list[1] as? [String: Any])
        #expect(kafka["term"] as? String == "Kafka")
        #expect(kafka["variants"] as? [String] == ["cafca", "kafca"])
        let meetingvox = try #require(list[2] as? [String: Any])
        #expect(meetingvox["note"] as? String == "x")
        #expect(meetingvox["variants"] == nil)
        #expect(list[3] as? String == "Kubernetes")
    }

    @Test func transcriptFlagIsWrittenOnlyWhenOffAndKeepsShapes() throws {
        try write("{\"glossary\":[\"Kafka\",{\"term\":\"MeetingVox\",\"variants\":[\"miting vox\"],\"note\":\"x\"}]}")
        let model = makeModel()

        model.setTranscript("Kafka", false)
        model.setTranscript("meetingvox", false)
        var list = try #require(try readJSON()["glossary"] as? [Any])
        let kafka = try #require(list[0] as? [String: Any])
        #expect(kafka["term"] as? String == "Kafka")
        #expect(kafka["transcript"] as? Bool == false)
        #expect(kafka.count == 2)
        let meetingvox = try #require(list[1] as? [String: Any])
        #expect(meetingvox["note"] as? String == "x")
        #expect(meetingvox["variants"] as? [String] == ["miting vox"])
        #expect(meetingvox["transcript"] as? Bool == false)
        #expect(model.glossary.map(\.transcript) == [false, false])

        model.setTranscript("Kafka", true)
        model.setTranscript("MeetingVox", true)
        list = try #require(try readJSON()["glossary"] as? [Any])
        #expect(list[0] as? String == "Kafka")
        let back = try #require(list[1] as? [String: Any])
        #expect(back["transcript"] == nil)
        #expect(back["note"] as? String == "x")
        #expect(model.glossary.map(\.transcript) == [true, true])
    }

    @Test func editingVariantsKeepsTheTranscriptFlag() throws {
        try write("{\"glossary\":[{\"term\":\"Kafka\",\"variants\":[\"cafca\"],\"transcript\":false}]}")
        let model = makeModel()
        model.beginEditing(try #require(model.glossary.first))
        model.editingVariants = ""
        model.saveEditing()

        let list = try #require(try readJSON()["glossary"] as? [Any])
        let kafka = try #require(list[0] as? [String: Any])
        #expect(kafka["transcript"] as? Bool == false)
        #expect(kafka["variants"] == nil)
        #expect(model.glossary == [GlossaryEntry(term: "Kafka", transcript: false)])
    }

    @Test func settingTheFlagOfAnUnknownTermWritesNothing() throws {
        let text = "{\"glossary\":[\"Kafka\"]}"
        try write(text)
        let model = makeModel()
        model.setTranscript("Nadie", false)
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test func cancelEditingWritesNothing() throws {
        let text = "{\"glossary\":[\"Kafka\"]}"
        try write(text)
        let model = makeModel()
        model.beginEditing(GlossaryEntry(term: "Kafka"))
        model.editingVariants = "cafca"
        model.cancelEditing()
        #expect(model.editingTerm == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test func removeTermRemovesObjectEntries() throws {
        try write("{\"glossary\":[{\"term\":\"MeetingVox\",\"variants\":[\"miting vox\"]},\"Kubernetes\"]}")
        let model = makeModel()
        model.removeTerm("MeetingVox")
        let list = try #require(try readJSON()["glossary"] as? [Any])
        #expect(list.count == 1)
        #expect(list[0] as? String == "Kubernetes")
        #expect(model.glossary == [GlossaryEntry(term: "Kubernetes")])
    }

    @Test func reloadClearsTypedKey() {
        let model = makeModel()
        model.apiKeyInput = "sk-or-unsaved"
        model.reload()
        #expect(model.apiKeyInput.isEmpty)
    }

    // MARK: - Key presence and legacy migration (onboarding "Minutas")

    private func makeModel(keychain: any APIKeyStore) -> SettingsModel {
        SettingsModel(configURL: url, templatesDir: root, keychain: keychain)
    }

    @Test func keyPresenceIsReadAtLoadWithoutReadingTheSecret() {
        let store = LegacyOnlyStore()
        let model = makeModel(keychain: store)
        #expect(model.keyPresence == .legacyOnly)
        #expect(model.hasKey)  // the pipeline can use a legacy key
        #expect(store.reads == 0)
    }

    @Test func keyPresenceOfAnEmptyStoreIsNone() {
        let model = makeModel()
        #expect(model.keyPresence == .none)
        #expect(!model.hasKey)
    }

    @Test func migratingCopiesTheLegacyKeyAndReReadsPresence() async {
        let store = LegacyOnlyStore(outcome: .copies)
        let model = makeModel(keychain: store)

        await model.migrateLegacyKey()

        #expect(store.reads == 1)
        #expect(model.keyPresence == .primary)
        #expect(model.keyError == nil)
        #expect(!model.migratingKey)
    }

    @Test func aDeniedLegacyPromptLeavesTheKeyLegacyOnlyAndSaysSo() async {
        let store = LegacyOnlyStore(outcome: .deniedAsMissing)
        let model = makeModel(keychain: store)

        await model.migrateLegacyKey()

        #expect(store.reads == 1)
        #expect(model.keyPresence == .legacyOnly)
        #expect(model.keyError == Textos.Onboarding.claveNoMigrada)
        #expect(!model.migratingKey)
    }

    @Test func aThrowingLegacyReadShowsTheErrorAndKeepsPresence() async {
        let store = LegacyOnlyStore(outcome: .throwsError)
        let model = makeModel(keychain: store)

        await model.migrateLegacyKey()

        #expect(model.keyPresence == .legacyOnly)
        #expect(model.keyError != nil)
        #expect(!model.migratingKey)
    }

    @Test func migratingOnlyHappensForALegacyOnlyKey() async {
        for presence in [KeyPresence.primary, .none] {
            let store = LegacyOnlyStore(presence)
            let model = makeModel(keychain: store)
            await model.migrateLegacyKey()
            #expect(store.reads == 0, "\(presence)")  // never prompt when there is nothing to migrate
            #expect(model.keyPresence == presence)
        }
    }

    @Test func savingATypedKeyMakesItPrimary() {
        let store = LegacyOnlyStore()
        let model = makeModel(keychain: store)
        model.apiKeyInput = "sk-or-typed"
        model.saveAPIKey()
        #expect(model.keyPresence == .primary)
        #expect(model.apiKeyInput.isEmpty)
    }

    @Test func deletingTheKeyMakesItNone() {
        let store = LegacyOnlyStore(.primary)
        let model = makeModel(keychain: store)
        model.deleteAPIKey()
        #expect(model.keyPresence == .none)
    }

    // MARK: reload on window key (F5)

    @Test func reloadingForTheWindowKeepsATypedKeyButPicksUpDiskEdits() throws {
        try write("{\"openrouter\":{\"model\":\"a/b\"}}")
        let model = makeModel()
        model.apiKeyInput = "sk-or-unsaved"

        try write("{\"openrouter\":{\"model\":\"c/d\"},\"minutes\":{\"enabled\":true}}")
        model.reload(preservingKeyInput: true)

        #expect(model.apiKeyInput == "sk-or-unsaved")
        #expect(model.modelID == "c/d")
        #expect(model.minutesEnabled)
    }

    @Test func aPlainReloadStillClearsATypedKey() {
        let model = makeModel()
        model.apiKeyInput = "sk-or-unsaved"
        model.reload(preservingKeyInput: false)
        #expect(model.apiKeyInput.isEmpty)
    }

    // MARK: recordings folder

    @Test func settingTheRecordingsFolderSavesItAndUpdatesTheField() throws {
        let model = makeModel()
        let folder = try makeFolder()

        model.setRecordingsDir(folder)

        let saved = try #require(try readJSON()["recordings_dir"] as? String)
        #expect(saved == folder.path)
        #expect(model.recordingsDir == saved)
        #expect(model.recordingsDirError == nil)
    }

    @Test func settingTheRecordingsFolderKeepsOtherKeys() throws {
        try write("{\"minutes\":{\"enabled\":true},\"extra\":1}")
        let model = makeModel()
        let folder = try makeFolder()
        model.setRecordingsDir(folder)
        let json = try readJSON()
        #expect(json["recordings_dir"] as? String == folder.path)
        #expect(json["extra"] as? Int == 1)
        #expect((json["minutes"] as? [String: Any])?["enabled"] as? Bool == true)
    }

    // MARK: onboarding adapter

    @Test func theMinutesFactsAreDoneOnlyWithAUsableKeyAndAModel() throws {
        let store = LegacyOnlyStore(.none)
        let model = makeModel(keychain: store)
        let facts = SettingsMinutesFacts(settings: model)
        #expect(!facts.isDone)

        model.apiKeyInput = "sk-or-typed"
        model.saveAPIKey()
        #expect(!facts.isDone)  // a key alone is not enough

        model.selectModel("openai/gpt-4o-mini")
        #expect(facts.isDone)

        model.selectModel("")
        #expect(!facts.isDone)
    }

    @Test func aLegacyOnlyKeyIsNotDoneUntilItIsMigrated() async {
        let model = makeModel(keychain: LegacyOnlyStore(.legacyOnly))
        model.selectModel("openai/gpt-4o-mini")
        let facts = SettingsMinutesFacts(settings: model)
        #expect(!facts.isDone)

        await model.migrateLegacyKey()

        #expect(facts.isDone)
    }

    @Test func theCheckmarkReadsTheSavedModelNotAHalfTypedOne() throws {
        let model = makeModel(keychain: LegacyOnlyStore(.primary))
        let facts = SettingsMinutesFacts(settings: model)
        model.modelID = "openai/gpt-4o-mini"  // typed, not committed
        #expect(!facts.isDone)
        #expect(model.savedModelID == "")

        model.commitModelID()

        #expect(facts.isDone)
        #expect(model.savedModelID == "openai/gpt-4o-mini")
    }

    // MARK: model ID survives the window-key reload

    @Test func anUncommittedModelIDSurvivesTheOnboardingReload() throws {
        try write("{\"openrouter\":{\"model\":\"a/b\"}}")
        let model = makeModel()
        model.modelID = "typed/half"

        model.reload(preservingKeyInput: true)

        #expect(model.modelID == "typed/half")
        #expect(model.savedModelID == "a/b")  // what is on disk
        model.commitModelID()
        #expect(ConfigValues(raw: try readJSON()).openRouterModel == "typed/half")
    }

    @Test func aCommittedModelIDFollowsDiskEditsOnReload() throws {
        try write("{\"openrouter\":{\"model\":\"a/b\"}}")
        let model = makeModel()
        try write("{\"openrouter\":{\"model\":\"c/d\"}}")

        model.reload(preservingKeyInput: true)

        #expect(model.modelID == "c/d")
        #expect(model.savedModelID == "c/d")
    }

    @Test func aPlainReloadStillDiscardsAnUncommittedModelID() throws {
        try write("{\"openrouter\":{\"model\":\"a/b\"}}")
        let model = makeModel()
        model.modelID = "typed/half"
        model.reload()
        #expect(model.modelID == "a/b")
    }

    // MARK: recordings folder validation

    private func makeFolder(mode: Int = 0o755) throws -> URL {
        let dir = root.appendingPathComponent("carpeta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: dir.path)
        return dir
    }

    @Test func aReadOnlyFolderIsRefusedWithAnInlineErrorAndNothingIsSaved() throws {
        let model = makeModel()
        let before = model.recordingsDir
        let folder = try makeFolder(mode: 0o555)

        model.setRecordingsDir(folder)

        #expect(model.recordingsDirError == Textos.Ajustes.carpetaNoEscribible)
        #expect(model.recordingsDir == before)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aFolderInsideTheAppBundleIsRefused() throws {
        let model = makeModel()
        let app = root.appendingPathComponent("MeetingVox.app", isDirectory: true)
        let inside = app.appendingPathComponent("Contents/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)

        model.setRecordingsDir(inside, bundleURL: app)

        #expect(model.recordingsDirError == Textos.Ajustes.carpetaDentroDeLaApp)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aFolderNextToTheBundleNameButNotInsideItIsAccepted() throws {
        let model = makeModel()
        let app = root.appendingPathComponent("MeetingVox.app", isDirectory: true)
        let sibling = root.appendingPathComponent("MeetingVox.app-datos", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        model.setRecordingsDir(sibling, bundleURL: app)

        #expect(model.recordingsDirError == nil)
        #expect(try readJSON()["recordings_dir"] as? String == sibling.path)
    }

    @Test func aPathThatIsNotAFolderIsRefused() throws {
        let model = makeModel()
        let file = root.appendingPathComponent("archivo.txt")
        try Data("x".utf8).write(to: file)
        model.setRecordingsDir(file)
        #expect(model.recordingsDirError == Textos.Ajustes.carpetaNoValida)

        model.setRecordingsDir(root.appendingPathComponent("no-existe", isDirectory: true))
        #expect(model.recordingsDirError == Textos.Ajustes.carpetaNoValida)
    }

    @Test func aLaterValidChoiceClearsTheError() throws {
        let model = makeModel()
        model.setRecordingsDir(try makeFolder(mode: 0o555))
        #expect(model.recordingsDirError != nil)

        let good = try makeFolder()
        model.setRecordingsDir(good)

        #expect(model.recordingsDirError == nil)
        #expect(model.recordingsDir == good.path)
    }

    @Test func reloadingTheFactsRereadsDiskAndKeepsATypedKey() throws {
        try write("{}")
        let model = makeModel()
        let facts = SettingsMinutesFacts(settings: model)
        model.apiKeyInput = "sk-or-unsaved"
        try write("{\"openrouter\":{\"model\":\"c/d\"}}")

        facts.reload()

        #expect(model.modelID == "c/d")
        #expect(model.apiKeyInput == "sk-or-unsaved")
    }

    @Test func reloadingTheFactsAlsoRunsTheExtraHook() {
        var reloads = 0
        let facts = SettingsMinutesFacts(settings: makeModel(), onReload: { reloads += 1 })
        facts.reload()
        facts.reload()
        #expect(reloads == 2)
    }
}
