import Foundation
import Security

/// Where a secret was found, as far as attributes can tell (never its value).
enum KeyPresence: Equatable, Sendable {
    /// Under MeetingVox's own service.
    case primary
    /// Only under the legacy `quill` service: reading it raises the macOS
    /// "Always Allow" prompt, so it is offered for an explicit migration.
    case legacyOnly
    case none
}

/// Where a secret (OpenRouter API key, Hindsight token) lives. A seam so the settings model can be
/// tested without touching the real login keychain.
protocol APIKeyStore: Sendable {
    /// Attributes-only lookup; never prompts.
    func hasAPIKey() -> Bool
    /// Attributes-only, never prompts, never reads the secret. `hasAPIKey()`
    /// is `presence() != .none`; a store with a single service only knows
    /// `.primary` or `.none` (the default below).
    func presence() -> KeyPresence
    /// The secret, nil if missing; throws when it exists but can't be read
    /// (access denied, ACL mismatch after a rebuild…). May prompt.
    func read() throws -> String?
    func save(_ secret: String) throws
    func delete() throws
}

extension APIKeyStore {
    func presence() -> KeyPresence { hasAPIKey() ? .primary : .none }
}

/// A single generic-password item in the user's login keychain. The API key
/// lives here — never in config.json, logs, or stderr — so it is encrypted at
/// rest and never ends up in a dotfiles repo.
///
/// Uses the file-based login keychain on purpose: the data-protection
/// keychain needs a `keychain-access-groups` entitlement, which a bare,
/// ad-hoc signed binary can't carry.
struct Keychain: APIKeyStore {
    let service: String
    let account: String
    /// Shown in Keychain Access for an item MeetingVox adds.
    var label = "MeetingVox — OpenRouter API key"

    // The two secrets moved from the `com.digimata.quill` service to
    // MeetingVox's own. What the app uses is the `MigratingKeyStore` (new
    // service first, legacy as a one-time fallback); the plain items are
    // exposed for the tests.
    static let openRouterPrimary = Keychain(
        service: AppIdentity.keychainService, account: "openrouter_api_key"
    )
    static let openRouterLegacy = Keychain(
        service: AppIdentity.legacyKeychainService, account: "openrouter_api_key",
        label: "quill — OpenRouter API key"
    )
    /// Hindsight bearer token (export of sessions to the memory server).
    static let hindsightPrimary = Keychain(
        service: AppIdentity.keychainService, account: "hindsight_token",
        label: "MeetingVox — Hindsight token"
    )
    static let hindsightLegacy = Keychain(
        service: AppIdentity.legacyKeychainService, account: "hindsight_token",
        label: "quill — Hindsight token"
    )

    static let openRouter = MigratingKeyStore(
        primary: openRouterPrimary, legacy: openRouterLegacy, retirement: retirement(for: openRouterPrimary)
    )
    static let hindsight = MigratingKeyStore(
        primary: hindsightPrimary, legacy: hindsightLegacy, retirement: retirement(for: hindsightPrimary)
    )

    /// The retirement marker lives in the new config dir, next to the
    /// migrated config, so a rollback (deleting that dir) also forgets it.
    private static func retirement(for item: Keychain) -> FileLegacyKeyRetirement {
        FileLegacyKeyRetirement(
            marker: AppIdentity.configDir(home: FileManager.default.homeDirectoryForCurrentUser)
                .appendingPathComponent(AppIdentity.keychainRetirementMarker(account: item.account))
        )
    }

    /// `description` is English for stderr; `errorDescription` is the
    /// Spanish copy shown in the settings window.
    struct KeychainError: Error, CustomStringConvertible, LocalizedError {
        let status: OSStatus

        private var systemMessage: String? { SecCopyErrorMessageString(status, nil) as String? }

        var description: String {
            "keychain error \(status): \(systemMessage ?? "unknown error")"
        }

        var errorDescription: String? { Textos.Ajustes.errorLlavero(status, systemMessage) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Whether an item exists, without touching its secret. Attribute-only
    /// lookups don't trigger the "MeetingVox wants to use your keychain" prompt,
    /// which matters because `doctor` calls this at login.
    func hasAPIKey() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// The stored secret, nil if missing; throws `KeychainError` when the
    /// item exists but can't be read. May show a modal keychain prompt (e.g.
    /// after the binary is rebuilt) that blocks the calling thread, so call
    /// it off the main actor and only when the secret is actually needed.
    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    /// Update the existing item, or add it if missing.
    func save(_ secret: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: status)
        }
    }

    /// Remove the item. Deleting a missing item is not an error.
    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
