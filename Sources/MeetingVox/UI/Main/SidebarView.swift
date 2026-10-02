import SwiftUI

/// The main window's sidebar: Reuniones with the total, Tareas
/// (the tasks page), the ámbito filters with their counts, Biblioteca, and the
/// privacy footer. Solid rows rather than a native sidebar `List` so it draws
/// the same live and in the headless snapshots.
struct SidebarView: View {
    @Bindable var model: MainWindowModel

    var body: some View {
        let counts = model.counts
        VStack(alignment: .leading, spacing: 2) {
            row(.reuniones, count: counts.count(.all))
            row(.tareas, count: nil)

            header(Textos.Principal.ambito)
            ForEach(SidebarItem.ambitoItems, id: \.self) { item in
                row(item, dot: dotAmbito(item), count: item.ambitoFilter.map(counts.count))
            }

            header(Textos.Principal.biblioteca)
            ForEach(SidebarItem.bibliotecaItems, id: \.self) { item in
                row(item, count: nil)
            }

            Spacer(minLength: 12)
            Divider()
            HStack(spacing: 6) {
                Circle().fill(MainPalette.ok).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(Textos.Principal.audioNoSale)
            }
            .font(.system(size: 11))
            .foregroundStyle(MainPalette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(MainPalette.side)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MainPalette.muted)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func dotAmbito(_ item: SidebarItem) -> Color {
        if case .ambito(let ambito) = item { return MainPalette.dot(for: ambito) }
        return MainPalette.dot(for: nil)
    }

    private func row(_ item: SidebarItem, dot: Color? = nil, count: Int?) -> some View {
        Button {
            model.sidebar = item
        } label: {
            HStack(spacing: 8) {
                if let dot {
                    Circle().fill(dot).frame(width: 8, height: 8).frame(width: 14)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: item.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(MainPalette.muted)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                }
                Text(item.label)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(MainPalette.muted)
                }
            }
            .font(.system(size: 13, weight: model.sidebar == item ? .semibold : .regular))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(model.sidebar == item ? MainPalette.selection : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.sidebar == item ? .isSelected : [])
    }
}
