import Foundation
import Observation

// MARK: - Minutas step seam

/// What the "Minutas" and "Listo" steps tell the model: the checkmark and a
/// reload hook, so the model does not know about `SettingsModel`.
@MainActor
protocol OnboardingMinutesFacts: AnyObject {
    /// Informational checkmark only; it never blocks "Continuar".
    var isDone: Bool { get }
    /// The window became key: re-read what Ajustes (or a hand edit) may have
    /// changed while it was in the background (F5).
    func reload()
    /// The user is leaving the step (Continuar, Atrás, the rail, Empezar):
    /// save what is typed but not yet committed (the model ID).
    func commit()
}

/// For a model with no Minutas step behind it: never done.
@MainActor
final class PlaceholderMinutesFacts: OnboardingMinutesFacts {
    var isDone: Bool { false }
    func reload() {}
    func commit() {}
}

/// The real facts, over the onboarding window's own `SettingsModel`: done
/// when automatic minutes could run (a migrated key and a saved model).
/// Reads the model's observable properties, so the rail's checkmark updates live.
@MainActor
final class SettingsMinutesFacts: OnboardingMinutesFacts {
    private let settings: SettingsModel
    private let onReload: () -> Void

    /// `onReload`: other state that follows the window becoming key (the
    /// login item row, re-read after an approval in System Settings).
    init(settings: SettingsModel, onReload: @escaping () -> Void = {}) {
        self.settings = settings
        self.onReload = onReload
    }

    /// The saved model, not a half-typed one.
    var isDone: Bool { AutoMinutes.allowed(presence: settings.keyPresence, model: settings.savedModelID) }

    func commit() { settings.commitModelID() }

    /// Keeps a key typed but not yet saved: it must survive a trip to
    /// another window.
    func reload() {
        settings.reload(preservingKeyInput: true)
        onReload()
    }
}

// MARK: - Model step state

extension ModelProvisioner.Failure {
    /// What the user reads. The raw error (English, system-worded) goes to
    /// stderr instead, via the model's `log`.
    var userMessage: String {
        switch self {
        case .offline: Textos.Onboarding.modeloSinConexion
        case .other: Textos.Onboarding.modeloFallo
        }
    }
}

/// What the "Modelo" step shows: the provisioner's state, except that with
/// transcription turned off there is no model to fetch at all.
enum ModelStepState: Equatable {
    case notApplicable
    case checking
    case absent
    case downloading(ModelProgress)
    /// The files exist on disk. Presence, not validation.
    case present
    case failed(ModelProvisioner.Failure)

    static func map(transcriptionEnabled: Bool, provisioner: ModelProvisioner.State) -> ModelStepState {
        guard transcriptionEnabled else { return .notApplicable }
        switch provisioner {
        case .checking: return .checking
        case .absent: return .absent
        case .present: return .present
        case .downloading(let progress): return .downloading(progress)
        case .failed(let failure): return .failed(failure)
        }
    }
}

// MARK: - Model

/// The onboarding window's container: navigation, the four permission rows
/// and the model download, all through injected seams so tests never touch
/// TCC, the network or a window.
///
/// Nothing here prompts by itself. Reading statuses is read-only; every
/// request comes from `perform(_:)`, which a single user click drives, and
/// `inFlight` keeps a second click from stacking a second system dialog.
/// The model downloads only from `startModelDownload()` (a button).
@MainActor
@Observable
final class OnboardingModel {
    private(set) var flow = OnboardingFlow()
    /// `nil` for a kind until the first read completes.
    private(set) var rows: [PermissionKind: PermissionRow] = [:]
    /// The kind whose system prompt is up. Every "Permitir" waits for it.
    private(set) var inFlight: PermissionKind?
    private(set) var transcriptionEnabled: Bool
    private(set) var provisionerState: ModelProvisioner.State = .checking

    var current: OnboardingStep { flow.current }
    var canGoBack: Bool { flow.canGoBack }
    var primary: OnboardingFlow.Primary { flow.primary }
    var modelState: ModelStepState {
        .map(transcriptionEnabled: transcriptionEnabled, provisioner: provisionerState)
    }

