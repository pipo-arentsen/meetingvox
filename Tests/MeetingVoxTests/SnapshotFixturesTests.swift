import Foundation
import Testing

@testable import MeetingVox

/// The synthetic sessions the headless snapshots render (VS-2, VS-4). They
/// are checked through the same pure derivations the window uses, so a
/// fixture that no longer produces its state fails here rather than silently
/// producing a misleading PNG.
@Suite("SnapshotFixtures")
struct SnapshotFixturesTests {
    private let fm = FileManager.default

    private func makeRoot() throws -> URL {
        let root = fm.temporaryDirectory
            .appendingPathComponent("meetingvox-snapshot-fixtures-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func install(_ tempRoot: URL) throws -> (SnapshotEnvironment, SnapshotFixtures.Installed) {
        let env = try SnapshotEnvironment.make(tempRoot: tempRoot)
        return (env, try SnapshotFixtures.install(in: env))
    }

    private func entry(_ dir: URL) -> MeetingEntry { MeetingEntry.load(dir) }

    private func memory(_ dir: URL, _ env: SnapshotEnvironment) -> HindsightStatus? {
        HindsightStatus.derive(
            facts: HindsightFacts.read(dir, env.hindsightOptions), settings: env.hindsightSettings,
            timeZone: env.timeZone, authPaused: false
        )
    }

    private func pill(_ dir: URL, _ env: SnapshotEnvironment) -> StatusPill? {
        StatusPill.derive(entry: entry(dir), memory: memory(dir, env), live: [:], recordingDir: nil)
    }

    private func steps(_ dir: URL, _ env: SnapshotEnvironment) -> [PipelineStep.Kind: PipelineStep.State] {
        let derived = PipelineStepper.derive(
            entry: entry(dir), memory: memory(dir, env), live: [:], recording: false, summaryApplies: true
        )
        return Dictionary(uniqueKeysWithValues: derived.map { ($0.kind, $0.state) })
    }

    // MARK: - Coverage (VS-4)

    @Test func everyKindHasAtLeastOneSessionFolderUnderTheFixtureRoot() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let (env, installed) = try install(root)

        for kind in SnapshotFixtures.Kind.allCases {
            let dirs = installed.dirs(of: kind)
            #expect(!dirs.isEmpty, "no session for \(kind)")
            for dir in dirs {
                #expect(dir.deletingLastPathComponent().standardizedFileURL == env.recordingsRoot.standardizedFileURL)
                #expect(fm.fileExists(atPath: dir.appendingPathComponent(SessionFiles.meta).path))
            }
        }
    }

    @Test func theCompleteSessionHasEveryStepDoneAndNothingInMemoryYet() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let (env, installed) = try install(root)
        let dir = try #require(installed.dirs(of: .complete).first)

