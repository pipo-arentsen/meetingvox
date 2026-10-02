import Foundation

/// What the detail tells the user when a stage's "Reintentar" finds nothing to
/// redo (the stage's own gate refused): one sentence per stage saying why,
/// instead of a tap that seems to do nothing. Pure.
enum RetryRefusal {
    static func message(for stage: Notice.Stage) -> String {
        switch stage {
        case .transcription: Textos.Principal.nadaQueReintentar(Textos.Principal.razonTranscripcion)
        case .minutes: Textos.Principal.nadaQueReintentar(Textos.Principal.razonMinuta)
        case .summary: Textos.Principal.nadaQueReintentar(Textos.Principal.razonResumen)
        case .memory: Textos.Principal.memoriaCambio
        }
    }
}
