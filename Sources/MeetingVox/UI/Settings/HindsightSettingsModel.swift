import Foundation
import Observation

/// State behind the "Memoria" settings tab (Hindsight export). Same rules as
/// `SettingsModel`: the toggle and the date save at once, text fields on
/// submit / focus loss / window close, and the token only on an explicit
/// Save — never read back into the UI, never in config.json.
@MainActor
@Observable
final class HindsightSettingsModel {
    var enabled = false {
        didSet { enabledChanged() }
    }
    var baseURL = ""
    var bank = ""
    var ownerName = ""
    var ownerDescription = ""
    /// `hindsight.auto_send`. Turning it on without a cutoff saves today, so
    /// older meetings stay out unless the user picks an earlier day.
    var autoSend = false {
        didSet { autoSendChanged() }
    }
    var minWords = ConfigValues.defaultHindsightMinWords {
        didSet {
            guard !isLoading else { return }
            save(minWords, "min_words")
        }
    }
    var minMinutes = ConfigValues.defaultHindsightMinMinutes {
        didSet {
            guard !isLoading else { return }
            save(minMinutes, "min_minutes")
        }
    }
    /// `hindsight.since`: first day of the automatic send.
    var since = Date() {
        didSet {
            guard !isLoading else { return }
            hasSince = true
            save(ConfigValues.hindsightDay(since, timeZone: timeZone), "since")
        }
    }

    var tokenInput = ""
    private(set) var hasToken = false
    private(set) var tokenError: String?
    private(set) var configError: String?

    private(set) var connectionResult: String?
    private(set) var connectionFailed = false
    private(set) var testingConnection = false

    /// The banks the picker offers (`HindsightBankList` is `@Observable` on
    /// its own).
    @ObservationIgnored let bankList: HindsightBankList
    @ObservationIgnored private let configURL: URL
    @ObservationIgnored private let keychain: any APIKeyStore
    @ObservationIgnored private let backend: any HindsightBackend
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private let notifications: NotificationCenter
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var hasSince = false
    /// Trimmed text-field values as on disk, so a commit without an edit
    /// doesn't rewrite the file.
    @ObservationIgnored private var committed: [String: String] = [:]
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = 0

    init(
        configURL: URL = Config.path,
        keychain: any APIKeyStore = Keychain.hindsight,
        backend: any HindsightBackend = HindsightClient(),
        now: @escaping () -> Date = { Date() },
        timeZone: TimeZone = .current,
        notifications: NotificationCenter = .default,
        bankList: HindsightBankList? = nil
    ) {
        self.configURL = configURL
        self.keychain = keychain
        self.backend = backend
        self.now = now
        self.timeZone = timeZone
        self.notifications = notifications
        // Tests get a list that reads the same (temporary) config file and
        // fake backend; the app passes the shared one.
        self.bankList = bankList ?? HindsightBankList(
            backend: backend, keyStore: keychain,
            config: { ConfigValues(raw: (try? ConfigStore.loadRaw(at: configURL)) ?? [:]) },
            notifications: notifications
        )
        reload()
    }

    // MARK: - Loading

