import Foundation

/// What a Hindsight call means for the exporter.
enum HindsightOutcome: Sendable, Equatable {
    case success
    /// No response, timeout, 408, 429, 5xx: leave the session pending for
    /// the next sweep; nothing is written.
    case transient(String)
    /// 401/403: the token is wrong; every send pauses until it changes.
    case unauthorized(status: Int)
    /// 409, 422, any other 4xx: this content won't be accepted as is.
    case rejected(status: Int, message: String?)

    static func classify(status: Int, message: String?) -> HindsightOutcome {
        switch status {
        case 200..<300: .success
        case 401, 403: .unauthorized(status: status)
        case 408, 429, 500...599: .transient("HTTP \(status)")
        default: .rejected(status: status, message: message)
        }
    }

    /// English, for stderr and `hindsight.log`. Never contains the token.
    var logDescription: String {
        switch self {
        case .success: "ok"
        case .transient(let detail): "transient (\(detail))"
        case .unauthorized(let status): "unauthorized (HTTP \(status))"
        case .rejected(let status, let message): "rejected (HTTP \(status)\(message.map { ": \($0)" } ?? ""))"
        }
    }
}

/// What a document delete means for the caller. Separate from
/// `HindsightOutcome` because a 404 here means "already gone" (success),
/// whereas a send maps it to a rejection.
enum HindsightDeleteOutcome: Sendable, Equatable {
    /// 2xx, or 404 (the document is not in memory: nothing left to delete).
    case deleted
    /// No response, timeout, 408, 429, 5xx.
    case transient(String)
    /// 401/403: the token is wrong.
    case unauthorized(status: Int)
    /// Any other status.
    case rejected(status: Int, message: String?)

    static func classify(status: Int, message: String?) -> HindsightDeleteOutcome {
        switch status {
        case 200..<300, 404: .deleted
        case 401, 403: .unauthorized(status: status)
        case 408, 429, 500...599: .transient("HTTP \(status)")
        default: .rejected(status: status, message: message)
        }
    }

    /// English, for stderr. Never contains the token.
    var logDescription: String {
        switch self {
        case .deleted: "ok"
        case .transient(let detail): "transient (\(detail))"
        case .unauthorized(let status): "unauthorized (HTTP \(status))"
        case .rejected(let status, let message): "rejected (HTTP \(status)\(message.map { ": \($0)" } ?? ""))"
        }
    }
}

/// The network seam of the exporter (faked in tests).
protocol HindsightBackend: Sendable {
    func retain(baseURL: URL, bank: String, token: String, body: Data) async -> HindsightOutcome
    func testConnection(baseURL: URL, token: String) async -> HindsightOutcome
    /// `GET /v1/default/banks` → bank ids; nil on any failure (the caller
    /// falls back to the default bank).
    func listBanks(baseURL: URL, token: String) async -> [String]?
    /// `DELETE /v1/default/banks/{bank}/documents/{id}`: permanently removes
    /// the document and the memories extracted from it.
    func deleteDocument(baseURL: URL, bank: String, documentID: String, token: String) async -> HindsightDeleteOutcome
}

/// Thin Hindsight REST client. Stateless; the token is passed per call (read
/// from the Keychain by the caller) and only ever goes into the
/// `Authorization` header.
struct HindsightClient: HindsightBackend {
    static let timeout: TimeInterval = 30

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func retain(baseURL: URL, bank: String, token: String, body: Data) async -> HindsightOutcome {
        await send(Self.retainRequest(baseURL: baseURL, bank: bank, token: token, body: body))
    }

    /// `GET /v1/default/banks`: proves the server is reachable and the token valid.
    func testConnection(baseURL: URL, token: String) async -> HindsightOutcome {
        await send(Self.banksRequest(baseURL: baseURL, token: token))
    }

    func listBanks(baseURL: URL, token: String) async -> [String]? {
        do {
            let (data, response) = try await session.data(for: Self.banksRequest(baseURL: baseURL, token: token))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return Self.parseBanks(data)
        } catch {
            return nil
        }
    }

    func deleteDocument(baseURL: URL, bank: String, documentID: String, token: String) async -> HindsightDeleteOutcome {
        let request = Self.deleteRequest(baseURL: baseURL, bank: bank, documentID: documentID, token: token)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .transient("non-HTTP response") }
            return .classify(status: http.statusCode, message: Self.errorMessage(from: data))
        } catch {
            return .transient(error.localizedDescription)
        }
    }

    // MARK: Pure helpers (internal for tests)

    static func retainRequest(baseURL: URL, bank: String, token: String, body: Data) -> URLRequest {
        let url = banksURL(baseURL).appendingPathComponent(bank).appendingPathComponent("memories")
        var req = request(url, token: token)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    static func deleteRequest(baseURL: URL, bank: String, documentID: String, token: String) -> URLRequest {
        let url = banksURL(baseURL).appendingPathComponent(bank)
            .appendingPathComponent("documents").appendingPathComponent(documentID)
        var req = request(url, token: token)
        req.httpMethod = "DELETE"
        return req
    }

    static func banksRequest(baseURL: URL, token: String) -> URLRequest {
        var req = request(banksURL(baseURL), token: token)
        req.httpMethod = "GET"
        return req
    }

    /// FastAPI error body: `{"detail": "…"}` or `{"detail": [{"msg": "…"}]}`.
    /// Capped at 200 characters (it ends up in `hindsight.error` and logs).
    static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let text: String?
        if let detail = json["detail"] as? String {
            text = detail
        } else if let list = json["detail"] as? [[String: Any]] {
            text = list.first?["msg"] as? String
        } else {
            text = json["message"] as? String
        }
        return text.map { String($0.prefix(200)) }
    }

    /// `BankListResponse { banks: [{bank_id, name, …}], total, limit, offset }`
    /// (Hindsight 0.10.1) → ids in server order, trimmed; blank and repeated
    /// ids dropped. Nil when the body isn't that shape. A non-object element
    /// (e.g. a stray `null`) is skipped rather than failing the whole list.
    /// Only the first page is read: an installation has a handful of banks.
    static func parseBanks(_ data: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let banks = json["banks"] as? [Any]
        else { return nil }
        var seen = Set<String>()
        return banks
            .compactMap { $0 as? [String: Any] }
            .compactMap { ($0["bank_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// One-shot reachability check logged at launch (`quill run`), so
    /// `/tmp/quill.err.log` shows whether launchd-run quill can reach the
    /// server (local-network permission, `http://`). Nil when disabled.
    static func startupProbe(config: ConfigValues, keyStore: any APIKeyStore, backend: any HindsightBackend) async -> String? {
        guard config.hindsightEnabled else { return nil }
        guard let baseURL = config.hindsightBaseURL else { return "hindsight: probe → skipped (no base_url)" }
        let token: String?
        do {
            token = try keyStore.read()
        } catch {
            return "hindsight: probe → skipped (keychain: \(error))"
        }
        guard let token, !token.isEmpty else { return "hindsight: probe → skipped (no token)" }
        let outcome = await backend.testConnection(baseURL: baseURL, token: token)
        return "hindsight: probe → \(outcome.logDescription)"
    }

    // MARK: Transport

    private static func banksURL(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("v1").appendingPathComponent("default").appendingPathComponent("banks")
    }

    private static func request(_ url: URL, token: String) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func send(_ request: URLRequest) async -> HindsightOutcome {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .transient("non-HTTP response") }
            return .classify(status: http.statusCode, message: Self.errorMessage(from: data))
        } catch {
            return .transient(error.localizedDescription)
        }
    }
}
