import Foundation
import Testing
import UserNotifications
@testable import MeetingVox

/// The pure map from a tapped notification (action id, category id,
/// userInfo strings) to an `AppAction`. Nothing here touches the
/// notification center.
@Suite struct NotificationActionRouterTests {
    private let session = "/Users/x/Recordings/2026.09.29-1000"
    private let defaultAction = NotificationActionRouter.defaultAction

    private func route(_ action: String, _ category: String, _ info: [String: String]) -> AppAction? {
        NotificationActionRouter.route(action: action, category: category, userInfo: info)
    }

    private var dir: URL { URL(fileURLWithPath: session) }

    // MARK: identifiers

    @Test func theDefaultAndDismissIdsAreTheSystemOnes() {
        #expect(NotificationActionRouter.defaultAction == UNNotificationDefaultActionIdentifier)
        #expect(NotificationActionRouter.dismissAction == UNNotificationDismissActionIdentifier)
    }

    // MARK: body click

    @Test func clickingAReadyNoticeOpensTheSession() {
        #expect(route(defaultAction, "mv.ready", ["session": session]) == .openSession(dir))
        #expect(route(defaultAction, "mv.ready.memory", ["session": session]) == .openSession(dir))
    }

    @Test func clickingAMinutesNoticeOpensThatFile() {
        #expect(route(defaultAction, "mv.minutes", ["session": session, "file": "minuta.md"])
            == .openFile(dir.appendingPathComponent("minuta.md")))
        #expect(route(defaultAction, "mv.minutes", ["session": session, "file": "minuta.ejecutiva.md"])
            == .openFile(dir.appendingPathComponent("minuta.ejecutiva.md")))
    }

    @Test func clickingAMinutesNoticeWithoutAFileOpensTheSession() {
        #expect(route(defaultAction, "mv.minutes", ["session": session]) == .openSession(dir))
    }

    @Test func clickingAFailureNoticeShowsTheSession() {
        #expect(route(defaultAction, "mv.failure.retry", ["session": session, "stage": "minutes"]) == .showSession(dir))
        #expect(route(defaultAction, "mv.failure", ["session": session, "stage": "memory"]) == .showSession(dir))
    }

    @Test func clickingAnInfoNoticeDoesNothing() {
        #expect(route(defaultAction, "mv.info", ["session": session]) == nil)
        #expect(route(defaultAction, "mv.info", [:]) == nil)
    }

    // MARK: buttons

    @Test func openButtonOpensLikeTheBody() {
        #expect(route("mv.open", "mv.ready", ["session": session]) == .openSession(dir))
        #expect(route("mv.open", "mv.ready.memory", ["session": session]) == .openSession(dir))
        #expect(route("mv.open", "mv.minutes", ["session": session, "file": "minuta.md"])
            == .openFile(dir.appendingPathComponent("minuta.md")))
    }

    @Test func memoryButtonSendsToMemory() {
        #expect(route("mv.memory", "mv.ready.memory", ["session": session]) == .sendToMemory(dir))
    }

    @Test func retryButtonRetriesTheStageOfTheFailure() {
        for stage in [Notice.Stage.transcription, .minutes, .summary] {
            #expect(route("mv.retry", "mv.failure.retry", ["session": session, "stage": stage.rawValue])
                == .retry(stage, dir))
        }
    }

    @Test func viewButtonShowsTheSession() {
        #expect(route("mv.view", "mv.failure.retry", ["session": session, "stage": "minutes"]) == .showSession(dir))
        #expect(route("mv.view", "mv.failure", ["session": session, "stage": "memory"]) == .showSession(dir))
    }

    // MARK: things that must not act

    @Test func dismissingDoesNothing() {
        #expect(route(NotificationActionRouter.dismissAction, "mv.ready", ["session": session]) == nil)
        #expect(route(NotificationActionRouter.dismissAction, "mv.failure.retry", ["session": session, "stage": "minutes"]) == nil)
    }

    @Test func anActionTheCategoryDoesNotOfferDoesNothing() {
        #expect(route("mv.memory", "mv.ready", ["session": session]) == nil)
        #expect(route("mv.retry", "mv.failure", ["session": session, "stage": "memory"]) == nil)
        #expect(route("mv.retry", "mv.ready", ["session": session, "stage": "minutes"]) == nil)
        #expect(route("mv.open", "mv.failure.retry", ["session": session, "stage": "minutes"]) == nil)
    }

    @Test func unknownActionOrCategoryDoesNothing() {
        #expect(route("mv.bogus", "mv.ready", ["session": session]) == nil)
        #expect(route("mv.open", "other.category", ["session": session]) == nil)
        #expect(route("mv.open", "", ["session": session]) == nil)
    }

    @Test func aMissingOrBadSessionPathDoesNothing() {
        #expect(route("mv.open", "mv.ready", [:]) == nil)
        #expect(route("mv.open", "mv.ready", ["session": ""]) == nil)
        #expect(route("mv.open", "mv.ready", ["session": "relative/2026.09.29-1000"]) == nil)
        #expect(route("mv.open", "mv.ready", ["session": "/Users/x/Recordings/../../etc"]) == nil)
        #expect(route(defaultAction, "mv.failure", ["session": "~/x"]) == nil)
    }

    @Test func aBadStageDoesNothing() {
        #expect(route("mv.retry", "mv.failure.retry", ["session": session]) == nil)
        #expect(route("mv.retry", "mv.failure.retry", ["session": session, "stage": "coffee"]) == nil)
    }

    @Test func aBadOrMissingFileFallsBackToOpeningTheSession() {
        // Same as a notice without a file: the session still opens (minutes or
        // Reuniones); the odd name is never followed.
        for file in ["", "../x.md", "sub/minuta.md", "/etc/passwd", "notas.md", "minuta.txt", "minuta", "minuta/../../x.md"] {
            #expect(route(defaultAction, "mv.minutes", ["session": session, "file": file]) == .openSession(dir), "file: \(file)")
            #expect(route("mv.open", "mv.minutes", ["session": session, "file": file]) == .openSession(dir), "file: \(file)")
        }
    }
}

