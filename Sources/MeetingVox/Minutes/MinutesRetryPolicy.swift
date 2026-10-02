import Foundation

/// When a failed minutes request is tried again. Only transient OpenRouter
/// failures (`isRetryable`: transport, 429, 5xx/408) qualify; anything else
/// (bad key, model, credits, missing files) needs the user and fails at once.
enum MinutesRetryPolicy {
    /// Delay before retry 1, 2 and 3. Long on purpose: the usual causes are
    /// being offline or a provider outage, which don't clear in seconds.
    static let delays: [TimeInterval] = [30, 120, 600]

    enum Decision: Equatable {
        case retry(after: TimeInterval)
        /// Still a transient failure, but every retry was used. The request
        /// stays pending (resumed at next launch or by "Reintentar minuta")
        /// instead of being marked failed for good.
        case exhausted
        case fail
    }

    /// - Parameter retriesSoFar: retries already made for this job (0 after
    ///   the first attempt fails).
    static func decide(error: Error, retriesSoFar: Int) -> Decision {
        guard let error = error as? OpenRouterError, error.isRetryable else { return .fail }
        guard retriesSoFar < delays.count else { return .exhausted }
        return .retry(after: delays[retriesSoFar])
    }
}
