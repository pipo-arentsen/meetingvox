import Foundation

/// `~/.config/meetingvox/onboarding.json`: `{"version": 1, "completed_at": ISO 8601}`.
///
/// Written only by "Empezar", so closing the window any other way leaves it
/// unwritten and the window returns at the next launch. Deleting the file
/// re-shows onboarding. Home is a parameter of `AppIdentity.onboardingMarkerFile`
/// and the URL a parameter here, so tests never touch the real config dir.
enum OnboardingMarker {
    /// What reading the marker found.
    enum State: Equatable {
        case missing
        /// Present but unreadable: not JSON, not an object, or no integer `version`.
        case malformed
        case valid(version: Int)
    }

    /// A file that can't be read at all (permissions, a directory in its
    /// place) reads as `.missing`, not `.malformed`: either way the window
    /// shows again, and only readable-but-wrong content is called malformed.
    static func read(at url: URL) -> State {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = integer(json["version"])
        else { return .malformed }
        return .valid(version: version)
    }

    /// Sets `version` and `completed_at`, keeping every other key of an
    /// existing object (a later build may add keys this one doesn't know).
    /// An existing file that isn't a JSON object is replaced: unlike
    /// `config.json` it holds nothing worth protecting, and refusing would
    /// leave "Empezar" unable to finish. Symlinks are resolved first so an
    /// atomic write doesn't detach a dotfiles link. Throws when the parent
    /// can't be created or written; the caller (the "Empezar" path) decides
    /// what to tell the user.
    static func write(version: Int, at url: URL, now: Date = Date()) throws {
        let target = url.resolvingSymlinksInPath()
        var json = (try? Data(contentsOf: target))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        json["version"] = version
        json["completed_at"] = ISO8601DateFormatter().string(from: now)
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try (data + Data("\n".utf8)).write(to: target, options: .atomic)
    }

    /// A JSON integer, not a boolean (`true` bridges to an `NSNumber` too)
    /// and not a fraction.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded()
        else { return nil }
        return number.intValue
    }
}
