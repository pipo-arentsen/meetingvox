import Testing
@testable import MeetingVox

@Suite struct SummaryPromptsTests {
    private let glossary = [GlossaryEntry(term: "Kubernetes", variants: [], transcript: true)]

    @Test func systemPromptAsksForTasksAndCountry() {
        let prompt = SummaryPrompts.systemPrompt(glossary: [])
        #expect(prompt.contains("\"tasks\""))
        #expect(prompt.contains("\"who\""))
        #expect(prompt.contains("\"what\""))
        #expect(prompt.contains("\"when\""))
        #expect(prompt.contains("\"country\""))
    }

    @Test func countryIsNullUnlessExplicit() {
        let prompt = SummaryPrompts.systemPrompt(glossary: [])
        #expect(prompt.contains(SummaryPrompts.paisSoloExplicito))
        #expect(SummaryPrompts.paisSoloExplicito.contains("null"))
        #expect(SummaryPrompts.paisSoloExplicito.contains("explícit"))
    }

    @Test func systemPromptKeepsTheGlossary() {
        let prompt = SummaryPrompts.systemPrompt(glossary: glossary)
        #expect(prompt.contains("Kubernetes"))
        #expect(prompt.contains("\"tasks\""))
    }

    @Test func theTaskLimitInThePromptIsTheParsersLimit() {
        #expect(SummaryPrompts.tareasClave.contains("hasta \(SummaryParser.maxTasks)"))
    }

    @Test func tasksSystemPromptAsksOnlyForTasksAndCountry() {
        let prompt = SummaryPrompts.tareasSystemPrompt(glossary: glossary)
        #expect(prompt.contains("\"tasks\""))
        #expect(prompt.contains("\"country\""))
        #expect(prompt.contains(SummaryPrompts.paisSoloExplicito))
        #expect(prompt.contains("Kubernetes"))
        #expect(!prompt.contains("\"title\""))
        #expect(!prompt.contains("\"topics\""))
    }

    @Test func tasksSystemPromptWithoutGlossaryHasNoGlossaryBlock() {
        #expect(!SummaryPrompts.tareasSystemPrompt(glossary: []).contains("Kubernetes"))
    }

    @Test func chunkNotesInstructionKeepsWhoWhatWhen() {
        let text = SummaryPrompts.tareasNotasInstrucciones
        #expect(text.contains("quién"))
        #expect(text.contains("qué"))
        #expect(text.contains("cuándo"))
    }
}
