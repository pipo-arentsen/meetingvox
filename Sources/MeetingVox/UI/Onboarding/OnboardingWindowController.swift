import AppKit
import SwiftUI

/// Owns the single, reusable onboarding window (760 × 560, fixed).
///
/// The window holds an `ActivationPolicyCoordinator` lease while it is open,
/// so the Dock icon and a focusable window exist only then; every close path
/// (button, red dot, teardown) goes through `windowWillClose`, which releases
/// it. `windowDidBecomeKey` re-reads the permission statuses, so enabling
/// one in System Settings and coming back shows up without a click.
/// Nothing here opens the window on its own: launch wiring calls `show()`.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let contentSize = NSSize(width: 760, height: 560)

    private let model: OnboardingModel
    private let activation: ActivationPolicyCoordinator
    private let onClose: () -> Void
    private let minutasStep: AnyView
    private let listoStep: AnyView
    private var window: NSWindow?
    private var lease: ActivationPolicyCoordinator.Lease?

    /// `minutasStep` and `listoStep` default to placeholders until those
    /// steps exist.
    init(
        model: OnboardingModel,
        activation: ActivationPolicyCoordinator = .shared,
        minutasStep: AnyView = AnyView(PlaceholderStepView()),
        listoStep: AnyView = AnyView(PlaceholderStepView()),
        onClose: @escaping () -> Void = {}
    ) {
        self.model = model
        self.activation = activation
        self.minutasStep = minutasStep
        self.listoStep = listoStep
        self.onClose = onClose
        super.init()
        // The controller owns the model's `close` (see `OnboardingModel.close`):
        // assigned once here, never chained.
        model.close = { [weak self] in
            guard let self else { return }
            self.closeWindow(self.window)
        }
        presentWindow = { [weak self] in self?.presentRealWindow() ?? false }
    }

    /// Brings the window up and says whether it is visible. Tests replace it:
    /// they never create an `NSWindow`.
    var presentWindow: () -> Bool = { false }

    /// How "Empezar" closes the window. `NSWindow.close()` posts
    /// `willClose`, which reaches `windowWillClose`; tests replace this since
    /// they never create a window.
    var closeWindow: (NSWindow?) -> Void = { $0?.close() }

    /// Whether the window is up afterwards; launch releases its held starts
    /// when it is not. A window that did not come up gives the Dock icon
    /// back at once: no close will ever arrive to release the lease.
    @discardableResult
    func show() -> Bool {
        holdActivation()
        let visible = presentWindow()
        if !visible { releaseActivation() }
        return visible
    }

    private func presentRealWindow() -> Bool {
        let window = self.window ?? makeWindow()
        if self.window == nil {
            self.window = window
            window.center()
        }
        model.startObservingModel()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return window.isVisible
    }

    /// Takes the lease once per opening.
    func holdActivation() {
        if lease == nil { lease = activation.acquire() }
    }

    private func releaseActivation() {
        lease?.release()
        lease = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Textos.Onboarding.tituloVentana
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: OnboardingView(model: model, minutasStep: minutasStep, listoStep: listoStep)
        )
        window.setContentSize(Self.contentSize)
        return window
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        Task { await model.windowDidBecomeKey() }
    }

    func windowWillClose(_ notification: Notification) {
        model.windowClosed()
        releaseActivation()
        onClose()
    }
}
