import Foundation
import Testing
@testable import MeetingVox

private func seg(_ speaker: String, _ startMs: Int, _ text: String, end: Int? = nil) -> TranscriptInput.Segment {
    TranscriptInput.Segment(speaker: speaker, start_ms: startMs, end_ms: end ?? startMs + 1000, text: text)
}

// MARK: - PromptBuilder

@Suite struct PromptBuilderTests {
    @Test func mapsSpeakersAndMergesConsecutiveTurns() {
        let lines = PromptBuilder.lines(from: [
            seg("me", 0, "Hola"),
            seg("me", 2_000, "¿cómo están?", end: 3_500),
            seg("them", 4_000, "Bien"),
            seg("them", 5_000, "   "),
            seg("me", 65_000, "Perfecto"),
        ])
        #expect(lines.map(\.rendered) == [
            "[00:00] Yo: Hola ¿cómo están?",
            "[00:04] Otros: Bien",
            "[01:05] Yo: Perfecto",
        ])
        // The merged line keeps the first start and the last end.
        #expect(lines[0].startMs == 0)
        #expect(lines[0].endMs == 3_500)
    }

    @Test func mergedLinesNeverExceedTheCap() {
        // 300 short segments of one speaker: unbounded, one giant line.
        let segments = (0..<300).map { seg("me", $0 * 1_000, "frase número \($0) del monólogo") }
        let cap = 50
        let lines = PromptBuilder.lines(from: segments, maxLineTokens: cap)
        #expect(lines.count > 1)
        for line in lines {
            #expect(Chunker.estimateTokens(line.rendered) <= cap)
        }
        // Order and content kept; each line starts at its first segment.
        #expect(lines.map(\.text).joined(separator: " ") == segments.map(\.text).joined(separator: " "))
        #expect(lines.map(\.startMs) == lines.map(\.startMs).sorted())
        #expect(PromptBuilder.lines(from: segments).count == 1)
    }

    @Test func oversizeSegmentIsSplitOnWhitespace() {
        let words = (0..<200).map { "palabra\($0)" }
        let lines = PromptBuilder.lines(
            from: [seg("them", 61_000, words.joined(separator: " "), end: 180_000), seg("me", 200_000, "Ok")],
            maxLineTokens: 30
        )
        #expect(lines.count > 2)
        let pieces = lines.dropLast()
        for line in pieces {
            #expect(Chunker.estimateTokens(line.rendered) <= 30)
            #expect(line.speaker == "them")
            #expect(line.startMs == 61_000)
            #expect(line.endMs == 180_000)
            #expect(line.rendered.hasPrefix("[01:01] Otros: "))
        }
        // Split on whitespace only: every word survives intact, in order.
        #expect(pieces.flatMap { $0.text.split(separator: " ").map(String.init) } == words)
        #expect(lines.last?.rendered == "[03:20] Yo: Ok")
    }

    @Test func wordLongerThanTheCapIsCut() {
        let pieces = PromptBuilder.split("a " + String(repeating: "x", count: 25) + " b", maxCharacters: 10)
        #expect(pieces == ["a", "xxxxxxxxxx", "xxxxxxxxxx", "xxxxx b"])
    }

    @Test func timestampsBelowAndAboveOneHour() {
        #expect(PromptBuilder.timestamp(0) == "00:00")
        #expect(PromptBuilder.timestamp(599_000) == "09:59")
        #expect(PromptBuilder.timestamp(3_599_999) == "59:59")
        #expect(PromptBuilder.timestamp(3_600_000) == "1:00:00")
        #expect(PromptBuilder.timestamp(3_723_000) == "1:02:03")
    }

    @Test func durationIsHoursAndMinutes() {
        #expect(PromptBuilder.duration(59) == "0:00")
        #expect(PromptBuilder.duration(45 * 60) == "0:45")
        #expect(PromptBuilder.duration(3_900) == "1:05")
    }

    @Test func systemPromptWithGlossary() {
        let prompt = PromptBuilder.systemPrompt(
            template: FactoryTemplates.general, language: "español", glossary: [GlossaryEntry(term: "Grafana"), GlossaryEntry(term: "Kubernetes")]
        )
        #expect(prompt.hasPrefix(MinutesPrompts.rol))
        #expect(prompt.contains(FactoryTemplates.general.cuerpo))
        #expect(prompt.contains("Redacta la minuta en español."))
        #expect(prompt.contains("Términos propios (escritura correcta); úsalos para corregir errores de transcripción: Grafana, Kubernetes."))
        #expect(prompt.contains(MinutesPrompts.aviso))
    }

    @Test func systemPromptWithoutGlossaryOmitsBlock() {
        let prompt = PromptBuilder.systemPrompt(template: FactoryTemplates.general, language: "inglés", glossary: [])
        #expect(!prompt.contains("Términos propios"))
        #expect(prompt.contains("Redacta la minuta en inglés."))
    }

    @Test func metadataInSpanish() throws {
        let started = try #require(ISO8601DateFormatter().date(from: "2026-09-23T14:05:00Z"))
        let info = SessionInfo(name: "2026.09.23-1405", started: started, durationSeconds: 3_900)
        let text = PromptBuilder.metadata(info, timeZone: TimeZone(identifier: "UTC")!)
        #expect(text.contains("- Nombre de la sesión: 2026.09.23-1405"))
        #expect(text.contains("23 de septiembre de 2026"))
        #expect(text.contains("miércoles"))
        #expect(text.contains("14:05"))
        #expect(text.contains("- Duración: 1:05 (h:mm)"))
    }

    @Test func metadataSkipsUnknownFields() {
        let text = PromptBuilder.metadata(SessionInfo(name: "x", started: nil, durationSeconds: nil))
        #expect(text == "\(MinutesPrompts.encabezadoMetadatos)\n- Nombre de la sesión: x")
    }

    @Test func userPromptHasMetadataThenTranscript() {
        let lines = PromptBuilder.lines(from: [seg("me", 0, "Hola"), seg("them", 1_000, "Hola")])
        let user = PromptBuilder.userPrompt(info: SessionInfo(name: "s", started: nil, durationSeconds: nil), lines: lines)
        #expect(user.hasSuffix("Transcripción:\n[00:00] Yo: Hola\n[00:01] Otros: Hola"))
    }

    @Test func partialPromptNamesPartAndRange() {
        let lines = [
            TranscriptLine(startMs: 60_000, endMs: 70_000, speaker: "me", text: "a"),
            TranscriptLine(startMs: 80_000, endMs: 125_000, speaker: "them", text: "b"),
        ]
        let prompt = PromptBuilder.partialSystemPrompt(part: 2, of: 3, lines: lines, language: "español", glossary: [])
        #expect(prompt.contains("parte 2 de 3, 01:00–02:05"))
    }
}

