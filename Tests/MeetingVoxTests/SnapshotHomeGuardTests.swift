import Foundation
import Testing

@testable import MeetingVox

/// VS-2: the snapshot route (and the main-window views it renders) must
/// NEVER read or write the real home: not `~/Recordings`, not
/// `~/.config/meetingvox`, not the login keychain. Two independent guards:
/// (a) every URL the fixture environment hands out lives under the temp
/// root, and (b) the sources of the snapshot harness and of the views it
/// draws do not even mention the APIs that would reach the real home.
@Suite("SnapshotHomeGuard")
struct SnapshotHomeGuardTests {
    private let fm = FileManager.default

    /// True when `url` is `root` or inside it (standardized, symlinks of the
    /// temp directory resolved on both sides).
    private func isInside(_ url: URL, _ root: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    private func makeRoot() throws -> URL {
        let root = fm.temporaryDirectory
            .appendingPathComponent("meetingvox-snapshot-guard-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - (a) URLs

    @Test func theContainmentHelperTellsInsideFromOutside() {
        let root = URL(fileURLWithPath: "/tmp/x/root")
        #expect(isInside(root.appendingPathComponent("a/b"), root))
        #expect(isInside(root, root))
        #expect(!isInside(URL(fileURLWithPath: "/tmp/x/root-sibling/a"), root))
        #expect(!isInside(fm.homeDirectoryForCurrentUser.appendingPathComponent("Recordings"), root))
    }

    @Test func everyEnvironmentURLIsUnderTheTempRootAndNeverTheRealHome() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let env = try SnapshotEnvironment.make(tempRoot: root)
        let home = fm.homeDirectoryForCurrentUser

        #expect(!isInside(root, home)) // the test's own temp root is not in the home
        #expect(env.urls.count >= 4)
        for url in env.urls {
            #expect(isInside(url, root), "\(url.path) is outside the temp root")
            #expect(!isInside(url, home), "\(url.path) is inside the real home")
        }
        for real in [Config.path, Config.templatesDir, Config.defaultRoot] {
            for url in env.urls {
                #expect(url.standardizedFileURL != real.standardizedFileURL)
                #expect(!isInside(url, real))
            }
        }
    }

    @Test func theEnvironmentWritesItsConfigAndTemplatesOnlyInsideTheTempRoot() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let env = try SnapshotEnvironment.make(tempRoot: root)

        #expect(fm.fileExists(atPath: env.configURL.path))
        let templates = TemplateStore.list(in: env.templatesDir)
        #expect(Set(templates.map(\.id)) == Set(FactoryTemplates.all.map(\.id)))
        // The typed view reads the fake config, not the real one.
        #expect(env.config.recordingsDir?.standardizedFileURL == env.recordingsRoot.standardizedFileURL)
        #expect(env.config.hindsightBank == "meetingvox")
    }

    @Test func theKeyStoreIsTheFakeOneAndHoldsNoSecret() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let env = try SnapshotEnvironment.make(tempRoot: root)

        #expect(type(of: env.keyStore) == SnapshotKeyStore.self)
        #expect(!env.keyStore.hasAPIKey())
        #expect(env.keyStore.presence() == .none)
        #expect(try env.keyStore.read() == nil)
        #expect(throws: (any Error).self) { try env.keyStore.save("sk-should-never-be-stored") }
        #expect(!env.keyStore.hasAPIKey())
    }

    @MainActor
    @Test func theMeetingsModelItBuildsScansOnlyTheFixtureRoot() async throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let env = try SnapshotEnvironment.make(tempRoot: root)
        _ = try SnapshotFixtures.install(in: env)

        let model = env.makeMeetingsModel()
        await model.reload().value

        #expect(model.entries.count >= 6)
        for entry in model.entries { #expect(isInside(entry.dir, root)) }
    }

    @MainActor
    @Test func theLibraryTheEnvironmentBuildsTouchesOnlyTheTempRootAndTheFakeConfig() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let env = try SnapshotEnvironment.make(tempRoot: root)
        let home = fm.homeDirectoryForCurrentUser

