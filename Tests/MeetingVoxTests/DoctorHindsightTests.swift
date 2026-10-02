import Foundation
import Testing
@testable import MeetingVox

@Suite struct DoctorHindsightTests {
    private func isWarn(_ check: Check) -> Bool {
        if case .warn = check.status { return true }
        return false
    }

    private func isOK(_ check: Check) -> Bool {
        if case .ok = check.status { return true }
        return false
    }

    @Test func disabledIsOK() {
        let checks = DoctorReport.checkHindsight(config: ConfigValues(raw: [:]), hasToken: false)
        #expect(checks.map(\.name) == ["hindsight"])
        #expect(checks.allSatisfy(isOK))
    }

    @Test func enabledReportsEachMissingPieceAsAWarningOnly() {
        let checks = DoctorReport.checkHindsight(
            config: ConfigValues(raw: ["hindsight": ["enabled": true, "auto_send": true, "since": "ayer"]]), hasToken: false
        )
        #expect(checks.map(\.name) == ["hindsight token", "hindsight url", "hindsight bank", "hindsight since"])
        #expect(checks.allSatisfy(isWarn))
        #expect(DoctorReport.allOK(checks))
    }

    @Test func manualModeDoesNotNeedACutoff() {
        let config = ConfigValues(raw: ["hindsight": ["enabled": true, "base_url": "http://h:8888", "bank": "meetingvox"]])
        let checks = DoctorReport.checkHindsight(config: config, hasToken: true)
        #expect(checks.map(\.name) == ["hindsight"])
        #expect(checks.allSatisfy(isOK))
    }

    @Test func fullyConfiguredIsOK() {
        let config = ConfigValues(raw: ["hindsight": [
            "enabled": true, "base_url": "http://h:8888", "bank": "meetingvox", "since": "2026-09-24",
        ]])
        let checks = DoctorReport.checkHindsight(config: config, hasToken: true)
        #expect(checks.map(\.name) == ["hindsight"])
        #expect(checks.allSatisfy(isOK))
    }
}