        let e = entry(dir)
        #expect(e.hasTranscript && e.hasMinutes && e.summary != nil)
        #expect(e.summaryState == .done && e.minutesState == .done)
        #expect(memory(dir, env) == .notSent) // long enough to send, not sent
        #expect(pill(dir, env) == nil) // a finished session shows no pill
        let s = steps(dir, env)
        #expect(s[.grabada] == .done && s[.transcrita] == .done && s[.minuta] == .done && s[.resumen] == .done)
    }

    @Test func theMinutesErrorSessionShowsTheErrorPillEvenWithMemoryPending() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let (env, installed) = try install(root)
        let dir = try #require(installed.dirs(of: .minutesError).first)

        let e = entry(dir)
        #expect(e.minutesFailed && !e.hasMinutes)
        #expect(memory(dir, env) == .pending)
        #expect(pill(dir, env) == .error)
        #expect(steps(dir, env)[.minuta] == .failed)
    }

    @Test func theNoMinutesSessionHasATranscriptAndNoMinutesMarkers() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let (env, installed) = try install(root)
        let dir = try #require(installed.dirs(of: .noMinutes).first)

        let e = entry(dir)
        #expect(e.hasTranscript && !e.hasMinutes && !e.minutesPending && !e.minutesFailed)
        #expect(MeetingType.of(e, knownTemplateIDs: []) == .noMinutes)
        #expect(pill(dir, env) == nil)
    }

    @Test func thePendingMemorySessionWaitsForItsSendRequest() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let (env, installed) = try install(root)
        let dir = try #require(installed.dirs(of: .pendingMemory).first)

        #expect(memory(dir, env) == .pending)
        #expect(pill(dir, env) == .pending)
        #expect(steps(dir, env)[.memoria] == .pending)
    }

    @Test func theSentSessionMatchesItsCurrentContentAndNamesTheBank() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let (env, installed) = try install(root)
        let dir = try #require(installed.dirs(of: .sent).first)

        guard case .sent(_, let bank) = memory(dir, env) else {
            Issue.record("expected .sent, got \(String(describing: memory(dir, env)))")
            return
        }
        #expect(bank == "meetingvox")
        #expect(pill(dir, env) == .sent)
        #expect(steps(dir, env)[.memoria] == .done)
    }

    @Test func theInProgressSessionOwesMinutesAndSummary() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let (env, installed) = try install(root)
        let dir = try #require(installed.dirs(of: .inProgress).first)

        let e = entry(dir)
        #expect(e.hasTranscript && !e.hasMinutes && e.minutesPending && e.summaryState == .pending)
        #expect(pill(dir, env) == .active(.minutes))
        let s = steps(dir, env)
        #expect(s[.minuta] == .active && s[.resumen] == .active)
    }

    @Test func theBulkSelectionIsThreeDistinctFixtureSessions() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let (_, installed) = try install(root)

        let all = Set(installed.sessions.map(\.dir))
        #expect(installed.bulkSelection.count == 3)
        #expect(Set(installed.bulkSelection).count == 3)
        #expect(Set(installed.bulkSelection).isSubset(of: all))
    }

    // MARK: - The list sections

    @Test func theFixtureClockYieldsHoyAyerWeekdaysAndMonths() async throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let (env, _) = try install(root)

        let entries = await MeetingIndex().scan(root: env.recordingsRoot)
        let sections = ListSections.build(entries, now: env.now, calendar: env.calendar)

        // Tue 29 Sep 2026 11:00 (UTC-3): Saturday 26 and Thursday 24 are weekday
        // sections, older sessions fall to their month.
        #expect(sections.map(\.kind) == [
            .today, .yesterday, .weekday(7), .weekday(5),
            .month(year: 2026, month: 9), .month(year: 2026, month: 8), .month(year: 2026, month: 7),
        ])
        #expect(sections.map(\.title) == [
            "Hoy", "Ayer", "Sábado", "Jueves", "Septiembre 2026", "Agosto 2026", "Julio 2026",
        ])
        #expect(sections.allSatisfy { !$0.entries.isEmpty })
    }

    @Test func theSessionsHaveDistinctAmbitosAndAtLeastOneUnclassified() async throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let (env, _) = try install(root)

        let entries = await MeetingIndex().scan(root: env.recordingsRoot)

        #expect(Set(entries.compactMap(\.ambito)) == Set(Ambito.allCases))
        #expect(entries.contains { $0.ambito == nil })
    }

    // MARK: - Realism and determinism

    @Test func summariesAndTitlesAreSpanishAndFilled() async throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let (env, _) = try install(root)

        let entries = await MeetingIndex().scan(root: env.recordingsRoot)
        let summaries = entries.compactMap(\.summary)

        #expect(summaries.count >= 6)
        #expect(summaries.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty && !$0.topics.isEmpty })
        #expect(summaries.contains { $0.client == "Cliente A" })
    }

    @Test func tasksFixturesCoverPopulatedNoneAndNotExtracted() async throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let (env, installed) = try install(root)

        let entries = await MeetingIndex().scan(root: env.recordingsRoot)
        let complete = try #require(entries.first { $0.dir.standardizedFileURL == installed.dirs(of: .complete)[0].standardizedFileURL })
        #expect((complete.summary?.tasks?.count ?? 0) >= 3)
        #expect(complete.summary?.country == "Colombia")
        let rows = TaskAggregator.build(entries)
        #expect(rows.contains { $0.task.who == nil }, "an unassigned task is shown")
        #expect(rows.contains { $0.task.who == "Yo" })
        #expect(rows.contains { $0.task.when != nil })
        #expect(TaskAggregator.whoOptions(in: rows).count >= 3, "the filter has people to pick")
        let summaries = entries.compactMap(\.summary)
        #expect(summaries.contains { $0.tasks == [] }, "one meeting was extracted and had none")
        #expect(summaries.contains { $0.tasks == nil }, "one meeting was never extracted")
        #expect(TaskAggregator.notExtractedCount(entries) == 2)
        let none = try #require(entries.first { $0.dir.standardizedFileURL == installed.dirs(of: .noMinutes)[0].standardizedFileURL })
        #expect(none.summary?.tasks == [])
        let notExtracted = try #require(entries.first { $0.dir.standardizedFileURL == installed.dirs(of: .minutesError)[0].standardizedFileURL })
        #expect(notExtracted.summary?.tasks == nil)
    }

    @Test func theMinutesFixtureRendersATableWithTasks() {
        let blocks = MarkdownBlocks.parse(SnapshotFixtures.sampleMinutes)

        // The provenance line is stripped: the first block is the title.
        #expect(blocks.first == .heading(level: 1, text: "Reunión comercial: plan del cuarto trimestre"))
        let tables = blocks.compactMap { block -> MarkdownTable? in
            if case .table(let table) = block { return table }
            return nil
        }
        #expect(tables.count == 1)
        #expect(tables.first?.header == ["Quién", "Qué", "Para cuándo"])
        #expect((tables.first?.rows.count ?? 0) >= 3)
    }

    @Test func installingTwiceProducesIdenticalFilesNoRealClockOrRandomness() throws {
        let a = try makeRoot()
        let b = try makeRoot()
        defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        let (envA, _) = try install(a)
        let (envB, _) = try install(b)

        func snapshot(_ env: SnapshotEnvironment) throws -> [String: Data] {
            var result: [String: Data] = [:]
            let base = env.recordingsRoot.standardizedFileURL.path
            let walker = try #require(fm.enumerator(at: env.recordingsRoot, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                result[String(url.standardizedFileURL.path.dropFirst(base.count))] = try Data(contentsOf: url)
            }
            return result
        }
        let (left, right) = (try snapshot(envA), try snapshot(envB))

        #expect(left.count > 40) // many files, so equality below is not vacuous
        #expect(left == right)
    }
}
