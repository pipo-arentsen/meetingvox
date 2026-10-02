import Network
import Testing
@testable import MeetingVox

@Suite struct HindsightSchedulerTests {
    @Test func sweepsOnlyWhenThePathBecomesSatisfied() {
        #expect(!HindsightScheduler.becameSatisfied(previous: nil, current: .satisfied))
        #expect(HindsightScheduler.becameSatisfied(previous: .unsatisfied, current: .satisfied))
        #expect(HindsightScheduler.becameSatisfied(previous: .requiresConnection, current: .satisfied))
        #expect(!HindsightScheduler.becameSatisfied(previous: .satisfied, current: .satisfied))
        #expect(!HindsightScheduler.becameSatisfied(previous: .satisfied, current: .unsatisfied))
    }

    @Test func sweepIntervalIsTenMinutes() {
        #expect(HindsightScheduler.sweepInterval == 600)
    }
}
