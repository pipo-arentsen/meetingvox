import ArgumentParser
import Foundation

/// Manage MeetingVox's launch-at-login registration.
///
/// The mechanism is `SMAppService.agent(plistName:)` over the plist embedded in
/// the bundle (`LoginItem.swift`), with a plain LaunchAgent in
/// `~/Library/LaunchAgents` as the fallback when the system rejects it. Both use
/// the same label. This command never touches the legacy quill agent
/// (`com.digimata.quill`); `Scripts/install-app.sh` retires that one, on the
/// user's say.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Register or remove MeetingVox as a login item, or show its state.",
        discussion: """
            --launch-at-login only works from the installed app \
            (\(AppIdentity.installedAppPath)); --uninstall stops the login item, and with it a \
            running MeetingVox (a recording in progress is finalized first). \
            --launch-at-login may also restart a running MeetingVox when the LaunchAgent \
            fallback is the active mechanism and has to be replaced.

            Exit codes of --launch-at-login: 0 registered, 1 failed or refused, \
            \(LoginItemInstaller.Result.pendingApprovalExitCode) registered but the \
            user still has to allow it in System Settings > General > Login Items.
            """
    )

    @Flag(name: .long, help: "Register MeetingVox to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the login item (both the service and the fallback agent).")
    var uninstall: Bool = false

    @Flag(name: .long, help: "Show the login item state; changes nothing.")
    var status: Bool = false

    func run() throws {
        guard [launchAtLogin, uninstall, status].filter({ $0 }).count == 1 else {
            printError("specify exactly one of --launch-at-login, --uninstall or --status")
            throw ExitCode(64)
        }
        let service = AgentServiceLoginItem()
        let fallback = LaunchAgentFileLoginItem()

        if status {
            printStatus(service: service, fallback: fallback)
        } else if uninstall {
            try runUninstall(service: service, fallback: fallback)
        } else {
            try runInstall(service: service, fallback: fallback)
        }
    }

    // MARK: -

    private func runInstall(service: LoginItem, fallback: FallbackLoginItem) throws {
        let bundled = LoginItemPlan.isInstalledBundle(Bundle.main.bundleURL)
        let result: LoginItemInstaller.Result
        do {
            result = try LoginItemInstaller.install(service: service, fallback: fallback, isInstalledBundle: bundled)
        } catch {
            printError("could not register the login item: \(LoginItemInstaller.describe(error))")
            throw ExitCode(1)
        }
        switch result {
        case .service:
            print("✓ launch-at-login registered (login item service)")
        case .pendingApproval:
            print("! launch-at-login registered but not yet allowed")
            print("  Open System Settings > General > Login Items & Extensions and turn on \(AppIdentity.displayName).")
            print("  Until then nothing starts it at login (exit code \(result.exitCode)).")
            throw ExitCode(result.exitCode)
        case .fallback(let reason):
            print("✓ launch-at-login registered (LaunchAgent file; \(reason))")
            print("  plist: \(AppIdentity.launchAgentFile(home: FileManager.default.homeDirectoryForCurrentUser).path)")
        case .refusedNotBundled:
            printError(
                "not registering: this is not the installed app (\(Bundle.main.bundleURL.path)). "
                    + "Run it from \(AppIdentity.installedAppPath), for example through Scripts/install-app.sh."
            )
            throw ExitCode(result.exitCode)
        }
    }

    private func runUninstall(service: LoginItem, fallback: LoginItem) throws {
        let report = LoginItemInstaller.uninstall(service: service, fallback: fallback)
        for failure in report.failures { printError("could not remove \(failure)") }
        if !report.failures.isEmpty { throw ExitCode(1) }
        if report.removedService || report.removedFallback {
            var removed: [String] = []
            if report.removedService { removed.append("login item service") }
            if report.removedFallback { removed.append("LaunchAgent file") }
            print("✓ launch-at-login removed (\(removed.joined(separator: ", ")))")
        } else {
            print("nothing to remove (launch-at-login is not registered)")
        }
    }

    private func printStatus(service: LoginItem, fallback: LoginItem) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        print("login item service: \(Self.describe(service.status))")
        print("LaunchAgent file:   \(Self.describe(fallback.status)) (\(AppIdentity.launchAgentFile(home: home).path))")
        print("running from:       \(Bundle.main.bundleURL.path)"
            + (LoginItemPlan.isInstalledBundle(Bundle.main.bundleURL) ? "" : " (not the installed app; --launch-at-login would refuse)"))
        // Read-only: whether the legacy agent's plist is still in place.
        let legacy = AppIdentity.launchAgentsDir(home: home).appendingPathComponent("\(AppIdentity.legacyAgentLabel).plist")
        print("legacy quill agent: \(FileManager.default.fileExists(atPath: legacy.path) ? "plist present" : "no active plist") (never changed by this command)")
    }

    private static func describe(_ status: LoginItemStatus) -> String {
        switch status {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "waiting for approval in Login Items"
        case .notFound: return "not found by the system"
        }
    }

    private func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
