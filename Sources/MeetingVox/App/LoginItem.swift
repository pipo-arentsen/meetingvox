import Foundation
import ServiceManagement

// The launch-at-login mechanisms. Two implementations share one label so
// launchd can never run both:
//
// - `AgentServiceLoginItem`: `SMAppService.agent(plistName:)` over the plist
//   embedded in the bundle (`Packaging/LaunchAgents/`). Shows up in System
//   Settings > Login Items and restarts the app after a crash.
// - `LaunchAgentFileLoginItem`: a plain LaunchAgent in `~/Library/LaunchAgents`
//   pointing at the installed executable, for when the system rejects the
//   embedded one (for example a self-signed bundle).
//
// The decisions are pure (`LoginItemPlan`) or run over the `LoginItem`
// protocol (`LoginItemInstaller`), so they are tested with fakes. Neither
// touches the legacy `com.digimata.quill` agent.

enum LoginItemStatus: Equatable {
    case notRegistered
    case enabled
    /// Registered, but the user still has to allow it in Login Items.
    case requiresApproval
    /// The system can't find the service (for example the plist is not in the bundle).
    case notFound
}

protocol LoginItem {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// The file-based fallback, which can be dropped in two ways: `unregister`
/// stops its job, `removeFile` only deletes its file.
protocol FallbackLoginItem: LoginItem {
    /// Deletes the registration file and touches nothing running. Its label is
    /// the service job's too, so stopping "its" job could stop the service's.
    func removeFile() throws
}

// MARK: - Pure decisions

enum LoginItemPlan {
    /// What `SMAppService` said when asked to register.
    enum ServiceResult: Equatable {
        case enabled
        case requiresApproval
        case notFound
        case failed(String)

        /// The result of a `register()` that did not throw. `.notRegistered`
        /// afterwards means it silently did nothing, which is not success.
        init(status: LoginItemStatus) {
            switch status {
            case .enabled: self = .enabled
            case .requiresApproval: self = .requiresApproval
            case .notFound: self = .notFound
            case .notRegistered: self = .failed("the service is still not registered after registering")
            }
        }
    }

    enum Decision: Equatable {
        case useService
        /// Registered; the user has to allow it in System Settings > Login Items.
        /// Not a failure, so no fallback (the two would run side by side).
        case pendingApproval
        case fallback(reason: String)
        /// Not running from the installed bundle: a login item would point at
        /// a build directory. Nothing is tried.
        case refuseNotBundled
    }

    /// `serviceResult` is an autoclosure: the service is only asked to
    /// register when the bundle is the installed one.
    static func decide(isInstalledBundle: Bool, serviceResult: @autoclosure () -> ServiceResult) -> Decision {
        guard isInstalledBundle else { return .refuseNotBundled }
        switch serviceResult() {
        case .enabled: return .useService
        case .requiresApproval: return .pendingApproval
        case .notFound: return .fallback(reason: "the system did not find the embedded agent")
        case .failed(let message): return .fallback(reason: "registration failed: \(message)")
        }
    }

    /// True for `/Applications/MeetingVox.app` only. The fallback LaunchAgent
    /// hardcodes that path and an SMAppService registered from a build
    /// directory would survive it being rebuilt or deleted.
    static func isInstalledBundle(_ bundleURL: URL) -> Bool {
        bundleURL.resolvingSymlinksInPath().standardizedFileURL.path == AppIdentity.installedAppPath
    }
}

/// The fallback LaunchAgent as a property list. Pure: paths are inputs (launchd
/// does not expand `~`).
enum LaunchAgentPlist {
    static func make(label: String, executablePath: String, logPath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executablePath, "run"],
            "RunAtLoad": true,
            // Only an unsuccessful exit restarts: a normal quit and the
            // single-instance refusal exit 0 and must not respawn.
            "KeepAlive": ["SuccessfulExit": false] as [String: Bool],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
    }

    static func data(label: String, executablePath: String, logPath: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: make(label: label, executablePath: executablePath, logPath: logPath),
            format: .xml, options: 0
        )
    }
}

// MARK: - Installer (over the protocol)

enum LoginItemInstaller {
    enum Result: Equatable {
        case service
        case pendingApproval
        case fallback(reason: String)
        case refusedNotBundled

        /// The process exit code of `install --launch-at-login`. 3 = registered
        /// but not allowed yet: nothing starts at login until the user approves
        /// it, and a caller (`install-app.sh`) has to start the app itself.
        var exitCode: Int32 {
            switch self {
            case .service, .fallback: return 0
            case .refusedNotBundled: return 1
            case .pendingApproval: return Self.pendingApprovalExitCode
            }
        }

        static let pendingApprovalExitCode: Int32 = 3
    }

    struct UninstallReport: Equatable {
        var removedService = false
        var removedFallback = false
        /// One line per mechanism that failed; the other is still attempted.
        var failures: [String] = []
    }

