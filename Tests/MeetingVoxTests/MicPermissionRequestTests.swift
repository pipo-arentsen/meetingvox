import AVFoundation
import Testing
import UserNotifications

@testable import MeetingVox

@Suite("MicPermission.request")
struct MicPermissionRequestTests {
    @Test func authorizedNeedsNoRequest() {
        #expect(MicPermission.decision(for: .authorized) == .alreadyGranted)
    }

    @Test func notDeterminedAsks() {
        #expect(MicPermission.decision(for: .notDetermined) == .ask)
    }

    @Test func deniedAndRestrictedNeverAskAgain() {
        #expect(MicPermission.decision(for: .denied) == .denied)
        #expect(MicPermission.decision(for: .restricted) == .denied)
    }

    @Test func avStatusesMapToTheNeutralAuthorization() {
        #expect(SystemAuthorization(av: .authorized) == .authorized)
        #expect(SystemAuthorization(av: .notDetermined) == .notDetermined)
        #expect(SystemAuthorization(av: .denied) == .denied)
        #expect(SystemAuthorization(av: .restricted) == .restricted)
    }

    @Test func notificationStatusesMapToTheNeutralAuthorization() {
        #expect(SystemAuthorization(un: .authorized) == .authorized)
        #expect(SystemAuthorization(un: .provisional) == .authorized)
        #expect(SystemAuthorization(un: .notDetermined) == .notDetermined)
        #expect(SystemAuthorization(un: .denied) == .denied)
    }

    @Test func sharedSettingsAreNamedAfterTheApp() {
        #expect(PrivateTapPermissionPrimer.tapName == "\(AppIdentity.displayName) permission tap")
        #expect(PrivateTapPermissionPrimer.aggregateName == "\(AppIdentity.displayName)-permission-tap")
    }

    /// The onboarding "Permitir" and the lazy request in the notifier ask for
    /// the same thing, so the prompt shows the same options either way.
    @Test func notificationsAreRequestedForAlertsOnly() {
        #expect(UserNotificationsNotifier.authorizationOptions == [.alert])
    }
}
