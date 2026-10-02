import Foundation
import Testing
@testable import MeetingVox

// MARK: - Recorder selection

@Suite struct MicBackendTests {
    @Test func rawMicUsesCaptureSession() {
        #expect(MicBackend.forConfig(voiceProcessing: false) == .capture)
        #expect(MicBackend.forConfig(voiceProcessing: false).makeRecorder() is CaptureMicRecorder)
    }

    @Test func voiceProcessingUsesEngine() {
        #expect(MicBackend.forConfig(voiceProcessing: true) == .engine)
        #expect(MicBackend.forConfig(voiceProcessing: true).makeRecorder() is MicRecorder)
    }

    @Test func defaultConfigSelectsCapture() {
        let values = ConfigValues(raw: [:])
        #expect(MicBackend.forConfig(voiceProcessing: values.micVoiceProcessing) == .capture)
    }
}

// MARK: - Silence padding

@Suite struct MicTimelineTests {
    let rate = 48_000.0

    @Test func noGapWhenOnSchedule() {
        // 2 s elapsed, 2 s written minus the 0.1 s buffer that ends now.
        let frames = MicTimeline.silenceFrames(elapsed: 2, framesWritten: 91_200,
                                               incomingFrames: 4_800, sampleRate: rate)
        #expect(frames == 0)
    }

    @Test func padsWallClockGap() {
        // 10 s elapsed, only 4 s written, 0.1 s buffer arriving: 5.9 s missing.
        let frames = MicTimeline.silenceFrames(elapsed: 10, framesWritten: 192_000,
                                               incomingFrames: 4_800, sampleRate: rate)
        #expect(frames == 480_000 - 4_800 - 192_000)
    }

    @Test func ignoresJitterBelowThreshold() {
        // 0.2 s behind: under the 0.25 s minimum.
        let frames = MicTimeline.silenceFrames(elapsed: 5, framesWritten: 240_000 - 9_600,
                                               incomingFrames: 0, sampleRate: rate)
        #expect(frames == 0)
        // 0.3 s behind: padded.
        let more = MicTimeline.silenceFrames(elapsed: 5, framesWritten: 240_000 - 14_400,
                                             incomingFrames: 0, sampleRate: rate)
        #expect(more == 14_400)
    }

    @Test func neverNegativeWhenAhead() {
        let frames = MicTimeline.silenceFrames(elapsed: 1, framesWritten: 96_000,
                                               incomingFrames: 4_800, sampleRate: rate)
        #expect(frames == 0)
    }
}

// MARK: - Padding clamp

@Suite struct MicGapElapsedTests {
    @Test func usesMediaTimelineWhenPlausible() {
        // Delivered late: media says 9.8 s, wall says 10 s -> trust media.
        #expect(MicTimeline.gapElapsed(media: 9.8, wall: 10) == 9.8)
    }

    @Test func clampsMediaToWallClockPlusTolerance() {
        // A stale clock claiming an hour must never pad more than the wall gap.
        #expect(MicTimeline.gapElapsed(media: 3_600, wall: 10) == 10.25)
        #expect(MicTimeline.gapElapsed(media: 10.2, wall: 10) == 10.2)
    }

    @Test func fallsBackToWallClockWhenMediaLagsOrIsMissing() {
        #expect(MicTimeline.gapElapsed(media: 2, wall: 10) == 10)
        #expect(MicTimeline.gapElapsed(media: -50, wall: 10) == 10)
        #expect(MicTimeline.gapElapsed(media: nil, wall: 10) == 10)
        #expect(MicTimeline.gapElapsed(media: .nan, wall: 10) == 10)
    }

    @Test func paddingNeverExceedsWallClockGap() {
        let rate = 48_000.0
        let elapsed = MicTimeline.gapElapsed(media: 3_600, wall: 10)
        let frames = MicTimeline.silenceFrames(elapsed: elapsed, framesWritten: 0,
                                               incomingFrames: 0, sampleRate: rate)
        #expect(frames <= Int64((10 + MicTimeline.wallClockTolerance) * rate))
    }
}

