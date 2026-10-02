import Foundation
import Testing
@testable import MeetingVox

/// The predicate that decides whether a summary is awaited is the same
/// one `SummaryCoordinator.request` gates on, so it lives in one place.
@Suite struct SummaryGateTests {
    private func config(enabled: Bool? = nil, model: String? = "m/x") -> ConfigValues {
        var raw: [String: Any] = [:]
        if let enabled { raw["summary"] = ["enabled": enabled] }
        if let model { raw["openrouter"] = ["model": model] }
        return ConfigValues(raw: raw)
    }

    @Test func appliesWhenEnabledWithTranscriptModelAndKey() {
        #expect(SummaryGate.applies(config: config(), hasTranscript: true, hasAPIKey: true))
    }

    @Test func summariesDisabledMeansNotAwaited() {
        #expect(!SummaryGate.applies(config: config(enabled: false), hasTranscript: true, hasAPIKey: true))
    }

    @Test func noTranscriptMeansNotAwaited() {
        #expect(!SummaryGate.applies(config: config(), hasTranscript: false, hasAPIKey: true))
    }

    @Test func noModelMeansNotAwaited() {
        #expect(!SummaryGate.applies(config: config(model: nil), hasTranscript: true, hasAPIKey: true))
    }

    @Test func noKeyMeansNotAwaited() {
        #expect(!SummaryGate.applies(config: config(), hasTranscript: true, hasAPIKey: false))
    }

    /// The Keychain is read last: it is only asked when everything cheaper
    /// already passed.
    @Test func theKeychainIsOnlyConsultedWhenTheCheaperChecksPass() {
        final class Counter: @unchecked Sendable { var reads = 0 }
        let counter = Counter()
        func key() -> Bool { counter.reads += 1; return true }

        _ = SummaryGate.applies(config: config(enabled: false), hasTranscript: true, hasAPIKey: key())
        _ = SummaryGate.applies(config: config(), hasTranscript: false, hasAPIKey: key())
        _ = SummaryGate.applies(config: config(model: nil), hasTranscript: true, hasAPIKey: key())
        #expect(counter.reads == 0)

        #expect(SummaryGate.applies(config: config(), hasTranscript: true, hasAPIKey: key()))
        #expect(counter.reads == 1)
    }
}