/// `perform` acts only on folders that are recorded sessions of this app:
/// a direct child of the recordings root with a `meta.json`.
@Suite struct NotificationActionValidationTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-action-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func session(_ name: String, meta: Bool = true, in base: URL? = nil) throws -> URL {
        let dir = (base ?? root).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if meta { try Data("{}".utf8).write(to: dir.appendingPathComponent(SessionFiles.meta)) }
        return dir
    }

    /// The action with its paths as plain strings, so trailing-slash
    /// differences between equal file URLs don't matter.
    private func shape(_ action: AppAction?) -> String {
        switch action {
        case nil: "nil"
        case .openSession(let u)?: "openSession \(u.path)"
        case .openFile(let u)?: "openFile \(u.path)"
        case .showSession(let u)?: "showSession \(u.path)"
        case .retry(let s, let u)?: "retry \(s.rawValue) \(u.path)"
        case .sendToMemory(let u)?: "sendToMemory \(u.path)"
        }
    }

    @Test func aSessionUnderTheRootWithMetaPassesEveryDirectoryAction() throws {
        let dir = try session("2026.09.29-1000")
        defer { try? FileManager.default.removeItem(at: root) }
        for action in [AppAction.openSession(dir), .showSession(dir), .retry(.minutes, dir), .sendToMemory(dir)] {
            #expect(shape(NotificationActionRouter.validated(action, root: root)) == shape(action))
        }
    }

    @Test func aFolderWithoutMetaIsRejected() throws {
        let dir = try session("2026.09.29-1000", meta: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(NotificationActionRouter.validated(.openSession(dir), root: root) == nil)
        #expect(NotificationActionRouter.validated(.retry(.summary, dir), root: root) == nil)
    }

    @Test func aFolderOutsideTheRootIsRejected() throws {
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-elsewhere-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: other)
            try? FileManager.default.removeItem(at: root)
        }
        let dir = try session("2026.09.29-1000", in: other)
        #expect(NotificationActionRouter.validated(.sendToMemory(dir), root: root) == nil)
    }

    @Test func aNestedOrEscapingPathIsRejected() throws {
        let dir = try session("2026.09.29-1000")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = try session("inner", in: dir)
        #expect(NotificationActionRouter.validated(.openSession(nested), root: root) == nil)
        // A path that climbs out of the root and back in still names a direct child.
        let escaping = root.appendingPathComponent("x/../2026.09.29-1000")
        #expect(shape(NotificationActionRouter.validated(.openSession(escaping), root: root))
            == shape(.openSession(dir)))
        // ...but one that lands outside does not.
        let outside = root.appendingPathComponent("../")
        #expect(NotificationActionRouter.validated(.openSession(outside), root: root) == nil)
        #expect(NotificationActionRouter.validated(.openSession(root), root: root) == nil)
    }

    @Test func aSymlinkOutOfTheRootIsRejected() throws {
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-symlink-target-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: other)
            try? FileManager.default.removeItem(at: root)
        }
        let target = try session("real", in: other)
        let link = root.appendingPathComponent("2026.09.29-1000")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(NotificationActionRouter.validated(.openSession(link), root: root) == nil)
    }

    @Test func aMinutesFileThatExistsPassesAndAMissingOneFallsBackToTheSession() throws {
        let dir = try session("2026.09.29-1000")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = dir.appendingPathComponent("minuta.md")
        #expect(shape(NotificationActionRouter.validated(.openFile(file), root: root)) == shape(.openSession(dir)))
        try Data("# minuta".utf8).write(to: file)
        #expect(shape(NotificationActionRouter.validated(.openFile(file), root: root)) == shape(.openFile(file)))
    }

    @Test func aFileOutsideASessionIsRejected() throws {
        let dir = try session("2026.09.29-1000")
        defer { try? FileManager.default.removeItem(at: root) }
        let stray = root.appendingPathComponent("minuta.md")
        try Data("x".utf8).write(to: stray)
        #expect(NotificationActionRouter.validated(.openFile(stray), root: root) == nil)
        let deep = dir.appendingPathComponent("a/minuta.md")
        #expect(NotificationActionRouter.validated(.openFile(deep), root: root) == nil)
    }
}

