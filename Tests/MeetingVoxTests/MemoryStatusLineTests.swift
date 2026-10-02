import Foundation
import Testing
@testable import MeetingVox

/// The sentence the detail keeps for the memory state — what the Reuniones row
/// said next to its button ("En memoria (banco) — fecha", "Error al enviar",
/// "No se envía", "Pendiente", "Muy corta") and the stepper's dot cannot.
@Suite struct MemoryStatusLineTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let sentAt = ISO8601DateFormatter().date(from: "2026-09-24T18:05:00Z")!

    @Test func aSentSessionNamesTheBankAndWhen() {
        #expect(MemoryStatusLine.text(.sent(sentAt, bank: "meetingvox"), timeZone: utc) == "En memoria (meetingvox) — 24 sep 2026, 18:05")
    }

    @Test func theTimeIsShownInTheGivenZone() {
        let santiago = TimeZone(secondsFromGMT: -3 * 3600)!
        #expect(MemoryStatusLine.text(.sent(sentAt, bank: nil), timeZone: santiago) == "En memoria — 24 sep 2026, 15:05")
    }

    @Test func theOtherStatesHaveTheirOwnWords() {
        #expect(MemoryStatusLine.text(.error, timeZone: utc) == "Error al enviar")
        #expect(MemoryStatusLine.text(.omitted, timeZone: utc) == "No se envía")
        #expect(MemoryStatusLine.text(.pending, timeZone: utc) == "Pendiente")
        #expect(MemoryStatusLine.text(.short, timeZone: utc) == "Muy corta")
    }

    @Test func nothingToSayForASessionNotSentYetOrWithTheIntegrationOff() {
        #expect(MemoryStatusLine.text(.notSent, timeZone: utc) == nil)
        #expect(MemoryStatusLine.text(nil, timeZone: utc) == nil)
    }
}
