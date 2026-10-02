import Foundation
import Testing
@testable import MeetingVox

/// Records which `disableReasoning` values `withReasoningFallback` tried.
private final class AttemptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Bool] = []
    var values: [Bool] { lock.withLock { _values } }
    func append(_ value: Bool) { lock.withLock { _values.append(value) } }
}

@Suite struct OpenRouterClientTests {
    // MARK: - /models decoding

    @Test func decodesModelsSkippingMalformedEntries() throws {
        let payload = """
        {"data": [
          {"id": "openai/gpt-4o-mini", "name": "OpenAI: GPT-4o-mini", "context_length": 128000,
           "pricing": {"prompt": "0.00000015", "completion": "0.0000006", "input_cache_read": "0"},
           "architecture": {"modality": "text->text"}},
          {"name": "missing id"},
          {"id": "x/no-extras"}
        ]}
        """
        let models = try OpenRouterClient.decodeModels(Data(payload.utf8))
        #expect(models == [
            OpenRouterModel(id: "openai/gpt-4o-mini", name: "OpenAI: GPT-4o-mini", contextLength: 128000,
                            promptPrice: "0.00000015", completionPrice: "0.0000006"),
            OpenRouterModel(id: "x/no-extras", name: "x/no-extras", contextLength: nil,
                            promptPrice: nil, completionPrice: nil),
        ])
    }

    @Test func modelsEnvelopeMissingIsDecodingError() {
        #expect(throws: OpenRouterError.self) {
            try OpenRouterClient.decodeModels(Data("{\"models\": []}".utf8))
        }
    }

    // MARK: - Chat body

    private func body(deny: Bool, maxTokens: Int? = nil) throws -> [String: Any] {
        let data = try OpenRouterClient.chatRequestBody(
            model: "m/x", messages: [.system("s"), .user("u")], maxTokens: maxTokens, denyDataCollection: deny
        )
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func bodyDeniesDataCollectionWhenEnabled() throws {
        let json = try body(deny: true, maxTokens: 4000)
        #expect((json["provider"] as? [String: Any])?["data_collection"] as? String == "deny")
        #expect(json["model"] as? String == "m/x")
        #expect(json["max_tokens"] as? Int == 4000)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "s"], ["role": "user", "content": "u"]])
    }

    @Test func bodyOmitsProviderWhenDisabled() throws {
        let json = try body(deny: false)
        #expect(json["provider"] == nil)
        #expect(json["max_tokens"] == nil)
    }

    // MARK: - Chat response

    @Test func decodesChatContent() throws {
        let data = Data(##"{"choices":[{"message":{"role":"assistant","content":"# Minuta"}}]}"##.utf8)
        #expect(try OpenRouterClient.decodeChatContent(data) == "# Minuta")
    }

    @Test func emptyChatContentThrows() {
        let data = Data(#"{"choices":[{"message":{"content":"  "}}]}"#.utf8)
        #expect(throws: OpenRouterError.emptyContent) { try OpenRouterClient.decodeChatContent(data) }
    }

    @Test func errorInsideSuccessBodyIsClassified() {
        let data = Data(#"{"error":{"code":429,"message":"slow down"}}"#.utf8)
        #expect(throws: OpenRouterError.rateLimited("slow down")) { try OpenRouterClient.decodeChatContent(data) }
    }

    @Test func extractsErrorMessage() {
        let data = Data(#"{"error":{"message":"No auth credentials found","code":401}}"#.utf8)
        #expect(OpenRouterClient.errorMessage(from: data) == "No auth credentials found")
        #expect(OpenRouterClient.errorMessage(from: Data("<html>".utf8)) == nil)
    }

    // MARK: - Error classification

    @Test(arguments: [
        (400, false), (401, false), (402, false), (403, false), (404, false),
        (408, true), (429, true), (500, true), (502, true), (503, true),
    ])
    func retryability(status: Int, retryable: Bool) {
        #expect(OpenRouterError.classify(status: status, message: nil).isRetryable == retryable)
    }

    @Test func classification() {
        #expect(OpenRouterError.classify(status: 401, message: "m") == .unauthorized("m"))
        #expect(OpenRouterError.classify(status: 403, message: nil) == .unauthorized(nil))
        #expect(OpenRouterError.classify(status: 400, message: nil) == .badRequest(nil))
        #expect(OpenRouterError.classify(status: 402, message: nil) == .insufficientCredits(nil))
        #expect(OpenRouterError.classify(status: 429, message: nil) == .rateLimited(nil))
        #expect(OpenRouterError.classify(status: 503, message: nil) == .server(status: 503, message: nil))
        #expect(OpenRouterError.classify(status: 418, message: nil) == .unexpectedStatus(418, nil))
    }

    @Test func nonStatusErrorsRetryability() {
        #expect(OpenRouterError.transport("offline").isRetryable)
        #expect(!OpenRouterError.decoding("x").isRetryable)
        #expect(!OpenRouterError.emptyContent.isRetryable)
    }

    // MARK: - Reasoning

    @Test func bodyDisablesReasoningByDefault() throws {
        let json = try body(deny: true)
        #expect(json["reasoning"] as? [String: Bool] == ["enabled": false])
    }

    @Test func bodyOmitsReasoningWhenAskedTo() throws {
        let data = try OpenRouterClient.chatRequestBody(
            model: "m/x", messages: [.user("u")], maxTokens: nil, denyDataCollection: false, disableReasoning: false
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["reasoning"] == nil)
    }

    @Test func emptyContentCutByTheLengthLimitIsOutputTruncated() {
        let empty = Data(#"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#.utf8)
        #expect(throws: OpenRouterError.outputTruncated) { try OpenRouterClient.decodeChatContent(empty) }
        let null = Data(#"{"choices":[{"message":{"content":null},"finish_reason":"length"}]}"#.utf8)
        #expect(throws: OpenRouterError.outputTruncated) { try OpenRouterClient.decodeChatContent(null) }
    }

    @Test func emptyContentWithAnotherFinishReasonIsStillEmptyContent() {
        let data = Data(#"{"choices":[{"message":{"content":" "},"finish_reason":"stop"}]}"#.utf8)
        #expect(throws: OpenRouterError.emptyContent) { try OpenRouterClient.decodeChatContent(data) }
    }

    @Test func outputTruncatedIsNotRetryableAndHasSpanishCopy() {
        #expect(!OpenRouterError.outputTruncated.isRetryable)
        #expect(OpenRouterError.outputTruncated.errorDescription == Textos.OpenRouter.errorTruncada)
        #expect(MinutesRetryPolicy.decide(error: OpenRouterError.outputTruncated, retriesSoFar: 0) == .fail)
    }

    @Test func reasoningRejectionRetriesOnceWithoutIt() async throws {
        let log = AttemptLog()
        let text = try await OpenRouterClient.withReasoningFallback { disable in
            log.append(disable)
            if disable { throw OpenRouterError.badRequest("Unrecognized request argument: reasoning") }
            return "# Minuta"
        }
        #expect(text == "# Minuta")
        #expect(log.values == [true, false])
    }

    @Test func otherBadRequestsAreNotRetried() async {
        let log = AttemptLog()
        await #expect(throws: OpenRouterError.badRequest("m/x is not a valid model ID")) {
            try await OpenRouterClient.withReasoningFallback { disable in
                log.append(disable)
                throw OpenRouterError.badRequest("m/x is not a valid model ID")
            }
        }
        #expect(log.values == [true])
    }

    @Test func aFailedRetryPropagatesItsError() async {
        let log = AttemptLog()
        await #expect(throws: OpenRouterError.rateLimited(nil)) {
            try await OpenRouterClient.withReasoningFallback { disable in
                log.append(disable)
                if disable { throw OpenRouterError.badRequest("reasoning is not supported") }
                throw OpenRouterError.rateLimited(nil)
            }
        }
        #expect(log.values == [true, false])
    }

    @Test(arguments: [
        (OpenRouterError.badRequest("Reasoning is not supported for this model"), true),
        (OpenRouterError.badRequest("invalid model"), false),
        (OpenRouterError.badRequest(nil), false),
        (OpenRouterError.unexpectedStatus(422, "reasoning"), false),
    ])
    func detectsAReasoningRejection(error: OpenRouterError, expected: Bool) {
        #expect(OpenRouterClient.rejectsReasoningParameter(error) == expected)
    }
}
