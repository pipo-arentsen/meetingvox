import Foundation
import Testing

@testable import MeetingVox

@Suite struct DoctorCalendarTests {
    private func isWarn(_ check: Check) -> Bool {
        if case .warn = check.status { return true }
        return false
    }

    @Test func disabledAddsNoRowAndReadsNothing() {
        var reads = 0
        let checks = DoctorReport.checkCalendar(enabled: false, isBundled: true, status: { reads += 1; return .authorized }())
        #expect(checks.isEmpty)
        #expect(reads == 0)
        #expect(DoctorReport.checkCalendar(enabled: false, isBundled: false, status: .unavailable).isEmpty)
    }

    @Test func unbundledAndEnabledWarnsWithoutReadingTheStatus() throws {
        var reads = 0
        let checks = DoctorReport.checkCalendar(enabled: true, isBundled: false, status: { reads += 1; return .authorized }())
        #expect(reads == 0)
        let check = try #require(checks.first)
        #expect(checks.count == 1)
        guard case .warn(let message) = check.status else { Issue.record("not a warn"); return }
        #expect(message == "cannot be read outside MeetingVox.app")
    }

    @Test func bundledAuthorizedIsOk() throws {
        let check = try #require(DoctorReport.checkCalendar(enabled: true, isBundled: true, status: .authorized).first)
        guard case .ok = check.status else { Issue.record("not ok"); return }
    }

    @Test func bundledNotAuthorizedWarnsNeverFails() {
        for system in [CalendarSystemStatus.notDetermined, .denied, .restricted, .writeOnly, .unavailable] {
            let checks = DoctorReport.checkCalendar(enabled: true, isBundled: true, status: system)
            #expect(checks.count == 1, "\(system)")
            #expect(checks.allSatisfy(isWarn), "\(system)")
        }
        #expect(DoctorReport.allOK(DoctorReport.checkCalendar(enabled: true, isBundled: true, status: .denied)))
        #expect(DoctorReport.allOK(DoctorReport.checkCalendar(enabled: true, isBundled: false, status: .unavailable)))
    }

    @Test func theDeniedWarningPointsAtThePrivacyPane() throws {
        let check = try #require(DoctorReport.checkCalendar(enabled: true, isBundled: true, status: .denied).first)
        #expect(check.remediation?.contains("Calendarios") == true)
    }
}
