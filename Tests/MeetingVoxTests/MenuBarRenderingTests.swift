import AppKit
import Testing
@testable import MeetingVox

/// The AppKit half of the status menu: what `MenuBarController` makes of a
/// `MenuModel`. Builds the controller (an `NSStatusItem`, as
/// `OnboardingReopenTests` already does) but never shows the menu.
@MainActor
@Suite struct MenuBarRenderingTests {
    private func item(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    private func click(_ item: NSMenuItem) {
        _ = (item.target as AnyObject?)?.perform(item.action, with: item)
    }

    @Test func theToggleIsWiredAndClickingItCallsOnToggle() throws {
        let bar = MenuBarController()
        var toggles = 0
        bar.onToggle = { toggles += 1 }
        let toggle = try #require(item(Textos.Menu.iniciarGrabacion, in: bar.menu))
        #expect(toggle.target === bar)
        #expect(toggle.action != nil)
        #expect(toggle.keyEquivalent == "r")
        #expect(toggle.keyEquivalentModifierMask == [.command])
        #expect(toggle.isEnabled)
        click(toggle)
        #expect(toggles == 1)
    }

    @Test func theToggleIsTheFirstActionableItem() throws {
        let bar = MenuBarController()
        bar.updateTranscription("t")
        bar.updateHindsight("paused")
        let first = try #require(bar.menu.items.first { $0.action != nil })
        #expect(first.title == Textos.Menu.iniciarGrabacion)
    }

    @Test func aTickUpdatesTitlesInPlaceAndKeepsTheSameWiredItem() throws {
        let bar = MenuBarController()
        var toggles = 0
        bar.onToggle = { toggles += 1 }
        bar.update(recording: true, elapsed: "0:01", app: "Teams")
        let before = try #require(item(Textos.Menu.detenerGrabacion, in: bar.menu))
        #expect(bar.menu.items.first?.title == Textos.Menu.grabando("0:01", app: "Teams"))

        bar.update(recording: true, elapsed: "0:02", app: "Teams")
        let after = try #require(item(Textos.Menu.detenerGrabacion, in: bar.menu))
        #expect(after === before)
        #expect(bar.menu.items.first?.title == Textos.Menu.grabando("0:02", app: "Teams"))
        #expect(after.target === bar)
        click(after)
        #expect(toggles == 1)
    }

    @Test func theOptionAlternateFollowsOpenMainWithCommandOptionJ() throws {
        let bar = MenuBarController()
        var opened = 0, rebuilt = 0
        bar.onMainWindow = { opened += 1 }
        bar.onRebuildIndex = { rebuilt += 1 }
        let index = try #require(bar.menu.items.firstIndex { $0.title == Textos.Menu.abrirVentana })
        let main = bar.menu.items[index]
        let alternate = bar.menu.items[index + 1]
        #expect(main.isAlternate == false)
        #expect(main.keyEquivalent == "j")
        #expect(main.keyEquivalentModifierMask == [.command])
        #expect(alternate.title == Textos.Sesiones.reconstruirIndice)
        #expect(alternate.isAlternate)
        #expect(alternate.keyEquivalent == "j")
        #expect(alternate.keyEquivalentModifierMask == [.command, .option])
        click(main)
        click(alternate)
        #expect(opened == 1)
        #expect(rebuilt == 1)
    }

    @Test func theLastSessionIsReadWhenTheMenuOpensAndOpensItsMinutesTab() throws {
        let bar = MenuBarController()
        let dir = URL(fileURLWithPath: "/tmp/fixture/2026.09.29-1100")
        bar.lastSession = { MenuModel.Last(dir: dir, title: "Kickoff", hasMinutes: true) }
        var opened: [(URL, Bool)] = []
        bar.onOpenLast = { opened.append(($0, $1)) }
        #expect(item(Textos.Menu.ultima("Kickoff"), in: bar.menu) == nil)
        bar.menuNeedsUpdate(bar.menu)
        let last = try #require(item(Textos.Menu.ultima("Kickoff"), in: bar.menu))
        click(last)
        #expect(opened.count == 1)
        #expect(opened.first?.0 == dir)
        #expect(opened.first?.1 == true)
    }

    @Test func theTemplateSubmenuAppearsOnlyWhileRecordingWithMinutes() {
        let bar = MenuBarController()
        #expect(!bar.menu.items.contains { $0 === bar.sessionTemplate.item })
        bar.update(recording: true, elapsed: "0:01", showTemplateMenu: true)
        #expect(bar.menu.items.contains { $0 === bar.sessionTemplate.item })
        #expect(bar.sessionTemplate.item.isHidden == false)
        bar.update(recording: false, elapsed: nil)
        #expect(!bar.menu.items.contains { $0 === bar.sessionTemplate.item })
    }
}
