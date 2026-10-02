import Foundation
import Testing
@testable import MeetingVox

@Suite struct HindsightStatusTests {
    private let tz = TimeZone(identifier: "America/Mexico_City")!
    private let sentAt = ISO8601DateFormatter().date(from: "2026-09-24T18:00:00Z")!

    private func facts(
        words: Int = 500, duration: Int? = 3600, started: String = "2026-09-24T16:00:00Z",
        contentHash: String? = "h1", sentHash: String? = nil, failed: Bool = false,
        request: HindsightRequestMarker? = nil, skipped: Bool = false, hasTranscript: Bool = true
    ) -> HindsightFacts {
        var f = HindsightFacts(started: ISO8601DateFormatter().date(from: started))
        f.hasTranscript = hasTranscript
        f.words = words
        f.durationSeconds = duration
        f.contentHash = contentHash
        f.sent = sentHash.map {
            HindsightSentRecord(documentID: "mv-2026.09.24-1000", contentHash: $0, operationID: "op", sentAt: sentAt)
        }
        f.failed = failed
        f.request = request
        f.skipped = skipped
        return f
    }

    private func settings(enabled: Bool = true, autoSend: Bool = false, since: String? = nil) -> HindsightStatus.Settings {
        HindsightStatus.Settings(enabled: enabled, autoSend: autoSend, since: since, minWords: 150, minMinutes: 2)
    }

    private func derive(
        _ f: HindsightFacts?, _ s: HindsightStatus.Settings? = nil, paused: Bool = false
    ) -> HindsightStatus? {
        HindsightStatus.derive(facts: f, settings: s ?? settings(), timeZone: tz, authPaused: paused)
    }

    private let plain = HindsightRequestMarker(force: false, requestedAt: nil)

    @Test func nothingWhenDisabledWithoutFactsOrWithoutTranscript() {
        #expect(derive(facts(), settings(enabled: false)) == nil)
        #expect(derive(nil) == nil)
        #expect(derive(facts(hasTranscript: false)) == nil)
    }

    @Test func manualUnsentSessionOffersSend() {
        #expect(derive(facts()) == .notSent)
        #expect(HindsightStatus.notSent.action == .send)
    }

    @Test func shortSessionOffersSendAnyway() {
        #expect(derive(facts(words: 20)) == .short)
        #expect(derive(facts(duration: 60)) == .short)
        #expect(HindsightStatus.short.action == .sendAnyway)
    }

    @Test func requestedSessionIsPendingEvenIfShortAndErrorWhilePaused() {
        #expect(derive(facts(words: 20, request: plain)) == .pending)
        #expect(derive(facts(request: plain), paused: true) == .error)
        #expect(HindsightStatus.pending.action == .retry)
        #expect(HindsightStatus.error.action == .retry)
    }

    @Test func sentWithTheCurrentContentIsInMemoryAndOffersResend() {
        #expect(derive(facts(sentHash: "h1")) == .sent(sentAt, bank: nil))
        #expect(derive(facts(sentHash: "h1"), paused: true) == .sent(sentAt, bank: nil))
        #expect(HindsightStatus.sent(sentAt, bank: nil).action == .resend)
    }

    @Test func sentShowsTheRecordedBankOrTheDefault() {
        var f = facts(sentHash: "h1")
        let withDefault = HindsightStatus.Settings(
            enabled: true, autoSend: false, since: nil, minWords: 150, minMinutes: 2, defaultBank: "meetingvox"
        )
        #expect(derive(f, withDefault) == .sent(sentAt, bank: "meetingvox"))
        f.sent = HindsightSentRecord(
            documentID: "mv-2026.09.24-1000", contentHash: "h1", operationID: "op", sentAt: sentAt, bank: "archivo"
        )
        #expect(derive(f, withDefault) == .sent(sentAt, bank: "archivo"))
    }

    @Test func onlySendActionsChooseABank() {
        #expect(HindsightStatus.Action.send.choosesBank)
        #expect(HindsightStatus.Action.sendAnyway.choosesBank)
        #expect(!HindsightStatus.Action.resend.choosesBank)
        #expect(!HindsightStatus.Action.retry.choosesBank)
    }

    @Test func sentWithAChangedTranscriptIsPending() {
        #expect(derive(facts(sentHash: "old")) == .pending)
    }

