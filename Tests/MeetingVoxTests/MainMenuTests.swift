import AppKit
import Testing

@testable import MeetingVox

/// The invisible-until-`.regular` main menu: ⌘Q and ⌘, must reach the app
/// controller (never `NSApp.terminate` directly, or a recording would end
/// without the confirmation), and the text-editing shortcuts must survive.
@MainActor
@Suite("MainMenu")
struct MainMenuTests {
    private final class Calls {
        var quit = 0
        var settings = 0
    }

    private func make() -> (menu: NSMenu, actions: MainMenuActions, calls: Calls) {
        let calls = Calls()
        let actions = MainMenuActions(requestQuit: { calls.quit += 1 }, openSettings: { calls.settings += 1 })
        return (MainMenu.build(actions: actions), actions, calls)
    }

    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(allItems) ?? []) }
    }

    private func item(_ menu: NSMenu, key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem? {
        allItems(menu).first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }
    }

    @Test func salirIsCommandQAndGoesThroughRequestQuit() throws {
        let (menu, actions, calls) = make()
        let quit = try #require(item(menu, key: "q"))

        #expect(quit.title == Textos.MenuPrincipal.salir)
        #expect(quit.target === actions)
        #expect(quit.action != #selector(NSApplication.terminate(_:)), "must ask first, never terminate directly")

        _ = quit.target?.perform(quit.action, with: quit)
        #expect(calls.quit == 1)
        #expect(calls.settings == 0)
    }

    @Test func ajustesIsCommandCommaAndOpensSettings() throws {
        let (menu, actions, calls) = make()
        let settings = try #require(item(menu, key: ","))

        #expect(settings.title == Textos.MenuPrincipal.ajustes)
        #expect(settings.target === actions)

        _ = settings.target?.perform(settings.action, with: settings)
        #expect(calls.settings == 1)
        #expect(calls.quit == 0)
    }

    @Test func closeWindowStaysOnTheResponderChain() throws {
        let (menu, _, _) = make()
        let close = try #require(item(menu, key: "w"))
        #expect(close.action == #selector(NSWindow.performClose(_:)))
        #expect(close.target == nil)
    }

    @Test func theTextEditingShortcutsSurvive() {
        let (menu, _, _) = make()
        for key in ["x", "c", "v", "a", "z"] {
            #expect(item(menu, key: key) != nil, "⌘\(key) missing")
        }
        #expect(item(menu, key: "z", modifiers: [.command, .shift]) != nil)
    }

    @Test func salirAndAjustesLiveInTheAppMenuSoTheMenuBarShowsThem() {
        let (menu, _, _) = make()
        let appMenu = menu.items.first?.submenu
        let titles = appMenu?.items.map(\.title) ?? []
        #expect(titles.contains(Textos.MenuPrincipal.ajustes))
        #expect(titles.contains(Textos.MenuPrincipal.salir))
        // Salir is the last entry, after a separator.
        #expect(titles.last == Textos.MenuPrincipal.salir)
    }
}
