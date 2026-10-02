import Foundation

/// Whether a summary is (or will be) produced for a session: the one
/// predicate `SummaryCoordinator.request` gates on and `SessionSettlement`
/// uses to decide whether to wait for one. Pure apart from the autoclosure.
enum SummaryGate {
    /// Summaries on, a transcript, a model and — checked last, because
    /// reading it may touch the Keychain — an API key.
    static func applies(
        config: ConfigValues, hasTranscript: Bool, hasAPIKey: @autoclosure () -> Bool
    ) -> Bool {
        guard config.summaryEnabled, hasTranscript, config.openRouterModel != nil else { return false }
        return hasAPIKey()
    }
}
