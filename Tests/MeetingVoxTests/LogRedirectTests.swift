import Darwin
import Foundation
import Testing

@testable import MeetingVox

/// A bundled app has no terminal, so its stderr would vanish. It is
/// redirected to `~/Library/Logs/MeetingVox/meetingvox.log` only for a
/// bundled `run` whose stderr is not already a terminal; the CLI, `diag` and
/// tests keep theirs.
@Suite("LogRedirect")
struct LogRedirectTests {
    @Test func redirectsOnlyForABundledRunWithoutATerminal() {
        #expect(LogRedirect.shouldRedirect(isBundled: true, isRunRoute: true, stderrIsTTY: false))
        #expect(!LogRedirect.shouldRedirect(isBundled: false, isRunRoute: true, stderrIsTTY: false))
        #expect(!LogRedirect.shouldRedirect(isBundled: true, isRunRoute: false, stderrIsTTY: false))
        #expect(!LogRedirect.shouldRedirect(isBundled: true, isRunRoute: true, stderrIsTTY: true))
        #expect(!LogRedirect.shouldRedirect(isBundled: false, isRunRoute: false, stderrIsTTY: true))
    }

    @Test func aBundleURLIsRecognizedByItsAppExtension() {
        #expect(LogRedirect.isBundled(bundleURL: URL(fileURLWithPath: "/Applications/MeetingVox.app")))
        #expect(LogRedirect.isBundled(bundleURL: URL(fileURLWithPath: "/Applications/MeetingVox.app/", isDirectory: true)))
        #expect(!LogRedirect.isBundled(bundleURL: URL(fileURLWithPath: "/Users/x/quill/.build/release", isDirectory: true)))
        #expect(!LogRedirect.isBundled(bundleURL: URL(fileURLWithPath: "/usr/local/bin")))
    }

    // MARK: - rotation

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aLogOverTheLimitMovesToDotOne() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("meetingvox.log")
        try Data(repeating: 0x41, count: 11).write(to: log)

        let rotated = LogRedirect.rotateIfNeeded(logFile: log, maxBytes: 10)

        #expect(rotated)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        let old = dir.appendingPathComponent("meetingvox.log.1")
        #expect(try Data(contentsOf: old) == Data(repeating: 0x41, count: 11))
    }

    @Test func aLogAtOrUnderTheLimitIsLeftAlone() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("meetingvox.log")
        try Data(repeating: 0x42, count: 10).write(to: log)

        #expect(!LogRedirect.rotateIfNeeded(logFile: log, maxBytes: 10))
        #expect(try Data(contentsOf: log) == Data(repeating: 0x42, count: 10))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("meetingvox.log.1").path))
    }

    @Test func rotationReplacesThePreviousDotOne() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("meetingvox.log")
        let old = dir.appendingPathComponent("meetingvox.log.1")
        try Data("stale".utf8).write(to: old)
        try Data(repeating: 0x43, count: 20).write(to: log)

        #expect(LogRedirect.rotateIfNeeded(logFile: log, maxBytes: 10))

        #expect(try Data(contentsOf: old) == Data(repeating: 0x43, count: 20))
    }

    @Test func aMissingLogIsNotRotated() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!LogRedirect.rotateIfNeeded(logFile: dir.appendingPathComponent("meetingvox.log"), maxBytes: 10))
    }

    @Test func theProductionLimitIsTenMegabytes() {
        #expect(LogRedirect.maxBytes == 10 * 1024 * 1024)
    }

    // MARK: - redirect (stand-in descriptors, never the real stderr)

    private func standIn(in dir: URL, _ name: String) throws -> (fd: Int32, url: URL) {
        let url = dir.appendingPathComponent(name)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        try #require(fd >= 0)
        return (fd, url)
    }

    private func write(_ text: String, to fd: Int32) {
        _ = text.withCString { Darwin.write(fd, $0, strlen($0)) }
    }

    @Test func redirectAppendsToTheLogOntoEveryDescriptor() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try standIn(in: dir, "a.txt"), b = try standIn(in: dir, "b.txt")
        defer { close(a.fd); close(b.fd) }
        let log = dir.appendingPathComponent("meetingvox.log")
        try Data("old\n".utf8).write(to: log)

        #expect(LogRedirect.redirect(to: log, onto: [a.fd, b.fd]))
        write("from-a\n", to: a.fd)
        write("from-b\n", to: b.fd)

        #expect(try String(contentsOf: log, encoding: .utf8) == "old\nfrom-a\nfrom-b\n")
        #expect(try String(contentsOf: a.url, encoding: .utf8) == "")
    }

    @Test func aFailedOpenLeavesTheOriginalDescriptorsWorking() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try standIn(in: dir, "a.txt")
        defer { close(a.fd) }
        let unwritable = dir.appendingPathComponent("no-such-dir", isDirectory: true).appendingPathComponent("x.log")

        #expect(!LogRedirect.redirect(to: unwritable, onto: [a.fd]))

        write("still-here\n", to: a.fd)
        #expect(try String(contentsOf: a.url, encoding: .utf8) == "still-here\n")
    }

    @Test func aBadTargetDescriptorLeavesTheOthersUntouched() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try standIn(in: dir, "a.txt")
        defer { close(a.fd) }
        let log = dir.appendingPathComponent("meetingvox.log")

        #expect(!LogRedirect.redirect(to: log, onto: [a.fd, -1]))

        write("untouched\n", to: a.fd)
        #expect(try String(contentsOf: a.url, encoding: .utf8) == "untouched\n")
        #expect(((try? String(contentsOf: log, encoding: .utf8)) ?? "") == "")
    }

    @Test func rotateAndReattachMovesTheOldLogAndKeepsWritingToANewOne() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try standIn(in: dir, "a.txt")
        defer { close(a.fd) }
        let log = dir.appendingPathComponent("meetingvox.log")
        #expect(LogRedirect.redirect(to: log, onto: [a.fd]))
        write("0123456789-old\n", to: a.fd)

        #expect(LogRedirect.rotateAndReattach(logFile: log, maxBytes: 10, onto: [a.fd]))
        write("new\n", to: a.fd)

        #expect(try String(contentsOf: dir.appendingPathComponent("meetingvox.log.1"), encoding: .utf8) == "0123456789-old\n")
        #expect(try String(contentsOf: log, encoding: .utf8) == "new\n")
    }

    @Test func rotateAndReattachDoesNothingUnderTheLimit() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try standIn(in: dir, "a.txt")
        defer { close(a.fd) }
        let log = dir.appendingPathComponent("meetingvox.log")
        #expect(LogRedirect.redirect(to: log, onto: [a.fd]))
        write("small\n", to: a.fd)

        #expect(!LogRedirect.rotateAndReattach(logFile: log, maxBytes: 100, onto: [a.fd]))
        write("more\n", to: a.fd)

        #expect(try String(contentsOf: log, encoding: .utf8) == "small\nmore\n")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("meetingvox.log.1").path))
    }

    @Test func aLongLivedProcessIsCheckedHourly() {
        #expect(LogRedirect.checkInterval == 3600)
    }
}
