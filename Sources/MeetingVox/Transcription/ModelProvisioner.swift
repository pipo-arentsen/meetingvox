import Foundation

// MARK: - Progress

/// What the user sees while the speech model downloads. FluidAudio calls its
/// hub once per model file, so the raw fraction can restart from zero between
/// files (and callbacks can arrive out of order); `fold` keeps the bar
/// monotonic.
struct ModelProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case descargando
        /// Core ML compiling what was just downloaded.
        case preparando
    }

    var fraction: Double
    var phase: Phase

    static let zero = ModelProgress(fraction: 0, phase: .descargando)

    /// The fraction never goes back (a non-finite sample is ignored); the
    /// phase is whatever the latest sample said.
    static func fold(_ previous: ModelProgress?, fraction: Double, phase: Phase) -> ModelProgress {
        let floor = previous?.fraction ?? 0
        let clamped = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return ModelProgress(fraction: max(floor, clamped), phase: phase)
    }
}

// MARK: - Seam

/// The two things the provisioner needs from the model vendor: whether the
/// files are already on disk (a pure filesystem read) and how to fetch them.
protocol ModelDownloader: Sendable {
    /// Where the model lives; what the engine loads from.
    var directory: URL { get }
    func isPresent() -> Bool
    /// Downloads without loading. `progress` may be called from any queue.
    func download(progress: @escaping @Sendable (Double, ModelProgress.Phase) -> Void) async throws
}

// MARK: - Provisioner

/// Single-flight download of the speech model. Onboarding, `ParakeetEngine.prepare`
/// and a resumed transcription all go through `ensureAvailable()`, so the
/// model is never fetched twice: concurrent callers await the same flight,
/// and a caller giving up (cancelled Task) does not stop it for the others.
/// A failure is not cached: the next call starts a fresh download.
///
/// Looking (`updates()`, `currentState()`) never downloads; only
/// `ensureAvailable()` does, and callers invoke it from an explicit action.
///
/// `.present` means the files exist on disk, not that they were validated
/// (see `State.present`): onboarding may show "ready" for a cache that
/// `prepare()` later repairs by downloading again.
actor ModelProvisioner {
    static let shared = ModelProvisioner(downloader: FluidAudioModelDownloader())

    enum Failure: Equatable, Sendable {
        case offline
        case other(String)
    }

    enum State: Equatable, Sendable {
        case checking
        case absent
        /// The model files exist on disk. This is a presence check, not a
        /// validation: a corrupt or mismatched cache still reads as present
        /// and can be purged and re-downloaded inside `ParakeetEngine.prepare()`
        /// (FluidAudio revalidates on load), exactly as before this type existed.
        case present
        case downloading(ModelProgress)
        case failed(Failure)
    }

    nonisolated let directory: URL

    private let downloader: any ModelDownloader
    private var state: State = .checking
    private var flight: Task<Void, Error>?
    private var flightID = 0
    private var subscribers: [UUID: AsyncStream<State>.Continuation] = [:]

    /// Callers currently awaiting the flight (the one that started it
    /// included). Observable so tests can join deterministically.
    private(set) var inFlightCallers = 0

    init(downloader: any ModelDownloader) {
        self.downloader = downloader
        self.directory = downloader.directory
    }

    /// Returns once the model files are on disk, downloading them first if
    /// needed. A cancelled caller is released at once with `CancellationError`;
    /// the download itself keeps running for any other caller.
    func ensureAvailable() async throws {
        try Task.checkCancellation()
        if let flight {
            try await join(flight)
            return
        }
        if downloader.isPresent() {
            publish(.present)
            return
        }
        try await join(startFlight())
    }

    /// Current state first, then every change. Idle states (present/absent)
    /// are re-read from disk on subscribing; a failure stays until retried.
    func updates() -> AsyncStream<State> {
        refreshIfIdle()
        let id = UUID()
        // Only the latest state matters: a slow subscriber skips the backlog.
        let (stream, continuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(state)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    func currentState() -> State {
        refreshIfIdle()
        return state
    }

    // MARK: - Flight

    private func join(_ flight: Task<Void, Error>) async throws {
        inFlightCallers += 1
        defer { inFlightCallers -= 1 }
        // Awaiting `flight.value` directly would keep a cancelled caller
        // parked until the whole download ends. Instead a per-caller waiter
        // is resolved by whichever comes first: the flight's outcome or this
        // caller's cancellation. The watcher is unstructured, so cancelling
        // the caller never reaches the flight.
        let waiter = FlightWaiter()
        Task { waiter.resolve(await flight.result) }
        try await withTaskCancellationHandler {
            try await waiter.wait()
        } onCancel: {
            waiter.resolve(.failure(CancellationError()))
        }
    }

    private func startFlight() -> Task<Void, Error> {
        flightID += 1
        let id = flightID
        publish(.downloading(.zero))
        let task = Task { [downloader] in
            // Progress callbacks arrive on arbitrary queues; an ordered
            // stream drained on the actor keeps them in order and lets the
            // flight apply every sample before it reports the outcome.
            // Only the newest sample matters (the fold keeps the bar monotonic).
            let (samples, sink) = AsyncStream.makeStream(of: Sample.self, bufferingPolicy: .bufferingNewest(1))
            let pump = Task { for await s in samples { self.record(s, flight: id) } }
            do {
                try await downloader.download { fraction, phase in
                    sink.yield(Sample(fraction: fraction, phase: phase))
                }
                sink.finish()
                await pump.value
                self.finish(flight: id, error: nil)
            } catch {
                sink.finish()
                await pump.value
                self.finish(flight: id, error: error)
                throw error
            }
        }
        flight = task
        return task
    }

    /// One caller's view of the flight: resolved exactly once, by the flight's
    /// outcome or by the caller's cancellation, whichever comes first, in
    /// either order relative to `wait()`.
    private final class FlightWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<Void, Error>?
        private var continuation: CheckedContinuation<Void, Error>?

        func resolve(_ result: Result<Void, Error>) {
            let pending: CheckedContinuation<Void, Error>? = lock.withLock {
                guard outcome == nil else { return nil }
                outcome = result
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
        }

        func wait() async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let ready: Result<Void, Error>? = lock.withLock {
                    if let outcome { return outcome }
                    continuation = c
                    return nil
                }
                if let ready { c.resume(with: ready) }
            }
        }
    }

    private struct Sample: Sendable {
        let fraction: Double
        let phase: ModelProgress.Phase
    }

    private func record(_ sample: Sample, flight id: Int) {
        guard id == flightID, case .downloading(let previous) = state else { return }
        publish(.downloading(ModelProgress.fold(previous, fraction: sample.fraction, phase: sample.phase)))
    }

    private func finish(flight id: Int, error: Error?) {
        guard id == flightID else { return }
        flight = nil
        publish(error.map { .failed(Self.classify($0)) } ?? .present)
    }

    // MARK: - State

    private func refreshIfIdle() {
        guard flight == nil else { return }
        if case .failed = state { return }
        publish(downloader.isPresent() ? .present : .absent)
    }

    private func publish(_ new: State) {
        guard new != state else { return }
        state = new
        for continuation in subscribers.values { continuation.yield(new) }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    // MARK: - Classification

    /// Connectivity problems are `.offline` (the view offers "Reintentar" with
    /// a connection hint); anything else keeps its description.
    static func classify(_ error: Error) -> Failure {
        if isOffline(error) { return .offline }
        return .other((error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }

    private static let offlineCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
        NSURLErrorTimedOut, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff,
    ]

    private static func isOffline(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 8 {
            if e.domain == NSURLErrorDomain, offlineCodes.contains(e.code) { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}
