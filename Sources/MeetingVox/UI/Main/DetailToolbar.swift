import SwiftUI

/// "Regenerar ▾", "Enviar a memoria ▾" and "⋯". It draws
/// `DetailActions` and forwards every choice to `SessionDetailModel`; which
/// items exist, and which are disabled, was decided there.
struct DetailToolbar: View {
    let actions: DetailActions
    let session: SessionDetailModel
    /// The row being drawn: every action acts on it, not on the selection.
    let dir: URL

    var body: some View {
        HStack(spacing: 6) {
            regenerateMenu
            if let memory = actions.memory { memoryMenu(memory) }
            overflowMenu
        }
    }

    // MARK: Regenerar ▾

    private var regenerateMenu: some View {
        menu(label: Textos.Principal.regenerar, chevron: true) {
            let regenerate = actions.regenerate
            if let retry = regenerate.retry {
                Button(Textos.Sesiones.reintentarMinuta) { session.retry(.minuta, dir: dir) }
                    .disabled(!retry.isEnabled)
                    .help(retry.tooltip ?? "")
                Divider()
            }
            if let choices = regenerate.regenerateWith {
                Menu(Textos.Sesiones.regenerarCon) {
                    templates(choices) { session.regenerate(templateID: $0, dir: dir) }
                }
            }
            Menu(Textos.Sesiones.generarCon) {
                templates(regenerate.generateWith) { session.generate(templateID: $0, dir: dir) }
            }
        }
    }

    @ViewBuilder
    private func templates(_ choices: DetailActions.TemplateChoices, pick: @escaping (String) -> Void) -> some View {
        switch choices {
        case .choices(let list):
            ForEach(list, id: \.id) { choice in
                Button(choice.title) { pick(choice.id) }.help(choice.tooltip ?? "")
            }
        case .unavailable(let reason):
            Button(reason) {}.disabled(true)
        }
    }

    // MARK: Enviar a memoria ▾

    private func memoryMenu(_ memory: DetailActions.Memory) -> some View {
        menu(label: memory.title, chevron: true) {
            if let banks = memory.banks {
                ForEach(banks, id: \.title) { bank in
                    Button {
                        session.chooseMemory(memory.action, bank: bank.bank, shownAs: memory.status, dir: dir)
                    } label: {
                        if bank.isDefault {
                            Label(bank.title, systemImage: "checkmark")
                        } else {
                            Text(bank.title)
                        }
                    }
                    .disabled(!memory.isEnabled)
                }
            } else {
                Button(memory.title) { session.chooseMemory(memory.action, bank: nil, shownAs: memory.status, dir: dir) }
                    .disabled(!memory.isEnabled)
            }
            if memory.canSkip {
                Divider()
                Button(Textos.Memoria.noEnviar) { session.skipMemory(dir: dir) }
            }
        }
    }

    // MARK: ⋯

    private var overflowMenu: some View {
        menu(label: "⋯", chevron: false) {
            ForEach(Array(actions.overflow.enumerated()), id: \.offset) { _, item in
                Button(item.title) { session.perform(item.kind, dir: dir) }.disabled(!item.isEnabled)
            }
        }
        .accessibilityLabel(Textos.Principal.masAcciones)
    }

    // MARK: Look

    private func menu<Content: View>(label: String, chevron: Bool, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            ToolbarButtonLabel(text: label, chevron: chevron)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// A bordered toolbar button face: text and, for menus, a small chevron.
struct ToolbarButtonLabel: View {
    let text: String
    let chevron: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            if chevron {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(MainPalette.muted)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(MainPalette.window))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(MainPalette.line))
    }
}
