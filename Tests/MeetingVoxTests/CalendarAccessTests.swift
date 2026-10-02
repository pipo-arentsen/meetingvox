import Foundation
import Testing

@testable import MeetingVox

/// The pure access state and the one-request rule.
@Suite struct CalendarAccessTests {
    private typealias S = CalendarSystemStatus

    @Test func offWhenTheToggleIsOffWhateverTheSystemSays() {
        for system in [S.notDetermined, .authorized, .denied, .restricted, .writeOnly, .unavailable] {
            #expect(CalendarAccess.derive(enabled: false, system: system, requesting: false) == .off)
            #expect(CalendarAccess.derive(enabled: false, system: system, requesting: true) == .off)
        }
    }

    @Test func enabledFollowsTheSystemStatus() {
        #expect(CalendarAccess.derive(enabled: true, system: .notDetermined, requesting: false) == .notDetermined)
        #expect(CalendarAccess.derive(enabled: true, system: .authorized, requesting: false) == .authorized)
        #expect(CalendarAccess.derive(enabled: true, system: .denied, requesting: false) == .denied)
        #expect(CalendarAccess.derive(enabled: true, system: .restricted, requesting: false) == .restricted)
        #expect(CalendarAccess.derive(enabled: true, system: .unavailable, requesting: false) == .unavailable)
    }

    @Test func writeOnlyCountsAsDeniedBecauseWeNeedToReadEvents() {
        #expect(CalendarAccess.derive(enabled: true, system: .writeOnly, requesting: false) == .denied)
    }

    @Test func aRequestInFlightShowsRequestingWhileEnabled() {
        #expect(CalendarAccess.derive(enabled: true, system: .notDetermined, requesting: true) == .requesting)
        // Once the system answered, the answer wins over a stale flag.
        #expect(CalendarAccess.derive(enabled: true, system: .authorized, requesting: true) == .authorized)
    }

    // MARK: One request, only when undetermined

    @Test func turningOnRequestsOnlyWhenNotDetermined() {
        #expect(CalendarAccess.toggleOn(system: .notDetermined) == .request)
        for system in [S.authorized, .denied, .restricted, .writeOnly, .unavailable] {
            #expect(CalendarAccess.toggleOn(system: system) == CalendarAccess.ToggleAction.none)
        }
    }

    // MARK: effective gate

    @Test func effectiveNeedsEnabledAndAuthorized() {
        #expect(CalendarAccess.effective(enabled: true, system: .authorized))
        #expect(!CalendarAccess.effective(enabled: false, system: .authorized))
        #expect(!CalendarAccess.effective(enabled: true, system: .notDetermined))
        #expect(!CalendarAccess.effective(enabled: true, system: .denied))
        #expect(!CalendarAccess.effective(enabled: true, system: .writeOnly))
        #expect(!CalendarAccess.effective(enabled: true, system: .unavailable))
    }
}
