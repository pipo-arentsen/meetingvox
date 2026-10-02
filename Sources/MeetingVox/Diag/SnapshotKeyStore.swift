import Foundation

/// The key store of the snapshot route: it holds nothing and can save
/// nothing. The headless renderer must never reach the login keychain (a
/// read could raise a system prompt), so views that ask "is there an API
/// key?" get a deterministic "no" and every write is refused.
struct SnapshotKeyStore: APIKeyStore {
    struct ReadOnly: Error, CustomStringConvertible {
        var description: String { "the snapshot key store is read-only" }
    }

    func hasAPIKey() -> Bool { false }
    func presence() -> KeyPresence { .none }
    func read() throws -> String? { nil }
    func save(_ secret: String) throws { throw ReadOnly() }
    func delete() throws { throw ReadOnly() }
}
