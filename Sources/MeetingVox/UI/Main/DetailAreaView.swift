import SwiftUI

/// The detail column: an invitation with no selection, the bulk panel with 2+
/// selected rows, and the session detail for one. It switches on
/// `DetailSelection`, which carries what each case needs.
struct DetailAreaView: View {
    @Bindable var model: MainWindowModel

    var body: some View {
        switch model.detail {
        case .none:
            note(title: Textos.Principal.elegirReunion, detail: Textos.Principal.elegirReunionDetalle)
                .onAppear { model.session.select(nil) }
        case .single(let entry):
            SessionDetailView(model: model, entry: entry)
        case .bulk(let count):
            BulkClassifyView(
                title: Textos.Indice.seleccionadas(count),
                classify: { model.classifySelected(as: $0) },
                moveToTrash: { model.requestTrash(model.bulkTargets) }
            )
                .onAppear { model.session.select(nil) }
        }
    }

    private func note(title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(MainPalette.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MainPalette.window)
    }
}
