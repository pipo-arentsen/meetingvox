import Foundation

/// The last Local Network probe result, cached so reading it never waits.
///
/// A probe can take its whole timeout (and raises the system prompt), so:
/// the click awaits it (`click`), and every later refresh runs in the
/// background (`refreshIfClicked`), single-flight, updating the cache and
/// calling `onChange` so the window can read again. Before the first click
/// nothing is ever probed.
///
/// `onChange` fires only when the cached result actually differs from the
/// previous one (the first answer counts: nothing was known before). A
/// listener that reads again and thereby refreshes again would otherwise be
/// woken by every probe it starts, forever.
final class LocalNetworkTracker: @unchecked Sendable {
    private struct State {
        var result: LocalNetworkProbe.Result?
        var clicked = false
        var refreshing = false
    }

    private let probe: @Sendable (URL) async -> LocalNetworkProbe.Result
    private let onChange: @Sendable () -> Void
    private let state = NSLock()
    private var stored = State()

    init(
        probe: @escaping @Sendable (URL) async -> LocalNetworkProbe.Result,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.probe = probe
        self.onChange = onChange
    }

    var current: LocalNetworkProbe.Result? { state.withLock { stored.result } }
    var hasClicked: Bool { state.withLock { stored.clicked } }

    /// The user's "Permitir": marks the click and waits for the probe.
    func click(_ url: URL) async {
        state.withLock { stored.clicked = true }
        let result = await probe(url)
        let changed = state.withLock { () -> Bool in
            defer { stored.result = result }
            return stored.result != result
        }
        if changed { onChange() }
    }

    /// Returns at once. Only after a click, and only if no probe is running.
    func refreshIfClicked(_ url: URL) {
        let start = state.withLock { () -> Bool in
            guard stored.clicked, !stored.refreshing else { return false }
            stored.refreshing = true
            return true
        }
        guard start else { return }
        Task { [self] in
            let result = await probe(url)
            let changed = state.withLock { () -> Bool in
                defer {
                    stored.result = result
                    stored.refreshing = false
                }
                return stored.result != result
            }
            if changed { onChange() }
        }
    }
}
