import Foundation

/// Opens the main window, optionally on a session and tab (a notice's
/// "Abrir"/"Ver reunión", the sessions menu, a refused retry).
///
/// While onboarding holds the starts the window would run the very reads that
/// are being held, so onboarding comes forward instead. A request for a
/// *session* made in that time is not lost: it waits under one key in
/// `DeferredStarts` (the last one wins) and opens when the starts are
/// released. A plain open with no session is not remembered, so the window
/// never appears by itself after onboarding. Every collaborator is injected.
@MainActor
struct MainWindowOpenRouter {
    let deferred: DeferredStarts
    /// Brings onboarding forward; false when it could not be shown.
    let showOnboarding: () -> Bool
    /// The banks list refresh a window opening triggers (through the gate).
    let refreshBanks: () -> Void
    let present: (_ session: URL?, _ tab: DetailTab?) -> Void

    func open(focusing session: URL?, tab: DetailTab?) {
        if ReopenRoute.decide(startsHeld: deferred.isHolding) == .onboarding {
            if showOnboarding() {
                if let session {
                    deferred.perform(.openSession) { open(focusing: session, tab: tab) }
                }
                return
            }
            // Onboarding could not come up: release the starts and carry on.
            deferred.windowFailed()
        }
        refreshBanks()
        present(session, tab)
    }
}
