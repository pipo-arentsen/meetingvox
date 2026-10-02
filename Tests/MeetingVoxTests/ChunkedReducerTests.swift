import Foundation
import Testing
@testable import MeetingVox

/// Thread-safe recorder for `@Sendable` closures under test.
private final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func record(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

/// Pure unit tests for the chunk → notes → consolidate algorithm, extracted
/// from `MinutesCoordinator` so it can be reused (summary pipeline) and
/// tested without the coordinator's actor/queue/filesystem machinery.
/// `MinutesCoordinatorTests` remains the approval suite for the end-to-end
/// behavior through the coordinator.
@Suite struct ChunkedReducerTests {
    private func line(_ i: Int, speaker: String) -> TranscriptLine {
        TranscriptLine(
            startMs: i * 10_000, endMs: i * 10_000 + 9_000, speaker: speaker,
            text: String(repeating: "palabra ", count: 25)
        )
    }

    private func prompting(context: Int = 4_000) -> ChunkedReducer.Prompting {
        ChunkedReducer.Prompting(
            info: SessionInfo(name: "s1", started: nil, durationSeconds: nil),
            finalSystem: "SYSTEM",
            language: "español",
            glossary: [],
            context: context,
            timeZone: TimeZone(identifier: "UTC")!
        )
    }

    @Test func chunksLongTranscriptThenConsolidates() async throws {
        let lines = (0..<60).map { line($0, speaker: $0 % 2 == 0 ? "me" : "them") }
        let calls = Recorder<[ChatMessage]>()
        let complete: ChunkedReducer.Complete = { messages, _ in
            calls.record(messages)
            return "# Minuta\n\ncontenido"
        }
        let logs = Recorder<String>()
        var notes: [String] = []
        var plan: String?
        let p = prompting()

        let result = try await ChunkedReducer.run(
            lines: lines, p, notes: &notes, plan: &plan,
            finalMaxTokens: Chunker.maxTokens(contextLength: p.context),
            log: { logs.record($0) }, complete
        )

        #expect(result == "# Minuta\n\ncontenido")
        #expect(calls.all.count >= 3)
        let partials = calls.all.dropLast()
        for (i, call) in partials.enumerated() {
            #expect(call[0].content.contains("parte \(i + 1) de \(partials.count)"))
        }
        #expect(calls.all.last?[1].content.contains(MinutesPrompts.introConsolidacion) == true)
        #expect(notes.count == partials.count)
        #expect(plan?.hasPrefix("context=4000;chunks=") == true)
        #expect(logs.all.contains { $0.hasPrefix("chunks: ") })
    }

    @Test func discardsStalePartialNotesWhenTheChunkSplitChanges() async throws {
        let lines = (0..<60).map { line($0, speaker: $0 % 2 == 0 ? "me" : "them") }
        let complete: ChunkedReducer.Complete = { _, _ in "note" }
        let logs = Recorder<String>()
        var notes = ["stale note"]
        var plan: String? = "context=999;chunks=1,2"
        let p = prompting()

        _ = try await ChunkedReducer.run(
            lines: lines, p, notes: &notes, plan: &plan,
            finalMaxTokens: Chunker.maxTokens(contextLength: p.context),
            log: { logs.record($0) }, complete
        )

        #expect(logs.all.contains { $0.contains("discarding 1 partial note(s)") })
        #expect(!notes.contains("stale note"))
        #expect(plan?.hasPrefix("context=4000;chunks=") == true)
    }
}
