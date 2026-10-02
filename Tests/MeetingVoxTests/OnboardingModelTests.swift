import AppKit
import Foundation
import Testing

@testable import MeetingVox

// MARK: - Fakes (nothing here touches TCC, the network, Keychain or a window)

private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Scripted probes. `request` can be parked on a gate, and it may change what
/// the next `snapshot` reports (the user answering the prompt).
private final class FakeProbes: PermissionProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: PermissionSnapshot
    private var _snapshotCalls: [URL?] = []
    private var _probeFlags: [Bool] = []
    private var _requests: [PermissionKind] = []
    private var _requestURLs: [URL?] = []
    private var gate: Gate?
    private var answers: [PermissionKind: (inout PermissionSnapshot) -> Void] = [:]

    init(_ snapshot: PermissionSnapshot = FakeProbes.undecided) {
        _snapshot = snapshot
    }

    static let undecided = PermissionSnapshot(
        microphone: .notDetermined, notifications: .notDetermined, systemAudio: nil, localNetwork: nil
    )

    var snapshotCalls: [URL?] { lock.withLock { _snapshotCalls } }
    /// Per snapshot: whether the caller allowed a Local Network re-probe.
    var probeFlags: [Bool] { lock.withLock { _probeFlags } }
    var requests: [PermissionKind] { lock.withLock { _requests } }
    var requestURLs: [URL?] { lock.withLock { _requestURLs } }

    func set(_ change: (inout PermissionSnapshot) -> Void) { lock.withLock { change(&_snapshot) } }
    func park(requestsOn gate: Gate) { lock.withLock { self.gate = gate } }
    func answer(_ kind: PermissionKind, _ change: @escaping (inout PermissionSnapshot) -> Void) {
        lock.withLock { answers[kind] = change }
    }

    func snapshot(hindsight: URL?, refreshLocalNetwork: Bool) async -> PermissionSnapshot {
        lock.withLock {
            _snapshotCalls.append(hindsight)
            _probeFlags.append(refreshLocalNetwork)
            return _snapshot
        }
    }

    func request(_ kind: PermissionKind, hindsight: URL?) async {
        let gate = lock.withLock {
            _requests.append(kind)
            _requestURLs.append(hindsight)
            return self.gate
        }
        await gate?.wait()
        lock.withLock {
            if let change = answers[kind] { change(&_snapshot) }
        }
    }
}

/// A downloader that only records calls; `download` can park on a gate and
/// then either fails or leaves the files "on disk".
private final class FakeDownloader: ModelDownloader, @unchecked Sendable {
    let directory = URL(fileURLWithPath: "/nonexistent/onboarding-model")
    private let lock = NSLock()
    private var present: Bool
    private var calls = 0
    private var failures: [Error]
    private let gate: Gate?

    init(present: Bool = false, failures: [Error] = [], gate: Gate? = nil) {
        self.present = present
        self.failures = failures
        self.gate = gate
    }

    var callCount: Int { lock.withLock { calls } }
    func isPresent() -> Bool { lock.withLock { present } }

    func download(progress: @escaping @Sendable (Double, ModelProgress.Phase) -> Void) async throws {
        lock.withLock { calls += 1 }
        progress(0.4, .descargando)
        await gate?.wait()
        let failure: Error? = lock.withLock { failures.isEmpty ? nil : failures.removeFirst() }
        if let failure { throw failure }
        lock.withLock { present = true }
    }
}

@MainActor
private final class FakeMinutes: OnboardingMinutesFacts {
    var isDone = false
    var reloads = 0
    var commits = 0
    func reload() { reloads += 1 }
    func commit() { commits += 1 }
}

/// Everything the model reports outward.
@MainActor
private final class Outcomes {
    var markerWrites = 0
    var markerFails = false
    var closes = 0
    var logs: [String] = []
    var openedPanes: [SettingsPane] = []
    var recording = false
    var raw: [String: Any] = [:]
}

private struct MarkerError: Error {}

@MainActor
private func makeModel(
    probes: FakeProbes = FakeProbes(),
    downloader: FakeDownloader = FakeDownloader(),
    outcomes: Outcomes = Outcomes(),
    minutes: any OnboardingMinutesFacts = FakeMinutes(),
    provisioner: ModelProvisioner? = nil
) -> OnboardingModel {
    OnboardingModel(
        probes: probes,
        provisioner: provisioner ?? ModelProvisioner(downloader: downloader),
        config: { ConfigValues(raw: outcomes.raw) },
        isRecording: { outcomes.recording },
        minutes: minutes,
        openPane: { outcomes.openedPanes.append($0) },
        writeMarker: {
            if outcomes.markerFails { throw MarkerError() }
            outcomes.markerWrites += 1
        },
        close: { outcomes.closes += 1 },
        log: { outcomes.logs.append($0) }
    )
}

