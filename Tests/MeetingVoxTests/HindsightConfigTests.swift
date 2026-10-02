import Foundation
import Testing
@testable import MeetingVox

@Suite struct HindsightConfigTests {
    private let mexico = TimeZone(identifier: "America/Mexico_City")!

    @Test func defaultsAreOffAndUnconfigured() {
        let v = ConfigValues(raw: [:])
        #expect(v.hindsightEnabled == false)
        #expect(v.hindsightAutoSend == false)
        #expect(v.hindsightBaseURL == nil)
        #expect(v.hindsightBank == nil)
        #expect(v.hindsightOwnerName == "Yo")
        #expect(v.hindsightOwnerDescription == "")
        #expect(v.hindsightSince == nil)
        #expect(v.hindsightMinWords == 150)
        #expect(v.hindsightMinMinutes == 2)
    }

    @Test func readsTheHindsightSection() {
        let v = ConfigValues(raw: ["hindsight": [
            "enabled": true, "auto_send": true, "base_url": " http://localhost:8888 ", "bank": "meetingvox",
            "owner_name": "Usuario", "owner_description": " quien grabó la reunión ", "since": "2026-09-24",
            "min_words": 200, "min_minutes": 5,
        ]])
        #expect(v.hindsightEnabled)
        #expect(v.hindsightAutoSend)
        #expect(v.hindsightBaseURL == URL(string: "http://localhost:8888"))
        #expect(v.hindsightBank == "meetingvox")
        #expect(v.hindsightOwnerName == "Usuario")
        #expect(v.hindsightOwnerDescription == "quien grabó la reunión")
        #expect(v.hindsightSince == "2026-09-24")
        #expect(v.hindsightMinWords == 200)
        #expect(v.hindsightMinMinutes == 5)
    }

    /// What a send needs from config.json besides the cutoff (the token is
    /// in the Keychain): base URL and bank, without `since`.
    @Test func baseURLAndBankDoNotNeedACutoff() {
        let v = ConfigValues(raw: ["hindsight": ["base_url": "http://h:8888", "bank": "meetingvox"]])
        #expect(v.hindsightSince == nil)
        #expect(v.hindsightBaseURL != nil)
        #expect(v.hindsightBank == "meetingvox")
    }

    @Test func invalidThresholdsFallBackToDefaults() {
        // `Any` isn't Sendable, so this is a loop rather than `@Test(arguments:)`.
        let cases: [(String, Any)] = [
            ("min_words", -1), ("min_words", 1.5), ("min_words", "150"), ("min_words", true),
            ("min_minutes", -3), ("min_minutes", false),
        ]
        for (key, value) in cases {
            let v = ConfigValues(raw: ["hindsight": [key: value]])
            #expect(v.hindsightMinWords == 150, "\(key) = \(value)")
            #expect(v.hindsightMinMinutes == 2, "\(key) = \(value)")
        }
    }

    @Test func zeroThresholdsAreAllowed() {
        let v = ConfigValues(raw: ["hindsight": ["min_words": 0, "min_minutes": 0]])
        #expect(v.hindsightMinWords == 0)
        #expect(v.hindsightMinMinutes == 0)
    }

    @Test(arguments: ["localhost:8888", "ftp://host", "http://", "not a url", "  "])
    func rejectsURLsWithoutHTTPSchemeOrHost(_ text: String) {
        #expect(ConfigValues(raw: ["hindsight": ["base_url": text]]).hindsightBaseURL == nil)
    }

    @Test(arguments: ["2026-9-24", "24-09-2026", "2026-02-30", "hoy", ""])
    func malformedSinceIsTreatedAsMissing(_ text: String) {
        #expect(ConfigValues(raw: ["hindsight": ["since": text]]).hindsightSince == nil)
    }

    @Test func dayUsesTheGivenTimeZone() {
        let date = ISO8601DateFormatter().date(from: "2026-09-24T03:00:00Z")!
        #expect(ConfigValues.hindsightDay(date, timeZone: mexico) == "2026-09-23")
        #expect(ConfigValues.hindsightDay(date, timeZone: TimeZone(identifier: "UTC")!) == "2026-09-24")
    }

    @Test func dayRoundTrips() throws {
        let date = try #require(ConfigValues.hindsightDate(fromDay: "2026-09-24", timeZone: mexico))
        #expect(ConfigValues.hindsightDay(date, timeZone: mexico) == "2026-09-24")
        #expect(ConfigValues.hindsightDate(fromDay: "2026-02-30", timeZone: mexico) == nil)
    }

    @Test func writingKeepsSiblingKeys() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-hindsight-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"hindsight": {"bank": "meetingvox", "extra": 1}, "summary": {"enabled": false}}"#.utf8).write(to: url)

        try ConfigStore.set("http://h:8888", at: "hindsight", "base_url", url: url)

        let raw = try ConfigStore.loadRaw(at: url)
        let v = ConfigValues(raw: raw)
        #expect(v.hindsightBaseURL == URL(string: "http://h:8888"))
        #expect(v.hindsightBank == "meetingvox")
        #expect(v.summaryEnabled == false)
        #expect((raw["hindsight"] as? [String: Any])?["extra"] as? Int == 1)
    }

    @Test func hindsightKeychainItem() {
        #expect(Keychain.hindsightPrimary.service == "com.pipostudio.meetingvox")
        #expect(Keychain.hindsightPrimary.account == "hindsight_token")
        #expect(Keychain.openRouterPrimary.service == "com.pipostudio.meetingvox")
        #expect(Keychain.openRouterPrimary.account == "openrouter_api_key")
        #expect(Keychain.hindsightPrimary.label != Keychain.openRouterPrimary.label)
        // The old items stay reachable as the one-time fallback.
        #expect(Keychain.hindsightLegacy.service == "com.digimata.quill")
        #expect(Keychain.hindsightLegacy.account == "hindsight_token")
        #expect(Keychain.openRouterLegacy.service == "com.digimata.quill")
        #expect(Keychain.openRouterLegacy.account == "openrouter_api_key")
    }
}
