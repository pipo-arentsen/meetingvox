import Foundation
import Testing
@testable import MeetingVox

/// Where a "open this" request lands now that the window renders minutes:
/// `minuta.md` selects its session on the Minuta tab, everything else (the
/// transcript, a manual `minuta.<id>.md`) still opens in another app (DT-4).
@Suite struct OpenTargetTests {
    private let dir = URL(fileURLWithPath: "/fake/root/2026.09.29-1000", isDirectory: true)

    // MARK: - A file

    @Test func minutaMdSelectsItsSessionOnTheMinutaTab() {
        #expect(OpenTarget.decide(file: dir.appendingPathComponent("minuta.md")) == .session(dir, tab: .minuta))
    }

    @Test func aManualMinutesFileOpensOutsideTheApp() {
        let file = dir.appendingPathComponent("minuta.daily.md")
        #expect(OpenTarget.decide(file: file) == .external(file))
    }

    @Test func theTranscriptAndAnyOtherFileOpenOutsideTheApp() {
        for name in ["transcript.md", "transcript.json", "minuta-anterior.md", "notas.md"] {
            let file = dir.appendingPathComponent(name)
            #expect(OpenTarget.decide(file: file) == .external(file), "\(name)")
        }
    }

    @Test func aFolderNamedLikeTheMinutesIsNotTheMinutes() {
        // Only the file name counts, and only exactly.
        let file = dir.appendingPathComponent("Minuta.MD")
        #expect(OpenTarget.decide(file: file) == .external(file))
    }

    @Test func theMenusLatestMinutesUrlSelectsTheSameFolderUrlTheListKeysBy() {
        // The sessions menu hands `<folder>/minuta.md` built from the scan's
        // folder URL (with its trailing slash); the window selects by that URL.
        let scanned = URL(fileURLWithPath: "/fake/root/2026.09.29-1000", isDirectory: true)
        #expect(scanned.absoluteString.hasSuffix("/"))
        let target = OpenTarget.decide(file: scanned.appendingPathComponent(SessionFiles.minutes))
        #expect(target == .session(scanned, tab: .minuta))
    }

    // MARK: - "Abrir" on a session

    @Test func openingASessionWithMinutesLandsOnTheMinutaTab() {
        #expect(OpenTarget.decide(opening: dir, hasMinutes: true) == .session(dir, tab: .minuta))
    }

    @Test func openingASessionWithoutMinutesLandsOnTheResumenTab() {
        #expect(OpenTarget.decide(opening: dir, hasMinutes: false) == .session(dir, tab: .resumen))
    }

    // MARK: - A refused retry / "Ver reunión"

    @Test func aRefusedMinutesRetryShowsTheMinutaTab() {
        #expect(OpenTarget.decide(showing: dir, refusedStage: .minutes) == .session(dir, tab: .minuta))
    }

    @Test func otherStagesAndPlainViewsLeaveTheTabAlone() {
        for stage in [Notice.Stage.transcription, .summary, .memory] {
            #expect(OpenTarget.decide(showing: dir, refusedStage: stage) == .session(dir, tab: nil), "\(stage)")
        }
        #expect(OpenTarget.decide(showing: dir, refusedStage: nil) == .session(dir, tab: nil))
    }
}
