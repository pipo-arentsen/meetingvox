import Foundation
import Testing
@testable import MeetingVox

/// dBFS scale of the level meters.
@Suite struct LevelMeterScaleTests {
    @Test func endpoints() {
        #expect(LevelMeterScale.fraction(1.0) == 1.0)
        #expect(LevelMeterScale.fraction(0.001) < 1e-6)  // -60 dBFS (Float(0.001) is a hair above)
    }

    @Test func linearInDecibels() {
        #expect(abs(LevelMeterScale.fraction(0.1) - (40.0 / 60.0)) < 1e-6)  // -20 dBFS
        #expect(abs(LevelMeterScale.fraction(0.5) - (60 + 20 * log10(0.5)) / 60) < 1e-6)
    }

    @Test func hfpLevelIsVisible() {
        // The Bluetooth HFP mic sits near -37 dBFS: it must not read as empty.
        let peak = Float(pow(10.0, -37.0 / 20.0))
        let fraction = LevelMeterScale.fraction(peak)
        #expect(abs(fraction - 0.38) < 0.01)
    }

    @Test func clamps() {
        #expect(LevelMeterScale.fraction(0.0001) == 0)
        #expect(LevelMeterScale.fraction(4.0) == 1)
        #expect(LevelMeterScale.fraction(16) == 1)
    }

    @Test func invalidAndTinyReadingsAreEmpty() {
        #expect(LevelMeterScale.fraction(.nan) == 0)
        #expect(LevelMeterScale.fraction(0) == 0)
        #expect(LevelMeterScale.fraction(1e-6) == 0)
        #expect(LevelMeterScale.fraction(-1) == 0)
        #expect(LevelMeterScale.fraction(.infinity) == 0)
    }
}