    @ObservationIgnored private let probes: any PermissionProbing
    @ObservationIgnored private let provisioner: ModelProvisioner
    @ObservationIgnored private let config: () -> ConfigValues
    @ObservationIgnored private let isRecording: () -> Bool
    @ObservationIgnored private let minutes: any OnboardingMinutesFacts
    @ObservationIgnored private let openPane: (SettingsPane) -> Void
    @ObservationIgnored private let writeMarker: () throws -> Void
    /// Closes the window after "Empezar". Owned by the window controller,
    /// which assigns it once in its `init` (the model is built first, so it
    /// cannot be passed in); a model without a controller keeps the one it
    /// was built with.
    @ObservationIgnored var close: () -> Void
    @ObservationIgnored private let log: (String) -> Void
    @ObservationIgnored private var hindsightEnabled = false
    @ObservationIgnored private var hindsightURL: URL?
    @ObservationIgnored private var requested: Set<PermissionKind> = []
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    @ObservationIgnored private var finished = false
    /// Set by a close, cleared when the window is key again: a report from
    /// the Local Network tracker that lands in between has nobody to read for.
    @ObservationIgnored private var windowIsClosed = false

    init(
        probes: any PermissionProbing,
        provisioner: ModelProvisioner,
        config: @escaping () -> ConfigValues = { Config.values() },
        isRecording: @escaping () -> Bool,
        minutes: any OnboardingMinutesFacts = PlaceholderMinutesFacts(),
        openPane: @escaping (SettingsPane) -> Void,
        writeMarker: @escaping () throws -> Void,
        close: @escaping () -> Void = {},
        log: @escaping (String) -> Void = { FileHandle.standardError.write(Data(("onboarding: " + $0 + "\n").utf8)) }
    ) {
        self.probes = probes
        self.provisioner = provisioner
        self.config = config
        self.isRecording = isRecording
        self.minutes = minutes
        self.openPane = openPane
        self.writeMarker = writeMarker
        self.close = close
        self.log = log
        transcriptionEnabled = config().transcriptionEnabled
        applyConfig()
    }

    /// The one place config is read into model state: what the steps depend
    /// on (transcription on, memory on, the server to probe).
    private func applyConfig() {
        let values = config()
        transcriptionEnabled = values.transcriptionEnabled
        hindsightEnabled = values.hindsightEnabled
        hindsightURL = values.hindsightEnabled ? values.hindsightBaseURL : nil
    }

    // MARK: - Navigation

    func next() { minutes.commit(); flow.next() }
    func back() { minutes.commit(); flow.back() }
    func jump(to step: OnboardingStep) { minutes.commit(); flow.jump(to: step) }

    /// Informational checkmark; navigation never consults it.
    func stepIsDone(_ step: OnboardingStep) -> Bool {
        OnboardingFlow.isDone(step, facts: .init(
            permissionsDone: PermissionKind.allCases.allSatisfy { kind in
                let status = rows[kind]?.status
                return status == .granted || status == .notApplicable
            },
            modelDone: modelState == .present || modelState == .notApplicable,
            minutesDone: minutes.isDone
        ))
    }

    /// "Omitir y usar solo la transcripción": moves to "Listo" and changes
    /// nothing else. Explicitly not a write of `minutes.enabled`,
    /// `summary.enabled` or any other minutes/summary setting: a user who
    /// already had them on keeps them (A4), covered by a test that compares
    /// the config file byte for byte.
    func skipMinutes() {
        jump(to: .listo)
    }

    /// "Empezar": the only writer of the marker. A failed write still closes
    /// the window (it returns at the next launch); trapping the user in it
    /// would be worse.
    func finish() {
        guard !finished else { return }
        finished = true
        minutes.commit()
        do {
            try writeMarker()
        } catch {
            log("could not write the marker: \(error)")
        }
        close()
    }

    /// Any close path. Writes nothing: only `finish()` does, and it stops
    /// following the provisioner.
    ///
    /// The model outlives the window, so reopening ("Primeros pasos…") keeps
    /// the last step and the "clicked this run" set; the rows stay as last
    /// read until the reopened window becomes key and `windowDidBecomeKey()`
    /// re-reads them. Stale for that instant on purpose: nothing reads the
    /// system before the window is up.
    func windowClosed() {
        observeTask?.cancel()
        observeTask = nil
        finished = false
        windowIsClosed = true
    }

    // MARK: - Permissions

