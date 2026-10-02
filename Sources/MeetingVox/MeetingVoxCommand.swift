import AppKit
import ArgumentParser
import Foundation

struct MeetingVoxCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: AppIdentity.commandName,
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self, Diag.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Best-effort: a read-only or odd config dir must not keep the
        // recorder from starting — templates only matter for minutes.
        do {
            try TemplateStore.installFactoryTemplatesIfMissing(in: Config.templatesDir)
        } catch {
            FileHandle.standardError.write(Data(
                "warning: could not install minutes templates in \(Config.templatesDir.path): \(error)\n".utf8
            ))
        }

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Onboarding shows only for the bundled app on this route (never for
        // the bare binary, a CLI subcommand or tests); the plan built from it
        // holds every launch start that could raise a system prompt.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let onboarding = OnboardingGate.decide(
            isBundled: NotifierFactory.currentKind == .userNotifications,
            isRunRoute: true,
            marker: OnboardingMarker.read(at: AppIdentity.onboardingMarkerFile(home: home)),
            hasExistingConfig: FileManager.default.fileExists(atPath: Config.path.path)
        )
        if case .show(let reason) = onboarding {
            FileHandle.standardError.write(Data("onboarding: will show (\(reason))\n".utf8))
        }
        let controller = AppController(root: root, onboarding: onboarding)
        // ⌘Q and Salir ask first while recording (`requestQuit`); ⌘, opens
        // Ajustes. Installed once the controller exists, since both go to it.
        MainMenu.install(
            requestQuit: { [weak controller] in controller?.requestQuit() },
            openSettings: { [weak controller] in controller?.showSettings() }
        )
        // NSApplication keeps its delegate weakly.
        let delegate = AppDelegate(controller: controller)
        app.delegate = delegate

        // SIGINT (^C) and SIGTERM (launchd, `kill`) take the same road as ⌘Q
        // and the menu's Quit: `NSApp.terminate` → `applicationShouldTerminate`
        // → stop the recording (meta.json) → exit. The handler only requests
        // it; nothing is finalized inside the signal handler itself.
        let signalSources = [(SIGINT, "SIGINT"), (SIGTERM, "SIGTERM")].map { number, name in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                FileHandle.standardError.write(Data("\nshutting down (\(name))\n".utf8))
                MainActor.assumeIsolated { controller.shutdown() }
            }
            source.resume()
            signal(number, SIG_IGN)
            return source
        }

        // A long-lived process keeps its log bounded: recheck the size hourly
        // and reopen the file when it was rotated.
        if LogRedirect.isActive {
            Timer.scheduledTimer(withTimeInterval: LogRedirect.checkInterval, repeats: true) { _ in
                LogRedirect.rotateAndReattach()
            }
        }

        FileHandle.standardError.write(Data(
            "MeetingVox up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        withExtendedLifetime((delegate, signalSources)) { app.run() }
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let minutes: MinutesCoordinator
    private let transcription: TranscriptionCoordinator
    private let summary: SummaryCoordinator
    /// Links a finished recording to its calendar event (start lookup held in
    /// memory, one write after a normal stop, nothing on termination).
    private let calendarLink: CalendarSessionLink
    /// The one calendar source of the process: the linker, Ajustes and the
    /// onboarding toggle share it (one request gate). Only the bundled app
    /// gets a real one; nothing asks the system until the user's toggle does.
    private let calendarSource = CalendarSources.make(isBundled: NotifierFactory.currentKind == .userNotifications)
    private let hindsight: HindsightCoordinator
    private let hindsightScheduler: HindsightScheduler
    /// Posts the one "reunión lista" notice per session; evaluated after
    /// every stage callback below and once per launch.
    private let settlement: SettlementNotifier
    /// "Enviar a memoria ▸" and the Settings picker; refreshed on open and on
    /// config changes.
    private let hindsightBanks = HindsightBankList()
    /// Created on first use: most sessions never open settings, and the
    /// model touches config and Keychain when it loads.
    private lazy var settings = SettingsWindowController(
        bankList: hindsightBanks, calendarSource: calendarSource,
        onOpenOnboarding: { [weak self] in self?.onboardingReopen.fromAjustes() },
        onOpenLibrary: { [weak self] in self?.openLibrary() }
    )
    /// What the app is doing right now (stages, recording), for the main
    /// window: fed from inside the same status handlers that drive the menu
    /// lines, which it does not replace.
    private let pipeline = PipelineStatusStore()
    /// The main window (⌘J, reopening the app, notices). Created on first use;
    /// it never opens by itself at launch: the app is menu-bar-first.
    private lazy var mainWindow = makeMainWindowController()
    /// While recording the detector only watches for the meeting's end
    /// (or nothing, with `prompt_on_end` off) and resyncs once when it stops.
    private var session: RecordingSession? {
        didSet {
            meetingDetector.setRecording(session != nil)
            recordingFlag.set(session != nil)
        }
    }
    private var ticker: Timer?
    /// Mirrors `HindsightCoordinator.authPaused`, updated from its handler:
    /// the main window reads it (via `MeetingsModel`'s injected
    /// closure) to show "Error al enviar" on an otherwise-pending session.
    private var hindsightAuthPaused = false
    /// Minutes enabled when the current recording started: the menu offers
    /// "Plantilla de la minuta" only then.
    private var sessionOffersTemplate = false
    private let meetingDetector = MeetingDetector()
    /// The floating pill: the detected/ended prompts and, while recording,
    /// the recording face. One persistent window; it never records or stops by
    /// itself (its buttons come back here).
    private let pill = RecordingPillController(presenter: RecordingPillPanel(), scheduler: TimerPillScheduler())
    /// What launch may do directly, and the queue that holds the rest while
    /// the onboarding window is open (see `StartupPlan`, `DeferredStarts`).
    private let onboarding: OnboardingGate.Decision
    private let plan: StartupPlan
    private let deferred: DeferredStarts
    /// Automatic `hindsight.request(dir)`: held while onboarding is open,
    /// then run; one per session. User-initiated sends (`performHindsightAction`)
    /// never come through here: a forced or bank-specific send must not
    /// collapse into an automatic request (see `DeferredStarts`).
    private let requestHindsight: @Sendable (URL) -> Void
    /// `session != nil`, readable from the permission probes' queues.
    private let recordingFlag = RecordingFlag()
    /// The menu's "Primeros pasos…" and Ajustes' button: plain shows, no gate.
    private lazy var onboardingReopen = OnboardingReopen(show: { [weak self] in self?.showOnboarding() ?? false })
    private lazy var onboardingLauncher = OnboardingLauncher(
        runningRoot: root, recording: recordingFlag, calendarSource: calendarSource,
        onClose: { [weak self] in self?.deferred.windowClosed() }
    )

    init(root: URL, onboarding: OnboardingGate.Decision = .skip) {
        self.root = root
        let plan = StartupPlan.make(onboarding)
        let deferred = DeferredStarts(deferring: plan.deferBackground)
        self.onboarding = onboarding
        self.plan = plan
        self.deferred = deferred
        let settlement = SettlementNotifier()
        self.settlement = settlement
        // A pipeline stage finished for `dir`: the session may now be ready.
        // Fire-and-forget, hops to the main actor where the notifier lives;
        // held (one per session) while onboarding is open, since a notice can
        // raise the notification-authorization prompt.
        let stageFinished: @Sendable (URL) -> Void = { dir in
            Task { @MainActor in
                deferred.perform(.settlementEvaluate(dir.path)) { settlement.evaluate(dir) }
            }
        }
        // After every real send attempt (see `HindsightCoordinator.Environment.didAttempt`):
        // the session may now settle without waiting out the 10-minute cap.
        // The coordinator's own `authPaused` travels with it.
        var hindsightEnvironment = HindsightCoordinator.Environment.live
        hindsightEnvironment.didAttempt = { dir, paused in
            Task { @MainActor in settlement.didAttempt(dir, authPaused: paused) }
        }
        let hindsight = HindsightCoordinator(environment: hindsightEnvironment)
        self.hindsight = hindsight
        let requestHindsight: @Sendable (URL) -> Void = { dir in
            Task { @MainActor in
                deferred.perform(.hindsightRequest(dir.path)) { Task { await hindsight.request(dir) } }
            }
        }
        self.requestHindsight = requestHindsight
        hindsightScheduler = HindsightScheduler(root: root, coordinator: hindsight)
        let summary = SummaryCoordinator(environment: .live(
            indexDidChange: {
                IndexWriter.regenerate(root: root)
                Task { @MainActor in NotificationCenter.default.post(name: .meetingVoxMeetingIndexDidChange, object: nil) }
            },
            // The summary settled: the session may now be ready, with its
            // metadata. Fire-and-forget: the Hindsight actor may be busy in a
            // synchronous Keychain read (which can show a dialog), and this
            // caller must never stall waiting for its turn.
            didFinish: { dir in
                requestHindsight(dir)
                stageFinished(dir)
            }
        ))
        self.summary = summary
        // Only the bundled app gets a real source; the bare binary, tests and
        // diag get the unavailable one. `calendar.enabled` is read per recording.
        calendarLink = CalendarSessionLink(
            linker: CalendarLinker(
                source: calendarSource,
                isEnabled: { Config.values().calendarEnabled }),
            write: { record, dir in try SessionFiles.setCalendarEvent(record, in: dir, ifAbsent: true) },
            reindex: { await summary.reindex() })
        let minutes = MinutesCoordinator(environment: .live(
            onAutomaticFinished: { dir in
                // Summary first: its `resumen.pendiente` must exist before the
                // export looks, so the send waits for the summary's metadata.
                // The export request itself is fire-and-forget (see above).
                await summary.request(dir)
                requestHindsight(dir)
                stageFinished(dir)
            },
            // A regenerate or after-the-fact "Generar minuta" (main
            // window) usually doesn't get a `.meetingVoxMeetingIndexDidChange`
            // from the summary pipeline above: `summary.request` typically
            // no-ops once `resumen.json` already exists with source
            // `.minutes`. Refresh the open window directly instead.
            // Fire-and-forget, same reasoning as the export request.
            onMinutesWritten: { dir in
                Task { @MainActor in NotificationCenter.default.post(name: .meetingVoxMeetingIndexDidChange, object: nil) }
                stageFinished(dir)
            },
            // A user-requested "Minuta lista" is its meeting's ready notice:
            // take the claim first so the settlement check right after the
            // same success posts nothing more. Awaited (not fire-and-forget):
            // the claim must exist before the notice and the check.
            claimReadyNotice: { dir in
                await MainActor.run { settlement.claimReadyNotice(dir) }
            }
        ))
        self.minutes = minutes
        // Chained, not nested: the transcription queue only drops the job
        // into the minutes queue, so the LLM call never keeps Parakeet loaded.
        // With minutes disabled, the summary (then the export) is requested directly.
        transcription = TranscriptionCoordinator(
            // Both handoffs lead to a job that reads the OpenRouter key, so
            // while onboarding holds the starts they wait (one per session)
            // and run on release; transcription itself already ran.
            minutesHandoff: { dir in
                await deferred.handoff(dir) { await minutes.enqueueAutomatic(dir) }
            },
            summaryHandoff: { dir in
                await deferred.handoff(dir) {
                    await summary.request(dir)
                    // Fire-and-forget: see the `didFinish` closure above.
                    requestHindsight(dir)
                    stageFinished(dir)
                }
            }
        )
        settlement.startObservingWake()
        pill.startObservingWake()
        // `recording_pill.enabled` and `meeting_detection.auto_stop`, re-read on
        // every config write: the controller itself never touches Config.
        pill.startObservingConfig {
            let values = Config.values()
            let detection = MeetingDetectionConfig(values)
            return (values.recordingPillEnabled, detection.autoStopActive)
        }
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.sessionTemplate.source = { [weak self] in
            (TemplateStore.list(in: Config.templatesDir),
             self?.session?.minutesTemplate ?? Config.minutesTemplate())
        }
        menuBar.sessionTemplate.onSelect = { [weak self] id in self?.setSessionTemplate(id) }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onSettings = { [weak self] in self?.settings.show() }
        menuBar.onOnboarding = { [weak self] in self?.onboardingReopen.fromMenu() }
        menuBar.onMainWindow = { [weak self] in self?.showMainWindow() }
        menuBar.onQuit = { [weak self] in self?.requestQuit() }
        menuBar.update(recording: false, elapsed: nil)
        configureMenuBar()
        configureMeetingDetection()
        // The observer's own refreshes (a config change) are held with the
        // launch one while onboarding is open.
        hindsightBanks.refreshGate = { action in deferred.perform(.banksRefresh, action) }
        hindsightBanks.startObservingConfig()
        let hindsightBanks = self.hindsightBanks
        plan.launch(.banksRefresh, key: .banksRefresh, through: deferred) { hindsightBanks.refresh() }
        // Ask now, not while starting the first meeting (never blocks); with
        // onboarding, after it (the Permisos step asks on a click).
        plan.launch(.mic, key: .micPermission, through: deferred) { MicPermission.requestIfUndetermined() }

        // Local-network check (Hindsight plan, task 4): one probe at launch so
        // the log shows whether launchd-run quill reaches the server. Detached:
        // the Keychain read may prompt and must not block the main thread.
        // Held while onboarding is open: the probe raises the Local Network
        // prompt, which must follow a click.
        plan.launch(.hindsightProbe, key: .hindsightProbe, through: deferred) {
            Task.detached {
                if let line = await HindsightClient.startupProbe(
                    config: Config.values(), keyStore: Keychain.hindsight, backend: HindsightClient()
                ) {
                    FileHandle.standardError.write(Data("\(line)\n".utf8))
                }
            }
        }

        Task { [transcription, minutes, summary, settlement, root, plan, deferred] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await minutes.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showMinutes(status)
                }
            }
            await summary.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showSummary(status)
                }
            }
            // Transcription resumes at once (no Keychain, no network). Pending
            // minutes and summaries read the OpenRouter key, which can raise
            // the legacy-item prompt: held while onboarding is open.
            await plan.resumeAtLaunch(
                transcription: { await transcription.resumePending(root: root) },
                keychainJobs: {
                    await minutes.resumePending(root: root)
                    await summary.resumePending(root: root)
                },
                through: deferred
            )
            // Sessions that settled while the app was closed (or whose
            // notice was never claimed) are notified now — never the ones
            // that started before the cutoff.
            await MainActor.run {
                plan.launch(.background, key: .settlementPending, through: deferred) {
                    settlement.evaluatePending(root: root)
                }
            }
        }

        // Menu status line first, then the sweeps (launch, every 10 min,
        // network back, settings changed).
        Task { [weak self, hindsight] in
            // The memory send in flight, for the main window's overlay.
            await hindsight.setStatusHandler { status in
                Task { @MainActor in self?.pipeline.apply(StageEvent(status)) }
            }
            await hindsight.setAuthPausedHandler { paused in
                Task { @MainActor in
                    self?.hindsightAuthPaused = paused
                    self?.settlement.authPaused = paused
                    self?.menuBar.updateHindsight(paused ? Textos.Memoria.tokenInvalido : nil)
                }
            }
            // `setAuthPausedHandler`'s Task and this one are two
            // independent hops off the actor, so their relative order on
            // the main actor isn't guaranteed. Instead of racing them,
            // this one re-reads `authPaused` straight from the actor
            // before touching the mirror or posting: by construction the
            // mirror is correct before .meetingVoxHindsightStatusDidChange goes
            // out, so any observer's reload sees the up-to-date value —
            // regardless of whether the other handler's Task has run yet.
            await hindsight.setChangeHandler { [weak self, hindsight] in
                Task { @MainActor in
                    let paused = await hindsight.authPaused
                    self?.hindsightAuthPaused = paused
                    self?.menuBar.updateHindsight(paused ? Textos.Memoria.tokenInvalido : nil)
                    NotificationCenter.default.post(name: .meetingVoxHindsightStatusDidChange, object: nil)
                }
            }
            guard let self else { return }
            // The first sweep and the timer: Local Network and notices, so
            // held while onboarding is open.
            self.plan.launch(.background, key: .hindsightScheduler, through: self.deferred) { [weak self] in
                self?.hindsightScheduler.start()
            }
        }
    }

    /// Feed the status menu's "Última" and its ⌥ item from the recordings
    /// root. `lastSession` runs each time the menu opens, on the main thread,
    /// so it stays one directory listing and never prompts.
    private func configureMenuBar() {
        let root = self.root
        menuBar.lastSession = { MenuModel.last(in: root) }
        // "Última": the session in the window, on the Minuta tab when it has
        // minutes (`OpenTarget`).
        menuBar.onOpenLast = { [weak self] dir, hasMinutes in
            self?.open(OpenTarget.decide(opening: dir, hasMinutes: hasMinutes))
        }
        // ⌥ on "Abrir MeetingVox": backfill summaries and regenerate `indice.md`.
        menuBar.onRebuildIndex = { [summary, root] in
            Task { await summary.rebuild(root: root) }
        }
    }

    /// The main window: the list engine over the recordings root, plus the
    /// live store and the session detail's toolbar wiring.
    private func makeMainWindowController() -> MainWindowController {
        let meetings = MeetingsModel(
            root: root, config: { Config.values() },
            hindsightAuthPaused: { [weak self] in self?.hindsightAuthPaused ?? false }
        )
        meetings.listTemplates = { TemplateStore.list(in: Config.templatesDir) }
        meetings.otherBanks = { [weak self] in self?.hindsightBanks.others ?? [] }
        meetings.defaultBank = { [weak self] in self?.hindsightBanks.defaultBank }
        let session = SessionDetailModel(inputs: { [weak self] in self?.detailInputs() ?? .none })
        configureDetailCommands(session)
        // Biblioteca's editors over the real folders. The glossary's
        // SettingsModel is a second instance beside Ajustes' own: both write
        // through the config file and re-read it when shown.
        let library = LibraryModel(
            templates: TemplateEditorModel(dir: Config.templatesDir),
            glossary: SettingsModel(
                configURL: Config.path, templatesDir: Config.templatesDir, keychain: Keychain.openRouter
            )
        )
        self.library = library
        let model = MainWindowModel(
            meetings: meetings, store: pipeline, calendar: .current, now: { Date() }, session: session, library: library
        )
        // "Mover a la papelera…": memory deletion through the coordinator
        // (token read inside it) and `trashItem` — a session folder is never
        // `removeItem`'d, so it stays recoverable from the macOS Trash.
        let hindsight = self.hindsight
        model.trashEffects.deleteFromMemory = { await hindsight.deleteFromMemory($0) }
        // Owed work = on-disk requests, or a transcription the coordinator
        // still has queued or running (a failed one is neither: trashable).
        let transcription = self.transcription
        model.trashEffects.hasPendingWork = { dir in
            if TrashPlan.hasPendingWorkOnDisk(dir) { return true }
            return await transcription.isQueuedOrRunning(dir)
        }
        model.trashEffects.trash = { dir in
            var resulting: NSURL?
            try FileManager.default.trashItem(at: dir, resultingItemURL: &resulting)
        }
        return MainWindowController(model: model, onToggleRecording: { [weak self] in self?.toggle() })
    }

    /// What a selection reads from config and the Keychain attributes (never a
    /// secret): the memory options, whether summaries can run, and why minutes
    /// cannot (the reason the sessions menu shows).
    private func detailInputs() -> SessionDetailInputs {
        let config = Config.values()
        let hasKey = Keychain.openRouter.hasAPIKey()
        let reason: String? = if !hasKey {
            Textos.Sesiones.sinClave
        } else if config.openRouterModel == nil {
            Textos.Sesiones.sinModelo
        } else {
            nil
        }
        return SessionDetailInputs(
            options: config.hindsightEnabled ? HindsightFacts.Options(config: config, timeZone: .current) : nil,
            summaryApplies: SummaryGate.applies(config: config, hasTranscript: true, hasAPIKey: hasKey),
            minutesUnavailableReason: reason,
            defaultTemplateID: config.minutesTemplate
        )
    }

    /// The detail toolbar and stepper actions: the same coordinator calls the
    /// menu makes. A memory send arrives already re-checked
    /// against the disk (`SessionDetailModel.chooseMemory`).
    private func configureDetailCommands(_ session: SessionDetailModel) {
        let (minutes, hindsight, summary) = (self.minutes, self.hindsight, self.summary)
        session.commands.reindex = { Task { await summary.reindex() } }
        session.liveMemoryStatus = { [weak self] dir in self?.liveHindsightStatus(dir) }
        session.commands.openFolder = { NSWorkspace.shared.open($0) }
        session.commands.openFile = { NSWorkspace.shared.open($0) }
        session.commands.applyGlossary = { [weak self] dir in self?.applyGlossary(dir) }
        session.commands.regenerate = { dir, templateID in
            Task { await minutes.regenerate(dir, templateID: templateID) }
        }
        session.commands.generateManual = { dir, templateID in
            Task { await minutes.generate(dir, templateID: templateID) }
        }
        // The Minuta tab's "Generar minuta": a pure user-requested job, no
        // `minuta.pendiente` marker and no `on_stop` hook.
        session.commands.generateFromWindow = { dir in
            await minutes.generateFromWindow(dir)
        }
        session.commands.retryStage = { [weak self] stage, dir, refused in
            // A stage with nothing to retry says so in the detail (`refused`)
            // and the window re-reads the session, rather than opening another
            // window; the log line stays.
            self?.retry(stage, dir) { stage, dir in
                NotificationLog.write("\(stage.rawValue) retry does not apply to \(dir.lastPathComponent)")
                refused()
                NotificationCenter.default.post(name: .meetingVoxMeetingIndexDidChange, object: nil)
            }
        }
        session.commands.sendToMemory = { [weak self] dir, action, bank in
            self?.performHindsightAction(action, on: dir, bank: bank)
        }
        session.commands.setMemorySkipped = { dir, skipped in
            Task { await hindsight.setSkipped(dir, skipped) }
        }
    }

    /// Menu and main-window memory actions → coordinator. Fire-and-forget: the
    /// actor may be busy in a Keychain read and the UI never waits.
    private func performHindsightAction(_ action: HindsightStatus.Action, on dir: URL, bank: String?) {
        let hindsight = self.hindsight
        Task {
            switch action {
            case .send, .sendAnyway: await hindsight.send(dir, force: false, bank: bank)
            case .resend: await hindsight.send(dir, force: true)
            case .retry: await hindsight.retryNow(dir)
            }
        }
    }

    /// "Aplicar glosario" from the menu or the main window. Fire-and-forget; the
    /// user hears back by notification. A rewritten transcript may change
    /// what Hindsight holds, so the session is re-evaluated (sent only if
    /// subscribed or auto-eligible) and open windows reload.
    private func applyGlossary(_ dir: URL) {
        let transcription = self.transcription
        let requestHindsight = self.requestHindsight
        let name = dir.lastPathComponent
        Task {
            switch await transcription.applyGlossary(dir) {
            case .rewritten(let replacements)?:
                notifyUser(title: Textos.Notificacion.glosarioAplicado, body: Textos.Notificacion.reemplazos(name, replacements))
                requestHindsight(dir)
                await MainActor.run {
                    NotificationCenter.default.post(name: .meetingVoxMeetingIndexDidChange, object: nil)
                }
            case .unchanged?:
                notifyUser(title: Textos.Notificacion.glosarioAplicado, body: Textos.Notificacion.sinCambiosGlosario(name))
            case nil:
                notifyUser(title: Textos.Notificacion.glosarioFallido, body: Textos.Notificacion.glosarioFallidoCuerpo(name))
            }
        }
    }

    /// Prompt to record when a known meeting app starts using the mic. The
    /// detector never records by itself: only "Grabar" in the pill does,
    /// through the same path as the menu.
    private func configureMeetingDetection() {
        // The prompt state, never "the pill window is on screen": a recording pill is not
        // a prompt, or the end machine would never emit during a recording. The
        // pill also owns the async re-evaluation after a prompt closes.
        pill.connect(to: meetingDetector)
        meetingDetector.onPrompt = { [weak self] prompt in self?.showMeetingPrompt(prompt) }
        meetingDetector.onEndPrompt = { [weak self] prompt in self?.showMeetingEndPrompt(prompt) }
        // The call resumed, the feature was turned off or the app ignored:
        // close the end prompt (only that kind; closing never stops anything).
        meetingDetector.onEndPromptWithdrawn = { [weak self] in
            guard let self, self.pill.promptKind == .end else { return }
            self.pill.dismiss()
        }
        // The countdown reached zero: the same path as "Detener".
        pill.onAutoStop = { [weak self] in
            guard let self, self.session != nil else { return }
            FileHandle.standardError.write(Data("meeting end prompt: auto-stop\n".utf8))
            self.stopSession()
        }
        meetingDetector.start()
    }

    private func showMeetingPrompt(_ prompt: MeetingDetectionMachine.Prompt) {
        guard session == nil else { return }
        let config = meetingDetector.config
        pill.show(
            label: prompt.app.label,
            templates: config.minutesEnabled ? TemplateStore.list(in: Config.templatesDir) : nil,
            defaultTemplate: config.minutesTemplate,
            onRecord: { [weak self] templateID in
                guard let self, self.session == nil else { return }
                self.startSession(minutesTemplate: templateID, meetingApp: prompt.app.id)
            },
            onIgnore: {
                FileHandle.standardError.write(Data("meeting prompt ignored: \(prompt.app.id)\n".utf8))
            }
        )
    }

    /// "The meeting ended — stop?". Never stops by itself: "Detener" takes
    /// the menu's stop path; "Seguir grabando" waits for the next capture
    /// and release. Closed by `stopSession` if the recording ends otherwise,
    /// and withdrawn by the detector when it no longer applies.
    private func showMeetingEndPrompt(_ prompt: MeetingEndMachine.Prompt) {
        guard session != nil else { return }
        let config = meetingDetector.config
        pill.showEnd(
            title: prompt.app.endedTitle,
            autoStop: config.autoStopActive,
            onStop: { [weak self] in
                guard let self, self.session != nil else { return }
                FileHandle.standardError.write(Data("meeting end prompt: stop (\(prompt.app.id))\n".utf8))
                self.stopSession()
            },
            onContinue: { [weak self] in
                FileHandle.standardError.write(Data("meeting end prompt: keep recording (\(prompt.app.id))\n".utf8))
                self?.meetingDetector.endPromptDismissed()
            }
        )
    }

    var isRecording: Bool { session != nil }

    // MARK: - Onboarding

    /// `applicationDidFinishLaunching`: the window needs the app running, so
    /// it opens here rather than in `init`. A window that does not come up
    /// releases the held starts at once.
    func launchFinished() {
        guard case .show = onboarding else { return }
        if !showOnboarding() { deferred.windowFailed() }
    }

    /// Launch, the menu's "Primeros pasos…" and Ajustes, regardless of the
    /// marker. Re-opening after the starts were released changes nothing else.
    @discardableResult
    func showOnboarding() -> Bool { onboardingLauncher.show() }

    /// Quit. The signal handlers call this directly; it goes through
    /// `NSApp.terminate` so `AppDelegate.applicationShouldTerminate` (and
    /// `TerminationPolicy`) decide, the same as for logout. A person quitting
    /// (⌘Q, the menu bar's Salir) comes through `requestQuit` instead.
    func shutdown() {
        NSApp.terminate(nil)
    }

    /// ⌘Q and the menu bar's Salir. While a recording is in progress, or a
    /// template has unsaved changes, the user is asked first
    /// (`QuitDecision.questions`); confirming quits through `shutdown()`,
    /// which finalizes the recording. Signals never come here, so they never
    /// show UI.
    func requestQuit() {
        let draft = library?.templates.draftName
        let questions = QuitDecision.questions(isRecording: isRecording, draft: draft)
        guard !questions.isEmpty else { return shutdown() }
        // An accessory app is not frontmost: without this the alert would
        // open behind the meeting window.
        NSApp.activate()
        for question in questions {
            switch question {
            case .stopRecording:
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = Textos.Salir.pregunta
                alert.informativeText = Textos.Salir.detalle
                alert.addButton(withTitle: Textos.Salir.detenerYSalir)
                alert.addButton(withTitle: Textos.Salir.cancelar)
                let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                guard QuitDecision.Answer(buttonIndex: index).terminates else { return }
            case .saveDraft(let name):
                guard confirmDraft(named: name) else { return }
            }
        }
        // The delegate must not ask a second time on the terminate below.
        quitConfirmed = true
        shutdown()
    }

    /// "Hay cambios sin guardar en la plantilla X": Guardar / Descartar /
    /// Cancelar. Saving that fails (the file changed on disk, a write error)
    /// keeps the app open on the editor, which shows why.
    private func confirmDraft(named name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Textos.Salir.plantillaSinGuardar(name)
        alert.informativeText = Textos.Salir.plantillaDetalle
        alert.addButton(withTitle: Textos.Salir.guardar)
        alert.addButton(withTitle: Textos.Salir.descartar)
        alert.addButton(withTitle: Textos.Salir.cancelar)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let answer = QuitDecision.DraftAnswer(buttonIndex: index)
        var saved = false
        if answer == .save, let editor = library?.templates {
            editor.save()
            saved = !editor.isDirty && editor.failure == nil
            if !saved { openLibrary() } // show the banner that says why
        }
        return answer.proceeds(saved: saved)
    }

    /// The Biblioteca's editors once the main window has been created; nil
    /// before, so asking about a draft never builds the window.
    private var library: LibraryModel?

    /// A template has unsaved changes: a person quitting from the Dock is
    /// asked too (`QuitDecision.atTermination`).
    var hasTemplateDraft: Bool { library?.templates.draftName != nil }

    /// The person already answered "Detener y salir": `applicationShouldTerminate`
    /// lets this termination through without asking again.
    private(set) var quitConfirmed = false

    /// Ajustes… (⌘, in the main menu).
    func showSettings() {
        settings.show()
    }

    /// Called by the delegate once termination is approved: stop the
    /// background machinery and finalize a live session synchronously
    /// (`meta.json` is written before the delegate replies). Transcription is
    /// not enqueued: the process is about to exit, and the filesystem is the
    /// queue, so the next launch resumes the session (`meta.json` without
    /// `transcript.json`).
    func prepareForTermination() {
        meetingDetector.stop()
        hindsightScheduler.stop()
        settlement.stopObservingWake()
        pill.stopObservingWake()
        pill.dismiss()
        stopSession(enqueueTranscription: false)
    }

    /// The main window (⌘J, the menu item, the app being reopened), optionally
    /// on one session (a notice's "Abrir"/"Ver reunión") and tab. While
    /// onboarding holds the starts, bring it forward instead and open the
    /// requested session once they are released (`MainWindowOpenRouter`).
    func showMainWindow(focusing session: URL? = nil, tab: DetailTab? = nil) {
        windowRouter.open(focusing: session, tab: tab)
    }

    /// Ajustes' "Abrir Biblioteca": the main window on Plantillas.
    func openLibrary() {
        mainWindow.select(.plantillas)
        showMainWindow()
    }

    private lazy var windowRouter = MainWindowOpenRouter(
        deferred: deferred,
        showOnboarding: { [weak self] in self?.showOnboarding() ?? false },
        // Through the gate as well (a no-op distinction once released).
        refreshBanks: { [weak self] in
            guard let self else { return }
            let banks = self.hindsightBanks
            self.deferred.perform(.banksRefresh) { banks.refresh() }
        },
        present: { [weak self] session, tab in self?.mainWindow.show(focusing: session, tab: tab) }
    )

    /// Applies an `OpenTarget`: a session opens in the window, a file in its
    /// default app.
    private func open(_ target: OpenTarget) {
        switch target {
        case .session(let dir, let tab): showMainWindow(focusing: dir, tab: tab)
        case .external(let file): NSWorkspace.shared.open(file)
        }
    }

    // MARK: - Notification actions

    /// A tap on a native notice. The action came out of a notification's
    /// `userInfo` (stored by the system, so not trusted): it only proceeds for
    /// a recorded session under the recordings root.
    func perform(_ action: AppAction) {
        guard let action = NotificationActionRouter.validated(action, root: root) else {
            NotificationLog.write("ignoring an action for an unknown session")
            return
        }
        switch action {
        case .openSession(let dir): openSession(dir)
        case .openFile(let file): open(OpenTarget.decide(file: file))
        case .showSession(let dir): open(OpenTarget.decide(showing: dir, refusedStage: nil))
        case .retry(let stage, let dir): retry(stage, dir)
        case .sendToMemory(let dir): tapMemory(.send, dir)
        }
    }

    /// "Abrir": the session in the main window, on the Minuta tab when it has
    /// minutes.
    func openSession(_ dir: URL) {
        open(OpenTarget.decide(opening: dir, hasMinutes: SessionFiles.exists(SessionFiles.minutes, in: dir)))
    }

    /// The live memory status (cheap facts, config and auth snapshot): nil with the integration off.
    private func liveHindsightStatus(_ dir: URL) -> HindsightStatus? {
        let config = Config.values()
        guard config.hindsightEnabled else { return nil }
        return HindsightStatus.derive(
            facts: HindsightFacts.readCheap(dir),
            settings: HindsightStatus.Settings(config: config), timeZone: .current,
            authPaused: hindsightAuthPaused
        )
    }

    /// A memory button on a notice may be stale ("No enviar a memoria" since,
    /// or already sent): only act if the live status still offers it.
    private func tapMemory(_ request: NotificationActionRouter.MemoryRequest, _ dir: URL) {
        switch NotificationActionRouter.memoryTap(request, status: liveHindsightStatus(dir)) {
        case .send: performHindsightAction(.send, on: dir, bank: nil)
        case .retryNow: performHindsightAction(.retry, on: dir, bank: nil)
        case .show:
            NotificationLog.write("memory \(request) no longer applies to \(dir.lastPathComponent); showing it")
            open(OpenTarget.decide(showing: dir, refusedStage: nil))
        }
    }

    /// "Reintentar" on a failure notice: each stage's own retry entry point.
    /// Fire-and-forget, like the menu; a success settles the session and the
    /// ready notice follows from the stage callbacks as usual. When the
    /// stage's gate refuses (transcription off, summary off or without a
    /// key/model, nothing to redo) the session is shown instead, so a tap
    /// never does nothing silently.
    private func retry(_ stage: Notice.Stage, _ dir: URL) {
        retry(stage, dir, whenRefused: { [weak self] stage, dir in self?.retryRefused(stage, dir) })
    }

    /// `whenRefused` decides what "nothing to retry" means for the caller: a
    /// notice tap shows the session, the detail just refreshes.
    private func retry(
        _ stage: Notice.Stage, _ dir: URL, whenRefused: @escaping @MainActor @Sendable (Notice.Stage, URL) -> Void
    ) {
        let (transcription, minutes, summary) = (self.transcription, self.minutes, self.summary)
        switch stage {
        case .memory:
            tapMemory(.retry, dir)
        case .transcription:
            Task { if await !transcription.retry(dir) { whenRefused(stage, dir) } }
        case .summary:
            Task { if await !summary.retry(dir) { whenRefused(stage, dir) } }
        case .minutes:
            switch NotificationActionRouter.minutesRetry(for: MinutesRequestRoute.decide(dir: dir)) {
            case .retryAutomatic: Task { await minutes.retry(dir) }
            case .showSession: whenRefused(stage, dir)
            }
        }
    }

    /// The stage had nothing to retry: log one line and show the session.
    private func retryRefused(_ stage: Notice.Stage, _ dir: URL) {
        NotificationLog.write("\(stage.rawValue) retry does not apply to \(dir.lastPathComponent); showing it")
        open(OpenTarget.decide(showing: dir, refusedStage: stage))
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    /// - Parameters:
    ///   - minutesTemplate: template chosen in the meeting prompt (nil from
    ///     the menu, or with minutes disabled).
    ///   - meetingApp: the meeting app rule id, only set when started from
    ///     the meeting prompt (nil from the menu/toggle).
    private func startSession(minutesTemplate: String? = nil, meetingApp: String? = nil) {
        pill.prepareForRecording()
        do {
            let newSession = try RecordingSession(root: root)
            newSession.minutesTemplate = minutesTemplate
            newSession.meetingApp = meetingApp
            // Before the tracks start: a mic that is silent from the first second
            // must still reach the pill. Only the current recording's signals count.
            let dir = newSession.dir
            newSession.onMicSignal = { [weak self] signal in
                Task { @MainActor in
                    guard let self, self.session?.dir == dir else { return }
                    self.pill.micSignal(signal)
                }
            }
            try newSession.start()
            session = newSession
            // After `start()` succeeded: a failed start never queries the calendar.
            calendarLink.recordingStarted(dir: dir, startedAt: newSession.startedAt, meetingApp: meetingApp)
            // Whether the system tap excludes this process decides if the
            // player may keep going during the recording; it must be set
            // before `.recording` so the gate reads the right answer.
            pipeline.recordingExcludesSelf = newSession.systemTapExcludesSelf
            pipeline.apply(.recording(newSession.dir, elapsed: 0))
            // A recording is under way: nothing is left to protect the user
            // from a prompt at a bad moment, and the pipeline must not wait.
            deferred.recordingStarted()
            pill.recordingStarted(pillRecording(for: newSession))
            FileHandle.standardError.write(Data(
                "● recording → \(newSession.dir.path)\(minutesTemplate.map { " · template \($0)" } ?? "")\n".utf8
            ))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: Textos.Notificacion.grabacionFallida, body: "\(error)")
            pill.recordingFailed()
            return
        }

        sessionOffersTemplate = Config.minutesEnabled()
        menuBar.update(
            recording: true, elapsed: "0:00", showTemplateMenu: sessionOffersTemplate,
            app: meetingApp.map(MeetingRowMeta.appName)
        )
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopSession(enqueueTranscription: Bool = true) {
        guard let session else { return }
        // The end prompt belongs to this recording (the start prompt can't
        // be up while recording); the pill goes with it.
        pill.recordingStopped()
        session.stop()
        // Captured here, after `stop()` returned: the follow-up refines with it.
        let endedAt = Date()
        let elapsed = ElapsedText.format(endedAt.timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        pipeline.apply(.recording(nil, elapsed: 0))
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        // Termination (signals, logout, quit): the start lookup is dropped and
        // nothing calendar-related is written; the drain stays synchronous.
        guard enqueueTranscription else {
            calendarLink.recordingTerminated()
            return
        }
        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
        // Normal stop: meta.json is already written exactly as without the
        // feature; the follow-up (off-main) may add `calendar_event` once.
        calendarLink.recordingStopped(endedAt: endedAt)
    }

    /// The minutes template chosen while recording, from the menu or the pill:
    /// one path so both surfaces stay in step (the pill's own picker already
    /// shows it; `setTemplate` is idempotent).
    private func setSessionTemplate(_ id: String) {
        guard let session else { return }
        session.minutesTemplate = id
        pill.setTemplate(id)
        FileHandle.standardError.write(Data("session minutes template → \(id)\n".utf8))
    }

    /// What the pill needs for this recording; every Config read happens here,
    /// never in the controller. The picker only when minutes are enabled (the
    /// same rule as the menu's "Plantilla de la minuta").
    private func pillRecording(for newSession: RecordingSession) -> PillRecording {
        let offersTemplate = Config.minutesEnabled()
        return PillRecording(
            startedAt: newSession.startedAt,
            templates: offersTemplate ? TemplateStore.list(in: Config.templatesDir) : nil,
            selectedTemplate: newSession.minutesTemplate ?? Config.minutesTemplate(),
            pillEnabled: Config.values().recordingPillEnabled,
            levels: { [weak newSession] in
                newSession?.levels() ?? LevelSnapshot(mic: .unavailable, system: .unavailable)
            },
            onTemplate: { [weak self] id in self?.setSessionTemplate(id) },
            onStop: { [weak self] in self?.stopSession() },
            openSoundInput: {
                if SystemSettingsLink.openSoundInputInSystemSettings() == nil {
                    // No Sound candidate opened: the Privacy pane is the last resort.
                    _ = SystemSettingsLink.openInSystemSettings(.microphone)
                }
            })
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        pipeline.apply(StageEvent(status))
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0
                    ? Textos.Transcripcion.transcribiendo(name, enCola: queued)
                    : Textos.Transcripcion.transcribiendo(name)
            )
        case .failed(let name):
            menuBar.updateTranscription(Textos.Transcripcion.fallo(name))
        }
    }

    private func showMinutes(_ status: MinutesCoordinator.Status) {
        pipeline.apply(StageEvent(status))
        switch status {
        case .idle:
            menuBar.updateMinutes(nil)
        case .generating(let name, let queued):
            menuBar.updateMinutes(
                queued > 0 ? Textos.Minuta.generando(name, enCola: queued) : Textos.Minuta.generando(name)
            )
        case .waitingRetry(let name):
            menuBar.updateMinutes(Textos.Minuta.esperandoReintento(name))
        case .failed(let name):
            menuBar.updateMinutes(Textos.Minuta.fallo(name))
        }
    }

    private func showSummary(_ status: SummaryCoordinator.Status) {
        pipeline.apply(StageEvent(status))
        switch status {
        case .idle:
            menuBar.updateSummary(nil)
        case .generating(let name, let queued):
            menuBar.updateSummary(
                queued > 0 ? Textos.Resumen.generando(name, enCola: queued) : Textos.Resumen.generando(name)
            )
        case .waitingRetry(let name):
            menuBar.updateSummary(Textos.Resumen.esperandoReintento(name))
        case .failed(let name):
            menuBar.updateSummary(Textos.Resumen.fallo(name))
        case .extractingTasks(let name, let queued):
            menuBar.updateSummary(
                queued > 0 ? Textos.Resumen.extrayendoTareas(name, enCola: queued) : Textos.Resumen.extrayendoTareas(name)
            )
        }
    }

    private func tick() {
        guard let session else { return }
        let elapsed = Date().timeIntervalSince(session.startedAt)
        menuBar.update(
            recording: true,
            elapsed: ElapsedText.format(elapsed),
            showTemplateMenu: sessionOffersTemplate,
            app: session.meetingApp.map(MeetingRowMeta.appName)
        )
        pipeline.apply(.recording(session.dir, elapsed: elapsed))
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }
}
