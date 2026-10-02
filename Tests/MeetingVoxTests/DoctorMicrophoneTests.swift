import AVFoundation
import Testing

@testable import MeetingVox

/// A denied microphone must never abort startup: the system-audio track still
/// records and a menu-bar app that exits silently looks broken. Only `.warn`.
@Suite("Doctor microphone")
struct DoctorMicrophoneTests {
    private func kind(_ check: Check) -> String {
        switch check.status {
        case .ok: return "ok"
        case .warn: return "warn"
        case .fail: return "fail"
        }
    }

    @Test func deniedAndRestrictedAreWarningsNotFailures() {
        let denied = DoctorReport.checkMicrophone(status: .denied)
        let restricted = DoctorReport.checkMicrophone(status: .restricted)
        #expect(kind(denied) == "warn")
        #expect(kind(restricted) == "warn")
        #expect(denied.remediation?.contains("MeetingVox") == true)
        #expect(DoctorReport.allOK([denied, restricted]))
    }

    @Test func authorizedIsOKAndNotDeterminedStaysAWarning() {
        #expect(kind(DoctorReport.checkMicrophone(status: .authorized)) == "ok")
        #expect(kind(DoctorReport.checkMicrophone(status: .notDetermined)) == "warn")
    }

    @Test func aWarningMessageSaysThatSystemAudioStillRecords() {
        guard case .warn(let message) = DoctorReport.checkMicrophone(status: .denied).status else {
            Issue.record("expected a warning"); return
        }
        #expect(message.contains("denied"))
        #expect(message.contains("system audio"))
    }
}
