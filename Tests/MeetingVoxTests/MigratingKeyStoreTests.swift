import Foundation
import Testing

@testable import MeetingVox

/// In-memory stand-ins for the two Keychain services and the retirement
/// marker, so nothing here can reach the real login keychain.
private final class MemoryStore: APIKeyStore, @unchecked Sendable {
    struct Denied: Error {}

    private let lock = NSLock()
    private var value: String?
    private(set) var reads = 0
    private(set) var saves = 0
    private(set) var deletes = 0
    var readError: Error?
    var saveError: Error?

    init(_ value: String? = nil) { self.value = value }

    var stored: String? { lock.lock(); defer { lock.unlock() }; return value }

    func hasAPIKey() -> Bool { lock.lock(); defer { lock.unlock() }; return value != nil }

    func read() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        if let readError { throw readError }
        return value
    }

    func save(_ secret: String) throws {
        lock.lock(); defer { lock.unlock() }
        saves += 1
        if let saveError { throw saveError }
        value = secret
    }

    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        deletes += 1
        value = nil
    }
}

private final class MemoryRetirement: LegacyKeyRetirement, @unchecked Sendable {
    struct CannotWrite: Error {}

    private let lock = NSLock()
    private var retired: Bool
    var failToRetire = false

    init(retired: Bool = false) { self.retired = retired }

    var isRetired: Bool { lock.lock(); defer { lock.unlock() }; return retired }

    func retire() throws {
        lock.lock(); defer { lock.unlock() }
        if failToRetire { throw CannotWrite() }
        retired = true
    }
}

@Suite("MigratingKeyStore")
struct MigratingKeyStoreTests {
    private func make(
        primary: MemoryStore = MemoryStore(), legacy: MemoryStore = MemoryStore(),
        retirement: MemoryRetirement = MemoryRetirement()
    ) -> MigratingKeyStore {
        MigratingKeyStore(primary: primary, legacy: legacy, retirement: retirement, log: { _ in })
    }

    // MARK: - read

    @Test func aLegacyOnlySecretIsReturnedAndCopiedToThePrimary() throws {
        let primary = MemoryStore(), legacy = MemoryStore("sk-legacy")
        let retirement = MemoryRetirement()
        let store = make(primary: primary, legacy: legacy, retirement: retirement)

        #expect(try store.read() == "sk-legacy")

        #expect(primary.stored == "sk-legacy")
        #expect(legacy.stored == "sk-legacy")
        #expect(legacy.deletes == 0)
        #expect(retirement.isRetired)
    }

    @Test func thePrimaryWinsAndTheLegacyIsNotEvenRead() throws {
        let legacy = MemoryStore("sk-old")
        let store = make(primary: MemoryStore("sk-new"), legacy: legacy)

        #expect(try store.read() == "sk-new")
        #expect(legacy.reads == 0)
        #expect(legacy.stored == "sk-old")
    }

    @Test func aDeniedLegacyReadIsNilWritesNothingAndIsRetriedNextTime() throws {
        let primary = MemoryStore(), legacy = MemoryStore("sk-legacy")
        legacy.readError = MemoryStore.Denied()
        let retirement = MemoryRetirement()
        let store = make(primary: primary, legacy: legacy, retirement: retirement)

        #expect(try store.read() == nil)
        #expect(primary.saves == 0)
        #expect(legacy.deletes == 0)
        #expect(!retirement.isRetired)

        legacy.readError = nil // the user answered the prompt with "Allow"
        #expect(try store.read() == "sk-legacy")
        #expect(legacy.reads == 2)
        #expect(primary.stored == "sk-legacy")
    }

    @Test func noSecretAnywhereIsNilAndNothingIsRetired() throws {
        let retirement = MemoryRetirement()
        let store = make(retirement: retirement)

        #expect(try store.read() == nil)
        #expect(!retirement.isRetired)
    }

    @Test func aFailedCopyToThePrimaryStillReturnsTheSecretButDoesNotRetire() throws {
        let primary = MemoryStore(), legacy = MemoryStore("sk-legacy")
        primary.saveError = MemoryStore.Denied()
        let retirement = MemoryRetirement()
        let store = make(primary: primary, legacy: legacy, retirement: retirement)

        #expect(try store.read() == "sk-legacy")
        #expect(!retirement.isRetired)
        #expect(primary.stored == nil)
    }

    @Test func aPrimaryReadErrorPropagates() {
        let primary = MemoryStore("x")
        primary.readError = MemoryStore.Denied()
        let store = make(primary: primary, legacy: MemoryStore("y"))

        #expect(throws: MemoryStore.Denied.self) { try store.read() }
    }

    // MARK: - retirement

    @Test func aRetiredLegacyItemIsNotReadAgain() throws {
        let legacy = MemoryStore("sk-legacy")
        let store = make(legacy: legacy, retirement: MemoryRetirement(retired: true))

        #expect(try store.read() == nil)
        #expect(legacy.reads == 0)
    }

    @Test func savingRetiresTheLegacyItemAndWritesOnlyThePrimary() throws {
        let primary = MemoryStore(), legacy = MemoryStore("sk-legacy")
        let retirement = MemoryRetirement()
        let store = make(primary: primary, legacy: legacy, retirement: retirement)

        try store.save("sk-typed")

        #expect(primary.stored == "sk-typed")
        #expect(legacy.stored == "sk-legacy")
        #expect(legacy.saves == 0)
        #expect(retirement.isRetired)
    }

