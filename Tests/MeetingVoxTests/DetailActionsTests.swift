import Foundation
import Testing
@testable import MeetingVox

/// The detail toolbar's contents as pure data: "Regenerar ▾", "Enviar a
/// memoria ▾" and "⋯". These are the intents the sessions menu tests
/// (`SessionsMenuGlossaryTests`, `SessionsMenuRegenerateTests`,
/// `HindsightMenuTests`) pinned, migrated to the builder that replaces that
/// menu's per-session submenu.
@Suite struct DetailActionsTests {
    private let sentAt = ISO8601DateFormatter().date(from: "2026-09-24T18:00:00Z")!
    private let templates = [FactoryTemplates.general, FactoryTemplates.daily]

    private func build(
        transcript: Bool = true, transcriptMD: Bool? = nil, minutes: Bool = true, owed: Bool = false, manual: [String] = [],
        templates: [MinutesTemplate]? = nil, reason: String? = nil,
        memory: HindsightStatus? = nil, defaultBank: String? = nil, otherBanks: [String] = [], inFlight: Bool = false
    ) -> DetailActions {
        DetailActions.build(DetailActions.Input(
            hasTranscript: transcript, hasTranscriptMD: transcriptMD ?? transcript, hasMinutes: minutes, minutesOwed: owed, manualMinutes: manual,
            templates: templates ?? self.templates, minutesUnavailableReason: reason,
            memory: memory, memoryInFlight: inFlight, defaultBank: defaultBank, otherBanks: otherBanks
        ))
    }

    // MARK: - Regenerar ▾

    @Test func regenerateWithIsOfferedOnlyWhenMinutesAndTranscriptExist() {
        #expect(build(minutes: false).regenerate.regenerateWith == nil)
        #expect(build(transcript: false).regenerate.regenerateWith == nil)
        let both = build().regenerate.regenerateWith
        #expect(both?.choices.map(\.title) == [FactoryTemplates.general.nombre, FactoryTemplates.daily.nombre])
        #expect(both?.choices.map(\.id) == ["general", "daily"])
    }

    @Test func aTemplateChoiceCarriesItsDescriptionAsTooltip() {
        let choice = build().regenerate.regenerateWith?.choices.first
        #expect(choice?.tooltip == (FactoryTemplates.general.descripcion.isEmpty ? nil : FactoryTemplates.general.descripcion))
        let bare = MinutesTemplate(id: "x", nombre: "X", descripcion: "", cuerpo: "")
        #expect(build(templates: [bare]).regenerate.regenerateWith?.choices.first?.tooltip == nil)
    }

    @Test func regenerateShowsWhyMinutesCannotRun() {
        let unavailable = build(reason: Textos.Sesiones.sinClave).regenerate
        #expect(unavailable.regenerateWith == .unavailable(Textos.Sesiones.sinClave))
        #expect(unavailable.generateWith == .unavailable(Textos.Sesiones.sinClave))
        #expect(build(templates: []).regenerate.regenerateWith == .unavailable(Textos.Sesiones.sinPlantillas))
    }

