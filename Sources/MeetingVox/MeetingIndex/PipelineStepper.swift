import Foundation

/// One dot of the detail header's stepper.
struct PipelineStep: Equatable, Sendable, Identifiable {
    enum Kind: CaseIterable, Sendable {
        case grabada, transcrita, minuta, resumen, memoria

        var title: String {
            switch self {
            case .grabada: Textos.Principal.pasoGrabada
            case .transcrita: Textos.Principal.pasoTranscrita
            case .minuta: Textos.Principal.pasoMinuta
            case .resumen: Textos.Principal.pasoResumen
            case .memoria: Textos.Principal.pasoMemoria
            }
        }
    }

    /// `skipped`: the step will not happen (feature off, nothing to send).
    enum State: Equatable, Sendable {
        case done, active, pending, failed, skipped
    }

    let kind: Kind
    let state: State

    var id: Kind { kind }
    var title: String { kind.title }
}

/// Grabada, Transcrita, Minuta, Resumen, Memoria for one session (PS-1..3).
/// Disk markers are the truth (`MeetingEntry` carries them with
/// `SessionSettlement.Facts`' precedence); the live overlay can only turn a
/// step that has no marker into `active` — never `done`, never `failed`.
/// Pure.
enum PipelineStepper {
    /// - Parameters:
    ///   - memory: `HindsightStatus.derive` result; nil when the integration
    ///     is off or there is no transcript.
    ///   - recording: this folder is being recorded right now.
    ///   - summaryApplies: `SummaryGate.applies` for the session (needs the
    ///     Keychain attribute check, so the caller snapshots it once per
    ///     reload).
    static func derive(
        entry: MeetingEntry, memory: HindsightStatus?, live: LiveStages, recording: Bool, summaryApplies: Bool
    ) -> [PipelineStep] {
        let grabada: PipelineStep.State = recording ? .active : .done
        let transcrita = transcription(entry, live: live, recording: recording)
        let minuta = minutes(entry, live: live)
        var resumen = summary(entry, live: live, summaryApplies: summaryApplies)
        var memoria = memoryStep(entry, memory: memory, live: live)

        // Once the minutes failed for good, whatever is still to come waits
        // (or stays skipped); steps that finished or failed on their own
        // markers keep that.
        if minuta == .failed {
            resumen = afterFailure(resumen)
            memoria = afterFailure(memoria)
        }
        return zip(PipelineStep.Kind.allCases, [grabada, transcrita, minuta, resumen, memoria]).map {
            PipelineStep(kind: $0, state: $1)
        }
    }

    private static func afterFailure(_ state: PipelineStep.State) -> PipelineStep.State {
        state == .active ? .pending : state
    }

    private static func transcription(_ entry: MeetingEntry, live: LiveStages, recording: Bool) -> PipelineStep.State {
        if entry.hasTranscript { return .done }
        if recording { return .pending }
        return live[.transcription] != nil ? .active : .pending
    }

    private static func minutes(_ entry: MeetingEntry, live: LiveStages) -> PipelineStep.State {
        switch entry.minutesState {
        case .pending: return .active
        case .done: return .done
        case .failed: return .failed
        case .absent:
            if live[.minutes] != nil { return .active }
            // Automatic minutes leave `minuta.pendiente` right after the
            // transcript, so a transcript with no marker never asked for them.
            return entry.hasTranscript ? .skipped : .pending
        }
    }

    private static func summary(_ entry: MeetingEntry, live: LiveStages, summaryApplies: Bool) -> PipelineStep.State {
        switch entry.summaryState {
        case .pending: return .active
        case .done: return .done
        case .failed: return .failed
        case .absent:
            if live[.summary] != nil { return .active }
            if !entry.hasTranscript { return .pending }
            return summaryApplies ? .pending : .skipped
        }
    }

    private static func memoryStep(_ entry: MeetingEntry, memory: HindsightStatus?, live: LiveStages) -> PipelineStep.State {
        switch memory {
        case .sent: return .done
        case .error: return .failed
        case .pending: return live[.memory] != nil ? .active : .pending
        // Sendable and not sent: the step is still ahead ("Enviar"); an omitted
        // session was told never to go, so it stays out.
        case .short, .notSent: return live[.memory] != nil ? .active : .pending
        case .omitted: return live[.memory] != nil ? .active : .skipped
        case nil:
            // No transcript yet means the integration state is unknown, not off.
            return entry.hasTranscript ? .skipped : .pending
        }
    }
}
