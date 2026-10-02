@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// The mic track file: native-format buffers in, 48 kHz mono AAC CAF out.
/// The converter is rebuilt whenever the input format changes (e.g. 44.1 kHz
/// stereo -> 16 kHz mono on a Bluetooth HFP switch). After `markResync()`,
/// the next written buffer is preceded by silence covering the capture gap,
/// so the track stays aligned with the system track.
///
/// Has its own lock and no capture-session knowledge, so the recorder's
/// session control never shares a lock with file I/O. Every lock hold is
/// bounded: padding never exceeds the wall-clock gap.
final class MicTrackWriter: @unchecked Sendable {
    enum AppendResult {
        /// Written; `peak` is the converted buffer's peak.
        case written(AVAudioPCMBuffer, peak: Float)
        /// The converter produced nothing yet (resampler priming).
        case buffered
        /// No converter for this format, or conversion / file write failed.
        case failed
        /// `close()` was called.
        case closed
    }

    let fileFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
    )!

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    /// Format whose conversion failure was already logged (once per format).
    private var loggedFailureFormat: AVAudioFormat?
    private var framesWritten: Int64 = 0
    private var resyncPending = false
    private var _firstBufferAt: Date?
    private var firstUptime: TimeInterval?
    /// Host-clock time (s) at which the first written buffer started.
    private var firstMediaTime: Double?
    /// Converts sample timestamps to host time; re-read from `clockSource`
    /// on the first buffer and after every resync (a restart or device
    /// switch may change it).
    private var mediaClock: CMClock?
    private var writeErrors = 0

    private let clockSource: @Sendable () -> CMClock?
    private let log: @Sendable (String) -> Void

    init(url: URL, clockSource: @escaping @Sendable () -> CMClock? = { nil },
         log: @escaping @Sendable (String) -> Void) throws {
        self.clockSource = clockSource
        self.log = log
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: fileFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    var firstBufferAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return _firstBufferAt
    }

    /// The next written buffer checks for (and pads) a gap.
    func markResync() {
        lock.lock()
        resyncPending = true
        lock.unlock()
    }

    /// Closes the file (released here, so it is complete when this returns).
    func close() {
        lock.lock()
        file = nil
        converter = nil
        converterInput = nil
        lock.unlock()
    }

    /// Converts and appends `buffer`, padding a pending gap first.
    /// `presentationTime` is the buffer's sample timestamp, if known.
    func append(_ buffer: AVAudioPCMBuffer, presentationTime: CMTime? = nil) -> AppendResult {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return .closed }
        guard let out = convert(buffer) else { return .failed }
        guard out.frameLength > 0 else { return .buffered }

        let uptime = ProcessInfo.processInfo.systemUptime
        let inputDuration = Double(buffer.frameLength) / buffer.format.sampleRate
        if _firstBufferAt == nil {
            mediaClock = clockSource()
            _firstBufferAt = Date()
            firstUptime = uptime
            firstMediaTime = presentationTime.flatMap(hostSeconds)
            resyncPending = false
        } else if resyncPending, let firstUptime {
            resyncPending = false
            mediaClock = clockSource() ?? mediaClock
            let media = firstMediaTime.flatMap { first in
                presentationTime.flatMap(hostSeconds).map { $0 + inputDuration - first }
            }
            let elapsed = MicTimeline.gapElapsed(media: media, wall: uptime - firstUptime)
            let gap = MicTimeline.silenceFrames(elapsed: elapsed, framesWritten: framesWritten,
                                                incomingFrames: Int64(out.frameLength),
                                                sampleRate: fileFormat.sampleRate)
            if gap > 0 { writeSilence(gap, to: file) }
        }
        do {
            try file.write(from: out)
            framesWritten += Int64(out.frameLength)
        } catch {
            writeErrors += 1
            if writeErrors <= 5 { log("mic track write failed: \(error)") }
            return .failed
        }
        return .written(out, peak: Self.peak(of: out))
    }

    /// Native -> 48 kHz mono Float32. Caller holds `lock`.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: fileFormat)
            converter?.downmix = true
            converterInput = buffer.format
            log("mic: native format \(buffer.format) -> 48 kHz mono" + (converter == nil ? " (NO CONVERTER)" : ""))
        }
        guard let converter else { return nil }
        let ratio = fileFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity) else { return nil }
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
            if loggedFailureFormat != buffer.format {
                loggedFailureFormat = buffer.format
                log("mic convert failed for \(buffer.format): \(error.map { "\($0)" } ?? "unknown")")
            }
            return nil
        }
        return out
    }

    /// Caller holds `lock`.
    private func writeSilence(_ frames: Int64, to file: AVAudioFile) {
        let chunk = AVAudioFrameCount(fileFormat.sampleRate)
        guard let silence = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: chunk),
              let data = silence.floatChannelData?[0]
        else { return }
        data.update(repeating: 0, count: Int(chunk))
        var remaining = frames
        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, Int64(chunk)))
            silence.frameLength = n
            do { try file.write(from: silence) } catch {
                log("mic silence padding failed: \(error)")
                return
            }
            framesWritten += Int64(n)
            remaining -= Int64(n)
        }
        log(String(format: "mic: padded %.1f s of silence across the capture gap",
                   Double(frames) / fileFormat.sampleRate))
    }

    /// Sample timestamp -> host-clock seconds. Caller holds `lock`.
    private func hostSeconds(_ pts: CMTime) -> Double? {
        guard pts.isValid, pts.isNumeric else { return nil }
        let host = CMClockGetHostTimeClock()
        let converted = mediaClock.map { CMSyncConvertTime(pts, from: $0, to: host) } ?? pts
        guard converted.isValid, converted.isNumeric else { return nil }
        return converted.seconds
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        return peak
    }
}
