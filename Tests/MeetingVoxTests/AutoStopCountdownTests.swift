import Testing
@testable import MeetingVox

/// The injected-clock auto-stop countdown (times are `systemUptime` values).
@Suite struct AutoStopCountdownTests {
    @Test func notRunningUntilStarted() {
        let countdown = AutoStopCountdown()
        #expect(!countdown.isRunning)
        #expect(countdown.remaining(at: 100) == nil)
        #expect(!countdown.isExpired(at: 1000))
    }

    @Test func startsAtFortyFiveSeconds() {
        var countdown = AutoStopCountdown()
        countdown.start(at: 100)
        #expect(AutoStopCountdown.duration == 45)
        #expect(countdown.isRunning)
        #expect(countdown.remaining(at: 100) == 45)
        #expect(countdown.remaining(at: 120) == 25)
        #expect(!countdown.isExpired(at: 144.9))
    }

    @Test func textShowsMinutesAndSecondsRoundingUp() {
        #expect(AutoStopCountdown.text(45) == "0:45")
        #expect(AutoStopCountdown.text(44.2) == "0:45")
        #expect(AutoStopCountdown.text(9) == "0:09")
        #expect(AutoStopCountdown.text(0.1) == "0:01")
        #expect(AutoStopCountdown.text(0) == "0:00")
        #expect(AutoStopCountdown.text(-3) == "0:00")
    }

    @Test func expiresAtZeroAndRemainingNeverGoesNegative() {
        var countdown = AutoStopCountdown()
        countdown.start(at: 0)
        #expect(countdown.isExpired(at: 45))
        #expect(countdown.remaining(at: 500) == 0)
    }

    @Test func cancelStopsIt() {
        var countdown = AutoStopCountdown()
        countdown.start(at: 0)
        countdown.cancel()
        #expect(!countdown.isRunning)
        #expect(countdown.remaining(at: 10) == nil)
        #expect(!countdown.isExpired(at: 1000))
    }

    @Test func restartRestartsOnlyARunningCountdown() {
        var countdown = AutoStopCountdown()
        countdown.restart(at: 50)
        #expect(!countdown.isRunning)
        countdown.start(at: 0)
        countdown.restart(at: 25)
        #expect(countdown.remaining(at: 25) == 45)
        #expect(countdown.remaining(at: 60) == 10)
    }
}