// MARK: - Chunker

@Suite struct ChunkerTests {
    @Test func estimateRoundsUp() {
        #expect(Chunker.estimateTokens("") == 0)
        #expect(Chunker.estimateTokens("abc") == 1)
        #expect(Chunker.estimateTokens(String(repeating: "a", count: 7)) == 2)
        #expect(Chunker.estimateTokens(String(repeating: "a", count: 8)) == 3)
    }

    @Test func thresholdIsSixtyPercent() {
        #expect(!Chunker.needsChunking(estimatedTokens: 600, contextLength: 1_000))
        #expect(Chunker.needsChunking(estimatedTokens: 601, contextLength: 1_000))
    }

    @Test func everyLineOnceInOrderWithinBudget() {
        let lines = (0..<200).map { "línea \($0) " + String(repeating: "x", count: $0 % 37) }
        let budget = 40
        let chunks = Chunker.chunk(lines, maxTokens: budget) { $0 }
        #expect(chunks.flatMap { $0 } == lines)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(Chunker.estimateTokens(chunk.joined(separator: "\n")) <= budget)
        }
    }

    @Test func overlongLineBecomesItsOwnChunk() {
        let long = String(repeating: "y", count: 1_000)
        let chunks = Chunker.chunk(["a", long, "b"], maxTokens: 10) { $0 }
        #expect(chunks == [["a"], [long], ["b"]])
    }

    @Test func emptyInput() {
        #expect(Chunker.chunk([String](), maxTokens: 10) { $0 }.isEmpty)
    }

    @Test func outputCap() {
        #expect(Chunker.maxTokens(contextLength: 128_000) == 4096)
        #expect(Chunker.maxTokens(contextLength: 8_000) == 2_000)
    }

    @Test func noteCapScalesSoAllNotesFit() {
        // 32k context: 19_200 prompt budget, 1_200 overhead → 18_000 for notes.
        #expect(Chunker.promptBudget(contextLength: 32_000) == 19_200)
        #expect(Chunker.noteMaxTokens(count: 2, overheadTokens: 1_200, contextLength: 32_000) == 4096)
        let eight = Chunker.noteMaxTokens(count: 8, overheadTokens: 1_200, contextLength: 32_000)
        #expect(eight == 18_000 / 8 - Chunker.noteHeadingTokens)
        #expect(8 * (eight + Chunker.noteHeadingTokens) + 1_200 <= 19_200)
        // Never below the floor; the coordinator reduces hierarchically then.
        #expect(Chunker.noteMaxTokens(count: 500, overheadTokens: 1_200, contextLength: 32_000) == Chunker.minNoteTokens)
    }
}