    /// Registers the service, else the fallback. Idempotent: an enabled or
    /// approval-pending service is not registered again (that throws "already
    /// registered"), and a re-run with nothing to change makes no calls.
    ///
    /// Both mechanisms share one label, so which way a leftover fallback goes
    /// depends on who owns the label now. If the service is registered, its job
    /// owns it: only the fallback's file is deleted, because stopping "the
    /// fallback" would stop the live service job. If the service is not
    /// registered, the fallback is the active mechanism being replaced and is
    /// stopped before the service registers.
    static func install(service: LoginItem, fallback: FallbackLoginItem, isInstalledBundle: Bool) throws -> Result {
        if isInstalledBundle, fallback.status != .notRegistered {
            switch service.status {
            case .enabled, .requiresApproval: try fallback.removeFile()
            case .notRegistered, .notFound: try fallback.unregister()
            }
        }
        switch LoginItemPlan.decide(isInstalledBundle: isInstalledBundle, serviceResult: attempt(service)) {
        case .useService: return .service
        case .pendingApproval: return .pendingApproval
        case .refuseNotBundled: return .refusedNotBundled
        case .fallback(let reason):
            try fallback.register()
            return .fallback(reason: reason)
        }
    }

    /// Removes whichever is registered; both are attempted even if one fails.
    static func uninstall(service: LoginItem, fallback: LoginItem) -> UninstallReport {
        var report = UninstallReport()
        if service.status == .enabled || service.status == .requiresApproval {
            do { try service.unregister(); report.removedService = true } catch {
                report.failures.append("login item service: \(describe(error))")
            }
        }
        if fallback.status != .notRegistered {
            do { try fallback.unregister(); report.removedFallback = true } catch {
                report.failures.append("launch agent file: \(describe(error))")
            }
        }
        return report
    }

    private static func attempt(_ service: LoginItem) -> LoginItemPlan.ServiceResult {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: break
        }
        do { try service.register() } catch {
            // A throw can leave the registration in place (for example it went
            // through but the system wants approval): honour that state rather
            // than adding a second mechanism next to it.
            switch service.status {
            case .enabled: return .enabled
            case .requiresApproval: return .requiresApproval
            case .notRegistered, .notFound: return .failed(describe(error))
            }
        }
        return LoginItemPlan.ServiceResult(status: service.status)
    }

    /// Errors from the system (SMAppService throws `NSError`s) carry their
    /// text in `localizedDescription`; `String(describing:)` on one would
    /// print its domain and user info. Swift errors of ours are described by
    /// their own `description`, which `localizedDescription` would replace with
    /// "The operation couldn't be completed".
    static func describe(_ error: Error) -> String {
        type(of: error) is NSError.Type
            ? (error as NSError).localizedDescription
            : String(describing: error)
    }
}

// MARK: - Live implementations

enum LoginItemError: Error, CustomStringConvertible {
    case bootstrapFailed(status: Int32, stderr: String, plist: String)

    var description: String {
        switch self {
        case .bootstrapFailed(let status, let stderr, let plist):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "launchctl bootstrap exited \(status)\(detail.isEmpty ? "" : ": \(detail)"); "
                + "the plist was written to \(plist) and loads at the next login"
        }
    }
}

struct AgentServiceLoginItem: LoginItem {
    private var service: SMAppService { SMAppService.agent(plistName: AppIdentity.agentPlistName) }

    var status: LoginItemStatus {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

struct LaunchAgentFileLoginItem: FallbackLoginItem {
    let home: URL
    let uid: uid_t
    /// Runs `launchctl <args>`; injected so tests never reach the real one.
    let launchctl: @Sendable ([String]) -> (status: Int32, stderr: String)

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        uid: uid_t = getuid(),
        launchctl: @escaping @Sendable ([String]) -> (status: Int32, stderr: String) = Self.runLaunchctl
    ) {
        self.home = home
        self.uid = uid
        self.launchctl = launchctl
    }

    private var file: URL { AppIdentity.launchAgentFile(home: home) }
    private var domain: String { "gui/\(uid)" }

    var status: LoginItemStatus {
        FileManager.default.fileExists(atPath: file.path) ? .enabled : .notRegistered
    }

    func register() throws {
        let logFile = AppIdentity.launchdLogFile(home: home)
        let fm = FileManager.default
        // launchd creates the log file but not its directory.
        try fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LaunchAgentPlist.data(
            label: AppIdentity.agentLabel,
            executablePath: AppIdentity.installedExecutablePath,
            logPath: logFile.path
        ).write(to: file, options: .atomic)

        // A previous load of this job would make bootstrap fail; bootout only
        // if it is loaded, since it stops whatever runs under this label.
        if isLoaded { _ = launchctl(["bootout", domain, file.path]) }
        let result = launchctl(["bootstrap", domain, file.path])
        if result.status != 0 {
            throw LoginItemError.bootstrapFailed(status: result.status, stderr: result.stderr, plist: file.path)
        }
    }

    /// With no file there is nothing to do and no `launchctl` call: this
    /// label is also the SMAppService job's, and a bootout would stop it.
    func unregister() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        if isLoaded { _ = launchctl(["bootout", domain, file.path]) }
        try FileManager.default.removeItem(at: file)
    }

    func removeFile() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    /// Whether launchd has a job under the label (`launchctl print` exits 0).
    private var isLoaded: Bool {
        launchctl(["print", "\(domain)/\(AppIdentity.agentLabel)"]).status == 0
    }

    static let runLaunchctl: @Sendable ([String]) -> (status: Int32, stderr: String) = { args in
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = FileHandle.nullDevice
        do { try task.run() } catch { return (-1, "\(error)") }
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: err, as: UTF8.self))
    }
}
