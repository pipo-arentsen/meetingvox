import Foundation
import Testing
@testable import MeetingVox

/// Asserts the engine identifies itself as Parakeet Ultra. v3 drifted into
/// inventing English words on real Spanish meetings; Ultra removed that in
/// spike testing at no speed cost, so the engine must never silently revert
/// to v3 (or the wrong model id would go into `transcript.json` /
/// `hindsight.json`'s `motor_transcripcion`/`modelo_transcripcion`).
@Suite struct ParakeetEngineTests {
    @Test func identifiesAsParakeetUltra() {
        let engine = ParakeetEngine()
        #expect(engine.name == "parakeet")
        #expect(engine.model == "parakeet-ultra-coreml")
    }

    /// `prepare()` goes through the shared provisioner, so onboarding and the
    /// transcription queue never download twice. The fake downloader is held
    /// on a gate until both engines have joined the flight, then fails on
    /// purpose: the engines must surface that error and never reach the model
    /// load (nothing here can touch the network or load weights).
    @Test func prepareDownloadsThroughTheSharedProvisionerOnce() async {
        let gate = PrepareGate()
        let downloader = GatedFailingDownloader(gate: gate)
        let provisioner = ModelProvisioner(downloader: downloader)
        let a = Task { try await ParakeetEngine(provisioner: provisioner).prepare() }
        let b = Task { try await ParakeetEngine(provisioner: provisioner).prepare() }
        var joined = false
        for _ in 0..<2000 where !joined {
            joined = await provisioner.inFlightCallers == 2
            if !joined { await Task.yield() }
        }
        #expect(joined)
        await gate.release()
        var failures = 0
        do { try await a.value } catch { failures += 1 }
        do { try await b.value } catch { failures += 1 }
        #expect(failures == 2)
        #expect(downloader.callCount == 1)
        #expect(await provisioner.currentState() == .failed(.other("no network in tests")))
    }
}

private actor PrepareGate {
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

/// Fails every download with a fixed error once its gate opens; counts the calls.
private final class GatedFailingDownloader: ModelDownloader, @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible { var description: String { "no network in tests" } }
    let directory = URL(fileURLWithPath: "/nonexistent/parakeet-test")
    private let gate: PrepareGate
    private let lock = NSLock()
    private var calls = 0
    init(gate: PrepareGate) { self.gate = gate }
    var callCount: Int { lock.withLock { calls } }
    func isPresent() -> Bool { false }
    func download(progress: @escaping @Sendable (Double, ModelProgress.Phase) -> Void) async throws {
        lock.withLock { calls += 1 }
        await gate.wait()
        throw Failure()
    }
}
