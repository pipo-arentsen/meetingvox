import AppKit
import Foundation
import Testing
@testable import MeetingVox

/// The main window's shell, without a window: the observers it keeps while
/// open (asserted on a synchronous spy center and the model's reload counter),
/// and the activation lease that makes the app `.regular` (Dock icon) only
/// while it is open, counted together with the onboarding window's.
@MainActor
@Suite final class MainWindowControllerTests {
    private final class Applied {
        var policies: [ActivationPolicyCoordinator.Policy] = []
    }

    private let root: URL
    private let applied = Applied()
    private let manual = ManualReloadScheduler()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-main-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent("2026.09.20-1000", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"started": "2026-09-20T10:00:00Z", "duration_seconds": 600, "files": {"mic": "mic.caf"}}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.meta))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private struct Rig {
        let controller: MainWindowController
        let model: MainWindowModel
        let spy: SpyNotificationCenter
        let activation: ActivationPolicyCoordinator
    }

    private func make(
        presenting: Bool = true, activation: ActivationPolicyCoordinator? = nil, library: LibraryModel? = nil
    ) -> Rig {
        let spy = SpyNotificationCenter()
        let meetings = MeetingsModel(root: root, config: { ConfigValues(raw: [:]) })
        let model = MainWindowModel(
            meetings: meetings, store: PipelineStatusStore(), calendar: .current, now: { Date() },
            reloadScheduler: manual.scheduler, library: library ?? (try? TestLibrary.make().library)!
        )
        let applied = self.applied
        let activation = activation ?? ActivationPolicyCoordinator { applied.policies.append($0) }
        let controller = MainWindowController(model: model, notifications: spy, activation: activation)
        controller.presentWindow = { presenting }
        return Rig(controller: controller, model: model, spy: spy, activation: activation)
    }

    @Test func aSidebarEntryChosenFromOutsideReachesTheModel() {
        let rig = make()
        #expect(rig.model.sidebar == .reuniones)

        rig.controller.select(.plantillas)

        #expect(rig.model.sidebar == .plantillas)
    }

    @Test func aTemplateSavedWhileOpenReloadsTheMeetingsTemplates() {
        let rig = make()
        rig.controller.show()
        let base = rig.model.reloadCount

        rig.spy.post(name: .meetingVoxTemplatesDidChange, object: nil)
        rig.spy.post(name: .meetingVoxTemplatesDidChange, object: nil)
        #expect(rig.model.reloadCount == base, "debounced: nothing yet")
        manual.fire()

        #expect(rig.model.reloadCount == base + 1, "one scan for the burst, which re-lists the templates")
        close(rig.controller)
    }

    @Test func showingRefreshesTheLibraryPageThatIsOpen() throws {
        let (library, libraryRoot) = try TestLibrary.make(config: ["glossary": ["Uno"]])
        let rig = make(library: library)
        rig.model.sidebar = .plantillas
        try Data("---\nnombre: Externa\n---\nx".utf8)
            .write(to: TemplateStore.fileURL(id: "externa", in: libraryRoot.appendingPathComponent("plantillas")))
        try JSONSerialization.data(withJSONObject: ["glossary": ["Uno", "Dos"]])
            .write(to: libraryRoot.appendingPathComponent("config.json"))
        #expect(library.templates.files.map(\.id) == [])

        rig.controller.show()
        #expect(library.templates.files.map(\.id) == ["externa"], "reopening on Plantillas re-lists the folder")
        #expect(library.glossary.glossary.map(\.term) == ["Uno"], "Glosario is not the page shown")

        rig.model.sidebar = .glosario
        try JSONSerialization.data(withJSONObject: ["glossary": ["Uno", "Tres"]])
            .write(to: libraryRoot.appendingPathComponent("config.json"))
        rig.controller.show()
        #expect(library.glossary.glossary.map(\.term) == ["Uno", "Tres"], "reopening on Glosario re-reads the config")
        close(rig.controller)
    }

    @Test func showingOnReunionesRefreshesNoEditor() throws {
        let (library, libraryRoot) = try TestLibrary.make()
        let rig = make(library: library)
        try Data("---\nnombre: Externa\n---\nx".utf8)
            .write(to: TemplateStore.fileURL(id: "externa", in: libraryRoot.appendingPathComponent("plantillas")))

        rig.controller.show()

        #expect(library.templates.files.isEmpty)
        close(rig.controller)
    }

    private func close(_ controller: MainWindowController) {
        controller.windowWillClose(Notification(name: NSNotification.Name("test")))
    }

    // MARK: - Observers

    @Test func showingReloadsOnceAndObservesIndexHindsightConfigAndTemplatesOnly() {
        let rig = make()

        rig.controller.show()

        #expect(rig.model.reloadCount == 1)
        #expect(Set(rig.spy.activeNames) == [
            .meetingVoxMeetingIndexDidChange, .meetingVoxHindsightStatusDidChange, .meetingVoxConfigDidChange,
            .meetingVoxTemplatesDidChange,
        ])
        #expect(rig.spy.activeCount == 4)
        #expect(rig.model.isActive)
        close(rig.controller)
    }

    @Test func eachNotificationWhileOpenSchedulesAReloadThatRunsAfterTheDelay() {
        let rig = make()
        rig.controller.show()

        for name in [
            Notification.Name.meetingVoxMeetingIndexDidChange, .meetingVoxHindsightStatusDidChange, .meetingVoxConfigDidChange,
            .meetingVoxTemplatesDidChange,
        ] {
            let base = rig.model.reloadCount
            rig.spy.post(name: name, object: nil)
            #expect(rig.model.reloadCount == base, "\(name.rawValue): waits for the delay")
            manual.fire()
            #expect(rig.model.reloadCount == base + 1, "\(name.rawValue)")
        }
        close(rig.controller)
    }

    @Test func aBurstOfNotificationsIsOneScan() {
        let rig = make()
        rig.controller.show()
        let base = rig.model.reloadCount

        rig.spy.post(name: .meetingVoxMeetingIndexDidChange, object: nil)
        rig.spy.post(name: .meetingVoxHindsightStatusDidChange, object: nil)
        rig.spy.post(name: .meetingVoxConfigDidChange, object: nil)
        rig.spy.post(name: .meetingVoxMeetingIndexDidChange, object: nil)
        manual.fire()

        #expect(rig.model.reloadCount == base + 1)
        close(rig.controller)
    }

    @Test func aChangeThisWindowAnnouncedItselfDoesNotRescan() {
        let rig = make()
        rig.controller.show()
        let base = rig.model.reloadCount

        rig.spy.post(name: .meetingVoxMeetingIndexDidChange, object: rig.model.meetings)
        manual.fire()
        #expect(rig.model.reloadCount == base, "its rows are already patched in place")

        rig.spy.post(name: .meetingVoxMeetingIndexDidChange, object: MeetingsModel(root: root, config: { ConfigValues(raw: [:]) }))
        manual.fire()
        #expect(rig.model.reloadCount == base + 1, "another window's change does")
        close(rig.controller)
    }

    @Test func closingWithAReloadPendingDropsIt() {
        let rig = make()
        rig.controller.show()
        let base = rig.model.reloadCount
        rig.spy.post(name: .meetingVoxMeetingIndexDidChange, object: nil)

        close(rig.controller)
        manual.fire()

        #expect(rig.model.reloadCount == base)
    }

    @Test func showingTwiceDoesNotDoubleRegisterButStillRefreshes() {
        let rig = make()
        rig.controller.show()
        rig.controller.show()

        #expect(rig.spy.addedCount == 4)
        #expect(rig.model.reloadCount == 2)
        close(rig.controller)
    }

    @Test func closingRemovesEveryObserverAndLaterPostsReloadNothing() {
        let rig = make()
        rig.controller.show()
        close(rig.controller)

        #expect(rig.spy.activeCount == 0)
        #expect(rig.spy.removedCount == 4)
        #expect(!rig.model.isActive)

        let base = rig.model.reloadCount
        rig.spy.post(name: .meetingVoxMeetingIndexDidChange, object: nil)
        rig.spy.post(name: .meetingVoxHindsightStatusDidChange, object: nil)
        rig.spy.post(name: .meetingVoxConfigDidChange, object: nil)
        #expect(rig.model.reloadCount == base)
    }

    @Test func reopeningAfterCloseObservesAgain() {
        let rig = make()
        rig.controller.show()
        close(rig.controller)
        rig.controller.show()

        #expect(rig.spy.activeCount == 4)
        #expect(rig.model.isActive)
        close(rig.controller)
    }

    @Test func closingBringsTheListBackToItsFirstPage() async {
        let rig = make()
        rig.controller.show()
        await rig.model.meetings.factsTask?.value
        rig.model.meetings.loadOlder()
        #expect(rig.model.meetings.extraMonths == 1)

        close(rig.controller)
        #expect(rig.model.meetings.extraMonths == 0)
    }

    // MARK: - Activation lease

    @Test func showingTakesTheLeaseAndTheAppBecomesRegular() {
        let rig = make()
        #expect(rig.activation.holders == 0)

        rig.controller.show()
        #expect(rig.activation.holders == 1)
        #expect(applied.policies == [.regular])

        close(rig.controller)
    }

    @Test func showingAnOpenWindowAgainKeepsASingleLease() {
        let rig = make()
        rig.controller.show()
        rig.controller.show()
        #expect(rig.activation.holders == 1)
        close(rig.controller)
        #expect(rig.activation.holders == 0, "one close releases the one lease")
        #expect(applied.policies == [.regular, .accessory])
    }

    @Test func closingReleasesTheLeaseAndTheAppGoesBackToAccessory() {
        let rig = make()
        rig.controller.show()
        close(rig.controller)

        #expect(rig.activation.holders == 0)
        #expect(applied.policies == [.regular, .accessory])
    }

    @Test func aWindowThatDidNotComeUpReleasesTheLeaseAndObservesNothing() {
        let rig = make(presenting: false)

        rig.controller.show()

        #expect(rig.activation.holders == 0)
        #expect(applied.policies == [.regular, .accessory], "the Dock icon must not stay pinned by a failed show")
        #expect(rig.spy.activeCount == 0)
        #expect(!rig.model.isActive)
    }

    @Test func aFailedShowDoesNotBreakTheNextOne() {
        let rig = make(presenting: false)
        rig.controller.show()
        rig.controller.presentWindow = { true }

        rig.controller.show()

        #expect(rig.activation.holders == 1)
        #expect(rig.spy.activeCount == 4)
        close(rig.controller)
    }

    @Test func mainWindowAndOnboardingHoldTheSameCoordinatorTogether() {
        let applied = self.applied
        let shared = ActivationPolicyCoordinator { applied.policies.append($0) }
        let onboardingLease = shared.acquire() // the onboarding window is open
        let rig = make(activation: shared)

        rig.controller.show()
        #expect(shared.holders == 2)
        #expect(applied.policies == [.regular], "already regular: no second switch")

        close(rig.controller) // main window closes first
        #expect(shared.holders == 1)
        #expect(applied.policies == [.regular], "onboarding still needs the Dock icon")

        onboardingLease.release() // onboarding closes
        #expect(shared.holders == 0)
        #expect(applied.policies == [.regular, .accessory])
    }

    @Test func aSecondCloseNotificationDoesNotReleaseSomeoneElsesLease() {
        let applied = self.applied
        let shared = ActivationPolicyCoordinator { applied.policies.append($0) }
        let onboardingLease = shared.acquire()
        let rig = make(activation: shared)
        rig.controller.show()

        close(rig.controller)
        close(rig.controller)

        #expect(shared.holders == 1)
        _ = onboardingLease
        onboardingLease.release()
    }

    // MARK: - Opening on a session

    @Test func showingFocusingASessionSelectsItOnTheRequestedTab() async {
        let rig = make()
        let dir = root.appendingPathComponent("2026.09.20-1000", isDirectory: true)

        rig.controller.show(focusing: dir, tab: .minuta)
        await rig.model.meetings.factsTask?.value

        #expect(rig.model.meetings.selection.map(\.lastPathComponent) == ["2026.09.20-1000"])
        #expect(rig.model.tab == .minuta)
        close(rig.controller)
    }

    @Test func showingWithoutASessionTouchesNeitherSelectionNorTab() async {
        let rig = make()
        rig.model.tab = .transcripcion

        rig.controller.show()
        await rig.model.meetings.factsTask?.value

        #expect(rig.model.meetings.selection.isEmpty)
        #expect(rig.model.tab == .transcripcion)
        close(rig.controller)
    }

    @Test func aWindowThatFailsToShowStillLeavesNoLeaseAfterAFocusingShow() {
        let rig = make(presenting: false)
        rig.controller.show(focusing: root.appendingPathComponent("2026.09.20-1000", isDirectory: true))
        #expect(rig.activation.holders == 0)
    }
}

