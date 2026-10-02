import Foundation
import Observation

/// The banks the "Enviar a memoria ▸" menus and the Settings picker offer:
/// read from the server with the installation's token (the
/// same one as the export), kept in memory only, refreshed when the main window
/// or Ajustes → Memoria open and after a config change. Without a server
/// answer the list is just the default bank. The default always comes first.
@MainActor
@Observable
final class HindsightBankList {
    private(set) var banks: [String]
    /// The last refresh got an answer from the server (Settings shows a
    /// picker only then; a free text field otherwise).
    private(set) var loadedFromServer = false

    @ObservationIgnored private let backend: any HindsightBackend
    @ObservationIgnored private let keyStore: any APIKeyStore
    @ObservationIgnored private let config: () -> ConfigValues
    @ObservationIgnored private let notifications: NotificationCenter
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// A refresh superseded by a newer one is dropped on return.
    @ObservationIgnored private var generation = 0
    /// Every automatic refresh (the config-change observer) passes through
    /// here, so launch can hold it while onboarding is open: a refresh reads
    /// the Keychain and talks to the server, which must follow a click. A
    /// direct `refresh()` (opening the main window or Ajustes → Memoria) is a user
    /// action and is never gated. Runs at once by default.
    @ObservationIgnored var refreshGate: (@escaping @MainActor () -> Void) -> Void = { $0() }

    init(
        backend: any HindsightBackend = HindsightClient(),
        keyStore: any APIKeyStore = Keychain.hindsight,
        config: @escaping () -> ConfigValues = { Config.values() },
        notifications: NotificationCenter = .default
    ) {
        self.backend = backend
        self.keyStore = keyStore
        self.config = config
        self.notifications = notifications
        banks = Self.merge(server: nil, defaultBank: config().hindsightBank)
    }

    var defaultBank: String? { config().hindsightBank }

    /// Every bank but the default: what the "▸" menus list after it.
    var others: [String] {
        let defaultBank = self.defaultBank
        return banks.filter { $0 != defaultBank }
    }

    /// Refresh on every `meetingVoxConfigDidChange` (URL, default bank, token).
    func startObservingConfig() {
        guard observer == nil else { return }
        observer = notifications.addObserver(forName: .meetingVoxConfigDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshGate { [weak self] in _ = self?.refresh() }
            }
        }
    }

    /// Integration off, no URL or no token → the default alone, no network.
    /// The Keychain read runs off the main actor (it may prompt). Returns the
    /// task for tests.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        generation += 1
        let expected = generation
        let values = config()
        let defaultBank = values.hindsightBank
        guard values.hindsightEnabled, let baseURL = values.hindsightBaseURL, keyStore.hasAPIKey() else {
            apply(server: nil, defaultBank: defaultBank)
            return Task {}
        }
        let keyStore = self.keyStore
        let backend = self.backend
        return Task {
            // `try?` flattens String?? to String?; an unreadable token = no list.
            let token = try? await Task.detached { try keyStore.read() }.value
            var server: [String]?
            if let token, !token.isEmpty {
                server = await backend.listBanks(baseURL: baseURL, token: token)
            }
            guard expected == self.generation else { return }
            self.apply(server: server, defaultBank: defaultBank)
        }
    }

    private func apply(server: [String]?, defaultBank: String?) {
        banks = Self.merge(server: server, defaultBank: defaultBank)
        loadedFromServer = server != nil
    }

    /// Default first (kept even when the server doesn't list it: a send to
    /// it still works or fails visibly), then the other server banks sorted;
    /// no server answer → the default alone.
    nonisolated static func merge(server: [String]?, defaultBank: String?) -> [String] {
        let others = (server ?? [])
            .filter { $0 != defaultBank }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (defaultBank.map { [$0] } ?? []) + others
    }
}
