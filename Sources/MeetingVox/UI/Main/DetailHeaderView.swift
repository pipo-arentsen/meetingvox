import SwiftUI

/// The session detail's header: a 21 pt bold title with the toolbar on
/// its right, the meta line, and the chips — ámbito (a menu that classifies),
/// cliente and Pistas.
struct DetailHeaderView: View {
    let header: DetailHeader
    let actions: DetailActions
    let session: SessionDetailModel
    let dir: URL
    let classify: (Ambito?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Text(header.title)
                    .font(.system(size: 21, weight: .bold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DetailToolbar(actions: actions, session: session, dir: dir)
            }
            Text(header.meta)
                .font(.system(size: 12))
                .foregroundStyle(MainPalette.muted)
                .lineLimit(1)
            HStack(spacing: 6) {
                ambitoChip
                if let client = header.client { chip { Text(client) } }
                if let pistas = header.pistas { chip { Text(pistas) } }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    /// The ámbito as a menu chip: a dot in its colour, the name, a chevron.
    private var ambitoChip: some View {
        Menu {
            ForEach(Ambito.allCases, id: \.self) { ambito in
                Button(ambito.label) { classify(ambito) }
            }
            Divider()
            Button(Textos.Indice.sinClasificar) { classify(nil) }
        } label: {
            chip {
                Circle().fill(MainPalette.dot(for: header.ambito)).frame(width: 6, height: 6)
                Text(header.ambito?.label ?? Textos.Indice.sinClasificar)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(MainPalette.muted)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(Textos.Principal.clasificarAmbito)
        .accessibilityValue(header.ambito?.label ?? Textos.Indice.sinClasificar)
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) { content() }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(MainPalette.sunken))
    }
}
