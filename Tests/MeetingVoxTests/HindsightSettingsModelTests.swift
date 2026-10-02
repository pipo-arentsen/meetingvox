import Foundation
import Testing
@testable import MeetingVox

private final class MemoryKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secret: String?
    init(_ secret: String? = nil) { self.secret = secret }
    func hasAPIKey() -> Bool { lock.withLock { secret != nil } }
    func read() throws -> String? { lock.withLock { secret } }
    func save(_ secret: String) throws { lock.withLock { self.secret = secret } }
    func delete() throws { lock.withLock { secret = nil } }
}

private struct FixedBackend: HindsightBackend {
    let outcome: HindsightOutcome
    var banks: [String]? = nil
    func retain(baseURL: URL, bank: String, token: String, body: Data) async -> HindsightOutcome { outcome }
    func testConnection(baseURL: URL, token: String) async -> HindsightOutcome { outcome }
    func listBanks(baseURL: URL, token: String) async -> [String]? { banks }
    func deleteDocument(baseURL: URL, bank: String, documentID: String, token: String) async -> HindsightDeleteOutcome { .deleted }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func bump() { lock.withLock { _value += 1 } }
}

private let mexico = TimeZone(identifier: "America/Mexico_City")!
/// 2026-09-24 12:00 in Mexico City.
private let noon = ISO8601DateFormatter().date(from: "2026-09-24T18:00:00Z")!

