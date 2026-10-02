import Foundation
import Testing

@testable import MeetingVox

/// `EKAuthorizationStatus` / `EKParticipantStatus` raw values map to our own
/// enums without touching EventKit (the pure half of the actor's mapping).
@Suite struct CalendarStatusMappingTests {
    @Test func authorizationRawValuesMap() {
        #expect(CalendarStatusMapping.system(rawValue: 0) == .notDetermined)
        #expect(CalendarStatusMapping.system(rawValue: 1) == .restricted)
        #expect(CalendarStatusMapping.system(rawValue: 2) == .denied)
        // 3 is both `.fullAccess` and the deprecated `.authorized`.
        #expect(CalendarStatusMapping.system(rawValue: 3) == .authorized)
        #expect(CalendarStatusMapping.system(rawValue: 4) == .writeOnly)
    }

    @Test func anUnknownRawValueIsDeniedNeverAuthorized() {
        #expect(CalendarStatusMapping.system(rawValue: 5) == .denied)
        #expect(CalendarStatusMapping.system(rawValue: -1) == .denied)
        #expect(CalendarStatusMapping.system(rawValue: 99) == .denied)
    }

    @Test func participantStatusRawValuesMap() {
        #expect(CalendarParticipantStatus(ekRawValue: 0) == .unknown)
        #expect(CalendarParticipantStatus(ekRawValue: 1) == .pending)
        #expect(CalendarParticipantStatus(ekRawValue: 2) == .accepted)
        #expect(CalendarParticipantStatus(ekRawValue: 3) == .declined)
        #expect(CalendarParticipantStatus(ekRawValue: 4) == .tentative)
        #expect(CalendarParticipantStatus(ekRawValue: 5) == .delegated)
        #expect(CalendarParticipantStatus(ekRawValue: 42) == .unknown)
    }

    @Test func participantStatusStringsRoundTrip() {
        for status in CalendarParticipantStatus.allCases {
            #expect(CalendarParticipantStatus(rawValue: status.rawValue) == status)
        }
        #expect(CalendarParticipantStatus.accepted.rawValue == "accepted")
    }

    @Test func mailtoURLsYieldAnEmailAndOthersDoNot() {
        #expect(CalendarStatusMapping.email(fromParticipantURL: URL(string: "mailto:p1@example.com")) == "p1@example.com")
        #expect(CalendarStatusMapping.email(fromParticipantURL: URL(string: "MAILTO:P1@Example.com")) == "P1@Example.com")
        #expect(CalendarStatusMapping.email(fromParticipantURL: URL(string: "https://example.com/p1")) == nil)
        #expect(CalendarStatusMapping.email(fromParticipantURL: URL(string: "mailto:")) == nil)
        #expect(CalendarStatusMapping.email(fromParticipantURL: nil) == nil)
    }
}
