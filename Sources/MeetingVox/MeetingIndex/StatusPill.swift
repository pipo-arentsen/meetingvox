import Foundation

/// The one status chip on a list row. At most one: `derive` returns a
/// single optional, so "two pills" cannot be represented. Pure.
///
/// Precedence: recording > error > active step > sending / pending > sent >
/// none (a finished session that is not in memory shows nothing).
enum StatusPill: Equatable, Sendable {
    case recording
    case error
    /// The stage that is running or still owed.
    case active(Notice.Stage)
    /// The memory send is in flight.
    case sending
    /// Waiting to be sent to memory.
    case pending
    case sent

    /// - Parameters:
    ///   - memory: `HindsightStatus.derive` for the entry; nil when the
    ///     integration is off or there is no transcript.
    ///   - live: the in-memory overlay for this folder (`PipelineState.live`).
    ///   - recordingDir: the folder being recorded right now, if any.
    static func derive(
        entry: MeetingEntry, memory: HindsightStatus?, live: LiveStages, recordingDir: URL?
    ) -> StatusPill? {
        if let recordingDir, recordingDir.standardizedFileURL.path == entry.dir.standardizedFileURL.path {
            return .recording
        }

        if entry.minutesState == .failed || entry.summaryState == .failed || memory == .error { return .error }

        if let stage = activeStage(entry: entry, live: live) { return .active(stage) }

        if live[.memory] != nil { return .sending }
        if memory == .pending { return .pending }
        if case .sent = memory { return .sent }
        return nil
    }

    /// A running/retrying stage first (transcription, minutes, summary), then
    /// what the markers say is owed: `minuta.pendiente`, `resumen.pendiente`.
    ///
    /// Deliberately not derived from "no transcript yet": nothing on disk says
    /// transcription is happening (a folder can lack one for good), so that
    /// would be a permanent "Transcribiendo". Only a live signal shows it,
    /// which is also what the stepper does (its Transcrita stays `.pending`).
    ///
    /// Pill vs stepper: a live minutes/summary run counts as active even while
    /// the output file exists (a regeneration is work in progress the user
    /// should see), whereas the stepper trusts the marker and keeps that step
    /// done.
    private static func activeStage(entry: MeetingEntry, live: LiveStages) -> Notice.Stage? {
        for stage in [Notice.Stage.transcription, .minutes, .summary] where live[stage] != nil { return stage }
        if entry.minutesState == .pending { return .minutes }
        if entry.summaryState == .pending { return .summary }
        return nil
    }

    /// How the chip is coloured: the one thing a view needs besides `label`.
    enum Tone: Equatable, Sendable {
        case recording
        case error
        /// Work under way.
        case running
        /// Quiet information ("Pendiente", "En memoria").
        case neutral
    }

    var tone: Tone {
        switch self {
        case .recording: .recording
        case .error: .error
        case .active, .sending: .running
        case .pending, .sent: .neutral
        }
    }

    /// Draws the small spinner: something is actually being worked on.
    var isBusy: Bool {
        switch self {
        case .active, .sending: true
        case .recording, .error, .pending, .sent: false
        }
    }

    var label: String {
        switch self {
        case .recording: Textos.Principal.pildoraGrabando
        case .error: Textos.Principal.pildoraError
        case .active(.transcription): Textos.Principal.pildoraTranscribiendo
        case .active(.minutes): Textos.Principal.pildoraMinuta
        case .active(.summary): Textos.Principal.pildoraResumen
        case .active(.memory), .sending: Textos.Principal.pildoraEnviando
        case .pending: Textos.Principal.pildoraPendiente
        case .sent: Textos.Principal.pildoraEnMemoria
        }
    }
}