@MainActor
@Suite final class HindsightSettingsModelTests {
    let root: URL
    let url: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-hindsight-settings-\(UUID().uuidString)", isDirectory: true)
        url = root.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String) throws { try Data(text.utf8).write(to: url) }

    private func section() throws -> [String: Any] {
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return json["hindsight"] as? [String: Any] ?? [:]
    }

    private func makeModel(
        outcome: HindsightOutcome = .success, keychain: MemoryKeyStore = MemoryKeyStore(),
        notifications: NotificationCenter = NotificationCenter(), banks: [String]? = nil
    ) -> HindsightSettingsModel {
        HindsightSettingsModel(
            configURL: url, keychain: keychain, backend: FixedBackend(outcome: outcome, banks: banks),
            now: { noon }, timeZone: mexico, notifications: notifications
        )
    }

    @Test func reloadDoesNotWrite() throws {
        let text = #"{"hindsight":{"auto_send":true,"base_url":"http://h:8888","bank":"meetingvox","enabled":true,"min_minutes":3,"min_words":90,"owner_description":"R (rol)","since":"2026-09-01"}}"#
        try write(text)
        let model = makeModel()
        model.windowDidClose()
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
        #expect(model.enabled)
        #expect(model.baseURL == "http://h:8888")
        #expect(ConfigValues.hindsightDay(model.since, timeZone: mexico) == "2026-09-01")
        #expect(model.autoSend)
        #expect(model.ownerDescription == "R (rol)")
        #expect(model.minWords == 90)
        #expect(model.minMinutes == 3)
    }

    @Test func enablingTheIntegrationDoesNotSaveACutoff() throws {
        let model = makeModel()
        model.enabled = true
        let s = try section()
        #expect(s["enabled"] as? Bool == true)
        #expect(s["since"] == nil)
    }

    @Test func enablingAutoSendWithoutCutoffSavesToday() throws {
        let model = makeModel()
        model.autoSend = true
        let s = try section()
        #expect(s["auto_send"] as? Bool == true)
        #expect(s["since"] as? String == "2026-09-24")
    }

    @Test func enablingAutoSendKeepsAnExistingCutoff() throws {
        try write(#"{"hindsight":{"since":"2026-01-15"}}"#)
        let model = makeModel()
        model.autoSend = true
        #expect(try section()["since"] as? String == "2026-01-15")
    }

    @Test func ownerDescriptionAndThresholdsAreSaved() throws {
        let model = makeModel()
        #expect(model.minWords == 150)
        #expect(model.minMinutes == 2)
        model.ownerDescription = " quien grabó la reunión "
        model.commitOwnerDescription()
        model.minWords = 200
        model.minMinutes = 5
        let s = try section()
        #expect(s["owner_description"] as? String == "quien grabó la reunión")
        #expect(s["min_words"] as? Int == 200)
        #expect(s["min_minutes"] as? Int == 5)
    }

    @Test func pickingADateSavesIt() throws {
        let model = makeModel()
        model.since = try #require(ConfigValues.hindsightDate(fromDay: "2026-08-01", timeZone: mexico))
        #expect(try section()["since"] as? String == "2026-08-01")
    }

    @Test func textFieldsCommitTrimmedAndEmptyRemovesTheKey() throws {
        try write(#"{"hindsight":{"bank":"old","extra":1}}"#)
        let model = makeModel()
        model.baseURL = " http://h:8888 "
        model.commitBaseURL()
        model.bank = ""
        model.commitBank()
        let s = try section()
        #expect(s["base_url"] as? String == "http://h:8888")
        #expect(s["bank"] == nil)
        #expect(s["extra"] as? Int == 1)
    }

    @Test func tokenGoesOnlyToTheKeychainAndPostsAConfigChange() throws {
        let keychain = MemoryKeyStore()
        let center = NotificationCenter()
        let posts = Counter()
        let observer = center.addObserver(forName: .meetingVoxConfigDidChange, object: nil, queue: nil) { _ in posts.bump() }
        defer { center.removeObserver(observer) }
        let model = makeModel(keychain: keychain, notifications: center)

        model.tokenInput = " s3cret "
        model.saveToken()

        #expect(try keychain.read() == "s3cret")
        #expect(model.hasToken)
        #expect(model.tokenInput.isEmpty)
        #expect(posts.value == 1)
        if FileManager.default.fileExists(atPath: url.path) {
            #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("s3cret"))
        }

        model.deleteToken()
        #expect(!model.hasToken)
        #expect(posts.value == 2)
    }

    @Test func testConnectionMapsOutcomes() async {
        let cases: [(HindsightOutcome, String)] = [
            (.success, Textos.Memoria.conexionCorrecta),
            (.unauthorized(status: 401), Textos.Memoria.tokenRechazado),
            (.transient("offline"), Textos.Memoria.noAlcanzable("offline")),
            (.rejected(status: 404, message: nil), Textos.Memoria.respuestaInesperada(404)),
        ]
        for (outcome, message) in cases {
            let model = makeModel(outcome: outcome, keychain: MemoryKeyStore("t"))
            model.baseURL = "http://h:8888"
            await model.testConnection().value
            #expect(model.connectionResult == message)
            #expect(model.connectionFailed == (outcome != .success))
        }
    }

    @Test func defaultBankPickerListsServerBanksAndSavesTheChoice() async throws {
        try write(#"{"hindsight":{"enabled":true,"base_url":"http://hindsight.test:8888","bank":"meetingvox"}}"#)
        let model = makeModel(keychain: MemoryKeyStore("tok"), banks: ["archivo", "meetingvox"])
        await model.refreshBanks().value
        #expect(model.bankList.loadedFromServer)
        #expect(model.bankChoices == ["meetingvox", "archivo"])

        model.selectBank("archivo")
        #expect(model.bank == "archivo")
        #expect(try section()["bank"] as? String == "archivo")
    }

    /// Review focus 5.
    @Test func withoutAServerListTheBankStaysFreeText() async throws {
        try write(#"{"hindsight":{"enabled":true,"base_url":"http://hindsight.test:8888","bank":"meetingvox"}}"#)
        let model = makeModel(keychain: MemoryKeyStore("tok"), banks: nil)
        await model.refreshBanks().value
        #expect(!model.bankList.loadedFromServer)
        #expect(model.bankChoices == ["meetingvox"])
    }

    /// With the server list loaded and
    /// no bank saved yet, the picker's selection ("") must still have a
    /// matching tag — a leading placeholder entry provides it.
    @Test func bankChoicesOffersAPlaceholderWhenNoneIsSavedYet() async throws {
        try write(#"{"hindsight":{"enabled":true,"base_url":"http://hindsight.test:8888"}}"#)
        let model = makeModel(keychain: MemoryKeyStore("tok"), banks: ["meetingvox", "archivo"])
        await model.refreshBanks().value
        #expect(model.bank.isEmpty)
        #expect(model.bankChoices == ["", "archivo", "meetingvox"])
    }

    @Test func testConnectionNeedsAValidURLAndAToken() async {
        let noURL = makeModel(keychain: MemoryKeyStore("t"))
        noURL.baseURL = "192.168.1.10:8888"
        await noURL.testConnection().value
        #expect(noURL.connectionResult == Textos.Memoria.faltaURL)

        let noToken = makeModel()
        noToken.baseURL = "http://h:8888"
        await noToken.testConnection().value
        #expect(noToken.connectionResult == Textos.Memoria.necesitaToken)
    }
}
