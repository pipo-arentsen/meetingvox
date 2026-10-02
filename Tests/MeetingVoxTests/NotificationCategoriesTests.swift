import Foundation
import Testing
import UserNotifications
@testable import MeetingVox

/// Which category and userInfo each `Notice` carries, and the
/// category table the native backend registers. Pure: no notification center.
@Suite struct NotificationCategoriesTests {
    private let session = URL(fileURLWithPath: "/Users/x/Recordings/2026.09.29-1000")

    private func category(_ id: String) -> NotificationCategories.Category? {
        NotificationCategories.all.first { $0.id == id }
    }

    // MARK: table

    @Test func theTableHasTheSixDesignedCategories() {
        #expect(NotificationCategories.all.map(\.id)
            == ["mv.ready", "mv.ready.memory", "mv.minutes", "mv.failure.retry", "mv.failure", "mv.info"])
        #expect(Set(NotificationCategories.all.map(\.id)).count == 6)
    }

    @Test func eachCategoryOffersExactlyItsActions() {
        #expect(category("mv.ready")?.actions.map(\.id) == ["mv.open"])
        #expect(category("mv.ready.memory")?.actions.map(\.id) == ["mv.open", "mv.memory"])
        #expect(category("mv.minutes")?.actions.map(\.id) == ["mv.open"])
        #expect(category("mv.failure.retry")?.actions.map(\.id) == ["mv.retry", "mv.view"])
        #expect(category("mv.failure")?.actions.map(\.id) == ["mv.view"])
        #expect(category("mv.info")?.actions.isEmpty == true)
    }

    @Test func actionTitlesComeFromTextos() {
        let titles = Dictionary(
            NotificationCategories.all.flatMap(\.actions).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }
        )
        #expect(titles["mv.open"] == Textos.Notificacion.accionAbrir)
        #expect(titles["mv.memory"] == Textos.Notificacion.accionMemoria)
        #expect(titles["mv.retry"] == Textos.Notificacion.accionReintentar)
        #expect(titles["mv.view"] == Textos.Notificacion.accionVerReunion)
        #expect(titles.values.allSatisfy { !$0.isEmpty })
    }

    @Test func onlyViewBringsTheAppToTheForeground() {
        let all = NotificationCategories.all.flatMap(\.actions)
        #expect(all.filter(\.foreground).map(\.id).allSatisfy { $0 == "mv.view" })
        #expect(all.contains { $0.id == "mv.view" && $0.foreground })
    }

    @Test func everyActionTheRouterAcceptsIsOfferedByThatCategory() {
        // The router's whitelist and the registered buttons must agree.
        for cat in NotificationCategories.all {
            for action in cat.actions {
                let info = ["session": session.path, "stage": "minutes"]
                #expect(NotificationActionRouter.route(action: action.id, category: cat.id, userInfo: info) != nil,
                        "\(action.id) in \(cat.id)")
            }
        }
    }

    // MARK: category of a notice

    @Test func readyPicksTheMemoryCategoryOnlyWithAMemoryAction() {
        #expect(NotificationCategories.categoryID(for: .ready(memoryAction: false)) == "mv.ready")
        #expect(NotificationCategories.categoryID(for: .ready(memoryAction: true)) == "mv.ready.memory")
    }

    @Test func minutesInfoAndFailureCategories() {
        #expect(NotificationCategories.categoryID(for: .minutesReady(file: "minuta.md")) == "mv.minutes")
        #expect(NotificationCategories.categoryID(for: .info) == "mv.info")
        #expect(NotificationCategories.categoryID(for: .failure(.minutes, retryable: true)) == "mv.failure.retry")
        #expect(NotificationCategories.categoryID(for: .failure(.memory, retryable: false)) == "mv.failure")
    }

    // MARK: userInfo

    @Test func readyCarriesOnlyTheSession() {
        let notice = NoticeBuilder.ready(session: session, label: "Kickoff", parts: [.transcript], memoryAction: false)
        #expect(NotificationCategories.userInfo(for: notice) == ["session": session.path])
    }

    @Test func minutesCarriesSessionAndFile() {
        let notice = NoticeBuilder.minutesReady(session: session, file: "minuta.ejecutiva.md")
        #expect(NotificationCategories.userInfo(for: notice) == ["session": session.path, "file": "minuta.ejecutiva.md"])
    }

    @Test func failureCarriesSessionAndStage() {
        let notice = NoticeBuilder.failed(.summary, session: session)
        #expect(NotificationCategories.userInfo(for: notice) == ["session": session.path, "stage": "summary"])
    }

    @Test func aNoticeWithoutASessionCarriesNothing() {
        #expect(NotificationCategories.userInfo(for: Notice(title: "T", body: "B")).isEmpty)
    }

    @Test func whatANoticeCarriesRoutesBackToTheSameSession() {
        let ready = NoticeBuilder.ready(session: session, label: "K", parts: [.minutes], memoryAction: true)
        let failed = NoticeBuilder.failed(.transcription, session: session)
        let minutes = NoticeBuilder.minutesReady(session: session, file: "minuta.md")
        func route(_ action: String, _ notice: Notice) -> AppAction? {
            NotificationActionRouter.route(
                action: action, category: NotificationCategories.categoryID(for: notice.kind),
                userInfo: NotificationCategories.userInfo(for: notice)
            )
        }
        #expect(route("mv.memory", ready) == .sendToMemory(URL(fileURLWithPath: session.path)))
        #expect(route("mv.retry", failed) == .retry(.transcription, URL(fileURLWithPath: session.path)))
        #expect(route(NotificationActionRouter.defaultAction, minutes)
            == .openFile(URL(fileURLWithPath: session.path).appendingPathComponent("minuta.md")))
    }
}

