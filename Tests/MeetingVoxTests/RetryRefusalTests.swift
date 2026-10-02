import Foundation
import Testing
@testable import MeetingVox

/// What the detail says when "Reintentar" finds nothing to retry.
@Suite struct RetryRefusalTests {
    @Test func eachStageNamesItsOwnReason() {
        let transcription = RetryRefusal.message(for: .transcription)
        let minutes = RetryRefusal.message(for: .minutes)
        let summary = RetryRefusal.message(for: .summary)
        #expect(transcription == Textos.Principal.nadaQueReintentar(Textos.Principal.razonTranscripcion))
        #expect(minutes == Textos.Principal.nadaQueReintentar(Textos.Principal.razonMinuta))
        #expect(summary == Textos.Principal.nadaQueReintentar(Textos.Principal.razonResumen))
        #expect(Set([transcription, minutes, summary]).count == 3, "three different reasons")
        #expect(minutes.hasPrefix("No hay nada que reintentar: "))
    }

    @Test func aMemoryRefusalUsesTheGenericChangedMessage() {
        #expect(RetryRefusal.message(for: .memory) == Textos.Principal.memoriaCambio)
    }
}