    /// Re-reads config and the four statuses. Read-only: never prompts. A
    /// slower, older read never overwrites a newer one.
    ///
    /// `probingLocalNetwork` lets the read start a background Local Network
    /// probe (only ever after that row's click). Only the window becoming key
    /// asks for it; every read caused by a click or by a probe finishing
    /// passes false and just reads the cache, so probes cannot chain.
    func refreshStatuses(probingLocalNetwork: Bool = true) async {
        applyConfig()

        refreshGeneration += 1
        let generation = refreshGeneration
        let snapshot = await probes.snapshot(hindsight: hindsightURL, refreshLocalNetwork: probingLocalNetwork)
        guard generation == refreshGeneration else { return }
        rows = Self.rows(
            from: snapshot, requested: requested,
            hindsightEnabled: hindsightEnabled, isRecording: isRecording()
        )
    }

    /// The window became key: the user may have changed something in System
    /// Settings or Ajustes, so read again.
    func windowDidBecomeKey() async {
        windowIsClosed = false
        minutes.reload()
        await refreshStatuses()
    }

    /// The Local Network tracker calls this from a background queue when its
    /// probe result changes; hop to the main actor before touching state.
    /// Reads the cache only (see `refreshStatuses`) and does nothing once the
    /// window has closed.
    nonisolated func localNetworkChanged() {
        Task { @MainActor [weak self] in
            guard let self, !self.windowIsClosed else { return }
            await self.refreshStatuses(probingLocalNetwork: false)
        }
    }

    /// One click on a row's button: "Permitir" raises that permission's
    /// prompt, "Abrir Ajustes del Sistema" opens its pane.
    func perform(_ kind: PermissionKind) async {
        guard let row = rows[kind] else { return }
        switch row.action {
        case .none, .waitForRecordingEnd:
            return
        case .openSettings(let pane):
            openPane(pane)
        case .allow:
            guard inFlight == nil else { return }
            if kind == .systemAudio, isRecording() {
                // The row was read before the recording started.
                await refreshStatuses(probingLocalNetwork: false)
                return
            }
            inFlight = kind
            requested.insert(kind)
            await probes.request(kind, hindsight: hindsightURL)
            inFlight = nil
            // The click itself probed Local Network when it was that row.
            await refreshStatuses(probingLocalNetwork: false)
        }
    }

    /// Pure: the four rows for one read. `requested` = kinds clicked this run.
    nonisolated static func rows(
        from snapshot: PermissionSnapshot, requested: Set<PermissionKind>,
        hindsightEnabled: Bool, isRecording: Bool
    ) -> [PermissionKind: PermissionRow] {
        [
            .microphone: PermissionStatus.mapAuthorization(
                snapshot.microphone, pane: .microphone, requestedThisRun: requested.contains(.microphone)
            ),
            .systemAudio: PermissionStatus.mapSystemAudio(
                tcc: snapshot.systemAudio, requestedThisRun: requested.contains(.systemAudio),
                isRecording: isRecording
            ),
            .notifications: PermissionStatus.mapNotifications(
                snapshot.notifications, requestedThisRun: requested.contains(.notifications)
            ),
            .localNetwork: PermissionStatus.mapLocalNetwork(
                hindsightEnabled: hindsightEnabled, probe: snapshot.localNetwork,
                probeRequested: requested.contains(.localNetwork)
            ),
        ]
    }

    // MARK: - Speech model

    /// Follows the provisioner while the window is open. Looking never
    /// downloads.
    func startObservingModel() {
        guard observeTask == nil else { return }
        let provisioner = provisioner
        observeTask = Task { [weak self] in
            for await state in await provisioner.updates() {
                guard let self else { return }
                self.provisionerState = state
            }
        }
    }

    /// "Descargar modelo" / "Reintentar". Joins a download already running
    /// (onboarding and transcription share one flight). The outcome reaches
    /// `modelState` through the provisioner's updates.
    func startModelDownload() async {
        guard transcriptionEnabled else { return }
        do {
            try await provisioner.ensureAvailable()
        } catch is CancellationError {
            // A cancelled caller just stops waiting; the flight goes on.
        } catch {
            // `.failed` arrives through `updates()`; the view shows Spanish
            // copy (`Failure.userMessage`), the raw error only goes to the log.
            log("model download failed: \(error)")
        }
    }
}
