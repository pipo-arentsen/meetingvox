import Foundation

// MARK: - Models

/// One entry of OpenRouter's `/models` catalog — only the fields the
/// settings UI shows. Prices are kept as the API's decimal strings (USD per
/// token) to avoid float rounding in display.
struct OpenRouterModel: Sendable, Equatable, Identifiable, Decodable {
    let id: String
    let name: String
    let contextLength: Int?
    let promptPrice: String?
    let completionPrice: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, pricing
        case contextLength = "context_length"
    }

    private struct Pricing: Decodable {
        let prompt: String?
        let completion: String?
    }

    init(id: String, name: String, contextLength: Int?, promptPrice: String?, completionPrice: String?) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.promptPrice = promptPrice
        self.completionPrice = completionPrice
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        contextLength = try? c.decodeIfPresent(Int.self, forKey: .contextLength)
        let pricing = try? c.decodeIfPresent(Pricing.self, forKey: .pricing)
        promptPrice = pricing?.prompt
        completionPrice = pricing?.completion
    }
}

/// A chat message in OpenAI/OpenRouter wire format.
struct ChatMessage: Sendable, Equatable, Codable {
    let role: String
    let content: String

    static func system(_ content: String) -> ChatMessage { ChatMessage(role: "system", content: content) }
    static func user(_ content: String) -> ChatMessage { ChatMessage(role: "user", content: content) }
}

// MARK: - Errors

/// Failure classes the minutes pipeline (F4) needs to tell apart: which are
/// worth retrying, and which need the user to fix something in settings.
enum OpenRouterError: Error, Equatable, LocalizedError {
    /// No response (offline, DNS, TLS, timeout).
    case transport(String)
    /// 401/403: missing, invalid or disabled key.
    case unauthorized(String?)
    /// 400: invalid model id, malformed request, context too long.
    case badRequest(String?)
    /// 402: the account has run out of credits.
    case insufficientCredits(String?)
    /// 429.
    case rateLimited(String?)
    /// 5xx, plus 408 (upstream timeout): the provider side failed.
    case server(status: Int, message: String?)
    /// Any other non-2xx status.
    case unexpectedStatus(Int, String?)
    /// A 2xx body we couldn't parse.
    case decoding(String)
    /// A well-formed completion with no text in it.
    case emptyContent
    /// No text and `finish_reason == "length"`: a reasoning model spent the
    /// whole output budget thinking. Not retryable, like `emptyContent`.
    case outputTruncated

    /// Transient failures a caller may retry with backoff; everything else
    /// needs a change (key, model, credits, request) before trying again.
    var isRetryable: Bool {
        switch self {
        case .transport, .rateLimited, .server: true
        default: false
        }
    }

    /// Map an HTTP status and optional provider message to an error.
    static func classify(status: Int, message: String?) -> OpenRouterError {
        switch status {
        case 400: .badRequest(message)
        case 401, 403: .unauthorized(message)
        case 402: .insufficientCredits(message)
        case 408: .server(status: status, message: message)
        case 429: .rateLimited(message)
        case 500...599: .server(status: status, message: message)
        default: .unexpectedStatus(status, message)
        }
    }

    /// User-visible (settings window, notifications), hence Spanish.
    var errorDescription: String? {
        let e = Textos.OpenRouter.self
        switch self {
        case .transport(let detail): return e.errorRed(detail)
        case .unauthorized: return e.errorClave
        case .badRequest(let m): return e.errorSolicitud(m)
        case .insufficientCredits: return e.errorCreditos
        case .rateLimited: return e.errorLimite
        case .server(let status, _): return e.errorServidor(status)
        case .unexpectedStatus(let status, let m): return e.errorInesperado(status, m)
        case .decoding: return e.errorRespuesta
        case .emptyContent: return e.errorVacia
        case .outputTruncated: return e.errorTruncada
        }
    }
}

// MARK: - Client

/// Thin OpenRouter REST client. Stateless and `Sendable`: the API key is
/// passed per call (read from the Keychain by the caller) so it is never
/// held longer than a request needs it.
struct OpenRouterClient: Sendable {
    static let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    /// Catalog/key lookups are small; chat completions for an hour-long
    /// transcript can legitimately take minutes.
    static let shortTimeout: TimeInterval = 30
    static let chatTimeout: TimeInterval = 300

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Endpoints

    /// Public model catalog (no auth). Entries that fail to decode are
    /// skipped so one odd model never empties the picker.
    func listModels() async throws -> [OpenRouterModel] {
        let data = try await send(request(path: "models", apiKey: nil, timeout: Self.shortTimeout))
        return try Self.decodeModels(data)
    }

    /// Validate a key via `GET /key` and describe it briefly (label, usage,
    /// limit) for the settings window.
    func testConnection(apiKey: String) async throws -> String {
        let data = try await send(request(path: "key", apiKey: apiKey, timeout: Self.shortTimeout))
        struct Envelope: Decodable {
            struct Info: Decodable {
                let label: String?
                let usage: Double?
                let limit: Double?
            }
            let data: Info
        }
        do {
            let info = try JSONDecoder().decode(Envelope.self, from: data).data
            return Textos.OpenRouter.conexionCorrecta(label: info.label, usage: info.usage, limit: info.limit)
        } catch {
            throw OpenRouterError.decoding("\(error)")
        }
    }