    /// Re-read config and token presence (never the token itself).
    func reload() {
        isLoading = true
        defer { isLoading = false }
        let raw: [String: Any]
        do {
            raw = try ConfigStore.loadRaw(at: configURL)
            configError = nil
        } catch {
            raw = [:]
            FileHandle.standardError.write(Data("settings: config read failed: \(error)\n".utf8))
            configError = Textos.Ajustes.errorLeer(error.localizedDescription)
        }
        let values = ConfigValues(raw: raw)
        let section = raw["hindsight"] as? [String: Any] ?? [:]
        func text(_ key: String) -> String {
            ((section[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        enabled = values.hindsightEnabled
        baseURL = text("base_url")
        bank = text("bank")
        ownerName = text("owner_name")
        ownerDescription = text("owner_description")
        autoSend = values.hindsightAutoSend
        minWords = values.hindsightMinWords
        minMinutes = values.hindsightMinMinutes
        committed = ["base_url": baseURL, "bank": bank, "owner_name": ownerName, "owner_description": ownerDescription]
        if let day = values.hindsightSince, let date = ConfigValues.hindsightDate(fromDay: day, timeZone: timeZone) {
            since = date
            hasSince = true
        } else {
            since = now()
            hasSince = false
        }
        tokenInput = ""
        hasToken = keychain.hasAPIKey()
        tokenError = nil
        cancelConnectionTest()
    }

    func windowDidClose() {
        commitBaseURL()
        commitBank()
        commitOwnerName()
        commitOwnerDescription()
        tokenInput = ""
    }

    // MARK: - Fields

    func commitBaseURL() { commit(baseURL, "base_url") }
    func commitBank() { commit(bank, "bank") }
    func commitOwnerName() { commit(ownerName, "owner_name") }
    func commitOwnerDescription() { commit(ownerDescription, "owner_description") }

    /// The picker's options: the server list, plus the saved bank if the
    /// server doesn't know it, so the picker never shows a choice with no
    /// matching entry. With no bank saved yet, a placeholder ("") stands in
    /// for "none chosen" — the view
    /// renders it as "—" — since otherwise `bank`'s current value ("")
    /// would have no matching tag once the server list has loaded.
    var bankChoices: [String] {
        let saved = bank.trimmingCharacters(in: .whitespacesAndNewlines)
        let banks = bankList.banks
        if saved.isEmpty { return [""] + banks }
        return banks.contains(saved) ? banks : [saved] + banks
    }

    func selectBank(_ id: String) {
        bank = id
        commitBank()
    }

    /// Ajustes → Memoria opened.
    @discardableResult
    func refreshBanks() -> Task<Void, Never> { bankList.refresh() }

    private func commit(_ text: String, _ key: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != committed[key] else { return }
        if save(value.isEmpty ? nil : value, key) { committed[key] = value }
    }

    private func enabledChanged() {
        guard !isLoading else { return }
        save(enabled, "enabled")
    }

    private func autoSendChanged() {
        guard !isLoading else { return }
        save(autoSend, "auto_send")
        if autoSend, !hasSince {
            since = now() // didSet saves it
        }
    }

    // MARK: - Token

    func saveToken() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        cancelConnectionTest()
        do {
            try keychain.save(token)
            tokenInput = ""
            tokenError = nil
            tokenChanged()
        } catch {
            FileHandle.standardError.write(Data("settings: \(error)\n".utf8))
            tokenError = error.localizedDescription
        }
        hasToken = keychain.hasAPIKey()
    }

    func deleteToken() {
        cancelConnectionTest()
        do {
            try keychain.delete()
            tokenError = nil
            tokenChanged()
        } catch {
            FileHandle.standardError.write(Data("settings: \(error)\n".utf8))
            tokenError = error.localizedDescription
        }
        hasToken = keychain.hasAPIKey()
    }

    /// A new token may lift the exporter's auth pause (`HindsightScheduler`
    /// listens for config changes).
    private func tokenChanged() {
        notifications.post(name: .meetingVoxConfigDidChange, object: nil)
    }

    // MARK: - Connection test

    /// `GET /v1/default/banks` with the *saved* token. The Keychain read runs
    /// off the main actor (it may prompt). Returns the task for tests.
    @discardableResult
    func testConnection() -> Task<Void, Never> {
        commitBaseURL()
        cancelConnectionTest()
        guard let url = ConfigValues(raw: ["hindsight": ["base_url": baseURL]]).hindsightBaseURL else {
            connectionResult = Textos.Memoria.faltaURL
            connectionFailed = true
            return Task {}
        }
        let generation = connectionGeneration
        let keychain = self.keychain
        let backend = self.backend
        testingConnection = true
        let task = Task {
            let result: (message: String, failed: Bool)
            do {
                let token = try await Task.detached { try keychain.read() }.value
                if let token, !token.isEmpty {
                    result = Self.describe(await backend.testConnection(baseURL: url, token: token))
                } else {
                    result = (Textos.Memoria.necesitaToken, true)
                }
            } catch {
                FileHandle.standardError.write(Data("settings: \(error)\n".utf8))
                result = (error.localizedDescription, true)
            }
            guard generation == connectionGeneration else { return }
            connectionResult = result.message
            connectionFailed = result.failed
            testingConnection = false
        }
        connectionTask = task
        return task
    }

    static func describe(_ outcome: HindsightOutcome) -> (message: String, failed: Bool) {
        switch outcome {
        case .success: (Textos.Memoria.conexionCorrecta, false)
        case .unauthorized: (Textos.Memoria.tokenRechazado, true)
        case .transient(let detail): (Textos.Memoria.noAlcanzable(detail), true)
        case .rejected(let status, _): (Textos.Memoria.respuestaInesperada(status), true)
        }
    }

    private func cancelConnectionTest() {
        connectionTask?.cancel()
        connectionTask = nil
        connectionGeneration += 1
        testingConnection = false
        connectionResult = nil
    }

    // MARK: - Persistence

    /// Write `hindsight.<key>` (nil removes it); keeps every other key.
    /// Posts `meetingVoxConfigDidChange` so the exporter re-reads and un-pauses.
    @discardableResult
    private func save(_ value: Any?, _ key: String) -> Bool {
        guard !isLoading else { return false }
        do {
            try ConfigStore.update(at: configURL) { ConfigStore.set(value, at: ["hindsight", key], in: &$0) }
            configError = nil
            notifications.post(name: .meetingVoxConfigDidChange, object: nil)
            return true
        } catch {
            FileHandle.standardError.write(Data("settings: config write failed: \(error)\n".utf8))
            configError = Textos.Ajustes.errorGuardar(error.localizedDescription)
            return false
        }
    }
}