/// Polls on the main actor until `condition` holds (bounded).
@MainActor
private func poll(_ condition: () -> Bool) async {
    for _ in 0..<1000 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private func hindsightOn() -> [String: Any] {
    ["hindsight": ["enabled": true, "base_url": "http://192.168.1.10:8888"]]
}

// MARK: - Rows (pure mapping)

@Suite("OnboardingModel.rows")
struct OnboardingRowsTests {
    @Test func everyKindGetsARowFromTheSnapshot() {
        let snapshot = PermissionSnapshot(
            microphone: .authorized, notifications: .denied, systemAudio: .granted, localNetwork: nil
        )
        let rows = OnboardingModel.rows(
            from: snapshot, requested: [], hindsightEnabled: false, isRecording: false
        )
        #expect(rows[.microphone] == PermissionRow(status: .granted, action: .none))
        #expect(rows[.notifications] == PermissionRow(status: .denied, action: .openSettings(.notifications)))
        #expect(rows[.systemAudio] == PermissionRow(status: .granted, action: .none))
        #expect(rows[.localNetwork] == PermissionRow(status: .notApplicable, action: .none, note: .whenMemoryEnabled))
    }

    @Test func aClickedKindReadsAsRequestedWhileTheSystemStaysUndecided() {
        let rows = OnboardingModel.rows(
            from: FakeProbes.undecided, requested: [.microphone], hindsightEnabled: true, isRecording: true
        )
        #expect(rows[.microphone] == PermissionRow(status: .requested, action: .openSettings(.microphone)))
        #expect(rows[.notifications] == PermissionRow(status: .notDetermined, action: .allow))
        #expect(rows[.systemAudio] == PermissionRow(
            status: .notDetermined, action: .waitForRecordingEnd, note: .recordingInProgress
        ))
        #expect(rows[.localNetwork] == PermissionRow(status: .notDetermined, action: .allow))
    }
}

// MARK: - Model state (pure mapping)

@Suite("ModelStepState.map")
struct ModelStepStateTests {
    @Test func disabledTranscriptionIsNotApplicableWhateverTheProvisionerSays() {
        for state: ModelProvisioner.State in [.absent, .present, .checking, .failed(.offline)] {
            #expect(ModelStepState.map(transcriptionEnabled: false, provisioner: state) == .notApplicable)
        }
    }

    @Test func enabledTranscriptionFollowsTheProvisioner() {
        let progress = ModelProgress(fraction: 0.5, phase: .preparando)
        #expect(ModelStepState.map(transcriptionEnabled: true, provisioner: .checking) == .checking)
        #expect(ModelStepState.map(transcriptionEnabled: true, provisioner: .absent) == .absent)
        #expect(ModelStepState.map(transcriptionEnabled: true, provisioner: .present) == .present)
        #expect(ModelStepState.map(transcriptionEnabled: true, provisioner: .downloading(progress)) == .downloading(progress))
        #expect(ModelStepState.map(transcriptionEnabled: true, provisioner: .failed(.offline)) == .failed(.offline))
        #expect(ModelStepState.map(transcriptionEnabled: true, provisioner: .failed(.other("x"))) == .failed(.other("x")))
    }
}

// MARK: - Permissions

@MainActor
@Suite("OnboardingModel.permissions")
struct OnboardingModelPermissionTests {
    @Test func refreshingReadsTheSnapshotIntoRowsWithoutRequestingAnything() async {
        let probes = FakeProbes(PermissionSnapshot(
            microphone: .authorized, notifications: .notDetermined, systemAudio: .denied, localNetwork: nil
        ))
        let model = makeModel(probes: probes)
        await model.refreshStatuses()
        #expect(model.rows[.microphone]?.status == .granted)
        #expect(model.rows[.notifications]?.status == .notDetermined)
        #expect(model.rows[.systemAudio]?.status == .denied)
        #expect(probes.snapshotCalls.count == 1)
        #expect(probes.requests.isEmpty)
    }

    @Test func windowBecomingKeyRereadsSoTheUserEnablingItInSettingsShowsUp() async {
        let probes = FakeProbes()
        let model = makeModel(probes: probes)
        await model.refreshStatuses()
        #expect(model.rows[.microphone]?.status == .notDetermined)

        probes.set { $0.microphone = .authorized }  // toggled in System Settings
        await model.windowDidBecomeKey()

        #expect(model.rows[.microphone]?.status == .granted)
        #expect(probes.snapshotCalls.count == 2)
        #expect(probes.requests.isEmpty)
    }

    @Test func allowRaisesExactlyThatRequestThenRereads() async {
        let probes = FakeProbes()
        probes.answer(.microphone) { $0.microphone = .authorized }
        let model = makeModel(probes: probes)
        await model.refreshStatuses()

        await model.perform(.microphone)

        #expect(probes.requests == [.microphone])
        #expect(model.rows[.microphone]?.status == .granted)
        #expect(model.rows[.notifications]?.status == .notDetermined)  // untouched
        #expect(model.inFlight == nil)
    }

    @Test func aStillUndecidedAnswerAfterTheClickReadsAsRequested() async {
        let probes = FakeProbes()  // the request leaves the mic undetermined
        let model = makeModel(probes: probes)
        await model.refreshStatuses()
        await model.perform(.microphone)
        #expect(model.rows[.microphone]?.status == .requested)
        #expect(model.rows[.notifications]?.status == .notDetermined)
    }

