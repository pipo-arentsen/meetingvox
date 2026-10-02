import Foundation
import Testing

@testable import MeetingVox

// MARK: - Progress fold (pure)

/// FluidAudio's download calls the hub once per file, so its fraction can
/// restart from 0 between files. The fold keeps what the user sees monotonic.
@Suite("ModelProgress")
struct ModelProgressTests {
    @Test func theFirstSampleIsTakenAsIs() {
        let p = ModelProgress.fold(nil, fraction: 0.25, phase: .descargando)
        #expect(p == ModelProgress(fraction: 0.25, phase: .descargando))
    }

    @Test func aLowerFractionNeverMovesTheBarBack() {
        let a = ModelProgress.fold(nil, fraction: 0.6, phase: .descargando)
        let b = ModelProgress.fold(a, fraction: 0.1, phase: .descargando)  // next file restarted
        #expect(b.fraction == 0.6)
        let c = ModelProgress.fold(b, fraction: 0.8, phase: .descargando)
        #expect(c.fraction == 0.8)
    }

    @Test func theFractionIsClampedToTheUnitInterval() {
        #expect(ModelProgress.fold(nil, fraction: 1.7, phase: .descargando).fraction == 1)
        #expect(ModelProgress.fold(nil, fraction: -0.4, phase: .descargando).fraction == 0)
    }

    @Test func aNonFiniteFractionKeepsThePreviousOne() {
        let a = ModelProgress.fold(nil, fraction: 0.5, phase: .descargando)
        #expect(ModelProgress.fold(a, fraction: .nan, phase: .descargando).fraction == 0.5)
        #expect(ModelProgress.fold(nil, fraction: .infinity, phase: .descargando).fraction == 0)
    }

    @Test func thePhaseFollowsTheLatestSampleEvenWhenTheFractionDoesNot() {
        let a = ModelProgress.fold(nil, fraction: 0.9, phase: .descargando)
        let b = ModelProgress.fold(a, fraction: 0.2, phase: .preparando)
        #expect(b == ModelProgress(fraction: 0.9, phase: .preparando))
    }
}

// MARK: - Error classification (pure)

@Suite("ModelProvisioner.classify")
struct ModelProvisionerClassifyTests {
    @Test func connectivityURLErrorsAreOffline() {
        for code in [
            URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .timedOut, .dataNotAllowed,
        ] {
            #expect(ModelProvisioner.classify(URLError(code)) == .offline, "\(code)")
        }
    }

    @Test func aBareNSURLErrorDomainErrorIsOffline() {
        let e = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(ModelProvisioner.classify(e) == .offline)
    }

    @Test func anOfflineCauseUnderAWrapperIsStillOffline() {
        let wrapped = NSError(
            domain: "Wrapper", code: 7,
            userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet) as NSError]
        )
        #expect(ModelProvisioner.classify(wrapped) == .offline)
    }

    @Test func otherErrorsKeepTheirDescription() {
        struct Boom: Error, CustomStringConvertible { var description: String { "disk exploded" } }
        #expect(ModelProvisioner.classify(Boom()) == .other("disk exploded"))
        // An HTTP 500 is not a connectivity problem: retry may help, but it is not "offline".
        let http = NSError(domain: "HTTP", code: 500)
        if case .other = ModelProvisioner.classify(http) {} else { Issue.record("HTTP 500 must not be offline") }
        #expect(ModelProvisioner.classify(URLError(.badServerResponse)) != .offline)
    }
}

// MARK: - Provisioner (fake downloader; never touches FluidAudio or the network)

/// A downloader the test drives: `download` suspends on `gate`, reports the
/// scripted samples, then either throws `failure` or marks itself present.
private final class FakeDownloader: ModelDownloader, @unchecked Sendable {
    let directory = URL(fileURLWithPath: "/nonexistent/fake-model")
    private let lock = NSLock()
    private var present: Bool
    private var calls = 0
    private var sawCancellation = false
    private var failures: [Error]
    private let samples: [(Double, ModelProgress.Phase)]
    private let gate: Gate?
    private var sink: (@Sendable (Double, ModelProgress.Phase) -> Void)?

    init(present: Bool = false, failures: [Error] = [], samples: [(Double, ModelProgress.Phase)] = [], gate: Gate? = nil) {
        self.present = present
        self.failures = failures
        self.samples = samples
        self.gate = gate
    }

    var callCount: Int { lock.withLock { calls } }
    var observedCancellation: Bool { lock.withLock { sawCancellation } }

    func isPresent() -> Bool { lock.withLock { present } }

    /// Reports a sample from the test, once `download` is running.
    func emit(_ fraction: Double, _ phase: ModelProgress.Phase) {
        lock.withLock { sink }?(fraction, phase)
    }

