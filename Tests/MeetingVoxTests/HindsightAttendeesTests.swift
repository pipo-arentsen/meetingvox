import Testing
@testable import MeetingVox

@Suite struct HindsightAttendeesTests {
    private let header = "<!-- quill minutes · model: m/x · template: general · generated_at: 2026-09-24T17:10:29Z · chunked: no -->\n\n"

    @Test func generalTemplateStripsTrackLabelsSplitsCommasAndDedupes() {
        let minutes = header + """
        # Minuta de reunión

        ## Asistentes
        - Yo: Participante 1
        - Otros: Participante 2, Participante 3 (?), participante 2

        ## Personas mencionadas
        - Participante 4: se reunirá con Participante 3.
        """
        #expect(HindsightAttendees.parse(minutes: minutes, templateID: "general") == ["Participante 1", "Participante 2", "Participante 3"])
    }

    @Test func unidentifiedParticipantsAndNotMentionedAreDropped() {
        let minutes = "## Asistentes\n- Yo: Participante 1\n- Otros: participantes no identificados.\n"
        #expect(HindsightAttendees.parse(minutes: minutes, templateID: "general") == ["Participante 1"])
        let none = "## Participantes\n- No se mencionó.\n"
        #expect(HindsightAttendees.parse(minutes: none, templateID: "levantamiento") == [])
    }

    @Test func comercialLabelsAreStripped() {
        let minutes = """
        # Llamada comercial

        ## Participantes
        - Por nuestro equipo: Participante 1, Participante 2
        - Por el cliente: Participante 3
        - Socios u otros: No se mencionó.

        ## Contexto del cliente
        - Banco.
        """
        #expect(HindsightAttendees.parse(minutes: minutes, templateID: "comercial") == ["Participante 1", "Participante 2", "Participante 3"])
    }

    @Test func singularParticipantSectionAndCaseInsensitiveHeading() {
        #expect(HindsightAttendees.parse(minutes: "## PARTICIPANTE\n- Participante 2\n\n## Temas conversados\n- x", templateID: "uno-a-uno") == ["Participante 2"])
    }

    @Test func boldMarkupNestedBulletsAndLoneAnnotation() {
        let minutes = """
        ## Asistentes
        - **Yo**: Participante 1
        - **Otros**:
          - Participante 2
          - Participante 3 (P3)
          - (?)
        ### Nota
        - no es asistente
        ## Temas tratados
        - Tema
        """
        #expect(HindsightAttendees.parse(minutes: minutes, templateID: "general") == ["Participante 1", "Participante 2", "Participante 3 (P3)", "no es asistente"])
    }

    @Test func onlyTheFirstAttendeesSectionCounts() {
        let minutes = "## Asistentes\n- Participante 1\n\n## Participantes\n- Participante 2\n"
        #expect(HindsightAttendees.parse(minutes: minutes, templateID: "general") == ["Participante 1"])
    }

    @Test func dailyUsesPersonHeadingsAndSkipsTheFixedSections() {
        let minutes = """
        # Daily

        ## Participante 1
        - **Qué hizo:** propuesta.

        ## Otros
        - **Qué hizo:** no se identificó.

        ## Participante 2
        - **Qué hará:** revisar.

        ## Oportunidades mencionadas
        | Cliente u oportunidad | Estado o avance | Próximo paso | Responsable |

        ## Bloqueos que requieren seguimiento
        - No se mencionó.

        ## Acuerdos
        - x

        ## Otros temas
        - y
        """
        #expect(HindsightAttendees.parse(minutes: minutes, templateID: "daily") == ["Participante 1", "Participante 2"])
        #expect(HindsightAttendees.parse(minutes: minutes, templateID: "general") == [])
    }

    @Test func templatesWithoutASectionGiveNothing() {
        let entrevista = "# Entrevista\n\n## Perfil del candidato\n- Ingeniera.\n"
        #expect(HindsightAttendees.parse(minutes: entrevista, templateID: "entrevista") == [])
        #expect(HindsightAttendees.parse(minutes: "", templateID: nil) == [])
    }

    @Test func familiarMinutesYieldTheirParticipants() {
        let minutes = header + """
        # Reunión familiar

        ## Participantes
        - Yo: Participante 1
        - Otros: Participante 2, Participante 3 (?)

        ## Temas conversados
        - Organización del mes.
        """
        #expect(HindsightAttendees.parse(minutes: minutes, templateID: "familiar") == ["Participante 1", "Participante 2", "Participante 3"])
    }
}
