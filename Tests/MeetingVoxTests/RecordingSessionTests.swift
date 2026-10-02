@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import MeetingVox

/// A track recorder that either throws on start or writes an empty file.
private final class FakeTrack: MicRecording, @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    var diagBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onUnavailable: (@Sendable (Error) -> Void)?
    private(set) var isRecording = false
    private(set) var firstBufferAt: Date?
    private(set) var stopped = false
    let startError: Error?
    let firstBuffer: Date?

    init(startError: Error? = nil, firstBuffer: Date? = nil) {
        self.startError = startError
        self.firstBuffer = firstBuffer
    }

    func start(writingTo url: URL) throws {
        if let startError { throw startError }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        isRecording = true
        firstBufferAt = firstBuffer
    }

    func stop() {
        isRecording = false
        stopped = true
    }
}

/// A system track that reports whether its tap excludes this process.
private final class FakeExcludingTrack: TrackRecording, SelfExcludingTap, @unchecked Sendable {
    private(set) var isRecording = false
    let firstBufferAt: Date? = Date()
    let excludesSelf: Bool
    let startsOK: Bool

    init(excludesSelf: Bool, startsOK: Bool = true) {
        self.excludesSelf = excludesSelf
        self.startsOK = startsOK
    }

    func start(writingTo url: URL) throws {
        if !startsOK { throw FakeTrack.Failure(description: "tap") }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        isRecording = true
    }

    func stop() { isRecording = false }
}

private final class Notifications: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, String)] = []
    var all: [(String, String)] { lock.lock(); defer { lock.unlock() }; return items }
    func add(_ title: String, _ body: String) { lock.lock(); items.append((title, body)); lock.unlock() }
}

@Suite struct RecordingSessionTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func meta(_ dir: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func micFailureRecordsSystemOnly() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = Notifications()
        let mic = FakeTrack(startError: FakeTrack.Failure(description: "sin permiso"))
        let system = FakeTrack(firstBuffer: Date())
        let session = try RecordingSession(root: root, mic: mic, system: system,
                                           notify: { notes.add($0, $1) })

        try session.start()
        #expect(system.isRecording)
        #expect(notes.all.count == 1)
        #expect(notes.all.first?.0 == Textos.Notificacion.sinMicrofono)
        #expect(notes.all.first?.1 == "sin permiso")

        session.stop()
        #expect(system.stopped)
        let json = try meta(session.dir)
        #expect(json["files"] as? [String: String] == ["system": "system.caf"])
        #expect(json["start_offset_ms"] as? [String: Int] == ["system": 0])
    }

    @Test func lateMicLossNotifiesOnceAndDropsTheTrack() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = Notifications()
        let mic = FakeTrack()
        let system = FakeTrack(firstBuffer: Date())
        let session = try RecordingSession(root: root, mic: mic, system: system,
                                           notify: { notes.add($0, $1) })
        try session.start()
        #expect(notes.all.isEmpty)

        // Permission prompt answered "no" after start: no mic.caf is left.
        try FileManager.default.removeItem(at: session.dir.appendingPathComponent("mic.caf"))
        mic.onUnavailable?(FakeTrack.Failure(description: "denegado"))
        mic.onUnavailable?(FakeTrack.Failure(description: "denegado"))
        #expect(notes.all.count == 1)
        #expect(notes.all.first?.0 == Textos.Notificacion.sinMicrofono)

        session.stop()
        #expect(try meta(session.dir)["files"] as? [String: String] == ["system": "system.caf"])
    }

    @Test func systemFailureRecordsMicOnly() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = Notifications()
        let mic = FakeTrack(firstBuffer: Date())
        let system = FakeTrack(startError: FakeTrack.Failure(description: "tap"))
        let session = try RecordingSession(root: root, mic: mic, system: system,
                                           notify: { notes.add($0, $1) })
        try session.start()
        #expect(mic.isRecording)
        #expect(notes.all.map(\.0) == [Textos.Notificacion.sinAudioSistema])
        session.stop()
        #expect(try meta(session.dir)["files"] as? [String: String] == ["mic": "mic.caf"])
    }

    @Test func bothFailingFailsTheSession() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeTrack(startError: FakeTrack.Failure(description: "mic"))
        let system = FakeTrack(startError: FakeTrack.Failure(description: "tap"))
        let session = try RecordingSession(root: root, mic: mic, system: system, notify: { _, _ in })
        #expect(throws: RecordingSession.StartError.self) { try session.start() }
    }

    @Test func bothTracksKeepOffsetsFromFirstBuffers() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let t0 = Date()
        let mic = FakeTrack(firstBuffer: t0.addingTimeInterval(0.3))
        let system = FakeTrack(firstBuffer: t0)
        let session = try RecordingSession(root: root, mic: mic, system: system, notify: { _, _ in })
        try session.start()
        session.stop()
        let json = try meta(session.dir)
        #expect(json["files"] as? [String: String] == ["mic": "mic.caf", "system": "system.caf"])
        #expect(json["start_offset_ms"] as? [String: Int] == ["mic": 300, "system": 0])
    }

    @Test func minutesTemplateIsAbsentUnlessChosen() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, mic: FakeTrack(), system: FakeTrack(), notify: { _, _ in })
        try session.start()
        session.stop()
        #expect(try meta(session.dir)["minutes_template"] == nil)
        #expect(SessionFiles.chosenMinutesTemplate(in: session.dir) == nil)
    }

    @Test func minutesTemplateChosenWhileRecordingIsWrittenAtStop() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, mic: FakeTrack(), system: FakeTrack(), notify: { _, _ in })
        session.minutesTemplate = "daily"   // from the meeting prompt
        try session.start()
        session.minutesTemplate = "comercial" // changed from the menu
        session.stop()
        #expect(try meta(session.dir)["minutes_template"] as? String == "comercial")
        #expect(SessionFiles.chosenMinutesTemplate(in: session.dir) == "comercial")
    }

    @Test func meetingAppIsAbsentForAManualRecording() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, mic: FakeTrack(), system: FakeTrack(), notify: { _, _ in })
        try session.start()
        session.stop()
        #expect(try meta(session.dir)["meeting_app"] == nil)
    }

    @Test func meetingAppFromThePromptIsWrittenAtStop() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, mic: FakeTrack(), system: FakeTrack(), notify: { _, _ in })
        session.meetingApp = "teams"
        try session.start()
        session.stop()
        #expect(try meta(session.dir)["meeting_app"] as? String == "teams")
    }

    @Test func exposesWhetherTheSystemTapExcludesThisProcess() throws {
        for flag in [true, false] {
            let root = try tempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let session = try RecordingSession(root: root, mic: FakeTrack(firstBuffer: Date()),
                                               system: FakeExcludingTrack(excludesSelf: flag), notify: { _, _ in })
            #expect(session.systemTapExcludesSelf == false)   // nothing started yet
            try session.start()
            #expect(session.systemTapExcludesSelf == flag)
            session.stop()
        }
    }

    @Test func aSystemTrackThatFailedNeverExcludesSelf() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, mic: FakeTrack(firstBuffer: Date()),
                                           system: FakeExcludingTrack(excludesSelf: true, startsOK: false),
                                           notify: { _, _ in })
        try session.start()
        #expect(session.systemTapExcludesSelf == false)
    }

    @Test func aSystemTrackWithoutTheProtocolNeverExcludesSelf() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, mic: FakeTrack(firstBuffer: Date()),
                                           system: FakeTrack(firstBuffer: Date()), notify: { _, _ in })
        try session.start()
        #expect(session.systemTapExcludesSelf == false)
    }
}
