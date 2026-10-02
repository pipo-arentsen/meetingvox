@preconcurrency import AVFoundation
import Accelerate
import Foundation
import Synchronization

// MARK: - Peak cell

/// A lock-free "peak since the last read" cell: audio queues `publish`, the
/// pill's 10 Hz poll on main `sample()`s. No allocation, lock or dispatch on
/// either side, so the audio paths stay as they were.
///
/// Encoding: writers store `peak.bitPattern + 1` with an atomic max. Non-negative
/// IEEE-754 patterns order like their integer values and the `+ 1` makes a
/// written 0.0 distinguishable from "no write" (0). A read is an `exchange(0)`,
/// so no peak between two reads is lost. The encoding stays below 2^31 on
/// purpose: `Atomic<UInt32>.max` compares as SIGNED on Swift 6.3.3 (measured:
/// `max(0x8000_0005)` on 0 leaves 0), so a high-bit marker would never win.
final class LevelTap: Sendable {
    /// Peaks above this are clamped (float32 audio can overshoot 1.0 a little;
    /// anything wild is a bug upstream, not a louder meter).
    static let ceiling: Float = 16

    private let bits = Atomic<UInt32>(0)

    /// Ignores non-finite and negative values. A lower peak never lowers the
    /// held maximum.
    func publish(_ peak: Float) {
        guard peak.isFinite, peak >= 0 else { return }
        let clamped = min(peak, Self.ceiling)
        bits.max(clamped.bitPattern + 1, ordering: .relaxed)
    }

    /// The peak since the last read and resets the cell; nil when nothing was
    /// written since (the track is silent *or* not delivering).
    func sample() -> Float? {
        let raw = bits.exchange(0, ordering: .relaxed)
        guard raw != 0 else { return nil }
        return Float(bitPattern: raw - 1)
    }

    /// Peak magnitude of a float32 buffer (interleaved: one pass over all
    /// samples; planar: one `vDSP_maxmgv` per plane); nil for any other format
    /// or an empty buffer. No allocation: the result lives on the stack.
    static func peak(of buffer: AVAudioPCMBuffer) -> Float? {
        guard buffer.format.commonFormat == .pcmFormatFloat32, buffer.frameLength > 0,
              let data = buffer.floatChannelData else { return nil }
        let frames = vDSP_Length(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var peak: Float = 0
        if buffer.format.isInterleaved {
            vDSP_maxmgv(data[0], 1, &peak, frames * vDSP_Length(channels))
        } else {
            for plane in 0..<channels {
                var planePeak: Float = 0
                vDSP_maxmgv(data[plane], 1, &planePeak, frames)
                peak = max(peak, planePeak)
            }
        }
        return peak
    }
}

// MARK: - Recorder seams

/// A track that exposes its live level. Only the raw `AVCaptureSession` mic and
/// the system tap conform; the VPIO engine mic does not ("Yo" shows "—").
protocol MeteredTrack: AnyObject {
    var level: LevelTap { get }
}

/// The mic stopped hearing anything (`silent`) or hears again (`back`): the
/// existing `DeadMicDetector` events, forwarded once per transition.
enum MicSignal: Sendable, Equatable {
    case silent, back

    /// `DeadMicDetector` emits `.dead` and `.recovered` once per episode, so
    /// this is once per transition too.
    init(_ event: DeadMicDetector.Event) {
        switch event {
        case .dead: self = .silent
        case .recovered: self = .back
        }
    }
}

/// A mic recorder that reports `MicSignal`s. Separate from `MicRecording`
/// (untouched). Set `onSignalChange` before `start`.
protocol MicSignalReporting: AnyObject {
    var onSignalChange: (@Sendable (MicSignal) -> Void)? { get set }
}

// MARK: - Polling value types

/// One track in a `LevelSnapshot`.
enum TrackLevel: Equatable, Sendable {
    /// Not started, failed, lost or not metered: the UI shows "—".
    case unavailable
    /// Peak since the last poll; nil = no write since.
    case sample(Float?)
}

/// What `RecordingSession.levels()` returns.
struct LevelSnapshot: Equatable, Sendable {
    var mic: TrackLevel
    var system: TrackLevel
}

extension CaptureMicRecorder: MeteredTrack, MicSignalReporting {}
extension SystemAudioRecorder: MeteredTrack {}
