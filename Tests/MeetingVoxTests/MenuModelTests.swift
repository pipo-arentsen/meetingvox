import Foundation
import Testing
@testable import MeetingVox

/// The one-level status menu as data: what is listed, in which order, with
/// which shortcuts. `MenuBarController` only renders it.
@Suite struct MenuModelTests {
    private static let dir = URL(fileURLWithPath: "/tmp/fixture/2026.09.29-1100")

    private func build(
        recording: MenuModel.Recording? = nil,
        offersTemplate: Bool = false,
        transcription: String? = nil,
        minutes: String? = nil,
        summary: String? = nil,
        tokenInvalid: Bool = false,
        last: MenuModel.Last? = nil
    ) -> [MenuModel.Entry] {
        MenuModel.build(MenuModel.Input(
            recording: recording, offersTemplate: offersTemplate,
            transcription: transcription, minutes: minutes, summary: summary,
            tokenInvalid: tokenInvalid, last: last
        ))
    }

    private func items(_ entries: [MenuModel.Entry]) -> [MenuModel.Item] { MenuModel.items(of: entries) }

    private func item(_ command: MenuModel.Command, in entries: [MenuModel.Entry]) -> MenuModel.Item? {
        items(entries).first { $0.command == command }
    }

    private let kickoff = MenuModel.Last(dir: dir, title: "Kickoff", hasMinutes: true)

    // MARK: - Status line

    @Test func idleStatusLineIsInactivoAndFirst() {
        let first = items(build()).first
        #expect(first?.title == "inactivo")
        #expect(first?.command == .info)
        #expect(first?.isEnabled == false)
    }

    @Test func recordingStatusLineHasElapsedAndTheMeetingApp() {
        let with = items(build(recording: .init(elapsed: "12:34", app: "Teams"))).first
        #expect(with?.title == "● Grabando · 12:34 · Teams")
        let without = items(build(recording: .init(elapsed: "0:05", app: nil))).first
        #expect(without?.title == "● Grabando · 0:05")
    }

    // MARK: - The first action is always the recording toggle (user requirement)

    @Test func theFirstActionIsTheToggleInEveryState() {
        let states: [[MenuModel.Entry]] = [
            build(),
            build(last: kickoff),
            build(recording: .init(elapsed: "1:00", app: "Zoom"), offersTemplate: true, last: kickoff),
            build(transcription: "t", minutes: "m", summary: "s", tokenInvalid: true, last: kickoff),
            build(recording: .init(elapsed: "1:00", app: nil), transcription: "t", tokenInvalid: true),
        ]
        for entries in states {
            let firstAction = items(entries).first { $0.command != .info }
            #expect(firstAction?.command == .toggleRecording)
        }
    }

    @Test func theToggleTitleAndShortcutFollowRecordingState() {
        let idle = item(.toggleRecording, in: build())
        #expect(idle?.title == "Iniciar grabación")
        #expect(idle?.shortcut == MenuModel.Shortcut(key: "r", option: false))
        let recording = item(.toggleRecording, in: build(recording: .init(elapsed: "1:00", app: nil)))
        #expect(recording?.title == "Detener grabación")
        #expect(recording?.shortcut == MenuModel.Shortcut(key: "r", option: false))
    }

    // MARK: - Plantilla

    @Test func templateSubmenuOnlyWhileRecordingWithMinutes() {
        let recording = MenuModel.Recording(elapsed: "1:00", app: nil)
        let shown = item(.template, in: build(recording: recording, offersTemplate: true))
        #expect(shown?.hasSubmenu == true)
        #expect(item(.template, in: build(recording: recording, offersTemplate: false)) == nil)
        #expect(item(.template, in: build(recording: nil, offersTemplate: true)) == nil)
    }

    // MARK: - Idle scenario

    @Test func idleMenuHasNoSubmenuAndListsTheLastSession() {
        let entries = build(last: kickoff)
        #expect(items(entries).allSatisfy { !$0.hasSubmenu })
        let last = item(.openLast(Self.dir, hasMinutes: true), in: entries)
        #expect(last?.title == "Última: Kickoff")
        #expect(last?.isEnabled == true)
        #expect(item(.template, in: entries) == nil)
    }