// MARK: - Restart backoff

@Suite struct RestartBackoffTests {
    /// Restart times when something asks for a restart every second.
    private func restartTimes(_ backoff: inout RestartBackoff, from: Int, to: Int) -> [Int] {
        (from..<to).filter { backoff.allow(at: TimeInterval($0)) }
    }

    @Test func scheduleIs5_10_20_40ThenEvery60() {
        var b = RestartBackoff()
        let times = restartTimes(&b, from: 0, to: 300)
        #expect(times == [0, 5, 15, 35, 75, 135, 195, 255])
    }

    @Test func resetsAfter30sOfHealthyAudio() {
        var b = RestartBackoff()
        _ = restartTimes(&b, from: 0, to: 40)     // 0, 5, 15, 35
        #expect(b.restarts == 4)
        // Audio flows every 0.1 s from t=36; not yet 30 s by t=65.
        for t in stride(from: 36.0, to: 65, by: 0.1) { b.noteAudio(at: t) }
        #expect(b.restarts == 4)
        for t in stride(from: 65.0, to: 66.5, by: 0.1) { b.noteAudio(at: t) }
        #expect(b.restarts == 0)
        let r1 = b.allow(at: 66.5)
        #expect(r1)                                // immediate again
        let r2 = b.allow(at: 70)
        #expect(!r2)                               // back to a 5 s wait
    }

    @Test func pausesInAudioBreakTheHealthyStreak() {
        var b = RestartBackoff()
        _ = restartTimes(&b, from: 0, to: 20)     // 0, 5, 15
        for t in stride(from: 16.0, to: 30, by: 0.1) { b.noteAudio(at: t) }
        // 5 s pause, then 20 s more audio: never 30 s in a row.
        for t in stride(from: 35.0, to: 55, by: 0.1) { b.noteAudio(at: t) }
        #expect(b.restarts == 3)
    }
}

// MARK: - Mic health (watchdog + dead mic)

@Suite struct MicHealthMonitorTests {
    @Test func conversionFailureCountsAsDeadAudio() {
        var m = MicHealthMonitor()
        // Buffers keep arriving every 0.1 s but none can be converted.
        var events: [DeadMicDetector.Event] = []
        var t = 0.1
        while t < 20 {
            if let e = m.conversionFailed(at: t) { events.append(e) }
            t += 0.1
        }
        #expect(events.count == 1)
        if case .dead = events.first {} else { Issue.record("expected .dead") }
        // Nothing was written: the watchdog sees the whole stretch as silent.
        #expect(m.lastWriteAt == 0)
        let tick = m.tick(at: 20)
        #expect(tick.silentFor > 2.5)
        #expect(m.isStalled(at: 20))
    }

    @Test func writesFeedTheWatchdog() {
        var m = MicHealthMonitor()
        _ = m.written(peak: 0.1, at: 5)
        #expect(m.lastWriteAt == 5)
        #expect(!m.isStalled(at: 5.4))
        #expect(m.isStalled(at: 5.6))
        let tick = m.tick(at: 5.5)
        #expect(tick.silentFor == 0.5)
    }

    @Test func notifiesAtMostOncePerRecording() {
        var m = MicHealthMonitor()
        var notifications = 0
        var t = 0.1
        // Three dead episodes separated by speech.
        for _ in 0..<3 {
            let end = t + 15
            while t < end {
                if let e = m.written(peak: 0, at: t), m.shouldNotify(e) { notifications += 1 }
                t += 0.1
            }
            if let e = m.written(peak: 0.3, at: t) { #expect(e == .recovered) }
            t += 0.1
        }
        #expect(notifications == 1)
        #expect(m.hasNotified)
    }

    @Test func recoveredNeverNotifies() {
        var m = MicHealthMonitor()
        let notify = m.shouldNotify(.recovered)
        #expect(!notify)
    }
}

// MARK: - Restart rate limiting

@Suite struct RestartLimiterTests {
    @Test func atMostOneRestartPerInterval() {
        var limiter = RestartLimiter(minimumInterval: 5)
        let r1 = limiter.allow(at: 100)
        #expect(r1)
        let r2 = limiter.allow(at: 101)
        #expect(!r2)
        let r3 = limiter.allow(at: 104.9)
        #expect(!r3)
        let r4 = limiter.allow(at: 105)
        #expect(r4)
        let r5 = limiter.allow(at: 106)
        #expect(!r5)
    }

