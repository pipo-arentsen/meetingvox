import SwiftUI

/// The list column: search and a compact "Filtros" menu, the sections
/// (Hoy, Ayer, weekdays, months), and the "N de M reuniones" footer with
/// "Meses anteriores" paging. Rows can be multi-selected (⌘/⇧-click) for the
/// bulk panel.
struct MeetingListView: View {
    @Bindable var model: MainWindowModel

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if let empty = model.emptyState {
                EmptyListView(state: empty)
            } else {
                list
            }
            Divider()
            footer
        }
        .background(MainPalette.window)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(MainPalette.muted)
                TextField(Textos.Principal.buscar, text: Bindable(model.meetings).query)
                    .textFieldStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(MainPalette.sunken))
            FiltersMenu(model: model.meetings)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            sectionedList
                // "Abrir"/"Ver reunión": bring the focused row into view — on
                // change, and on appear for a list that came into being with
                // the target already set (the window's first opening).
                .onChange(of: model.meetings.scrollTarget) { _, _ in scrollToFocus(proxy) }
                .onAppear { Task { @MainActor in scrollToFocus(proxy) } }
        }
    }

    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let target = model.meetings.scrollTarget else { return }
        proxy.scrollTo(target, anchor: .center)
        model.meetings.consumeScrollTarget()
    }

    private var sectionedList: some View {
        List(selection: Bindable(model.meetings).selection) {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        let hit = model.meetings.searchHit(for: entry)
                        MeetingRowView(
                            entry: entry, pill: model.pill(for: entry), timeZone: model.timeZone,
                            hit: hit, onOpenHit: hit.map { hit in { model.openSearchHit(entry.dir, hit) } }
                        )
                        .tag(entry.dir)
                    }
                } header: {
                    Text(section.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MainPalette.muted)
                }
            }
        }
        .listStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Text(model.footer)
                .font(.system(size: 11))
                .foregroundStyle(MainPalette.muted)
            Spacer()
            if model.meetings.canLoadOlder {
                Button(Textos.Principal.mesesAnteriores) { model.meetings.loadOlder() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The "Filtros" menu: client, tipo and rango (no filter the old main window
/// had is lost). The ámbito lives in the sidebar. The button shows a dot
/// while any of them narrows the list.
private struct FiltersMenu: View {
    @Bindable var model: MeetingsModel

    private var isFiltering: Bool {
        model.selectedClient != nil || model.typeFilter != nil || model.range != .any
    }

    var body: some View {
        Menu {
            Picker(Textos.Indice.cliente, selection: $model.selectedClient) {
                Text(Textos.Indice.todosLosClientes).tag(String?.none)
                ForEach(model.clients, id: \.self) { client in
                    Text(client).tag(String?.some(client))
                }
            }
            Picker(Textos.Indice.tipo, selection: $model.typeFilter) {
                Text(Textos.Indice.todosLosTipos).tag(MeetingType?.none)
                ForEach(model.types, id: \.self) { type in
                    Text(type.label(templates: model.templates)).tag(MeetingType?.some(type))
                }
            }
            Picker(Textos.Indice.periodo, selection: $model.range) {
                Text(Textos.Indice.cualquierFecha).tag(MeetingFilter.Range.any)
                Text(Textos.Indice.ultimos7Dias).tag(MeetingFilter.Range.last7Days)
                Text(Textos.Indice.esteMes).tag(MeetingFilter.Range.thisMonth)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(Textos.Principal.filtros)
                if isFiltering {
                    Circle().fill(MainPalette.accent).frame(width: 6, height: 6)
                }
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// The list column when there is nothing to draw.
struct EmptyListView: View {
    let state: ListEmptyState

    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(state.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state == .noMatches ? MainPalette.muted : .primary)
            if let detail = state.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(MainPalette.muted)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}