/// `diag --mode notifications` compares what the center reports back with the
/// table the app registers. Pure: it gets plain dictionaries.
@Suite struct NotificationCategoriesReadBackTests {
    private var registered: [String: [String]] {
        Dictionary(uniqueKeysWithValues: NotificationCategories.all.map { ($0.id, $0.actions.map(\.id)) })
    }

    @Test func aFaithfulReadBackHasNoProblems() {
        #expect(NotificationCategories.problems(readBack: registered).isEmpty)
    }

    @Test func aMissingCategoryIsReported() {
        var readBack = registered
        readBack["mv.failure"] = nil
        #expect(NotificationCategories.problems(readBack: readBack) == ["missing category mv.failure"])
    }

    @Test func anUnexpectedCategoryIsReported() {
        var readBack = registered
        readBack["other"] = []
        #expect(NotificationCategories.problems(readBack: readBack) == ["unexpected category other"])
    }

    @Test func wrongActionsAreReportedWithBothSides() {
        var readBack = registered
        readBack["mv.ready.memory"] = ["mv.open"]
        #expect(NotificationCategories.problems(readBack: readBack)
            == ["category mv.ready.memory has actions [mv.open], expected [mv.open, mv.memory]"])
    }

    @Test func actionOrderDoesNotMatter() {
        var readBack = registered
        readBack["mv.failure.retry"] = ["mv.view", "mv.retry"]
        #expect(NotificationCategories.problems(readBack: readBack).isEmpty)
    }

    @Test func aReadBackFromNothingReportsEverything() {
        #expect(NotificationCategories.problems(readBack: [:]).count == NotificationCategories.all.count)
    }
}

@Suite struct NotificationAuthorizationDescriptionTests {
    @Test func eachStatusHasAName() {
        #expect(NotificationAuthorizationPolicy.name(.notDetermined) == "notDetermined")
        #expect(NotificationAuthorizationPolicy.name(.denied) == "denied")
        #expect(NotificationAuthorizationPolicy.name(.authorized) == "authorized")
        #expect(NotificationAuthorizationPolicy.name(.provisional) == "provisional")
    }
}