    @Test func onlyOneRequestIsInFlightAndTheNextClickIsIgnoredUntilItReturns() async {
        let gate = Gate()
        let probes = FakeProbes()
        probes.park(requestsOn: gate)
        let model = makeModel(probes: probes)
        await model.refreshStatuses()

        let first = Task { @MainActor in await model.perform(.microphone) }
        await poll { probes.requests.count == 1 }
        #expect(model.inFlight == .microphone)

        // A second dialog must not stack. Run it as a Task so a regression
        // fails the assertion below instead of hanging on the parked gate.
        let second = Task { @MainActor in await model.perform(.notifications) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(probes.requests == [.microphone])

        await gate.release()
        await first.value
        await second.value
        #expect(model.inFlight == nil)

        await model.perform(.notifications)  // now it may go
        #expect(probes.requests == [.microphone, .notifications])
    }

    @Test func aRowWithoutAnAllowActionNeverRequests() async {
        let probes = FakeProbes(PermissionSnapshot(
            microphone: .authorized, notifications: .authorized, systemAudio: .granted, localNetwork: nil
        ))
        let model = makeModel(probes: probes)
        await model.refreshStatuses()
        for kind in PermissionKind.allCases { await model.perform(kind) }
        #expect(probes.requests.isEmpty)
    }

    @Test func aDeniedRowOpensItsSettingsPaneAndRequestsNothing() async {
        let outcomes = Outcomes()
        let probes = FakeProbes(PermissionSnapshot(
            microphone: .denied, notifications: .denied, systemAudio: .denied, localNetwork: nil
        ))
        let model = makeModel(probes: probes, outcomes: outcomes)
        await model.refreshStatuses()
        await model.perform(.microphone)
        await model.perform(.systemAudio)
        #expect(outcomes.openedPanes == [.microphone, .systemAudio])
        #expect(probes.requests.isEmpty)
    }

    @Test func systemAudioIsRefusedWhileRecording() async {
        let outcomes = Outcomes()
        outcomes.recording = true
        let probes = FakeProbes()
        let model = makeModel(probes: probes, outcomes: outcomes)
        await model.refreshStatuses()
        #expect(model.rows[.systemAudio]?.action == .waitForRecordingEnd)

        await model.perform(.systemAudio)

        #expect(probes.requests.isEmpty)
        #expect(model.inFlight == nil)
    }

    @Test func aRecordingThatStartsAfterTheRefreshStillBlocksTheClick() async {
        let outcomes = Outcomes()
        let probes = FakeProbes()
        let model = makeModel(probes: probes, outcomes: outcomes)
        await model.refreshStatuses()
        #expect(model.rows[.systemAudio]?.action == .allow)  // stale by the time of the click

        outcomes.recording = true
        await model.perform(.systemAudio)

        #expect(probes.requests.isEmpty)
        #expect(model.rows[.systemAudio]?.action == .waitForRecordingEnd)  // re-read on the refusal
    }

    @Test func systemAudioIsRequestedWhenNotRecording() async {
        let probes = FakeProbes()
        let model = makeModel(probes: probes)
        await model.refreshStatuses()
        await model.perform(.systemAudio)
        #expect(probes.requests == [.systemAudio])
    }

    @Test func localNetworkIsNeverProbedBeforeAClick() async {
        let outcomes = Outcomes()
        outcomes.raw = hindsightOn()
        let probes = FakeProbes()
        let model = makeModel(probes: probes, outcomes: outcomes)

        await model.refreshStatuses()
        await model.windowDidBecomeKey()
        await model.refreshStatuses()

        #expect(probes.requests.isEmpty)
        #expect(model.rows[.localNetwork] == PermissionRow(status: .notDetermined, action: .allow))
        // The base URL travels with every read (the live probe re-probes only
        // once the user clicked), but no request was raised.
        #expect(probes.snapshotCalls.allSatisfy { $0 == URL(string: "http://192.168.1.10:8888") })
    }

    @Test func localNetworkClickRequestsWithTheConfiguredBaseURL() async {
        let outcomes = Outcomes()
        outcomes.raw = hindsightOn()
        let probes = FakeProbes()
        probes.answer(.localNetwork) { $0.localNetwork = .reachable }
        let model = makeModel(probes: probes, outcomes: outcomes)
        await model.refreshStatuses()

        await model.perform(.localNetwork)

        #expect(probes.requests == [.localNetwork])
        #expect(probes.requestURLs == [URL(string: "http://192.168.1.10:8888")])
        #expect(model.rows[.localNetwork]?.status == .granted)
    }

    @Test func localNetworkIsNotApplicableAndNeverRequestedWithMemoryOff() async {
        let probes = FakeProbes()
        let model = makeModel(probes: probes)
        await model.refreshStatuses()
        #expect(model.rows[.localNetwork]?.status == .notApplicable)
        #expect(probes.snapshotCalls == [nil])  // no URL: nothing to probe
        await model.perform(.localNetwork)
        #expect(probes.requests.isEmpty)
    }

    @Test func aLocalNetworkChangeFromAnotherQueueRereadsOnTheMainActor() async {
        let probes = FakeProbes()
        let model = makeModel(probes: probes)
        await model.refreshStatuses()
        #expect(probes.snapshotCalls.count == 1)

        probes.set { $0.localNetwork = .prohibited }
        // The tracker calls this from a background queue.
        await Task.detached { model.localNetworkChanged() }.value
        await poll { probes.snapshotCalls.count == 2 }

        #expect(probes.snapshotCalls.count == 2)
    }

    @Test func aLocalNetworkChangeRereadsWithoutStartingAnotherProbe() async {
        let probes = FakeProbes()
        let outcomes = Outcomes()
        outcomes.raw = hindsightOn()
        let model = makeModel(probes: probes, outcomes: outcomes)
        await model.windowDidBecomeKey()  // the window-key read may probe
        #expect(probes.probeFlags == [true])

        model.localNetworkChanged()
        await poll { probes.snapshotCalls.count == 2 }

        #expect(probes.probeFlags == [true, false], "the tracker's own report must not re-probe")
    }

    @Test func theRefreshAfterAClickReadsTheCacheWithoutProbingAgain() async {
        let probes = FakeProbes()
        let outcomes = Outcomes()
        outcomes.raw = hindsightOn()
        let model = makeModel(probes: probes, outcomes: outcomes)
        await model.windowDidBecomeKey()

        await model.perform(.microphone)  // any click: request, then read

        #expect(probes.probeFlags == [true, false])
    }

    @Test func aRefreshCanStillBeAskedToProbe() async {
        let probes = FakeProbes()
        let model = makeModel(probes: probes)
        await model.refreshStatuses()
        await model.refreshStatuses(probingLocalNetwork: false)
        #expect(probes.probeFlags == [true, false])
    }

    @Test func aLocalNetworkReportAfterTheWindowClosedReadsNothing() async {
        let probes = FakeProbes()
        let model = makeModel(probes: probes)
        await model.windowDidBecomeKey()
        model.windowClosed()
        let before = probes.snapshotCalls.count

        model.localNetworkChanged()
        try? await Task.sleep(for: .milliseconds(80))

        #expect(probes.snapshotCalls.count == before)
    }

    @Test func aReopenedWindowReadsAgain() async {
        let probes = FakeProbes()
        let model = makeModel(probes: probes)
        await model.windowDidBecomeKey()
        model.windowClosed()

        await model.windowDidBecomeKey()  // reopened from the menu
        model.localNetworkChanged()
        await poll { probes.snapshotCalls.count == 3 }

        #expect(probes.snapshotCalls.count == 3)
    }
}

// MARK: - Model step

@MainActor
@Suite("OnboardingModel.model")
struct OnboardingModelModelStepTests {
    @Test func lookingNeverDownloads() async {
        let downloader = FakeDownloader()
        let model = makeModel(downloader: downloader)
        model.startObservingModel()
        await poll { model.modelState == .absent }
        await model.refreshStatuses()
        await model.windowDidBecomeKey()
        #expect(model.modelState == .absent)
        #expect(downloader.callCount == 0)
        model.windowClosed()
    }

