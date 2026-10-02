import Foundation
import Testing
@testable import MeetingVox

private struct NoKeyStore: APIKeyStore {
    func hasAPIKey() -> Bool { false }
    func read() throws -> String? { nil }
    func save(_ secret: String) throws {}
    func delete() throws {}
}

private final class Posts: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

/// Ajustes → Reuniones: the recording pill and auto-stop toggles.
@MainActor
@Suite final class PillSettingsTests {
    let root: URL
    let url: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-pill-settings-\(UUID().uuidString)", isDirectory: true)
        url = root.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func model(_ json: String = "{}") throws -> SettingsModel {
        try Data(json.utf8).write(to: url)
        return SettingsModel(configURL: url, templatesDir: root, keychain: NoKeyStore())
    }

    private func values() throws -> ConfigValues { ConfigValues(raw: try ConfigStore.loadRaw(at: url)) }

    @Test func defaultsMatchConfigDefaults() throws {
        let model = try model()
        #expect(model.recordingPillEnabled)
        #expect(model.meetingAutoStop == false)
    }

    @Test func loadsFromDisk() throws {
        let model = try model(#"{"recording_pill": {"enabled": false}, "meeting_detection": {"auto_stop": true}}"#)
        #expect(model.recordingPillEnabled == false)
        #expect(model.meetingAutoStop)
    }

    @Test func recordingPillToggleWritesAndKeepsUnknownKeys() throws {
        let model = try model(#"{"recording_pill": {"future": 1}}"#)
        model.recordingPillEnabled = false
        let raw = try ConfigStore.loadRaw(at: url)
        #expect(ConfigValues(raw: raw).recordingPillEnabled == false)
        #expect((raw["recording_pill"] as? [String: Any])?["future"] as? Int == 1)
        model.recordingPillEnabled = true
        #expect(try values().recordingPillEnabled)
    }

    @Test func autoStopToggleWritesInsideMeetingDetection() throws {
        let model = try model(#"{"meeting_detection": {"ignored_apps": ["x"]}}"#)
        model.meetingAutoStop = true
        let v = try values()
        #expect(v.meetingDetectionAutoStop)
        #expect(v.meetingDetectionIgnoredApps == ["x"])
        model.meetingAutoStop = false
        #expect(try values().meetingDetectionAutoStop == false)
    }

    @Test func togglesPostConfigChange() throws {
        let model = try model()
        let posts = Posts()
        let observer = NotificationCenter.default.addObserver(
            forName: .meetingVoxConfigDidChange, object: nil, queue: nil) { _ in posts.bump() }
        defer { NotificationCenter.default.removeObserver(observer) }
        model.recordingPillEnabled = false
        #expect(posts.value == 1)
        model.meetingAutoStop = true
        #expect(posts.value == 2)
    }

    @Test func autoStopAvailabilityNeedsDetectionAndPromptOnEnd() throws {
        let model = try model()
        #expect(model.autoStopAvailable)
        model.meetingPromptOnEnd = false
        #expect(model.autoStopAvailable == false)
        model.meetingPromptOnEnd = true
        model.meetingDetectionEnabled = false
        #expect(model.autoStopAvailable == false)
        model.meetingDetectionEnabled = true
        #expect(model.autoStopAvailable)
    }

    @Test func malformedAutoStopIsNeverOverwritten() throws {
        let original = #"{"meeting_detection": {"auto_stop": "yes"}}"#
        let model = try model(original)
        #expect(model.meetingDetectionInvalid)
        #expect(model.configError?.contains("meeting_detection.auto_stop") == true)
        model.meetingAutoStop = true
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == original)
        #expect(model.meetingAutoStop == false)
    }

    @Test func malformedRecordingPillIsNeverOverwritten() throws {
        for original in [#"{"recording_pill": "off"}"#, #"{"recording_pill": {"enabled": 0}}"#] {
            let model = try model(original)
            #expect(model.recordingPillInvalid)
            #expect(model.configError?.contains("recording_pill") == true)
            #expect(model.recordingPillEnabled)  // read default stays on
            model.recordingPillEnabled = false
            #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == original)
            #expect(model.recordingPillEnabled)
        }
    }

    @Test func wellFormedRecordingPillIsNotInvalid() throws {
        #expect(try model(#"{"recording_pill": {"enabled": false}}"#).recordingPillInvalid == false)
        #expect(try model().recordingPillInvalid == false)
    }
}
