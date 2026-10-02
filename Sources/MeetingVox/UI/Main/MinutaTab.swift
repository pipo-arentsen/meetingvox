import SwiftUI

/// The Minuta tab (DT-2): `minuta.md` rendered (Markdown, at
/// `MarkdownDocumentView.readingWidth`), a progress bar while a job runs, "Reintentar" for minutes still
/// owed, or the template picker with "Generar minuta". It draws
/// `MinutaTabState` and decides nothing; the folder's row identity
/// (`.id(dir)` at the call site) resets the picker between sessions.
struct MinutaTab: View {
    let state: MinutaTabState
    /// `minuta.md` as read off the main thread; nil until then.
    let text: String?
    /// The session's data has arrived (a nil `text` then means unreadable).
    let loaded: Bool
    let templates: [MinutesTemplate]
    /// Where the picker starts (`MinutaTabState.initialTemplate`).
    let initialTemplate: String?
    let onRetry: () -> Void
    let onGenerate: (String) -> Void

    @State private var choice: String?

    var body: some View {
        switch state {
        case .document(let regenerating):
            VStack(spacing: 0) {
                if regenerating { progressBar(Textos.Principal.minutaRegenerando) }
                document
            }
        case .running(let waitingRetry):
            VStack(spacing: 0) {
                progressBar(waitingRetry ? Textos.Principal.minutaEsperandoReintento : Textos.Principal.minutaGenerando)
                Spacer(minLength: 0)
            }
        case .retry(let failed, let reason):
            VStack(spacing: 0) {
                retryBar(failed: failed, reason: reason)
                Spacer(minLength: 0)
            }
        case .generate(let reason):
            generateCard(reason: reason)
        case .noTranscript:
            TabNote(text: Textos.Principal.minutaSinTranscripcion)
        }
    }

    // MARK: - Document

    @ViewBuilder private var document: some View {
        if let text {
            ScrollView {
                MarkdownDocumentView(text: text)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if loaded {
            TabNote(text: Textos.Principal.minutaSinLeer)
        } else {
            TabNote(text: Textos.Principal.cargandoDetalle)
        }
    }

    // MARK: - Bars

    private func progressBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            SpinnerView(diameter: 12).foregroundStyle(MainPalette.accent)
            Text(message).font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(MainPalette.accentBackground)
        .accessibilityElement(children: .combine)
    }

    private func retryBar(failed: Bool, reason: String?) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(failed ? Textos.Principal.minutaFallo : Textos.Principal.minutaPendiente)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(failed ? MainPalette.error : Color.primary)
                if let reason {
                    Text(reason).font(.system(size: 11)).foregroundStyle(MainPalette.muted)
                }
            }
            Spacer(minLength: 0)
            Button(Textos.Principal.reintentarPaso, action: onRetry)
                .disabled(reason != nil)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(failed ? MainPalette.errorBackground : MainPalette.accentBackground)
    }

    // MARK: - Generar

    private func generateCard(reason: String?) -> some View {
        let selected = choice ?? initialTemplate
        return VStack(spacing: 14) {
            Text(Textos.Principal.minutaSinCrear)
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 8) {
                Text(Textos.Principal.minutaPlantilla)
                    .font(.system(size: 12))
                    .foregroundStyle(MainPalette.muted)
                Picker(Textos.Principal.minutaPlantilla, selection: Binding(get: { selected }, set: { choice = $0 })) {
                    ForEach(templates, id: \.id) { Text($0.nombre).tag(String?.some($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(templates.isEmpty || reason != nil)
            }
            Button(Textos.Principal.generarMinuta) {
                if let selected { onGenerate(selected) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected == nil || reason != nil)
            if let reason {
                Text(reason).font(.system(size: 12)).foregroundStyle(MainPalette.muted)
            } else if templates.isEmpty {
                Text(Textos.Sesiones.sinPlantillas).font(.system(size: 12)).foregroundStyle(MainPalette.muted)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
