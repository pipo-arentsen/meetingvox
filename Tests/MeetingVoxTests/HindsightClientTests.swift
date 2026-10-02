import Foundation
import Testing
@testable import MeetingVox

private struct ScriptedBackend: HindsightBackend {
    let outcome: HindsightOutcome
    func retain(baseURL: URL, bank: String, token: String, body: Data) async -> HindsightOutcome { outcome }
    func testConnection(baseURL: URL, token: String) async -> HindsightOutcome { outcome }
    func listBanks(baseURL: URL, token: String) async -> [String]? { nil }
    func deleteDocument(baseURL: URL, bank: String, documentID: String, token: String) async -> HindsightDeleteOutcome { .deleted }
}

private struct TokenStore: APIKeyStore {
    let token: String?
    func hasAPIKey() -> Bool { token != nil }
    func read() throws -> String? { token }
    func save(_ secret: String) throws {}
    func delete() throws {}
}

private func kind(_ outcome: HindsightOutcome) -> String {
    switch outcome {
    case .success: "success"
    case .transient: "transient"
    case .unauthorized: "unauthorized"
    case .rejected: "rejected"
    }
}

private func enabledConfig(url: String? = "http://localhost:8888") -> ConfigValues {
    var section: [String: Any] = ["enabled": true]
    if let url { section["base_url"] = url }
    return ConfigValues(raw: ["hindsight": section])
}

@Suite struct HindsightClientTests {
    @Test(arguments: [
        (200, "success"), (202, "success"), (401, "unauthorized"), (403, "unauthorized"),
        (408, "transient"), (429, "transient"), (500, "transient"), (503, "transient"),
        (400, "rejected"), (404, "rejected"), (409, "rejected"), (422, "rejected"),
    ])
    func classification(status: Int, expected: String) {
        #expect(kind(HindsightOutcome.classify(status: status, message: nil)) == expected)
    }

    @Test func rejectionKeepsStatusAndMessage() {
        #expect(HindsightOutcome.classify(status: 409, message: "reused") == .rejected(status: 409, message: "reused"))
    }

