import Foundation
import Testing

@testable import MeetingVox

/// Candidate filter and the ranking tuple 1-6 of `CalendarEventMatcher`.
@Suite struct CalendarEventMatcherTests {
    private typealias F = CalendarFixtures
    private let recording = DateInterval(start: F.at(0), end: F.at(30))

    private func pick(_ events: [CalendarEventSnapshot], app: String? = nil) -> String? {
        CalendarEventMatcher.pick(from: events, recording: recording, meetingApp: app)?.id
    }

    // MARK: Candidates

    @Test func allDayCancelledAndSelfDeclinedAreNeverPicked() {
        #expect(pick([F.snapshot(id: "a", allDay: true)]) == nil)
        #expect(pick([F.snapshot(id: "b", cancelled: true)]) == nil)
        #expect(pick([F.snapshot(id: "c", selfStatus: .declined)]) == nil)
        // The same event, valid, is picked: the filter (not an empty list) produced nil above.
        #expect(pick([F.snapshot(id: "d")]) == "d")
        #expect(pick([F.snapshot(id: "a", allDay: true), F.snapshot(id: "z")]) == "z")
    }

    // MARK: Correction: involves the user, non-blank title

    @Test func aBlankTitleIsNeverACandidate() {
        #expect(pick([F.snapshot(id: "empty", title: "")]) == nil)
        #expect(pick([F.snapshot(id: "spaces", title: "  \n\t ")]) == nil)
        #expect(pick([F.snapshot(id: "empty", title: ""), F.snapshot(id: "named", title: "Weekly")]) == "named")
    }

    @Test func aSharedCalendarEventTheUserIsNotPartOfIsNeverLinked() {
        let others = F.snapshot(
            id: "a", organizer: F.person("Participante 1"), attendees: [F.person("Participante 1"), F.person("Participante 2")])
        #expect(pick([others]) == nil)
        let withoutMe = F.snapshot(id: "b", organizer: F.person("Participante 1"), attendees: [F.person("Participante 2")])
        #expect(pick([withoutMe]) == nil)
    }

    @Test func theUserAsOrganizerAsAttendeeOrWithNobodyElseInvitedIsACandidate() {
        #expect(pick([F.snapshot(id: "o", organizer: F.person("Yo", isSelf: true), attendees: [F.person("Participante 1")])]) == "o")
        #expect(pick([F.snapshot(id: "t", attendees: [F.person("Participante 1"), F.person("Yo", isSelf: true)])]) == "t")
        #expect(pick([F.snapshot(id: "s")]) == "s")
    }

    // MARK: Window

    @Test func anEventStartingEightMinutesBeforeIsACandidate() {
        // Ends 5 min before the recording starts, but overlaps the widened window.
        #expect(pick([F.snapshot(id: "early", start: -8, end: -5)]) == "early")
    }

    @Test func anEventEndedElevenMinutesBeforeIsNot() {
        #expect(pick([F.snapshot(id: "old", start: -60, end: -11)]) == nil)
    }

    @Test func anEventStartingAfterTheRecordingEndsIsNot() {
        #expect(pick([F.snapshot(id: "late", start: 31, end: 60)]) == nil)
        #expect(pick([F.snapshot(id: "during", start: 29, end: 60)]) == "during")
    }

    @Test func eventsTouchingTheWindowEdgesDoNotOverlap() {
        #expect(pick([F.snapshot(id: "edge", start: -60, end: -10)]) == nil)
        #expect(pick([F.snapshot(id: "edge2", start: 30, end: 60)]) == nil)
    }

    // MARK: Ranking

    @Test func selfInvolvedOutranksAnEventOfOthers() {
        let others = F.snapshot(
            id: "a", organizer: F.person("Participante 1"), attendees: [F.person("Participante 1"), F.person("Participante 2")])
        let mine = F.snapshot(id: "b", attendees: [F.person("Yo", isSelf: true), F.person("Participante 1")])
        #expect(pick([others, mine]) == "b")
        // Self as organizer counts too.
        let organized = F.snapshot(id: "c", organizer: F.person("Yo", isSelf: true), attendees: [F.person("Participante 1")])
        #expect(pick([others, organized]) == "c")
    }

    @Test func anEventWithoutAttendeesCountsAsMine() {
        let others = F.snapshot(id: "a", attendees: [F.person("Participante 1")])
        let solo = F.snapshot(id: "b")
        #expect(pick([others, solo]) == "b")
    }

    @Test func aVideoHostMatchingTheMeetingAppOutranksAnyOtherVideoURL() {
        let zoom = F.snapshot(id: "z", videoURLs: [URL(string: "https://example.zoom.us/j/123")!])
        let teams = F.snapshot(id: "t", videoURLs: [URL(string: "https://teams.microsoft.com/l/meetup-join/abc")!])
        #expect(pick([zoom, teams], app: "zoom") == "z")
        #expect(pick([zoom, teams], app: "teams") == "t")
        // Order of the input does not matter.
        #expect(pick([teams, zoom], app: "zoom") == "z")
    }

    @Test func aBrowserMeetingAppMatchesAWebBasedService() {
        let meet = F.snapshot(id: "m", videoURLs: [URL(string: "https://meet.google.com/abc-defg-hij")!])
        let zoom = F.snapshot(id: "z", videoURLs: [URL(string: "https://example.zoom.us/j/123")!])
        #expect(pick([zoom, meet], app: "brave") == "m")
    }

    @Test func anyVideoURLOutranksNone() {
        let video = F.snapshot(id: "v", videoURLs: [URL(string: "https://meet.google.com/abc")!])
        let plain = F.snapshot(id: "a")
        #expect(pick([plain, video], app: nil) == "v")
        #expect(pick([plain, video], app: "teams") == "v")
    }

    @Test func longerOverlapWinsThenClosestStartThenLowestID() {
        // Same rank 1-3; overlap with the recording [0, 30]: 30 vs 20.
        let long = F.snapshot(id: "z-long", start: -5, end: 40)
        let short = F.snapshot(id: "a-short", start: 10, end: 40)
        #expect(pick([short, long]) == "z-long")

        // Equal overlap (20): the one starting closer to the recording start wins.
        let near = F.snapshot(id: "z-near", start: -2, end: 20)
        let far = F.snapshot(id: "a-far", start: 10, end: 30)
        #expect(pick([far, near]) == "z-near")

        // Full tie: the lowest id, whatever the input order.
        let one = F.snapshot(id: "a1", start: 0, end: 30)
        let two = F.snapshot(id: "b2", start: 0, end: 30)
        #expect(pick([two, one]) == "a1")
        #expect(pick([one, two]) == "a1")
    }

    @Test func rankingIsDeterministicUnderPermutation() {
        let events = (0..<6).map { F.snapshot(id: "e\($0)", start: 0, end: 30) }
        let expected = pick(events)
        #expect(expected == "e0")
        for shift in 1..<events.count {
            let rotated = Array(events[shift...] + events[..<shift])
            #expect(pick(rotated) == expected)
        }
    }

    @Test func noCandidatesGivesNil() {
        #expect(CalendarEventMatcher.pick(from: [], recording: recording, meetingApp: "teams") == nil)
    }
}
