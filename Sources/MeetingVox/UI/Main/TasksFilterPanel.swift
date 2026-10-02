import SwiftUI

/// The Tareas page's list column: title and note, the search, the owner
/// filter, the counter and — while some summaries still lack tasks — a hint
/// about "Reconstruir índice". Draws `TasksPageModel`; touches no config.
struct TasksFilterPanel: View {
    @Bindable var model: TasksPageModel

    /// The column is a `ScrollView`: a split view measures its columns at
    /// their minimum width, where the wrapped note (`fixedSize` vertical) is
    /// thousands of points tall; unscrolled, that height pushed the whole
    /// window's content off screen.
    var body: some View {
        ScrollView(.vertical) {
            panel
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(MainPalette.window)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Textos.Tareas.titulo)
                .font(.system(size: 20, weight: .bold))
            Text(Textos.Tareas.nota)
                .font(.system(size: 12))
                .foregroundStyle(MainPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(MainPalette.muted)
                TextField(Textos.Tareas.buscar, text: $model.query)
                    .textFieldStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(MainPalette.sunken))
            HStack {
                Text(Textos.Tareas.responsable)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker(Textos.Tareas.responsable, selection: $model.who) {
                    Text(Textos.Tareas.todos).tag(TaskWhoFilter.all)
                    Text(Textos.Tareas.sinResponsable).tag(TaskWhoFilter.unassigned)
                    if !model.whoOptions.isEmpty { Divider() }
                    ForEach(model.whoChoices, id: \.self) { name in
                        Text(name).tag(TaskWhoFilter.person(name))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                Text(model.counter)
                    .font(.system(size: 11))
                    .foregroundStyle(MainPalette.muted)
                Spacer()
                if model.isFiltering {
                    Button(Textos.Tareas.quitarFiltros) { model.clearFilters() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
            if model.notExtractedCount > 0 {
                Label(Textos.Tareas.sinExtraer(model.notExtractedCount), systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(MainPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
