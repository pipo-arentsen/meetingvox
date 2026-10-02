import Foundation
import Testing
@testable import MeetingVox

/// The Transcripción tab's lines (DT-3): consecutive segments of one speaker
/// merged, a merged line that would span more than 60 s split (the timestamp
/// then repeats), `mm:ss` stamps and Yo/Otros labels.
@Suite struct TranscriptViewLinesTests {
    private func seg(_ speaker: String, _ startS: Double, _ endS: Double?, _ text: String) -> TranscriptInput.Segment {
        TranscriptInput.Segment(
            speaker: speaker, start_ms: Int(startS * 1000), end_ms: endS.map { Int($0 * 1000) }, text: text
        )
    }

    // MARK: - Merging

    @Test func twoConsecutiveSegmentsOfTheSameSpeakerBecomeOneLine() {
        let lines = TranscriptViewLines.build([
            seg("me", 0, 4, "Buenos días"), seg("me", 5, 9, "gracias por juntarse"),
        ])
        #expect(lines.count == 1)
        #expect(lines[0].text == "Buenos días gracias por juntarse")
        #expect(lines[0].timestamp == "00:00")
        #expect(lines[0].label == "Yo")
        #expect(lines[0].rendered == "[00:00] Yo: Buenos días gracias por juntarse")
    }

    @Test func aSpeakerChangeStartsANewLineWithItsOwnStampAndLabel() {
        let lines = TranscriptViewLines.build([
            seg("me", 0, 4, "Hola"), seg("them", 65, 70, "Buenas"), seg("me", 71, 75, "Adiós"),
        ])
        #expect(lines.map(\.label) == ["Yo", "Otros", "Yo"])
        #expect(lines.map(\.timestamp) == ["00:00", "01:05", "01:11"])
        #expect(lines.map(\.text) == ["Hola", "Buenas", "Adiós"])
    }

    @Test func anUnknownSpeakerIdPassesThroughAsItsOwnLabel() {
        let lines = TranscriptViewLines.build([seg("carla", 3, 4, "Hola")])
        #expect(lines.map(\.label) == ["carla"])
    }

    @Test func blankSegmentsAreDroppedAndDoNotBreakAMerge() {
        let lines = TranscriptViewLines.build([
            seg("me", 0, 2, "uno"), seg("me", 2, 3, "   "), seg("me", 3, 5, "dos"),
        ])
        #expect(lines.map(\.text) == ["uno dos"])
    }

    @Test func aBlankTurnOfTheOtherSideIsDroppedSoTheTwoSegmentsAroundItMerge() {
        let lines = TranscriptViewLines.build([
            seg("me", 0, 2, "uno"), seg("them", 2, 3, ""), seg("me", 3, 5, "dos"),
        ])
        #expect(lines.map(\.text) == ["uno dos"])
        let apart = TranscriptViewLines.build([
            seg("me", 0, 2, "uno"), seg("them", 2, 3, "mm"), seg("me", 3, 5, "dos"),
        ])
        #expect(apart.map(\.text) == ["uno", "mm", "dos"], "a real turn in between keeps them apart")
    }

    // MARK: - The 60 s split

    @Test func aMergedLineThatWouldSpanMoreThanSixtySecondsSplitsAndTheStampRepeats() {
        let lines = TranscriptViewLines.build([
            seg("me", 0, 30, "a"), seg("me", 30, 55, "b"), seg("me", 55, 80, "c"),
        ])
        #expect(lines.map(\.text) == ["a b", "c"])
        #expect(lines.map(\.timestamp) == ["00:00", "00:55"])
        #expect(lines.map(\.label) == ["Yo", "Yo"])
    }

    @Test func aLineThatSpansExactlySixtySecondsStillMerges() {
        let lines = TranscriptViewLines.build([seg("me", 0, 20, "a"), seg("me", 20, 60, "b")])
        #expect(lines.map(\.text) == ["a b"])
    }

    @Test func aSegmentPastSixtySecondsFromTheLineStartOpensTheNextLineWhichKeepsMerging() {
        let lines = TranscriptViewLines.build([
            seg("them", 0, 20, "a"), seg("them", 20, 61, "b"), seg("them", 61, 70, "c"), seg("them", 70, 100, "d"),
        ])
        // b ends 61 s after the first line began -> a new line at 20 s; c still
        // fits in 60 s of it, d (ending 80 s after 20 s) opens a third.
        #expect(lines.map(\.timestamp) == ["00:00", "00:20", "01:10"])
        #expect(lines.map(\.text) == ["a", "b c", "d"])
    }

    @Test func oneSegmentLongerThanSixtySecondsStaysOneLine() {
        let lines = TranscriptViewLines.build([seg("me", 10, 200, "un monólogo largo")])
        #expect(lines.map(\.text) == ["un monólogo largo"])
        #expect(lines.map(\.timestamp) == ["00:10"])
    }

    @Test func aSegmentWithoutAnEndCountsAsAPointInTime() {
        let lines = TranscriptViewLines.build([seg("me", 0, nil, "a"), seg("me", 59, nil, "b"), seg("me", 61, nil, "c")])
        #expect(lines.map(\.text) == ["a b", "c"])
    }

    // MARK: - Glossary marks

    private func segRaw(_ speaker: String, _ startS: Double, _ endS: Double, _ text: String, raw: String?) -> TranscriptInput.Segment {
        TranscriptInput.Segment(
            speaker: speaker, start_ms: Int(startS * 1000), end_ms: Int(endS * 1000), text: text, text_raw: raw
        )
    }

    private func marked(_ line: TranscriptViewLine) -> [String] {
        line.marks.map { (line.text as NSString).substring(with: NSRange(location: $0.location, length: $0.length)) }
    }

