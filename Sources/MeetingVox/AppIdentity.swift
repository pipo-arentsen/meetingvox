import Foundation

/// Every identifier that names the app, in one place so it is easy to audit
/// what persists across launches.
///
/// The rename to MeetingVox happens in slices. In-process identifiers (queue
/// labels, notification names, tap names, temp prefixes), the config
/// directory and the Keychain service already use the new names, each paired
/// with its legacy `quill` value because a migration or fallback reads the
/// old one (`ConfigMigration`, `MigratingKeyStore`). The bundle id in
/// `Packaging/Info.plist` (assembled into `MeetingVox.app` by
/// `Scripts/build-app.sh`) is `bundleID`. Values here are plain constants;
/// nothing in this file touches disk.
enum AppIdentity {
    static let displayName = "MeetingVox"
    static let executableName = "MeetingVox"
    static let commandName = "meetingvox"

    static let bundleID = "com.pipostudio.meetingvox"
    static let legacyBundleID = "com.digimata.quill"

    /// Keychain service of the OpenRouter key and the Hindsight token.
    static let keychainService = bundleID
    static let legacyKeychainService = "com.digimata.quill"

    static let configDirName = "meetingvox"
    static let legacyConfigDirName = "quill"
    static let legacyExecutablePath = "/usr/local/bin/quill"

    /// Written inside the new config dir as the last step of the copy, so its
    /// presence means the migration finished.
    static let migrationMarker = ".migrated-from-quill"

    /// `~/.config/meetingvox` for the given home. Home is a parameter so tests
    /// never touch the real one.
    static func configDir(home: URL) -> URL {
        home.appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(configDirName, isDirectory: true)
    }

    /// `~/.config/meetingvox/notificaciones.desde`: an ISO 8601 instant.
    /// Sessions that started before it never get a "reunión lista" notice
    /// (see `NotificationCutoff`).
    static func notificationCutoffFile(home: URL) -> URL {
        configDir(home: home).appendingPathComponent("notificaciones.desde")
    }

    /// `~/.config/meetingvox/onboarding.json`: written only by "Empezar" in
    /// the onboarding window (see `OnboardingMarker`). Older builds ignore it.
    static func onboardingMarkerFile(home: URL) -> URL {
        configDir(home: home).appendingPathComponent("onboarding.json")
    }

    /// `~/.config/quill`: read by the migration, never written.
    static func legacyConfigDir(home: URL) -> URL {
        home.appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(legacyConfigDirName, isDirectory: true)
    }

    /// File inside the new config dir that retires the legacy Keychain item
    /// of `account`, so a secret deleted in Settings doesn't resurface.
    static let keychainRetirementMarkerPrefix = ".keychain-legacy-done."

    static func keychainRetirementMarker(account: String) -> String {
        keychainRetirementMarkerPrefix + account
    }

    /// `~/Library/Logs/MeetingVox`: where a bundled `run` sends stderr, since
    /// an app started by Finder or launchd has no terminal.
    static func logDir(home: URL) -> URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(displayName, isDirectory: true)
    }

    static let logFileName = "meetingvox.log"

    static func logFile(home: URL) -> URL {
        logDir(home: home).appendingPathComponent(logFileName)
    }

    /// The single-instance `flock` file. Application Support, not the config
    /// dir: it is process state, not user configuration.
    static func lockFile(home: URL) -> URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(displayName, isDirectory: true)
            .appendingPathComponent("instance.lock")
    }

    // MARK: Login item

    /// Label of the login-item job. The SMAppService agent embedded in the
    /// bundle and the fallback LaunchAgent file use the same label on purpose,
    /// so launchd can never run both at once.
    static let agentLabel = "com.pipostudio.meetingvox.agent"
    /// The legacy quill LaunchAgent. Never touched by this app's install or
    /// uninstall; only `Scripts/install-app.sh` retires it, on the user's say.
    static let legacyAgentLabel = "com.digimata.quill"
    /// File name of the embedded agent plist (`Contents/Library/LaunchAgents/`)
    /// and of the fallback LaunchAgent.
    static let agentPlistName = "\(agentLabel).plist"

    /// Where `Scripts/install-app.sh` puts the bundle. The fallback LaunchAgent
    /// points here, so the login item is only registered from this path.
    static let installedAppPath = "/Applications/\(displayName).app"
    static let installedExecutablePath = "\(installedAppPath)/Contents/MacOS/\(executableName)"

    static func launchAgentsDir(home: URL) -> URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    /// The fallback LaunchAgent plist.
    static func launchAgentFile(home: URL) -> URL {
        launchAgentsDir(home: home).appendingPathComponent(agentPlistName)
    }

    /// Where launchd writes the fallback agent's own stdout/stderr: catches a
    /// crash before `LogRedirect` takes over.
    static func launchdLogFile(home: URL) -> URL {
        logDir(home: home).appendingPathComponent("launchd.log")
    }

    /// Prefix for files created in the temporary directory.
    static let tempPrefix = "meetingvox-"

    /// Label for a `DispatchQueue`, namespaced by the bundle id.
    static func queueLabel(_ suffix: String) -> String { "\(bundleID).\(suffix)" }

    /// Name for an in-process `Notification`, namespaced by the bundle id.
    static func notificationName(_ suffix: String) -> Notification.Name {
        Notification.Name("\(bundleID).\(suffix)")
    }
}
