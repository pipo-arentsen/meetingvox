import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no Dock icon — except while the main
/// window or onboarding is open).
///
/// One level, no session submenus: `MenuModel` decides what is listed, this
/// class renders it and routes the clicks. Titles that tick (the elapsed
/// time) are updated in place; anything that changes the menu's shape
/// rebuilds it.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    let menu = NSMenu()

    /// What the model is built from; every `update…` mutates it and renders.
    private var input = MenuModel.Input()
    private var rendered: [MenuModel.Entry] = []
    /// The `NSMenuItem` of each rendered entry (nil for separators).
    private var renderedItems: [NSMenuItem?] = []

    /// "Plantilla de la minuta ▸" for the live recording; the model lists it
    /// only while recording with minutes enabled.
    let sessionTemplate = SessionTemplateMenu()

    /// The newest session, read each time the menu opens.
    var lastSession: (() -> MenuModel.Last?)?

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onSettings: (() -> Void)?
    var onOnboarding: (() -> Void)?
    /// "Abrir MeetingVox" (⌘J): the main window.
    var onMainWindow: (() -> Void)?
    /// "Reconstruir índice": the ⌥ alternate of "Abrir MeetingVox".
    var onRebuildIndex: (() -> Void)?
    /// "Última: <título>": the session, on its Minuta tab when it has one.
    var onOpenLast: ((_ dir: URL, _ hasMinutes: Bool) -> Void)?
    var onQuit: (() -> Void)?
    /// "Primeros pasos…"; its target lives apart so the wiring is testable.
    let onboardingEntry = OnboardingMenuItem()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        render()

        if let button = statusItem.button {
            let image = AppGlyph.feather()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
        onboardingEntry.onSelect = { [weak self] in self?.onOnboarding?() }
    }

    /// Reflect recording state in the icon tint, the elapsed time next to the
    /// feather (monospaced digits, so the item doesn't jitter as it ticks;
    /// feather only when idle) and the menu. Call once a second while
    /// recording. `app` = the meeting app's short name, when known.
    func update(recording: Bool, elapsed: String?, showTemplateMenu: Bool = false, app: String? = nil) {
        input.recording = recording ? MenuModel.Recording(elapsed: elapsed ?? "0:00", app: app) : nil
        input.offersTemplate = showTemplateMenu
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
        statusItem.button?.attributedTitle = Self.elapsedTitle(recording ? (elapsed ?? "0:00") : nil)
            ?? NSAttributedString(string: "")
        render()
    }

    /// The status item's text while recording: a gap then the elapsed time in
    /// monospaced digits; nil when not recording (feather only). Pure.
    static func elapsedTitle(_ elapsed: String?) -> NSAttributedString? {
        guard let elapsed else { return nil }
        return NSAttributedString(string: " \(elapsed)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ])
    }

    /// Show transcription progress/failure as a processing line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        input.transcription = text
        render()
    }

    /// Minutes progress/failure as its own line (nil hides it), so a slow LLM
    /// call never hides the transcription state or vice versa.
    func updateMinutes(_ text: String?) {
        input.minutes = text
        render()
    }

    /// Summary progress/failure as its own line (nil hides it), for the same
    /// reason as minutes: each pipeline stage reports on its own line.
    func updateSummary(_ text: String?) {
        input.summary = text
        render()
    }

    /// Hindsight export paused on a rejected token: `text` non-nil shows the
    /// "Token de Hindsight inválido" line, nil hides it.
    func updateHindsight(_ text: String?) {
        input.tokenInvalid = text != nil
        render()
    }

    // MARK: - NSMenuDelegate

    /// The last session comes from disk, so it is re-read every time the
    /// menu opens (no timer).
    func menuNeedsUpdate(_ menu: NSMenu) {
        input.last = lastSession?()
        render()
    }

    // MARK: - Rendering

    private func render() {
        let entries = MenuModel.build(input)
        if MenuModel.shape(rendered) == MenuModel.shape(entries), renderedItems.count == entries.count {
            // Same items, maybe other titles (the elapsed time ticking).
            for (entry, item) in zip(entries, renderedItems) {
                guard case .item(let model) = entry, let item, item.title != model.title,
                      model.command != .template, model.command != .onboarding
                else { continue }
                item.title = model.title
            }
            rendered = entries
            return
        }
        menu.removeAllItems()
        renderedItems = entries.map { entry in
            switch entry {
            case .separator:
                menu.addItem(.separator())
                return nil
            case .item(let model):
                let item = makeItem(model)
                menu.addItem(item)
                return item
            }
        }
        rendered = entries
    }

    private func makeItem(_ model: MenuModel.Item) -> NSMenuItem {
        switch model.command {
        case .template:
            sessionTemplate.item.isHidden = false
            return sessionTemplate.item
        case .onboarding:
            return onboardingEntry.item
        default:
            break
        }
        let item = NSMenuItem(
            title: model.title, action: model.command == .info ? nil : #selector(itemClicked(_:)),
            keyEquivalent: model.shortcut?.key ?? ""
        )
        item.target = self
        item.isEnabled = model.isEnabled
        if let shortcut = model.shortcut {
            item.keyEquivalentModifierMask = shortcut.option ? [.command, .option] : [.command]
        }
        item.isAlternate = model.isAlternate
        item.representedObject = CommandBox(model.command)
        return item
    }

    private final class CommandBox: NSObject {
        let command: MenuModel.Command
        init(_ command: MenuModel.Command) { self.command = command }
    }

    @objc private func itemClicked(_ sender: NSMenuItem) {
        guard let command = (sender.representedObject as? CommandBox)?.command else { return }
        switch command {
        case .toggleRecording: onToggle?()
        case .openLast(let dir, let hasMinutes): onOpenLast?(dir, hasMinutes)
        case .openMainWindow: onMainWindow?()
        case .rebuildIndex: onRebuildIndex?()
        case .openFolder: onOpenFolder?()
        case .settings: onSettings?()
        case .quit: onQuit?()
        case .info, .template, .onboarding: break
        }
    }
}

/// Template picker for the recording in progress. Its submenu is rebuilt
/// each time it opens (own delegate), so edits to the templates folder and
/// the config default show up without a timer.
@MainActor
final class SessionTemplateMenu: NSObject, NSMenuDelegate {
    let item = NSMenuItem(title: Textos.Menu.plantillaMinuta, action: nil, keyEquivalent: "")
    private let submenu = NSMenu()

    /// Templates to list and the id to check (session choice, else config).
    var source: (() -> (templates: [MinutesTemplate], current: String))?
    var onSelect: ((String) -> Void)?

    override init() {
        super.init()
        submenu.autoenablesItems = false
        submenu.delegate = self
        item.submenu = submenu
        item.isHidden = true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let (templates, current) = source?() else { return }
        if templates.isEmpty {
            let empty = NSMenuItem(title: Textos.Menu.sinPlantillas, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for template in templates {
            let entry = NSMenuItem(title: template.nombre, action: #selector(selected(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = template.id
            entry.state = template.id == current ? .on : .off
            menu.addItem(entry)
        }
    }

    @objc private func selected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelect?(id)
    }
}
