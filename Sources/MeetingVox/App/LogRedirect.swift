import Darwin
import Foundation

/// A bundled app started by Finder, SMAppService or launchd has no terminal,
/// so everything it writes to stderr would vanish. Redirecting the file
/// descriptors at startup keeps every existing call site as it is. (A
/// LaunchAgent `StandardErrorPath` can't do it: launchd doesn't expand `~` in
/// a plist embedded in a bundle.)
///
/// Redirecting and rotating are separate steps: a second instance that is
/// about to be refused may append its refusal line to the live log, but must
/// never rotate it out from under the running one.
enum LogRedirect {
    static let maxBytes: Int64 = 10 * 1024 * 1024
    /// A long-lived process rechecks the size this often.
    static let checkInterval: TimeInterval = 3600

    /// True once `install` pointed stderr at the log; the hourly check only
    /// exists then. Written once at startup, before any other thread.
    nonisolated(unsafe) private(set) static var isActive = false

    /// Only a bundled `run` whose stderr isn't already a terminal. The CLI,
    /// `doctor`, `diag` and tests keep their own stderr.
    static func shouldRedirect(isBundled: Bool, isRunRoute: Bool, stderrIsTTY: Bool) -> Bool {
        isBundled && isRunRoute && !stderrIsTTY
    }

    static func isBundled(bundleURL: URL) -> Bool {
        bundleURL.pathExtension == "app"
    }

    /// Moves a log over `maxBytes` to `<name>.1`, replacing the previous one.
    /// One generation is enough for a diagnostic log. Returns whether it
    /// rotated; a missing file or any failure just returns false.
    @discardableResult
    static func rotateIfNeeded(
        logFile: URL, maxBytes: Int64 = LogRedirect.maxBytes, fileManager: FileManager = .default
    ) -> Bool {
        guard let size = (try? fileManager.attributesOfItem(atPath: logFile.path))?[.size] as? NSNumber,
              size.int64Value > maxBytes else { return false }
        let old = logFile.appendingPathExtension("1")
        try? fileManager.removeItem(at: old)
        do {
            try fileManager.moveItem(at: logFile, to: old)
            return true
        } catch {
            return false
        }
    }

    /// Opens `file` for append (0600) and `dup2`s it onto each descriptor in
    /// `descriptors`. All or nothing: the log is opened and the originals are
    /// duplicated first, so a failure at any step leaves every descriptor as
    /// it was (`freopen` would close stderr before failing).
    @discardableResult
    static func redirect(to file: URL, onto descriptors: [Int32] = [STDERR_FILENO, STDOUT_FILENO]) -> Bool {
        let log = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard log >= 0 else { return false }
        defer { close(log) }

        var saved: [Int32] = []
        defer { saved.forEach { close($0) } }
        for descriptor in descriptors {
            let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
            guard copy >= 0 else { return false }
            saved.append(copy)
        }
        for (index, descriptor) in descriptors.enumerated() where dup2(log, descriptor) < 0 {
            for (restored, original) in zip(descriptors, saved).prefix(index) { dup2(original, restored) }
            return false
        }
        return true
    }

    /// Rotates an oversized log and points the descriptors at the new file
    /// (they still refer to the moved one). Returns whether it rotated.
    @discardableResult
    static func rotateAndReattach(
        logFile: URL = AppIdentity.logFile(home: FileManager.default.homeDirectoryForCurrentUser),
        maxBytes: Int64 = LogRedirect.maxBytes,
        onto descriptors: [Int32] = [STDERR_FILENO, STDOUT_FILENO]
    ) -> Bool {
        guard rotateIfNeeded(logFile: logFile, maxBytes: maxBytes) else { return false }
        redirect(to: logFile, onto: descriptors)
        return true
    }

    /// Creates the log dir and points stderr and stdout (append) at the log,
    /// line-buffered. Does not rotate (see the type comment). Best-effort:
    /// returns false and leaves stderr as it was if anything fails.
    @discardableResult
    static func install(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: AppIdentity.logDir(home: home), withIntermediateDirectories: true
            )
        } catch {
            return false
        }
        guard redirect(to: AppIdentity.logFile(home: home)) else { return false }
        setvbuf(stderr, nil, _IOLBF, 0)
        setvbuf(stdout, nil, _IOLBF, 0)
        isActive = true
        return true
    }
}