// MARK: - Retry policy

@Suite struct MinutesRetryPolicyTests {
    @Test func scheduleThenStop() {
        let error = OpenRouterError.server(status: 503, message: nil)
        #expect(MinutesRetryPolicy.decide(error: error, retriesSoFar: 0) == .retry(after: 30))
        #expect(MinutesRetryPolicy.decide(error: error, retriesSoFar: 1) == .retry(after: 120))
        #expect(MinutesRetryPolicy.decide(error: error, retriesSoFar: 2) == .retry(after: 600))
        #expect(MinutesRetryPolicy.decide(error: error, retriesSoFar: 3) == .exhausted)
    }

    @Test func nonRetryableFailsImmediately() {
        #expect(MinutesRetryPolicy.decide(error: OpenRouterError.unauthorized(nil), retriesSoFar: 0) == .fail)
        #expect(MinutesRetryPolicy.decide(error: OpenRouterError.badRequest("x"), retriesSoFar: 0) == .fail)
        #expect(MinutesRetryPolicy.decide(error: MinutesError.noAPIKey, retriesSoFar: 0) == .fail)
    }

    @Test func transientErrorsRetry() {
        #expect(MinutesRetryPolicy.decide(error: OpenRouterError.transport("offline"), retriesSoFar: 0) == .retry(after: 30))
        #expect(MinutesRetryPolicy.decide(error: OpenRouterError.rateLimited(nil), retriesSoFar: 0) == .retry(after: 30))
    }
}

// MARK: - Template ids

@Suite struct TemplateIDTests {
    @Test(arguments: ["general", "uno-a-uno", "mi plantilla", "v1.2"])
    func valid(_ id: String) { #expect(TemplateStore.isValidID(id)) }

    @Test(arguments: ["", "../x", "a/b", "/abs", ".oculta", ".."])
    func invalid(_ id: String) {
        #expect(!TemplateStore.isValidID(id))
        #expect(TemplateStore.template(id: id, in: FileManager.default.temporaryDirectory) == nil)
    }
}

// MARK: - Session files

@Suite struct SessionFilesTests {
    @Test func manualMinutesFileNames() {
        #expect(SessionFiles.minutes(templateID: "daily") == "minuta.daily.md")
        #expect(SessionFiles.templateID(ofMinutesFile: "minuta.daily.md") == "daily")
        #expect(SessionFiles.templateID(ofMinutesFile: "minuta.uno-a-uno.md") == "uno-a-uno")
        #expect(SessionFiles.templateID(ofMinutesFile: "minuta.md") == nil)
        #expect(SessionFiles.templateID(ofMinutesFile: "minuta.log") == nil)
        #expect(SessionFiles.templateID(ofMinutesFile: "transcript.md") == nil)
    }
}
