import AppKit

/// Where the main menu's own commands go. A class because `NSMenuItem.target`
/// is not retained: whoever installs the menu keeps this alive (`MainMenu`
/// holds the installed one), and tests build one to call the items directly.
@MainActor
final class MainMenuActions: NSObject {
    private let requestQuit: @MainActor () -> Void
    private let openSettings: @MainActor () -> Void

    init(requestQuit: @escaping @MainActor () -> Void, openSettings: @escaping @MainActor () -> Void) {
        self.requestQuit = requestQuit
        self.openSettings = openSettings
    }

    @objc func quit(_ sender: Any?) { requestQuit() }
    @objc func settings(_ sender: Any?) { openSettings() }
}

/// The main menu. The app is `.accessory` most of the time, so it is never
/// visible then, but AppKit routes key equivalents through `NSApp.mainMenu`:
/// without it ⌘V does nothing in the settings window and the API key can't be
/// pasted. While the main window is open the app is `.regular` and this is
/// the menu bar the user sees.
///
/// ⌘Q and Salir do not call `NSApp.terminate` themselves: they go to
/// `AppController.requestQuit`, which asks "¿Detener y salir?" while a
/// recording is in progress and only then terminates (through
/// `AppDelegate.applicationShouldTerminate`, which still finalizes the
/// recording). That is what makes a stray ⌘Q safe to offer.
enum MainMenu {
    /// The installed menu's targets, kept alive for as long as the menu is.
    @MainActor private static var installedActions: MainMenuActions?

    @MainActor
    static func install(requestQuit: @escaping @MainActor () -> Void, openSettings: @escaping @MainActor () -> Void) {
        let actions = MainMenuActions(requestQuit: requestQuit, openSettings: openSettings)
        installedActions = actions
        NSApp.mainMenu = build(actions: actions)
    }

    @MainActor
    static func build(actions: MainMenuActions) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: AppIdentity.displayName)
        let settings = appMenu.addItem(
            withTitle: Textos.MenuPrincipal.ajustes, action: #selector(MainMenuActions.settings(_:)), keyEquivalent: ","
        )
        settings.target = actions
        appMenu.addItem(
            withTitle: Textos.MenuPrincipal.cerrarVentana,
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(
            withTitle: Textos.MenuPrincipal.salir, action: #selector(MainMenuActions.quit(_:)), keyEquivalent: "q"
        )
        quit.target = actions
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: Textos.MenuPrincipal.edicion)
        edit.addItem(withTitle: Textos.MenuPrincipal.deshacer, action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: Textos.MenuPrincipal.rehacer, action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: Textos.MenuPrincipal.cortar, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: Textos.MenuPrincipal.copiar, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: Textos.MenuPrincipal.pegar, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: Textos.MenuPrincipal.seleccionarTodo, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        return main
    }
}
