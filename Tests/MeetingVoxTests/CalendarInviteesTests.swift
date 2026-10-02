import Foundation
import Testing

@testable import MeetingVox

/// `CalendarInvitees.offMac` is the only attendee view that may leave
/// the Mac: names only, never the user, never an email.
@Suite struct CalendarInviteesTests {
    private typealias F = CalendarFixtures

    private func record(organizer: CalendarParticipant? = nil, attendees: [CalendarParticipant]) -> CalendarEventRecord {
        CalendarEventRecord(
            snapshot: F.snapshot(organizer: organizer, attendees: attendees), matchedAt: F.at(1))
    }

    @Test func selfAndNamelessAreDropped() {
        let names = CalendarInvitees.offMac(record(attendees: [
            F.person("Yo", isSelf: true), F.person("Persona Invitada"), F.person(nil, email: "x@example.com"),
            F.person("   "), F.person("Participante 2"),
        ]))
        #expect(names == ["Persona Invitada", "Participante 2"])
    }

    @Test func aNameThatIsAnEmailAddressIsDropped() {
        let names = CalendarInvitees.offMac(record(attendees: [
            F.person("invitada@example.com"), F.person("Participante 1"), F.person("Participante 2 <p2@example.com>"),
        ]))
        #expect(names == ["Participante 1"])
        for name in names { #expect(!name.contains("@")) }
    }

    @Test func theOrganizerIsIncludedFirstUnlessItIsTheUser() {
        let theirs = CalendarInvitees.offMac(record(
            organizer: F.person("Participante 1", status: nil), attendees: [F.person("Participante 2"), F.person("Participante 1")]))
        #expect(theirs == ["Participante 1", "Participante 2"])
        let mine = CalendarInvitees.offMac(record(
            organizer: F.person("Yo", isSelf: true, status: nil), attendees: [F.person("Participante 2")]))
        #expect(mine == ["Participante 2"])
    }

    @Test func duplicatesAreMergedIgnoringCaseAndPadding() {
        let names = CalendarInvitees.offMac(record(attendees: [
            F.person("Persona Invitada"), F.person(" persona invitada "), F.person("Participante 2"),
        ]))
        #expect(names == ["Persona Invitada", "Participante 2"])
    }

    @Test func capsAtTwentyFiveKeepingOrder() {
        let thirty = (1...30).map { F.person("Persona \($0)") }
        let names = CalendarInvitees.offMac(record(attendees: thirty))
        #expect(CalendarInvitees.cap == 25)
        #expect(names.count == 25)
        #expect(names.first == "Persona 1")
        #expect(names.last == "Persona 25")
    }

    @Test func nothingLeftWhenOnlyTheUserIsInvited() {
        #expect(CalendarInvitees.offMac(record(attendees: [F.person("Yo", isSelf: true)])).isEmpty)
        #expect(CalendarInvitees.offMac(record(attendees: [])).isEmpty)
    }
}
