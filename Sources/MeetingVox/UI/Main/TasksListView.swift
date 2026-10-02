import SwiftUI

/// The Tareas page's detail column: every task, newest meeting first, or the
/// reason there is none. Each row links to its meeting (Resumen tab).
struct TasksListView: View {
    @Bindable var model: TasksPageModel
    let timeZone: TimeZone

    var body: some View {
        Group {
            if let empty = model.emptyState {
                emptyView(empty)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.visible) { row in
                            TaskRowView(row: row, timeZone: timeZone) { model.open(row) }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MainPalette.window)
    }

    private func emptyView(_ state: TasksEmptyState) -> some View {
        VStack(spacing: 6) {
            switch state {
            case .loading:
                Text(Textos.Tareas.cargando).foregroundStyle(MainPalette.muted)
            case .noTasks:
                Text(Textos.Tareas.vacioTitulo).font(.system(size: 15, weight: .semibold))
                Text(Textos.Tareas.vacioDetalle)
                    .font(.system(size: 12))
                    .foregroundStyle(MainPalette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            case .noMatches:
                Text(Textos.Tareas.sinCoincidencias).foregroundStyle(MainPalette.muted)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One task: the action, the owner and deadline, and the meeting it came from
/// as a link.
private struct TaskRowView: View {
    let row: TaskRow
    let timeZone: TimeZone
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.task.what)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let who = row.task.who, !who.isEmpty {
                    Text(who).font(.system(size: 11, weight: .semibold))
                } else {
                    Text(Textos.Tareas.sinResponsable).font(.system(size: 11)).foregroundStyle(MainPalette.muted)
                }
                if let when = row.task.when, !when.isEmpty {
                    Text(Textos.Tareas.para(when)).font(.system(size: 11)).foregroundStyle(MainPalette.muted)
                }
                Spacer(minLength: 8)
                Button(action: open) {
                    Text(linkText)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.link)
                .accessibilityLabel(Textos.Tareas.abrirReunion(row.meetingTitle))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var linkText: String {
        [row.meetingTitle, row.dayText(timeZone: timeZone)].compactMap { $0 }.joined(separator: " · ")
    }
}