    @Test func aCorrectedSegmentCarriesItsMarks() {
        let lines = TranscriptViewLines.build([segRaw("me", 0, 4, "MeetingVox abrió", raw: "miting vox abrió")])
        #expect(marked(lines[0]) == ["MeetingVox"])
        #expect(lines[0].marks[0].original == "miting vox")
        #expect(lines[0].glossaryTooltip == "«miting vox» → MeetingVox")
    }

    @Test func aLineWithoutRawOrWithEqualTextHasNoMarks() {
        let lines = TranscriptViewLines.build([
            segRaw("me", 0, 4, "hola", raw: nil), segRaw("them", 5, 9, "chao", raw: "chao"),
        ])
        #expect(lines.map(\.marks) == [[], []])
        #expect(lines.map(\.glossaryTooltip) == [nil, nil])
    }

    @Test func mergingShiftsTheSecondSegmentsMarksIntoTheMergedText() {
        let lines = TranscriptViewLines.build([
            segRaw("me", 0, 4, "Buenos días", raw: "Buenos días"),
            segRaw("me", 5, 9, "hablé con MeetingVox", raw: "hablé con miting vox"),
        ])
        #expect(lines.count == 1)
        #expect(lines[0].text == "Buenos días hablé con MeetingVox")
        #expect(marked(lines[0]) == ["MeetingVox"])
        let prefix = "Buenos días ".utf16.count
        #expect(lines[0].marks[0].location == prefix + "hablé con ".utf16.count)
    }

    @Test func marksOfBothMergedSegmentsSurviveAndAccentsCountInUTF16() {
        let lines = TranscriptViewLines.build([
            segRaw("me", 0, 4, "Ñandú Grafana", raw: "Ñandú gra fana"),
            segRaw("me", 5, 9, "con MeetingVox", raw: "con miting vox"),
        ])
        #expect(marked(lines[0]) == ["Grafana", "MeetingVox"])
    }

    @Test func aSixtySecondCutDoesNotShiftTheNextLinesMarks() {
        let lines = TranscriptViewLines.build([
            segRaw("me", 0, 30, "uno", raw: "uno"), segRaw("me", 30, 55, "dos", raw: "dos"),
            segRaw("me", 55, 80, "con MeetingVox", raw: "con miting vox"),
        ])
        #expect(lines.map(\.text) == ["uno dos", "con MeetingVox"])
        #expect(marked(lines[1]) == ["MeetingVox"])
        #expect(lines[1].marks[0].location == "con ".utf16.count)
    }

    // MARK: - Stamps

    @Test func stampsPastAnHourShowTheHour() {
        let lines = TranscriptViewLines.build([seg("me", 3725, 3730, "tarde")])
        #expect(lines.map(\.timestamp) == ["1:02:05"])
        #expect(lines[0].rendered == "[1:02:05] Yo: tarde")
    }

    @Test func linesAreNumberedInOrder() {
        let lines = TranscriptViewLines.build([seg("me", 0, 1, "a"), seg("them", 2, 3, "b"), seg("me", 4, 5, "c")])
        #expect(lines.map(\.id) == [0, 1, 2])
    }

    @Test func noSegmentsMeansNoLines() {
        #expect(TranscriptViewLines.build([seg("me", 0, 1, "   ")]).isEmpty)
        #expect(TranscriptViewLines.build([]).isEmpty)
    }

    // MARK: - Reading a session

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-transcript-lines-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadReadsTranscriptJSONIntoLines() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"""
        {"engine": "fake", "model": "fake", "segments": [
          {"speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "hola", "text_raw": "ola"},
          {"speaker": "them", "start_ms": 2000, "end_ms": 3000, "text": "buenas"}]}
        """#.utf8).write(to: dir.appendingPathComponent(SessionFiles.transcriptJSON))

        let lines = TranscriptViewLines.load(from: dir)
        #expect(lines?.map(\.rendered) == ["[00:00] Yo: hola", "[00:02] Otros: buenas"])
    }

    @Test func loadIsNilWhenTheFileIsMissingOrUnreadable() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(TranscriptViewLines.load(from: dir) == nil, "no transcript.json")

        try Data("{ not json".utf8).write(to: dir.appendingPathComponent(SessionFiles.transcriptJSON))
        #expect(TranscriptViewLines.load(from: dir) == nil, "malformed")
    }

    @Test func aTranscriptWithNoSegmentsLoadsAsAnEmptyList() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"segments": []}"#.utf8).write(to: dir.appendingPathComponent(SessionFiles.transcriptJSON))
        #expect(TranscriptViewLines.load(from: dir)?.isEmpty == true)
    }
}

/// Which of the Transcripción tab's looks a session gets.
@Suite struct TranscriptTabStateTests {
    private let line = TranscriptViewLine(id: 0, startMs: 0, speaker: "me", text: "hola")

    @Test func noTranscriptFileIsMissingWhateverTheReadSays() {
        #expect(TranscriptTabState.derive(hasTranscript: false, loaded: true, lines: nil) == .missing)
        #expect(TranscriptTabState.derive(hasTranscript: false, loaded: false, lines: nil) == .missing)
    }

    @Test func aTranscriptStillBeingReadIsLoading() {
        #expect(TranscriptTabState.derive(hasTranscript: true, loaded: false, lines: nil) == .loading)
    }

    @Test func aLoadedTranscriptIsUnreadableEmptyOrItsLines() {
        #expect(TranscriptTabState.derive(hasTranscript: true, loaded: true, lines: nil) == .unreadable)
        #expect(TranscriptTabState.derive(hasTranscript: true, loaded: true, lines: []) == .empty)
        #expect(TranscriptTabState.derive(hasTranscript: true, loaded: true, lines: [line]) == .lines([line]))
    }
}
