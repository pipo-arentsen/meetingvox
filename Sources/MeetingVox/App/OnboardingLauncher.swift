import AppKit
import SwiftUI

/// A flag the permission probes (which run off the main actor) can read while
/// the app controller (on it) keeps it current.
final class RecordingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var current = false

    var value: Bool { lock.withLock { current } }
    func set(_ newValue: Bool) { lock.withLock { current = newValue } }
}

/// Builds the onboarding window's whole object graph the first time it is
/// shown (the settings model reads the Keychain's attributes and the probes
/// exist only for this window, so a normal launch pays for none of it) and
/// shows it. Wiring only: every decision lives in the tested pieces.
@MainActor
final class OnboardingLauncher {
    private let runningRoot: URL
    private let recording: RecordingFlag
    private let calendarSource: any CalendarSource
    private let onClose: () -> Void
    private var controller: OnboardingWindowController?

    /// `onClose` runs on every close path (Empezar, the red dot): launch
    /// uses it to release the held starts.
    init(
        runningRoot: URL, recording: RecordingFlag, calendarSource: any CalendarSource, onClose: @escaping () -> Void
    ) {
        self.runningRoot = runningRoot
        self.recording = recording
        self.calendarSource = calendarSource
        self.onClose = onClose
    }

    /// Shows (or re-shows) the window; false when it did not come up.
    func show() -> Bool {
        let controller = self.controller ?? build()
        self.controller = controller
        return controller.show()
    }

    private func build() -> OnboardingWindowController {
        let settings = SettingsModel()
        let calendar = CalendarSettingsModel(configURL: Config.path, source: calendarSource)
        // One recording source for the probes, the model and the login item.
        let recording = self.recording
        let loginItem = LoginItemController.live(isRecording: { recording.value })
        let (_, model) = Self.wire(
            recording: { recording.value },
            probeParts: .live,
            minutes: SettingsMinutesFacts(settings: settings, onReload: { loginItem.refresh() }),
            provisioner: .shared,
            config: { Config.values() },
            openPane: { SystemSettingsLink.openInSystemSettings($0) },
            writeMarker: {
                try OnboardingMarker.write(
                    version: OnboardingGate.currentVersion,
                    at: AppIdentity.onboardingMarkerFile(home: FileManager.default.homeDirectoryForCurrentUser)
                )
            }
        )
        let onClose = self.onClose
        return OnboardingWindowController(
            model: model,
            minutasStep: AnyView(MinutesStepView(settings: settings, model: model)),
            listoStep: AnyView(ReadyStepView(settings: settings, loginItem: loginItem, calendar: calendar, runningRoot: runningRoot)),
            onClose: {
                // Half-typed model IDs and a typed-but-unsaved key are
                // committed / dropped like when Ajustes closes.
                settings.windowDidClose()
                onClose()
            }
        )
    }

    /// The system-facing parts of the live probes; tests replace them so the
    /// real composition runs without TCC, notifications or the network.
    struct ProbeParts: @unchecked Sendable {
        var tcc: TCCAccessing = TCCBridge.live
        var systemAudioTap: (@Sendable () async -> Void)?
        var localNetworkProbe: @Sendable (URL) async -> LocalNetworkProbe.Result = { await LocalNetworkProbe.probe(baseURL: $0) }
        var readMicrophone: @Sendable () -> SystemAuthorization = { LivePermissionProbes.microphone() }
        var readNotifications: @Sendable () async -> SystemAuthorization? = { await LivePermissionProbes.notifications() }

        static let live = ProbeParts()
    }

    /// The probes and the model, joined the way the window uses them: the
    /// Local Network tracker reports from a background queue, before the
    /// model exists to receive it, so the callback is late-bound. Shared by
    /// `build()` and the composition tests.
    static func wire(
        recording: @escaping @Sendable () -> Bool,
        probeParts: ProbeParts,
        minutes: any OnboardingMinutesFacts,
        provisioner: ModelProvisioner,
        config: @escaping () -> ConfigValues,
        openPane: @escaping (SettingsPane) -> Void,
        writeMarker: @escaping () throws -> Void
    ) -> (LivePermissionProbes, OnboardingModel) {
        let modelBox = ModelBox()
        let probes = LivePermissionProbes(
            tcc: probeParts.tcc,
            isRecording: recording,
            systemAudioTap: probeParts.systemAudioTap,
            localNetworkProbe: probeParts.localNetworkProbe,
            onLocalNetworkChange: { modelBox.model?.localNetworkChanged() },
            readMicrophone: probeParts.readMicrophone,
            readNotifications: probeParts.readNotifications
        )
        let model = OnboardingModel(
            probes: probes,
            provisioner: provisioner,
            config: config,
            isRecording: recording,
            minutes: minutes,
            openPane: openPane,
            writeMarker: writeMarker
        )
        modelBox.model = model
        return (probes, model)
    }

    private final class ModelBox: @unchecked Sendable {
        private let lock = NSLock()
        private weak var _model: OnboardingModel?
        var model: OnboardingModel? {
            get { lock.withLock { _model } }
            set { lock.withLock { _model = newValue } }
        }
    }
}
