import Foundation
import Testing

@testable import MeetingVox

/// Which login-item mechanism the app uses is decided by pure functions over
/// what `SMAppService` reported; the installer runs over fake login items and
/// the fallback file item over a temp home with a recording `launchctl`, so
/// nothing here touches the real login items or LaunchAgents.
@Suite("LoginItem")
struct LoginItemTests {
    // MARK: - LoginItemPlan.decide

    @Test func anEnabledServiceIsUsed() {
        #expect(LoginItemPlan.decide(isInstalledBundle: true, serviceResult: .enabled) == .useService)
    }

    @Test func aServiceAwaitingApprovalIsReportedNotReplacedByTheFallback() {
        #expect(LoginItemPlan.decide(isInstalledBundle: true, serviceResult: .requiresApproval) == .pendingApproval)
    }

    @Test func aServiceThatCannotBeFoundFallsBack() {
        #expect(LoginItemPlan.decide(isInstalledBundle: true, serviceResult: .notFound)
            == .fallback(reason: "the system did not find the embedded agent"))
    }

    @Test func aServiceThatFailedFallsBackAndKeepsTheReason() {
        #expect(LoginItemPlan.decide(isInstalledBundle: true, serviceResult: .failed("Operation not permitted"))
            == .fallback(reason: "registration failed: Operation not permitted"))
    }

    @Test func outsideTheInstalledBundleNothingIsRegisteredAndTheServiceIsNeverTried() {
        var tried = false
        func attempt() -> LoginItemPlan.ServiceResult { tried = true; return .enabled }
        #expect(LoginItemPlan.decide(isInstalledBundle: false, serviceResult: attempt()) == .refuseNotBundled)
        #expect(!tried)
        #expect(LoginItemPlan.decide(isInstalledBundle: true, serviceResult: attempt()) == .useService)
        #expect(tried)
    }

    @Test func serviceStatusesMapToResults() {
        #expect(LoginItemPlan.ServiceResult(status: .enabled) == .enabled)
        #expect(LoginItemPlan.ServiceResult(status: .requiresApproval) == .requiresApproval)
        #expect(LoginItemPlan.ServiceResult(status: .notFound) == .notFound)
        // Registered without error yet still off: not something to leave silent.
        #expect(LoginItemPlan.ServiceResult(status: .notRegistered)
            == .failed("the service is still not registered after registering"))
    }

    // MARK: - LoginItemPlan.isInstalledBundle

    @Test func onlyTheApplicationsBundleCountsAsInstalled() {
        func installed(_ path: String) -> Bool { LoginItemPlan.isInstalledBundle(URL(fileURLWithPath: path)) }
        #expect(installed("/Applications/MeetingVox.app"))
        #expect(installed("/Applications/MeetingVox.app/"))
        #expect(!installed("/Users/x/quill/.build/app/MeetingVox.app"))
        #expect(!installed("/Users/x/Applications/MeetingVox.app"))
        #expect(!installed("/Applications/Other.app"))
        #expect(!installed("/Users/x/quill/.build/release"))
    }

    // MARK: - LoginItemInstaller (fakes)

    private final class Fake: FallbackLoginItem, @unchecked Sendable {
        var status: LoginItemStatus
        /// What `status` becomes after a successful register.
        var statusAfterRegister: LoginItemStatus
        var registerError: Error?
        var unregisterError: Error?
        /// What `status` becomes when `register` throws (a partial registration).
        var statusAfterFailedRegister: LoginItemStatus?
        private(set) var calls: [String] = []
        let log: CallLog

        init(_ name: String, status: LoginItemStatus = .notRegistered, afterRegister: LoginItemStatus = .enabled, log: CallLog) {
            self.name = name
            self.status = status
            self.statusAfterRegister = afterRegister
            self.log = log
        }
        let name: String
        func register() throws {
            log.add("\(name).register")
            if let registerError {
                if let statusAfterFailedRegister { status = statusAfterFailedRegister }
                throw registerError
            }
            status = statusAfterRegister
        }
        func removeFile() throws {
            log.add("\(name).removeFile")
            status = .notRegistered
        }
        func unregister() throws {
            log.add("\(name).unregister")
            if let unregisterError { throw unregisterError }
            status = .notRegistered
        }
    }

    private final class CallLog: @unchecked Sendable {
        private(set) var entries: [String] = []
        func add(_ s: String) { entries.append(s) }
    }

    private struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }

    @Test func installUsesTheServiceAndLeavesAnAbsentFallbackAlone() throws {
        let log = CallLog()
        let service = Fake("service", log: log), fallback = Fake("fallback", log: log)
        let result = try LoginItemInstaller.install(service: service, fallback: fallback, isInstalledBundle: true)
        #expect(result == .service)
        #expect(log.entries == ["service.register"])
    }

    @Test func installClearsAPreviousFallbackBeforeRegisteringTheService() throws {
        let log = CallLog()
        let service = Fake("service", log: log), fallback = Fake("fallback", status: .enabled, log: log)
        #expect(try LoginItemInstaller.install(service: service, fallback: fallback, isInstalledBundle: true) == .service)
        // The fallback shares the label: it goes first, so its bootout can
        // never stop the service job.
        #expect(log.entries == ["fallback.unregister", "service.register"])
    }

    @Test func installWithTheServiceAlreadyEnabledOnlyDeletesTheFallbackFile() throws {
        // Re-running install: the service job owns the label, so a bootout of
        // the fallback (which resolves to that label) would stop the live job.
        let log = CallLog()
        let service = Fake("service", status: .enabled, log: log), fallback = Fake("fallback", status: .enabled, log: log)
        #expect(try LoginItemInstaller.install(service: service, fallback: fallback, isInstalledBundle: true) == .service)
        #expect(log.entries == ["fallback.removeFile"])
    }

    @Test func installWithTheServiceAwaitingApprovalOnlyDeletesTheFallbackFile() throws {
        let log = CallLog()
        let service = Fake("service", status: .requiresApproval, log: log), fallback = Fake("fallback", status: .enabled, log: log)
        #expect(try LoginItemInstaller.install(service: service, fallback: fallback, isInstalledBundle: true) == .pendingApproval)
        #expect(log.entries == ["fallback.removeFile"])
    }

    @Test func aRerunWithNothingToChangeCallsNothing() throws {
        let log = CallLog()
        let service = Fake("service", status: .enabled, log: log), fallback = Fake("fallback", log: log)
        #expect(try LoginItemInstaller.install(service: service, fallback: fallback, isInstalledBundle: true) == .service)
        #expect(try LoginItemInstaller.install(service: service, fallback: fallback, isInstalledBundle: true) == .service)
        #expect(log.entries.isEmpty)
    }

    @Test func aServiceThatThrowsButEndsUpRegisteredIsNotReplacedByTheFallback() throws {
        let log = CallLog()
        let service = Fake("service", log: log), fallback = Fake("fallback", log: log)
        service.registerError = Boom()
        service.statusAfterFailedRegister = .requiresApproval
        #expect(try LoginItemInstaller.install(service: service, fallback: fallback, isInstalledBundle: true) == .pendingApproval)
        #expect(!log.entries.contains("fallback.register"))

        let log2 = CallLog()
        let service2 = Fake("service", log: log2), fallback2 = Fake("fallback", log: log2)
        service2.registerError = Boom()
        service2.statusAfterFailedRegister = .enabled
        #expect(try LoginItemInstaller.install(service: service2, fallback: fallback2, isInstalledBundle: true) == .service)
        #expect(!log2.entries.contains("fallback.register"))
    }

    @Test func eachResultHasItsOwnExitCode() {
        #expect(LoginItemInstaller.Result.service.exitCode == 0)
        #expect(LoginItemInstaller.Result.fallback(reason: "x").exitCode == 0)
        #expect(LoginItemInstaller.Result.refusedNotBundled.exitCode == 1)
        // Registered, but nothing starts at login until the user allows it:
        // a caller (install-app.sh) must be able to tell.
        #expect(LoginItemInstaller.Result.pendingApproval.exitCode == 3)
    }

    @Test func describeUsesTheLocalizedTextOfCocoaErrorsAndTheDescriptionOfOurs() {
        let cocoa = NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        #expect(LoginItemInstaller.describe(cocoa) == "Operation not permitted")
        #expect(LoginItemInstaller.describe(Boom()) == "boom")
    }

    @Test func installReportsPendingApprovalWithoutWritingTheFallback() throws {
        let log = CallLog()
        let service = Fake("service", afterRegister: .requiresApproval, log: log), fallback = Fake("fallback", log: log)
        #expect(try LoginItemInstaller.install(service: service, fallback: fallback, isInstalledBundle: true) == .pendingApproval)
        #expect(!log.entries.contains("fallback.register"))
    }

    @Test func installFallsBackWhenTheServiceRejects() throws {
        let log = CallLog()
        let service = Fake("service", log: log), fallback = Fake("fallback", log: log)
        service.registerError = Boom()
        let result = try LoginItemInstaller.install(service: service, fallback: fallback, isInstalledBundle: true)
        #expect(result == .fallback(reason: "registration failed: boom"))
        #expect(log.entries == ["service.register", "fallback.register"])
    }

    @Test func installFallsBackWhenTheServiceIsNotFound() throws {
        let log = CallLog()
        let service = Fake("service", afterRegister: .notFound, log: log), fallback = Fake("fallback", log: log)
        let result = try LoginItemInstaller.install(service: service, fallback: fallback, isInstalledBundle: true)
        #expect(result == .fallback(reason: "the system did not find the embedded agent"))
        #expect(log.entries.last == "fallback.register")
    }

    @Test func installIsIdempotentWhenTheServiceIsAlreadyEnabled() throws {
        let log = CallLog()
        let service = Fake("service", status: .enabled, log: log), fallback = Fake("fallback", log: log)
        #expect(try LoginItemInstaller.install(service: service, fallback: fallback, isInstalledBundle: true) == .service)
        // Registering twice throws "already registered": don't.
        #expect(!log.entries.contains("service.register"))
    }

    @Test func installOutsideTheInstalledBundleTouchesNothing() throws {
        let log = CallLog()
        let service = Fake("service", log: log), fallback = Fake("fallback", log: log)
        #expect(try LoginItemInstaller.install(service: service, fallback: fallback, isInstalledBundle: false) == .refusedNotBundled)
        #expect(log.entries.isEmpty)
    }

    @Test func aFailingFallbackWriteSurfaces() {
        let log = CallLog()
        let service = Fake("service", log: log), fallback = Fake("fallback", log: log)
        service.registerError = Boom()
        fallback.registerError = Boom()
        #expect(throws: Boom.self) {
            try LoginItemInstaller.install(service: service, fallback: fallback, isInstalledBundle: true)
        }
    }

    @Test func uninstallRemovesBothMechanisms() {
        let log = CallLog()
        let service = Fake("service", status: .enabled, log: log), fallback = Fake("fallback", status: .enabled, log: log)
        let report = LoginItemInstaller.uninstall(service: service, fallback: fallback)
        #expect(log.entries == ["service.unregister", "fallback.unregister"])
        #expect(report.failures.isEmpty)
        #expect(report.removedService && report.removedFallback)
    }

    @Test func uninstallIsIdempotentWhenNothingIsRegistered() {
        let log = CallLog()
        let service = Fake("service", status: .notRegistered, log: log), fallback = Fake("fallback", status: .notRegistered, log: log)
        let report = LoginItemInstaller.uninstall(service: service, fallback: fallback)
        #expect(log.entries.isEmpty)
        #expect(report.failures.isEmpty)
        #expect(!report.removedService && !report.removedFallback)
    }

    @Test func uninstallRemovesAnApprovalPendingService() {
        let log = CallLog()
        let service = Fake("service", status: .requiresApproval, log: log), fallback = Fake("fallback", log: log)
        _ = LoginItemInstaller.uninstall(service: service, fallback: fallback)
        #expect(log.entries == ["service.unregister"])
    }

    @Test func uninstallStillClearsTheFallbackWhenTheServiceFails() {
        let log = CallLog()
        let service = Fake("service", status: .enabled, log: log), fallback = Fake("fallback", status: .enabled, log: log)
        service.unregisterError = Boom()
        let report = LoginItemInstaller.uninstall(service: service, fallback: fallback)
        #expect(log.entries == ["service.unregister", "fallback.unregister"])
        #expect(report.failures == ["login item service: boom"])
        #expect(report.removedFallback && !report.removedService)
    }

    // MARK: - LaunchAgentFileLoginItem (temp home, recording launchctl)

    private final class Launchctl: @unchecked Sendable {
        private(set) var calls: [[String]] = []
        func forgetCalls() { calls.removeAll() }
        /// What `launchctl print gui/<uid>/<label>` reports: is the job loaded.
        var loaded = false
        /// Exit status of `launchctl bootstrap`.
        var bootstrapStatus: Int32 = 0
        func run(_ args: [String]) -> (status: Int32, stderr: String) {
            calls.append(args)
            let status: Int32
            switch args.first {
            case "print": status = loaded ? 0 : 113
            case "bootstrap": status = bootstrapStatus
            default: status = 0
            }
            return (status, status == 0 ? "" : "launchctl said no")
        }
    }

    private func tempHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-loginitem-\(UUID().uuidString)", isDirectory: true)
    }

    private func fileItem(_ home: URL, _ ctl: Launchctl) -> LaunchAgentFileLoginItem {
        LaunchAgentFileLoginItem(home: home, uid: 501, launchctl: { ctl.run($0) })
    }

    @Test func registerWritesThePlistAndBootstrapsItInTheUsersDomain() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ctl = Launchctl()
        let item = fileItem(home, ctl)
        #expect(item.status == .notRegistered)

        try item.register()

        let file = AppIdentity.launchAgentFile(home: home)
        let data = try Data(contentsOf: file)
        let plist = try #require(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == AppIdentity.agentLabel)
        #expect(plist["ProgramArguments"] as? [String] == [AppIdentity.installedExecutablePath, "run"])
        #expect(plist["StandardErrorPath"] as? String == AppIdentity.launchdLogFile(home: home).path)
        // The log directory exists so launchd can open its file.
        #expect(FileManager.default.fileExists(atPath: AppIdentity.launchdLogFile(home: home).deletingLastPathComponent().path))
        #expect(item.status == .enabled)
        // Not loaded: no bootout of a job that isn't there, just the bootstrap.
        #expect(ctl.calls == [["print", "gui/501/\(AppIdentity.agentLabel)"], ["bootstrap", "gui/501", file.path]])
    }

    @Test func registerBootsOutAJobThatIsLoadedBeforeBootstrappingAgain() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ctl = Launchctl()
        ctl.loaded = true
        try fileItem(home, ctl).register()
        let file = AppIdentity.launchAgentFile(home: home)
        #expect(ctl.calls == [
            ["print", "gui/501/\(AppIdentity.agentLabel)"],
            ["bootout", "gui/501", file.path],
            ["bootstrap", "gui/501", file.path],
        ])
    }

    @Test func aFailedBootstrapThrowsAndSaysWhereThePlistIs() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ctl = Launchctl()
        ctl.bootstrapStatus = 5
        let item = fileItem(home, ctl)

        #expect(throws: LoginItemError.self) { try item.register() }
        // The plist stays: it still loads at the next login.
        #expect(FileManager.default.fileExists(atPath: AppIdentity.launchAgentFile(home: home).path))
    }

    @Test func unregisterBootsOutALoadedJobAndRemovesTheFile() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ctl = Launchctl()
        let item = fileItem(home, ctl)
        try item.register()
        ctl.loaded = true
        ctl.forgetCalls()

        try item.unregister()

        let file = AppIdentity.launchAgentFile(home: home)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(ctl.calls == [["print", "gui/501/\(AppIdentity.agentLabel)"], ["bootout", "gui/501", file.path]])
        #expect(item.status == .notRegistered)
    }

    @Test func unregisterDoesNotBootOutAJobThatIsNotLoaded() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ctl = Launchctl()
        let item = fileItem(home, ctl)
        try item.register()
        ctl.forgetCalls()

        try item.unregister()

        #expect(!ctl.calls.contains { $0.first == "bootout" })
        #expect(item.status == .notRegistered)
    }

    @Test func removeFileDeletesTheFileWithoutAnyLaunchctlCall() throws {
        // The service job shares the label: its live job must survive.
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ctl = Launchctl()
        let item = fileItem(home, ctl)
        try item.register()
        ctl.loaded = true
        ctl.forgetCalls()

        try item.removeFile()

        #expect(!FileManager.default.fileExists(atPath: AppIdentity.launchAgentFile(home: home).path))
        #expect(ctl.calls.isEmpty)
        try item.removeFile()  // already gone: still fine
        #expect(ctl.calls.isEmpty)
    }

    @Test func unregisterWithoutAFileDoesNotCallLaunchctl() throws {
        // Same label as the SMAppService job: a bootout here would stop it.
        let home = tempHome()
        let ctl = Launchctl()
        try fileItem(home, ctl).unregister()
        #expect(ctl.calls.isEmpty)
    }

    @Test func noLaunchctlCallEverNamesTheLegacyAgent() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ctl = Launchctl()
        let item = fileItem(home, ctl)
        try item.register()
        try item.unregister()
        // Judged on the label and the plist's own name, not on the temp path
        // (which could contain anything).
        let file = AppIdentity.launchAgentFile(home: home)
        #expect(!ctl.calls.isEmpty)
        for arg in ctl.calls.flatMap({ $0 }) {
            #expect(!arg.contains(AppIdentity.legacyAgentLabel))
            #expect(["print", "bootout", "bootstrap", "gui/501", "gui/501/\(AppIdentity.agentLabel)", file.path].contains(arg))
        }
        #expect(file.lastPathComponent == AppIdentity.agentPlistName)
        #expect(file.lastPathComponent != "\(AppIdentity.legacyAgentLabel).plist")
    }
}