    @Test func aPresentModelReadsAsPresentWithoutDownloading() async {
        let downloader = FakeDownloader(present: true)
        let model = makeModel(downloader: downloader)
        model.startObservingModel()
        await poll { model.modelState == .present }
        #expect(model.modelState == .present)
        #expect(downloader.callCount == 0)
        model.windowClosed()
    }

    @Test func theDownloadButtonDownloadsOnceAndShowsProgress() async {
        let gate = Gate()
        let downloader = FakeDownloader(gate: gate)
        let model = makeModel(downloader: downloader)
        model.startObservingModel()
        await poll { model.modelState == .absent }

        let download = Task { @MainActor in await model.startModelDownload() }
        await poll { model.modelState == .downloading(ModelProgress(fraction: 0.4, phase: .descargando)) }
        #expect(model.modelState == .downloading(ModelProgress(fraction: 0.4, phase: .descargando)))

        await gate.release()
        await download.value
        await poll { model.modelState == .present }
        #expect(model.modelState == .present)
        #expect(downloader.callCount == 1)
        model.windowClosed()
    }

    @Test func anOfflineFailureOffersARetryThatDownloadsAgain() async {
        let downloader = FakeDownloader(failures: [URLError(.notConnectedToInternet)])
        let model = makeModel(downloader: downloader)
        model.startObservingModel()
        await poll { model.modelState == .absent }

        await model.startModelDownload()
        await poll { model.modelState == .failed(.offline) }
        #expect(model.modelState == .failed(.offline))
        #expect(downloader.callCount == 1)

        await model.startModelDownload()  // "Reintentar"
        await poll { model.modelState == .present }
        #expect(model.modelState == .present)
        #expect(downloader.callCount == 2)
        model.windowClosed()
    }

