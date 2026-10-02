import AVFoundation
import CoreAudio
import Foundation

/// What a "Permitir" on the system-audio row did.
enum SystemAudioTriggerOutcome: Equatable, Sendable {
    /// A recording is running: nothing was created or requested.
    case refusedWhileRecording
    case granted
    case denied
    /// Asked, no definite answer (SPI missing, or the answer is still pending).
    case requested
}

/// Raises the system-audio prompt from a user click.
protocol SystemAudioPermissionTrigger: Sendable {
    func trigger() async -> SystemAudioTriggerOutcome
}

/// The decision chain, over seams so it is tested without creating a tap:
/// refuse while recording, `TCCAccessRequest`, re-preflight, and if still
/// undetermined (or the SPI is missing) a brief private tap, then preflight
/// again. The recording flag is read before every step that raises anything,
/// because a recording can start while the prompt is waiting for an answer.
struct SystemAudioTriggerChain: SystemAudioPermissionTrigger {
    let tcc: TCCAccessing
    let isRecording: @Sendable () -> Bool
    /// Creates and destroys the private tap (`PrivateTapPermissionPrimer`).
    let ioTrigger: @Sendable () async -> Void

    func trigger() async -> SystemAudioTriggerOutcome {
        if isRecording() { return .refusedWhileRecording }
        _ = await tcc.requestAudioCapture()
        if let settled = Self.settled(tcc.preflightAudioCapture()) { return settled }
        // Tap creation alone may not prompt on every macOS; the IO is the
        // proven prompt source. Never while a recording started meanwhile.
        if isRecording() { return .refusedWhileRecording }
        await ioTrigger()
        return Self.settled(tcc.preflightAudioCapture()) ?? .requested
    }

    private static func settled(_ status: TCCAccessStatus?) -> SystemAudioTriggerOutcome? {
        switch status {
        case .granted: .granted
        case .denied: .denied
        case .unknown, nil: nil
        }
    }
}

/// The live adapter: the TCC bridge plus the private tap. **Raises the
/// system-audio prompt and briefly lights the recording indicator: MANUAL
/// verification only, never run by an agent.** The TCC access is injected
/// (the same one the probes read the status with); `ioTrigger` defaults to
/// the private tap and is replaced in tests.
struct LiveSystemAudioPermissionTrigger: SystemAudioPermissionTrigger {
    let tcc: TCCAccessing
    let isRecording: @Sendable () -> Bool
    let ioTrigger: @Sendable () async -> Void

    init(
        tcc: TCCAccessing,
        isRecording: @escaping @Sendable () -> Bool,
        ioTrigger: (@Sendable () async -> Void)? = nil
    ) {
        self.tcc = tcc
        self.isRecording = isRecording
        self.ioTrigger = ioTrigger ?? { await PrivateTapPermissionPrimer.run(isRecording: isRecording) }
    }

    func trigger() async -> SystemAudioTriggerOutcome {
        await SystemAudioTriggerChain(tcc: tcc, isRecording: isRecording, ioTrigger: ioTrigger).trigger()
    }
}

/// A private process tap and private aggregate device with an IOProc that
/// discards every buffer for ~0.3 s, then destroys them: the first buffer
/// request is what makes macOS ask for "System Audio Recording". No file is
/// written. Same Core Audio calls as `SystemAudioRecorder`, minus the file.
enum PrivateTapPermissionPrimer {
    static let duration: TimeInterval = 0.3
    static let tapName = "\(AppIdentity.displayName) permission tap"
    static let aggregateName = "\(AppIdentity.displayName)-permission-tap"

    /// `isRecording` is read once more right before the device starts: a
    /// recording that began while the objects were being created wins, and
    /// the primer tears down without ever running IO.
    static func run(isRecording: @Sendable () -> Bool) async {
        let queue = DispatchQueue(label: AppIdentity.queueLabel("system-audio-primer"))
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = tapName
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return }
        defer { AudioHardwareDestroyProcessTap(tapID) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: aggregateName,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else { return }
        defer { AudioHardwareDestroyAggregateDevice(aggregateID) }

        var procID: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, { _, _, _, _, _ in }) == noErr,
              let procID
        else { return }
        defer { AudioDeviceDestroyIOProcID(aggregateID, procID) }

        guard !isRecording() else { return }
        guard AudioDeviceStart(aggregateID, procID) == noErr else { return }
        try? await Task.sleep(for: .seconds(duration))
        AudioDeviceStop(aggregateID, procID)
    }
}
