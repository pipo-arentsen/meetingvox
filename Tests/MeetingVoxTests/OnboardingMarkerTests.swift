import Foundation
import Testing

@testable import MeetingVox

/// The marker lives in a temp directory here; the real config dir is never
/// touched.
@Suite("OnboardingMarker")
struct OnboardingMarkerTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(AppIdentity.tempPrefix)onboarding-marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func object(at url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: Location

    @Test func theMarkerIsOnboardingJSONInTheConfigDir() {
        let home = URL(fileURLWithPath: "/h", isDirectory: true)
        #expect(AppIdentity.onboardingMarkerFile(home: home).path == "/h/.config/meetingvox/onboarding.json")
        #expect(AppIdentity.onboardingMarkerFile(home: URL(fileURLWithPath: "/other", isDirectory: true)).path
            == "/other/.config/meetingvox/onboarding.json")
    }

    // MARK: Read

    @Test func aMissingFileIsMissing() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(OnboardingMarker.read(at: dir.appendingPathComponent("onboarding.json")) == .missing)
    }

    @Test func aValidFileReportsItsVersion() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("onboarding.json")
        try Data(#"{"version": 3, "completed_at": "2026-09-29T10:00:00Z"}"#.utf8).write(to: url)
        #expect(OnboardingMarker.read(at: url) == .valid(version: 3))
        try Data(#"{"version": 1}"#.utf8).write(to: url)
        #expect(OnboardingMarker.read(at: url) == .valid(version: 1))
    }

    @Test func unreadableContentsAreMalformed() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("onboarding.json")
        let bad = [
            "not json {",
            "[1, 2]",
            "{}",
            #"{"version": "1"}"#,
            #"{"version": 1.5}"#,
            #"{"version": true}"#,
            #"{"version": null}"#,
            "",
        ]
        for text in bad {
            try Data(text.utf8).write(to: url)
            #expect(OnboardingMarker.read(at: url) == .malformed, "input: \(text)")
        }
    }

    // MARK: Write

    @Test func writeThenReadRoundTripsTheVersion() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("onboarding.json")
        try OnboardingMarker.write(version: 1, at: url, now: Date(timeIntervalSince1970: 0))
        #expect(OnboardingMarker.read(at: url) == .valid(version: 1))
        try OnboardingMarker.write(version: 2, at: url, now: Date(timeIntervalSince1970: 0))
        #expect(OnboardingMarker.read(at: url) == .valid(version: 2))
    }

    @Test func writeRecordsCompletionTimeAsISO8601() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("onboarding.json")
        try OnboardingMarker.write(version: 1, at: url, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try object(at: url)["completed_at"] as? String == "2027-01-15T08:00:00Z")
    }

    @Test func writeCreatesMissingParentDirectories() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/config/onboarding.json")
        try OnboardingMarker.write(version: 1, at: url, now: Date())
        #expect(OnboardingMarker.read(at: url) == .valid(version: 1))
    }

    @Test func writePreservesUnknownKeys() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("onboarding.json")
        try Data(#"{"version": 0, "zeta": {"a": [1, 2]}, "alpha": "keep"}"#.utf8).write(to: url)
        try OnboardingMarker.write(version: 1, at: url, now: Date(timeIntervalSince1970: 0))
        let written = try object(at: url)
        #expect(written["version"] as? Int == 1)
        #expect(written["alpha"] as? String == "keep")
        #expect((written["zeta"] as? [String: Any])?["a"] as? [Int] == [1, 2])
    }

    @Test func writeReplacesAMalformedFileInsteadOfRefusing() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("onboarding.json")
        try Data("garbage".utf8).write(to: url)
        try OnboardingMarker.write(version: 1, at: url, now: Date(timeIntervalSince1970: 0))
        #expect(OnboardingMarker.read(at: url) == .valid(version: 1))
    }

    @Test func writeIsSortedAndAtomicLeavingNoTempFiles() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("onboarding.json")
        try Data(#"{"zeta": 1}"#.utf8).write(to: url)
        try OnboardingMarker.write(version: 1, at: url, now: Date(timeIntervalSince1970: 0))
        let text = try String(contentsOf: url, encoding: .utf8)
        let completed = try #require(text.range(of: "completed_at"))
        let version = try #require(text.range(of: "\"version\""))
        let zeta = try #require(text.range(of: "zeta"))
        #expect(completed.lowerBound < version.lowerBound)
        #expect(version.lowerBound < zeta.lowerBound)
        #expect(text.hasSuffix("\n"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["onboarding.json"])
    }

    @Test func writeThroughASymlinkKeepsTheLinkAndUpdatesTheTarget() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.json")
        let link = dir.appendingPathComponent("onboarding.json")
        try Data(#"{"version": 0}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try OnboardingMarker.write(version: 1, at: link, now: Date(timeIntervalSince1970: 0))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path)
        #expect(OnboardingMarker.read(at: target) == .valid(version: 1))
    }

    // MARK: Failure paths

    @Test func writeIntoAnUnwritableParentThrowsAndLeavesNothingBehind() throws {
        let dir = try makeDir()
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = locked.appendingPathComponent("onboarding.json")
        #expect(throws: Error.self) {
            try OnboardingMarker.write(version: 1, at: url, now: Date())
        }
        #expect(OnboardingMarker.read(at: url) == .missing)
    }

    @Test func writeWhereTheParentIsAFileThrows() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notADirectory = dir.appendingPathComponent("config")
        try Data("x".utf8).write(to: notADirectory)
        let url = notADirectory.appendingPathComponent("onboarding.json")
        #expect(throws: Error.self) {
            try OnboardingMarker.write(version: 1, at: url, now: Date())
        }
    }

    @Test func aFileThatCannotBeReadReadsAsMissingNotMalformed() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A directory where the marker should be: present but unreadable.
        let asDirectory = dir.appendingPathComponent("onboarding.json", isDirectory: true)
        try FileManager.default.createDirectory(at: asDirectory, withIntermediateDirectories: true)
        #expect(OnboardingMarker.read(at: asDirectory) == .missing)
        // Contrast: readable garbage is malformed.
        let garbage = dir.appendingPathComponent("other.json")
        try Data("nope".utf8).write(to: garbage)
        #expect(OnboardingMarker.read(at: garbage) == .malformed)
    }
}
