import SwiftUI

/// The confirmation sheet of "Mover a la papelera…": how many sessions go,
/// which ones are skipped and why, and — only when some session reached
/// Hindsight — the opt-in (default off) to delete it from memory too. It
/// draws a `TrashPlan`; nothing moves until "Mover a la papelera".
struct TrashConfirmationView: View {
    let plan: TrashPlan
    /// A session's one-line name (title, else folder).
    let label: (URL) -> String
    let cancel: () -> Void
    let confirm: (_ deleteFromMemory: Bool) -> Void

    @State private var deleteFromMemory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if plan.trashable.isEmpty {
                Text(Textos.Papelera.ningunaSePuede).font(.system(size: 15, weight: .bold))
            } else {
                Text(Textos.Papelera.titulo(plan.trashable.count)).font(.system(size: 15, weight: .bold))
                Text(Textos.Papelera.detalle(plan.trashable.count))
                    .font(.system(size: 12))
                    .foregroundStyle(MainPalette.muted)
            }
            if !plan.blocked.isEmpty { blockedList }
            if plan.offersMemoryDelete { memoryOption }
            HStack {
                Spacer()
                if plan.trashable.isEmpty {
                    Button(Textos.Papelera.entendido, action: cancel).keyboardShortcut(.defaultAction)
                } else {
                    Button(Textos.Papelera.cancelar, action: cancel).keyboardShortcut(.cancelAction)
                    Button(Textos.Papelera.confirmar) { confirm(deleteFromMemory) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(MainPalette.window)
    }

    private var blockedList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Textos.Papelera.omitidas).font(.system(size: 12, weight: .semibold))
            ForEach(plan.blocked, id: \.dir) { item in
                Text("\(label(item.dir)) — \(Textos.Papelera.motivo(item.reason))")
                    .font(.system(size: 12))
                    .foregroundStyle(MainPalette.muted)
                    .lineLimit(2)
            }
        }
    }

    private var memoryOption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(Textos.Papelera.memoriaCasilla, isOn: $deleteFromMemory)
                .toggleStyle(.checkbox)
            Text(Textos.Papelera.memoriaNota)
                .font(.system(size: 11))
                .foregroundStyle(MainPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }
}