    @Test func transcriptionDisabledIsNotApplicableAndNeverDownloads() async {
        let outcomes = Outcomes()
        outcomes.raw = ["transcription": ["enabled": false]]
        let downloader = FakeDownloader()
        let model = makeModel(downloader: downloader, outcomes: outcomes)
        model.startObservingModel()
        await model.refreshStatuses()
        #expect(model.modelState == .notApplicable)

        await model.startModelDownload()

        #expect(downloader.callCount == 0)
        #expect(model.modelState == .notApplicable)
        model.windowClosed()
    }

    @Test func enablingTranscriptionInSettingsWhileOpenBringsTheStepBack() async {
        let outcomes = Outcomes()
        outcomes.raw = ["transcription": ["enabled": false]]
        let model = makeModel(outcomes: outcomes)
        model.startObservingModel()
        await model.refreshStatuses()
        #expect(model.modelState == .notApplicable)

        outcomes.raw = [:]  // transcription.enabled defaults to true
        await model.windowDidBecomeKey()
        await poll { model.modelState == .absent }
        #expect(model.modelState == .absent)
        model.windowClosed()
    }
}

// MARK: - Navigation, ticks, finish

@MainActor
@Suite("OnboardingModel.flow")
struct OnboardingModelFlowTests {
    @Test func continuingIsNeverBlockedByAnUnfinishedStep() async {
        let probes = FakeProbes(PermissionSnapshot(
            microphone: .denied, notifications: .denied, systemAudio: .denied, localNetwork: nil
        ))
        let model = makeModel(probes: probes)
        await model.refreshStatuses()
        #expect(model.stepIsDone(.permisos) == false)

        model.next()
        #expect(model.current == .modelo)
        model.next()
        #expect(model.current == .minutas)
        model.next()
        #expect(model.current == .listo)
        model.next()
        #expect(model.current == .listo)
        model.back()
        #expect(model.current == .minutas)
        model.jump(to: .permisos)
        #expect(model.current == .permisos)
        #expect(model.canGoBack == false)
    }

    @Test func permissionsAreDoneWhenEveryRowIsGrantedOrNotApplicable() async {
        let probes = FakeProbes(PermissionSnapshot(
            microphone: .authorized, notifications: .authorized, systemAudio: .granted, localNetwork: nil
        ))
        let model = makeModel(probes: probes)
        #expect(model.stepIsDone(.permisos) == false)  // nothing read yet
        await model.refreshStatuses()
        #expect(model.stepIsDone(.permisos))  // Red local n/a with memory off

        probes.set { $0.systemAudio = nil }  // unreadable, not clicked: Permitir pending
        await model.refreshStatuses()
        #expect(model.stepIsDone(.permisos) == false)
    }

    @Test func aRequestedRowIsNotDone() async {
        let model = makeModel()
        await model.refreshStatuses()
        await model.perform(.microphone)  // stays undetermined -> "Solicitado"
        #expect(model.stepIsDone(.permisos) == false)
    }

    @Test func theModelStepIsDoneWhenPresentOrNotApplicable() async {
        let outcomes = Outcomes()
        let model = makeModel(downloader: FakeDownloader(present: true), outcomes: outcomes)
        #expect(model.stepIsDone(.modelo) == false)  // still checking
        model.startObservingModel()
        await poll { model.modelState == .present }
        #expect(model.stepIsDone(.modelo))
        model.windowClosed()

        outcomes.raw = ["transcription": ["enabled": false]]
        let disabled = makeModel(outcomes: outcomes)
        #expect(disabled.stepIsDone(.modelo))
    }

    @Test func theMinutesStepFollowsItsFactsAndListoIsNeverDone() {
        let minutes = FakeMinutes()
        let model = makeModel(minutes: minutes)
        #expect(model.stepIsDone(.minutas) == false)
        minutes.isDone = true
        #expect(model.stepIsDone(.minutas))
        #expect(model.stepIsDone(.listo) == false)
    }

    @Test func finishWritesTheMarkerOnceAndTellsTheWindow() {
        let outcomes = Outcomes()
        let model = makeModel(outcomes: outcomes)
        model.finish()
        model.finish()  // a double click
        #expect(outcomes.markerWrites == 1)
        #expect(outcomes.closes == 1)
    }

    @Test func aMarkerWriteFailureStillClosesTheWindow() {
        let outcomes = Outcomes()
        outcomes.markerFails = true
        let model = makeModel(outcomes: outcomes)
        model.finish()
        #expect(outcomes.markerWrites == 0)
        #expect(outcomes.closes == 1)  // it re-shows at the next launch; never trap the user
    }

    @Test func closingWithoutEmpezarWritesNoMarker() async {
        let outcomes = Outcomes()
        let model = makeModel(outcomes: outcomes)
        model.startObservingModel()
        await model.refreshStatuses()
        model.next()
        model.windowClosed()
        #expect(outcomes.markerWrites == 0)
        #expect(outcomes.closes == 0)
    }

