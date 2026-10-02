import Foundation
import Testing

@testable import MeetingVox

/// The cached Local Network result. `snapshot()` must never wait on the
/// probe, which can take its whole timeout: it reads the cache and lets a
/// background refresh update it.
@Suite("LocalNetworkTracker")
struct LocalNetworkTrackerTests {
    private let url = URL(string: "http://hindsight.local:8888")!

    /// A probe that answers when told to, so a test controls when it ends.
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func bump() { lock.withLock { n += 1 } }
    }

    private final class Changes: @unchecked Sendable {
        let stream: AsyncStream<Void>
        let continuation: AsyncStream<Void>.Continuation
        init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
        func fired() { continuation.yield() }
        func next() async { var it = stream.makeAsyncIterator(); _ = await it.next() }
    }

    @Test func nothingIsCachedBeforeTheClick() {
        let calls = Calls()
        let tracker = LocalNetworkTracker(probe: { _ in calls.bump(); return .reachable }, onChange: {})
        tracker.refreshIfClicked(url)
        #expect(tracker.current == nil)
        #expect(tracker.hasClicked == false)
        #expect(calls.count == 0)
    }

    @Test func theClickProbesAndCachesTheResult() async {
        let tracker = LocalNetworkTracker(probe: { _ in .prohibited }, onChange: {})
        await tracker.click(url)
        #expect(tracker.hasClicked)
        #expect(tracker.current == .prohibited)
    }

    @Test func aRefreshAfterTheClickReturnsAtOnceAndUpdatesTheCacheLater() async {
        let gate = Gate()
        let changes = Changes()
        let answers = Calls()
        let tracker = LocalNetworkTracker(
            probe: { _ in
                answers.bump()
                if answers.count == 1 { return .prohibited }
                await gate.wait()
                return .reachable
            },
            onChange: { changes.fired() }
        )
        await tracker.click(url)  // first answer: prohibited
        tracker.refreshIfClicked(url)  // returns while the second probe waits
        #expect(tracker.current == .prohibited)
        await gate.release()
        await changes.next()  // the click's change
        await changes.next()  // the refresh's change
        #expect(tracker.current == .reachable)
    }

    @Test func refreshesWhileOneIsInFlightDoNotStartAnother() async {
        let gate = Gate()
        let calls = Calls()
        let changes = Changes()
        let tracker = LocalNetworkTracker(
            probe: { _ in
                calls.bump()
                if calls.count > 1 { await gate.wait() }
                return calls.count == 1 ? .prohibited : .reachable
            },
            onChange: { changes.fired() }
        )
        await tracker.click(url)
        tracker.refreshIfClicked(url)
        tracker.refreshIfClicked(url)
        tracker.refreshIfClicked(url)
        await gate.release()
        await changes.next()
        await changes.next()
        #expect(calls.count == 2)
    }

    // MARK: - onChange only on a change

    @Test func aRefreshThatFindsTheSameResultReportsNoChange() async {
        let changes = Calls()
        let probes = Calls()
        let tracker = LocalNetworkTracker(
            probe: { _ in probes.bump(); return .reachable }, onChange: { changes.bump() }
        )
        await tracker.click(url)
        #expect(changes.count == 1, "the first answer is a change (nothing was known before)")

        tracker.refreshIfClicked(url)
        while probes.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))  // let the refresh finish and (not) report

        #expect(tracker.current == .reachable)
        #expect(changes.count == 1, "the same answer again is not a change")
    }

    @Test func aClickThatFindsTheSameResultReportsNoChange() async {
        let changes = Calls()
        let tracker = LocalNetworkTracker(probe: { _ in .prohibited }, onChange: { changes.bump() })
        await tracker.click(url)
        await tracker.click(url)  // "Permitir" pressed again
        #expect(changes.count == 1)
    }

    @Test func aDifferentResultAfterTheSameOneReportsAgain() async {
        let changes = Calls()
        let answers = Calls()
        let tracker = LocalNetworkTracker(
            probe: { _ in
                answers.bump()
                return answers.count < 3 ? .prohibited : .reachable
            },
            onChange: { changes.bump() }
        )
        await tracker.click(url)  // nil -> prohibited: change
        await tracker.click(url)  // prohibited -> prohibited: none
        await tracker.click(url)  // prohibited -> reachable: change
        #expect(changes.count == 2)
        #expect(tracker.current == .reachable)
    }

    // MARK: - Through LivePermissionProbes

    private final class FakeTCC: TCCAccessing, @unchecked Sendable {
        func preflightAudioCapture() -> TCCAccessStatus? { .granted }
        func requestAudioCapture() async -> Bool? { true }
    }

    @Test func aSnapshotDoesNotWaitForTheLocalNetworkProbe() async {
        let gate = Gate()
        let calls = Calls()
        let probes = LivePermissionProbes(
            tcc: FakeTCC(), isRecording: { false },
            localNetworkProbe: { _ in
                calls.bump()
                if calls.count > 1 { await gate.wait() }  // the second probe hangs
                return .reachable
            }
        )
        await probes.request(.localNetwork, hindsight: url)  // the click
        let snapshot = await probes.snapshot(hindsight: url)  // must return although a probe hangs
        #expect(snapshot.localNetwork == .reachable)
        #expect(snapshot.systemAudio == .granted)
        await gate.release()
    }

    @Test func aSnapshotBeforeTheClickNeverProbes() async {
        let calls = Calls()
        let probes = LivePermissionProbes(
            tcc: FakeTCC(), isRecording: { false },
            localNetworkProbe: { _ in calls.bump(); return .reachable }
        )
        let snapshot = await probes.snapshot(hindsight: url)
        #expect(snapshot.localNetwork == nil)
        #expect(calls.count == 0)
    }
}