/// The one rule for "what does a minutes request in this state call for",
/// shared by the Reuniones window button and the notification's "Reintentar".
@Suite struct MinutesRequestRouteTests {
    private func decide(
        minutes: Bool = false, pendingOrFailed: Bool = false, transcript: Bool = true
    ) -> MinutesRequestRoute {
        MinutesRequestRoute.decide(hasMinutes: minutes, hasPendingOrFailedRequest: pendingOrFailed, hasTranscript: transcript)
    }

    @Test func minutesThatExistAreOpened() {
        #expect(decide(minutes: true) == .openMinutes)
        #expect(decide(minutes: true, pendingOrFailed: true) == .openMinutes)
    }

    @Test func aRequestOwedByTheAutomaticPathIsRetriedThroughIt() {
        #expect(decide(pendingOrFailed: true) == .retryAutomatic)
        #expect(decide(pendingOrFailed: true, transcript: false) == .retryAutomatic)
    }

    @Test func aTranscriptWithNothingOwedAsksForAFreshUserRequestedJob() {
        #expect(decide() == .generate)
    }

    @Test func withoutATranscriptThereIsNothingToDo() {
        #expect(decide(transcript: false) == .unavailable)
    }
}

/// The notice's side of that rule: only a request the automatic path still
/// owes is retried; everything else shows the session so the user chooses.
@Suite struct NotificationMinutesRetryTests {
    private typealias Retry = NotificationActionRouter.MinutesRetry

    @Test func onlyAnOwedAutomaticRequestIsRetriedFromTheNotice() {
        #expect(NotificationActionRouter.minutesRetry(for: .retryAutomatic) == Retry.retryAutomatic)
    }

    @Test func aFailedManualOrUserRequestedJobLeavesNothingOnDiskSoItShowsTheSession() {
        // "Generar minuta con <plantilla>" (manual) and the Reuniones button
        // leave no marker: from disk they look like `.generate`, and
        // generating again would silently pick another template.
        #expect(NotificationActionRouter.minutesRetry(for: .generate) == Retry.showSession)
    }