    @Test func aSecretDeletedInSettingsDoesNotResurfaceFromTheLegacyItem() throws {
        let primary = MemoryStore(), legacy = MemoryStore("sk-legacy")
        let store = make(primary: primary, legacy: legacy)
        #expect(try store.read() == "sk-legacy") // migrated

        try store.delete()

        #expect(primary.stored == nil)
        #expect(try store.read() == nil)
        #expect(legacy.stored == "sk-legacy")
        #expect(legacy.deletes == 0)
    }

    @Test func deletingBeforeEverReadingAlsoRetiresTheLegacyItem() throws {
        let legacy = MemoryStore("sk-legacy")
        let store = make(legacy: legacy)

        try store.delete()

        #expect(try store.read() == nil)
        #expect(!store.hasAPIKey())
    }

    @Test func ifTheMarkerCannotBeWrittenDeleteThrowsAndTheSecretStaysPut() {
        let primary = MemoryStore("sk-new")
        let retirement = MemoryRetirement()
        retirement.failToRetire = true
        let store = make(primary: primary, legacy: MemoryStore("sk-old"), retirement: retirement)

        #expect(throws: MemoryRetirement.CannotWrite.self) { try store.delete() }
        #expect(primary.stored == "sk-new")
    }

    @Test func aFailedRetirementAfterSaveDoesNotFailTheSave() throws {
        let primary = MemoryStore()
        let retirement = MemoryRetirement()
        retirement.failToRetire = true
        let store = make(primary: primary, retirement: retirement)

        try store.save("sk-typed")

        #expect(primary.stored == "sk-typed")
    }

    // MARK: - presence

    @Test func presenceIsTrueForALegacyOnlyItemWithoutReadingIt() {
        let legacy = MemoryStore("sk-legacy")
        let store = make(legacy: legacy)

        #expect(store.hasAPIKey())
        #expect(legacy.reads == 0)
    }

    @Test func presenceIsTrueForAPrimaryOnlyItem() {
        #expect(make(primary: MemoryStore("sk-new")).hasAPIKey())
    }

    @Test func presenceIsFalseForARetiredLegacyItem() {
        let store = make(legacy: MemoryStore("sk-legacy"), retirement: MemoryRetirement(retired: true))

        #expect(!store.hasAPIKey())
    }

    @Test func presenceIsFalseWhenNeitherServiceHoldsAnItem() {
        #expect(!make().hasAPIKey())
    }

    // MARK: - presence() (attributes only: primary | legacyOnly | none)

    @Test func presenceReportsThePrimaryItemWithoutReadingAnything() {
        let primary = MemoryStore("sk-new"), legacy = MemoryStore("sk-old")
        let store = make(primary: primary, legacy: legacy)

        #expect(store.presence() == .primary)
        #expect(primary.reads == 0 && legacy.reads == 0)
        #expect(primary.saves == 0 && legacy.saves == 0)
    }

    @Test func presenceReportsALegacyOnlyItemWithoutReadingOrCopyingIt() {
        let primary = MemoryStore(), legacy = MemoryStore("sk-old")
        let retirement = MemoryRetirement()
        let store = make(primary: primary, legacy: legacy, retirement: retirement)

        #expect(store.presence() == .legacyOnly)
        #expect(legacy.reads == 0)  // a read would raise the legacy ACL prompt
        #expect(primary.saves == 0)
        #expect(!retirement.isRetired)
        #expect(legacy.stored == "sk-old")
    }

    @Test func presenceReportsNoneWhenNeitherServiceHoldsAnItem() {
        #expect(make().presence() == .none)
    }

    @Test func aRetiredLegacyItemIsNotOfferedForMigration() {
        let store = make(legacy: MemoryStore("sk-old"), retirement: MemoryRetirement(retired: true))

        #expect(store.presence() == .none)
        #expect(!store.hasAPIKey())
    }

    @Test func aPrimaryItemWinsOverARetiredLegacyOne() {
        let store = make(
            primary: MemoryStore("sk-new"), legacy: MemoryStore("sk-old"),
            retirement: MemoryRetirement(retired: true)
        )
        #expect(store.presence() == .primary)
    }

    @Test func hasAPIKeyIsPresenceNotNone() {
        for (primary, legacy, retired) in [
            ("sk", nil, false), (nil, "sk", false), (nil, nil, false), (nil, "sk", true),
        ] as [(String?, String?, Bool)] {
            let store = make(
                primary: MemoryStore(primary), legacy: MemoryStore(legacy),
                retirement: MemoryRetirement(retired: retired)
            )
            #expect(store.hasAPIKey() == (store.presence() != .none))
        }
    }

    @Test func aPlainStoreDefaultsToPrimaryOrNone() {
        // The protocol default, for every store that only knows hasAPIKey().
        #expect(MemoryStore("sk").presence() == .primary)
        #expect(MemoryStore().presence() == .none)
    }
}

@Suite("FileLegacyKeyRetirement")
struct FileLegacyKeyRetirementTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-retire-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func retiringCreatesTheMarkerAndCreatesTheConfigDirIfNeeded() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent(AppIdentity.keychainRetirementMarker(account: "hindsight_token"))
        let retirement = FileLegacyKeyRetirement(marker: marker)
        #expect(!retirement.isRetired)

        try retirement.retire()

        #expect(retirement.isRetired)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        // Idempotent.
        try retirement.retire()
        #expect(retirement.isRetired)
    }

    @Test func markersAreIndependentPerAccount() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = FileLegacyKeyRetirement(marker: dir.appendingPathComponent(
            AppIdentity.keychainRetirementMarker(account: "openrouter_api_key")))
        let b = FileLegacyKeyRetirement(marker: dir.appendingPathComponent(
            AppIdentity.keychainRetirementMarker(account: "hindsight_token")))

        try a.retire()

        #expect(a.isRetired)
        #expect(!b.isRetired)
    }
}
