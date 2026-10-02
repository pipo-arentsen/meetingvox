import SwiftUI

/// Biblioteca > Plantillas, detail column (LE-1, LE-2): the selected file as
/// raw markdown next to a preview of what it will read like, with explicit
/// Save and Revert, "Restaurar de fábrica" for the shipped ids only, and the
/// banners the model's state calls for (invalid bytes, file changed on disk
/// with "Recargar", a failed write). It draws `TemplateEditorModel` and
/// decides nothing.
struct TemplatesEditorView: View {
    @Bindable var model: TemplateEditorModel
    @State private var confirmRestore = false
    /// The text the preview shows: it trails typing by `previewDelay`, so a
    /// long prompt is not re-parsed on every keystroke.
    @State private var previewText = ""
    @State private var previewID: String?

    static let previewDelay: Duration = .milliseconds(200)

    var body: some View {
        Group {
            if let id = model.selectedID {
                VStack(spacing: 0) {
                    header(id)
                    Divider()
                    banners
                    panes
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MainPalette.window)
    }

    // MARK: - Header

    private func header(_ id: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.files.first { $0.id == id }?.title ?? id)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(id + "." + TemplateStore.fileExtension)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(MainPalette.muted)
            }
            if model.isDirty {
                Text(Textos.Biblioteca.sinGuardar)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .foregroundStyle(MainPalette.high)
                    .background(Capsule().fill(MainPalette.sunken))
            }
            Spacer(minLength: 8)
            if model.isFactory {
                Button(Textos.Biblioteca.restaurarFabrica) { confirmRestore = true }
            }
            Button(Textos.Biblioteca.revertir) { model.revert() }
                .disabled(!model.isDirty)
            Button(Textos.Biblioteca.guardar) { model.save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canSave)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .alert(Textos.Biblioteca.restaurarTitulo, isPresented: $confirmRestore) {
            Button(Textos.Biblioteca.restaurar, role: .destructive) { model.restoreFactory() }
            Button(Textos.Biblioteca.cancelar, role: .cancel) {}
        } message: {
            Text(Textos.Biblioteca.restaurarMensaje)
        }
    }

    // MARK: - Banners

    @ViewBuilder private var banners: some View {
        if model.conflict {
            banner(
                Textos.Biblioteca.archivoCambio, detail: Textos.Biblioteca.archivoCambioDetalle,
                action: (Textos.Biblioteca.recargar, model.reloadFromDisk)
            )
        } else if let failure = model.failure {
            banner(failure.message, detail: nil, action: nil)
        }
        if let readError = model.readError {
            banner(Textos.Biblioteca.noSePudoLeer(readError), detail: nil, action: nil)
        } else if model.hasInvalidBytes {
            banner(Textos.Biblioteca.advertenciaBytes, detail: nil, action: nil, warning: true)
        }
        if let backup = model.backupName {
            banner(Textos.Biblioteca.copiaGuardada(backup), detail: nil, action: nil, warning: true)
        }
    }

    private func banner(
        _ title: String, detail: String?, action: (String, () -> Void)?, warning: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(warning ? Color.primary : MainPalette.error)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(MainPalette.muted)
                }
            }
            Spacer(minLength: 0)
            if let action { Button(action.0, action: action.1) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(warning ? MainPalette.accentBackground : MainPalette.errorBackground)
    }

    // MARK: - Editor and preview

    private var panes: some View {
        HStack(spacing: 0) {
            pane(title: Textos.Biblioteca.editor) {
                PlainTextEditor(text: $model.text, isEditable: model.readError == nil)
                    .accessibilityLabel(Textos.Biblioteca.editor)
            }
            Divider()
            pane(title: Textos.Biblioteca.vistaPrevia) { preview }
        }
    }

    private func pane<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MainPalette.muted)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// What the file says once parsed: name and description from the
    /// frontmatter, then the body as markdown (the tolerant parser, so a
    /// broken frontmatter shows the whole file as the body).
    private var preview: some View {
        // Until the debounce has caught up with a newly shown template, the
        // live text is what is drawn (also what the headless snapshots see).
        let shown = previewID == model.selectedID ? previewText : model.text
        let parsed = MinutesTemplate.parse(id: model.selectedID ?? "", contents: shown)
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(parsed.nombre).font(.system(size: 17, weight: .bold))
                if !parsed.descripcion.isEmpty {
                    Text(parsed.descripcion).font(.system(size: 12)).foregroundStyle(MainPalette.muted)
                }
                Divider()
                MarkdownDocumentView(text: parsed.cuerpo)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: PreviewKey(id: model.selectedID, text: model.text)) {
            // A different template shows at once; typing waits for a pause.
            if previewID == model.selectedID {
                try? await Task.sleep(for: Self.previewDelay)
                if Task.isCancelled { return }
            }
            previewID = model.selectedID
            previewText = model.text
        }
    }

    private struct PreviewKey: Equatable {
        let id: String?
        let text: String
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(MainPalette.muted)
                .accessibilityHidden(true)
            Text(Textos.Biblioteca.elegirPlantilla).font(.system(size: 17, weight: .semibold))
            Text(Textos.Biblioteca.elegirPlantillaDetalle)
                .font(.system(size: 13))
                .foregroundStyle(MainPalette.muted)
        }
    }
}
