import SwiftUI

/// Biblioteca > Glosario: the glossary tab that used to live in Ajustes,
/// unchanged in behavior (term, variants, "Corregir en la transcripción",
/// edit, delete) and now split over the window's two columns: the note and
/// the "add a term" form on the left (`GlossaryAddPanel`), the entries on
/// the right (`GlossaryEntriesView`).
///
/// Both take the `SettingsModel` explicitly; nothing here reaches for config
/// or the Keychain, so the headless snapshots render them over a temp file.

// MARK: - Add panel

struct GlossaryAddPanel: View {
    @Bindable var model: SettingsModel

    /// A `ScrollView`, like the Tareas panel: a split view measures its columns
    /// at their minimum width, where the wrapped note is thousands of points
    /// tall, and an unscrolled column pushed the whole window off screen.
    var body: some View {
        ScrollView(.vertical) {
            panel
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(MainPalette.window)
        .disabled(model.configLoadFailed)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Textos.Biblioteca.glosarioTitulo)
                .font(.system(size: 20, weight: .bold))
            Text(Textos.Biblioteca.glosarioNota)
                .font(.system(size: 12))
                .foregroundStyle(MainPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(Textos.Biblioteca.nuevoTerminoTitulo)
                .font(.system(size: 12, weight: .semibold))
            TextField(Textos.Biblioteca.nuevoTermino, text: $model.newTerm)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.addTerm() }
            TextField(Textos.Biblioteca.variantesCampo, text: $model.newVariants)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.addTerm() }
            HStack {
                Spacer()
                Button(Textos.Biblioteca.agregar) { model.addTerm() }
                    .disabled(model.newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.configError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(MainPalette.error)
            }
        }
    }
}

// MARK: - Entries

struct GlossaryEntriesView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Group {
            if model.glossary.isEmpty {
                Text(Textos.Biblioteca.glosarioVacio)
                    .foregroundStyle(MainPalette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.glossary, id: \.term) { entry in
                            GlossaryRow(entry: entry, model: model)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 9)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MainPalette.window)
        .disabled(model.configLoadFailed)
        .sheet(isPresented: Binding(
            get: { model.editingTerm != nil },
            set: { if !$0 { model.cancelEditing() } }
        )) {
            GlossaryVariantsSheet(model: model)
        }
    }
}

/// "MeetingVox — miting vox, mitin vox", with edit and delete buttons.
private struct GlossaryRow: View {
    let entry: GlossaryEntry
    let model: SettingsModel

    var body: some View {
        HStack {
            Text(entry.term)
            if !entry.variants.isEmpty {
                Text("— " + entry.variantsText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Toggle(Textos.Biblioteca.corregirEnTranscripcion, isOn: Binding(
                get: { entry.transcript },
                set: { model.setTranscript(entry.term, $0) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help(Textos.Biblioteca.corregirEnTranscripcionAyuda)
            Button {
                model.beginEditing(entry)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help(Textos.Biblioteca.editarVariantes)
            .accessibilityLabel(Textos.Biblioteca.editarVariantes)
            Button {
                model.removeTerm(entry.term)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(Textos.Biblioteca.eliminar)
            .accessibilityLabel(Textos.Biblioteca.eliminar)
        }
    }
}

/// Small sheet to edit one term's variants as comma-separated text.
private struct GlossaryVariantsSheet: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Textos.Biblioteca.variantesDe(model.editingTerm ?? "")).font(.headline)
            Text(Textos.Biblioteca.variantesEdicionNota).font(.callout).foregroundStyle(.secondary)
            TextField(Textos.Biblioteca.variantesCampo, text: $model.editingVariants)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.saveEditing() }
            HStack {
                Spacer()
                Button(Textos.Biblioteca.cancelar) { model.cancelEditing() }
                    .keyboardShortcut(.cancelAction)
                Button(Textos.Biblioteca.guardar) { model.saveEditing() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 380)
    }
}
