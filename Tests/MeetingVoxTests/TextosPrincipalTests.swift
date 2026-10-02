import Foundation
import Testing
@testable import MeetingVox

@Suite struct TextosPrincipalTests {
    @Test func weekdayAndMonthTablesAreCompleteAndSpanish() {
        #expect(Textos.Principal.diasLargos.count == 7)
        #expect(Textos.Principal.diasLargos[0] == "Domingo")
        #expect(Textos.Principal.diasLargos[6] == "Sábado")
        #expect(Textos.Principal.mesesLargos.count == 12)
        #expect(Textos.Principal.mes(9, 2026) == "Septiembre 2026")
        #expect(Textos.Principal.mes(1, 2025) == "Enero 2025")
    }

    @Test func sidebarAndFooterCopy() {
        #expect(Textos.Principal.reuniones == "Reuniones")
        #expect(Textos.Principal.tareas == "Tareas")
        #expect(Textos.Principal.biblioteca == "Biblioteca")
        #expect(Textos.Principal.audioNoSale == "El audio no sale de este Mac")
    }
}