    @Test func existingMinutesOrNoTranscriptShowTheSession() {
        #expect(NotificationActionRouter.minutesRetry(for: .openMinutes) == Retry.showSession)
        #expect(NotificationActionRouter.minutesRetry(for: .unavailable) == Retry.showSession)
    }

    /// A real session folder per route, decided from disk both ways the app
    /// does: from the markers (the tapped notice) and from a scanned entry
    /// (the Reuniones window). Both must agree, and the notice maps each
    /// route to its retry.
    @Test func everyRouteIsDecidedFromARealSessionFolderTheSameWayByBothCallers() throws {
        let fixture = try SessionFixture()
        func session(
            _ name: String, transcript: Bool = true, minutes: Bool = false, pending: Bool = false, error: Bool = false
        ) throws -> URL {
            let dir = try fixture.session(name, transcript: transcript, pending: pending)
            if minutes { try SessionFiles.writeMarker(SessionFiles.minutes, in: dir) }
            if error { try SessionFiles.writeMarker(SessionFiles.minutesError, in: dir) }
            return dir
        }
        let cases: [(URL, MinutesRequestRoute, Retry)] = [
            (try session("s-minutes", minutes: true), .openMinutes, .showSession),
            (try session("s-minutes-pending", minutes: true, pending: true), .openMinutes, .showSession),
            (try session("s-pending", pending: true), .retryAutomatic, .retryAutomatic),
            (try session("s-error", error: true), .retryAutomatic, .retryAutomatic),
            (try session("s-pending-no-transcript", transcript: false, pending: true), .retryAutomatic, .retryAutomatic),
            (try session("s-generate"), .generate, .showSession),
            (try session("s-unavailable", transcript: false), .unavailable, .showSession),
        ]
        #expect(cases.count == 7)
        for (dir, route, retry) in cases {
            #expect(MinutesRequestRoute.decide(dir: dir) == route, "decide(dir:) for \(dir.lastPathComponent)")
            #expect(MinutesRequestRoute.decide(MeetingEntry.load(dir)) == route, "decide(entry) for \(dir.lastPathComponent)")
            #expect(NotificationActionRouter.minutesRetry(for: MinutesRequestRoute.decide(dir: dir)) == retry)
        }
    }

    @Test func aFolderThatDoesNotExistHasNothingToDo() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(MinutesRequestRoute.decide(dir: missing) == .unavailable)
    }
}

/// A memory button on a notice can be stale (the user may have chosen "No
/// enviar a memoria", or the session was sent, since it was posted): the tap
/// re-checks the live status.
@Suite struct NotificationMemoryTapTests {
    private typealias Tap = NotificationActionRouter.MemoryTap
    private func send(_ status: HindsightStatus?) -> Tap { NotificationActionRouter.memoryTap(.send, status: status) }
    private func retry(_ status: HindsightStatus?) -> Tap { NotificationActionRouter.memoryTap(.retry, status: status) }

    @Test func sendingIsAllowedOnlyWhereTheStatusOffersAFirstSend() {
        #expect(send(.notSent) == .send)
        // "Enviar igual" for a short session is what the notice offered too.
        #expect(send(.short) == .send)
    }

    @Test func aSessionTheUserOmittedIsNotSentBehindTheirBack() {
        #expect(send(.omitted) == .show)
    }

    @Test func aSentOrPendingOrFailedSessionIsShownNotSentAgain() {
        #expect(send(.sent(Date(timeIntervalSince1970: 0), bank: "meetingvox")) == .show)
        #expect(send(.pending) == .show)
        #expect(send(.error) == .show)
    }

    @Test func aDisabledIntegrationOrUnreadableSessionIsShown() {
        #expect(send(nil) == .show)
    }

    @Test func retryingIsAllowedOnlyAfterAFailure() {
        #expect(retry(.error) == .retryNow)
    }

    @Test func retryingAnythingElseShowsTheSession() {
        for status in [HindsightStatus.notSent, .short, .omitted, .pending, .sent(Date(timeIntervalSince1970: 0), bank: nil)] {
            #expect(retry(status) == .show, "\(status)")
        }
        #expect(retry(nil) == .show)
    }
}
