import Foundation
import Testing

@testable import MeetingVox

/// Video-service recognition, meeting-app matching and link extraction.
@Suite struct CalendarVideoLinkTests {
    private func service(_ url: String) -> CalendarVideoLink.Service? {
        CalendarVideoLink.service(for: URL(string: url)!)
    }

    @Test func recognisesTheMainServicesByHost() {
        #expect(service("https://teams.microsoft.com/l/meetup-join/x") == .teams)
        #expect(service("https://teams.live.com/meet/1") == .teams)
        #expect(service("https://example.zoom.us/j/99") == .zoom)
        #expect(service("https://zoom.us/j/99") == .zoom)
        #expect(service("https://meet.google.com/abc-defg-hij") == .meet)
        #expect(service("https://example.webex.com/meet/x") == .webex)
    }

    @Test func nonVideoHostsAndLookalikesAreNotServices() {
        #expect(service("https://example.com/zoom.us") == nil)
        #expect(service("https://notzoom.us/j/1") == nil)
        #expect(service("https://zoom.us.evil.example/j/1") == nil)
        #expect(service("ftp://zoom.us/j/1") == nil)
    }

    @Test func serviceMatchesItsMeetingAppRuleOrAnyBrowser() {
        #expect(CalendarVideoLink.Service.zoom.matches(meetingApp: "zoom"))
        #expect(!CalendarVideoLink.Service.zoom.matches(meetingApp: "teams"))
        #expect(CalendarVideoLink.Service.teams.matches(meetingApp: "teams"))
        #expect(CalendarVideoLink.Service.meet.matches(meetingApp: "brave"))
        #expect(CalendarVideoLink.Service.meet.matches(meetingApp: "safari"))
        #expect(CalendarVideoLink.Service.meet.matches(meetingApp: "webkit"))
        #expect(!CalendarVideoLink.Service.meet.matches(meetingApp: "zoom"))
        #expect(!CalendarVideoLink.Service.meet.matches(meetingApp: nil))
    }

    @Test func extractsHTTPLinksFromFreeTextAndSkipsTheRest() {
        let urls = CalendarVideoLink.extract(from: [
            "Join: https://example.zoom.us/j/99?pwd=abc please",
            nil,
            "Sala 3, piso 2",
            "mailto:ana@example.com",
            "https://meet.google.com/abc-defg-hij",
        ])
        #expect(urls.map(\.absoluteString) == [
            "https://example.zoom.us/j/99?pwd=abc", "https://meet.google.com/abc-defg-hij",
        ])
    }

    @Test func extractionDedupesAndKeepsFirstSeenOrder() {
        let urls = CalendarVideoLink.extract(from: ["https://zoom.us/j/1", "https://zoom.us/j/1 and https://zoom.us/j/2"])
        #expect(urls.map(\.absoluteString) == ["https://zoom.us/j/1", "https://zoom.us/j/2"])
    }
}
