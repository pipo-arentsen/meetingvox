import Foundation
import Testing

@testable import MeetingVox

/// The fallback LaunchAgent is a plain plist, so it is built by a pure
/// function and checked by reading it back; the embedded one (an SMAppService
/// agent inside the bundle) is a checked-in file that must agree with the
/// constants the code relies on.
@Suite("LaunchAgentPlist")
struct LaunchAgentPlistTests {
    private func make(
        label: String = AppIdentity.agentLabel,
        executable: String = AppIdentity.installedExecutablePath,
        log: String = "/Users/x/Library/Logs/MeetingVox/launchd.log"
    ) -> [String: Any] {
        LaunchAgentPlist.make(label: label, executablePath: executable, logPath: log)
    }

    // MARK: - fallback plist

    @Test func runsTheInstalledExecutableWithRunUnderTheSharedLabel() {
        let plist = make()
        #expect(plist["Label"] as? String == "com.pipostudio.meetingvox.agent")
        #expect(plist["ProgramArguments"] as? [String]
            == ["/Applications/MeetingVox.app/Contents/MacOS/MeetingVox", "run"])
        #expect(plist["RunAtLoad"] as? Bool == true)
    }

    @Test func restartsOnlyAfterAnUnsuccessfulExit() {
        // Exit 0 is the single-instance refusal and a normal quit: respawning
        // it would loop.
        let keepAlive = make()["KeepAlive"] as? [String: Bool]
        #expect(keepAlive == ["SuccessfulExit": false])
    }

    @Test func isAnInteractiveAquaJobThatLogsToTheGivenFile() {
        let plist = make(log: "/tmp/x/launchd.log")
        #expect(plist["ProcessType"] as? String == "Interactive")
        #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(plist["StandardOutPath"] as? String == "/tmp/x/launchd.log")
        #expect(plist["StandardErrorPath"] as? String == "/tmp/x/launchd.log")
    }

    @Test func followsItsInputsRatherThanConstants() {
        let plist = make(label: "l.other", executable: "/opt/App/Contents/MacOS/App", log: "/l.log")
        #expect(plist["Label"] as? String == "l.other")
        #expect(plist["ProgramArguments"] as? [String] == ["/opt/App/Contents/MacOS/App", "run"])
        #expect(plist["StandardErrorPath"] as? String == "/l.log")
    }

    @Test func rendersAsAnXMLPropertyListThatReadsBackIdentically() throws {
        let data = try LaunchAgentPlist.data(label: AppIdentity.agentLabel, executablePath: AppIdentity.installedExecutablePath, logPath: "/a/b.log")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("<?xml"))
        var format = PropertyListSerialization.PropertyListFormat.xml
        let back = try #require(PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any])
        #expect(format == .xml)
        #expect(NSDictionary(dictionary: back).isEqual(to: make(log: "/a/b.log")))
    }

    // MARK: - embedded plist (SMAppService)

    private func embedded() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Packaging/LaunchAgents/\(AppIdentity.agentPlistName)")
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
    }

    @Test func theEmbeddedAgentPlistIsNamedAfterTheLabelAndRunsTheBundleProgram() throws {
        let plist = try embedded()
        #expect(plist["Label"] as? String == AppIdentity.agentLabel)
        // Relative to the bundle; no absolute path, no arguments (argument
        // routing makes a bare launch a `run`).
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/\(AppIdentity.executableName)")
        #expect(plist["Program"] == nil)
        #expect(plist["ProgramArguments"] == nil)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
        #expect(plist["ProcessType"] as? String == "Interactive")
        #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == [AppIdentity.bundleID])
    }

    @Test func theEmbeddedAgentPlistSetsNoLogPaths() throws {
        // launchd doesn't expand `~` and the bundle is shared by every user:
        // the app redirects its own stderr (LogRedirect) instead.
        let plist = try embedded()
        #expect(plist["StandardErrorPath"] == nil)
        #expect(plist["StandardOutPath"] == nil)
    }
}
