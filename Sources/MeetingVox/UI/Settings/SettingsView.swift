import SwiftUI

/// The tabs of the settings window, as data so a test can assert the list
/// (Glosario moved to the main window's Biblioteca and must not come back).
enum SettingsTab: CaseIterable {
    case openRouter, reuniones, memoria

    var title: String {
        switch self {
        case .openRouter: Textos.Ajustes.pestanaOpenRouter
        case .reuniones: Textos.Ajustes.pestanaReuniones
        case .memoria: Textos.Memoria.pestana
        }
    }
}

/// Root of the settings window: three tabs (OpenRouter incl. privacy;
/// Reuniones = detection, recording and minutes; Memoria = Hindsight
/// export; the template editor and the glossary live in the main window's
/// Biblioteca), plus a footer that shows config write errors (e.g. config.json
/// hand-edited into invalid JSON).
struct SettingsView: View {
    @Bindable var model: SettingsModel
    @Bindable var hindsight: HindsightSettingsModel
    let calendar: CalendarSettingsModel
    /// Re-opens the onboarding window ("Primeros pasos…").
    var onOpenOnboarding: () -> Void = {}
    /// Opens the main window on Biblioteca (templates, glossary).
    var onOpenLibrary: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                OpenRouterTab(model: model)
                    .tabItem { Text(SettingsTab.openRouter.title) }
                MeetingsTab(model: model, calendar: calendar, onOpenLibrary: onOpenLibrary)
                    .tabItem { Text(SettingsTab.reuniones.title) }
                MemoryTab(model: hindsight)
                    .tabItem { Text(SettingsTab.memoria.title) }
            }
            .padding()

            if let error = model.configError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                    Spacer()
                    if model.configLoadFailed {
                        Button(Textos.Ajustes.reintentar) { model.reload() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 10)
            }

            Divider()
            HStack {
                Button(Textos.Ajustes.primerosPasos) { onOpenOnboarding() }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 560, minHeight: 500)
    }
}

// MARK: - OpenRouter

