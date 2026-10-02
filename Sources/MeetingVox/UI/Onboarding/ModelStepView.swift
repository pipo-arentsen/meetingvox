import SwiftUI

/// The "Modelo" step: what the speech model is, its state, and the explicit
/// download button. "Present" reads as "in this Mac", never as validated.
struct ModelStepView: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Textos.Onboarding.modeloTitulo).font(.headline)
            Text(Textos.Onboarding.modeloDescripcion)
            Label(Textos.Onboarding.audioPrivado, systemImage: "lock.fill")
                .foregroundStyle(.secondary)
            Divider()
            state
        }
    }

    @ViewBuilder private var state: some View {
        switch model.modelState {
        case .notApplicable:
            Text(Textos.Onboarding.modeloNoAplica).foregroundStyle(.secondary)
        case .checking:
            Text(Textos.Onboarding.modeloComprobando).foregroundStyle(.secondary)
        case .absent:
            Text(Textos.Onboarding.modeloAusente)
            download(Textos.Onboarding.descargarModelo)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress.fraction)
                Text(Self.progressText(progress)).font(.callout).foregroundStyle(.secondary)
            }
        case .present:
            Label(Textos.Onboarding.modeloPresente, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let failure):
            Text(failure.userMessage).foregroundStyle(.red)
            download(Textos.Onboarding.reintentar)
        }
    }

    private func download(_ title: String) -> some View {
        Button(title) { Task { await model.startModelDownload() } }
            .buttonStyle(.borderedProminent)
    }

    static func progressText(_ progress: ModelProgress) -> String {
        let percent = Int((progress.fraction * 100).rounded())
        switch progress.phase {
        case .descargando: return Textos.Onboarding.modeloDescargando(percent)
        case .preparando: return Textos.Onboarding.modeloPreparando(percent)
        }
    }
}
