import Foundation
import Testing
@testable import MeetingVox

@Suite struct MarkdownBlocksTests {
    private func parse(_ s: String) -> [MarkdownBlock] { MarkdownBlocks.parse(s) }

    // MARK: - Headings

    @Test func headingsOneToSixKeepTheirLevelAndDisplayAsAtMostFour() {
        let blocks = parse("# a\n## b\n### c\n#### d\n##### e\n###### f")

        #expect(blocks == [
            .heading(level: 1, text: "a"), .heading(level: 2, text: "b"), .heading(level: 3, text: "c"),
            .heading(level: 4, text: "d"), .heading(level: 5, text: "e"), .heading(level: 6, text: "f"),
        ])
        #expect(blocks.compactMap { if case .heading(let l, _) = $0 { MarkdownBlock.displayLevel(l) } else { nil } } == [1, 2, 3, 4, 4, 4])
    }

    @Test func headingClosingHashesAreDroppedAndSevenHashesAreAParagraph() {
        #expect(parse("## Título ##") == [.heading(level: 2, text: "Título")])
        #expect(parse("####### siete") == [.paragraph("####### siete")])
    }

    @Test func hashWithoutSpaceOrWithoutTextIsAParagraphNotAHeading() {
        #expect(parse("#hashtag") == [.paragraph("#hashtag")])
        #expect(parse("##") == [.paragraph("##")])
    }

    // MARK: - Paragraphs

    @Test func paragraphsSplitOnBlankLinesAndKeepLineBreaks() {
        #expect(parse("uno\ndos\n\ntres") == [.paragraph("uno\ndos"), .paragraph("tres")])
    }

    @Test func aParagraphEndsWhereAnotherBlockStarts() {
        #expect(parse("Texto\n## Sub\nOtro\n- item") == [
            .paragraph("Texto"), .heading(level: 2, text: "Sub"), .paragraph("Otro"),
            .listItem(.bullet, level: 0, text: "item"),
        ])
    }

    @Test func emptyAndWhitespaceOnlyInputHaveNoBlocks() {
        #expect(parse("").isEmpty)
        #expect(parse("  \n\n \t\n").isEmpty)
        #expect(!parse("x").isEmpty)
    }

    // MARK: - Lists

    @Test func bulletMarkersAndNumberedMarkers() {
        #expect(parse("- a\n* b\n+ c\n1. d\n2) e") == [
            .listItem(.bullet, level: 0, text: "a"), .listItem(.bullet, level: 0, text: "b"),
            .listItem(.bullet, level: 0, text: "c"),
            .listItem(.number(1), level: 0, text: "d"), .listItem(.number(2), level: 0, text: "e"),
        ])
    }

    @Test func nestingByTwoSpacesAndByFourSpacesBothGiveLevels() {
        let two = parse("- a\n  - b\n    - c\n- d")
        let four = parse("- a\n    - b\n        - c\n- d")
        let levels: ([MarkdownBlock]) -> [Int] = { $0.compactMap { if case .listItem(_, let l, _) = $0 { l } else { nil } } }

        #expect(levels(two) == [0, 1, 2, 0])
        #expect(levels(four) == [0, 1, 2, 0])
    }

    @Test func nestingDeeperThanThreeStaysAtThree() {
        let blocks = parse("- a\n  - b\n    - c\n      - d\n        - e")

        #expect(blocks.count == 5)
        #expect(blocks.compactMap { if case .listItem(_, let l, _) = $0 { l } else { nil } } == [0, 1, 2, 3, 3])
    }

    @Test func aLineRightAfterAnItemContinuesIt() {
        #expect(parse("- primera\n  sigue aquí\n- segunda") == [
            .listItem(.bullet, level: 0, text: "primera\nsigue aquí"),
            .listItem(.bullet, level: 0, text: "segunda"),
        ])
    }

    @Test func aBlankLineAfterAnItemStartsAFreshParagraph() {
        #expect(parse("- a\n\nfuera") == [.listItem(.bullet, level: 0, text: "a"), .paragraph("fuera")])
    }

    @Test func aBulletMarkerWithoutTextIsNotAnItem() {
        #expect(parse("-") == [.paragraph("-")])
        #expect(parse("-guion") == [.paragraph("-guion")])
    }

    // MARK: - Tables

    @Test func specScenarioTableOneBlockTwoColumnsOneRow() {
        let blocks = parse("| Quién | Qué |\n|---|---|\n| Participante 1 | Enviar |")

        #expect(blocks.count == 1)
        guard case .table(let table) = blocks[0] else { Issue.record("not a table"); return }
        #expect(table.header == ["Quién", "Qué"])
        #expect(table.rows == [["Participante 1", "Enviar"]])
        #expect(table.columnCount == 2)
        #expect(table.alignments == [.none, .none])
    }

    @Test func tableAlignmentsAndPipelessEdges() {
        let blocks = parse("a | b | c | d\n:--- | :---: | ---: | ---\n1 | 2 | 3 | 4")

        guard case .table(let table) = blocks.first else { Issue.record("not a table"); return }
        #expect(table.alignments == [.leading, .center, .trailing, .none])
        #expect(table.rows == [["1", "2", "3", "4"]])
    }

    @Test func raggedRowsArePaddedAndExtraCellsAreKeptInTheLastColumn() {
        let blocks = parse("| A | B | C |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |")

        guard case .table(let table) = blocks.first else { Issue.record("not a table"); return }
        #expect(table.rows[0] == ["1", "", ""])
        #expect(table.rows[1] == ["1", "2", "3 | 4"])
        #expect(table.rows.allSatisfy { $0.count == 3 })
    }

    @Test func anEscapedPipeStaysInsideItsCell() {
        let blocks = parse("| Clave | Valor |\n|---|---|\n| a\\|b | **x** |")

        guard case .table(let table) = blocks.first else { Issue.record("not a table"); return }
        #expect(table.rows == [["a|b", "**x**"]])
    }

    @Test func aTableEndsAtABlankLineAndAtALineWithoutPipes() {
        let blocks = parse("| A | B |\n|---|---|\n| 1 | 2 |\nTexto después\n\n| C | D |\n|---|---|")

        #expect(blocks.count == 3)
        #expect(blocks[1] == .paragraph("Texto después"))
        guard case .table(let second) = blocks[2] else { Issue.record("not a table"); return }
        #expect(second.header == ["C", "D"])
        #expect(second.rows.isEmpty)
    }

    @Test func headerAndDelimiterWithDifferentWidthsIsNotATable() {
        #expect(parse("| A | B | C |\n|---|---|") == [.paragraph("| A | B | C |\n|---|---|")])
    }

    @Test func aPipeInAParagraphWithoutADelimiterRowStaysAParagraph() {
        #expect(parse("a | b\nc | d") == [.paragraph("a | b\nc | d")])
    }

    // MARK: - Rules

    @Test func horizontalRules() {
        #expect(parse("---") == [.rule])
        #expect(parse("***") == [.rule])
        #expect(parse("___") == [.rule])
        #expect(parse("- - -") == [.rule])
        #expect(parse("texto\n\n---\n\notro") == [.paragraph("texto"), .rule, .paragraph("otro")])
        #expect(parse("--") == [.paragraph("--")])
    }

    // MARK: - Fenced code

    @Test func fencedCodeKeepsItsBodyVerbatimAndTheLanguage() {
        let blocks = parse("```swift\nlet a = 1\n\n# not a heading\n- not a list\n```\nfin")

        #expect(blocks == [.code(language: "swift", text: "let a = 1\n\n# not a heading\n- not a list"), .paragraph("fin")])
    }

    @Test func tildeFencesAndLongerClosingFences() {
        #expect(parse("~~~\nx\n~~~") == [.code(language: nil, text: "x")])
        #expect(parse("```\nx\n`````") == [.code(language: nil, text: "x")])
        #expect(parse("````\n```\ninner\n```\n````") == [.code(language: nil, text: "```\ninner\n```")])
    }

    @Test func anEmptyFenceIsAnEmptyCodeBlock() {
        #expect(parse("```\n```") == [.code(language: nil, text: "")])
    }

    @Test func unclosedFenceBecomesOneParagraphVerbatimToTheEnd() {
        let source = "Antes\n\n```python\nprint(1)\n\n# comentario\n- x"
        let blocks = parse(source)

        #expect(blocks == [.paragraph("Antes"), .paragraph("```python\nprint(1)\n\n# comentario\n- x")])
    }

    // MARK: - Provenance header

    @Test func specScenarioProvenanceHeaderIsStripped() {
        let header = MinutesCoordinator.provenance(model: "m/x", templateID: "general", generatedAt: Date(), chunked: false)
        let blocks = parse(header + "\n\n# Minuta\n\nTexto")

        #expect(blocks == [.heading(level: 1, text: "Minuta"), .paragraph("Texto")])
    }

    @Test func onlyTheFirstLineIsEverStripped() {
        let header = "<!-- quill minutes · model: m · template: t · generated_at: x · chunked: no -->"

        #expect(parse("# A\n" + header) == [.heading(level: 1, text: "A"), .paragraph(header)])
        #expect(parse("<!-- otro comentario -->\n# A") == [.paragraph("<!-- otro comentario -->"), .heading(level: 1, text: "A")])
        #expect(parse(header + "\n" + header) == [.paragraph(header)])
    }

    @Test func aProvenanceLineWithWindowsLineEndingsIsStripped() {
        #expect(parse("<!-- quill minutes · x -->\r\n# A\r\n") == [.heading(level: 1, text: "A")])
    }

    // MARK: - Unknown syntax degrades to a paragraph

    @Test func htmlBlocksAndBlockquotesKeepTheirOriginalText() {
        #expect(parse("<div class=\"x\">hola</div>") == [.paragraph("<div class=\"x\">hola</div>")])
        #expect(parse("> Registro parcial: la reunión empieza a mitad.") == [.paragraph("> Registro parcial: la reunión empieza a mitad.")])
        #expect(parse("<!--\nnota\n-->") == [.paragraph("<!--\nnota\n-->")])
    }

    @Test func crlfAndBareCRAreNormalized() {
        #expect(parse("# A\r\n\r\nuno\r\ndos") == [.heading(level: 1, text: "A"), .paragraph("uno\ndos")])
        #expect(parse("a\rb") == [.paragraph("a\nb")])
    }

    @Test func oddInputNeverThrowsOrCrashes() {
        let odd = ["|", "||", "| |\n|-|", "```", "~~~~\n", "#", "-\t", "1.", "\0", "🙂|🙂\n|:-:|", "\\", "|\n---|\n"]
        for input in odd { _ = parse(input) }
        #expect(odd.allSatisfy { !parse($0).isEmpty || $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    // MARK: - No text loss (MD-3 / MD-5)

    /// Every letter and digit of the source, in order, must survive.
    private func content(_ s: String) -> [Character] { s.filter { $0.isLetter || $0.isNumber } }

    private func flatten(_ blocks: [MarkdownBlock]) -> String {
        blocks.map { block -> String in
            switch block {
            case .heading(_, let text), .paragraph(let text): text
            case .listItem(let marker, _, let text):
                if case .number(let n) = marker { "\(n) \(text)" } else { text }
            case .table(let table): ([table.header] + table.rows).map { $0.joined(separator: " ") }.joined(separator: "\n")
            case .rule: ""
            case .code(let language, let text): (language ?? "") + "\n" + text
            }
        }.joined(separator: "\n")
    }

    @Test func allSevenFactoryTemplatesParseWithoutLosingText() {
        #expect(FactoryTemplates.all.count == 7)
        for template in FactoryTemplates.all {
            let header = MinutesCoordinator.provenance(model: "m/x", templateID: template.id, generatedAt: Date(), chunked: false)
            let source = header + "\n" + template.cuerpo
            let blocks = parse(source)

            #expect(blocks.count > 5, "\(template.id) produced too few blocks")
            #expect(content(flatten(blocks)) == content(template.cuerpo), "text lost in \(template.id)")
        }
    }

    @Test func factoryTemplatesRenderTheirOutputTablesAsTables() {
        // general/comercial/... all end their structure with an "Acuerdos"-style table.
        for template in FactoryTemplates.all where template.cuerpo.contains("|---|") {
            let tables = parse(template.cuerpo).compactMap { block -> MarkdownTable? in
                if case .table(let table) = block { return table } else { return nil }
            }
            #expect(!tables.isEmpty, "\(template.id) lost its table")
            #expect(tables.allSatisfy { table in table.columnCount >= 2 && table.rows.allSatisfy { $0.count == table.columnCount } })
        }
        #expect(FactoryTemplates.all.contains { $0.cuerpo.contains("|---|") })
    }

    @Test func theFamiliarTasksTableIsAThreeColumnQuienQueParaCuando() {
        let blocks = parse(FactoryTemplates.familiar.cuerpo)
        let tables = blocks.compactMap { block -> MarkdownTable? in
            if case .table(let table) = block { return table } else { return nil }
        }

        #expect(tables.count == 1)
        #expect(tables[0].header == ["Quién", "Qué", "Para cuándo"])
        #expect(tables[0].rows == [["...", "...", "..."]])
    }

    @Test func aRealisticMinutesWithFilledTableParsesBlockByBlock() {
        let header = MinutesCoordinator.provenance(model: "m", templateID: "general", generatedAt: Date(), chunked: true)
        let source = """
            \(header)

            # Minuta de reunión

            ## Asistentes
            - Yo: Participante 1
            - Otros: Participante 2 (?)

            ## Acuerdos
            | Acuerdo | Responsable | Fecha |
            |---|---|---|
            | Enviar la **propuesta** | Yo | el viernes |
            | Revisar contrato | No se mencionó | No se mencionó |

            ## Pendientes
            1. Confirmar monto de USD 1.200
            2. Agendar demo
            """

        let blocks = parse(source)

        #expect(blocks.count == 9)
        #expect(blocks[0] == .heading(level: 1, text: "Minuta de reunión"))
        guard case .table(let table) = blocks[5] else { Issue.record("expected table at 5: \(blocks[5])"); return }
        #expect(table.rows.count == 2)
        #expect(table.rows[0] == ["Enviar la **propuesta**", "Yo", "el viernes"])
        #expect(blocks[7] == .listItem(.number(1), level: 0, text: "Confirmar monto de USD 1.200"))
    }
}
