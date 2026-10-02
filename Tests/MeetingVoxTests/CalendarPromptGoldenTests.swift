import Foundation
import Testing
@testable import MeetingVox

/// Pins today's prompt bytes for sessions without a calendar event, so the
/// calendar context can never alter a
/// prompt it does not apply to. These strings were written against the code
/// before the calendar parameters existed.
@Suite struct CalendarPromptGoldenTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let started = Date(timeIntervalSince1970: 1_790_172_300) // 2026-09-23T14:05:00Z

    private var info: SessionInfo {
        SessionInfo(name: "2026.09.23-1405", started: started, durationSeconds: 3_900)
    }

    private var lines: [TranscriptLine] {
        PromptBuilder.lines(from: [
            .init(speaker: "me", start_ms: 0, end_ms: 1_000, text: "Hola"),
            .init(speaker: "them", start_ms: 4_000, end_ms: 5_000, text: "Buenas tardes"),
        ])
    }

    private let metadataGolden = """
    Datos de la sesión:
    - Nombre de la sesión: 2026.09.23-1405
    - Fecha y hora de inicio: miércoles, 23 de septiembre de 2026, 14:05
    - Duración: 1:05 (h:mm)
    """

    @Test func minutesMetadataIsByteIdenticalWithoutAnEvent() {
        #expect(PromptBuilder.metadata(info, timeZone: utc) == metadataGolden)
    }

    @Test func minutesMetadataWithoutDateOrDurationIsByteIdentical() {
        let bare = SessionInfo(name: "x", started: nil, durationSeconds: nil)
        #expect(PromptBuilder.metadata(bare, timeZone: utc) == "Datos de la sesión:\n- Nombre de la sesión: x")
    }

    @Test func minutesUserPromptIsByteIdenticalWithoutAnEvent() {
        let expected = metadataGolden + "\n\nTranscripción:\n[00:00] Yo: Hola\n[00:04] Otros: Buenas tardes"
        #expect(PromptBuilder.userPrompt(info: info, lines: lines, timeZone: utc) == expected)
    }

    @Test func minutesChunkPromptsAreByteIdenticalWithoutAnEvent() {
        let partial = PromptBuilder.partialUserPrompt(info: info, part: 1, of: 2, lines: lines, timeZone: utc)
        #expect(partial.hasPrefix(metadataGolden + "\n\n"))
        let consolidation = PromptBuilder.consolidationUserPrompt(info: info, notes: ["n1", "n2"], timeZone: utc)
        #expect(consolidation.hasPrefix(metadataGolden + "\n\n"))
        let reduction = PromptBuilder.reductionUserPrompt(
            info: info, notes: ["n1"], firstPart: 1, total: 2, timeZone: utc)
        #expect(reduction.hasPrefix(metadataGolden + "\n\n"))
    }

    @Test func summaryUserPromptIsByteIdenticalWithoutAnEvent() {
        #expect(
            SummaryPrompts.userPrompt(sessionName: "2026.09.23-1405", content: "[00:00] Yo: Hola")
                == "Sesión: 2026.09.23-1405\n\nContenido de la reunión:\n[00:00] Yo: Hola")
    }
}