    @Test func noLastItemWithoutASession() {
        let entries = build()
        #expect(!items(entries).contains { if case .openLast = $0.command { true } else { false } })
    }

    @Test func theLastItemCarriesWhetherItHasMinutes() {
        let bare = MenuModel.Last(dir: Self.dir, title: "Sin minuta", hasMinutes: false)
        #expect(item(.openLast(Self.dir, hasMinutes: false), in: build(last: bare)) != nil)
    }

    // MARK: - Option alternate

    @Test func rebuildIndexIsTheOptionAlternateOfOpenMain() throws {
        let list = items(build(last: kickoff))
        let mainIndex = try #require(list.firstIndex { $0.command == .openMainWindow })
        let main = list[mainIndex]
        #expect(main.isAlternate == false)
        #expect(main.title == "Abrir MeetingVox")
        #expect(main.shortcut == MenuModel.Shortcut(key: "j", option: false))
        let alternate = list[mainIndex + 1]
        #expect(alternate.command == .rebuildIndex)
        #expect(alternate.isAlternate == true)
        #expect(alternate.title == "Reconstruir índice")
        #expect(alternate.shortcut == MenuModel.Shortcut(key: "j", option: true))
    }

    @Test func rebuildIndexIsNeverAStandaloneItem() {
        let list = items(build())
        #expect(list.filter { $0.command == .rebuildIndex }.allSatisfy { $0.isAlternate })
    }

    // MARK: - Folder, settings, onboarding, quit

    @Test func openFolderIsVisibleWithCommandO() {
        let folder = item(.openFolder, in: build())
        #expect(folder?.title == "Abrir carpeta de grabaciones")
        #expect(folder?.shortcut == MenuModel.Shortcut(key: "o", option: false))
        #expect(folder?.isAlternate == false)
        #expect(folder?.isEnabled == true)
    }

    @Test func theTailIsSettingsOnboardingThenQuit() {
        let tail = items(build(last: kickoff)).suffix(3)
        #expect(tail.map(\.command) == [.settings, .onboarding, .quit])
        #expect(tail.first?.shortcut == MenuModel.Shortcut(key: ",", option: false))
        #expect(tail.first?.title == "Ajustes…")
        #expect(tail.last?.shortcut == MenuModel.Shortcut(key: "q", option: false))
        #expect(tail.last?.title == "Salir de MeetingVox")
        #expect(tail[tail.startIndex + 1].title == "Primeros pasos…")
    }

    @Test func nonAlternateShortcutsAreUnique() {
        let keys = items(build(recording: .init(elapsed: "1:00", app: nil), offersTemplate: true, last: kickoff))
            .filter { !$0.isAlternate }.compactMap(\.shortcut).map(\.key)
        #expect(Set(keys).count == keys.count)
    }

    // MARK: - Processing lines and the paused line

    @Test func processingLinesAppearInOrderAsDisabledInfo() throws {
        let entries = build(transcription: "T", minutes: "M", summary: "S", last: kickoff)
        let list = items(entries)
        let lines = list.filter { ["T", "M", "S"].contains($0.title) }
        #expect(lines.map(\.title) == ["T", "M", "S"])
        #expect(lines.allSatisfy { $0.command == .info && !$0.isEnabled })
        let lastIndex = try #require(list.firstIndex { if case .openLast = $0.command { true } else { false } })
        let summaryIndex = try #require(list.firstIndex { $0.title == "S" })
        #expect(summaryIndex < lastIndex)
    }

    @Test func absentProcessingLinesAreNotListed() {
        let list = items(build(minutes: "M"))
        #expect(list.contains { $0.title == "M" })
        #expect(list.filter { $0.command == .info }.count == 2) // status + minutes
    }

    @Test func theTokenLineShowsOnlyWhenPaused() {
        #expect(items(build(tokenInvalid: true)).contains { $0.title == Textos.Memoria.tokenInvalido })
        #expect(!items(build(tokenInvalid: false)).contains { $0.title == Textos.Memoria.tokenInvalido })
    }

    // MARK: - Shape (in-place title updates while the menu is open)

