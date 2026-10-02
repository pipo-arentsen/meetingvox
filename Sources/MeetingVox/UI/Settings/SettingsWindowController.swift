import AppKit
import SwiftUI

/// Owns the single, reusable settings window. The window is kept alive after
/// closing (`isReleasedWhenClosed = false`) so reopening is instant and keeps
/// the fetched model catalog.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model = SettingsModel()
    private let hindsight: HindsightSettingsModel
    private let calendar: CalendarSettingsModel
    private let onOpenOnboarding: () -> Void
    private let onOpenLibrary: () -> Void
    private var window: NSWindow?

    init(
        bankList: HindsightBankList, calendarSource: any CalendarSource, onOpenOnboarding: @escaping () -> Void = {},
        onOpenLibrary: @escaping () -> Void = {}
    ) {
        hindsight = HindsightSettingsModel(bankList: bankList)
        calendar = CalendarSettingsModel(configURL: Config.path, source: calendarSource)
        self.onOpenOnboarding = onOpenOnboarding
        self.onOpenLibrary = onOpenLibrary
        super.init()
    }

    /// Bring the window to the front. quill is an `.accessory` app (no Dock
    /// icon), so it is usually *not* the active app when the menu item is
    /// clicked; without an explicit activate the window opens behind
    /// whatever the user was using.
    func show() {
        let window = self.window ?? makeWindow()
        if self.window == nil {
            self.window = window
            window.center()
        } else {
            model.reload()
            hindsight.reload()
            Task { [calendar] in await calendar.refresh() }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Textos.Ajustes.tituloVentana
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 560, height: 500)
        window.contentView = NSHostingView(rootView: SettingsView(
            model: model, hindsight: hindsight, calendar: calendar, onOpenOnboarding: onOpenOnboarding, onOpenLibrary: onOpenLibrary
        ))
        window.setContentSize(NSSize(width: 640, height: 600))
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model.windowDidClose()
        hindsight.windowDidClose()
    }
}
