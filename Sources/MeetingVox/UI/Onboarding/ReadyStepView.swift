import SwiftUI

/// The "Listo" step: where recordings go, login item, detection and
/// automatic minutes. All writes go through `SettingsModel`; the login item
/// through `LoginItemController` (the installed bundle only).
struct ReadyStepView: View {
    @Bindable var settings: SettingsModel
    let loginItem: LoginItemController
    /// The calendar toggle: the one place besides Ajustes that may raise the
    /// calendar prompt, and only from the user's click.
    let calendar: CalendarSettingsModel
    /// The root this process resolved at launch: it never changes while
    /// running, so a new folder shows the restart note.
    let runningRoot: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            folder
            Divider()
            login
            Divider()
            detection
            Divider()
            CalendarSettingsRow(model: calendar)
            Divider()
            automaticMinutes
        }
        .disabled(settings.configLoadFailed)
        .onAppear { loginItem.refresh() }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Textos.Onboarding.carpetaTitulo).font(.headline)
            HStack {
                Text(settings.recordingsDir)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button(Textos.Onboarding.carpetaElegir) { settings.chooseRecordingsDir() }
            }
            if let error = settings.recordingsDirError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            Text(RecordingsFolderNote.needsRestart(runningRoot: runningRoot, configured: settings.recordingsDir)
                ? Textos.Onboarding.carpetaNotaReinicio : Textos.Onboarding.carpetaNotaGeneral)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var login: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Textos.Onboarding.inicioTitulo).font(.headline)
            HStack {
                switch loginItem.row {
                case .enabled:
                    Label(Textos.Onboarding.inicioActivo, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button(Textos.Onboarding.inicioDesactivar) { Task { await loginItem.tap() } }
                        .disabled(loginItem.recordingBlocked)
                case .pendingApproval:
                    Text(Textos.Onboarding.inicioPendiente)
                    Spacer()
                    Button(Textos.Onboarding.abrirAjustes) { Task { await loginItem.tap() } }
                case .off:
                    Spacer()
                    Button(Textos.Onboarding.inicioActivar) { Task { await loginItem.tap() } }
                        .disabled(loginItem.recordingBlocked)
                case .unavailable:
                    Text(Textos.Onboarding.inicioNoDisponible).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if loginItem.recordingBlocked {
                Text(Textos.Onboarding.inicioGrabando).font(.caption).foregroundStyle(.orange)
            } else if let message = loginItem.message {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
        }
    }

    private var detection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(Textos.Onboarding.deteccionTitulo, isOn: $settings.meetingDetectionEnabled)
            Text(Textos.Onboarding.deteccionDescripcion).font(.caption).foregroundStyle(.secondary)
        }
        .disabled(settings.meetingDetectionInvalid)
    }

    private var automaticMinutes: some View {
        // The saved model: a half-typed one does not count.
        let enabled = AutoMinutes.toggleEnabled(
            presence: settings.keyPresence, model: settings.savedModelID, isOn: settings.minutesEnabled
        )
        let requirement = AutoMinutes.requirement(presence: settings.keyPresence, model: settings.savedModelID)
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(Textos.Onboarding.minutasAutoTitulo, isOn: $settings.minutesEnabled)
                .disabled(!enabled)
            Text(Textos.Onboarding.minutasAutoDescripcion).font(.caption).foregroundStyle(.secondary)
            if !enabled, let requirement {
                Text(requirement == .migrateKey
                    ? Textos.Onboarding.minutasAutoRequisitoMigrar : Textos.Onboarding.minutasAutoRequisito)
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
