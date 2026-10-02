import Foundation
import Testing
@testable import MeetingVox

/// The lifecycle rule of the EventKit store, tested with plain integers (a
/// test never builds an `EKEventStore`).
@Suite struct CalendarStoreCacheTests {
    private final class Counter { var made = 0 }

    private func reading(_ cache: inout CalendarStoreCache<Int>, _ status: CalendarSystemStatus, _ c: Counter) -> Int? {
        cache.forReading(status: status) { c.made += 1; return c.made }
    }

    @Test func notAuthorizedHandsOutNoStoreAndDropsTheCachedOne() {
        let c = Counter()
        var cache = CalendarStoreCache<Int>()
        #expect(cache.forRequest { c.made += 1; return c.made } == 1)
        #expect(reading(&cache, .notDetermined, c) == nil)
        #expect(reading(&cache, .denied, c) == nil)
        // The store made for the request is gone: the next one is new.
        #expect(cache.forRequest { c.made += 1; return c.made } == 2)
    }

    @Test func aGrantMadeLaterInSystemSettingsGetsAFreshStore() {
        let c = Counter()
        var cache = CalendarStoreCache<Int>()
        #expect(reading(&cache, .denied, c) == nil)
        #expect(reading(&cache, .authorized, c) == 1)
        #expect(reading(&cache, .authorized, c) == 1, "reused while it stays authorized")
        #expect(c.made == 1)
    }

    @Test func theStoreUsedForTheRequestIsRecreatedOnTheTransitionToAuthorized() {
        let c = Counter()
        var cache = CalendarStoreCache<Int>()
        let requested = cache.forRequest { c.made += 1; return c.made }
        #expect(requested == 1)
        // First read after the grant: a store created before the grant answers with no events.
        #expect(reading(&cache, .authorized, c) == 2)
        #expect(reading(&cache, .authorized, c) == 2)
    }

    @Test func revokingAndGrantingAgainRecreatesTheStore() {
        let c = Counter()
        var cache = CalendarStoreCache<Int>()
        #expect(reading(&cache, .authorized, c) == 1)
        #expect(reading(&cache, .denied, c) == nil)
        #expect(reading(&cache, .authorized, c) == 2)
    }
}
