import Foundation
import Testing
@testable import MeetingVox

/// The user-visible privacy text must say what really leaves the Mac:
/// transcript (or minutes) text to OpenRouter — for summaries and, since the
/// tasks feature, for task extraction too — and, to Hindsight, the transcript
/// plus its metadata and the client and country as tags.
@Suite struct PrivacyCopyTests {
    private static func plist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packaging/Info.plist")
        let data = try Data(contentsOf: url)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func openRouterNoteMentionsTaskExtraction() {
        let note = Textos.Ajustes.privacidadNota.lowercased()
        #expect(note.contains("tareas"))
        #expect(note.contains("openrouter"))
        #expect(note.contains("audio nunca sale"))
    }

    @Test func memoryNoteMentionsClientAndCountryTags() {
        let note = Textos.Memoria.nota.lowercased()
        #expect(note.contains("cliente"))
        #expect(note.contains("país"))
        #expect(note.contains("etiquetas"))
        // Still true: minutes and audio never leave.
        #expect(note.contains("minuta nunca se envía"))
        #expect(note.contains("audio nunca sale"))
    }

    @Test func localNetworkDescriptionMentionsClientAndCountryTags() throws {
        let text = try #require(try Self.plist()["NSLocalNetworkUsageDescription"] as? String).lowercased()
        #expect(text.contains("cliente"))
        #expect(text.contains("país"))
        #expect(text.contains("etiquetas"))
        #expect(text.contains("nunca envía el audio"))
    }

    // MARK: - Calendar

    /// For sessions linked to a calendar event the event title and invitee
    /// names go out with the transcript; emails never do.
    private static func assertCalendarDisclosure(_ text: String, sourceLabel: String) {
        let lower = text.lowercased()
        #expect(lower.contains("calendario"), "\(sourceLabel)")
        #expect(lower.contains("título del evento"), "\(sourceLabel)")
        #expect(lower.contains("invitados"), "\(sourceLabel)")
        #expect(lower.contains("quitar evento del calendario"), "\(sourceLabel)")
        #expect(lower.contains("correos"), "\(sourceLabel)")
    }

    @Test func openRouterNoteDisclosesTheCalendarEvent() {
        Self.assertCalendarDisclosure(Textos.Ajustes.privacidadNota, sourceLabel: "privacidadNota")
        let note = Textos.Ajustes.privacidadNota.lowercased()
        #expect(note.contains("openrouter"))
        #expect(note.contains("audio nunca sale"))
    }

    @Test func memoryNoteDisclosesTheCalendarEvent() {
        Self.assertCalendarDisclosure(Textos.Memoria.nota, sourceLabel: "Memoria.nota")
        #expect(Textos.Memoria.nota.lowercased().contains("titulo"))
        #expect(Textos.Memoria.nota.lowercased().contains("asistentes"))
    }

    @Test func localNetworkDescriptionDisclosesTheCalendarEvent() throws {
        let text = try #require(try Self.plist()["NSLocalNetworkUsageDescription"] as? String)
        Self.assertCalendarDisclosure(text, sourceLabel: "NSLocalNetworkUsageDescription")
    }

    @Test func calendarUsageDescriptionIsSpanishReadOnlyAndTruthful() throws {
        let text = try #require(try Self.plist()["NSCalendarsFullAccessUsageDescription"] as? String)
        let lower = text.lowercased()
        #expect(lower.contains("solo lee"))
        #expect(lower.contains("título"))
        #expect(lower.contains("invitados"))
        #expect(lower.contains("nunca modifica"))
        #expect(lower.contains("nunca salen de este mac"))
    }

    @Test func calendarSettingsCopyNeverPromisesWhatTheAppDoesNotDo() {
        let note = Textos.Calendario.nota.lowercased()
        #expect(note.contains("opcional") || note.contains("solo si"))
        #expect(note.contains("nunca modifica"))
        #expect(note.contains("correos"))
    }

    @Test func entitlementsDeclareCalendars() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packaging/MeetingVox.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["com.apple.security.personal-information.calendars"] as? Bool == true)
        #expect(plist["com.apple.security.device.audio-input"] as? Bool == true)
    }
}
