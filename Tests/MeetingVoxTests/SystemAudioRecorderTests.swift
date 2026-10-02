import CoreAudio
import Foundation
import Testing
@testable import MeetingVox

/// Drives `SystemAudioRecorder.start` through its injected seams: no tap, no
/// aggregate device and no Core Audio call is made, so nothing here touches
/// the real audio system.
private final class Attempts: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private let lock = NSLock()
    private var calls: [[AudioObjectID]] = []
    private var logs: [String] = []
    /// Per call index (in order) whether that attempt throws.
    let failures: [Bool]

    init(failures: [Bool] = []) { self.failures = failures }

    var exclusions: [[AudioObjectID]] { lock.lock(); defer { lock.unlock() }; return calls }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return logs }

    func attempt(_ url: URL, _ exclusions: [AudioObjectID]) throws {
        lock.lock()
        let index = calls.count
        calls.append(exclusions)
        lock.unlock()
        if index < failures.count, failures[index] { throw Failure(description: "attempt \(index) failed") }
    }

    func log(_ line: String) { lock.lock(); logs.append(line); lock.unlock() }
}

@Suite struct SystemAudioRecorderTests {
    private let url = URL(fileURLWithPath: "/nonexistent/system.caf")

    private func recorder(own: AudioObjectID?, _ attempts: Attempts) -> SystemAudioRecorder {
        SystemAudioRecorder(ownProcessObject: { own }, attempt: attempts.attempt, log: attempts.log)
    }

    @Test func absentOwnObjectAttemptsOnceWithNoExclusion() throws {
        let attempts = Attempts()
        let rec = recorder(own: nil, attempts)
        try rec.start(writingTo: url)
        #expect(attempts.exclusions == [[]])
        #expect(rec.excludesSelf == false)
        #expect(rec.ownObject == nil)
        #expect(rec.isRecording)
        #expect(attempts.lines.count == 1)
    }

    @Test func presentOwnObjectExcludesItself() throws {
        let attempts = Attempts()
        let rec = recorder(own: 77, attempts)
        try rec.start(writingTo: url)
        #expect(attempts.exclusions == [[77]])
        #expect(rec.excludesSelf)
        #expect(rec.ownObject == 77)
        #expect(rec.isRecording)
        #expect(attempts.lines.count == 1)
        #expect(attempts.lines[0].contains("77"))
    }

    @Test func failedExclusionRetriesOnceWithoutItAndStillRecords() throws {
        let attempts = Attempts(failures: [true, false])
        let rec = recorder(own: 77, attempts)
        try rec.start(writingTo: url)
        #expect(attempts.exclusions == [[77], []])
        #expect(rec.excludesSelf == false)
        #expect(rec.isRecording)
        #expect(attempts.lines.count == 1)
        #expect(rec.firstBufferAt == nil)
    }

    @Test func failureOfBothAttemptsPropagatesAsToday() {
        let attempts = Attempts(failures: [true, true])
        let rec = recorder(own: 77, attempts)
        #expect(throws: Attempts.Failure.self) { try rec.start(writingTo: url) }
        #expect(attempts.exclusions == [[77], []])
        #expect(rec.isRecording == false)
        #expect(rec.excludesSelf == false)
    }

    @Test func failureWithoutOwnObjectPropagatesAfterASingleAttempt() {
        let attempts = Attempts(failures: [true])
        let rec = recorder(own: nil, attempts)
        #expect(throws: Attempts.Failure.self) { try rec.start(writingTo: url) }
        #expect(attempts.exclusions == [[]])
        #expect(rec.isRecording == false)
    }

    @Test func stopResetsTheFlag() throws {
        let attempts = Attempts()
        let rec = recorder(own: 5, attempts)
        try rec.start(writingTo: url)
        #expect(rec.excludesSelf)
        rec.stop()
        #expect(rec.excludesSelf == false)
        #expect(rec.isRecording == false)
    }

    @Test func secondStartWhileRecordingIsANoOp() throws {
        let attempts = Attempts()
        let rec = recorder(own: 5, attempts)
        try rec.start(writingTo: url)
        try rec.start(writingTo: url)
        #expect(attempts.exclusions == [[5]])
    }

    @Test func conformsToSelfExcludingTap() {
        let rec = recorder(own: nil, Attempts())
        #expect((rec as AnyObject) is SelfExcludingTap)
    }

    /// The real HAL translation, read-only: it only asks Core Audio which
    /// process object a PID maps to. A pid that cannot exist maps to nothing.
    @Test func translatingAnImpossiblePidGivesNil() {
        #expect(SystemAudioRecorder.processObject(for: pid_t(Int32.max)) == nil)
    }

    @Test func diagLinesHaveTheDocumentedShape() {
        #expect(Diag.ownObjectLine(42) == "own process object: found (42)")
        #expect(Diag.ownObjectLine(nil) == "own process object: absent")
        #expect(Diag.excludesSelfLine(true) == "excludesSelf: true")
        #expect(Diag.excludesSelfLine(false) == "excludesSelf: false")
    }
}