    @Test func theLastStepOffersEmpezarAndTheOthersContinuar() {
        let model = makeModel()
        #expect(model.primary == .continue)
        model.jump(to: .listo)
        #expect(model.primary == .start)
    }
}

// MARK: - Window controller (lifecycle only: no NSWindow is ever created)

@MainActor
@Suite("OnboardingWindowController.lifecycle")
struct OnboardingWindowControllerLifecycleTests {
    private final class Applied {
        var policies: [ActivationPolicyCoordinator.Policy] = []
        var closes = 0
    }

    private func make(
        probes: FakeProbes = FakeProbes()
    ) -> (OnboardingWindowController, ActivationPolicyCoordinator, Applied, OnboardingModel) {
        let applied = Applied()
        let coordinator = ActivationPolicyCoordinator { applied.policies.append($0) }
        let model = makeModel(probes: probes)
        let controller = OnboardingWindowController(
            model: model, activation: coordinator, onClose: { applied.closes += 1 }
        )
        return (controller, coordinator, applied, model)
    }

    @Test func theLeaseIsHeldWhileOpenAndReleasedOnClose() {
        let (controller, coordinator, applied, _) = make()
        controller.holdActivation()
        controller.holdActivation()  // a second show() must not take a second lease
        #expect(applied.policies == [.regular])
        #expect(coordinator.holders == 1)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        #expect(applied.policies == [.regular, .accessory])
        #expect(coordinator.holders == 0)
        #expect(applied.closes == 1)
    }

    @Test func aWindowThatIsReopenedTakesANewLease() {
        let (controller, coordinator, applied, _) = make()
        controller.holdActivation()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.holdActivation()
        #expect(applied.policies == [.regular, .accessory, .regular])
        #expect(coordinator.holders == 1)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(coordinator.holders == 0)
    }

    @Test func aWindowThatDoesNotAppearReleasesTheDockIconLease() {
        let (controller, coordinator, applied, _) = make()
        controller.presentWindow = { false }

        let shown = controller.show()

        #expect(!shown)
        #expect(coordinator.holders == 0, "a window that never came up must not pin the Dock icon")
        #expect(applied.policies == [.regular, .accessory])
    }

    @Test func aWindowThatAppearsKeepsTheLeaseUntilItCloses() {
        let (controller, coordinator, applied, _) = make()
        controller.presentWindow = { true }

        #expect(controller.show())
        #expect(controller.show(), "showing it again must not take a second lease")
        #expect(coordinator.holders == 1)
        #expect(applied.policies == [.regular])

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(coordinator.holders == 0)
    }

    @Test func aFailedShowCanBeRetriedAndTakesAFreshLease() {
        let (controller, coordinator, applied, _) = make()
        controller.presentWindow = { false }
        _ = controller.show()
        controller.presentWindow = { true }

        #expect(controller.show())

        #expect(coordinator.holders == 1)
        #expect(applied.policies == [.regular, .accessory, .regular])
    }

    @Test func closingWithoutEverOpeningReleasesNothingAndDoesNotGoNegative() {
        let (controller, coordinator, applied, _) = make()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(applied.policies.isEmpty)
        #expect(coordinator.holders == 0)
    }

    @Test func empezarClosesTheWindowWhichReleasesTheLeaseAndStopsFollowingTheModel() async throws {
        let downloader = FakeDownloader()
        let provisioner = ModelProvisioner(downloader: downloader)
        let applied = Applied()
        let coordinator = ActivationPolicyCoordinator { applied.policies.append($0) }
        let outcomes = Outcomes()
        let model = makeModel(outcomes: outcomes, provisioner: provisioner)
        let controller = OnboardingWindowController(
            model: model, activation: coordinator, onClose: { applied.closes += 1 }
        )
        // No NSWindow in tests: `NSWindow.close()` would post willClose, so
        // simulate exactly that.
        controller.closeWindow = { _ in
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        controller.holdActivation()
        model.startObservingModel()
        await poll { model.modelState == .absent }

        model.finish()  // "Empezar"

        #expect(outcomes.markerWrites == 1)
        #expect(applied.policies == [.regular, .accessory])
        #expect(coordinator.holders == 0)
        #expect(applied.closes == 1)
        try await provisioner.ensureAvailable()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.provisionerState == .absent)
    }

    @Test func aModelBuiltWithItsOwnCloseKeepsItUntilAControllerTakesOver() {
        let outcomes = Outcomes()
        let model = makeModel(outcomes: outcomes)
        model.finish()
        #expect(outcomes.closes == 1)  // the seam the model was built with
    }

    @Test func becomingKeyRefreshesTheStatuses() async {
        let probes = FakeProbes()
        let (controller, _, _, model) = make(probes: probes)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        // The call is recorded before the rows are applied: wait for the rows.
        await poll { model.rows[.microphone] != nil }
        #expect(probes.snapshotCalls.count == 1)
        #expect(model.rows[.microphone]?.status == .notDetermined)
    }
}

// MARK: - Fixups: copy, steps, failure log, reopen, close seam

@Suite("OnboardingStep.copy")
struct OnboardingStepCopyTests {
    @Test func stepsAreNumberedFromOneInRailOrder() {
        #expect(OnboardingStep.allCases.map(\.number) == [1, 2, 3, 4])
    }

