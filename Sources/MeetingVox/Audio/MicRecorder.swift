@preconcurrency import AVFoundation
import Foundation

/// Records the default input device to a fixed-format AAC mono CAF (48 kHz)
/// through AVAudioEngine. Only used when `mic_voice_processing` is on (VPIO
/// needs the duplex engine graph); raw capture goes through
/// `CaptureMicRecorder` because the engine's implicit input+output aggregate
/// fights Bluetooth headsets (see README, Bluetooth notes).
/// Survives device reconfiguration (Bluetooth A2DP -> hands-free switch):
/// rebuilds the engine, keeps writing the same file, resamples to 48 kHz and
/// pads the gap with silence so the mic track stays aligned.
final class MicRecorder: MicRecording, @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)

        var description: String {
            switch self {
            case .engineStartFailed(let e): return Textos.Errores.microfonoNoInicia(e)
            case .fileCreationFailed(let e): return Textos.Errores.archivoMicrofono(e)
            case .formatUnsupported(let f): return Textos.Errores.formatoMicrofono(f)
            }
        }
    }

    private let fileFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
    )!

    private var engine = AVAudioEngine()
    /// Engines replaced by a restart, kept alive until a delayed drain on
    /// `controlQueue` (see `retire(_:)`). Only touched on `controlQueue`.
    private var retiredEngines: [AVAudioEngine] = []
    private var file: AVAudioFile?
    private(set) var isRecording = false
    private(set) var firstBufferAt: Date?

    private let controlQueue = DispatchQueue(label: AppIdentity.queueLabel("mic.control"))
    private let lock = NSLock()
    private var framesWritten: AVAudioFramePosition = 0
    private var resyncPending = false
    private var lastAudioAt = Date()

    private var voiceProcessingActive = false
    private var configObserver: NSObjectProtocol?
    private var watchdog: DispatchSourceTimer?

    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = true

    // MARK: - Diagnostics hooks

    /// What `quill diag` observes. Emitted on the control queue.
    enum DiagEvent {
        /// `AVAudioEngineConfigurationChange` arrived; `current` is false when
        /// it belongs to an engine already replaced (and is ignored).
        case configurationChanged(current: Bool)
        case restarting(reason: String)
        /// The engine (re)started; `input` is live so its AudioUnit's bound
        /// device can be queried.
        case attached(input: AVAudioInputNode, inputFormat: AVAudioFormat, tapFormat: AVAudioFormat)
    }

    /// Diagnostics only (`quill diag`): nil during normal recording, where
    /// they add nothing but a nil check. Set before `start`, never after.
    var diagEvent: ((DiagEvent) -> Void)?
    /// Receives every raw input buffer (pre-conversion) on the tap thread.
    var diagBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Never called: the engine starts synchronously, so every failure is
    /// thrown from `start`.
    var onUnavailable: (@Sendable (Error) -> Void)?

    func start(writingTo url: URL) throws {
        try controlQueue.sync {
            guard !isRecording else { return }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: fileFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
            ]
            do {
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            } catch {
                throw RecorderError.fileCreationFailed(error)
            }
            framesWritten = 0
            firstBufferAt = nil
            resyncPending = false
            voiceProcessingActive = Config.micVoiceProcessing()
            isRecording = true
            do {
                try attach()
            } catch {
                isRecording = false
                file = nil
                throw error
            }
            startWatchdog()
        }
    }

    func stop() {
        controlQueue.sync {
            guard isRecording else { return }
            isRecording = false
            watchdog?.cancel()
            watchdog = nil
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            configObserver = nil
            engine.inputNode.removeTap(onBus: 0)
            Self.halt(engine)
        }
        lock.lock()
        file = nil
        lock.unlock()
    }

    private func attach() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode

        if voiceProcessingActive {
            do {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                log("warning: mic voice processing unavailable (\(error)) — recording raw mic")
                voiceProcessingActive = false
            }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: inputFormat.sampleRate,
                                             channels: 1, interleaved: false)
        else { throw RecorderError.formatUnsupported(inputFormat) }

        let tapFormat: AVAudioFormat
        if voiceProcessingActive {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            tapFormat = monoFormat
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
        } else {
            tapFormat = inputFormat
            livenessSettled = true
        }

        guard let converter = AVAudioConverter(from: tapFormat, to: fileFormat) else {
            throw RecorderError.formatUnsupported(tapFormat)
        }
        converter.downmix = true

        installTap(on: input, format: tapFormat, converter: converter)
        observeConfigurationChanges(of: engine)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            retire(engine)
            throw RecorderError.engineStartFailed(error)
        }

        lock.lock()
        lastAudioAt = Date()
        lock.unlock()

        diagEvent?(.attached(input: input, inputFormat: inputFormat, tapFormat: tapFormat))
        log("mic: voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(inputFormat) tap=\(tapFormat) file=\(fileFormat)")
    }

    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                            converter: AVAudioConverter) {
        let ratio = fileFormat.sampleRate / format.sampleRate
        let checkFrames = Int(format.sampleRate)
        let checkLiveness = voiceProcessingActive

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.diagBuffer?(buffer)

            if checkLiveness && !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames { self.livenessPeak = max(self.livenessPeak, abs(data[i])) }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        self.controlQueue.async { self.fallBackToRaw() }
                        return
                    }
                }
            }

            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: self.fileFormat, frameCapacity: capacity)
            else { return }

            let feed = OneShotFeed(buffer)
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if let next = feed.take() {
                    inputStatus.pointee = .haveData
                    return next
                }
                inputStatus.pointee = .noDataNow
                return nil
            }
            if status == .error {
                self.log("mic convert failed: \(error.map { "\($0)" } ?? "unknown")")
                return
            }
            if out.frameLength > 0 { self.append(out) }
        }
    }

    private func append(_ out: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }

        let now = Date()
        lastAudioAt = now
        if firstBufferAt == nil { firstBufferAt = now }

        if resyncPending, let first = firstBufferAt {
            resyncPending = false
            let expected = AVAudioFramePosition(now.timeIntervalSince(first) * fileFormat.sampleRate)
                - AVAudioFramePosition(out.frameLength)
            let gap = expected - framesWritten
            if gap > AVAudioFramePosition(fileFormat.sampleRate / 4) { writeSilence(gap, to: file) }
        }

        do {
            try file.write(from: out)
            framesWritten += AVAudioFramePosition(out.frameLength)
        } catch {
            log("mic track write failed: \(error)")
        }
    }

    private func writeSilence(_ frames: AVAudioFramePosition, to file: AVAudioFile) {
        let chunk = AVAudioFrameCount(fileFormat.sampleRate)
        guard let silence = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: chunk),
              let data = silence.floatChannelData?[0]
        else { return }
        data.update(repeating: 0, count: Int(chunk))

        var remaining = frames
        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, AVAudioFramePosition(chunk)))
            silence.frameLength = n
            do { try file.write(from: silence) } catch {
                log("mic silence padding failed: \(error)")
                return
            }
            framesWritten += AVAudioFramePosition(n)
            remaining -= AVAudioFramePosition(n)
        }
        log(String(format: "mic: padded %.1f s of silence across the device change",
                   Double(frames) / fileFormat.sampleRate))
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        let id = ObjectIdentifier(engine)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.controlQueue.async {
                let current = ObjectIdentifier(self.engine) == id
                self.diagEvent?(.configurationChanged(current: current))
                guard current else { return }
                self.restart(reason: "device configuration changed")
            }
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRecording else { return }
            self.lock.lock()
            let silentFor = Date().timeIntervalSince(self.lastAudioAt)
            self.lock.unlock()
            if silentFor > 2.5 {
                self.restart(reason: String(format: "no mic audio for %.1f s", silentFor))
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func restart(reason: String) {
        guard isRecording else { return }
        diagEvent?(.restarting(reason: reason))
        log("mic: \(reason) — restarting capture")
        retire(engine)

        lock.lock()
        resyncPending = true
        lock.unlock()

        for attempt in 1...10 {
            guard isRecording else { return }
            do {
                try attach()
                return
            } catch {
                if attempt == 10 {
                    log("mic restart failed: \(error) — will retry on next watchdog tick")
                    lock.lock()
                    lastAudioAt = Date()
                    lock.unlock()
                    return
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }

    /// Crash fix (`required condition is false: false == AUI().IsRunning()`
    /// thrown from `-[AVAudioEngine dealloc]` on a libdispatch worker).
    ///
    /// Root cause: on a Bluetooth HFP switch the engine posts
    /// `AVAudioEngineConfigurationChange` from its own queue, and the posted
    /// `Notification` retains the engine (it is the `object`). `restart`
    /// used to call `stop()` and then drop `self.engine` right away, so the
    /// last reference could end up being the in-flight notification — the
    /// engine was then deallocated on AVAudioEngine's notification thread,
    /// concurrently with its own IO reconfiguration, while the input
    /// AudioUnit had been started again underneath us. Tearing down a
    /// running IO unit trips that assertion and aborts the process.
    ///
    /// Fix: stop the old engine completely (tap removed, engine stopped,
    /// and the input AUHAL explicitly stopped) on `controlQueue`, and keep
    /// a strong reference here so the final release also happens on
    /// `controlQueue`, well after any in-flight notification has let go.
    private func retire(_ old: AVAudioEngine) {
        old.inputNode.removeTap(onBus: 0)
        Self.halt(old)
        park(old)
    }

    /// Keeps `old` alive on `controlQueue` and releases it (stopped again,
    /// in case the system restarted its IO unit meanwhile) 2 s later, on
    /// this same queue. An engine that is still `self.engine` (a failed
    /// start about to be replaced) stays retained by `self.engine` until the
    /// next `attach`, which also runs on this queue.
    private func park(_ old: AVAudioEngine) {
        guard !retiredEngines.contains(where: { $0 === old }) else { return }
        retiredEngines.append(old)
        let id = ObjectIdentifier(old)
        controlQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self,
                  let index = self.retiredEngines.firstIndex(where: { ObjectIdentifier($0) == id })
            else { return }
            let engine = self.retiredEngines.remove(at: index)
            Self.halt(engine)
            // `engine` goes out of scope here, on `controlQueue`.
        }
    }

    /// Stops the engine and, belt and braces, its input IO unit — which
    /// AVAudioEngine may have restarted on its own during a reconfiguration
    /// without reflecting it in `isRunning`.
    private static func halt(_ engine: AVAudioEngine) {
        engine.stop()
        if let unit = engine.inputNode.audioUnit { AudioOutputUnitStop(unit) }
    }

    private func fallBackToRaw() {
        guard isRecording, voiceProcessingActive else { return }
        voiceProcessingActive = false
        restart(reason: "voice processing delivered silence — switching to raw capture")
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