    @Test func aTickChangesTitlesButNotTheShape() {
        let a = build(recording: .init(elapsed: "1:00", app: "Teams"), last: kickoff)
        let b = build(recording: .init(elapsed: "1:01", app: "Teams"), last: kickoff)
        #expect(a != b)
        #expect(MenuModel.shape(a) == MenuModel.shape(b))
    }

    @Test func aNewLineChangesTheShape() {
        #expect(MenuModel.shape(build()) != MenuModel.shape(build(minutes: "M")))
        let recording = MenuModel.Recording(elapsed: "0:00", app: nil)
        #expect(MenuModel.shape(build(recording: recording)) != MenuModel.shape(build(recording: recording, offersTemplate: true)))
        #expect(MenuModel.shape(build()) != MenuModel.shape(build(last: kickoff)))
    }

    @Test func startingToRecordWithoutATemplateOnlyChangesTitles() {
        let recording = MenuModel.Recording(elapsed: "0:00", app: nil)
        #expect(MenuModel.shape(build()) == MenuModel.shape(build(recording: recording)))
    }

    // MARK: - Last session on disk

    @Test func lastIsTheNewestSessionFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("menu-last-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ name: String, minutes: Bool) throws {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: dir.appendingPathComponent(SessionFiles.meta))
            if minutes { try Data("# m".utf8).write(to: dir.appendingPathComponent(SessionFiles.minutes)) }
        }
        try make("2026.09.28-0900", minutes: true)
        try make("2026.09.29-1100", minutes: false)

        let last = try #require(MenuModel.last(in: root))
        #expect(last.dir.lastPathComponent == "2026.09.29-1100")
        #expect(last.hasMinutes == false)
        #expect(last.title == SessionLabel.load(last.dir))
    }

    // MARK: - Menu-open latency: only the newest folders are stat'ed

    private func folders(_ names: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("menu-many-\(UUID().uuidString)")
        for name in names {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true
            )
        }
        return root
    }

    @Test func lastStatsOnlyTheNewestFolderWhenItHasMeta() throws {
        let names = (1...200).map { String(format: "2026.01.%02d-%04d", ($0 % 28) + 1, $0) }
        let root = try folders(names)
        defer { try? FileManager.default.removeItem(at: root) }
        var checked: [String] = []
        let last = MenuModel.last(in: root, exists: { url in
            checked.append(url.deletingLastPathComponent().lastPathComponent)
            return true
        })
        #expect(checked.count == 1)
        #expect(last?.dir.lastPathComponent == names.sorted { $0.localizedStandardCompare($1) == .orderedDescending }.first)
    }

    @Test func lastSkipsFoldersWithoutMetaOnlyUntilTheFirstThatHasOne() throws {
        let names = ["2026.09.30-0900", "2026.09.29-1100", "2026.09.28-0900", "2026.09.27-0900", "2026.09.26-0900"]
        let root = try folders(names)
        defer { try? FileManager.default.removeItem(at: root) }
        var checked = 0
        let last = MenuModel.last(in: root, exists: { url in
            checked += 1
            return url.deletingLastPathComponent().lastPathComponent == "2026.09.28-0900"
        })
        #expect(last?.dir.lastPathComponent == "2026.09.28-0900")
        #expect(checked == 3)
    }

    @Test func aNumberedSuffixIsNewerThanItsBaseFolder() throws {
        let root = try folders(["2026.09.29-1100", "2026.09.29-1100-2", "2026.09.29-1100-10", "2026.09.29-1059"])
        defer { try? FileManager.default.removeItem(at: root) }
        let last = MenuModel.last(in: root, exists: { _ in true })
        #expect(last?.dir.lastPathComponent == "2026.09.29-1100-10")
        let next = MenuModel.last(in: root, exists: { $0.deletingLastPathComponent().lastPathComponent != "2026.09.29-1100-10" })
        #expect(next?.dir.lastPathComponent == "2026.09.29-1100-2")
    }

    @Test func lastIsNilForAnEmptyRoot() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("menu-empty-\(UUID().uuidString)")
        #expect(MenuModel.last(in: root) == nil)
    }
}
