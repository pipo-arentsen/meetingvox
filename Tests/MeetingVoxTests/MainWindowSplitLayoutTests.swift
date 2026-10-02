import AppKit
import SwiftUI
import Testing

@testable import MeetingVox

/// Regression: in the real `NavigationSplitView` the columns are measured at
/// their minimum, i.e. near-zero width. Wrapped text with
/// `.fixedSize(horizontal: false, vertical: true)` outside a `ScrollView`
/// then becomes thousands of points tall, the split view's minimum height
/// overflows the window and the title strip is pushed off screen: Tareas and
/// Glosario drew a blank window. The snapshots use `flatColumns` and never
/// saw it, so these tests measure the real split path (no app launch, no
/// window ordered front).
@MainActor
@Suite("MainWindowSplitLayout")
struct MainWindowSplitLayoutTests {
    private let fm = FileManager.default

    private func makeEnv() throws -> (SnapshotEnvironment, URL) {
        let root = fm.temporaryDirectory
            .appendingPathComponent("meetingvox-split-layout-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let env = try SnapshotEnvironment.make(tempRoot: root)
        _ = try SnapshotFixtures.install(in: env)
        return (env, root)
    }

    /// Awaits the scan directly (turning the run loop by hand does not drain
    /// the main actor under the test runner).
    private func load(_ model: MainWindowModel) async {
        await model.reload().value
        await model.meetings.factsTask?.value
    }

    /// Minimum height a column reports when it is offered almost no width (a
    /// zero-height proposal is how a split view asks for the minimum).
    private func narrowHeight<V: View>(_ view: V) -> CGFloat {
        let controller = NSHostingController(rootView: view)
        return controller.sizeThatFits(in: CGSize(width: 1, height: 0)).height
    }

    @Test func columnsStayShortWhenMeasuredNearZeroWidth() async throws {
        let (env, root) = try makeEnv()
        defer { try? fm.removeItem(at: root) }
        let model = env.makeMainWindowModel()
        await load(model)
        let limit = MainLayout.minimumSize.height

        let tasks = narrowHeight(TasksFilterPanel(model: model.tasks))
        let glossary = narrowHeight(GlossaryAddPanel(model: model.library.glossary))
        let templates = narrowHeight(TemplateListView(model: model.library.templates))
        #expect(tasks <= limit, "TasksFilterPanel asks for \(tasks) pt")
        #expect(glossary <= limit, "GlossaryAddPanel asks for \(glossary) pt")
        #expect(templates <= limit, "TemplateListView asks for \(templates) pt")
    }

    @Test func realSplitViewWindowFitsItsHeightOnEverySidebarEntry() async throws {
        let root = fm.temporaryDirectory
            .appendingPathComponent("meetingvox-split-layout-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let env = try SnapshotEnvironment.make(tempRoot: root)
        let installed = try SnapshotFixtures.install(in: env)
        let model = env.makeMainWindowModel()
        await load(model)

        let size = MainLayout.defaultSize
        let hosting = NSHostingView(rootView: MainView(model: model, onToggleRecording: {}, flatColumns: false))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        defer { window.close() }

        let entries: [SidebarItem] = [.reuniones, .tareas, .ambito(.personal), .sinClasificar, .plantillas, .glosario]
        for entry in entries {
            model.sidebar = entry
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.height <= size.height, "\(entry) wants \(hosting.fittingSize.height) pt")
        }

        // A session open on each tab: the detail column is measured too.
        model.sidebar = .reuniones
        if let fixture = installed.dirs(of: .complete).first,
           let entry = model.meetings.entries.first(where: { $0.dir.standardizedFileURL == fixture.standardizedFileURL }) {
            model.meetings.selection = [entry.dir]
            await model.session.select(entry.dir).value
            for tab in DetailTab.allCases {
                model.tab = tab
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                #expect(hosting.fittingSize.height <= size.height, "session on \(tab) wants \(hosting.fittingSize.height) pt")
            }
        } else {
            Issue.record("the complete fixture session is not in the scan: \(model.meetings.entries.map(\.dir.path)) vs \(installed.dirs(of: .complete).map(\.path))")
        }
    }
}
