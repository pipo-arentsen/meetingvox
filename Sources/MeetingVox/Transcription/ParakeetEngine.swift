@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Parakeet Ultra (moondream's full-precision post-training of the TDT 0.6B
/// v3 multilingual model) via FluidAudio's Core ML port. Same tokenizer,
/// window and decoder/joint contract as v3 — only the encoder weights and
/// accuracy differ. Quiet tracks (e.g. Bluetooth hands-free mics) are
/// gain-normalized into a temp file before transcription; the recorded file
/// is never modified.
///
/// v3 drifted into inventing English words on real Spanish meetings; Ultra
/// removed those hallucinations in spike testing with no speed regression.
/// The `language:` hint has no effect on Ultra (it only gates v3's top-K
/// script filtering), so it is intentionally never passed here.
actor ParakeetEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL, Error?)

        var description: String {
            switch self {
            case .notPrepared: return "parakeet engine used before prepare()"
            case .unreadableAudio(let url, let e):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            }
        }
    }

    nonisolated let name = "parakeet"
    nonisolated let model = "parakeet-ultra-coreml"

    private var manager: AsrManager?
    private let provisioner: ModelProvisioner

    /// The provisioner is shared by default so the onboarding download and
    /// `prepare()` (a resumed transcription) never fetch the model twice.
    init(provisioner: ModelProvisioner = .shared) {
        self.provisioner = provisioner
    }

    func prepare() async throws {
        guard manager == nil else { return }
        // Download (or join the download in flight) first, then load. "Present"
        // only means the files exist: `AsrModels.load` (via `ModelHub.loadModels`)
        // may still revalidate the cache and purge and re-download a corrupt or
        // mismatched one, same as `downloadAndLoad` did before.
        try await provisioner.ensureAvailable()
        let models = try await AsrModels.load(from: provisioner.directory, version: .ultra)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let manager else { throw EngineError.notPrepared }

        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        let (input, cleanup) = Self.normalizedIfQuiet(audio)
        defer { cleanup() }

        var state = try TdtDecoderState()
        let result = try await manager.transcribe(input, decoderState: &state)

        let words = buildWordTimings(from: result.tokenTimings ?? [])
        guard !words.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty
                ? []
                : [TranscriptSegment(start: 0, end: result.duration, text: text)]
        }
        return Self.segments(from: words)
    }

    func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
    }

    // MARK: - Loudness normalization

    /// Loud speech (95th percentile of 100 ms block RMS, silence excluded)
    /// is brought to ~-16 dBFS. Only boosts, never attenuates.
    private static let targetRMS: Float = 0.15
    private static let maxGain: Float = 20
    private static let minGainToApply: Float = 1.5
    private static let silenceFloor: Float = 1e-4

    /// Returns the URL to transcribe plus a cleanup closure. On any failure
    /// falls back to the original file.
    private static func normalizedIfQuiet(_ url: URL) -> (URL, () -> Void) {
        let noop: () -> Void = {}
        do {
            let reader = try AVAudioFile(forReading: url)
            let format = reader.processingFormat

            // Pass 1: loudness stats, streaming.
            let block = AVAudioFrameCount(max(1, Int(format.sampleRate / 10)))
            guard let blockBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)
            else { return (url, noop) }
            var levels: [Float] = []
            while reader.framePosition < reader.length {
                try reader.read(into: blockBuf, frameCount: block)
                if blockBuf.frameLength == 0 { break }
                let level = rms(blockBuf)
                if level > silenceFloor { levels.append(level) }
            }
            guard levels.count >= 10 else { return (url, noop) }
            levels.sort()
            let p95 = levels[min(levels.count - 1, Int(Float(levels.count) * 0.95))]
            let gain = min(maxGain, targetRMS / p95)
            guard gain >= minGainToApply else { return (url, noop) }

            // Pass 2: write a boosted 16-bit WAV copy, streaming.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(AppIdentity.tempPrefix)\(UUID().uuidString).wav")
            let cleanup: () -> Void = { _ = try? FileManager.default.removeItem(at: tmp) }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            do {
                let writer = try AVAudioFile(
                    forWriting: tmp, settings: settings,
                    commonFormat: .pcmFormatFloat32, interleaved: false
                )
                let chunk = AVAudioFrameCount(max(4096, Int(format.sampleRate)))
                guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)
                else { cleanup(); return (url, noop) }
                reader.framePosition = 0
                while reader.framePosition < reader.length {
                    try reader.read(into: buf, frameCount: chunk)
                    if buf.frameLength == 0 { break }
                    apply(gain, to: buf)
                    try writer.write(from: buf)
                }
                writer.close()
            } catch {
                cleanup()
                throw error
            }

            log("normalize: \(url.lastPathComponent) gain x\(String(format: "%.1f", gain))")
            return (tmp, cleanup)
        } catch {
            log("normalize: skipped for \(url.lastPathComponent) (\(error))")
            return (url, noop)
        }
    }

    private static func rms(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData else { return 0 }
        let n = Int(b.frameLength)
        let c = Int(b.format.channelCount)
        guard n > 0, c > 0 else { return 0 }
        var sum: Float = 0
        for k in 0..<c {
            let p = ch[k]
            for i in 0..<n { sum += p[i] * p[i] }
        }
        return (sum / Float(n * c)).squareRoot()
    }

    private static func apply(_ gain: Float, to b: AVAudioPCMBuffer) {
        guard let ch = b.floatChannelData else { return }
        let n = Int(b.frameLength)
        for k in 0..<Int(b.format.channelCount) {
            let p = ch[k]
            for i in 0..<n { p[i] = max(-1, min(1, p[i] * gain)) }
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    // MARK: - Segmentation

    /// Group word timings into readable segments: break on sentence-ending
    /// punctuation, a silence gap, or a hard length cap.
    private static func segments(from words: [WordTiming]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [WordTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(TranscriptSegment(
                start: first.startTime,
                end: last.endTime,
                text: current.map(\.word).joined(separator: " ")
            ))
            current = []
        }

        for word in words {
            if let last = current.last, word.startTime - last.endTime > 1.0 {
                flush()
            }
            current.append(word)
            let endsSentence = word.word.hasSuffix(".")
                || word.word.hasSuffix("?")
                || word.word.hasSuffix("!")
            if endsSentence || current.count >= 60 {
                flush()
            }
        }
        flush()
        return out
    }
}
