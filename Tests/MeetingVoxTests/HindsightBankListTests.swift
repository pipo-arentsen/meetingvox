import Foundation
import Testing
@testable import MeetingVox

private final class BankBackend: HindsightBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let banks: [String]?
    private var _calls = 0

    init(_ banks: [String]?) { self.banks = banks }

    var calls: Int { lock.withLock { _calls } }

    func retain(baseURL: URL, bank: String, token: String, body: Data) async -> HindsightOutcome { .success }
    func testConnection(baseURL: URL, token: String) async -> HindsightOutcome { .success }
    func deleteDocument(baseURL: URL, bank: String, documentID: String, token: String) async -> HindsightDeleteOutcome { .deleted }
    func listBanks(baseURL: URL, token: String) async -> [String]? {
        lock.withLock { _calls += 1 }
        return banks
    }
}

private struct Token: APIKeyStore {
    let token: String?
    func hasAPIKey() -> Bool { token != nil }
    func read() throws -> String? { token }
    func save(_ secret: String) throws {}
    func delete() throws {}
}

@MainActor
@Suite struct HindsightBankListTests {
    private func list(
        _ backend: BankBackend, enabled: Bool = true, token: String? = "tok", bank: String? = "meetingvox"
    ) -> HindsightBankList {
        HindsightBankList(
            backend: backend, keyStore: Token(token: token),
            config: {
                var section: [String: Any] = ["enabled": enabled, "base_url": "http://hindsight.test:8888"]
                if let bank { section["bank"] = bank }
                return ConfigValues(raw: ["hindsight": section])
            },
            notifications: NotificationCenter()
        )
    }

    @Test func mergePutsTheDefaultFirstAndSortsTheRest() {
        #expect(HindsightBankList.merge(server: ["otro", "meetingvox", "archivo"], defaultBank: "meetingvox")
            == ["meetingvox", "archivo", "otro"])
        // The default is kept even if the server doesn't list it.
        #expect(HindsightBankList.merge(server: ["archivo"], defaultBank: "meetingvox") == ["meetingvox", "archivo"])
        #expect(HindsightBankList.merge(server: nil, defaultBank: "meetingvox") == ["meetingvox"])
        #expect(HindsightBankList.merge(server: ["b", "a"], defaultBank: nil) == ["a", "b"])
    }

    @Test func serverListReplacesTheFallback() async {
        let banks = list(BankBackend(["otro", "meetingvox", "archivo"]))
        #expect(banks.banks == ["meetingvox"])
        #expect(!banks.loadedFromServer)

        await banks.refresh().value
        #expect(banks.banks == ["meetingvox", "archivo", "otro"])
        #expect(banks.loadedFromServer)
        #expect(banks.others == ["archivo", "otro"])
        #expect(banks.defaultBank == "meetingvox")
    }

    /// Review focus 5.
    @Test func withoutAServerAnswerTheListIsTheDefaultAlone() async {
        let banks = list(BankBackend(nil))
        await banks.refresh().value
        #expect(banks.banks == ["meetingvox"])
        #expect(!banks.loadedFromServer)
        #expect(banks.others.isEmpty)
    }

    /// Review focus 5.
    @Test func disabledOrWithoutTokenNeverAsksTheServer() async {
        let backend = BankBackend(["archivo"])
        await list(backend, enabled: false).refresh().value
        await list(backend, token: nil).refresh().value
        #expect(backend.calls == 0)
    }

    // MARK: - Refresh gate (onboarding holds the config-driven refresh)

    private func poll(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aConfigChangeGoesThroughTheRefreshGateAndRunsOnlyWhenTheGateReleasesIt() async {
        let center = NotificationCenter()
        let backend = BankBackend(["archivo"])
        let banks = HindsightBankList(
            backend: backend, keyStore: Token(token: "tok"),
            config: { ConfigValues(raw: ["hindsight": ["enabled": true, "base_url": "http://h.test:8888", "bank": "meetingvox"]]) },
            notifications: center
        )
        var held: [@MainActor () -> Void] = []
        banks.refreshGate = { held.append($0) }
        banks.startObservingConfig()

        center.post(name: .meetingVoxConfigDidChange, object: nil)
        await poll { !held.isEmpty }

        #expect(held.count == 1)
        #expect(backend.calls == 0)  // nothing reached the Keychain or the network

        guard let release = held.first else { return }
        release()
        await poll { backend.calls == 1 }
        #expect(backend.calls == 1)
    }

    @Test func withoutAGateAConfigChangeRefreshesAtOnce() async {
        let center = NotificationCenter()
        let backend = BankBackend(["archivo"])
        let banks = HindsightBankList(
            backend: backend, keyStore: Token(token: "tok"),
            config: { ConfigValues(raw: ["hindsight": ["enabled": true, "base_url": "http://h.test:8888", "bank": "meetingvox"]]) },
            notifications: center
        )
        banks.startObservingConfig()

        center.post(name: .meetingVoxConfigDidChange, object: nil)
        await poll { backend.calls == 1 }

        #expect(backend.calls == 1)
    }

    @Test func aDirectRefreshIsNeverGated() async {
        let backend = BankBackend(["archivo"])
        let banks = list(backend)
        var gated = 0
        banks.refreshGate = { _ in gated += 1 }

        await banks.refresh().value  // "opening Reuniones / Ajustes → Memoria" is a user action

        #expect(gated == 0)
        #expect(backend.calls == 1)
    }
}