        for library in [env.makeLibraryModel(), env.makeMainWindowModel().library] {
            for url in [library.templates.dir, library.glossary.configURL, library.glossary.templatesDir] {
                #expect(isInside(url, root), "\(url.path) is outside the temp root")
                #expect(!isInside(url, home), "\(url.path) is inside the real home")
                for real in [Config.path, Config.templatesDir] { #expect(url.standardizedFileURL != real.standardizedFileURL) }
            }
            #expect(library.templates.dir.standardizedFileURL == env.templatesDir.standardizedFileURL)
            // It reads the fake config, and its key store is the fake one (no key).
            #expect(library.glossary.glossary.map(\.term) == ["MeetingVox", "Grafana"])
            #expect(library.glossary.keyPresence == .none)
        }
    }

    @Test func aTempRootInsideTheRealHomeIsRefused() throws {
        let home = fm.homeDirectoryForCurrentUser
        let inHome = home.appendingPathComponent("meetingvox-snapshot-refused-\(UUID().uuidString)")

        #expect(throws: (any Error).self) { try SnapshotEnvironment.make(tempRoot: inHome, home: home) }
        #expect(!fm.fileExists(atPath: inHome.path)) // refused before creating anything
    }

    // MARK: - (b) source scan

    /// The forbidden APIs, matched on code only (a doc comment may name them).
    static let forbidden: [(name: String, pattern: String)] = [
        ("Config.", #"\bConfig\."#),
        ("Keychain.", #"\bKeychain\."#),
        ("homeDirectoryForCurrentUser", #"homeDirectoryForCurrentUser"#),
        ("NSHomeDirectory", #"NSHomeDirectory"#),
        // Calendar: EventKit lives only in
        // `Calendar/EventKitCalendarSource.swift`, and only the app's bootstrap
        // may pick a real source through the factory.
        ("EKEventStore", #"\bEKEventStore\b"#),
        ("import EventKit", #"\bimport\s+(@preconcurrency\s+)?EventKit\b"#),
        ("CalendarSources.", #"\bCalendarSources\."#),
    ]

    static func violations(in source: String) -> [String] {
        var found: [String] = []
        for (number, rawLine) in source.components(separatedBy: "\n").enumerated() {
            let code = rawLine.replacingOccurrences(of: #"(?<!:)//.*$"#, with: "", options: .regularExpression)
            for (name, pattern) in forbidden where code.range(of: pattern, options: .regularExpression) != nil {
                found.append("line \(number + 1): \(name)")
            }
        }
        return found
    }

    @Test func theScannerFlagsEachForbiddenAPIInCode() {
        #expect(Self.violations(in: "let u = Config.path") == ["line 1: Config."])
        #expect(Self.violations(in: "let k = Keychain.openRouter") == ["line 1: Keychain."])
        #expect(Self.violations(in: "let h = FileManager.default.homeDirectoryForCurrentUser")
            == ["line 1: homeDirectoryForCurrentUser"])
        #expect(Self.violations(in: "let h = NSHomeDirectory()") == ["line 1: NSHomeDirectory"])
    }

    @Test func theScannerFlagsEventKitAndTheSourceFactory() {
        #expect(Self.violations(in: "let s = EKEventStore()") == ["line 1: EKEventStore"])
        #expect(Self.violations(in: "import EventKit") == ["line 1: import EventKit"])
        #expect(Self.violations(in: "@preconcurrency import EventKit") == ["line 1: import EventKit"])
        #expect(Self.violations(in: "let s = CalendarSources.make(isBundled: true)") == ["line 1: CalendarSources."])
        #expect(Self.violations(in: "/// EKEventStore and import EventKit are only in one file").isEmpty)
        #expect(Self.violations(in: "let s = FakeCalendarSource()").isEmpty)
    }

    @Test func theScannerIgnoresCommentsAndLookalikes() {
        #expect(Self.violations(in: "/// never Config.path here").isEmpty)
        #expect(Self.violations(in: "let a = 1 // Keychain.openRouter is not used").isEmpty)
        #expect(Self.violations(in: "let v = ConfigValues(raw: [:])").isEmpty)
        #expect(Self.violations(in: "let s = SnapshotConfig.make()").isEmpty)
        #expect(Self.violations(in: "let s = ConfigStore.loadRaw(at: url)").isEmpty)
    }

    private var sources: URL {
        URL(fileURLWithPath: #filePath) // Tests/MeetingVoxTests/<file>
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingVox", isDirectory: true)
    }

    private func swiftFiles(in relative: String, prefix: String = "") -> [URL] {
        let dir = sources.appendingPathComponent(relative, isDirectory: true)
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "swift" && $0.lastPathComponent.hasPrefix(prefix) }
    }

    @Test func theSnapshotHarnessAndTheViewsItRendersNeverReachTheRealHome() throws {
        let scanned: [(label: String, files: [URL], minimum: Int)] = [
            ("Diag/Snapshot*.swift", swiftFiles(in: "Diag", prefix: "Snapshot"), 6),
            ("UI/Markdown", swiftFiles(in: "UI/Markdown"), 1),
            // Later units add these; scanned as soon as they exist.
            ("UI/Main", swiftFiles(in: "UI/Main"), 0),
            ("UI/Library", swiftFiles(in: "UI/Library"), 0),
            // The scan is not recursive: the full-text index is listed on its own.
            ("MeetingIndex/FullText", swiftFiles(in: "MeetingIndex/FullText"), 4),
            // Same for the player: it reads one session folder and nothing else.
            ("Playback", swiftFiles(in: "Playback"), 6),
            // The recording pill: its views and its controller read only what is injected.
            ("UI/Pill", swiftFiles(in: "UI/Pill"), 4),
            ("Pill", swiftFiles(in: "Pill"), 4),
            // Calendar: the pure core and the seam never touch EventKit, the
            // factory or the real home; the one EventKit file is excluded here
            // and held to its own rule below.
            (
                "Calendar (without EventKitCalendarSource)",
                swiftFiles(in: "Calendar").filter { $0.lastPathComponent != Self.eventKitFile }, 8
            ),
            ("UI/Settings/CalendarSettings*", swiftFiles(in: "UI/Settings", prefix: "CalendarSettings"), 0),
        ]
        for (label, files, minimum) in scanned {
            #expect(files.count >= minimum, "\(label): expected at least \(minimum) source files, found \(files.count)")
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                #expect(Self.violations(in: text).isEmpty, "\(file.lastPathComponent): \(Self.violations(in: text))")
            }
        }
    }

    // MARK: - EventKit isolation

    static let eventKitFile = "EventKitCalendarSource.swift"

    private func allSwiftFiles() -> [URL] {
        let walker = fm.enumerator(at: sources, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    /// EventKit may be imported, and `EKEventStore` named, in exactly one file;
    /// no other source of the app (and so no test-reachable path) can create a
    /// store.
    @Test func onlyTheEventKitSourceMentionsEventKit() throws {
        let files = allSwiftFiles()
        #expect(files.count > 100, "the source walk found only \(files.count) files")
        #expect(files.contains { $0.lastPathComponent == Self.eventKitFile })
        for file in files where file.lastPathComponent != Self.eventKitFile {
            let text = try String(contentsOf: file, encoding: .utf8)
            let found = Self.violations(in: text).filter { $0.hasSuffix("EKEventStore") || $0.hasSuffix("import EventKit") }
            #expect(found.isEmpty, "\(file.lastPathComponent): \(found)")
        }
    }

    @Test func theEventKitSourceNeverReadsNotes() throws {
        let file = try #require(allSwiftFiles().first { $0.lastPathComponent == Self.eventKitFile })
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(Self.notesReads(in: text).isEmpty, "\(Self.notesReads(in: text))")
    }

    static func notesReads(in source: String) -> [String] {
        var found: [String] = []
        for (number, rawLine) in source.components(separatedBy: "\n").enumerated() {
            let code = rawLine.replacingOccurrences(of: #"(?<!:)//.*$"#, with: "", options: .regularExpression)
            if code.range(of: #"\.notes\b"#, options: .regularExpression) != nil { found.append("line \(number + 1)") }
        }
        return found
    }

    @Test func theNotesScannerFlagsReadsAndIgnoresComments() {
        #expect(Self.notesReads(in: "let n = event.notes") == ["line 1"])
        #expect(Self.notesReads(in: "let n = event.notes ?? \"\"") == ["line 1"])
        #expect(Self.notesReads(in: "/// notes are never read, event.notes").isEmpty)
        #expect(Self.notesReads(in: "let n = event.notesCount").isEmpty)
    }
}
