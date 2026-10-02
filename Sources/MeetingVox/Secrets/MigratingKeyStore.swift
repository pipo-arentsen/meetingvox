import Foundation

/// Remembers that a legacy Keychain item must no longer be consulted.
///
/// Without it, a secret deleted (or replaced) in Settings would come back:
/// the primary service is empty again, so the fallback would find the old
/// `quill` item and copy it forward. The legacy item itself is never
/// deleted — it stays as the backup — so the memory of "we are done with it"
/// has to live somewhere else.
protocol LegacyKeyRetirement: Sendable {
    var isRetired: Bool { get }
    func retire() throws
}

/// One empty file per account in the new config dir
/// (`.keychain-legacy-done.<account>`, see `AppIdentity`).
struct FileLegacyKeyRetirement: LegacyKeyRetirement {
    let marker: URL

    var isRetired: Bool { FileManager.default.fileExists(atPath: marker.path) }

    func retire() throws {
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: marker, options: .atomic)
    }
}

/// A secret that moved from the legacy `com.digimata.quill` Keychain service
/// to the MeetingVox one.
///
/// Reads try the primary service first, then (until retired) the legacy one;
/// a value found only there is copied to the primary. Saving or deleting acts
/// on the primary and retires the legacy item, so the two can never disagree
/// about a secret the user changed on purpose. A legacy read that fails
/// (the ACL prompt was denied, say) counts as "missing" and is retried on the
/// next read; nothing is written or deleted because of it.
struct MigratingKeyStore: APIKeyStore {
    let primary: any APIKeyStore
    let legacy: any APIKeyStore
    let retirement: any LegacyKeyRetirement
    /// stderr by default; a seam so tests stay quiet.
    var log: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    /// Attribute-only on both services (never prompts). A retired legacy
    /// item doesn't count.
    func hasAPIKey() -> Bool { presence() != .none }

    /// Where the secret is, without reading it: the legacy item is only
    /// reported (and never touched) so the UI can explain the prompt a read
    /// would raise before offering to migrate.
    func presence() -> KeyPresence {
        if primary.hasAPIKey() { return .primary }
        if !retirement.isRetired, legacy.hasAPIKey() { return .legacyOnly }
        return .none
    }

    func read() throws -> String? {
        if let value = try primary.read() { return value }
        guard !retirement.isRetired else { return nil }

        let value: String?
        do {
            value = try legacy.read()
        } catch {
            log("keychain: legacy item not readable, will retry: \(error)")
            return nil
        }
        guard let value else { return nil }

        do {
            try primary.save(value)
        } catch {
            // Still usable this time; not retired, so the copy is retried.
            log("keychain: could not copy the legacy item to the new service: \(error)")
            return value
        }
        retireLoggingFailure()
        return value
    }

    func save(_ secret: String) throws {
        try primary.save(secret)
        retireLoggingFailure()
    }

    func delete() throws {
        // Retire first: if the marker can't be written the delete must not
        // half-happen and let the legacy secret resurface.
        try retirement.retire()
        try primary.delete()
    }

    private func retireLoggingFailure() {
        do {
            try retirement.retire()
        } catch {
            log("keychain: could not record the legacy item as retired: \(error)")
        }
    }
}
