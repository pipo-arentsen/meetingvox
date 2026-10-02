import Foundation
import Testing

@testable import MeetingVox

/// `calendar.enabled`, default off; additive, never throws.
@Suite struct CalendarConfigTests {
    @Test func defaultsToOffWhenMissing() {
        let v = ConfigValues(raw: [:])
        #expect(v.calendarEnabled == false)
        #expect(v.calendarFormatError == nil)
        #expect(ConfigValues(raw: ["calendar": [:] as [String: Any]]).calendarEnabled == false)
    }

    @Test func readsTheToggle() {
        #expect(ConfigValues(raw: ["calendar": ["enabled": true]]).calendarEnabled == true)
        #expect(ConfigValues(raw: ["calendar": ["enabled": false]]).calendarEnabled == false)
        #expect(ConfigValues(raw: ["calendar": ["enabled": true]]).calendarFormatError == nil)
    }

    @Test func malformedMeansOffAndIsReported() {
        for bad: Any in ["yes", 1, 0] {
            let v = ConfigValues(raw: ["calendar": ["enabled": bad]])
            #expect(v.calendarEnabled == false)
            #expect(v.calendarFormatError == "calendar.enabled")
        }
        let notObject = ConfigValues(raw: ["calendar": "on"])
        #expect(notObject.calendarEnabled == false)
        #expect(notObject.calendarFormatError == "calendar")
    }

    @Test func writingTheToggleKeepsUnknownKeysNestedToo() {
        var raw: [String: Any] = ["calendar": ["future": 1], "glossary": ["x"], "unknown_top": "keep"]
        ConfigStore.set(true, at: ["calendar", "enabled"], in: &raw)
        let values = ConfigValues(raw: raw)
        #expect(values.calendarEnabled == true)
        #expect((raw["calendar"] as? [String: Any])?["future"] as? Int == 1)
        #expect(raw["unknown_top"] as? String == "keep")
        #expect((raw["glossary"] as? [String]) == ["x"])
    }
}