    /// Non-streaming chat completion; returns the first choice's text.
    /// Reasoning is disabled; a provider that rejects the
    /// `reasoning` parameter gets the same call once more without it.
    func chatCompletion(
        apiKey: String,
        model: String,
        messages: [ChatMessage],
        maxTokens: Int? = nil,
        denyDataCollection: Bool
    ) async throws -> String {
        try await Self.withReasoningFallback { disableReasoning in
            var req = request(path: "chat/completions", apiKey: apiKey, timeout: Self.chatTimeout)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try Self.chatRequestBody(
                model: model, messages: messages, maxTokens: maxTokens,
                denyDataCollection: denyDataCollection, disableReasoning: disableReasoning
            )
            return try Self.decodeChatContent(try await send(req))
        }
    }

    /// First attempt with reasoning disabled; one retry without the
    /// `reasoning` parameter only when the provider's 400 names it.
    static func withReasoningFallback(
        _ attempt: (_ disableReasoning: Bool) async throws -> String
    ) async throws -> String {
        do {
            return try await attempt(true)
        } catch let error as OpenRouterError where rejectsReasoningParameter(error) {
            return try await attempt(false)
        }
    }

    /// A 400 whose provider message mentions `reasoning`.
    static func rejectsReasoningParameter(_ error: OpenRouterError) -> Bool {
        guard case .badRequest(let message?) = error else { return false }
        return message.localizedCaseInsensitiveContains("reasoning")
    }

    // MARK: Pure helpers (internal for tests)

    /// JSON body for `/chat/completions`. `provider.data_collection = "deny"`
    /// makes OpenRouter skip providers that store or train on prompts; when
    /// the user opts out we omit `provider` entirely so account defaults apply.
    /// `reasoning.enabled = false` keeps reasoning models from spending the
    /// whole output budget before writing.
    static func chatRequestBody(
        model: String,
        messages: [ChatMessage],
        maxTokens: Int?,
        denyDataCollection: Bool,
        disableReasoning: Bool = true
    ) throws -> Data {
        struct Provider: Encodable {
            let data_collection: String
        }
        struct Reasoning: Encodable {
            let enabled: Bool
        }
        struct Body: Encodable {
            let model: String
            let messages: [ChatMessage]
            let max_tokens: Int?
            let provider: Provider?
            let reasoning: Reasoning?
        }
        let body = Body(
            model: model,
            messages: messages,
            max_tokens: maxTokens,
            provider: denyDataCollection ? Provider(data_collection: "deny") : nil,
            reasoning: disableReasoning ? Reasoning(enabled: false) : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    static func decodeModels(_ data: Data) throws -> [OpenRouterModel] {
        /// Swallows a per-element failure instead of failing the whole array.
        struct Lossy: Decodable {
            let model: OpenRouterModel?
            init(from decoder: Decoder) throws {
                model = try? OpenRouterModel(from: decoder)
            }
        }
        struct Envelope: Decodable { let data: [Lossy] }
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).data.compactMap(\.model)
        } catch {
            throw OpenRouterError.decoding("\(error)")
        }
    }

    static func decodeChatContent(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
                let finish_reason: String?
            }
            let choices: [Choice]?
            let error: APIError?
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw OpenRouterError.decoding("\(error)")
        }
        // OpenRouter can report upstream failures inside a 200 body.
        if let error = response.error {
            throw OpenRouterError.classify(status: error.code ?? 500, message: error.message)
        }
        guard let choice = response.choices?.first else { throw OpenRouterError.emptyContent }
        let text = choice.message?.content ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw choice.finish_reason == "length" ? OpenRouterError.outputTruncated : OpenRouterError.emptyContent
        }
        return text
    }

    /// Provider message from an error body (`{"error": {"code", "message"}}`).
    static func errorMessage(from data: Data) -> String? {
        struct Envelope: Decodable { let error: APIError }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error.message
    }

    private struct APIError: Decodable {
        let code: Int?
        let message: String?

        private enum CodingKeys: String, CodingKey { case code, message }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // `code` is documented as a number but tolerate a string.
            code = (try? c.decodeIfPresent(Int.self, forKey: .code))
                ?? (try? c.decodeIfPresent(String.self, forKey: .code)).flatMap { Int($0) }
            message = try? c.decodeIfPresent(String.self, forKey: .message)
        }
    }

    // MARK: Transport

    private func request(path: String, apiKey: String?, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        // Attribution headers OpenRouter uses for its app rankings.
        req.setValue("https://github.com/pipo-arentsen/meetingvox", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("MeetingVox", forHTTPHeaderField: "X-Title")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OpenRouterError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.transport(Textos.OpenRouter.respuestaNoHTTP)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenRouterError.classify(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return data
    }
}
