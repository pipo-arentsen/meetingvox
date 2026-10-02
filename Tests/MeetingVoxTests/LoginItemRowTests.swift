import Foundation
import Testing

@testable import MeetingVox

/// The Listo step's login-item row: a pure mapping over what the two
/// mechanisms report, and a controller over injected closures. Nothing here
/// reaches `SMAppService`, `launchctl` or System Settings.
@Suite("LoginItemRow.map")
struct LoginItemRowMapTests {
    private func map(
        _ service: LoginItemStatus, _ fallback: LoginItemStatus = .notRegistered, installed: Bool = true
    ) -> LoginItemRow {
        LoginItemRow.map(service: service, fallback: fallback, isInstalledBundle: installed)
    }

    @Test func nothingRegisteredInTheInstalledBundleIsOff() {
        #expect(map(.notRegistered) == .off)
        #expect(map(.notFound) == .off)  // the embedded plist is missing: nothing is registered
    }

    @Test func anEnabledServiceOrFallbackIsEnabled() {
        #expect(map(.enabled) == .enabled)
        #expect(map(.notRegistered, .enabled) == .enabled)
        #expect(map(.notFound, .enabled) == .enabled)
    }

    @Test func aServiceAwaitingApprovalIsPendingApprovalEvenWithALeftoverFile() {
        #expect(map(.requiresApproval) == .pendingApproval)
        #expect(map(.requiresApproval, .enabled) == .pendingApproval)
    }

    @Test func outsideApplicationsAnOffRowIsUnavailable() {
        #expect(map(.notRegistered, installed: false) == .unavailable)
        #expect(map(.notFound, .notRegistered, installed: false) == .unavailable)
    }

    @Test func aRegistrationThatExistsIsShownEvenOutsideApplications() {
        #expect(map(.enabled, installed: false) == .enabled)
        #expect(map(.requiresApproval, installed: false) == .pendingApproval)
    }

    @Test func eachStateHasOneTapAction() {
        #expect(LoginItemRow.off.tap == .install)
        #expect(LoginItemRow.enabled.tap == .uninstall)
        #expect(LoginItemRow.pendingApproval.tap == .openLoginItemsSettings)
        #expect(LoginItemRow.unavailable.tap == .none)
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var _installs = 0
    private var _uninstalls = 0
    private var _opens = 0
    private var _service: LoginItemStatus
    private var _fallback: LoginItemStatus = .notRegistered
    var installResult: Result<LoginItemInstaller.Result, Error> = .success(.service)
    var installedStatus: LoginItemStatus = .enabled

    init(service: LoginItemStatus = .notRegistered) { _service = service }

    struct Boom: Error, CustomStringConvertible { var description: String { "launchctl exploded" } }

    var installs: Int { lock.withLock { _installs } }
    var uninstalls: Int { lock.withLock { _uninstalls } }
    var opens: Int { lock.withLock { _opens } }
    var statuses: (service: LoginItemStatus, fallback: LoginItemStatus) { lock.withLock { (_service, _fallback) } }

    func install() throws -> LoginItemInstaller.Result {
        lock.withLock { _installs += 1 }
        let result = try installResult.get()
        lock.withLock { _service = installedStatus }
        return result
    }

    func uninstall() -> LoginItemInstaller.UninstallReport {
        lock.withLock { _uninstalls += 1; _service = .notRegistered }
        return LoginItemInstaller.UninstallReport(removedService: true)
    }

    func open() { lock.withLock { _opens += 1 } }
}

@MainActor
@Suite("LoginItemController")
struct LoginItemControllerTests {
    private final class Recording { var value = false }

    private func make(
        _ calls: Calls, installed: Bool = true, recording: Recording = Recording()
    ) -> LoginItemController {
        LoginItemController(
            readStatus: { calls.statuses },
            isInstalledBundle: installed,
            isRecording: { recording.value },
            install: { try calls.install() },
            uninstall: { calls.uninstall() },
            openLoginItemsSettings: { calls.open() }
        )
    }

    @Test func itStartsFromWhatTheMechanismsReport() {
        #expect(make(Calls(service: .enabled)).row == .enabled)
        #expect(make(Calls(service: .notRegistered)).row == .off)
        #expect(make(Calls(service: .notRegistered), installed: false).row == .unavailable)
    }

