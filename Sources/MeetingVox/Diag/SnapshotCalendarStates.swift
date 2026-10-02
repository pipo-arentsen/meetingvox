import SwiftUI

/// A scripted source for the snapshots: reports one status, finds nothing
/// and never asks. Not EventKit (`SnapshotHomeGuardTests` keeps EventKit and
/// the real source factory out of `Diag/Snapshot*`).
struct SnapshotCalendarSource: CalendarSource {
    let current: CalendarSystemStatus
    func status() async -> CalendarSystemStatus { current }
    func requestFullAccess() async -> CalendarSystemStatus { current }
    func events(overlapping interval: DateInterval) async throws -> [CalendarEventSnapshot] { [] }
}

/// The calendar link's snapshot states: the Ajustes "Calendario" section off, authorized and denied, the
/// onboarding "Listo" step with its toggle, and a session whose list row and
/// detail header carry the calendar title. Every config file and fixture
/// lives under the temp root; the source is a scripted fake.
enum SnapshotCalendarStates {
    @MainActor
    static var all: [SnapshotState] {
        [settingsOff, settingsAuthorized, settingsDenied, settingsRestricted, listo, linkedDetail]
    }

    /// A model over a private config file under the temp root (`enabled`
    /// written when asked) with the status already read.
    @MainActor
    private static func model(
        _ context: SnapshotContext, name: String, enabled: Bool, system: CalendarSystemStatus
    ) -> CalendarSettingsModel {
        let url = context.env.tempRoot.appendingPathComponent("calendar-\(name).json")
        if enabled {
            try? Data(#"{"calendar":{"enabled":true}}"#.utf8).write(to: url)
        }
        let model = CalendarSettingsModel(
            configURL: url, source: SnapshotCalendarSource(current: system), notifications: NotificationCenter(),
            openURL: { _ in true })
        var finished = false
        Task { @MainActor in
            await model.refresh()
            finished = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !finished, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return model
    }

    /// The section as Ajustes › Reuniones draws it (the grouped form).
    @MainActor
    private static func settings(_ name: String, enabled: Bool, system: CalendarSystemStatus) -> SnapshotState {
        SnapshotState(name: "calendar-settings-\(name)", width: 640, height: nil) { context in
            let model = model(context, name: name, enabled: enabled, system: system)
            return AnyView(
                Form { CalendarSettingsSection(model: model) }
                    .formStyle(.grouped)
                    .frame(width: 640)
                    .fixedSize(horizontal: false, vertical: true))
        }
    }

    @MainActor static let settingsOff = settings("off", enabled: false, system: .notDetermined)
    @MainActor static let settingsAuthorized = settings("authorized", enabled: true, system: .authorized)
    @MainActor static let settingsDenied = settings("denied", enabled: true, system: .denied)
    @MainActor static let settingsRestricted = settings("restricted", enabled: true, system: .restricted)

    /// The onboarding "Listo" step with the calendar toggle, over a temp
    /// settings model and a fixed login item row (no `SMAppService`).
    @MainActor
    static let listo = SnapshotState(name: "calendar-onboarding-listo", width: 700, height: nil) { context in
        let calendar = model(context, name: "listo", enabled: true, system: .authorized)
        let loginItem = LoginItemController(
            readStatus: { (.enabled, .notRegistered) }, isInstalledBundle: true, isRecording: { false },
            install: { .service }, uninstall: { LoginItemInstaller.UninstallReport() }, openLoginItemsSettings: {})
        return AnyView(
            ReadyStepView(
                settings: context.env.makeSettingsModel(), loginItem: loginItem, calendar: calendar,
                runningRoot: context.env.recordingsRoot)
            .padding(24))
    }

    /// A complete session linked to an event: the list row and the detail
    /// header show the event title ("Revisión semanal de producto") instead
    /// of the summary's. Built on a private environment so the shared
    /// fixtures keep their summary titles for the other states.
    @MainActor
    static let linkedDetail = SnapshotState(
        name: "calendar-linked-detail", width: SnapshotDetailStates.windowSize.width,
        height: SnapshotDetailStates.windowSize.height
    ) { context in
        let root = context.env.tempRoot.appendingPathComponent("calendar-linked", isDirectory: true)
        guard let env = try? SnapshotEnvironment.make(tempRoot: root),
              let installed = try? SnapshotFixtures.install(in: env),
              let dir = installed.dirs(of: .complete).first
        else { return AnyView(Text("calendar-linked: fixtures failed")) }
        let start = env.now
        let record = CalendarEventRecord(
            id: "snapshot-event", externalID: "snapshot-ext", title: "Revisión semanal de producto",
            start: start, end: start.addingTimeInterval(3000),
            organizer: CalendarParticipant(name: "Participante 1", email: nil, isSelf: false, status: nil),
            attendees: [
                CalendarParticipant(name: "Participante 1", email: nil, isSelf: false, status: .accepted),
                CalendarParticipant(name: "Yo", email: nil, isSelf: true, status: .accepted),
                CalendarParticipant(name: "Participante 2", email: nil, isSelf: false, status: .tentative),
            ],
            matchedAt: start)
        _ = try? SessionFiles.setCalendarEvent(record, in: dir)
        let model = env.makeMainWindowModel()
        SnapshotEnvironment.load(model)
        if let entry = model.meetings.entries.first(where: { $0.dir.standardizedFileURL == dir.standardizedFileURL }) {
            model.meetings.selection = [entry.dir]
            SnapshotEnvironment.loadDetail(model)
        }
        return AnyView(MainView(model: model, onToggleRecording: {}, flatColumns: true))
    }
}
