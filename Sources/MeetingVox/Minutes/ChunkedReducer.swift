import Foundation

/// Map/reduce for transcripts too long for one model call: notes per chunk
/// (each capped so all of them fit the consolidation prompt), condensed in
/// groups while they still don't fit, then one consolidation call. Extracted
/// from `MinutesCoordinator` as a pure algorithm (no actor state, no I/O) so
/// the summary pipeline can reuse the same chunked path.
enum ChunkedReducer {
    typealias Complete = @Sendable (_ messages: [ChatMessage], _ maxTokens: Int) async throws -> String

    /// What every prompt of one run shares.
    struct Prompting {
        let info: SessionInfo
        let finalSystem: String
        let language: String
        let glossary: [GlossaryEntry]
        let context: Int
        let timeZone: TimeZone
        /// Extra instructions appended to the chunk-notes and condensing
        /// system prompts (never the final one, `finalSystem` carries its
        /// own): lets a caller keep data it needs verbatim through the map
        /// and reduce steps. Minutes leave it nil.
        var noteInstructions: String? = nil
    }

    /// Chunks `lines`, produces partial notes, condenses them if needed, then
    /// makes the final consolidation call. Returns its output.
    ///
    /// `notes`/`plan` are the caller's partial-progress state (e.g. a job's
    /// `partialNotes`/`partialPlan`): resumed when the chunk split is
    /// unchanged since the last attempt, discarded (with a log line) when it
    /// changed, so a retry never silently skips transcript.
    static func run(
        lines: [TranscriptLine],
        _ p: Prompting,
        notes: inout [String],
        plan: inout String?,
        finalMaxTokens: Int,
        log: @Sendable (String) -> Void,
        _ complete: Complete
    ) async throws -> String {
        let chunks = Chunker.chunk(lines, maxTokens: Chunker.chunkBudget(contextLength: p.context), text: \.rendered)
        let newPlan = "context=\(p.context);chunks=\(chunks.map { String($0.count) }.joined(separator: ","))"
        log("chunks: \(chunks.count)")
        if plan != newPlan {
            if !notes.isEmpty {
                log("chunk split changed since the last attempt; discarding \(notes.count) partial note(s)")
            }
            notes = []
            plan = newPlan
        }

        let overhead = Chunker.estimateTokens(p.finalSystem)
            + Chunker.estimateTokens(PromptBuilder.consolidationUserPrompt(info: p.info, notes: [], timeZone: p.timeZone))
        let noteCap = Chunker.noteMaxTokens(count: chunks.count, overheadTokens: overhead, contextLength: p.context)
        for (i, chunk) in chunks.enumerated() where i >= notes.count {
            log("chunk \(i + 1)/\(chunks.count)")
            let note = try await complete([
                .system(withNoteInstructions(PromptBuilder.partialSystemPrompt(
                    part: i + 1, of: chunks.count, lines: chunk, language: p.language, glossary: p.glossary
                ), p)),
                .user(PromptBuilder.partialUserPrompt(
                    info: p.info, part: i + 1, of: chunks.count, lines: chunk, timeZone: p.timeZone
                )),
            ], noteCap)
            notes.append(note)
        }

        let reduced = try await reduceToFit(notes, overhead: overhead, p, log: log, complete)
        log("consolidating \(reduced.count) partial notes")
        return try await complete([
            .system(p.finalSystem),
            .user(PromptBuilder.consolidationUserPrompt(info: p.info, notes: reduced, timeZone: p.timeZone)),
        ], finalMaxTokens)
    }

    /// Condense consecutive notes in groups, level by level, until the
    /// consolidation prompt fits `Chunker.promptBudget`. Every level at least
    /// halves the count, so this ends; a lone note that still doesn't fit is
    /// sent as is (it is capped at `maxTokens`, a quarter of the context).
    private static func reduceToFit(
        _ notes: [String], overhead: Int, _ p: Prompting, log: @Sendable (String) -> Void, _ complete: Complete
    ) async throws -> [String] {
        let budget = Chunker.promptBudget(contextLength: p.context)
        var notes = notes
        var level = 0
        while notes.count > 1 {
            let size = Chunker.estimateTokens(p.finalSystem) + Chunker.estimateTokens(
                PromptBuilder.consolidationUserPrompt(info: p.info, notes: notes, timeZone: p.timeZone)
            )
            guard size > budget else { break }
            level += 1
            var groups = Chunker.chunk(notes, maxTokens: Chunker.chunkBudget(contextLength: p.context)) { $0 }
            if groups.count >= notes.count {
                // Each note alone fills a group: pair them so the count drops.
                groups = stride(from: 0, to: notes.count, by: 2).map { Array(notes[$0..<min($0 + 2, notes.count)]) }
            }
            log("consolidation prompt ~\(size) tokens > \(budget); condensing \(notes.count) notes into \(groups.count) (level \(level))")
            let cap = Chunker.noteMaxTokens(count: groups.count, overheadTokens: overhead, contextLength: p.context)
            var reduced: [String] = []
            var first = 1
            for group in groups {
                let last = first + group.count - 1
                reduced.append(try await complete([
                    .system(withNoteInstructions(PromptBuilder.reductionSystemPrompt(
                        from: first, to: last, of: notes.count, language: p.language, glossary: p.glossary
                    ), p)),
                    .user(PromptBuilder.reductionUserPrompt(
                        info: p.info, notes: group, firstPart: first, total: notes.count, timeZone: p.timeZone
                    )),
                ], cap))
                first = last + 1
            }
            notes = reduced
        }
        return notes
    }

    private static func withNoteInstructions(_ prompt: String, _ p: Prompting) -> String {
        guard let extra = p.noteInstructions else { return prompt }
        return prompt + "\n\n" + extra
    }
}