private struct OpenRouterTab: View {
    @Bindable var model: SettingsModel
    @FocusState private var modelFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Textos.Ajustes.claveAPI).font(.headline)
            HStack {
                SecureField(Textos.Ajustes.claveAPI, text: $model.apiKeyInput, prompt: Text(Textos.Ajustes.clavePlaceholder))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.saveAPIKey() }
                Button(Textos.Ajustes.guardar) { model.saveAPIKey() }
                    .disabled(model.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(Textos.Ajustes.borrar, role: .destructive) { model.deleteAPIKey() }
                    .disabled(!model.hasKey)
            }
            if let error = model.keyError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if model.hasKey {
                Label(Textos.Ajustes.claveGuardada, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else {
                Label(Textos.Ajustes.sinClave, systemImage: "key").foregroundStyle(.secondary)
            }
            Text(Textos.Ajustes.claveNota).font(.caption).foregroundStyle(.secondary)

            Divider()

            Text(Textos.Ajustes.modelo).font(.headline)
            TextField(Textos.Ajustes.modelo, text: $model.modelID, prompt: Text(Textos.Ajustes.modeloPlaceholder))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($modelFieldFocused)
                .onSubmit { model.commitModelID() }
                .onChange(of: modelFieldFocused) { _, focused in
                    if !focused { model.commitModelID() }
                }
                .disabled(model.configLoadFailed)
            HStack {
                TextField(Textos.Ajustes.buscarModelos, text: $model.modelSearch)
                    .textFieldStyle(.roundedBorder)
                Button(Textos.Ajustes.recargar) { model.loadModels(force: true) }
                    .disabled(model.modelsState == .loading)
            }
            modelList
                .frame(minHeight: 120, maxHeight: .infinity)
                .disabled(model.configLoadFailed)

            HStack {
                Button(Textos.Ajustes.probarConexion) { model.testConnection() }
                    .disabled(model.testingConnection)
                if model.testingConnection {
                    ProgressView().controlSize(.small)
                    Text(Textos.Ajustes.probando).foregroundStyle(.secondary)
                } else if let result = model.connectionResult {
                    Text(result)
                        .foregroundStyle(model.connectionFailed ? .red : .green)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Divider()

            PrivacySection(model: model)
        }
        .padding()
        .onAppear { model.loadModels() }
    }

    @ViewBuilder
    private var modelList: some View {
        switch model.modelsState {
        case .idle, .loading:
            VStack {
                ProgressView()
                Text(Textos.Ajustes.cargandoModelos).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Text(Textos.Ajustes.errorModelos(message))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            let models = model.filteredModels
            if models.isEmpty {
                Text(Textos.Ajustes.sinResultados)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Selecting a row fills the hand-editable model ID field above.
                List(models, selection: Binding<String?>(
                    get: { model.modelID },
                    set: { if let id = $0 { model.selectModel(id) } }
                )) { entry in
                    ModelRow(entry: entry)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }
        }
    }
}

private struct ModelRow: View {
    let entry: OpenRouterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name)
            HStack {
                Text(entry.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if let context = entry.contextLength {
                    Text(Textos.Ajustes.contexto(context))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Meetings tab

/// One scrolling grouped form for everything about a meeting: detection,
/// recording, minutes. Each area keeps its own struct; they contribute
/// `Section`s (no `Form` of their own) so the grouped form flattens them.
private struct MeetingsTab: View {
    @Bindable var model: SettingsModel
    let calendar: CalendarSettingsModel
    let onOpenLibrary: () -> Void

    var body: some View {
        Form {
            DetectionSections(model: model)
            CalendarSettingsSection(model: calendar)
            RecordingSections(model: model)
            MinutesSections(model: model, onOpenLibrary: onOpenLibrary)
        }
        .formStyle(.grouped)
    }
}

/// Group heading shown on the first section of each area of the meetings tab.
private struct SectionHeading: View {
    let title: String

    var body: some View {
        Text(title).font(.title3).bold()
    }
}

// MARK: - Minutes

private struct MinutesSections: View {
    @Bindable var model: SettingsModel
    let onOpenLibrary: () -> Void
    @FocusState private var languageFocused: Bool

    var body: some View {
        Group {
            Section {
                Toggle(Textos.Ajustes.minutasAutomaticas, isOn: $model.minutesEnabled)
                Text(Textos.Ajustes.minutasNota).font(.caption).foregroundStyle(.secondary)
            } header: {
                SectionHeading(title: Textos.Ajustes.seccionMinutas)
            }
            .disabled(model.configLoadFailed)
            .onAppear { model.reloadTemplates() }
            Section {
                Toggle(Textos.Ajustes.resumenAutomatico, isOn: $model.summaryEnabled)
                Text(Textos.Ajustes.resumenAutomaticoNota).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(model.configLoadFailed)
            Section {
                Picker(Textos.Ajustes.plantilla, selection: $model.minutesTemplate) {
                    ForEach(model.templates, id: \.id) { template in
                        Text(template.nombre).tag(template.id)
                    }
                    // Keep a configured-but-missing id selectable instead of
                    // leaving the picker blank.
                    if !model.templates.contains(where: { $0.id == model.minutesTemplate }) {
                        Text(Textos.Ajustes.plantillaNoEncontrada(model.minutesTemplate))
                            .tag(model.minutesTemplate)
                    }
                }
                TextField(
                    Textos.Ajustes.idioma,
                    text: $model.minutesLanguage,
                    prompt: Text(ConfigValues.defaultMinutesLanguage)
                )
                .focused($languageFocused)
                .onSubmit { model.commitMinutesLanguage() }
                .onChange(of: languageFocused) { _, focused in
                    if !focused { model.commitMinutesLanguage() }
                }
            }
            .disabled(model.configLoadFailed)
            Section {
                Text(Textos.Ajustes.bibliotecaNota).font(.caption).foregroundStyle(.secondary)
                Button(Textos.Ajustes.abrirBiblioteca) { onOpenLibrary() }
            }
        }
    }
}

// MARK: - Recording

private struct RecordingSections: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Group {
            Section {
                LabeledContent(Textos.Ajustes.carpetaGrabaciones) {
                    HStack {
                        Text(model.recordingsDir)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button(Textos.Ajustes.elegir) { model.chooseRecordingsDir() }
                    }
                }
                if let error = model.recordingsDirError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                }
                Text(Textos.Ajustes.carpetaNota).font(.caption).foregroundStyle(.secondary)
            } header: {
                SectionHeading(title: Textos.Ajustes.seccionGrabacion)
            }
            Section {
                Toggle(Textos.Ajustes.procesamientoVoz, isOn: $model.micVoiceProcessing)
                Text(Textos.Ajustes.procesamientoVozNota).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(Textos.Ajustes.transcribirAutomaticamente, isOn: $model.transcriptionEnabled)
                Text(Textos.Ajustes.transcribirNota).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(Textos.Ajustes.pildoraGrabando, isOn: $model.recordingPillEnabled)
                    .disabled(model.recordingPillInvalid)
                Text(Textos.Ajustes.pildoraGrabandoNota).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(model.configLoadFailed)
    }
}

// MARK: - Meeting detection

private struct DetectionSections: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Group {
            Section {
                Toggle(Textos.Ajustes.detectarReuniones, isOn: $model.meetingDetectionEnabled)
                Text(Textos.Ajustes.reunionesNota).font(.caption).foregroundStyle(.secondary)
            } header: {
                SectionHeading(title: Textos.Ajustes.seccionDeteccion)
            }
            Section {
                Toggle(Textos.Ajustes.preguntarDetener, isOn: $model.meetingPromptOnEnd)
                Text(Textos.Ajustes.preguntarDetenerNota).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.meetingDetectionEnabled)
            Section {
                Toggle(Textos.Ajustes.detenerSola, isOn: $model.meetingAutoStop)
                Text(Textos.Ajustes.detenerSolaNota).font(.caption).foregroundStyle(.secondary)
                if !model.autoStopAvailable {
                    Text(Textos.Ajustes.autoStopRequierePregunta).font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!model.autoStopAvailable)
            Section(Textos.Ajustes.aplicaciones) {
                ForEach(MeetingApp.all) { app in
                    Toggle(app.name, isOn: Binding(
                        get: { model.isDetected(app) },
                        set: { model.setDetected(app, $0) }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            .disabled(!model.meetingDetectionEnabled)
        }
        .disabled(model.configLoadFailed || model.meetingDetectionInvalid)
    }
}

// MARK: - Privacy

/// Bottom of the OpenRouter tab: privacy only concerns what is sent there.
private struct PrivacySection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Textos.Ajustes.seccionPrivacidad).font(.headline)
            Toggle(Textos.Ajustes.denegarRecoleccion, isOn: $model.denyDataCollection)
            Text(Textos.Ajustes.privacidadNota)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.configLoadFailed)
    }
}

// MARK: - Memoria (Hindsight)

private struct MemoryTab: View {
    @Bindable var model: HindsightSettingsModel
    @FocusState private var focused: Field?

    private enum Field { case url, bank, owner, description }

    var body: some View {
        Form {
            Section {
                Toggle(Textos.Memoria.activar, isOn: $model.enabled)
                Text(Textos.Memoria.nota).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField(Textos.Memoria.url, text: $model.baseURL, prompt: Text(Textos.Memoria.urlPlaceholder))
                    .focused($focused, equals: .url)
                    .onSubmit { model.commitBaseURL() }
                if model.bankList.loadedFromServer {
                    Picker(Textos.Memoria.bancoPorDefecto, selection: Binding(
                        get: { model.bank },
                        set: { model.selectBank($0) }
                    )) {
                        ForEach(model.bankChoices, id: \.self) { choice in
                            Text(choice.isEmpty ? Textos.Memoria.bancoSinElegir : choice).tag(choice)
                        }
                    }
                } else {
                    TextField(Textos.Memoria.bancoPorDefecto, text: $model.bank)
                        .focused($focused, equals: .bank)
                        .onSubmit { model.commitBank() }
                    if model.enabled {
                        Text(Textos.Memoria.bancosSinLista).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField(Textos.Memoria.propietario, text: $model.ownerName, prompt: Text(ConfigValues.defaultHindsightOwnerName))
                    .focused($focused, equals: .owner)
                    .onSubmit { model.commitOwnerName() }
                TextField(Textos.Memoria.descripcionDueno, text: $model.ownerDescription,
                          prompt: Text(Textos.Memoria.descripcionDuenoPlaceholder))
                    .focused($focused, equals: .description)
                    .onSubmit { model.commitOwnerDescription() }
            }
            .onChange(of: focused) { previous, _ in
                switch previous {
                case .url: model.commitBaseURL()
                case .bank: model.commitBank()
                case .owner: model.commitOwnerName()
                case .description: model.commitOwnerDescription()
                case nil: break
                }
            }
            Section {
                Toggle(Textos.Memoria.autoEnviar, isOn: $model.autoSend)
                Text(Textos.Memoria.notaAuto).font(.caption).foregroundStyle(.secondary)
                DatePicker(Textos.Memoria.desde, selection: $model.since, displayedComponents: .date)
                    .disabled(!model.autoSend)
                Stepper(Textos.Memoria.minPalabras(model.minWords), value: $model.minWords, in: 0...5000, step: 10)
                Stepper(Textos.Memoria.minMinutos(model.minMinutes), value: $model.minMinutes, in: 0...120)
            }
            Section(Textos.Memoria.token) {
                HStack {
                    SecureField(Textos.Memoria.token, text: $model.tokenInput, prompt: Text(Textos.Memoria.tokenPlaceholder))
                        .onSubmit { model.saveToken() }
                    Button(Textos.Ajustes.guardar) { model.saveToken() }
                        .disabled(model.tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(Textos.Ajustes.borrar, role: .destructive) { model.deleteToken() }
                        .disabled(!model.hasToken)
                }
                if let error = model.tokenError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } else if model.hasToken {
                    Label(Textos.Memoria.tokenGuardado, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Label(Textos.Memoria.sinToken, systemImage: "key").foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button(Textos.Ajustes.probarConexion) { model.testConnection() }
                        .disabled(model.testingConnection)
                    if model.testingConnection {
                        ProgressView().controlSize(.small)
                        Text(Textos.Ajustes.probando).foregroundStyle(.secondary)
                    } else if let result = model.connectionResult {
                        Text(result)
                            .foregroundStyle(model.connectionFailed ? .red : .green)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                if let error = model.configError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshBanks() }
    }
}
