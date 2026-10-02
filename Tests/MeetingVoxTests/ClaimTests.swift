import Foundation
import Testing
@testable import MeetingVox

/// `listo.notificado` is claimed atomically (O_EXCL) before anything is
/// posted, so a relaunch, a resume or two concurrent evaluations never post
/// twice, and a failed post never releases the claim.
@Suite struct ClaimTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-claim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func theMarkerNameIsListoNotificado() {
        #expect(SessionFiles.readyNotified == "listo.notificado")
    }

    @Test func theFirstClaimCreatesTheMarker() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SessionFiles.claim(SessionFiles.readyNotified, in: dir) == .claimed)
        #expect(SessionFiles.exists(SessionFiles.readyNotified, in: dir))
    }

    @Test func aSecondClaimIsAlreadyClaimedAndLeavesTheMarker() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SessionFiles.claim(SessionFiles.readyNotified, in: dir) == .claimed)
        #expect(SessionFiles.claim(SessionFiles.readyNotified, in: dir) == .alreadyClaimed)
        #expect(SessionFiles.claim(SessionFiles.readyNotified, in: dir) == .alreadyClaimed)
        #expect(SessionFiles.exists(SessionFiles.readyNotified, in: dir))
    }

    @Test func aMarkerThatAlreadyExistedIsAlreadyClaimed() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SessionFiles.writeMarker(SessionFiles.readyNotified, in: dir)
        #expect(SessionFiles.claim(SessionFiles.readyNotified, in: dir) == .alreadyClaimed)
    }

    @Test func aMissingFolderFailsWithoutClaiming() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-claim-missing-\(UUID().uuidString)", isDirectory: true)
        let result = SessionFiles.claim(SessionFiles.readyNotified, in: dir)
        guard case .failed(let code) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(code == ENOENT)
        #expect(!SessionFiles.exists(SessionFiles.readyNotified, in: dir))
    }

    /// Concurrent evaluations racing for the same session: exactly one wins.
    @Test func concurrentClaimsHaveExactlyOneWinner() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        final class Results: @unchecked Sendable {
            private let lock = NSLock()
            private var _all: [SessionFiles.ClaimResult] = []
            func add(_ r: SessionFiles.ClaimResult) { lock.withLock { _all.append(r) } }
            var all: [SessionFiles.ClaimResult] { lock.withLock { _all } }
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            results.add(SessionFiles.claim(SessionFiles.readyNotified, in: dir))
        }
        #expect(results.all.count == 32)
        #expect(results.all.filter { $0 == .claimed }.count == 1)
        #expect(results.all.filter { $0 == .alreadyClaimed }.count == 31)
    }
}
