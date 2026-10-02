import Foundation
import Testing

@testable import MeetingVox

/// The Local Network feedback loop, through the REAL pieces: the tracker, the
/// live probes and the model, joined by the same wiring the window uses
/// (`OnboardingLauncher.wire`). Only the outermost edges are fake: the probe
/// transport (counts calls, never touches the network) and the AV / UN / TCC
/// readers (nothing here prompts or reads the system).
///
/// Before the fix one click made every finished probe call `onChange` ->
/// `refreshStatuses` -> `snapshot` -> `refreshIfClicked` -> another probe,
/// forever (284 probes in 2 s in the verify harness).
@MainActor
@Suite("OnboardingProbeLoop")
struct OnboardingProbeLoopTests {
    private static let url = "http://192.168.1.10:8888"

    /// Counts probes. A runaway loop is capped: past `limit` the probe never
    /// answers, so a regression fails the count instead of spinning the run.
    private final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        private let limit = 300
        private let answer: LocalNetworkProbe.Result
        init(answer: LocalNetworkProbe.Result) { self.answer = answer }
        var count: Int { lock.withLock { n } }
        func probe(_ url: URL) async -> LocalNetworkProbe.Result {
            let over = lock.withLock { () -> Bool in n += 1; return n > limit }
            if over { try? await Task.sleep(for: .seconds(3600)) }
            return answer
        }
    }

    private struct NoTCC: TCCAccessing {
        func preflightAudioCapture() -> TCCAccessStatus? { .granted }
        func requestAudioCapture() async -> Bool? { true }
    }

    @MainActor
    private final class NoMinutes: OnboardingMinutesFacts {
        var isDone: Bool { false }
        func reload() {}
        func commit() {}
    }

    private func wire(_ transport: Transport) -> (LivePermissionProbes, OnboardingModel) {
        var parts = OnboardingLauncher.ProbeParts()
        parts.tcc = NoTCC()
        parts.localNetworkProbe = { await transport.probe($0) }
        parts.readMicrophone = { .authorized }
        parts.readNotifications = { .authorized }
        let raw: [String: Any] = ["hindsight": ["enabled": true, "base_url": Self.url]]
        return OnboardingLauncher.wire(
            recording: { false }, probeParts: parts, minutes: NoMinutes(),
            provisioner: ModelProvisioner(downloader: NeverDownloader()),
            config: { ConfigValues(raw: raw) },
            openPane: { _ in }, writeMarker: {}
        )
    }

    private struct NeverDownloader: ModelDownloader {
        let directory = URL(fileURLWithPath: "/nonexistent/onboarding-probe-loop")
        func isPresent() -> Bool { true }
        func download(progress: @escaping @Sendable (Double, ModelProgress.Phase) -> Void) async throws {}
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

    @Test func oneClickOnRedLocalProbesOnceAndSettles() async {
        let transport = Transport(answer: .reachable)
        let (_, model) = wire(transport)
        await model.windowDidBecomeKey()
        #expect(transport.count == 0, "looking never probes before the click")
        #expect(model.rows[.localNetwork]?.action == .allow)

        await model.perform(.localNetwork)  // the click
        await settle()

        #expect(model.rows[.localNetwork]?.status == .granted)
        #expect(transport.count >= 1)
        #expect(transport.count <= 2, "a click must not start a probe loop, saw \(transport.count)")
    }

    @Test func anUnreachableServerDoesNotLoopEither() async {
        let transport = Transport(answer: .unreachable)
        let (_, model) = wire(transport)
        await model.windowDidBecomeKey()

        await model.perform(.localNetwork)
        await settle()

        #expect(model.rows[.localNetwork]?.note == .serverUnreachable)
        #expect(transport.count <= 2, "saw \(transport.count)")
    }

    @Test func theWindowBecomingKeyAgainProbesOncePerKeyOnly() async {
        let transport = Transport(answer: .reachable)
        let (_, model) = wire(transport)
        await model.windowDidBecomeKey()
        await model.perform(.localNetwork)
        await settle()
        let afterClick = transport.count

        await model.windowDidBecomeKey()  // back from System Settings
        await settle()

        #expect(transport.count == afterClick + 1, "one re-probe for one key event, saw \(transport.count - afterClick)")
    }

    @Test func nothingProbesAfterTheWindowCloses() async {
        let transport = Transport(answer: .reachable)
        let (_, model) = wire(transport)
        await model.windowDidBecomeKey()
        await model.perform(.localNetwork)
        await settle()

        model.windowClosed()
        let atClose = transport.count
        model.localNetworkChanged()  // a late report from a probe that was in flight
        await settle()

        #expect(transport.count == atClose, "probes after close: \(transport.count - atClose)")
        #expect(atClose <= 2)
    }
}
