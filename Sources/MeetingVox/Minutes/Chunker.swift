import Foundation

/// Token budgeting for long transcripts. Pure, so the thresholds are
/// testable without a model. Token counts are a character heuristic
/// (≈ 3.5 characters per token for Spanish prose): real tokenizers differ per
/// model, and the budgets below leave enough headroom for the error.
enum Chunker {
    /// Context size assumed when the model's catalog entry is unknown or the
    /// catalog is unreachable. Small enough to be safe for any current model.
    static let fallbackContextLength = 32_000

    /// Above this share of the context, the single-call prompt risks leaving
    /// too little room for the answer, so the transcript is chunked.
    static let chunkingThreshold = 0.6

    /// Each chunk's transcript share of the context; the rest covers the
    /// partial-notes prompt and the notes themselves.
    static let chunkShare = 0.4

    static let maxOutputTokens = 4096

    static func estimateTokens(_ text: String) -> Int {
        estimateTokens(characters: text.count)
    }

    static func estimateTokens(characters: Int) -> Int {
        Int((Double(characters) / 3.5).rounded(.up))
    }

    static func needsChunking(estimatedTokens: Int, contextLength: Int) -> Bool {
        Double(estimatedTokens) > chunkingThreshold * Double(contextLength)
    }

    static func chunkBudget(contextLength: Int) -> Int {
        max(1, Int(chunkShare * Double(contextLength)))
    }

    /// Output cap: 4096, or a quarter of a small context so prompt + answer
    /// still fit.
    static func maxTokens(contextLength: Int) -> Int {
        min(maxOutputTokens, max(minNoteTokens, contextLength / 4))
    }

    /// Prompt (system + user) budget for any single call: the same share as
    /// the chunking threshold, so the answer always has room left.
    static func promptBudget(contextLength: Int) -> Int {
        max(1, Int(chunkingThreshold * Double(contextLength)))
    }

    /// Floor for a note's output cap: below this, notes lose too much detail.
    /// Past it, the consolidation is reduced hierarchically instead.
    static let minNoteTokens = 256

    /// Tokens per note spent on its "Notas de la parte i de N:" heading.
    static let noteHeadingTokens = 16

    /// Output cap for each of `count` notes that will be sent together in one
    /// prompt next to `overheadTokens` of fixed text (system prompt, metadata),
    /// so they all fit in `promptBudget`. Never above `maxTokens`, never below
    /// `minNoteTokens`.
    static func noteMaxTokens(count: Int, overheadTokens: Int, contextLength: Int) -> Int {
        let available = promptBudget(contextLength: contextLength) - overheadTokens
        let share = available / max(1, count) - noteHeadingTokens
        return min(maxTokens(contextLength: contextLength), max(minNoteTokens, share))
    }

    /// Greedy split of `items` into consecutive chunks whose joined text
    /// (newline-separated) stays within `maxTokens`. Items are never split:
    /// an item that alone exceeds the budget becomes its own chunk (transcript
    /// lines are capped upstream by `PromptBuilder.lines(from:maxLineTokens:)`
    /// so that doesn't happen for them). Order is
    /// preserved and every item appears exactly once.
    static func chunk<T>(_ items: [T], maxTokens: Int, text: (T) -> String) -> [[T]] {
        var chunks: [[T]] = []
        var current: [T] = []
        var characters = 0
        for item in items {
            let length = text(item).count
            // +1 for the newline joining it to the previous line.
            let candidate = current.isEmpty ? length : characters + 1 + length
            if !current.isEmpty, estimateTokens(characters: candidate) > maxTokens {
                chunks.append(current)
                current = [item]
                characters = length
            } else {
                current.append(item)
                characters = candidate
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