    func download(progress: @escaping @Sendable (Double, ModelProgress.Phase) -> Void) async throws {
        lock.withLock { calls += 1; sink = progress }
        for (f, p) in samples { progress(f, p) }
        await gate?.wait()
        if Task.isCancelled { lock.withLock { sawCancellation = true } }
        let failure: Error? = lock.withLock { failures.isEmpty ? nil : failures.removeFirst() }
        if let failure { throw failure }
        lock.withLock { present = true }
    }
}

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

/// Polls (bounded) until `condition` holds; the provisioner is an actor, so
/// its state is only observable asynchronously.
private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

private func state(_ f: Double, _ p: ModelProgress.Phase) -> ModelProvisioner.State {
    .downloading(ModelProgress(fraction: f, phase: p))
}

@Suite("ModelProvisioner")
struct ModelProvisionerTests {
    @Test func aPresentModelIsNotDownloaded() async throws {
        let fake = FakeDownloader(present: true)
        let provisioner = ModelProvisioner(downloader: fake)
        try await provisioner.ensureAvailable()
        try await provisioner.ensureAvailable()
        #expect(fake.callCount == 0)
        var it = await provisioner.updates().makeAsyncIterator()
        #expect(await it.next() == .present)
    }

    @Test func anAbsentModelReportsAbsentUntilAskedToDownload() async throws {
        let fake = FakeDownloader()
        let provisioner = ModelProvisioner(downloader: fake)
        var it = await provisioner.updates().makeAsyncIterator()
        #expect(await it.next() == .absent)
        #expect(fake.callCount == 0)  // looking is not downloading
        try await provisioner.ensureAvailable()
        #expect(fake.callCount == 1)
        var later = await provisioner.updates().makeAsyncIterator()
        #expect(await later.next() == .present)
    }

    @Test func theDirectoryIsTheDownloaders() {
        let fake = FakeDownloader()
        #expect(ModelProvisioner(downloader: fake).directory == fake.directory)
    }

    @Test func concurrentCallersShareOneDownload() async throws {
        let gate = Gate()
        let fake = FakeDownloader(gate: gate)
        let provisioner = ModelProvisioner(downloader: fake)
        let a = Task { try await provisioner.ensureAvailable() }
        let b = Task { try await provisioner.ensureAvailable() }
        let c = Task { try await provisioner.ensureAvailable() }
        #expect(await eventually { await provisioner.inFlightCallers == 3 })
        await gate.release()
        try await a.value
        try await b.value
        try await c.value
        #expect(fake.callCount == 1)
        #expect(fake.isPresent())
    }

    @Test func aFailureReachesEveryJoinerAndIsNotCached() async throws {
        let gate = Gate()
        let fake = FakeDownloader(failures: [URLError(.notConnectedToInternet)], gate: gate)
        let provisioner = ModelProvisioner(downloader: fake)
        let a = Task { try await provisioner.ensureAvailable() }
        let b = Task { try await provisioner.ensureAvailable() }
        #expect(await eventually { await provisioner.inFlightCallers == 2 })
        await gate.release()
        for t in [a, b] {
            await #expect(throws: URLError.self) { try await t.value }
        }
        var it = await provisioner.updates().makeAsyncIterator()
        #expect(await it.next() == .failed(.offline))
        // Reintentar: the next call starts a new download and it succeeds.
        try await provisioner.ensureAvailable()
        #expect(fake.callCount == 2)
        var after = await provisioner.updates().makeAsyncIterator()
        #expect(await after.next() == .present)
    }

    @Test func anUnclassifiedFailureIsReportedWithItsDescription() async throws {
        struct Boom: Error, CustomStringConvertible { var description: String { "disk full" } }
        let fake = FakeDownloader(failures: [Boom()])
        let provisioner = ModelProvisioner(downloader: fake)
        await #expect(throws: Boom.self) { try await provisioner.ensureAvailable() }
        var it = await provisioner.updates().makeAsyncIterator()
        #expect(await it.next() == .failed(.other("disk full")))
    }

    @Test func aCancelledStarterIsReleasedAtOnceWhileTheFlightRunsForTheJoiner() async throws {
        let gate = Gate()
        let fake = FakeDownloader(gate: gate)
        let provisioner = ModelProvisioner(downloader: fake)
        let starter = Task { try await provisioner.ensureAvailable() }
        #expect(await eventually { await provisioner.inFlightCallers == 1 })
        let joiner = Task { try await provisioner.ensureAvailable() }
        #expect(await eventually { await provisioner.inFlightCallers == 2 })
        starter.cancel()
        // Released while the download is still blocked on the gate.
        await #expect(throws: CancellationError.self) { try await starter.value }
        #expect(fake.isPresent() == false)
        #expect(await eventually { await provisioner.inFlightCallers == 1 })
        await gate.release()
        try await joiner.value
        #expect(fake.callCount == 1)
        #expect(fake.observedCancellation == false)
        #expect(fake.isPresent())
    }

