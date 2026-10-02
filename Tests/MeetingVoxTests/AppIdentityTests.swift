import Foundation
import Testing

@testable import MeetingVox

/// `AppIdentity` is the one place that lists what identifies the app. In
/// this slice of the rename only the in-process identifiers move; the
/// persistent ones (config dir, Keychain service, bundle id in the embedded
/// Info.plist) stay legacy until their migration ships, so both values live
/// side by side.
@Suite("AppIdentity")
struct AppIdentityTests {
    @Test func namesAreTheMeetingVoxOnes() {
        #expect(AppIdentity.displayName == "MeetingVox")
        #expect(AppIdentity.executableName == "MeetingVox")
        #expect(AppIdentity.commandName == "meetingvox")
        #expect(AppIdentity.bundleID == "com.pipostudio.meetingvox")
    }

    @Test func legacyIdentitiesAreKeptForTheMigration() {
        #expect(AppIdentity.legacyBundleID == "com.digimata.quill")
        #expect(AppIdentity.legacyKeychainService == "com.digimata.quill")
        #expect(AppIdentity.legacyConfigDirName == "quill")
        #expect(AppIdentity.legacyExecutablePath == "/usr/local/bin/quill")
    }

    @Test func queueLabelsAndNotificationNamesAreNamespacedByTheBundleID() {
        #expect(AppIdentity.queueLabel("mic.control") == "com.pipostudio.meetingvox.mic.control")
        #expect(AppIdentity.queueLabel("system-tap") == "com.pipostudio.meetingvox.system-tap")
        #expect(AppIdentity.notificationName("configDidChange").rawValue
            == "com.pipostudio.meetingvox.configDidChange")
        #expect(AppIdentity.notificationName("meetingIndexDidChange")
            != AppIdentity.notificationName("configDidChange"))
    }

    @Test func temporaryPrefixIsLowercaseAndDashed() {
        #expect(AppIdentity.tempPrefix == "meetingvox-")
    }

    // MARK: - Persistent identities (config dir, Keychain service)

    @Test func configDirsLiveUnderDotConfigOfTheGivenHome() {
        let home = URL(fileURLWithPath: "/h", isDirectory: true)
        #expect(AppIdentity.configDir(home: home).path == "/h/.config/meetingvox")
        #expect(AppIdentity.legacyConfigDir(home: home).path == "/h/.config/quill")
        #expect(AppIdentity.configDir(home: URL(fileURLWithPath: "/other", isDirectory: true)).path
            == "/other/.config/meetingvox")
    }

    @Test func keychainServiceIsTheBundleIDAndDiffersFromTheLegacyOne() {
        #expect(AppIdentity.keychainService == "com.pipostudio.meetingvox")
        #expect(AppIdentity.keychainService != AppIdentity.legacyKeychainService)
    }

    @Test func markerNamesAreStable() {
        #expect(AppIdentity.migrationMarker == ".migrated-from-quill")
        #expect(AppIdentity.keychainRetirementMarker(account: "hindsight_token")
            == ".keychain-legacy-done.hindsight_token")
        #expect(AppIdentity.keychainRetirementMarker(account: "openrouter_api_key")
            == ".keychain-legacy-done.openrouter_api_key")
    }

    // MARK: - Lifecycle paths (log, instance lock)

    @Test func logAndLockFilesLiveUnderLibraryOfTheGivenHome() {
        let home = URL(fileURLWithPath: "/h", isDirectory: true)
        #expect(AppIdentity.logDir(home: home).path == "/h/Library/Logs/MeetingVox")
        #expect(AppIdentity.logFile(home: home).path == "/h/Library/Logs/MeetingVox/meetingvox.log")
        #expect(AppIdentity.lockFile(home: home).path == "/h/Library/Application Support/MeetingVox/instance.lock")
        #expect(AppIdentity.logFile(home: URL(fileURLWithPath: "/other", isDirectory: true)).path
            == "/other/Library/Logs/MeetingVox/meetingvox.log")
    }

    // MARK: - Login item

    @Test func agentLabelsAreDistinctAndTheLegacyOneIsTheOldBundleID() {
        #expect(AppIdentity.agentLabel == "com.pipostudio.meetingvox.agent")
        #expect(AppIdentity.legacyAgentLabel == "com.digimata.quill")
        #expect(AppIdentity.agentLabel != AppIdentity.legacyAgentLabel)
        #expect(AppIdentity.agentPlistName == "com.pipostudio.meetingvox.agent.plist")
    }

    @Test func installedAppPathsAndAgentFilesFollowTheGivenHome() {
        #expect(AppIdentity.installedAppPath == "/Applications/MeetingVox.app")
        #expect(AppIdentity.installedExecutablePath == "/Applications/MeetingVox.app/Contents/MacOS/MeetingVox")
        let home = URL(fileURLWithPath: "/h", isDirectory: true)
        #expect(AppIdentity.launchAgentsDir(home: home).path == "/h/Library/LaunchAgents")
        #expect(AppIdentity.launchAgentFile(home: home).path == "/h/Library/LaunchAgents/com.pipostudio.meetingvox.agent.plist")
        #expect(AppIdentity.launchdLogFile(home: home).path == "/h/Library/Logs/MeetingVox/launchd.log")
        // Never the legacy agent's plist.
        #expect(AppIdentity.launchAgentFile(home: home).lastPathComponent != "com.digimata.quill.plist")
    }
}
