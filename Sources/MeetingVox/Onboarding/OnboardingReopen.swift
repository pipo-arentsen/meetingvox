import AppKit

/// The menu's "Primeros pasos…" item and its action target, apart from the
/// status item so its wiring is testable without a menu bar.
@MainActor
final class OnboardingMenuItem: NSObject {
    let item: NSMenuItem
    var onSelect: () -> Void = {}

    override init() {
        item = NSMenuItem(title: Textos.Menu.primerosPasos, action: #selector(selected), keyEquivalent: "")
        super.init()
        item.target = self
    }

    @objc private func selected() { onSelect() }
}

/// Every way to bring the onboarding window back after the first run: the
/// menu's "Primeros pasos…" and Ajustes' footer button. Both are plain shows:
/// neither consults the marker or the gate (the window is re-openable at any
/// time, with live state).
@MainActor
struct OnboardingReopen {
    /// The launcher's `show()`.
    let show: () -> Bool

    func fromMenu() { _ = show() }
    func fromAjustes() { _ = show() }
}
