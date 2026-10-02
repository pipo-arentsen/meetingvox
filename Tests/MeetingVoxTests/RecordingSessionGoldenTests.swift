@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import MeetingVox

private final class GoldenMic: MicRecording, @unchecked Sendable {
    var diagBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onUnavailable: (@Sendable (Error) -> Void)?
    private(set) var isRecording = false
    let firstBufferAt: Date? = nil

    func start(writingTo url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        isRecording = true
    }

    func stop() { isRecording = false }
}

private final class GoldenSystem: TrackRecording, @unchecked Sendable {
    private(set) var isRecording = false
    let firstBufferAt: Date? = nil

    func start(writingTo url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        isRecording = true
    }

    func stop() { isRecording = false }
}

/// Pins the exact bytes `RecordingSession.stop()` writes to meta.json when no
/// calendar event is involved: the
/// calendar link is added later by a follow-up and `stop()` never writes it,
/// so a recording without an event stays byte-identical to a build without
/// the feature. Only the wall-clock values are masked.
@Suite struct RecordingSessionGoldenTests {
    private func stoppedMeta(app: String? = nil, template: String? = nil) throws -> (text: String, dir: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-golden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = try RecordingSession(root: root, mic: GoldenMic(), system: GoldenSystem(), notify: { _, _ in })
        session.meetingApp = app
        session.minutesTemplate = template
        try session.start()
        session.stop()
        let data = try Data(contentsOf: session.dir.appendingPathComponent("meta.json"))
        var text = try #require(String(data: data, encoding: .utf8))
        let stamp = try Regex(#""(\d{4}-\d{2}-\d{2}T[\d:]+Z)""#)
        text = text.replacing(stamp) { _ in "\"<date>\"" }
        return (text, session.dir)
    }

    @Test func plainRecordingMetaBytesAreUnchanged() throws {
        let (text, _) = try stoppedMeta()
        let expected = """
            {
              "duration_seconds" : 0,
              "ended" : "<date>",
              "files" : {
                "mic" : "mic.caf",
                "system" : "system.caf"
              },
              "start_offset_ms" : {
                "mic" : 0,
                "system" : 0
              },
              "started" : "<date>"
            }
            """
        #expect(text == expected)
    }

    @Test func stopNeverWritesACalendarEvent() throws {
        let (text, _) = try stoppedMeta(app: "zoom", template: "general")
        #expect(!text.contains("calendar_event"))
        #expect(text.contains("\"meeting_app\" : \"zoom\""))
        #expect(text.contains("\"minutes_template\" : \"general\""))
    }
}
