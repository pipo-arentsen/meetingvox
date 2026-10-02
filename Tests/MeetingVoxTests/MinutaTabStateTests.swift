import Foundation
import Testing
@testable import MeetingVox

/// What the Minuta tab shows (DT-2): the document, a progress bar, "Reintentar"
/// for minutes still owed, or the template picker with "Generar minuta". It is
/// `MinutesRequestRoute` plus the live overlay, so the tab, the notices and the
/// old Reuniones button all agree on what a session is owed.
@Suite struct MinutaTabStateTests {
    private func derive(
        minutes: Bool = false, pending: Bool = false, failed: Bool = false, transcript: Bool = true,
        live: LiveStages = [:], reason: String? = nil
    ) -> MinutaTabState {
        MinutaTabState.derive(
            hasMinutes: minutes, minutesPending: pending, minutesFailed: failed, hasTranscript: transcript,
            live: live, unavailableReason: reason
        )
    }

    // MARK: - Document

    @Test func minutesOnDiskShowTheDocument() {
        #expect(derive(minutes: true) == .document(regenerating: false))
    }

    @Test func aRegenerationRunningKeepsTheDocumentAndSaysSo() {
        #expect(derive(minutes: true, live: [.minutes: .running]) == .document(regenerating: true))
        #expect(derive(minutes: true, live: [.minutes: .waitingRetry]) == .document(regenerating: true))
        #expect(derive(minutes: true, live: [.summary: .running]) == .document(regenerating: false), "another stage is not ours")
    }

    @Test func aStaleErrorNextToTheMinutesDoesNotHideThem() {
        #expect(derive(minutes: true, failed: true) == .document(regenerating: false))
    }

    // MARK: - Reintentar (the retry scenario)

    @Test func minutesFailedForGoodOfferReintentarAndNotGenerar() {
        #expect(derive(failed: true) == .retry(failed: true, unavailableReason: nil))
    }

    @Test func minutesStillPendingOfferReintentarToo() {
        #expect(derive(pending: true) == .retry(failed: false, unavailableReason: nil))
    }

    @Test func aRetryThatCannotRunCarriesTheReason() {
        #expect(derive(failed: true, reason: "Falta la clave") == .retry(failed: true, unavailableReason: "Falta la clave"))
    }

    // MARK: - Running

    @Test func aRunningJobShowsProgressWhateverTheMarkersSay() {
        #expect(derive(pending: true, live: [.minutes: .running]) == .running(waitingRetry: false))
        #expect(derive(failed: true, live: [.minutes: .running]) == .running(waitingRetry: false))
        #expect(derive(live: [.minutes: .running]) == .running(waitingRetry: false), "a user-requested job leaves no marker")
    }

    @Test func aJobWaitingToRetryIsRunningWithThatNote() {
        #expect(derive(pending: true, live: [.minutes: .waitingRetry]) == .running(waitingRetry: true))
    }

    // MARK: - Generar

    @Test func aTranscriptWithNothingOwedOffersThePickerAndGenerar() {
        #expect(derive() == .generate(unavailableReason: nil))
    }

    @Test func generarIsUnavailableWithTheReasonWhenMinutesCannotRun() {
        #expect(derive(reason: "Falta el modelo") == .generate(unavailableReason: "Falta el modelo"))
    }

    @Test func withoutATranscriptThereIsNothingToGenerateFrom() {
        #expect(derive(transcript: false) == .noTranscript)
    }

    // MARK: - From a scanned entry

    @Test func theEntryOverloadReadsTheMarkers() {
        let plain = makeEntry()
        #expect(MinutaTabState.derive(entry: plain, live: [:], unavailableReason: nil) == .generate(unavailableReason: nil))
        let failed = makeEntry(minutesFailed: true)
        #expect(MinutaTabState.derive(entry: failed, live: [:], unavailableReason: nil) == .retry(failed: true, unavailableReason: nil))
        let done = makeEntry(hasMinutes: true)
        #expect(MinutaTabState.derive(entry: done, live: [:], unavailableReason: nil) == .document(regenerating: false))
    }

    // MARK: - The picker's starting choice

    private let templates = [FactoryTemplates.general, FactoryTemplates.daily, FactoryTemplates.comercial]

    @Test func theSessionsOwnChoiceComesFirst() {
        #expect(MinutaTabState.initialTemplate(templates, sessionChoice: "daily", configured: "general") == "daily")
    }

    @Test func aChoiceThatNoLongerExistsFallsBackToTheConfiguredTemplate() {
        #expect(MinutaTabState.initialTemplate(templates, sessionChoice: "borrada", configured: "comercial") == "comercial")
        #expect(MinutaTabState.initialTemplate(templates, sessionChoice: nil, configured: "comercial") == "comercial")
    }

    @Test func withNeitherThePickerStartsOnTheFirstTemplateAndAnEmptyListHasNone() {
        #expect(MinutaTabState.initialTemplate(templates, sessionChoice: nil, configured: "no-existe") == "general")
        #expect(MinutaTabState.initialTemplate([], sessionChoice: "daily", configured: "general") == nil)
    }
}
