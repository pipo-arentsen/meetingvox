import Foundation
import Testing
@testable import MeetingVox

@Suite struct StatusPillTests {
    private let sentDate = Date(timeIntervalSince1970: 1_790_000_000)

    private func derive(
        _ entry: MeetingEntry = makeEntry(hasMinutes: true, summaryState: .done),
        memory: HindsightStatus? = nil,
        live: LiveStages = [:],
        recordingDir: URL? = nil
    ) -> StatusPill? {
        StatusPill.derive(entry: entry, memory: memory, live: live, recordingDir: recordingDir)
    }

    // MARK: - Single states

    @Test func aFinishedSessionWithoutMemoryShowsNoPill() {
        #expect(derive() == nil)
        #expect(derive(memory: .notSent) == nil)
        #expect(derive(memory: .short) == nil)
        #expect(derive(memory: .omitted) == nil)
    }

    @Test func recordingWhenThisFolderIsBeingRecorded() {
        let entry = makeEntry(hasTranscript: false)
        #expect(derive(entry, recordingDir: entry.dir) == .recording)
        // Another folder recording, and no live transcription signal: no pill at all.
        #expect(derive(entry, recordingDir: URL(fileURLWithPath: "/fake/root/other")) == nil)
    }

    @Test func recordingComparisonIgnoresTrailingSlashAndDotSegments() {
        let entry = makeEntry("2026.09.29-1000")

        #expect(derive(entry, recordingDir: URL(fileURLWithPath: "/fake/root/2026.09.29-1000/")) == .recording)
        #expect(derive(entry, recordingDir: URL(fileURLWithPath: "/fake/root/./2026.09.29-1000")) == .recording)
        #expect(derive(entry, recordingDir: URL(fileURLWithPath: "/fake/root/2026.09.29-1001/")) == nil)
    }

    @Test func noTranscriptWithoutALiveSignalShowsNoPermanentTranscribingPill() {
        // Same rule as the stepper (.pending): nothing says transcription is happening.
        #expect(derive(makeEntry(hasTranscript: false)) == nil)
        #expect(derive(makeEntry(hasTranscript: false), live: [.transcription: .running]) == .active(.transcription))
        #expect(derive(makeEntry(hasTranscript: false), live: [.transcription: .waitingRetry]) == .active(.transcription))
    }

    @Test func aLiveRegenerationOverAFinishedOutputStillShowsActive() {
        // Intended difference from the stepper: the stepper trusts the marker
        // (Minuta stays done), the pill tells the user work is in progress.
        let done = makeEntry(hasMinutes: true, summaryState: .done)

        #expect(derive(done, live: [.minutes: .running]) == .active(.minutes))
        #expect(derive(done, live: [.summary: .running]) == .active(.summary))
        let stepper = PipelineStepper.derive(entry: done, memory: nil, live: [.minutes: .running], recording: false, summaryApplies: true)
        #expect(stepper[2].state == .done)
    }

    @Test func errorFromEachFailureSource() {
        #expect(derive(makeEntry(minutesFailed: true)) == .error)
        #expect(derive(makeEntry(hasMinutes: true, summaryState: .failed)) == .error)
        #expect(derive(memory: .error) == .error)
    }

    @Test func activeNamesTheStageThatIsRunningOrOwed() {
        #expect(derive(makeEntry(minutesPending: true)) == .active(.minutes))
        #expect(derive(makeEntry(hasMinutes: true, summaryState: .pending)) == .active(.summary))
        #expect(derive(live: [.minutes: .running]) == .active(.minutes))
        #expect(derive(live: [.summary: .waitingRetry]) == .active(.summary))
    }

    @Test func activeStageOrderIsTranscriptionThenMinutesThenSummary() {
        #expect(derive(live: [.summary: .running, .minutes: .running]) == .active(.minutes))
        #expect(derive(live: [.summary: .running, .transcription: .running]) == .active(.transcription))
        #expect(derive(makeEntry(minutesPending: true, summaryState: .pending)) == .active(.minutes))
    }

    @Test func memoryStatesMapToSendingPendingSent() {
        #expect(derive(live: [.memory: .running]) == .sending)
        #expect(derive(memory: .pending) == .pending)
        #expect(derive(memory: .sent(sentDate, bank: "b")) == .sent)
    }

