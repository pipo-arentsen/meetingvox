import Foundation
import Testing
@testable import MeetingVox

// MARK: - Defaults

@Suite struct ConfigValuesTests {
    @Test func defaultsForNewKeys() {
        let v = ConfigValues(raw: [:])
        #expect(v.minutesEnabled == false)
        #expect(v.minutesTemplate == "general")
        #expect(v.minutesLanguage == "español")
        #expect(v.summaryEnabled == true)
        #expect(v.openRouterModel == nil)
        #expect(v.denyDataCollection == true)
        #expect(v.glossary == [])
        // Existing defaults unchanged.
        #expect(v.transcriptionEnabled == true)
        #expect(v.micVoiceProcessing == false)
        #expect(v.recordingsDir == nil)
    }

    @Test func blankStringsFallBackToDefaults() {
        let v = ConfigValues(raw: [
            "minutes": ["template": "  ", "language": ""],
            "openrouter": ["model": " "],
        ])
        #expect(v.minutesTemplate == "general")
        #expect(v.minutesLanguage == "español")
        #expect(v.openRouterModel == nil)
    }

    @Test func summaryEnabledCanBeTurnedOff() {
        let v = ConfigValues(raw: ["summary": ["enabled": false]])
        #expect(v.summaryEnabled == false)
    }

    @Test func glossaryDropsBlankAndNonStringEntries() {
        let v = ConfigValues(raw: ["glossary": [" Grafana ", "", 3, "k8s"]])
        #expect(v.glossary.map(\.term) == ["Grafana", "k8s"])
    }
}

// MARK: - Store

@Suite final class ConfigStoreTests {
    let root: URL
    let url: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-config-\(UUID().uuidString)", isDirectory: true)
        url = root.appendingPathComponent("nested/config.json")
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeRaw(_ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func readRaw() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func createsFileAndDirectoryWhenMissing() throws {
        try ConfigStore.set(true, at: "minutes", "enabled", url: url)
        let json = try readRaw()
        #expect((json["minutes"] as? [String: Any])?["enabled"] as? Bool == true)
        #expect(ConfigValues(raw: json).minutesEnabled)
    }

    @Test func preservesUnknownTopLevelAndNestedKeys() throws {
        try writeRaw("""
        {
          "on_stop": "hook",
          "future_key": {"a": [1, 2]},
          "transcription": {"enabled": true, "engine": "parakeet", "beam": 4}
        }
        """)
        try ConfigStore.set(false, at: "transcription", "enabled", url: url)

        let json = try readRaw()
        #expect(json["on_stop"] as? String == "hook")
        #expect((json["future_key"] as? [String: Any])?["a"] as? [Int] == [1, 2])
        let t = try #require(json["transcription"] as? [String: Any])
        #expect(t["enabled"] as? Bool == false)
        #expect(t["engine"] as? String == "parakeet")
        #expect(t["beam"] as? Int == 4)
    }

    @Test func refusesToOverwriteInvalidJSON() throws {
        let broken = "{ \"recordings_dir\": \"~/R\", oops"
        try writeRaw(broken)
        #expect(throws: ConfigStore.StoreError.self) {
            try ConfigStore.set(true, at: "minutes", "enabled", url: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == broken)
    }

    @Test func writesThroughSymlinkedConfig() throws {
        // stow/chezmoi layout: config.json is a symlink into a dotfiles repo.
        let real = root.appendingPathComponent("dotfiles/config.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"on_stop\": \"hook\"}".utf8).write(to: real)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: real)

        try ConfigStore.set(true, at: "minutes", "enabled", url: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? [String: Any])
        #expect(json["on_stop"] as? String == "hook")
        #expect(ConfigValues(raw: json).minutesEnabled)
    }

    @Test func emptyOrWhitespaceFileIsEmptyConfig() throws {
        try writeRaw("")
        #expect(try ConfigStore.loadRaw(at: url).isEmpty)
        try writeRaw("  \n\t")
        #expect(try ConfigStore.loadRaw(at: url).isEmpty)
        try ConfigStore.set(true, at: "minutes", "enabled", url: url)
        #expect(ConfigValues(raw: try readRaw()).minutesEnabled)
    }

    @Test func unreadableFileIsReadFailureNotInvalidJSON() throws {
        // A directory where the file should be: exists, but can't be read.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            _ = try ConfigStore.loadRaw(at: url)
            Issue.record("expected readFailed")
        } catch ConfigStore.StoreError.readFailed {
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func nilRemovesKey() throws {
        try ConfigStore.set("openai/gpt-4o-mini", at: "openrouter", "model", url: url)
        try ConfigStore.set(nil, at: "openrouter", "model", url: url)
        #expect(ConfigValues(raw: try readRaw()).openRouterModel == nil)
    }

    @Test func glossaryRoundTrip() throws {
        let terms = ["Grafana", "Kubernetes", "ñandú"]
        try ConfigStore.set(terms, at: "glossary", url: url)
        #expect(ConfigValues(raw: try ConfigStore.loadRaw(at: url)).glossary.map(\.term) == terms)
    }

    @Test func writesSortedPrettyJSON() throws {
        try ConfigStore.update(at: url) { json in
            json["b"] = 1
            json["a"] = 2
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "{\n  \"a\" : 2,\n  \"b\" : 1\n}\n")
    }

    @Test func abbreviatesHome() {
        #expect(ConfigStore.abbreviatingHome("/Users/me/Recordings", home: "/Users/me") == "~/Recordings")
        #expect(ConfigStore.abbreviatingHome("/Users/me", home: "/Users/me/") == "~")
        #expect(ConfigStore.abbreviatingHome("/Users/meh/x", home: "/Users/me") == "/Users/meh/x")
        #expect(ConfigStore.abbreviatingHome("/Volumes/Data/R", home: "/Users/me") == "/Volumes/Data/R")
    }
}
