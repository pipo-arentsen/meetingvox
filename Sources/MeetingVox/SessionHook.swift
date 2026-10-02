import Foundation

/// The user's `on_stop` hook, in one place for both coordinators: spawned
/// fire-and-forget as `/bin/sh -c "<cmd> \"$0\"" <dir>`, so the session
/// directory is its sole argument whatever quoting the command uses.
enum SessionHook {
    /// Returns the launch error (for the caller's session log), nil when
    /// there's no hook configured or it launched.
    @discardableResult
    static func run(command: String?, dir: URL) -> Error? {
        guard let command else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "\(command) \"$0\"", dir.path]
        do {
            try task.run()
            return nil
        } catch {
            return error
        }
    }

    /// Run `launch` unless the session's `hook.ejecutado` marker says the
    /// hook already ran. The marker is written (atomically) before
    /// launching, so a crash, relaunch or a stuck `minuta.pendiente` can
    /// never fire the hook twice. If the marker can't be written the hook is
    /// still launched: running it once more on some later recovery is less
    /// harmful than never running it.
    ///
    /// A missing folder (moved to the Trash) never launches the hook.
    ///
    /// - Returns: true when `launch` was called.
    @discardableResult
    static func runOnce(for dir: URL, log: (String) -> Void, launch: () -> Void) -> Bool {
        // A trashed session has nothing for the hook to work on.
        guard SessionFiles.folderExists(dir) else { return false }
        guard !SessionFiles.exists(SessionFiles.hookRan, in: dir) else {
            log("on_stop hook already ran for this session; skipping")
            return false
        }
        do {
            try SessionFiles.writeMarker(SessionFiles.hookRan, in: dir)
        } catch {
            log("could not write \(SessionFiles.hookRan): \(error); running the hook anyway")
        }
        launch()
        return true
    }
}
