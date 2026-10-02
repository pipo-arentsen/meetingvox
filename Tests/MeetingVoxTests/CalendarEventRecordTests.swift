import Foundation
import Testing

@testable import MeetingVox

/// The `calendar_event` meta.json record (additive, tolerant, whole seconds).
@Suite struct CalendarEventRecordTests {
    private typealias F = CalendarFixtures

    private func fullSnapshot() -> CalendarEventSnapshot {
        F.snapshot(
            id: "e9", title: "Weekly X", start: 0, end: 45,
            organizer: F.person("Participante 1", email: "p1@example.com", status: .accepted),
            attendees: [
                F.person("Yo", email: "me@example.com", isSelf: true, status: .accepted),
                F.person("Persona Invitada", email: "invitada@example.com", status: .tentative),
            ],
            videoURLs: [URL(string: "https://zoom.us/j/1")!])
    }

    @Test func buildsFromASnapshotAndTruncatesEveryDateToWholeSeconds() {
        let start = F.base.addingTimeInterval(0.789)
        let record = CalendarEventRecord(
            snapshot: F.snapshot(start: 0, end: 30), matchedAt: start)
        #expect(record.matchedAt == F.base)
        #expect(record.start == F.base)

        let fractional = CalendarEventRecord(
            id: "i", externalID: "x", title: "T", start: F.base.addingTimeInterval(10.9),
            end: F.base.addingTimeInterval(20.5), organizer: nil, attendees: [], matchedAt: F.base.addingTimeInterval(1.5))
        #expect(fractional.start == F.base.addingTimeInterval(10))
        #expect(fractional.end == F.base.addingTimeInterval(20))
        #expect(fractional.matchedAt == F.base.addingTimeInterval(1))
    }

    @Test func encodeThenDecodeRoundTripsEqual() throws {
        let record = CalendarEventRecord(snapshot: fullSnapshot(), matchedAt: F.at(61))
        let object = record.jsonObject
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let reparsed = try JSONSerialization.jsonObject(with: data)
        #expect(CalendarEventRecord(jsonObject: reparsed) == record)
        #expect(record.attendees.count == 2)
        #expect(record.organizer?.name == "Participante 1")
    }

    @Test func theJSONHasTheSpecKeysAndNoNotesURLOrLocation() throws {
        let record = CalendarEventRecord(snapshot: fullSnapshot(), matchedAt: F.at(61))
        let object = record.jsonObject
        #expect(Set(object.keys) == [
            "id", "external_id", "title", "start", "end", "organizer", "attendees", "matched_at",
        ])
        let text = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) ?? ""
        for forbidden in ["notes", "url", "location", "zoom.us"] {
            #expect(!text.lowercased().contains(forbidden), "\(forbidden) leaked into the record")
        }
        let organizer = try #require(object["organizer"] as? [String: Any])
        #expect(Set(organizer.keys) == ["name", "email", "is_self"])
        let first = try #require((object["attendees"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == ["name", "email", "status", "is_self"])
        #expect(first["is_self"] as? Bool == true)
        #expect(first["status"] as? String == "accepted")
    }

    @Test func datesAreISO8601WholeSeconds() {
        let object = CalendarEventRecord(snapshot: F.snapshot(start: 0, end: 30), matchedAt: F.at(31)).jsonObject
        #expect(object["start"] as? String == "2026-09-30T15:00:00Z")
        #expect(object["end"] as? String == "2026-09-30T15:30:00Z")
        #expect(object["matched_at"] as? String == "2026-09-30T15:31:00Z")
    }

    @Test func missingOrBlankTitleOrStartIsNil() {
        let good: [String: Any] = [
            "id": "1", "external_id": "x", "title": "T", "start": "2026-09-30T15:00:00Z",
            "end": "2026-09-30T16:00:00Z", "matched_at": "2026-09-30T15:01:00Z",
        ]
        #expect(CalendarEventRecord(jsonObject: good)?.title == "T")
        var noTitle = good; noTitle["title"] = nil
        #expect(CalendarEventRecord(jsonObject: noTitle) == nil)
        var blankTitle = good; blankTitle["title"] = "   "
        #expect(CalendarEventRecord(jsonObject: blankTitle) == nil)
        var noStart = good; noStart["start"] = nil
        #expect(CalendarEventRecord(jsonObject: noStart) == nil)
        var badStart = good; badStart["start"] = "yesterday"
        #expect(CalendarEventRecord(jsonObject: badStart) == nil)
        #expect(CalendarEventRecord(jsonObject: "not an object") == nil)
        #expect(CalendarEventRecord(jsonObject: nil) == nil)
    }

    @Test func malformedOptionalPartsAreDroppedNotFatal() throws {
        let object: [String: Any] = [
            "id": "1", "external_id": "x", "title": "T", "start": "2026-09-30T15:00:00Z",
            "end": "garbage", "matched_at": 7, "organizer": "Participante 1",
            "attendees": [["name": "Invitada", "status": "accepted", "is_self": false], "oops", ["is_self": "yes"], 3],
            "future_key": 1,
        ]
        let record = try #require(CalendarEventRecord(jsonObject: object))
        #expect(record.organizer == nil)
        #expect(record.attendees.map(\.name) == ["Invitada"])
        // A bad end falls back to the start, so the range stays valid.
        #expect(record.end == record.start)
    }
}
