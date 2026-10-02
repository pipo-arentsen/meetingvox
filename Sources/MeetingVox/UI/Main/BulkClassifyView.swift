import SwiftUI

/// The detail area while 2+ visible rows are selected: "N
/// seleccionadas" and "Clasificar como" Trabajo / Profesional / Personal /
/// Sin clasificar. Only writes meta.json `ambito`, through the model.
struct BulkClassifyView: View {
    let title: String
    let classify: (Ambito?) -> Void
    let moveToTrash: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(MainPalette.muted)
            Text(title)
                .font(.system(size: 20, weight: .bold))
            Text(Textos.Indice.clasificarComo)
                .font(.system(size: 12))
                .foregroundStyle(MainPalette.muted)
            HStack(spacing: 10) {
                ForEach(Ambito.allCases, id: \.self) { ambito in
                    choice(ambito.label, dot: MainPalette.dot(for: ambito)) { classify(ambito) }
                }
                choice(Textos.Indice.sinClasificar, dot: MainPalette.dot(for: nil)) { classify(nil) }
            }
            Button(Textos.Papelera.mover, role: .destructive, action: moveToTrash)
                .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MainPalette.window)
    }

    private func choice(_ label: String, dot: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(label)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(MainPalette.sunken))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(MainPalette.line))
        }
        .buttonStyle(.plain)
    }
}