    @Test func manualGenerateNeedsATranscriptFirstThenAKeyThenTemplates() {
        #expect(build(transcript: false, minutes: false, reason: Textos.Sesiones.sinClave).regenerate.generateWith
            == .unavailable(Textos.Sesiones.sinTranscripcion))
        #expect(build(minutes: false, reason: Textos.Sesiones.sinModelo).regenerate.generateWith
            == .unavailable(Textos.Sesiones.sinModelo))
        #expect(build(minutes: false, templates: []).regenerate.generateWith == .unavailable(Textos.Sesiones.sinPlantillas))
        #expect(build(minutes: false).regenerate.generateWith.choices.map(\.id) == ["general", "daily"])
    }

    @Test func retryIsOfferedOnlyForOwedMinutesWithATranscript() {
        #expect(build(minutes: false, owed: true).regenerate.retry == DetailActions.Retry(isEnabled: true, tooltip: nil))
        #expect(build(minutes: false, owed: false).regenerate.retry == nil)
        #expect(build(transcript: false, minutes: false, owed: true).regenerate.retry == nil)
        let blocked = build(minutes: false, owed: true, reason: Textos.Sesiones.sinClave).regenerate.retry
        #expect(blocked == DetailActions.Retry(isEnabled: false, tooltip: Textos.Sesiones.sinClave))
    }

    // MARK: - ⋯

    @Test func theOverflowHoldsFolderTranscriptMinutesGlossaryAndTheTrash() {
        let items = build().overflow
        #expect(items.map(\.kind) == [.openFolder, .openTranscript, .openMinutes, .applyGlossary, .moveToTrash])
        #expect(items.map(\.title) == [
            Textos.Principal.mostrarCarpeta, Textos.Sesiones.abrirTranscripcion, Textos.Sesiones.abrirMinuta,
            Textos.Sesiones.aplicarGlosario, Textos.Papelera.mover,
        ])
        #expect(items.allSatisfy { $0.isEnabled })
    }

    @Test func glossaryNeedsATranscriptAndMinutesNeedMinutesButTheFolderAlwaysOpens() {
        let items = build(transcript: false, minutes: false).overflow
        #expect(items.first { $0.kind == .openFolder }?.isEnabled == true)
        #expect(items.first { $0.kind == .openTranscript }?.isEnabled == false)
        #expect(items.first { $0.kind == .openMinutes }?.isEnabled == false)
        #expect(items.first { $0.kind == .applyGlossary }?.isEnabled == false)
        // Minutes without a transcript file still open.
        #expect(build(transcript: false, minutes: true).overflow.first { $0.kind == .openMinutes }?.isEnabled == true)
    }

    @Test func openingTheTranscriptFollowsTheMarkdownFileNotTheJSON() {
        // transcript.json is the done marker; the file the app opens is transcript.md.
        let noMarkdown = build(transcript: true, transcriptMD: false).overflow
        #expect(noMarkdown.first { $0.kind == .openTranscript }?.isEnabled == false)
        #expect(noMarkdown.first { $0.kind == .applyGlossary }?.isEnabled == true, "the glossary works on the JSON")
        #expect(build(transcript: true, transcriptMD: true).overflow.first { $0.kind == .openTranscript }?.isEnabled == true)
    }

    @Test func glossaryLivesUnderTheOverflowNotTheRegenerateMenu() {
        let actions = build()
        #expect(actions.overflow.contains { $0.kind == .applyGlossary })
        #expect(actions.regenerate.regenerateWith?.choices.contains { $0.title == Textos.Sesiones.aplicarGlosario } == false)
    }

    @Test func manualMinutesOpenExternallyByTheirTemplateName() {
        let items = build(manual: ["daily", "viejo"]).overflow
        let manual = items.filter { if case .openManualMinutes = $0.kind { true } else { false } }
        #expect(manual.map(\.kind) == [.openManualMinutes(id: "daily"), .openManualMinutes(id: "viejo")])
        #expect(manual.map(\.title) == [
            Textos.Sesiones.abrirMinuta(FactoryTemplates.daily.nombre), Textos.Sesiones.abrirMinuta("viejo"),
        ], "a deleted template falls back to its id")
        #expect(build().overflow.count == 5, "no manual files, no extra items")
    }

    @Test func theTrashItemIsAlwaysEnabledAndLast() {
        // Blocked sessions (recording, working) are explained by the sheet, not hidden here.
        for items in [build().overflow, build(transcript: false, minutes: false).overflow, build(manual: ["daily"]).overflow] {
            #expect(items.last?.kind == .moveToTrash)
            #expect(items.last?.isEnabled == true)
        }
    }

    // MARK: - Enviar a memoria ▾

    @Test func noMemoryButtonWhenTheIntegrationIsOffOrThereIsNoTranscript() {
        #expect(build(memory: nil).memory == nil)
    }

    @Test func eachStatusOffersItsOwnActionTitle() {
        let titles: [(HindsightStatus, String)] = [
            (.notSent, Textos.Memoria.enviar), (.omitted, Textos.Memoria.enviar), (.short, Textos.Memoria.enviarIgual),
            (.sent(sentAt, bank: nil), Textos.Memoria.reenviar), (.pending, Textos.Memoria.reintentarEnvio),
            (.error, Textos.Memoria.reintentarEnvio),
        ]
        for (status, title) in titles {
            #expect(build(memory: status, defaultBank: "meetingvox").memory?.title == title)
        }
    }

    @Test func theSkipItemIsOfferedUnlessAlreadyOmitted() {
        #expect(build(memory: .notSent, defaultBank: "meetingvox").memory?.canSkip == true)
        #expect(build(memory: .omitted, defaultBank: "meetingvox").memory?.canSkip == false)
    }

    @Test func sendOffersEveryBankWithTheDefaultFirstAndChecked() {
        let memory = build(memory: .notSent, defaultBank: "meetingvox", otherBanks: ["archivo"]).memory
        #expect(memory?.banks?.map(\.title) == [Textos.Memoria.bancoPredeterminado("meetingvox"), "archivo"])
        #expect(memory?.banks?.map(\.isDefault) == [true, false])
        #expect(memory?.banks?.map(\.bank) == [nil, "archivo"], "nil selects the default bank")
        #expect(memory?.isEnabled == true)
        #expect(build(memory: .short, defaultBank: "meetingvox", otherBanks: ["archivo"]).memory?.banks?.count == 2,
                "Enviar igual chooses a bank too")
    }

    @Test func sendStillOffersAMenuWithJustTheDefaultBank() {
        let banks = build(memory: .notSent, defaultBank: "meetingvox", otherBanks: []).memory?.banks
        #expect(banks?.map(\.title) == [Textos.Memoria.bancoPredeterminado("meetingvox")])
        #expect(banks?.map(\.isDefault) == [true])
    }

    @Test func sendOffersOtherBanksWithoutAnUnusableDefault() {
        let memory = build(memory: .notSent, defaultBank: nil, otherBanks: ["archivo", "meetingvox"]).memory
        #expect(memory?.banks?.map(\.title) == ["archivo", "meetingvox"])
        #expect(memory?.banks?.map(\.bank) == ["archivo", "meetingvox"])
        #expect(memory?.isEnabled == true)
    }

    @Test func plainSendIsDisabledWhenNoBankIsKnownAtAll() {
        let memory = build(memory: .notSent, defaultBank: nil, otherBanks: []).memory
        #expect(memory?.banks == nil)
        #expect(memory?.isEnabled == false)
    }

    @Test func resendAndRetryNeverChooseABank() {
        let resend = build(memory: .sent(sentAt, bank: "meetingvox"), defaultBank: "meetingvox", otherBanks: ["archivo"]).memory
        #expect(resend?.banks == nil)
        #expect(resend?.isEnabled == true)
        let retry = build(memory: .error, defaultBank: nil, otherBanks: []).memory
        #expect(retry?.banks == nil)
        #expect(retry?.isEnabled == true, "a retry keeps the recorded bank; it needs none known")
    }

    // MARK: - Stepper "Enviar"

    @Test func aSendableUnsentSessionOffersAQuickSendToTheDefaultBank() {
        let notSent = build(memory: .notSent, defaultBank: "meetingvox", otherBanks: ["archivo"]).memory
        #expect(notSent?.quickSend == DetailActions.QuickSend(action: .send, bank: nil))
        let short = build(memory: .short, defaultBank: "meetingvox").memory
        #expect(short?.quickSend == DetailActions.QuickSend(action: .sendAnyway, bank: nil))
    }

    @Test func withoutADefaultTheQuickSendUsesTheFirstKnownBank() {
        let memory = build(memory: .notSent, defaultBank: nil, otherBanks: ["archivo", "meetingvox"]).memory
        #expect(memory?.quickSend == DetailActions.QuickSend(action: .send, bank: "archivo"))
    }

    @Test func noQuickSendWhenNothingIsSendableOrNoBankIsKnown() {
        #expect(build(memory: .omitted, defaultBank: "meetingvox").memory?.quickSend == nil, "omitted stays out")
        #expect(build(memory: .sent(sentAt, bank: nil), defaultBank: "meetingvox").memory?.quickSend == nil)
        #expect(build(memory: .pending, defaultBank: "meetingvox").memory?.quickSend == nil)
        #expect(build(memory: .notSent, defaultBank: nil, otherBanks: []).memory?.quickSend == nil)
    }

    // MARK: - In flight

    @Test func aSendInFlightDisablesTheMemoryButtonAndTheQuickSend() {
        let idle = build(memory: .notSent, defaultBank: "meetingvox").memory
        #expect(idle?.isEnabled == true && idle?.quickSend != nil)
        let sending = build(memory: .notSent, defaultBank: "meetingvox", inFlight: true).memory
        #expect(sending?.isEnabled == false)
        #expect(sending?.quickSend == nil)
        #expect(sending?.banks?.count == 1, "the menu is still there, just disabled")
        let resend = build(memory: .sent(sentAt, bank: nil), defaultBank: "meetingvox", inFlight: true).memory
        #expect(resend?.isEnabled == false)
    }

    // MARK: - Stale menu

    @Test func aMenuBuiltForANotSentSessionIsRefusedOnceTheSessionIsSent() throws {
        let shown = HindsightStatus.notSent
        let offered = try #require(build(memory: shown, defaultBank: "meetingvox").memory)
        #expect(offered.action.isStillOffered(by: shown, shownAs: shown))
        let live = HindsightStatus.sent(sentAt, bank: "meetingvox")
        #expect(!offered.action.isStillOffered(by: live, shownAs: shown))
        #expect(offered.status == shown, "the builder remembers what it showed, for the re-check")
    }
}