    @Test func theLegacyKeyConsentIsImpersonalNamesTheMacPasswordAndPermitirSiempre() {
        let copy = Textos.Onboarding.claveLegadoTitulo + " " + Textos.Onboarding.claveLegadoConsentimiento
        #expect(!copy.contains("Encontramos"))
        #expect(!copy.lowercased().contains("quill"))
        #expect(copy.contains("la versión anterior"))
        #expect(copy.contains("contraseña"))
        #expect(copy.contains("«Permitir siempre»"))
        #expect(copy.contains("vuelve a preguntar") || copy.contains("volverá a preguntar"))
    }

    @Test func everyStepHasItsOwnTitle() {
        #expect(OnboardingStep.allCases.map(\.title) == ["Permisos", "Modelo", "Minutas", "Listo"])
    }

    @Test func subtitlesUseNeutralChileanSpanishAndTheRightWords() {
        #expect(OnboardingStep.minutas.subtitle.contains("Minutas y resúmenes"))
        #expect(OnboardingStep.permisos.subtitle.contains("cuando haces clic"))
        for step in OnboardingStep.allCases {
            #expect(!step.subtitle.contains("Actas"), "\(step)")
            #expect(!step.subtitle.contains("pulsas"), "\(step)")
            #expect(!step.subtitle.isEmpty)
        }
    }
}

@Suite("ModelProvisioner.Failure.userMessage")
struct ModelFailureMessageTests {
    @Test func offlineIsSpanishAndPlain() {
        #expect(ModelProvisioner.Failure.offline.userMessage == "Sin conexión a internet")
    }

    @Test func anythingElseIsGenericAndNeverShowsTheRawSystemError() {
        let message = ModelProvisioner.Failure.other("The operation couldn't be completed. (NSURLErrorDomain -1)").userMessage
        #expect(message == "No se pudo descargar el modelo")
        #expect(!message.contains("NSURLErrorDomain"))
        #expect(ModelProvisioner.Failure.other("disk exploded").userMessage == message)
    }
}

@MainActor
@Suite("OnboardingModel.fixups")
struct OnboardingModelFixupTests {
    private struct Boom: Error, CustomStringConvertible { var description: String { "disk exploded" } }

    @Test func aFailedDownloadLogsTheRawErrorInsteadOfShowingIt() async {
        let outcomes = Outcomes()
        let model = makeModel(downloader: FakeDownloader(failures: [Boom()]), outcomes: outcomes)
        model.startObservingModel()
        await poll { model.modelState == .absent }

        await model.startModelDownload()

        #expect(outcomes.logs.count == 1)
        #expect(outcomes.logs.first?.contains("disk exploded") == true)
        await poll { model.modelState == .failed(.other("disk exploded")) }
        model.windowClosed()
    }

    @Test func aSuccessfulDownloadLogsNothing() async {
        let outcomes = Outcomes()
        let model = makeModel(outcomes: outcomes)
        await model.startModelDownload()
        #expect(outcomes.logs.isEmpty)
    }

    @Test func reopeningKeepsTheLastStepAndRequestedRowsUntilTheKeyRefreshLands() async {
        let probes = FakeProbes()  // the mic stays undetermined after the click
        let model = makeModel(probes: probes)
        await model.refreshStatuses()
        await model.perform(.microphone)
        model.jump(to: .modelo)
        #expect(model.rows[.microphone]?.status == .requested)

        model.windowClosed()  // closed with the red dot
        model.startObservingModel()  // reopened from the menu

        // Stale on purpose until the window becomes key: no read yet.
        #expect(model.current == .modelo)
        #expect(model.rows[.microphone]?.status == .requested)
        let readsBefore = probes.snapshotCalls.count

        probes.set { $0.microphone = .authorized }  // granted while closed
        await model.windowDidBecomeKey()

        #expect(probes.snapshotCalls.count == readsBefore + 1)
        #expect(model.rows[.microphone]?.status == .granted)
        #expect(model.current == .modelo)
        model.windowClosed()
    }

    @Test func closingStopsFollowingTheProvisioner() async throws {
        let downloader = FakeDownloader()
        let provisioner = ModelProvisioner(downloader: downloader)
        let model = makeModel(provisioner: provisioner)
        model.startObservingModel()
        await poll { model.modelState == .absent }

        model.windowClosed()
        try await provisioner.ensureAvailable()  // the model lands after the window went away
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.provisionerState == .absent)  // no longer following updates
        #expect(downloader.callCount == 1)
    }
}

// MARK: - Minutas step, Omitir, reload on key, deferred starts on close

@MainActor
@Suite("OnboardingModel.minutas")
struct OnboardingModelMinutasTests {
    private func tempConfig(_ text: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-onb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("config.json")
        try Data(text.utf8).write(to: url)
        return (root, url)
    }

    private final class MemoryKey: APIKeyStore, @unchecked Sendable {
        func hasAPIKey() -> Bool { true }
        func read() throws -> String? { "sk" }
        func save(_ secret: String) throws {}
        func delete() throws {}
    }

