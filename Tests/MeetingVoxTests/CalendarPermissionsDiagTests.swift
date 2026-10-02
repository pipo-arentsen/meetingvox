import Foundation
import Testing

@testable import MeetingVox

@Suite struct CalendarPermissionsDiagTests {
    @Test func unbundledNeverReadsTheStatus() {
        var reads = 0
        let line = Diag.calendarLine(enabled: true, bundled: false, status: { reads += 1; return .authorized }())
        #expect(reads == 0)
        #expect(line.contains("not read (unbundled process)"))
        #expect(line.contains("calendar.enabled=true"))
    }

    @Test func bundledPrintsTheStatusOnly() {
        let line = Diag.calendarLine(enabled: false, bundled: true, status: .denied)
        #expect(line.contains("denied"))
        #expect(line.contains("calendar.enabled=false"))
        #expect(line.contains("nothing is requested"))
    }

    @Test func theCalendarsLinkTargetsItsAnchorThenThePrivacyRoot() {
        #expect(SystemSettingsLink.calendarsCandidates.first?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        #expect(SystemSettingsLink.calendarsCandidates.last == SystemSettingsLink.privacyRoot)
        var tried: [URL] = []
        let opened = SystemSettingsLink.openCalendars { tried.append($0); return $0 == SystemSettingsLink.privacyRoot }
        #expect(opened == SystemSettingsLink.privacyRoot)
        #expect(tried.count == 2)
    }
}
