import Foundation

/// The two OpenRouter calls the minutes pipeline makes. A protocol so tests
/// can drive the coordinator without the network.
protocol MinutesBackend: Sendable {
    func models() async throws -> [OpenRouterModel]
    func complete(
        apiKey: String, model: String, messages: [ChatMessage], maxTokens: Int, denyDataCollection: Bool
    ) async throws -> String
}

extension OpenRouterClient: MinutesBackend {
    func models() async throws -> [OpenRouterModel] { try await listModels() }

    func complete(
        apiKey: String, model: String, messages: [ChatMessage], maxTokens: Int, denyDataCollection: Bool
    ) async throws -> String {
        try await chatCompletion(
            apiKey: apiKey, model: model, messages: messages,
            maxTokens: maxTokens, denyDataCollection: denyDataCollection
        )
    }
}

/// Failures of the minutes pipeline that aren't OpenRouter errors. None are
/// retryable: each needs the user to fix settings or the session folder.
enum MinutesError: Error, CustomStringConvertible {
    case noModel
    case noAPIKey
    case keychain(String)
    case transcriptUnreadable(String)
    case emptyTranscript
    /// A template picked from the menu that no longer exists (or has an
    /// invalid id). Manual jobs fail rather than silently use another one.
    case templateNotFound(String)

    var description: String {
        switch self {
        case .noModel: "no OpenRouter model configured"
        case .noAPIKey: "no OpenRouter API key in the Keychain"
        case .keychain(let detail): "could not read the OpenRouter API key from the Keychain: \(detail)"
        case .transcriptUnreadable(let detail): "can't read transcript.json: \(detail)"
        case .emptyTranscript: "transcript has no text"
        case .templateNotFound(let id): "template \"\(id)\" not found or invalid"
        }
    }
}
