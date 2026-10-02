import Foundation
import Testing
@testable import MeetingVox

/// The two optional keys of the recording pill. Both are additive, so an
/// older build ignores them and a malformed value never throws.
@Suite struct ConfigValuesPillTests {
    @Test func defaults() {
        let v = ConfigValues(raw: [:])
        #expect(v.recordingPillEnabled == true)
        #expect(v.meetingDetectionAutoStop == false)
        #expect(MeetingDetectionConfig(v).autoStop == false)
        #expect(MeetingDetectionConfig().autoStop == false)
    }

    @Test func readsBothKeys() {
        let v = ConfigValues(raw: [
            "recording_pill": ["enabled": false],
            "meeting_detection": ["auto_stop": true],
        ])
        #expect(v.recordingPillEnabled == false)
        #expect(v.meetingDetectionAutoStop == true)
        #expect(MeetingDetectionConfig(v).autoStop == true)
        #expect(v.meetingDetectionFormatError == nil)
    }

    @Test func missingOrNonBoolPillFallsBackToDefault() {
        #expect(ConfigValues(raw: ["recording_pill": [:] as [String: Any]]).recordingPillEnabled == true)
        #expect(ConfigValues(raw: ["recording_pill": ["enabled": "no"]]).recordingPillEnabled == true)
        #expect(ConfigValues(raw: ["recording_pill": ["enabled": 0]]).recordingPillEnabled == true)
        #expect(ConfigValues(raw: ["recording_pill": "off"]).recordingPillEnabled == true)
    }

    @Test func malformedAutoStopRejectsTheWholeSectionLikePromptOnEnd() {
        for bad: Any in ["yes", 1, 0] {
            let v = ConfigValues(raw: ["meeting_detection": ["auto_stop": bad, "enabled": false, "prompt_on_end": false]])
            #expect(v.meetingDetectionFormatError == "meeting_detection.auto_stop")
            let snapshot = MeetingDetectionConfig(v)
            #expect(snapshot.formatError == "meeting_detection.auto_stop")
            #expect(snapshot.autoStop == false)
            // The whole section falls back to defaults.
            #expect(snapshot.enabled == true)
            #expect(snapshot.promptOnEnd == true)
        }
    }

    @Test func autoStopMissingIsOff() {
        let v = ConfigValues(raw: ["meeting_detection": ["enabled": true]])
        #expect(v.meetingDetectionAutoStop == false)
        #expect(v.meetingDetectionFormatError == nil)
    }
}
