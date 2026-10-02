import AppKit
import SwiftUI

/// Owns the single, reusable main window. Same shape as the onboarding
/// window's controller: a `presentWindow` seam so tests never build an
/// `NSWindow`, an injected `NotificationCenter` and an injected
/// `ActivationPolicyCoordinator`.
///
/// While the window is open it holds an activation lease, which is what makes
/// the app `.regular` (Dock icon, a menu bar, focus). Every way out — the red
/// dot, ⌘W, a show that never came up — releases it exactly once, and the
/// coordinator counts it together with the onboarding window's, so the two
/// never fight over the policy.
///
/// It also observes the index, Hindsight status, config and templates
/// notifications, but only while open, and reloads the model on each: a
/// background summary write, an export outcome, a Settings change or a saved
/// template all reach the rows (and the template lists) without polling.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    /// AppKit saves and restores the window's size and position under this.
    static let frameAutosaveName = "MainWindow"

    private let model: MainWindowModel
    private let notifications: NotificationCenter
    private let activation: ActivationPolicyCoordinator
    private var window: NSWindow?
    private var lease: ActivationPolicyCoordinator.Lease?
    private var observers: [NSObjectProtocol] = []

    /// - Parameter onToggleRecording: the title strip's "Grabar"/"Detener".
    init(
        model: MainWindowModel, notifications: NotificationCenter = .default,
        activation: ActivationPolicyCoordinator = .shared,
        onToggleRecording: @escaping () -> Void = {}
    ) {
        self.model = model
        self.notifications = notifications
        self.activation = activation
        self.onToggleRecording = onToggleRecording
        super.init()
        presentWindow = { [weak self] in self?.presentRealWindow() ?? false }
    }

    private let onToggleRecording: () -> Void

    /// Brings the window up and says whether it is visible. Tests replace it.
    var presentWindow: () -> Bool = { false }

    /// - Parameters:
    ///   - session: a session to select (a notice's "Abrir"/"Ver reunión");
    ///     see `MainWindowModel.focus(on:tab:)`.
    ///   - tab: the tab to land on, nil = keep the current one.
    func show(focusing session: URL? = nil, tab: DetailTab? = nil) {
        if lease == nil { lease = activation.acquire() }
        startObserving()
        model.isActive = true
        if let session { model.focus(on: session, tab: tab) }
        // Reopening on Plantillas or Glosario: what the page shows may have
        // changed while the window was closed.
        model.library.refresh(for: model.sidebar)
        model.reload()
        if !presentWindow() { tearDown() }
    }

    /// Land on a sidebar entry (Ajustes' "Abrir Biblioteca").
    func select(_ item: SidebarItem) { model.sidebar = item }

    private func startObserving() {
        guard observers.isEmpty else { return }
        for name in [
            Notification.Name.meetingVoxMeetingIndexDidChange, .meetingVoxHindsightStatusDidChange, .meetingVoxConfigDidChange,
            .meetingVoxTemplatesDidChange,
        ] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Rescans are coalesced (a burst is one scan). A change this
                // window's own list announced already patched its rows.
                let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
                let name = note.name
                MainActor.assumeIsolated {
                    guard let self, sender != ObjectIdentifier(self.model.meetings) else { return }
                    if name == .meetingVoxHindsightStatusDidChange {
                        // Also ends a memory send that was in flight.
                        self.model.hindsightStatusChanged()
                    } else {
                        self.model.scheduleReload()
                    }
                }
            })
        }
    }

    /// Every close path: stop observing, give the Dock icon back, and let the
    /// next opening start on the first page again.
    private func tearDown() {
        for observer in observers { notifications.removeObserver(observer) }
        observers = []
        lease?.release()
        lease = nil
        model.isActive = false
        model.meetings.resetWindow()
    }

    private func presentRealWindow() -> Bool {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return window.isVisible
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: MainLayout.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppIdentity.displayName
        // The in-content strip carries the title and the record button.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = MainLayout.minimumSize
        window.contentView = NSHostingView(
            rootView: MainView(model: model, onToggleRecording: onToggleRecording)
        )
        window.setContentSize(MainLayout.defaultSize)
        // First open: centered at the default size. Afterwards AppKit
        // restores the size and position the user left, and keeps saving it.
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        _ = window.setFrameAutosaveName(Self.frameAutosaveName)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        tearDown()
    }
}