    @Test func sentIsShownForAResendOnlyOnceTheOverlayClears() {
        // A forced resend derives as .pending while it is outstanding.
        #expect(derive(memory: .pending, live: [.memory: .running]) == .sending)
    }

    // MARK: - Precedence: recording > error > active > sending > pending > sent

    /// A situation per rung that also holds when a higher rung's does.
    private struct Rung {
        let name: String
        let expected: StatusPill
        let apply: (inout Scenario) -> Void
    }

    private struct Scenario {
        var entry = makeEntry(hasMinutes: true, summaryState: .done)
        var memory: HindsightStatus?
        var live: LiveStages = [:]
        var recordingDir: URL?
    }

    private var rungs: [Rung] {
        let date = sentDate
        return [
            Rung(name: "recording", expected: .recording) { $0.recordingDir = $0.entry.dir },
            Rung(name: "error", expected: .error) { $0.entry = makeEntry(minutesFailed: true) },
            Rung(name: "active", expected: .active(.transcription)) { $0.live[.transcription] = .running },
            Rung(name: "sending", expected: .sending) { $0.live[.memory] = .running },
            Rung(name: "pending", expected: .pending) { $0.memory = .pending },
            Rung(name: "sent", expected: .sent) { $0.memory = .sent(date, bank: nil) },
        ]
    }

    @Test func higherRungAlwaysBeatsALowerOneForEveryPair() {
        let all = rungs
        var checked = 0
        for i in all.indices {
            for j in all.indices where j > i {
                var scenario = Scenario()
                // "pending" and "sent" both set `memory`; the later one wins the
                // assignment, so apply the lower rung first.
                all[j].apply(&scenario)
                all[i].apply(&scenario)
                // An error entry replaces the entry; keep the recording folder in sync.
                if all[i].name == "recording" || all[j].name == "recording" { scenario.recordingDir = scenario.entry.dir }
                let pill = StatusPill.derive(
                    entry: scenario.entry, memory: scenario.memory, live: scenario.live, recordingDir: scenario.recordingDir
                )
                // The two memory rungs collide on one field; skip that one impossible pair.
                if all[i].name == "pending" && all[j].name == "sent" { continue }
                #expect(pill == all[i].expected, "\(all[i].name) should beat \(all[j].name)")
                checked += 1
            }
        }
        #expect(checked == 14)
    }

    @Test func specScenarioMinutesFailedAndMemoryPendingIsTheErrorPill() {
        #expect(derive(makeEntry(minutesFailed: true), memory: .pending) == .error)
    }

    @Test func atMostOnePillIsProducedWhateverIsHappening() {
        // The return type is Optional, not a list: exercise a crowded case.
        let entry = makeEntry(hasTranscript: false, minutesPending: true, minutesFailed: true, summaryState: .failed)
        let pill = derive(
            entry, memory: .error, live: [.minutes: .running, .memory: .running], recordingDir: entry.dir
        )
        #expect(pill == .recording)
    }

    // MARK: - Copy

    @Test func labelsAreSpanishCopy() {
        #expect(StatusPill.recording.label == "Grabando")
        #expect(StatusPill.error.label == "Error")
        #expect(StatusPill.active(.transcription).label == "Transcribiendo")
        #expect(StatusPill.active(.minutes).label == "Generando minuta")
        #expect(StatusPill.active(.summary).label == "Resumiendo")
        #expect(StatusPill.sending.label == "Enviando")
        #expect(StatusPill.pending.label == "Pendiente")
        #expect(StatusPill.sent.label == "En memoria")
    }
}

// MARK: - Tone (how the row draws the chip)

@Suite struct StatusPillToneTests {
    @Test func eachPillHasOneToneAndOnlyBusyOnesSpin() {
        #expect(StatusPill.recording.tone == .recording)
        #expect(StatusPill.error.tone == .error)
        #expect(StatusPill.active(.minutes).tone == .running)
        #expect(StatusPill.sending.tone == .running)
        #expect(StatusPill.pending.tone == .neutral)
        #expect(StatusPill.sent.tone == .neutral)

        #expect(StatusPill.active(.transcription).isBusy)
        #expect(StatusPill.active(.summary).isBusy)
        #expect(StatusPill.sending.isBusy)
        #expect(!StatusPill.pending.isBusy, "waiting is not working")
        #expect(!StatusPill.recording.isBusy, "the recording dot pulses on its own")
        #expect(!StatusPill.error.isBusy)
        #expect(!StatusPill.sent.isBusy)
    }
}
