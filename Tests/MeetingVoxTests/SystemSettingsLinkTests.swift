import Foundation
import Testing

@testable import MeetingVox

@Suite("SystemSettingsLink")
struct SystemSettingsLinkTests {
    private let panes: [SettingsPane] = [.microphone, .systemAudio, .notifications, .localNetwork]

    @Test func everyPaneHasCandidatesEndingAtThePrivacyRoot() {
        for pane in panes {
            let candidates = SystemSettingsLink.candidates(for: pane)
            #expect(!candidates.isEmpty)
            #expect(candidates.last == SystemSettingsLink.privacyRoot)
        }
    }

    @Test func thePrivacyPanesTargetTheirOwnAnchorFirst() {
        #expect(SystemSettingsLink.candidates(for: .microphone).first?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #expect(SystemSettingsLink.candidates(for: .localNetwork).first?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        #expect(SystemSettingsLink.candidates(for: .systemAudio).first?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
    }

    @Test func systemAudioFallsBackToScreenRecordingBeforeTheRoot() {
        let urls = SystemSettingsLink.candidates(for: .systemAudio).map(\.absoluteString)
        #expect(urls.count == 3)
        #expect(urls[1] == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @Test func notificationsPointAtTheAppByItsBundleID() {
        let first = SystemSettingsLink.candidates(for: .notifications).first?.absoluteString
        #expect(first == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(AppIdentity.bundleID)")
        let custom = SystemSettingsLink.candidates(for: .notifications, bundleID: "com.example.app").first?.absoluteString
        #expect(custom == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.example.app")
    }

    @Test func candidatesHaveNoDuplicates() {
        for pane in panes {
            let candidates = SystemSettingsLink.candidates(for: pane)
            #expect(Set(candidates).count == candidates.count)
        }
    }

    // MARK: - Sound input

    @Test func soundInputCandidatesGoFromTheInputTabToThePaneToTheLegacyPane() {
        let urls = SystemSettingsLink.soundInputCandidates.map(\.absoluteString)
        #expect(urls == [
            "x-apple.systempreferences:com.apple.Sound-Settings.extension?input",
            "x-apple.systempreferences:com.apple.Sound-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.sound",
        ])
        #expect(Set(urls).count == urls.count)
    }

    @Test func openSoundInputStopsAtTheFirstSuccess() {
        var tried: [URL] = []
        let opened = SystemSettingsLink.openSoundInput { url in
            tried.append(url)
            return tried.count == 2
        }
        #expect(tried == Array(SystemSettingsLink.soundInputCandidates.prefix(2)))
        #expect(opened == SystemSettingsLink.soundInputCandidates[1])
    }

    @Test func openSoundInputReturnsNilWhenNothingOpens() {
        #expect(SystemSettingsLink.openSoundInput { _ in false } == nil)
    }

    // MARK: - Opening

    @Test func openingStopsAtTheFirstURLThatOpens() {
        var tried: [URL] = []
        let opened = SystemSettingsLink.open(.microphone) { url in
            tried.append(url)
            return true
        }
        #expect(opened == SystemSettingsLink.candidates(for: .microphone).first)
        #expect(tried.count == 1)
    }

    @Test func openingFallsBackDownTheListUntilOneWorks() {
        let candidates = SystemSettingsLink.candidates(for: .systemAudio)
        var tried: [URL] = []
        let opened = SystemSettingsLink.open(.systemAudio) { url in
            tried.append(url)
            return url == SystemSettingsLink.privacyRoot
        }
        #expect(opened == SystemSettingsLink.privacyRoot)
        #expect(tried == candidates)
    }

    @Test func openingReportsNilWhenNothingOpens() {
        var count = 0
        let opened = SystemSettingsLink.open(.notifications) { _ in
            count += 1
            return false
        }
        #expect(opened == nil)
        #expect(count == SystemSettingsLink.candidates(for: .notifications).count)
    }
}
