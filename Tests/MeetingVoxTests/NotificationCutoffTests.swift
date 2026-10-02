import Foundation
import Testing
@testable import MeetingVox

/// `~/.config/meetingvox/notificaciones.desde` keeps sessions recorded
/// before the notification rework silent for good.
@Suite struct NotificationCutoffTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-29T15:30:00Z")!

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-cutoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func read(_ file: URL) -> String? {
        (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func theFileLivesNextToTheConfig() {
        let home = URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        #expect(AppIdentity.notificationCutoffFile(home: home).path == "/tmp/home/.config/meetingvox/notificaciones.desde")
    }

    @Test func aMissingFileMeansNowAndIsWritten() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notificaciones.desde")

        #expect(NotificationCutoff.load(at: file, now: now) == now)
        #expect(read(file) == "2026-09-29T15:30:00Z")
    }

    @Test func aMissingParentFolderIsCreated() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("meetingvox", isDirectory: true).appendingPathComponent("notificaciones.desde")

        #expect(NotificationCutoff.load(at: file, now: now) == now)
        #expect(read(file) == "2026-09-29T15:30:00Z")
    }

    @Test func s2AMalformedFileMeansNowAndIsRewritten() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notificaciones.desde")
        try Data("not a date".utf8).write(to: file)

        #expect(NotificationCutoff.load(at: file, now: now) == now)
        #expect(read(file) == "2026-09-29T15:30:00Z")
    }

    @Test func anEmptyFileIsMalformedToo() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notificaciones.desde")
        try Data().write(to: file)

        #expect(NotificationCutoff.load(at: file, now: now) == now)
        #expect(read(file) == "2026-09-29T15:30:00Z")
    }

    @Test func aValidFileIsUsedAndLeftUntouched() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notificaciones.desde")
        try Data("2026-09-01T08:00:00Z\n".utf8).write(to: file)

        let cutoff = NotificationCutoff.load(at: file, now: now)
        #expect(cutoff == ISO8601DateFormatter().date(from: "2026-09-01T08:00:00Z"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "2026-09-01T08:00:00Z\n")
    }

    @Test func fractionalSecondsAreAccepted() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notificaciones.desde")
        try Data("2026-09-01T08:00:00.500Z".utf8).write(to: file)

        let cutoff = NotificationCutoff.load(at: file, now: now)
        #expect(abs(cutoff.timeIntervalSince(ISO8601DateFormatter().date(from: "2026-09-01T08:00:00Z")!) - 0.5) < 0.001)
    }

    @Test func aWriteFailureStillReturnsNowAndDoesNotThrow() throws {
        struct Boom: Error {}
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notificaciones.desde")
        final class Logged: @unchecked Sendable { var lines: [String] = [] }
        let logged = Logged()

        let cutoff = NotificationCutoff.load(
            at: file, now: now, write: { _, _ in throw Boom() }, log: { logged.lines.append($0) }
        )
        #expect(cutoff == now)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(logged.lines.count == 1)
    }

    @Test func aValidFileNeverTriggersAWrite() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notificaciones.desde")
        try Data("2026-09-01T08:00:00Z".utf8).write(to: file)
        final class Writes: @unchecked Sendable { var count = 0 }
        let writes = Writes()

        _ = NotificationCutoff.load(at: file, now: now, write: { _, _ in writes.count += 1 })
        #expect(writes.count == 0)
    }
}
