import Foundation
import Observation
import ServiceManagement

/// The Listo step's "abrir al iniciar sesión" row.
///
/// Pure on purpose: `map` only reads what the two mechanisms report
/// (`LoginItemStatus` of the embedded service and of the fallback file), so
/// every combination is tested without `SMAppService` or `launchctl`.
enum LoginItemRow: Equatable {
    case enabled
    /// Registered, waiting for the user to allow it in Login Items.
    case pendingApproval
    case off
    /// Not the installed bundle (`/Applications/MeetingVox.app`): a login
    /// item would point at a build directory, so the row cannot be changed.
    case unavailable

    /// What tapping the row does.
    enum Tap: Equatable {
        case install
        case uninstall
        case openLoginItemsSettings
        case none
    }

    /// A registration that exists is reported as it is, wherever the app
    /// runs; only an unregistered row depends on where the bundle is. The
    /// service awaiting approval wins over a leftover fallback file (the
    /// installer removes it once the service is registered).
    static func map(service: LoginItemStatus, fallback: LoginItemStatus, isInstalledBundle: Bool) -> LoginItemRow {
        if service == .requiresApproval { return .pendingApproval }
        if service == .enabled || fallback == .enabled { return .enabled }
        return isInstalledBundle ? .off : .unavailable
    }

    var tap: Tap {
        switch self {
        case .off: .install
        case .enabled: .uninstall
        case .pendingApproval: .openLoginItemsSettings
        case .unavailable: .none
        }
    }
}

/// Drives the row. Everything that touches the system is an injected closure
/// (`install` and `uninstall` may block on `launchctl`, so they run detached),
/// which is what lets the tests use fakes; `live()` wires the real ones.
@MainActor
@Observable
final class LoginItemController {
    private(set) var row: LoginItemRow
    /// Shown under the row after a failed install or uninstall.
    private(set) var message: String?

    @ObservationIgnored private let readStatus: () -> (service: LoginItemStatus, fallback: LoginItemStatus)
    @ObservationIgnored private let isInstalledBundle: Bool
    @ObservationIgnored private let isRecording: () -> Bool
    @ObservationIgnored private let install: @Sendable () throws -> LoginItemInstaller.Result
    @ObservationIgnored private let uninstall: @Sendable () -> LoginItemInstaller.UninstallReport
    @ObservationIgnored private let openLoginItemsSettings: () -> Void

    init(
        readStatus: @escaping () -> (service: LoginItemStatus, fallback: LoginItemStatus),
        isInstalledBundle: Bool,
        isRecording: @escaping () -> Bool,
        install: @escaping @Sendable () throws -> LoginItemInstaller.Result,
        uninstall: @escaping @Sendable () -> LoginItemInstaller.UninstallReport,
        openLoginItemsSettings: @escaping () -> Void
    ) {
        self.readStatus = readStatus
        self.isInstalledBundle = isInstalledBundle
        self.isRecording = isRecording
        self.install = install
        self.uninstall = uninstall
        self.openLoginItemsSettings = openLoginItemsSettings
        let status = readStatus()
        row = .map(service: status.service, fallback: status.fallback, isInstalledBundle: isInstalledBundle)
    }

    /// Re-reads the statuses (also after the user approved the item in
    /// System Settings and came back).
    func refresh() {
        let status = readStatus()
        row = .map(service: status.service, fallback: status.fallback, isInstalledBundle: isInstalledBundle)
    }

    /// Registering or unregistering can stop or restart the launchd job the
    /// app itself runs under, so neither happens during a recording. Opening
    /// the Login Items pane is harmless and stays available.
    var recordingBlocked: Bool {
        (row.tap == .install || row.tap == .uninstall) && isRecording()
    }

    /// One click on the row.
    func tap() async {
        if recordingBlocked {
            message = Textos.Onboarding.inicioGrabando
            return
        }
        switch row.tap {
        case .none:
            return
        case .openLoginItemsSettings:
            openLoginItemsSettings()
        case .install:
            let install = self.install
            do {
                _ = try await Task.detached { try install() }.value
                message = nil
            } catch {
                FileHandle.standardError.write(Data("onboarding: login item install failed: \(error)\n".utf8))
                message = Textos.Onboarding.inicioFallo
            }
            refresh()
        case .uninstall:
            let uninstall = self.uninstall
            let report = await Task.detached { uninstall() }.value
            message = report.failures.isEmpty ? nil : Textos.Onboarding.inicioFallo
            for failure in report.failures {
                FileHandle.standardError.write(Data("onboarding: login item: \(failure)\n".utf8))
            }
            refresh()
        }
    }

    /// The real mechanisms. The embedded service is only asked when the
    /// process is the bundled app; unbundled it reads as not found.
    static func live(isRecording: @escaping () -> Bool) -> LoginItemController {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bundled = NotifierFactory.currentKind == .userNotifications
        let installed = LoginItemPlan.isInstalledBundle(Bundle.main.bundleURL)
        return LoginItemController(
            readStatus: {
                (bundled ? AgentServiceLoginItem().status : .notFound, LaunchAgentFileLoginItem(home: home).status)
            },
            isInstalledBundle: installed,
            isRecording: isRecording,
            install: {
                try LoginItemInstaller.install(
                    service: AgentServiceLoginItem(), fallback: LaunchAgentFileLoginItem(home: home),
                    isInstalledBundle: installed
                )
            },
            uninstall: {
                LoginItemInstaller.uninstall(service: AgentServiceLoginItem(), fallback: LaunchAgentFileLoginItem(home: home))
            },
            openLoginItemsSettings: { SMAppService.openSystemSettingsLoginItems() }
        )
    }
}
