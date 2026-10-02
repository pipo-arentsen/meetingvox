@preconcurrency import AVFoundation
import CoreAudio
import Foundation

// MARK: - EXPERIMENTAL — `quill diag` only
//
// Alternative mic capture strategy kept for Bluetooth headset (A2DP -> HFP)
// diagnostics. Nothing in production recording uses this file; only
// `quill diag --mode engine-direct` does. (The AVCaptureSession experiment was
// promoted to `CaptureMicRecorder`.)

enum ExperimentalMicError: Error, CustomStringConvertible {
    case noInputDevice
    case noAudioUnit
    case bindFailed(AudioObjectID, OSStatus)
    case formatUnsupported(AVAudioFormat)

    var description: String {
        switch self {
        case .noInputDevice: return "no default audio input device"
        case .noAudioUnit: return "engine input node has no AudioUnit"
        case .bindFailed(let device, let status): return "binding input AudioUnit to device \(device) failed (\(status))"
        case .formatUnsupported(let format): return "unsupported input format \(format)"
        }
    }
}

// MARK: - AVAudioEngine bound directly to the input device

/// EXPERIMENTAL. AVAudioEngine whose input AudioUnit is bound directly to the
/// default input device (`kAudioOutputUnitProperty_CurrentDevice`) instead of
/// AVAudioEngine's implicit `CADefaultDeviceAggregate` (default input +
/// default output). `mainMixerNode` / `outputNode` are never touched, so the
/// engine should not claim the headset's output.
///
/// On `AVAudioEngineConfigurationChange` the engine is NOT recreated (the
/// production destroy-and-recreate restart is what feeds the A2DP <-> HFP
/// oscillation): wait until no further change for 1.0 s, then on the same
/// engine remove the tap, re-read the input format, reinstall the tap, start.
final class ExperimentalDirectEngineMic: @unchecked Sendable {
    /// Raw tap buffers (Float32, input format), on the tap thread.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    /// After every successful (re)start: bound device and input format.
    var onAttached: (@Sendable (AudioObjectID?, AVAudioFormat) -> Void)?
    /// Supplies the device to bind to (the current default input).
    var defaultInputDevice: (@Sendable () -> AudioObjectID)?

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: AppIdentity.queueLabel("diag.engine-direct"))
    private var writer: MicTrackWriter?
    private var observer: NSObjectProtocol?
    private var running = false
    private var generation = 0
    private var changes = 0

    private static let debounce: TimeInterval = 1.0
    private static let maxAttempts = 10

    func start(writingTo url: URL) throws {
        try queue.sync {
            writer = try MicTrackWriter(url: url, log: { [weak self] in self?.log($0) })
            try bindToDefaultInput()
            try installTapAndStart()
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.configurationChanged() }
            }
            running = true
        }
    }

    func stop() {
        queue.sync {
            running = false
            generation += 1
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            if let unit = engine.inputNode.audioUnit { AudioOutputUnitStop(unit) }
        }
        writer?.close()
        writer = nil
    }

    // MARK: Steps (all on `queue`)

    private func bindToDefaultInput() throws {
        guard let device = defaultInputDevice?(), device != kAudioObjectUnknown else {
            throw ExperimentalMicError.noInputDevice
        }
        guard let unit = engine.inputNode.audioUnit else { throw ExperimentalMicError.noAudioUnit }
        var id = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &id,
                                          UInt32(MemoryLayout<AudioObjectID>.size))
        log("engine-direct: bind input AudioUnit -> device \(device): "
            + (status == noErr ? "ok" : "FAILED (\(status))"))
        guard status == noErr else { throw ExperimentalMicError.bindFailed(device, status) }
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        log("engine-direct: input format \(format)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ExperimentalMicError.formatUnsupported(format)
        }
        let onBuffer = self.onBuffer
        let writer = self.writer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            onBuffer?(buffer)
            _ = writer?.append(buffer)
        }
        log("engine-direct: tap installed")
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            log("engine-direct: start FAILED: \(error)")
            throw error
        }
        log("engine-direct: started (isRunning=\(engine.isRunning))")
        onAttached?(boundDevice(), format)
    }

    private func configurationChanged() {
        guard running else { return }
        changes += 1
        generation += 1
        let token = generation
        log("engine-direct: AVAudioEngineConfigurationChange #\(changes) "
            + "(isRunning=\(engine.isRunning)) — waiting \(Self.debounce) s for it to settle")
        queue.asyncAfter(deadline: .now() + Self.debounce) { [weak self] in
            guard let self, self.running, self.generation == token else { return }
            self.reconfigure(attempt: 1, token: token)
        }
    }

    /// Same engine, never recreated.
    private func reconfigure(attempt: Int, token: Int) {
        log("engine-direct: settled; reconfiguring same engine (attempt \(attempt))")
        engine.inputNode.removeTap(onBus: 0)
        log("engine-direct: tap removed")
        if engine.isRunning {
            engine.stop()
            log("engine-direct: engine was still running; stopped")
        }
        let bound = boundDevice()
        let wanted = defaultInputDevice?() ?? AudioObjectID(kAudioObjectUnknown)
        log("engine-direct: bound=\(bound.map { "\($0)" } ?? "?") default input=\(wanted)")
        if bound != wanted {
            do { try bindToDefaultInput() } catch { log("engine-direct: rebind failed: \(error)") }
        }
        do {
            try installTapAndStart()
        } catch {
            guard attempt < Self.maxAttempts else {
                log("engine-direct: giving up after \(attempt) attempts: \(error)")
                return
            }
            queue.asyncAfter(deadline: .now() + Self.debounce) { [weak self] in
                guard let self, self.running, self.generation == token else { return }
                self.reconfigure(attempt: attempt + 1, token: token)
            }
        }
    }

    private func boundDevice() -> AudioObjectID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &device, &size)
        return status == noErr ? device : nil
    }

    private func log(_ message: String) { onLog?(message) }
}
