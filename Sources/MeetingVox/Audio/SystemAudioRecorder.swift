import Accelerate
import AVFoundation
import CoreAudio
import Foundation

/// Records all system audio output to a file via a Core Audio process tap
/// (macOS 14.2+). No virtual device, no kernel extension — the tap mixes every
/// process's output to stereo and hands us buffers through a private aggregate
/// device. First use triggers the one-time "System Audio Recording" TCC prompt
/// and lights the purple recording indicator while active.
///
/// The tap excludes MeetingVox's own process when the system lets it (so the
/// app's audio never lands in `system.caf`), else falls back to the plain tap.
/// This is diagnostic only: playback still pauses during ANY recording, because
/// the speakers would leak into `mic.caf` either way.
final class SystemAudioRecorder {
    enum RecorderError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case tapFormatUnreadable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case fileCreationFailed(Error)

        var description: String {
            switch self {
            case .tapCreationFailed(let s):
                return Textos.Errores.tapNoCreado(s)
            case .tapFormatUnreadable(let s): return Textos.Errores.formatoTap(s)
            case .aggregateCreationFailed(let s): return Textos.Errores.agregadoNoCreado(s)
            case .ioProcCreationFailed(let s): return Textos.Errores.ioProcNoCreado(s)
            case .deviceStartFailed(let s): return Textos.Errores.dispositivoNoInicia(s)
            case .fileCreationFailed(let e): return Textos.Errores.archivoSalida(e)
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: AppIdentity.queueLabel("system-tap"))
    private(set) var isRecording = false
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?
    /// Diagnostics only (`quill diag`): receives every tap buffer on the IO
    /// queue. Nil during normal recording. Set before `start`, never after.
    var diagBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Live peak for the recording pill (`MeteredTrack`), published from the IOProc.
    let level = LevelTap()

    /// Core Audio process object of this very process at the last `start`,
    /// nil when the HAL does not know it yet (diag prints it).
    private(set) var ownObject: AudioObjectID?
    /// True only while the running tap was built with this process excluded,
    /// so MeetingVox's own playback never reaches `system.caf`. False whenever
    /// the exclusion was unavailable or refused (the plain tap is running).
    private(set) var excludesSelf = false

    private let ownProcessObject: () -> AudioObjectID?
    private let attemptOverride: ((URL, [AudioObjectID]) throws -> Void)?
    private let log: (String) -> Void

    /// The seams exist for tests: `attempt` replaces the real tap build, so no
    /// Core Audio call is made; nil (production) builds the real tap.
    init(
        ownProcessObject: @escaping () -> AudioObjectID? = { SystemAudioRecorder.processObject(for: getpid()) },
        attempt: ((URL, [AudioObjectID]) throws -> Void)? = nil,
        log: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.ownProcessObject = ownProcessObject
        self.attemptOverride = attempt
        self.log = log
    }

    /// The Core Audio process object `pid` maps to, nil when the HAL has none
    /// (a process that has not touched audio yet, or a failed translation).
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Start capturing system audio, encoding AAC into `url` (use a .caf
    /// extension — CAF needs no finalization pass, so a crash mid-meeting
    /// loses nothing already written).
    ///
    /// The tap first tries to exclude this process, so a session played back
    /// in MeetingVox during a recording stays out of `system.caf`. Any failure
    /// of that attempt is cleaned up and followed by exactly the plain tap, so a
    /// recording that works without the exclusion never loses system audio.
    func start(writingTo url: URL) throws {
        guard !isRecording else { return }

        ownObject = ownProcessObject()
        if let own = ownObject {
            do {
                try attempt(url, [own])
                excludesSelf = true
                isRecording = true
                log("system tap excluding own process (object \(own))")
                return
            } catch {
                cleanup()
                firstBufferAt = nil
                log("system tap exclusion failed (\(error)); recording without it, playback pauses while recording")
            }
        } else {
            log("own process object absent; system tap without exclusion, playback pauses while recording")
        }

        try attempt(url, [])
        excludesSelf = false
        isRecording = true
    }

    private func attempt(_ url: URL, _ exclusions: [AudioObjectID]) throws {
        if let attemptOverride { try attemptOverride(url, exclusions) } else { try startTap(url: url, exclusions: exclusions) }
    }

    /// Today's tap build; any failure throws after its own `cleanup()`.
    private func startTap(url: URL, exclusions: [AudioObjectID]) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclusions)
        description.name = "MeetingVox system tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw RecorderError.tapCreationFailed(status) }
        tapID = newTapID

        do {
            let format = try tapStreamFormat()
            try createAggregateDevice(tapUUID: description.uuid)
            file = try makeFile(url: url, format: format)
            try installIOProc(format: format)
        } catch {
            cleanup()
            throw error
        }
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        excludesSelf = false
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
        }
        cleanup()
    }

    // MARK: -

    private func tapStreamFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError.tapFormatUnreadable(status)
        }
        return format
    }

    private func createAggregateDevice(tapUUID: UUID) throws {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetingVox-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAggregateID)
        guard status == noErr else { throw RecorderError.aggregateCreationFailed(status) }
        aggregateID = newAggregateID
    }

    private func makeFile(url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        do {
            return try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
    }

    private func installIOProc(format: AVAudioFormat) throws {
        let meter = level
        let isFloat = format.commonFormat == .pcmFormatFloat32
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else { return }
            if isFloat, let peak = LevelTap.peak(of: buffer) { meter.publish(peak) }
            self.diagBuffer?(buffer)
            do {
                try file.write(from: buffer)
            } catch {
                FileHandle.standardError.write(Data("system track write failed: \(error)\n".utf8))
            }
        }
        guard status == noErr, let procID else { throw RecorderError.ioProcCreationFailed(status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw RecorderError.deviceStartFailed(status) }
    }

    private func cleanup() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        file = nil
    }
}

/// A system track that can say whether its tap excludes this process.
/// `RecordingSession` reads it so the player knows if it may run mid-recording.
protocol SelfExcludingTap: AnyObject {
    var excludesSelf: Bool { get }
}

extension SystemAudioRecorder: SelfExcludingTap {}
