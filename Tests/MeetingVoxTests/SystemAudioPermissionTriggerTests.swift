import Foundation
import Testing

@testable import MeetingVox

/// The pre-trigger chain of the system-audio prompt, over fakes: nothing here
/// creates a tap or calls the TCC SPI.
@Suite("SystemAudioPermissionTrigger")
struct SystemAudioPermissionTriggerTests {
    private final class FakeTCC: TCCAccessing, @unchecked Sendable {
        private let lock = NSLock()
        private var preflights: [TCCAccessStatus?]
        private let requestAnswer: Bool?
        private(set) var events: [String] = []
        var onRequest: (@Sendable () -> Void)?

        init(preflights: [TCCAccessStatus?], requestAnswer: Bool? = true) {
            self.preflights = preflights
            self.requestAnswer = requestAnswer
        }

        func preflightAudioCapture() -> TCCAccessStatus? {
            lock.withLock {
                events.append("preflight")
                return preflights.count > 1 ? preflights.removeFirst() : preflights.first ?? nil
            }
        }

        func requestAudioCapture() async -> Bool? {
            lock.withLock { events.append("request") }
            onRequest?()
            return requestAnswer
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var isSet: Bool { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); value = newValue; lock.unlock() } }
    }

    private final class IO: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var runs: Int { lock.lock(); defer { lock.unlock() }; return count }
        func run() { lock.lock(); count += 1; lock.unlock() }
    }

    private func chain(_ tcc: FakeTCC, recording: Flag = Flag(false), io: IO = IO()) -> SystemAudioTriggerChain {
        SystemAudioTriggerChain(tcc: tcc, isRecording: { recording.isSet }, ioTrigger: { io.run() })
    }

    // MARK: - Refused while recording

    @Test func recordingRefusesAndTouchesNothing() async {
        let tcc = FakeTCC(preflights: [.unknown])
        let io = IO()
        let outcome = await chain(tcc, recording: Flag(true), io: io).trigger()
        #expect(outcome == .refusedWhileRecording)
        #expect(tcc.events.isEmpty)
        #expect(io.runs == 0)
    }

    @Test func aRecordingThatStartsDuringTheRequestStopsTheTapStep() async {
        let recording = Flag(false)
        let tcc = FakeTCC(preflights: [.unknown])
        tcc.onRequest = { recording.isSet = true }
        let io = IO()
        let outcome = await chain(tcc, recording: recording, io: io).trigger()
        #expect(outcome == .refusedWhileRecording)
        #expect(tcc.events == ["request", "preflight"])
        #expect(io.runs == 0)
    }

    // MARK: - SPI present

    @Test func aGrantedPreflightAfterTheRequestEndsTheChain() async {
        let tcc = FakeTCC(preflights: [.granted])
        let io = IO()
        let outcome = await chain(tcc, io: io).trigger()
        #expect(outcome == .granted)
        #expect(tcc.events == ["request", "preflight"])
        #expect(io.runs == 0)
    }

    @Test func aDeniedPreflightAfterTheRequestEndsTheChain() async {
        let tcc = FakeTCC(preflights: [.denied], requestAnswer: false)
        let io = IO()
        let outcome = await chain(tcc, io: io).trigger()
        #expect(outcome == .denied)
        #expect(io.runs == 0)
    }

    @Test func stillUnknownAfterTheRequestFallsBackToTheTapThenReadsAgain() async {
        let tcc = FakeTCC(preflights: [.unknown, .granted])
        let io = IO()
        let outcome = await chain(tcc, io: io).trigger()
        #expect(outcome == .granted)
        #expect(io.runs == 1)
        #expect(tcc.events == ["request", "preflight", "preflight"])
    }

    @Test func stillUnknownAfterTheTapIsSolicitado() async {
        let tcc = FakeTCC(preflights: [.unknown, .unknown])
        let io = IO()
        let outcome = await chain(tcc, io: io).trigger()
        #expect(outcome == .requested)
        #expect(io.runs == 1)
    }

    @Test func aDenialAfterTheTapIsReported() async {
        let tcc = FakeTCC(preflights: [.unknown, .denied])
        let outcome = await chain(tcc).trigger()
        #expect(outcome == .denied)
    }

    // MARK: - SPI absent

    @Test func withoutTheSPITheTapRunsAndTheOutcomeIsSolicitado() async {
        let tcc = FakeTCC(preflights: [nil], requestAnswer: nil)
        let io = IO()
        let outcome = await chain(tcc, io: io).trigger()
        #expect(outcome == .requested)
        #expect(io.runs == 1)
    }

    @Test func withoutTheSPIARecordingStillRefuses() async {
        let tcc = FakeTCC(preflights: [nil], requestAnswer: nil)
        let io = IO()
        let outcome = await chain(tcc, recording: Flag(true), io: io).trigger()
        #expect(outcome == .refusedWhileRecording)
        #expect(io.runs == 0)
    }

    // MARK: - Constants

    @Test func theTapRunsAboutThreeTenthsOfASecond() {
        #expect(PrivateTapPermissionPrimer.duration == 0.3)
    }

    // MARK: - Live adapters take the injected TCC

    @Test func theLiveTriggerUsesTheInjectedTCCAndTap() async {
        let tcc = FakeTCC(preflights: [.unknown, .granted])
        let io = IO()
        let outcome = await LiveSystemAudioPermissionTrigger(
            tcc: tcc, isRecording: { false }, ioTrigger: { io.run() }
        ).trigger()
        #expect(outcome == .granted)
        #expect(tcc.events == ["request", "preflight", "preflight"])
        #expect(io.runs == 1)
    }

    @Test func theLiveProbesHandTheirTCCToTheSystemAudioRow() async {
        let tcc = FakeTCC(preflights: [.granted])
        let io = IO()
        let probes = LivePermissionProbes(tcc: tcc, isRecording: { false }, systemAudioTap: { io.run() })
        await probes.request(.systemAudio, hindsight: nil)
        #expect(tcc.events == ["request", "preflight"])
        #expect(io.runs == 0)
    }

    @Test func theLiveProbesRefuseSystemAudioWhileRecording() async {
        let tcc = FakeTCC(preflights: [.unknown])
        let io = IO()
        let probes = LivePermissionProbes(tcc: tcc, isRecording: { true }, systemAudioTap: { io.run() })
        await probes.request(.systemAudio, hindsight: nil)
        #expect(tcc.events.isEmpty)
        #expect(io.runs == 0)
    }
}
