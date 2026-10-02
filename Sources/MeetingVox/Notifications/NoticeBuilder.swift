import Foundation

/// Pure constructors for every `Notice` the pipelines post. All copy comes
/// from `Textos`; none of it points the user to a log file, and none names a
/// button (the bare-binary backend has none).
enum NoticeBuilder {
    /// The one "ready" notice. `label` is the session's title
    /// (`SessionLabel`); parts are listed in a fixed order. `failed` are
    /// secondary stages (summary, memory) that ended badly: the meeting is
    /// still ready, and the body says what did not work.
    static func ready(
        session: URL, label: String, parts: Set<SessionSettlement.Part>, memoryAction: Bool,
        failed: Set<Notice.Stage> = []
    ) -> Notice {
        let names: [(SessionSettlement.Part, String)] = [
            (.transcript, Textos.Notificacion.parteTranscripcion),
            (.minutes, Textos.Notificacion.parteMinuta),
            (.summary, Textos.Notificacion.parteResumen),
        ]
        let failures: [(Notice.Stage, String)] = [
            (.summary, Textos.Notificacion.fallaResumen),
            (.memory, Textos.Notificacion.fallaMemoria),
        ]
        return Notice(
            title: Textos.Notificacion.reunionLista,
            body: Textos.Notificacion.reunionListaCuerpo(
                label, partes: names.filter { parts.contains($0.0) }.map(\.1),
                fallos: failures.filter { failed.contains($0.0) }.map(\.1)
            ),
            kind: .ready(memoryAction: memoryAction),
            session: session
        )
    }

    /// A minutes request the user made finished writing `file`.
    static func minutesReady(session: URL, file: String) -> Notice {
        Notice(
            title: Textos.Notificacion.minutaLista, body: session.lastPathComponent,
            kind: .minutesReady(file: file), session: session
        )
    }

    /// A stage failed for good.
    static func failed(_ stage: Notice.Stage, session: URL) -> Notice {
        let name = session.lastPathComponent
        let (title, body): (String, String) = switch stage {
        case .transcription: (Textos.Notificacion.transcripcionFallida, Textos.Notificacion.transcripcionFallidaCuerpo(name))
        case .minutes: (Textos.Notificacion.minutaFallida, Textos.Notificacion.minutaFallidaCuerpo(name))
        case .summary: (Textos.Notificacion.resumenFallido, Textos.Notificacion.resumenFallidoCuerpo(name))
        case .memory: (Textos.Memoria.envioRechazado, Textos.Memoria.envioRechazadoCuerpo(name))
        }
        return Notice(title: title, body: body, kind: .failure(stage, retryable: stage != .memory), session: session)
    }

    /// Transient retries ran out: the request stays pending. Only minutes and
    /// summaries retry transiently (anything else is worded as minutes).
    static func stillPending(_ stage: Notice.Stage, session: URL) -> Notice {
        let name = session.lastPathComponent
        let (title, body): (String, String) = switch stage {
        case .summary: (Textos.Notificacion.resumenFallido, Textos.Notificacion.resumenSigue(name))
        default: (Textos.Notificacion.minutaFallida, Textos.Notificacion.minutaSigue(name))
        }
        return Notice(title: title, body: body, kind: .failure(stage == .summary ? .summary : .minutes, retryable: true), session: session)
    }

    /// Exhausted retries of a minutes request made from the main window.
    static func minutesNotGeneratedFromMeetings(session: URL) -> Notice {
        Notice(
            title: Textos.Notificacion.minutaFallida,
            body: Textos.Notificacion.minutaNoGeneradaDesdeVentana(session.lastPathComponent),
            kind: .failure(.minutes, retryable: true), session: session
        )
    }

    /// Exhausted retries of "Regenerar minuta con": the current minutes stay.
    static func minutesNotRegenerated(session: URL) -> Notice {
        Notice(
            title: Textos.Notificacion.minutaFallida,
            body: Textos.Notificacion.minutaNoRegenerada(session.lastPathComponent),
            kind: .failure(.minutes, retryable: true), session: session
        )
    }
}
