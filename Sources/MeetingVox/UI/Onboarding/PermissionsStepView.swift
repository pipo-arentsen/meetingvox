import SwiftUI

/// The "Permisos" step: one row per permission with its status and its one
/// button. Presentational; a click calls `model.perform(kind)`.
struct PermissionsStepView: View {
    let model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(PermissionKind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 { Divider() }
                PermissionRowView(model: model, kind: kind)
            }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PermissionRowView: View {
    let model: OnboardingModel
    let kind: PermissionKind

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.name(kind)).fontWeight(.medium)
                Text(Self.detail(kind)).font(.callout).foregroundStyle(.secondary)
                if let note = model.rows[kind]?.note {
                    Text(Self.text(note)).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let row = model.rows[kind] {
                statusLabel(row.status)
                action(row.action)
            } else {
                Text(Textos.Onboarding.comprobando).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    @ViewBuilder private func action(_ action: RowAction) -> some View {
        switch action {
        case .none:
            EmptyView()
        case .allow:
            if model.inFlight == kind {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Textos.Onboarding.esperandoPermiso(Self.name(kind)))
            } else {
                Button(Textos.Onboarding.permitir) { Task { await model.perform(kind) } }
                    .disabled(model.inFlight != nil)
            }
        case .openSettings:
            Button(Textos.Onboarding.abrirAjustes) { Task { await model.perform(kind) } }
        case .waitForRecordingEnd:
            Text(Textos.Onboarding.esperarGrabacion).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func statusLabel(_ status: PermissionStatus) -> some View {
        let (text, color): (String, Color) = switch status {
        case .granted: (Textos.Onboarding.estadoPermitido, .green)
        case .notDetermined: (Textos.Onboarding.estadoPendiente, .secondary)
        case .denied: (Textos.Onboarding.estadoDenegado, .red)
        case .requested: (Textos.Onboarding.estadoSolicitado, .orange)
        case .notApplicable: (Textos.Onboarding.estadoNoAplica, .secondary)
        }
        return Text(text).font(.callout.weight(.medium)).foregroundStyle(color)
    }

    static func name(_ kind: PermissionKind) -> String {
        switch kind {
        case .microphone: Textos.Onboarding.microfono
        case .systemAudio: Textos.Onboarding.audioSistema
        case .notifications: Textos.Onboarding.notificaciones
        case .localNetwork: Textos.Onboarding.redLocal
        }
    }

    static func detail(_ kind: PermissionKind) -> String {
        switch kind {
        case .microphone: Textos.Onboarding.microfonoDetalle
        case .systemAudio: Textos.Onboarding.audioSistemaDetalle
        case .notifications: Textos.Onboarding.notificacionesDetalle
        case .localNetwork: Textos.Onboarding.redLocalDetalle
        }
    }

    static func text(_ note: PermissionNote) -> String {
        switch note {
        case .whenMemoryEnabled: Textos.Onboarding.notaMemoria
        case .restrictedByPolicy: Textos.Onboarding.notaRestringido
        case .recordingInProgress: Textos.Onboarding.notaGrabando
        case .serverUnreachable: Textos.Onboarding.notaServidor
        case .unavailableOutsideApp: Textos.Onboarding.notaFueraDeApp
        }
    }
}