    /// A forced resend (or a plain request not yet drained) on a session
    /// already in memory for the current content must show as pending, not
    /// "En memoria" — the outstanding request is about to change what's
    /// there.
    @Test func sentWithAnOutstandingRequestIsPending() {
        let forced = HindsightRequestMarker(force: true, requestedAt: nil)
        #expect(derive(facts(sentHash: "h1", request: forced)) == .pending)
        #expect(derive(facts(sentHash: "h1", request: plain)) == .pending)
        #expect(derive(facts(sentHash: "h1", request: forced), paused: true) == .error)
    }

    @Test func failedIsErrorUnlessTheCurrentContentIsInMemory() {
        #expect(derive(facts(failed: true)) == .error)
        #expect(derive(facts(sentHash: "h1", failed: true)) == .sent(sentAt, bank: nil))
    }

    @Test func omittedWinsAndOffersSend() {
        #expect(derive(facts(sentHash: "h1", failed: true, request: plain, skipped: true)) == .omitted)
        #expect(HindsightStatus.omitted.action == .send)
    }

    @Test func autoModeEligibleSessionsArePending() {
        let auto = settings(autoSend: true, since: "2026-09-24")
        #expect(derive(facts(), auto) == .pending)
        #expect(derive(facts(started: "2026-09-24T05:00:00Z"), auto) == .notSent, "23:00 the day before in Mexico City")
        #expect(derive(facts(words: 20), auto) == .short)
        #expect(derive(facts(), settings(autoSend: true, since: nil)) == .notSent)
    }

    @Test func actionTitles() {
        #expect(HindsightStatus.Action.send.title == Textos.Memoria.enviar)
        #expect(HindsightStatus.Action.sendAnyway.title == Textos.Memoria.enviarIgual)
        #expect(HindsightStatus.Action.resend.title == Textos.Memoria.reenviar)
        #expect(HindsightStatus.Action.retry.title == Textos.Memoria.reintentarEnvio)
    }

    @Test func settingsFromConfig() {
        let s = HindsightStatus.Settings(config: ConfigValues(raw: ["hindsight": [
            "enabled": true, "auto_send": true, "since": "2026-09-24", "min_words": 10, "min_minutes": 1, "bank": "meetingvox",
        ]]))
        #expect(s.enabled && s.autoSend)
        #expect(s.since == "2026-09-24")
        #expect(s.minWords == 10 && s.minMinutes == 1)
        #expect(s.defaultBank == "meetingvox")
    }

    // MARK: - isStillOffered

    @Test func anActionIsStillOfferedOnlyWhileTheLiveStatusOffersIt() {
        #expect(HindsightStatus.Action.send.isStillOffered(by: .notSent))
        #expect(HindsightStatus.Action.sendAnyway.isStillOffered(by: .short))
        #expect(HindsightStatus.Action.resend.isStillOffered(by: .sent(sentAt, bank: nil)))
        #expect(HindsightStatus.Action.retry.isStillOffered(by: .error))
        #expect(HindsightStatus.Action.retry.isStillOffered(by: .pending))
    }

    @Test func aSendIsRefusedOnceTheSessionIsInMemoryPendingOrGone() {
        // The menu offered "Enviar a memoria"; the disk moved on since.
        #expect(!HindsightStatus.Action.send.isStillOffered(by: .sent(sentAt, bank: "meetingvox")))
        #expect(!HindsightStatus.Action.send.isStillOffered(by: .pending))
        #expect(!HindsightStatus.Action.send.isStillOffered(by: .short))
        #expect(!HindsightStatus.Action.send.isStillOffered(by: nil), "integration off or no transcript")
        #expect(!HindsightStatus.Action.resend.isStillOffered(by: .notSent))
        #expect(!HindsightStatus.Action.retry.isStillOffered(by: .sent(sentAt, bank: nil)))
    }

    @Test func omittingSinceTheMenuWasShownBlocksASendButAnOmittedRowMayLiftIt() {
        // Shown as sendable, omitted meanwhile: the user's "No enviar" wins.
        #expect(!HindsightStatus.Action.send.isStillOffered(by: .omitted, shownAs: .notSent))
        #expect(!HindsightStatus.Action.send.isStillOffered(by: .omitted))
        // The row already said "No se envía · Enviar a memoria": lifting it is the click's meaning.
        #expect(HindsightStatus.Action.send.isStillOffered(by: .omitted, shownAs: .omitted))
        // Shown as omitted, but the user lifted it elsewhere: now a plain sendable session.
        #expect(HindsightStatus.Action.send.isStillOffered(by: .notSent, shownAs: .omitted))
    }
}
