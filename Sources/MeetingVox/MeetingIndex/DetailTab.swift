import Foundation

/// The three tabs under the session detail's stepper (DT-1).
enum DetailTab: CaseIterable, Sendable, Hashable {
    case resumen, minuta, transcripcion

    var title: String {
        switch self {
        case .resumen: Textos.Principal.tabResumen
        case .minuta: Textos.Principal.tabMinuta
        case .transcripcion: Textos.Principal.tabTranscripcion
        }
    }
}
