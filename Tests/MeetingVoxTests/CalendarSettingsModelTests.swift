import Foundation
import Testing

@testable import MeetingVox

/// A source whose access request stays pending until `release` runs, to see
/// the `requesting` state. Never EventKit.
private actor GatedCalendarSource: CalendarSource {
    private var continuation: CheckedContinuation<CalendarSystemStatus, Never>?
    private(set) var requestCount = 0
    private var current: CalendarSystemStatus = .notDetermined

    func status() async -> CalendarSystemStatus { current }

    func requestFullAccess() async -> CalendarSystemStatus {
        requestCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ answer: CalendarSystemStatus) {
        current = answer
        continuation?.resume(returning: answer)
        continuation = nil
    }

    func events(overlapping interval: DateInterval) async throws -> [CalendarEventSnapshot] { [] }
}

@MainActor
@Suite final class CalendarSettingsModelTests {
    let root: URL
    let url: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-calsettings-\(UUID().uuidString)", isDirectory: true)
        url = root.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String) throws { try Data(text.utf8).write(to: url) }

    private func readJSON() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func makeModel(
        _ source: any CalendarSource, opened: Box<[URL]>? = nil
    ) -> CalendarSettingsModel {
        CalendarSettingsModel(
            configURL: url, source: source, notifications: NotificationCenter(),
            openURL: { candidate in opened?.value.append(candidate); return true })
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: - Opt-in and the one request

    @Test func creatingTheModelAndRefreshingNeverRequests() async throws {
        let source = FakeCalendarSource(status: .notDetermined)
        let model = makeModel(source)
        await model.refresh()
        #expect(await source.requestCount == 0)
        #expect(model.access == .off)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func turningOnWithNotDeterminedWritesTheKeyAndRequestsOnce() async throws {
        let source = FakeCalendarSource(status: .notDetermined, answerToRequest: .authorized)
        let model = makeModel(source)
        await model.setEnabled(true)
        #expect(await source.requestCount == 1)
        #expect(model.access == .authorized)
        let calendar = try #require(readJSON()["calendar"] as? [String: Any])
        #expect(calendar["enabled"] as? Bool == true)
        // Off and on again: the system is no longer undetermined, so no second prompt.
        await model.setEnabled(false)
        await model.setEnabled(true)
        #expect(await source.requestCount == 1)
    }

    @Test func requestingShowsWhileThePromptIsOpenAndSettlesAfterTheAnswer() async throws {
        let source = GatedCalendarSource()
        let model = makeModel(source)
        let pending = Task { await model.setEnabled(true) }
        while await source.requestCount == 0 { await Task.yield() }
        #expect(model.access == .requesting)
        // A second click while the prompt is open must not ask again.
        await model.setEnabled(true)
        #expect(await source.requestCount == 1)
        await source.release(.denied)
        await pending.value
        #expect(model.access == .denied)
    }

    @Test func aDeniedAnswerKeepsTheToggleOnAndOffersTheLink() async throws {
        let source = FakeCalendarSource(status: .notDetermined, answerToRequest: .denied)
        let model = makeModel(source)
        await model.setEnabled(true)
        #expect(model.access == .denied)
        #expect(model.enabled)
        #expect(model.showsPrivacyLink)
        #expect(model.statusText != nil)
    }

    @Test func deniedAndRestrictedNeverPromptAndOfferTheLink() async throws {
        for system in [CalendarSystemStatus.denied, .restricted, .writeOnly] {
            let source = FakeCalendarSource(status: system)
            let model = makeModel(source)
            await model.setEnabled(true)
            #expect(await source.requestCount == 0, "\(system)")
            #expect(model.showsPrivacyLink, "\(system)")
            #expect(model.statusText != nil, "\(system)")
        }
        let restricted = makeModel(FakeCalendarSource(status: .restricted))
        await restricted.setEnabled(true)
        #expect(restricted.access == .restricted)
    }

    @Test func authorizedAndOffShowNoLink() async throws {
        let on = makeModel(FakeCalendarSource(status: .authorized))
        await on.setEnabled(true)
        #expect(on.access == .authorized)
        #expect(!on.showsPrivacyLink)
        await on.setEnabled(false)
        #expect(on.access == .off)
        #expect(!on.showsPrivacyLink)
        #expect(on.statusText == nil)
    }

    // MARK: - Off never revokes

    @Test func turningOffWritesFalseKeepsOtherKeysAndNeverRequests() async throws {
        try write(#"{"calendar":{"enabled":true,"extra":1},"minutes":{"enabled":true}}"#)
        let source = FakeCalendarSource(status: .authorized)
        let model = makeModel(source)
        await model.refresh()
        #expect(model.enabled)
        await model.setEnabled(false)
        #expect(await source.requestCount == 0)
        let json = try readJSON()
        let calendar = try #require(json["calendar"] as? [String: Any])
        #expect(calendar["enabled"] as? Bool == false)
        #expect(calendar["extra"] as? Int == 1)
        #expect((json["minutes"] as? [String: Any])?["enabled"] as? Bool == true)
        #expect(model.access == .off)
    }

    // MARK: - Privacy link

    @Test func theLinkOpensCalendarsThenFallsBackToThePrivacyRoot() async throws {
        let opened = Box<[URL]>([])
        let model = CalendarSettingsModel(
            configURL: url, source: FakeCalendarSource(status: .denied), notifications: NotificationCenter(),
            openURL: { candidate in opened.value.append(candidate); return candidate == SystemSettingsLink.privacyRoot })
        model.openPrivacySettings()
        #expect(opened.value.first?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        #expect(opened.value.last == SystemSettingsLink.privacyRoot)
    }

    // MARK: - Unavailable and malformed

    @Test func anUnavailableSourceShowsTheBundledOnlyNote() async throws {
        let model = makeModel(UnavailableCalendarSource())
        await model.setEnabled(true)
        #expect(model.access == .unavailable)
        #expect(!model.showsPrivacyLink)
        #expect(model.statusText != nil)
    }

    @Test func aMalformedCalendarSectionRefusesWrites() async throws {
        try write(#"{"calendar":"yes"}"#)
        let source = FakeCalendarSource(status: .notDetermined)
        let model = makeModel(source)
        await model.refresh()
        #expect(model.isInvalid)
        await model.setEnabled(true)
        #expect(await source.requestCount == 0)
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"calendar":"yes"}"#)
    }

    @Test func aGrantedAnswerLaterIsPickedUpByRefreshWithoutRetoggling() async throws {
        try write(#"{"calendar":{"enabled":true}}"#)
        let source = FakeCalendarSource(status: .denied)
        let model = makeModel(source)
        await model.refresh()
        #expect(model.access == .denied)
        let granted = makeModel(FakeCalendarSource(status: .authorized))
        await granted.refresh()
        #expect(granted.access == .authorized)
    }

    @Test func theConfigChangeNotificationFiresOnAWrite() async throws {
        let center = NotificationCenter()
        let seen = Box(0)
        let token = center.addObserver(forName: .meetingVoxConfigDidChange, object: nil, queue: nil) { _ in seen.value += 1 }
        defer { center.removeObserver(token) }
        let model = CalendarSettingsModel(
            configURL: url, source: FakeCalendarSource(status: .authorized), notifications: center, openURL: { _ in true })
        await model.setEnabled(true)
        #expect(seen.value == 1)
    }
}