    @Test func aCancelledJoinerIsReleasedAtOnceAndTheFlightStillCompletes() async throws {
        let gate = Gate()
        let fake = FakeDownloader(gate: gate)
        let provisioner = ModelProvisioner(downloader: fake)
        let starter = Task { try await provisioner.ensureAvailable() }
        let joiner = Task { try await provisioner.ensureAvailable() }
        #expect(await eventually { await provisioner.inFlightCallers == 2 })
        joiner.cancel()
        await #expect(throws: CancellationError.self) { try await joiner.value }
        #expect(fake.isPresent() == false)  // the download has not finished
        await gate.release()
        try await starter.value
        #expect(fake.callCount == 1)
        #expect(fake.observedCancellation == false)
        #expect(fake.isPresent())
    }

    @Test func aCallerCancelledBeforeAskingNeitherStartsNorJoinsADownload() async {
        let fake = FakeDownloader()
        let provisioner = ModelProvisioner(downloader: fake)
        let t = Task {
            while !Task.isCancelled { await Task.yield() }
            try await provisioner.ensureAvailable()
        }
        t.cancel()
        await #expect(throws: CancellationError.self) { try await t.value }
        #expect(fake.callCount == 0)
    }

    @Test func aFlightSurvivesEveryCallerLeavingAndALaterCallerJoinsIt() async throws {
        let gate = Gate()
        let fake = FakeDownloader(gate: gate)
        let provisioner = ModelProvisioner(downloader: fake)
        let first = Task { try await provisioner.ensureAvailable() }
        #expect(await eventually { await provisioner.inFlightCallers == 1 })
        first.cancel()
        _ = await first.result
        #expect(await eventually { await provisioner.inFlightCallers == 0 })
        let second = Task { try await provisioner.ensureAvailable() }
        #expect(await eventually { await provisioner.inFlightCallers == 1 })
        await gate.release()
        try await second.value
        #expect(fake.callCount == 1)  // joined the running flight, no second download
    }

    @Test func aSubscriberMidFlightGetsTheCurrentStateFirst() async throws {
        let gate = Gate()
        let fake = FakeDownloader(samples: [(0.4, .descargando)], gate: gate)
        let provisioner = ModelProvisioner(downloader: fake)
        let run = Task { try await provisioner.ensureAvailable() }
        #expect(await eventually { await provisioner.currentState() == .downloading(ModelProgress(fraction: 0.4, phase: .descargando)) })
        var it = await provisioner.updates().makeAsyncIterator()
        #expect(await it.next() == .downloading(ModelProgress(fraction: 0.4, phase: .descargando)))
        await gate.release()
        try await run.value
        #expect(await it.next() == .present)
    }

    @Test func aRestartingSourceNeverMovesTheBarBackAndStillUpdatesThePhase() async throws {
        let gate = Gate()
        let fake = FakeDownloader(gate: gate)
        let provisioner = ModelProvisioner(downloader: fake)
        let run = Task { try await provisioner.ensureAvailable() }
        #expect(await eventually { await provisioner.currentState() == .downloading(.zero) })
        fake.emit(0.6, .descargando)
        #expect(await eventually { await provisioner.currentState() == state(0.6, .descargando) })
        // The hub moved to the next file: the fraction restarts, the bar must not.
        fake.emit(0.1, .preparando)
        #expect(await eventually { await provisioner.currentState() == state(0.6, .preparando) })
        fake.emit(0.9, .descargando)
        #expect(await eventually { await provisioner.currentState() == state(0.9, .descargando) })
        await gate.release()
        try await run.value
        #expect(await provisioner.currentState() == .present)
    }

    @Test func aSlowSubscriberSeesTheLatestStateNotABacklog() async throws {
        let gate = Gate()
        let fake = FakeDownloader(gate: gate)
        let provisioner = ModelProvisioner(downloader: fake)
        var slow = await provisioner.updates().makeAsyncIterator()  // subscribed, never read while it all happens
        let run = Task { try await provisioner.ensureAvailable() }
        #expect(await eventually { await provisioner.currentState() == .downloading(.zero) })
        fake.emit(0.3, .descargando)
        #expect(await eventually { await provisioner.currentState() == .downloading(ModelProgress(fraction: 0.3, phase: .descargando)) })
        fake.emit(0.7, .descargando)
        #expect(await eventually { await provisioner.currentState() == .downloading(ModelProgress(fraction: 0.7, phase: .descargando)) })
        await gate.release()
        try await run.value
        // absent, downloading x3 and present all happened: only the latest is left.
        #expect(await slow.next() == .present)
    }
}
