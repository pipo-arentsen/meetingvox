import Foundation
import Testing
@testable import MeetingVox

/// The second line of a main-window list row: `10:53 · 42 min · Teams`. The
/// section header already gives the day, so it is time, duration, app.
@Suite("MeetingRowMeta")
struct MeetingRowMetaTests {
    private let utc = TimeZone(identifier: "UTC")!
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test func timeDurationAndTheAppTheMeetingWasDetectedIn() {
        #expect(MeetingRowMeta.text(
            started: date("2026-09-24T10:53:00Z"), ended: date("2026-09-24T11:35:00Z"), durationSeconds: nil,
            app: "teams", timeZone: utc
        ) == "10:53 · 42 min · Teams")
    }

    @Test func aManualRecordingSaysSoAndDurationFallsBackToDurationSeconds() {
        #expect(MeetingRowMeta.text(
            started: date("2026-09-24T08:02:00Z"), ended: nil, durationSeconds: 720, app: nil, timeZone: utc
        ) == "08:02 · 12 min · Grabación manual")
    }

    @Test func withoutAnyDurationOnlyTimeAndAppShow() {
        #expect(MeetingRowMeta.text(
            started: date("2026-09-24T08:02:00Z"), ended: nil, durationSeconds: nil, app: "zoom", timeZone: utc
        ) == "08:02 · Zoom")
    }

    @Test func timeIsInTheGivenTimeZone() {
        let santiago = TimeZone(secondsFromGMT: -3 * 3600)!
        #expect(MeetingRowMeta.text(
            started: date("2026-09-24T13:53:00Z"), ended: nil, durationSeconds: 60, app: nil, timeZone: santiago
        ) == "10:53 · 1 min · Grabación manual")
    }

    @Test func anAppIdNoLongerInTheRuleTableShowsRaw() {
        #expect(MeetingRowMeta.text(
            started: date("2026-09-24T08:02:00Z"), ended: nil, durationSeconds: 600, app: "skype", timeZone: utc
        ) == "08:02 · 10 min · skype")
    }

    @Test func withoutAStartTheTimeIsSimplyOmitted() {
        #expect(MeetingRowMeta.text(
            started: nil, ended: nil, durationSeconds: 300, app: nil, timeZone: utc
        ) == "5 min · Grabación manual")
    }

    @Test func everyMeetingAppNamesItselfExplicitlyForTheRow() {
        #expect(MeetingApp.teams.shortName == "Teams")
        #expect(MeetingApp.zoom.shortName == "Zoom")
        #expect(MeetingApp.whatsApp.shortName == "WhatsApp")
        #expect(MeetingApp.safari.shortName == "Safari")
        #expect(MeetingApp.brave.shortName == "Brave")
        #expect(MeetingApp.browserOS.shortName == "BrowserOS")
        #expect(MeetingApp.webKit.shortName == "Navegador")
        for app in MeetingApp.all {
            #expect(!app.shortName.isEmpty, "\(app.id)")
        }
    }

    @Test func aRowNamesTheAppByItsExplicitShortName() {
        for app in MeetingApp.all {
            let text = MeetingRowMeta.text(
                started: date("2026-09-24T08:02:00Z"), ended: nil, durationSeconds: 600, app: app.id, timeZone: utc
            )
            #expect(text == "08:02 · 10 min · \(app.shortName)", "\(app.id)")
        }
    }

    @Test func theAmbitoDotHasASpokenLabel() {
        #expect(MeetingRowMeta.ambitoAccessibilityLabel(.trabajo) == "Ámbito: Trabajo")
        #expect(MeetingRowMeta.ambitoAccessibilityLabel(.personal) == "Ámbito: Personal")
        #expect(MeetingRowMeta.ambitoAccessibilityLabel(nil) == "Ámbito: Sin clasificar")
    }

    @Test func rowTitleIsTheSummaryTitleElseSinTitulo() {
        #expect(MeetingRowMeta.title(summaryTitle: "Revisión sprint 14") == "Revisión sprint 14")
        #expect(MeetingRowMeta.title(summaryTitle: "  \n") == "Sin título")
        #expect(MeetingRowMeta.title(summaryTitle: nil) == "Sin título")
    }
}
