import AppKit
import Foundation

/// Deep links into System Settings. The pane identifiers of macOS 26 are not
/// documented, so each pane lists its specific anchor first and the Privacy
/// root last: the opener tries them in order and always lands somewhere useful.
enum SystemSettingsLink {
    static let privacyRoot = url("x-apple.systempreferences:com.apple.preference.security?Privacy")

    /// Specific pane first, `privacyRoot` last.
    static func candidates(for pane: SettingsPane, bundleID: String = AppIdentity.bundleID) -> [URL] {
        let security = "x-apple.systempreferences:com.apple.preference.security?"
        switch pane {
        case .microphone:
            return [url(security + "Privacy_Microphone"), privacyRoot]
        case .systemAudio:
            // "Screen & System Audio Recording": the audio-only anchor exists
            // from macOS 14.4, the screen one is the older spelling.
            return [url(security + "Privacy_AudioCapture"), url(security + "Privacy_ScreenCapture"), privacyRoot]
        case .localNetwork:
            return [url(security + "Privacy_LocalNetwork"), privacyRoot]
        case .notifications:
            let notifications = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            return [url(notifications + "?id=" + bundleID), url(notifications), privacyRoot]
        }
    }

    /// Sound › Input: the input tab first (macOS 13+), the Sound pane, then the
    /// pre-Ventura pane id. No `SettingsPane` case: only the pill's "Cambiar
    /// micrófono" uses it.
    static let soundInputCandidates: [URL] = [
        url("x-apple.systempreferences:com.apple.Sound-Settings.extension?input"),
        url("x-apple.systempreferences:com.apple.Sound-Settings.extension"),
        url("x-apple.systempreferences:com.apple.preference.sound"),
    ]

    /// Privacy › Calendars, then the Privacy root. No `SettingsPane` case: the
    /// onboarding permission rows do not list calendars (the toggle owns it).
    static let calendarsCandidates: [URL] = [
        url("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"),
        privacyRoot,
    ]

    /// Tries each Calendars candidate until `opener` reports success.
    @discardableResult
    static func openCalendars(using opener: (URL) -> Bool) -> URL? {
        calendarsCandidates.first(where: opener)
    }

    /// Tries each Sound candidate until `opener` reports success.
    @discardableResult
    static func openSoundInput(using opener: (URL) -> Bool) -> URL? {
        soundInputCandidates.first(where: opener)
    }

    /// `NSWorkspace` as the opener.
    @MainActor
    @discardableResult
    static func openSoundInputInSystemSettings() -> URL? {
        openSoundInput { NSWorkspace.shared.open($0) }
    }

    /// Tries each candidate until `opener` reports success; the URL that
    /// opened, or nil when none did.
    @discardableResult
    static func open(
        _ pane: SettingsPane, bundleID: String = AppIdentity.bundleID, using opener: (URL) -> Bool
    ) -> URL? {
        candidates(for: pane, bundleID: bundleID).first(where: opener)
    }

    /// `NSWorkspace` as the opener.
    @MainActor
    @discardableResult
    static func openInSystemSettings(_ pane: SettingsPane) -> URL? {
        open(pane) { NSWorkspace.shared.open($0) }
    }

    private static func url(_ string: String) -> URL {
        // Constants above; a typo is a programmer error found by the tests.
        URL(string: string)!
    }
}
