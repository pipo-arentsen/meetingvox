import SwiftUI

/// Biblioteca > Plantillas, list column: every template file sorted by name,
/// a warning mark on the ones that could not be read as UTF-8 (or at all),
/// and "Nueva plantilla". Selecting goes through the model's dirty guard, so
/// a switch with unsaved changes asks first.
struct TemplateListView: View {
    @Bindable var model: TemplateEditorModel
    @State private var creating = false
    @State private var newID = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.files.isEmpty {
                Text(Textos.Biblioteca.sinPlantillas)
                    .foregroundStyle(MainPalette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.files, id: \.id) { file in row(file) }
                    }
                    .padding(8)
                }
            }
        }
        .background(MainPalette.window)
        .sheet(isPresented: $creating) { newSheet }
        .alert(Textos.Biblioteca.descartarTitulo, isPresented: Binding(
            get: { model.pendingSelectionID != nil },
            set: { if !$0 { model.cancelPendingSelection() } }
        )) {
            Button(Textos.Biblioteca.descartar, role: .destructive) { model.confirmPendingSelection() }
            Button(Textos.Biblioteca.cancelar, role: .cancel) { model.cancelPendingSelection() }
        } message: {
            Text(Textos.Biblioteca.descartarMensaje)
        }
    }

    private var header: some View {
        HStack {
            Text(Textos.Biblioteca.plantillasTitulo)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button {
                newID = ""
                model.clearFailure()
                creating = true
            } label: {
                Label(Textos.Biblioteca.nuevaPlantilla, systemImage: "plus")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func row(_ file: TemplateStore.TemplateFile) -> some View {
        let selected = model.selectedID == file.id
        return Button {
            model.select(file.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    Text(file.id + "." + TemplateStore.fileExtension)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MainPalette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if TemplateStore.isFactoryID(file.id) {
                    Text(Textos.Biblioteca.deFabrica)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .foregroundStyle(MainPalette.muted)
                        .background(Capsule().fill(MainPalette.sunken))
                }
                if file.lossy || file.readError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(MainPalette.high)
                        .accessibilityLabel(file.readError.map(Textos.Biblioteca.noSePudoLeer) ?? Textos.Biblioteca.advertenciaBytes)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? MainPalette.selection : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var newSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Textos.Biblioteca.nuevaPlantillaTitulo).font(.headline)
            Text(Textos.Biblioteca.nuevaPlantillaMensaje).font(.callout).foregroundStyle(.secondary)
            TextField(Textos.Biblioteca.identificador, text: $newID)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            if let failure = model.failure {
                Text(failure.message).font(.caption).foregroundStyle(MainPalette.error)
            }
            HStack {
                Spacer()
                Button(Textos.Biblioteca.cancelar) {
                    model.clearFailure()
                    creating = false
                }
                    .keyboardShortcut(.cancelAction)
                Button(Textos.Biblioteca.crear, action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func create() {
        if model.create(id: newID) {
            model.clearFailure()
            creating = false
        }
    }
}
