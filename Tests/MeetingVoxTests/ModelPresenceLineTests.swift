import Foundation
import Testing

@testable import MeetingVox

/// `diag --mode permissions` prints whether the speech model is on disk. It
/// only asks the downloader for presence; `download` must never be called.
@Suite("ModelPresenceLine")
struct ModelPresenceLineTests {
    private struct Probe: ModelDownloader {
        let directory = URL(fileURLWithPath: "/tmp/fake-cache/parakeet")
        let present: Bool
        func isPresent() -> Bool { present }
        func download(progress: @escaping @Sendable (Double, ModelProgress.Phase) -> Void) async throws {
            Issue.record("the diag line must never download")
        }
    }

    @Test func aPresentModelIsReportedWithItsPath() {
        let line = Diag.modelPresenceLine(Probe(present: true))
        #expect(line == "speech model: present at /tmp/fake-cache/parakeet")
    }

    @Test func anAbsentModelIsReportedAsNotDownloadedAndNothingIsFetched() {
        let line = Diag.modelPresenceLine(Probe(present: false))
        #expect(line == "speech model: not downloaded (expected at /tmp/fake-cache/parakeet); nothing is downloaded by diag")
    }
}

/// The key lines of `diag --mode permissions`: attributes only, so the
/// store's `read()` (which can raise the legacy Keychain prompt) must never
/// be called.
@Suite("KeyPresenceLine")
struct KeyPresenceLineTests {
    private struct Store: APIKeyStore {
        let value: KeyPresence
        func hasAPIKey() -> Bool { value != .none }
        func presence() -> KeyPresence { value }
        func read() throws -> String? {
            Issue.record("the diag line must never read the secret")
            return nil
        }
        func save(_ secret: String) throws { Issue.record("diag never writes") }
        func delete() throws { Issue.record("diag never deletes") }
    }

    @Test func eachPresenceHasItsOwnLine() {
        #expect(Diag.keyPresenceLine("OpenRouter key", Store(value: .primary))
            == "OpenRouter key: primary (MeetingVox service; attributes only, never read)")
        #expect(Diag.keyPresenceLine("OpenRouter key", Store(value: .legacyOnly))
            == "OpenRouter key: legacyOnly (only under the legacy quill service; onboarding offers \"Migrar clave\"; attributes only, never read)")
        #expect(Diag.keyPresenceLine("Hindsight token", Store(value: .none))
            == "Hindsight token: none (attributes only, never read)")
    }
}
