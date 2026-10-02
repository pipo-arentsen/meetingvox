import AppKit
import SwiftUI

/// The one persistent floating window of the pill (detected, recording,
/// silent-mic and ended faces), evolved from the old meeting prompt panel with
/// exactly its window rules. It must never steal focus from the meeting app:
/// - it is a `.nonactivatingPanel` and MeetingVox never calls `NSApp.activate()`
///   for it, so clicks work without making the app active;
/// - it can never become key (`PromptPanel.canBecomeKey` is false), so
///   keystrokes always stay with the meeting app. Mouse input needs no key
///   status: buttons take the first click (`acceptsFirstMouse`) and the
///   template picker is an `NSPopUpButton`, whose menu tracks in its own window;
/// - no button has a keyboard shortcut.
///
/// It lives on all Spaces and over full-screen apps, starts at the top right
/// of the menu-bar screen and is draggable; a dragged position is kept in
/// memory until quit (never written to disk). The size follows the face; the
/// top-right corner stays put.
@MainActor
final class RecordingPillPanel: PillPresenting {
    static let width: CGFloat = 320
    static let margin: CGFloat = 12

    private var panel: PromptPanel?
    private var hosting: FirstClickHostingView<RecordingPillView>?
    /// The top-right corner after a user drag; nil = the default corner.
    private var userAnchor: CGPoint?
    private var isRepositioning = false
    private var moveObserver: NSObjectProtocol?

    func show(_ model: PillViewModel) {
        let panel = self.panel ?? makePanel(model)
        refit(panel)
        // MeetingVox is an inactive accessory app; plain orderFront could leave
        // the pill behind. Neither call activates MeetingVox.
        panel.orderFrontRegardless()
        // SwiftUI applies the new face on the next transaction: measure again.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.refit(panel)
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Pure geometry (tested)

    /// The configured default when it exists, else `general`, else the first.
    static func initialSelection(templates: [MinutesTemplate]?, configured: String) -> String? {
        guard let templates, !templates.isEmpty else { return nil }
        let ids = templates.map(\.id)
        if ids.contains(configured) { return configured }
        if ids.contains(FactoryTemplates.general.id) { return FactoryTemplates.general.id }
        return ids.first
    }

    /// Top-right corner of the screen that holds the menu bar, below it.
    static func defaultAnchor(in visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: visibleFrame.maxX - margin, y: visibleFrame.maxY - margin)
    }

    /// Window origin for a top-right `anchor` and a window `size`.
    static func origin(anchor: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: anchor.x - size.width, y: anchor.y - size.height)
    }

    /// A dragged anchor stays while it lies on a live screen; after a display
    /// change that left it off every screen, the first screen's default corner.
    static func clamped(_ anchor: CGPoint, screens: [CGRect]) -> CGPoint {
        let onScreen = screens.contains {
            anchor.x >= $0.minX && anchor.x <= $0.maxX && anchor.y >= $0.minY && anchor.y <= $0.maxY
        }
        if onScreen { return anchor }
        return screens.first.map(defaultAnchor(in:)) ?? anchor
    }

    // MARK: - Window

    private func makePanel(_ model: PillViewModel) -> PromptPanel {
        let panel = PromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true // belt and braces with canBecomeKey
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        let hosting = FirstClickHostingView(rootView: RecordingPillView(model: model))
        panel.contentView = hosting
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelMoved() }
        }
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    /// Re-measure the face and keep the top-right corner where it is.
    private func refit(_ panel: PromptPanel) {
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        isRepositioning = true
        defer { isRepositioning = false }
        panel.setContentSize(hosting.fittingSize)
        panel.setFrameOrigin(Self.origin(anchor: currentAnchor(), size: panel.frame.size))
    }

    private func currentAnchor() -> CGPoint {
        let screens = NSScreen.screens.map(\.visibleFrame)
        if let userAnchor { return Self.clamped(userAnchor, screens: screens) }
        guard let first = screens.first else { return .zero }
        return Self.defaultAnchor(in: first)
    }

    /// Only the user's drag counts: `refit` moves the window too.
    private func panelMoved() {
        guard !isRepositioning, let panel else { return }
        userAnchor = CGPoint(x: panel.frame.maxX, y: panel.frame.maxY)
    }
}

/// Never key, never main: the panel must not take the keyboard from the
/// meeting app (a `.titled` non-activating panel could otherwise become key
/// on a click or drag, and then keep it after the picker menu closes).
final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// MeetingVox is never the active app when the pill shows; accepting the first
/// mouse makes one click press a pill button instead of just focusing the pill.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
