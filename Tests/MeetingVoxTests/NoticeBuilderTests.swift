import Foundation
import Testing
@testable import MeetingVox

/// Pure `Notice` values. No failure copy may send the user to a
/// log file, and osascript notices (no actions) may not promise buttons.
@Suite struct NoticeBuilderTests {
    private let dir = URL(fileURLWithPath: "/tmp/rec/2026.09.29-1030", isDirectory: true)
    private let name = "2026.09.29-1030"

    private var allFailureNotices: [Notice] {
        var notices: [Notice] = []
        for stage in [Notice.Stage.transcription, .minutes, .summary, .memory] {
            notices.append(NoticeBuilder.failed(stage, session: dir))
        }
        notices.append(NoticeBuilder.stillPending(.minutes, session: dir))
        notices.append(NoticeBuilder.stillPending(.summary, session: dir))
        notices.append(NoticeBuilder.minutesNotGeneratedFromMeetings(session: dir))
        notices.append(NoticeBuilder.minutesNotRegenerated(session: dir))
        return notices
    }

    // MARK: - Ready

    @Test func readyListsEveryPartInAFixedOrder() {
        let notice = NoticeBuilder.ready(
            session: dir, label: "Kickoff Proveedor", parts: [.summary, .transcript, .minutes], memoryAction: false
        )
        #expect(notice.title == Textos.Notificacion.reunionLista)
        #expect(notice.body == Textos.Notificacion.reunionListaCuerpo(
            "Kickoff Proveedor", partes: ["transcripción", "minuta", "resumen"]
        ))
        #expect(notice.kind == .ready(memoryAction: false))
        #expect(notice.session == dir)
    }

    @Test func readyWithOnlyTheTranscriptNamesOnlyIt() {
        let notice = NoticeBuilder.ready(session: dir, label: "Reunión", parts: [.transcript], memoryAction: true)
        #expect(notice.body == Textos.Notificacion.reunionListaCuerpo("Reunión", partes: ["transcripción"]))
        #expect(notice.body.contains("minuta") == false)
        #expect(notice.kind == .ready(memoryAction: true))
    }

    @Test func readyNamesWhatFailedAfterWhatIsReady() {
        let notice = NoticeBuilder.ready(
            session: dir, label: "Kickoff", parts: [.transcript, .minutes], memoryAction: false, failed: [.summary]
        )
        #expect(notice.body == Textos.Notificacion.reunionListaCuerpo(
            "Kickoff", partes: ["transcripción", "minuta"], fallos: [Textos.Notificacion.fallaResumen]
        ))
        #expect(notice.body.contains("resumen"))
        #expect(notice.kind == .ready(memoryAction: false))
    }

    @Test func readyNamesEveryFailureInAFixedOrder() {
        let notice = NoticeBuilder.ready(
            session: dir, label: "K", parts: [.transcript], memoryAction: false, failed: [.memory, .summary]
        )
        #expect(notice.body == Textos.Notificacion.reunionListaCuerpo(
            "K", partes: ["transcripción"],
            fallos: [Textos.Notificacion.fallaResumen, Textos.Notificacion.fallaMemoria]
        ))
    }

    @Test func readyWithoutFailuresIsUnchanged() {
        let notice = NoticeBuilder.ready(session: dir, label: "K", parts: [.transcript], memoryAction: false)
        #expect(notice.body == Textos.Notificacion.reunionListaCuerpo("K", partes: ["transcripción"]))
        #expect(!notice.body.contains("·"))
    }

    @Test func aMinutesFailureSaysTheTranscriptIsAvailable() {
        let notice = NoticeBuilder.failed(.minutes, session: dir)
        #expect(notice.body.lowercased().contains("transcripción"))
        #expect(notice.body == Textos.Notificacion.minutaFallidaCuerpo(name))
    }

    @Test func readyBodyMentionsTheLabel() {
        let notice = NoticeBuilder.ready(session: dir, label: "Kickoff", parts: [.transcript, .summary], memoryAction: false)
        #expect(notice.body.contains("Kickoff"))
    }

    // MARK: - Minutes ready (user initiated)

    @Test func minutesReadyCarriesTheFileToOpen() {
        let notice = NoticeBuilder.minutesReady(session: dir, file: "minuta.reunion.md")
        #expect(notice.title == Textos.Notificacion.minutaLista)
        #expect(notice.body == name)
        #expect(notice.kind == .minutesReady(file: "minuta.reunion.md"))
        #expect(notice.session == dir)
    }

    // MARK: - Failures

    @Test func permanentFailuresNameTheStageAndCarryItsKind() {
        let expected: [(Notice.Stage, String, Bool)] = [
            (.transcription, Textos.Notificacion.transcripcionFallida, true),
            (.minutes, Textos.Notificacion.minutaFallida, true),
            (.summary, Textos.Notificacion.resumenFallido, true),
            (.memory, Textos.Memoria.envioRechazado, false),
        ]
        for (stage, title, retryable) in expected {
            let notice = NoticeBuilder.failed(stage, session: dir)
            #expect(notice.title == title)
            #expect(notice.kind == .failure(stage, retryable: retryable))
            #expect(notice.session == dir)
            #expect(notice.body.contains(name))
        }
    }

    @Test func noFailureCopyPointsToALogFile() {
        let notices = allFailureNotices
        #expect(notices.count == 8)
        for notice in notices {
            let text = (notice.title + " " + notice.body).lowercased()
            #expect(!text.contains("revisa"), "\(notice.title): \(notice.body)")
            #expect(!text.contains(".log"), "\(notice.title): \(notice.body)")
        }
    }

    /// osascript notices have no actions: the copy must not promise
    /// a button (only the native notices add Reintentar and Ver reunión).
    @Test func permanentFailureCopyPromisesNoButtons() {
        for stage in [Notice.Stage.transcription, .minutes, .summary, .memory] {
            let notice = NoticeBuilder.failed(stage, session: dir)
            let text = (notice.title + " " + notice.body).lowercased()
            #expect(!text.contains("botón"))
            #expect(!text.contains("reintentar"))
            #expect(!text.contains("ver reunión"))
        }
    }

    @Test func hindsightRejectionHasItsOwnCopyWithoutALogReference() {
        let notice = NoticeBuilder.failed(.memory, session: dir)
        #expect(notice.body == Textos.Memoria.envioRechazadoCuerpo(name))
        #expect(!notice.body.lowercased().contains("hindsight.log"))
    }

    @Test func stillPendingKeepsTheTruthfulExistingCopy() {
        let minutes = NoticeBuilder.stillPending(.minutes, session: dir)
        #expect(minutes.title == Textos.Notificacion.minutaFallida)
        #expect(minutes.body == Textos.Notificacion.minutaSigue(name))
        #expect(minutes.kind == .failure(.minutes, retryable: true))

        let summary = NoticeBuilder.stillPending(.summary, session: dir)
        #expect(summary.title == Textos.Notificacion.resumenFallido)
        #expect(summary.body == Textos.Notificacion.resumenSigue(name))
        #expect(summary.kind == .failure(.summary, retryable: true))
    }

    @Test func userInitiatedMinutesFailuresKeepTheirOwnCopy() {
        #expect(NoticeBuilder.minutesNotGeneratedFromMeetings(session: dir).body
            == Textos.Notificacion.minutaNoGeneradaDesdeVentana(name))
        #expect(NoticeBuilder.minutesNotRegenerated(session: dir).body
            == Textos.Notificacion.minutaNoRegenerada(name))
    }

    // MARK: - Identifiers

    @Test func identifiersReplaceARepostAndSeparateStages() {
        let ready = NoticeBuilder.ready(session: dir, label: "x", parts: [.transcript], memoryAction: false)
        #expect(ready.identifier == "ready-2026.09.29-1030")
        let minutes = NoticeBuilder.failed(.minutes, session: dir)
        #expect(minutes.identifier == "failure-2026.09.29-1030-minutes")
        #expect(NoticeBuilder.failed(.minutes, session: dir).identifier == minutes.identifier)
        #expect(NoticeBuilder.failed(.summary, session: dir).identifier == "failure-2026.09.29-1030-summary")
        #expect(NoticeBuilder.minutesReady(session: dir, file: "minuta.md").identifier == "minutes-2026.09.29-1030")
    }

    @Test func aSessionlessInfoNoticeStillHasAnIdentifier() {
        let notice = Notice(title: "T", body: "B")
        #expect(notice.kind == .info)
        #expect(notice.session == nil)
        #expect(notice.identifier == "info-T")
    }
}
