import Foundation

/// The copy and numbering of each step, shared by the rail and the header.
extension OnboardingStep {
    /// 1-based position shown in the rail's circle.
    var number: Int { rawValue }

    var title: String {
        switch self {
        case .permisos: Textos.Onboarding.pasoPermisos
        case .modelo: Textos.Onboarding.pasoModelo
        case .minutas: Textos.Onboarding.pasoMinutas
        case .listo: Textos.Onboarding.pasoListo
        }
    }

    var subtitle: String {
        switch self {
        case .permisos: Textos.Onboarding.subtituloPermisos
        case .modelo: Textos.Onboarding.subtituloModelo
        case .minutas: Textos.Onboarding.subtituloMinutas
        case .listo: Textos.Onboarding.subtituloListo
        }
    }
}