    @Test func retainRequestTargetsTheBankWithBearerToken() {
        let body = Data(#"{"items":[]}"#.utf8)
        let req = HindsightClient.retainRequest(
            baseURL: URL(string: "http://localhost:8888")!, bank: "meetingvox", token: "tok", body: body
        )
        #expect(req.url?.absoluteString == "http://localhost:8888/v1/default/banks/meetingvox/memories")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(req.httpBody == body)
        #expect(req.timeoutInterval == 30)
    }

    @Test func bankIsPercentEncodedAndTrailingSlashTolerated() {
        let req = HindsightClient.retainRequest(baseURL: URL(string: "http://h:8888/")!, bank: "mi banco", token: "t", body: Data())
        #expect(req.url?.absoluteString == "http://h:8888/v1/default/banks/mi%20banco/memories")
    }

    @Test func deleteRequestTargetsTheDocumentWithBearerToken() {
        let req = HindsightClient.deleteRequest(
            baseURL: URL(string: "http://h:8888")!, bank: "meetingvox", documentID: "mv-2026.09.29-1105", token: "tok"
        )
        #expect(req.url?.absoluteString == "http://h:8888/v1/default/banks/meetingvox/documents/mv-2026.09.29-1105")
        #expect(req.httpMethod == "DELETE")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(req.httpBody == nil)
        #expect(req.timeoutInterval == 30)
    }

    @Test func deleteRequestPercentEncodesBankAndDocumentID() {
        let req = HindsightClient.deleteRequest(
            baseURL: URL(string: "http://h:8888/")!, bank: "mi banco", documentID: "mv-a b?c#d", token: "t"
        )
        #expect(req.url?.absoluteString == "http://h:8888/v1/default/banks/mi%20banco/documents/mv-a%20b%3Fc%23d")
    }

    @Test(arguments: [
        (200, "deleted"), (204, "deleted"), (404, "deleted"),
        (401, "unauthorized"), (403, "unauthorized"),
        (408, "transient"), (429, "transient"), (500, "transient"), (503, "transient"),
        (400, "rejected"), (409, "rejected"), (422, "rejected"),
    ])
    func deleteClassification(status: Int, expected: String) {
        let outcome = HindsightDeleteOutcome.classify(status: status, message: nil)
        let kind: String = switch outcome {
        case .deleted: "deleted"
        case .transient: "transient"
        case .unauthorized: "unauthorized"
        case .rejected: "rejected"
        }
        #expect(kind == expected)
    }

    @Test func deleteLogDescriptionNeverHasAToken() {
        #expect(HindsightDeleteOutcome.deleted.logDescription == "ok")
        #expect(HindsightDeleteOutcome.rejected(status: 422, message: "bad").logDescription == "rejected (HTTP 422: bad)")
        #expect(HindsightDeleteOutcome.unauthorized(status: 401).logDescription == "unauthorized (HTTP 401)")
        #expect(HindsightDeleteOutcome.transient("HTTP 503").logDescription == "transient (HTTP 503)")
    }

    @Test func banksRequestIsAnAuthenticatedGET() {
        let req = HindsightClient.banksRequest(baseURL: URL(string: "http://h:8888")!, token: "tok")
        #expect(req.url?.absoluteString == "http://h:8888/v1/default/banks")
        #expect(req.httpMethod == "GET")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.timeoutInterval == 30)
    }

    @Test func extractsFastAPIErrorDetail() {
        #expect(HindsightClient.errorMessage(from: Data(#"{"detail":"operation_id reused"}"#.utf8)) == "operation_id reused")
        #expect(HindsightClient.errorMessage(from: Data(
            #"{"detail":[{"loc":["body","items"],"msg":"field required","type":"missing"}]}"#.utf8
        )) == "field required")
        #expect(HindsightClient.errorMessage(from: Data("<html>".utf8)) == nil)
        let long = Data(#"{"detail":"\#(String(repeating: "x", count: 500))"}"#.utf8)
        #expect(HindsightClient.errorMessage(from: long)?.count == 200)
    }

    @Test func probeIsSilentWhenDisabled() async {
        let line = await HindsightClient.startupProbe(
            config: ConfigValues(raw: [:]), keyStore: TokenStore(token: "t"), backend: ScriptedBackend(outcome: .success)
        )
        #expect(line == nil)
    }

    @Test func probeReportsWhatIsMissing() async {
        let noURL = await HindsightClient.startupProbe(
            config: enabledConfig(url: nil), keyStore: TokenStore(token: "t"), backend: ScriptedBackend(outcome: .success)
        )
        #expect(noURL == "hindsight: probe → skipped (no base_url)")
        let noToken = await HindsightClient.startupProbe(
            config: enabledConfig(), keyStore: TokenStore(token: nil), backend: ScriptedBackend(outcome: .success)
        )
        #expect(noToken == "hindsight: probe → skipped (no token)")
    }

    @Test func probeLogsTheOutcomeButNeverTheToken() async {
        let ok = await HindsightClient.startupProbe(
            config: enabledConfig(), keyStore: TokenStore(token: "s3cret"), backend: ScriptedBackend(outcome: .success)
        )
        #expect(ok == "hindsight: probe → ok")
        let denied = await HindsightClient.startupProbe(
            config: enabledConfig(), keyStore: TokenStore(token: "s3cret"),
            backend: ScriptedBackend(outcome: .unauthorized(status: 401))
        )
        #expect(denied == "hindsight: probe → unauthorized (HTTP 401)")
        #expect(denied?.contains("s3cret") == false)
    }

    @Test func parsesTheBankList() {
        let body = #"{"banks":[{"bank_id":"meetingvox","name":"MeetingVox"},{"bank_id":" archivo "},{"bank_id":""},{"name":"x"},{"bank_id":"meetingvox"}],"total":5,"limit":100,"offset":0}"#
        #expect(HindsightClient.parseBanks(Data(body.utf8)) == ["meetingvox", "archivo"])
        #expect(HindsightClient.parseBanks(Data(#"{"banks":[]}"#.utf8)) == [])
        #expect(HindsightClient.parseBanks(Data(#"{"detail":"Not authenticated"}"#.utf8)) == nil)
        #expect(HindsightClient.parseBanks(Data("not json".utf8)) == nil)
    }

    /// A stray non-object element (e.g. a literal `null`)
    /// doesn't fail the whole list.
    @Test func parseBanksToleratesANonObjectElement() {
        let body = #"{"banks":[{"bank_id":"meetingvox"},null,"oops",{"bank_id":"archivo"}]}"#
        #expect(HindsightClient.parseBanks(Data(body.utf8)) == ["meetingvox", "archivo"])
    }
}