    @Test func omitirMovesOnToListoAndLeavesEveryMinutesAndSummarySettingAsItWas() throws {
        let text = """
        {"minutes":{"enabled":true,"template":"daily","language":"inglés"},\
        "openrouter":{"model":"a/b","deny_data_collection":false},"summary":{"enabled":false}}
        """
        let (root, url) = try tempConfig(text)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsModel(configURL: url, templatesDir: root, keychain: MemoryKey())
        let facts = SettingsMinutesFacts(settings: settings)
        let model = makeModel(minutes: facts)
        model.jump(to: .minutas)

        model.skipMinutes()

        #expect(model.current == .listo)
        #expect(try String(contentsOf: url, encoding: .utf8) == text)  // byte-for-byte
        #expect(settings.minutesEnabled)
        #expect(!settings.summaryEnabled)
    }

    @Test func omitirOnAConfigWithoutMinutesKeysWritesNothingAtAll() throws {
        let (root, url) = try tempConfig("{}")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsModel(configURL: url, templatesDir: root, keychain: MemoryKey())
        let model = makeModel(minutes: SettingsMinutesFacts(settings: settings))
        model.jump(to: .minutas)

        model.skipMinutes()

        #expect(try String(contentsOf: url, encoding: .utf8) == "{}")
        #expect(model.current == .listo)
    }

    @Test func becomingKeyReloadsTheMinutesFactsAsWellAsTheStatuses() async {
        let minutes = FakeMinutes()
        let model = makeModel(minutes: minutes)

        await model.windowDidBecomeKey()
        await model.windowDidBecomeKey()

        #expect(minutes.reloads == 2)
    }

    @Test func everyWayOfLeavingAStepCommitsWhatWasTyped() {
        let minutes = FakeMinutes()
        let model = makeModel(minutes: minutes)

        model.next()  // "Continuar"
        #expect(minutes.commits == 1)
        model.back()
        #expect(minutes.commits == 2)
        model.jump(to: .listo)  // the rail
        #expect(minutes.commits == 3)
        model.skipMinutes()
        #expect(minutes.commits == 4)
    }

    @Test func empezarCommitsBeforeItWritesTheMarker() {
        let minutes = FakeMinutes()
        let outcomes = Outcomes()
        let model = makeModel(outcomes: outcomes, minutes: minutes)

        model.finish()

        #expect(minutes.commits == 1)
        #expect(outcomes.markerWrites == 1)
    }

    @Test func closingTheWindowDoesNotReloadTheFacts() {
        let minutes = FakeMinutes()
        let model = makeModel(minutes: minutes)
        model.windowClosed()
        #expect(minutes.reloads == 0)
    }

    @Test func theMinutesCheckmarkFollowsTheFacts() {
        let minutes = FakeMinutes()
        let model = makeModel(minutes: minutes)
        #expect(!model.stepIsDone(.minutas))
        minutes.isDone = true
        #expect(model.stepIsDone(.minutas))
    }
}

@MainActor
@Suite("OnboardingWindowController.deferredStarts")
struct OnboardingDeferredStartsWiringTests {
    private final class Ran { var count = 0 }

    private func make(
        outcomes: Outcomes = Outcomes(), deferred: DeferredStarts
    ) -> (OnboardingWindowController, OnboardingModel, ActivationPolicyCoordinator) {
        let coordinator = ActivationPolicyCoordinator { _ in }
        let model = makeModel(outcomes: outcomes)
        let controller = OnboardingWindowController(
            model: model, activation: coordinator, onClose: { deferred.windowClosed() }
        )
        controller.closeWindow = { _ in
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        return (controller, model, coordinator)
    }

    @Test func empezarWritesTheMarkerAndReleasesTheHeldStartsOnce() {
        let deferred = DeferredStarts(deferring: true, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let ran = Ran()
        deferred.perform(.settlementPending) { ran.count += 1 }
        let outcomes = Outcomes()
        let (controller, model, _) = make(outcomes: outcomes, deferred: deferred)
        controller.holdActivation()
        #expect(ran.count == 0)

        model.finish()

        #expect(outcomes.markerWrites == 1)
        #expect(ran.count == 1)
        #expect(deferred.releasedBecause == .windowClosed)
        #expect(!deferred.isHolding)
    }

    @Test func closingWithTheRedDotReleasesWithoutWritingAMarker() {
        let deferred = DeferredStarts(deferring: true, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let ran = Ran()
        deferred.perform(.hindsightScheduler) { ran.count += 1 }
        let outcomes = Outcomes()
        let (controller, _, _) = make(outcomes: outcomes, deferred: deferred)
        controller.holdActivation()

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        #expect(outcomes.markerWrites == 0)
        #expect(ran.count == 1)
        #expect(deferred.releasedBecause == .windowClosed)
    }

    @Test func aSecondCloseAfterTheReleaseRunsNothingAgain() {
        let deferred = DeferredStarts(deferring: true, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let ran = Ran()
        deferred.perform(.settlementPending) { ran.count += 1 }
        let (controller, _, _) = make(deferred: deferred)
        controller.holdActivation()

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.holdActivation()  // reopened from the menu
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        #expect(ran.count == 1)
    }
}