    @Test func watchdogTicksCannotLoop() {
        // A watchdog firing every second for a minute restarts at most 12 times.
        var limiter = RestartLimiter(minimumInterval: 5)
        let restarts = (0..<60).filter { limiter.allow(at: TimeInterval($0)) }.count
        #expect(restarts == 12)
    }
}

// MARK: - Dead mic detection

@Suite struct DeadMicDetectorTests {
    /// Feeds `peak` every 0.1 s from `from` to `to` (exclusive), returns events.
    private func feed(_ detector: inout DeadMicDetector, peak: Float,
                      from: TimeInterval, to: TimeInterval) -> [(TimeInterval, DeadMicDetector.Event)] {
        var events: [(TimeInterval, DeadMicDetector.Event)] = []
        var t = from
        while t < to - 1e-9 {
            if let e = detector.observe(peak: peak, at: t) { events.append((t, e)) }
            t += 0.1
        }
        return events
    }

    @Test func flagsSilenceAfterTenSecondsOnce() {
        var d = DeadMicDetector()
        let events = feed(&d, peak: 0, from: 3, to: 30)
        #expect(events.count == 1)
        if let (t, e) = events.first {
            #expect(t > 13 && t < 13.2)
            if case .dead(let silentFor) = e { #expect(silentFor > 10) } else { Issue.record("expected .dead") }
        }
        #expect(d.inDeadEpisode)
    }

    @Test func startupZerosAreGraceTime() {
        // Zeros from t=0: the first 3 s don't count, so no event before t=13.
        var d = DeadMicDetector()
        let r6 = feed(&d, peak: 0, from: 0, to: 12.9)
        #expect(r6.isEmpty)
        let r7 = feed(&d, peak: 0, from: 12.9, to: 13.3)
        #expect(r7.count == 1)
    }

    @Test func startupBurstThenVoiceNeverFlags() {
        var d = DeadMicDetector()
        let r8 = feed(&d, peak: 0, from: 0, to: 3)
        #expect(r8.isEmpty)
        let r9 = feed(&d, peak: 0.05, from: 3, to: 60)
        #expect(r9.isEmpty)
    }

    @Test func signalResetsTheSilenceClock() {
        var d = DeadMicDetector()
        let r10 = feed(&d, peak: 0, from: 3, to: 12)
        #expect(r10.isEmpty)
        let r11 = d.observe(peak: 0.01, at: 12)
        #expect(r11 == nil)
        // 9.9 s more of silence is still under the threshold.
        let r12 = feed(&d, peak: 0, from: 12.1, to: 22)
        #expect(r12.isEmpty)
    }

    @Test func recoversAndCanFlagANewEpisode() {
        var d = DeadMicDetector()
        let r13 = feed(&d, peak: 0, from: 3, to: 20)
        #expect(r13.count == 1)
        let r14 = d.observe(peak: 0.2, at: 20)
        #expect(r14 == .recovered)
        #expect(!d.inDeadEpisode)
        let r15 = d.observe(peak: 0.2, at: 20.1)
        #expect(r15 == nil)
        let second = feed(&d, peak: 0, from: 21, to: 40)
        #expect(second.count == 1)
    }

    @Test func thresholdIsInclusive() {
        var d = DeadMicDetector()
        // Exactly 1e-4 counts as silence.
        let r16 = feed(&d, peak: 1e-4, from: 3, to: 14)
        #expect(r16.count == 1)
    }
}