    @Test func tappingOffInstallsOnceAndRereadsTheStatus() async {
        let calls = Calls()
        let controller = make(calls)

        await controller.tap()

        #expect(calls.installs == 1)
        #expect(calls.opens == 0)
        #expect(controller.row == .enabled)
        #expect(controller.message == nil)
    }

    @Test func aRegistrationThatNeedsApprovalShowsPendingApprovalAndOpensNothingYet() async {
        let calls = Calls()
        calls.installResult = .success(.pendingApproval)
        calls.installedStatus = .requiresApproval
        let controller = make(calls)

        await controller.tap()

        #expect(controller.row == .pendingApproval)
        #expect(calls.opens == 0)
    }

    @Test func tappingPendingApprovalOpensTheLoginItemsPaneAndInstallsNothing() async {
        let calls = Calls(service: .requiresApproval)
        let controller = make(calls)

        await controller.tap()

        #expect(calls.opens == 1)
        #expect(calls.installs == 0)
        #expect(calls.uninstalls == 0)
    }

    @Test func tappingEnabledUninstalls() async {
        let calls = Calls(service: .enabled)
        let controller = make(calls)

        await controller.tap()

        #expect(calls.uninstalls == 1)
        #expect(controller.row == .off)
    }

    @Test func tappingAnUnavailableRowDoesNothing() async {
        let calls = Calls()
        let controller = make(calls, installed: false)

        await controller.tap()

        #expect(calls.installs == 0 && calls.uninstalls == 0 && calls.opens == 0)
    }

    @Test func aFailedInstallShowsAMessageAndRereadsTheRow() async {
        let calls = Calls()
        calls.installResult = .failure(Calls.Boom())
        let controller = make(calls)

        await controller.tap()

        #expect(controller.message == Textos.Onboarding.inicioFallo)
        #expect(controller.row == .off)
    }

    @Test func aLaterSuccessClearsTheMessage() async {
        let calls = Calls()
        calls.installResult = .failure(Calls.Boom())
        let controller = make(calls)
        await controller.tap()
        #expect(controller.message != nil)

        calls.installResult = .success(.service)
        await controller.tap()

        #expect(controller.message == nil)
        #expect(controller.row == .enabled)
    }

    // MARK: - Guard while recording (a launchd bootout can take the app down)

    @Test func disablingIsBlockedWhileRecordingAndExplainsWhy() async {
        let calls = Calls(service: .enabled)
        let recording = Recording()
        recording.value = true
        let controller = make(calls, recording: recording)
        #expect(controller.recordingBlocked)

        await controller.tap()

        #expect(calls.uninstalls == 0)
        #expect(controller.row == .enabled)
        #expect(controller.message == Textos.Onboarding.inicioGrabando)
    }

    @Test func enablingIsBlockedWhileRecordingToo() async {
        let calls = Calls()
        let recording = Recording()
        recording.value = true
        let controller = make(calls, recording: recording)

        await controller.tap()

        #expect(calls.installs == 0)
        #expect(controller.row == .off)
        #expect(controller.message == Textos.Onboarding.inicioGrabando)
    }

    @Test func openingTheLoginItemsPaneIsNeverBlockedByARecording() async {
        let calls = Calls(service: .requiresApproval)
        let recording = Recording()
        recording.value = true
        let controller = make(calls, recording: recording)
        #expect(!controller.recordingBlocked)

        await controller.tap()

        #expect(calls.opens == 1)
    }

    @Test func onceTheRecordingEndsTheChangeGoesThroughAndTheMessageClears() async {
        let calls = Calls(service: .enabled)
        let recording = Recording()
        recording.value = true
        let controller = make(calls, recording: recording)
        await controller.tap()
        #expect(controller.message != nil)

        recording.value = false
        #expect(!controller.recordingBlocked)
        await controller.tap()

        #expect(calls.uninstalls == 1)
        #expect(controller.message == nil)
    }

    @Test func anUnavailableRowIsNotReportedAsBlockedByARecording() {
        let recording = Recording()
        recording.value = true
        #expect(!make(Calls(), installed: false, recording: recording).recordingBlocked)
    }

