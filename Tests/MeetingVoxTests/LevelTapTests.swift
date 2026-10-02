@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import MeetingVox

/// The lock-free peak cell and the buffer peak helper.
@Suite struct LevelTapTests {
    @Test func sampleIsNilWithoutWrites() {
        let tap = LevelTap()
        #expect(tap.sample() == nil)
        #expect((tap.sample() ?? 0) == 0)
    }

    @Test func readReturnsTheMaxAndResetsTheCell() {
        let tap = LevelTap()
        tap.publish(0.2)
        tap.publish(0.7)
        #expect((tap.sample() ?? 0) == 0.7)
        #expect((tap.sample() ?? 0) == 0)
        tap.publish(0.3)
        #expect(tap.sample() == 0.3)
        #expect(tap.sample() == nil)
    }

    @Test func aLowerPeakNeverLowersTheHeldMax() {
        let tap = LevelTap()
        tap.publish(0.7)
        tap.publish(0.1)
        #expect((tap.sample() ?? 0) == 0.7)
    }

    @Test func aWrittenZeroIsARealReadingNotNil() {
        let tap = LevelTap()
        tap.publish(0)
        #expect(tap.sample() == 0)
        #expect(tap.sample() == nil)
    }

    @Test func nanInfinityAndNegativeAreIgnored() {
        let tap = LevelTap()
        tap.publish(.nan)
        tap.publish(.infinity)
        tap.publish(-0.5)
        #expect(tap.sample() == nil)
        tap.publish(0.4)
        tap.publish(.nan)
        #expect((tap.sample() ?? 0) == 0.4)
    }

    @Test func peaksAreClampedToSixteen() {
        let tap = LevelTap()
        tap.publish(1000)
        #expect((tap.sample() ?? 0) == 16)
    }

    @Test func manyWritersKeepTheOverallMax() {
        let tap = LevelTap()
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            for step in 0..<1000 {
                tap.publish(Float(index) / 10 + Float(step) / 100_000)
            }
        }
        let expected: Float = 0.7 + 999 / 100_000
        #expect(abs((tap.sample() ?? 0) - expected) < 1e-6)
        #expect(tap.sample() == nil)
    }

    // MARK: peak(of:)

    private func buffer(
        format: AVAudioCommonFormat, channels: AVAudioChannelCount, interleaved: Bool, frames: AVAudioFrameCount
    ) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: format, sampleRate: 48_000, channels: channels, interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: max(frames, 1))!
        buffer.frameLength = frames
        return buffer
    }

    @Test func peakOfInterleavedFloatBuffer() throws {
        let buf = buffer(format: .pcmFormatFloat32, channels: 2, interleaved: true, frames: 4)
        let data = try #require(buf.floatChannelData)
        let samples: [Float] = [0.1, -0.2, 0.3, -0.9, 0.0, 0.5, 0.2, 0.1]
        for (i, s) in samples.enumerated() { data[0][i] = s }
        #expect(LevelTap.peak(of: buf) == 0.9)
    }

    @Test func peakOfPlanarFloatBufferTakesTheLoudestPlane() throws {
        let buf = buffer(format: .pcmFormatFloat32, channels: 2, interleaved: false, frames: 3)
        let data = try #require(buf.floatChannelData)
        for i in 0..<3 { data[0][i] = 0.1 }
        data[1][0] = 0; data[1][1] = -0.6; data[1][2] = 0.2
        #expect(LevelTap.peak(of: buf) == 0.6)
    }

    @Test func nonFloatBufferHasNoPeak() {
        let buf = buffer(format: .pcmFormatInt16, channels: 1, interleaved: false, frames: 4)
        #expect(LevelTap.peak(of: buf) == nil)
    }

    @Test func emptyBufferHasNoPeak() {
        let buf = buffer(format: .pcmFormatFloat32, channels: 1, interleaved: false, frames: 0)
        #expect(LevelTap.peak(of: buf) == nil)
    }
}
