import Foundation

/// The process entry point. It exists so something runs before ArgumentParser
/// and before any `Config` static is touched: the config-dir migration has
/// to copy `~/.config/quill` into place first, otherwise the first read of
/// `Config.path` (a lazy static) or an early factory-template install would
/// create a fresh, empty `~/.config/meetingvox` instead.
///
/// Order, and why:
/// 1. `LaunchArguments.sanitize`: Finder/SMAppService flags never reach
///    ArgumentParser.
/// 2. Log redirect (bundled `run` without a terminal), append only: so every
///    later line, including a refusal below, lands in the log file.
/// 3. Single-instance guard (`run` only), after waiting out transient
///    blockers: a refused second instance exits 0, so launchd's `KeepAlive
///    { SuccessfulExit: false }` does not respawn it in a loop, and it neither
///    rotates the live log, migrates nor starts a recorder.
/// 4. Log rotation, only now that this process holds the lock (a long-lived
///    process rechecks hourly, see `Run`).
/// 5. Config migration (every route except `diag --mode snapshot`, which
///    renders synthetic fixtures and must not touch the real home).
/// 6. The command.
@main
enum MeetingVoxMain {
    /// The side effects of start-up, injected so a test can observe the order.
    struct Steps {
        var redirectLog: () -> Void
        var decideInstance: () -> InstanceDecision
        /// Reports the refusal and ends the process; never returns in
        /// production (it calls `exit(0)`).
        var refuse: (InstanceDecision.Refusal) -> Void
        /// Rotates an oversized log; only called after `redirectLog`.
        var rotateLog: () -> Void
        var migrate: () -> Void
        /// The sanitized arguments after argv[0].
        var launch: ([String]) -> Void
    }

    static func main() {
        start(
            arguments: CommandLine.arguments,
            isBundled: LogRedirect.isBundled(bundleURL: Bundle.main.bundleURL),
            stderrIsTTY: isatty(STDERR_FILENO) != 0,
            steps: Steps(
                redirectLog: { LogRedirect.install() },
                decideInstance: {
                    InstanceGuard.awaitClear(
                        probe: { InstanceGuard.probe() },
                        sleep: { Thread.sleep(forTimeInterval: $0) },
                        log: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
                    )
                },
                refuse: refuseAndExit,
                rotateLog: { LogRedirect.rotateAndReattach() },
                migrate: { ConfigMigration.migrateAtStartup() },
                launch: { MeetingVoxCommand.main($0) }
            )
        )
    }

    static func start(arguments: [String], isBundled: Bool, stderrIsTTY: Bool, steps: Steps) {
        let sanitized = LaunchArguments.sanitize(arguments)
        let isRun = LaunchArguments.isRunRoute(sanitized)

        let redirected = LogRedirect.shouldRedirect(isBundled: isBundled, isRunRoute: isRun, stderrIsTTY: stderrIsTTY)
        if redirected { steps.redirectLog() }
        if isRun, case .refuse(let refusal) = steps.decideInstance() {
            steps.refuse(refusal)
            return
        }
        if redirected { steps.rotateLog() }
        // The headless snapshot renderer never touches the real home, and
        // the migration copies `~/.config/quill` into place.
        if !LaunchArguments.isSnapshotRoute(sanitized) { steps.migrate() }
        steps.launch(Array(sanitized.dropFirst()))
    }

    /// Log the cause, tell the user, exit 0. Exit 0 is deliberate: a non-zero
    /// exit would make launchd respawn the refused instance forever.
    private static func refuseAndExit(_ refusal: InstanceDecision.Refusal) {
        FileHandle.standardError.write(Data((refusal.logLine + "\n").utf8))
        let body: String
        switch refusal {
        case .alreadyRunning: body = Textos.Notificacion.yaEnEjecucion
        case .legacyRunning: body = Textos.Notificacion.quillAnteriorEnEjecucion
        }
        // osascript on purpose, even from the bundled app: a native post is
        // asynchronous and would race the `exit(0)` below.
        OsaScriptNotifier().post(Notice(title: Textos.Notificacion.yaEnEjecucionTitulo, body: body))
        exit(0)
    }
}