    @Test func refreshPicksUpAnApprovalGrantedInSystemSettings() async {
        let calls = Calls(service: .requiresApproval)
        let controller = make(calls)
        #expect(controller.row == .pendingApproval)

        _ = try? calls.install()  // the user approved it: the service now reports enabled
        controller.refresh()

        #expect(controller.row == .enabled)
    }
}

@Suite("AutoMinutes")
struct AutoMinutesTests {
    @Test func needsAMigratedKeyAndAModel() {
        #expect(AutoMinutes.allowed(presence: .primary, model: "openai/gpt-4o-mini"))
        #expect(!AutoMinutes.allowed(presence: .none, model: "openai/gpt-4o-mini"))
        #expect(!AutoMinutes.allowed(presence: .primary, model: nil))
        #expect(!AutoMinutes.allowed(presence: .primary, model: ""))
        #expect(!AutoMinutes.allowed(presence: .primary, model: "   "))
        #expect(!AutoMinutes.allowed(presence: .none, model: nil))
    }

    @Test func aLegacyOnlyKeyIsNotEnoughSoTheFirstAutomaticJobNeverRaisesTheKeychainPrompt() {
        #expect(!AutoMinutes.allowed(presence: .legacyOnly, model: "openai/gpt-4o-mini"))
        #expect(!AutoMinutes.toggleEnabled(presence: .legacyOnly, model: "openai/gpt-4o-mini", isOn: false))
    }

    @Test func theToggleAlwaysLetsTheUserTurnItOff() {
        #expect(!AutoMinutes.toggleEnabled(presence: .none, model: nil, isOn: false))
        #expect(AutoMinutes.toggleEnabled(presence: .none, model: nil, isOn: true))
        #expect(AutoMinutes.toggleEnabled(presence: .legacyOnly, model: nil, isOn: true))
        #expect(AutoMinutes.toggleEnabled(presence: .primary, model: "a/b", isOn: false))
        #expect(!AutoMinutes.toggleEnabled(presence: .primary, model: nil, isOn: false))
    }

    @Test func theRequirementPointsAtMigratingForALegacyKeyAndAtKeyAndModelOtherwise() {
        #expect(AutoMinutes.requirement(presence: .primary, model: "a/b") == nil)
        #expect(AutoMinutes.requirement(presence: .legacyOnly, model: "a/b") == .migrateKey)
        #expect(AutoMinutes.requirement(presence: .legacyOnly, model: nil) == .migrateKey)
        #expect(AutoMinutes.requirement(presence: .none, model: "a/b") == .keyAndModel)
        #expect(AutoMinutes.requirement(presence: .primary, model: "") == .keyAndModel)
    }

    @Test func theRequirementCopyNamesMigrarClaveOnlyForTheLegacyCase() {
        #expect(Textos.Onboarding.minutasAutoRequisitoMigrar.contains("Migrar clave"))
        #expect(!Textos.Onboarding.minutasAutoRequisito.contains("Migrar clave"))
    }
}

@Suite("RecordingsFolderNote")
struct RecordingsFolderNoteTests {
    private let running = URL(fileURLWithPath: NSHomeDirectory() + "/Recordings", isDirectory: true)

    @Test func theSameFolderNeedsNoRestart() {
        #expect(!RecordingsFolderNote.needsRestart(runningRoot: running, configured: "~/Recordings"))
        #expect(!RecordingsFolderNote.needsRestart(runningRoot: running, configured: "~/Recordings/"))
        #expect(!RecordingsFolderNote.needsRestart(runningRoot: running, configured: NSHomeDirectory() + "/Recordings"))
    }

    @Test func aDifferentFolderNeedsARestartBecauseTheRunningRootIsFixedAtLaunch() {
        #expect(RecordingsFolderNote.needsRestart(runningRoot: running, configured: "~/Reuniones"))
        #expect(RecordingsFolderNote.needsRestart(runningRoot: running, configured: "/Volumes/Datos/Reuniones"))
    }

    @Test func aBlankConfiguredValueNeverClaimsARestart() {
        #expect(!RecordingsFolderNote.needsRestart(runningRoot: running, configured: ""))
    }
}
