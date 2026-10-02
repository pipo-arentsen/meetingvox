import SwiftUI

/// The "Minutas" step: optional OpenRouter setup. Everything writes through
/// `SettingsModel` (the same Keychain and config paths as Ajustes). Nothing
/// here prompts or hits the network by itself: the legacy-key prompt follows
/// "Migrar clave" and the model catalog follows "Ver modelos".
struct MinutesStepView: View {
    @Bindable var settings: SettingsModel
    let model: OnboardingModel
    @FocusState private var modelFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Textos.Onboarding.minutasIntro)
            Divider()
            key
            Divider()
            modelPicker
            Divider()
            privacy
            Divider()
            HStack {
                Button(Textos.Onboarding.omitirMinutas) { model.skipMinutes() }
                Text(Textos.Onboarding.omitirNota).font(.caption).foregroundStyle(.secondary)
            }
            if let error = settings.configError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
        }
        .disabled(settings.configLoadFailed)
    }

    // MARK: Key

    @ViewBuilder private var key: some View {
        Text(Textos.Onboarding.claveTitulo).font(.headline)
        switch settings.keyPresence {
        case .primary:
            HStack {
                Label(Textos.Onboarding.claveGuardada, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Spacer()
                Button(Textos.Ajustes.borrar, role: .destructive) { settings.deleteAPIKey() }
            }
        case .legacyOnly:
            // The consent copy comes first: "Migrar clave" is what raises the
            // macOS Keychain prompt.
            VStack(alignment: .leading, spacing: 8) {
                Label(Textos.Onboarding.claveLegadoTitulo, systemImage: "key.fill")
                Text(Textos.Onboarding.claveLegadoConsentimiento).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(Textos.Onboarding.migrarClave) { Task { await settings.migrateLegacyKey() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(settings.migratingKey)
                    if settings.migratingKey {
                        ProgressView().controlSize(.small)
                        Text(Textos.Onboarding.migrando).foregroundStyle(.secondary)
                    }
                }
            }
            entry
        case .none:
            entry
        }
        if let error = settings.keyError {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
        }
        Text(Textos.Ajustes.claveNota).font(.caption).foregroundStyle(.secondary)
    }

    private var entry: some View {
        HStack {
            SecureField(
                Textos.Onboarding.claveNueva, text: $settings.apiKeyInput,
                prompt: Text(Textos.Ajustes.clavePlaceholder)
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit { settings.saveAPIKey() }
            Button(Textos.Onboarding.guardarClave) { settings.saveAPIKey() }
                .disabled(settings.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: Model

    @ViewBuilder private var modelPicker: some View {
        Text(Textos.Onboarding.modeloOpenRouter).font(.headline)
        TextField(
            Textos.Onboarding.modeloOpenRouter, text: $settings.modelID,
            prompt: Text(Textos.Onboarding.modeloOpenRouterPlaceholder)
        )
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
        .focused($modelFieldFocused)
        .onSubmit { settings.commitModelID() }
        // Leaving the field saves it; Continuar, Atrás, the rail and Empezar do
        // too (`OnboardingModel`), so a typed ID is never lost.
        .onChange(of: modelFieldFocused) { _, focused in
            if !focused { settings.commitModelID() }
        }
        HStack {
            Button(Textos.Onboarding.verModelos) { settings.loadModels(force: true) }
                .disabled(settings.modelsState == .loading)
            Text(Textos.Onboarding.modelosNota).font(.caption).foregroundStyle(.secondary)
        }
        switch settings.modelsState {
        case .idle:
            EmptyView()
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text(Textos.Ajustes.cargandoModelos).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(Textos.Ajustes.errorModelos(message)).foregroundStyle(.red).font(.callout)
        case .loaded:
            TextField(Textos.Ajustes.buscarModelos, text: $settings.modelSearch).textFieldStyle(.roundedBorder)
            List(
                settings.filteredModels,
                selection: Binding<String?>(
                    get: { settings.modelID },
                    set: { if let id = $0 { settings.selectModel(id) } }
                )
            ) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                    Text(entry.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 140)
        }
    }

    // MARK: Privacy

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Textos.Onboarding.privacidadTitulo).font(.headline)
            Toggle(Textos.Ajustes.denegarRecoleccion, isOn: $settings.denyDataCollection)
            Text(Textos.Ajustes.privacidadNota).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
