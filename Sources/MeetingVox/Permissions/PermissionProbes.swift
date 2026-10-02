import AVFoundation
import Foundation
import UserNotifications

/// What one read of the system found. **Read-only**: producing it never
/// prompts.
struct PermissionSnapshot: Equatable, Sendable {
    var microphone: SystemAuthorization
    /// `nil` = unbundled process, the notification center is not touched.
    var notifications: SystemAuthorization?
    /// `nil` = the private TCC preflight is missing.
    var systemAudio: TCCAccessStatus?
    /// The last Local Network probe of this run; `nil` until the user clicked.
    var localNetwork: LocalNetworkProbe.Result?
}

/// The window's view of the system: read the four statuses, and raise one
/// prompt per call, each from a single user click. Faked in the model tests.
protocol PermissionProbing: Sendable {
    /// Never prompts. Re-probes Local Network only if the user already
    /// clicked it this run (`hindsight` = the `base_url`, if configured) AND
    /// `refreshLocalNetwork` is true: a read caused by a probe finishing must
    /// pass false, or every probe would start the next one.
    func snapshot(hindsight: URL?, refreshLocalNetwork: Bool) async -> PermissionSnapshot
    /// Raises the prompt of `kind` and returns when its callback returned, so
    /// the next request never stacks a second system dialog.
    func request(_ kind: PermissionKind, hindsight: URL?) async
}

extension PermissionProbing {
    /// A read that may re-probe Local Network (the window-key read).
    func snapshot(hindsight: URL?) async -> PermissionSnapshot {
        await snapshot(hindsight: hindsight, refreshLocalNetwork: true)
    }
}

/// The live probes. **`request` raises real system prompts** (microphone,
/// notifications, system audio, Local Network): MANUAL verification only.
final class LivePermissionProbes: PermissionProbing, @unchecked Sendable {
    private let tcc: TCCAccessing
    private let systemAudio: SystemAudioPermissionTrigger
    private let localNetwork: LocalNetworkTracker
    private let readMicrophone: @Sendable () -> SystemAuthorization
    private let readNotifications: @Sendable () async -> SystemAuthorization?

    /// `systemAudioTap` and `localNetworkProbe` default to the live private
    /// tap and the live probe; tests replace them.
    init(
        tcc: TCCAccessing = TCCBridge.live,
        isRecording: @escaping @Sendable () -> Bool,
        systemAudioTap: (@Sendable () async -> Void)? = nil,
        localNetworkProbe: @escaping @Sendable (URL) async -> LocalNetworkProbe.Result = {
            await LocalNetworkProbe.probe(baseURL: $0)
        },
        onLocalNetworkChange: @escaping @Sendable () -> Void = {},
        readMicrophone: @escaping @Sendable () -> SystemAuthorization = { LivePermissionProbes.microphone() },
        readNotifications: @escaping @Sendable () async -> SystemAuthorization? = { await LivePermissionProbes.notifications() }
    ) {
        self.tcc = tcc
        self.readMicrophone = readMicrophone
        self.readNotifications = readNotifications
        self.systemAudio = LiveSystemAudioPermissionTrigger(tcc: tcc, isRecording: isRecording, ioTrigger: systemAudioTap)
        self.localNetwork = LocalNetworkTracker(probe: localNetworkProbe, onChange: onLocalNetworkChange)
    }

    /// Never waits on the network: Local Network comes from the tracker's
    /// cache, refreshed in the background once the user has clicked.
    func snapshot(hindsight: URL?, refreshLocalNetwork: Bool) async -> PermissionSnapshot {
        if refreshLocalNetwork, let hindsight { localNetwork.refreshIfClicked(hindsight) }
        return PermissionSnapshot(
            microphone: readMicrophone(),
            notifications: await readNotifications(),
            systemAudio: tcc.preflightAudioCapture(),
            localNetwork: localNetwork.current
        )
    }

    func request(_ kind: PermissionKind, hindsight: URL?) async {
        switch kind {
        case .microphone:
            _ = await MicPermission.request()
        case .notifications:
            guard NotifierFactory.currentKind == .userNotifications else { return }
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: UserNotificationsNotifier.authorizationOptions)
        case .systemAudio:
            _ = await systemAudio.trigger()
        case .localNetwork:
            if let hindsight { await localNetwork.click(hindsight) }
        }
    }

    // MARK: - Reads

    static func microphone() -> SystemAuthorization {
        SystemAuthorization(av: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// `nil` unbundled: `UNUserNotificationCenter.current()` crashes there.
    static func notifications() async -> SystemAuthorization? {
        guard NotifierFactory.currentKind == .userNotifications else { return nil }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return SystemAuthorization(un: settings.authorizationStatus)
    }
}
