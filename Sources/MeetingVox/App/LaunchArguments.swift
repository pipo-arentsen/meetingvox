import Foundation

/// Routing of the process arguments, as pure functions over the whole argv.
///
/// A double-click, `open`, SMAppService and `launchd` start the binary with
/// flags the CLI never declared (`-psn_0_12345`, `-NSDocumentRevisionsDebugMode
/// YES`, `-AppleLanguages (es)`). ArgumentParser would reject them and the app
/// would exit with a usage error instead of running, so they are removed
/// before parsing. What is left (empty, or a real subcommand) goes to the
/// command, whose default subcommand is `run`.
enum LaunchArguments {
    /// The subcommands ArgumentParser knows; a flag without a value must not
    /// swallow one of these.
    static let subcommands: Set<String> = ["run", "doctor", "install", "diag"]

    /// argv[0] is kept as is; everything else is filtered. `-psn_*` is a single
    /// token. `-NS*`/`-Apple*` are flag + value: the next token goes with them
    /// unless it is itself a flag or a subcommand name, so a flag without a
    /// value never swallows `--out` or `doctor`.
    static func sanitize(_ argv: [String]) -> [String] {
        guard let first = argv.first else { return [] }
        var result = [first]
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            index += 1
            if arg.hasPrefix("-psn_") { continue }
            if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
                if index < argv.count, !argv[index].hasPrefix("-"), !subcommands.contains(argv[index]) { index += 1 }
                continue
            }
            result.append(arg)
        }
        return result
    }

    /// True when the arguments end up in the `run` subcommand: none, `run`, or
    /// an option only `run` declares. `--help`/`-h` (of `run` or the root),
    /// `--help` before any subcommand and every other subcommand are not the
    /// run route: they must neither redirect stderr nor take the instance
    /// lock. Takes the raw argv (argv[0] included) and sanitizes it itself, so
    /// callers may pass either the raw or the already sanitized form.
    static func isRunRoute(_ argv: [String]) -> Bool {
        let rest = sanitize(argv).dropFirst()
        if rest.contains("-h") || rest.contains("--help") { return false }
        guard let next = rest.first else { return true }
        return next == "run" || next == "--out" || next.hasPrefix("--out=")
    }

    /// The options of `diag` that take a separate value, so that value is
    /// never mistaken for a mode.
    private static let diagValueOptions: Set<String> = ["--out", "--seconds"]

    /// True for `diag --mode snapshot` (or `--mode=snapshot`): the headless
    /// view renderer. That route must not run the config migration (which
    /// copies `~/.config/quill`), so `MeetingVoxMain` asks before
    /// migrating. Like ArgumentParser, the last `--mode` wins; a value that
    /// belongs to another option (`--out snapshot`) is not a mode. Takes the
    /// raw argv and sanitizes it itself.
    static func isSnapshotRoute(_ argv: [String]) -> Bool {
        let rest = Array(sanitize(argv).dropFirst())
        guard rest.first == "diag" else { return false }
        var mode: String?
        var index = 1
        while index < rest.count {
            let arg = rest[index]
            index += 1
            if arg == "--mode" {
                mode = index < rest.count ? rest[index] : nil
                index += 1
            } else if arg.hasPrefix("--mode=") {
                mode = String(arg.dropFirst("--mode=".count))
            } else if diagValueOptions.contains(arg) {
                index += 1
            }
        }
        return mode == "snapshot"
    }
}
