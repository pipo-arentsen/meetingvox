import Testing
@testable import MeetingVox

/// Smoothing of a track's reading and when the meter says "—".
@Suite struct MeterReadingTests {
    @Test func riseIsImmediate() {
        var reading = MeterReading()
        #expect(reading.update(.sample(0.01), now: 0) == .level(LevelMeterScale.fraction(0.01)))
        #expect(reading.update(.sample(1.0), now: 0.1) == .level(1.0))
    }

    @Test func fallDecaysGraduallyAtOnePointFivePerSecond() {
        var reading = MeterReading()
        _ = reading.update(.sample(1.0), now: 0)
        // A real silent reading (peak 0), not "no write".
        guard case .level(let after) = reading.update(.sample(0), now: 0.2) else {
            Issue.record("expected a level"); return
        }
        #expect(abs(after - 0.7) < 1e-9)
        guard case .level(let later) = reading.update(.sample(0), now: 10) else {
            Issue.record("expected a level"); return
        }
        #expect(later == 0)
    }

    @Test func aTakenZeroIsAnEmptyBarNotADash() {
        var reading = MeterReading()
        #expect(reading.update(.sample(0), now: 0) == .level(0))
        #expect(reading.update(.sample(0), now: 5) == .level(0))
    }

    @Test func unavailableIsADashAndRecovers() {
        var reading = MeterReading()
        #expect(reading.update(.unavailable, now: 0) == .unavailable)
        #expect(reading.update(.sample(1.0), now: 1) == .level(1.0))
        #expect(reading.update(.unavailable, now: 2) == .unavailable)
    }

    @Test func noWriteHoldsAndDecaysUntilOneSecondThenShowsDash() {
        var reading = MeterReading()
        _ = reading.update(.sample(1.0), now: 0)
        guard case .level(let held) = reading.update(.sample(nil), now: 0.5) else {
            Issue.record("expected a level before 1 s"); return
        }
        #expect(abs(held - 0.25) < 1e-9)
        #expect(reading.update(.sample(nil), now: 0.99) != .unavailable)
        #expect(reading.update(.sample(nil), now: 1.0) == .unavailable)
        #expect(reading.update(.sample(nil), now: 3.0) == .unavailable)
        // A write brings it back.
        #expect(reading.update(.sample(0.5), now: 3.1) != .unavailable)
    }

    @Test func noWriteSinceTheStartAlsoTurnsIntoADash() {
        var reading = MeterReading()
        #expect(reading.update(.sample(nil), now: 0) == .level(0))
        #expect(reading.update(.sample(nil), now: 1.0) == .unavailable)
    }
}
