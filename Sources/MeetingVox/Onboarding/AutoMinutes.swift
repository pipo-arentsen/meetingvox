import Foundation

/// Automatic minutes need something to call: an OpenRouter key and a model.
/// Pure, so the Listo step's toggle rule is tested without a window.
enum AutoMinutes {
    /// What is missing, so the step can say where to fix it.
    enum Requirement: Equatable {
        /// A key only under the legacy service: migrate it first.
        case migrateKey
        case keyAndModel
    }

    /// Needs a key under MeetingVox's own service (`.primary`) and a
    /// non-blank model. A legacy-only key does not count: the first
    /// automatic job would read it and raise the Keychain prompt with nobody
    /// looking; "Migrar clave" in Minutas is where that prompt is explained.
    static func allowed(presence: KeyPresence, model: String?) -> Bool {
        presence == .primary && !(model ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Nil when automatic minutes are allowed.
    static func requirement(presence: KeyPresence, model: String?) -> Requirement? {
        if allowed(presence: presence, model: model) { return nil }
        return presence == .legacyOnly ? .migrateKey : .keyAndModel
    }

    /// Whether the toggle can be operated. Turning it off is always possible,
    /// so a config left on by hand without a key can still be undone.
    static func toggleEnabled(presence: KeyPresence, model: String?, isOn: Bool) -> Bool {
        isOn || allowed(presence: presence, model: model)
    }
}

/// The recordings root is resolved once at launch, so a folder chosen in the
/// Listo step only applies after a restart (no automatic relaunch).
enum RecordingsFolderNote {
    /// True when the saved folder is not the one the app is running with.
    static func needsRestart(runningRoot: URL, configured: String) -> Bool {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let saved = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
        return saved.standardizedFileURL.path != runningRoot.standardizedFileURL.path
    }
}

/// Whether a folder chosen for the recordings can be used at all. Pure over
/// the file system's answers, so the Listo step and Ajustes share it.
enum RecordingsFolderCheck {
    /// Nil when fine, else the Spanish reason.
    static func problem(_ url: URL, bundleURL: URL, fileManager: FileManager = .default) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return Textos.Ajustes.carpetaNoValida
        }
        if isInsideBundle(url, bundleURL: bundleURL) { return Textos.Ajustes.carpetaDentroDeLaApp }
        guard fileManager.isWritableFile(atPath: url.path) else { return Textos.Ajustes.carpetaNoEscribible }
        return nil
    }

    /// Inside an `.app` bundle only (a build directory is not one). Compares
    /// whole path components so `MeetingVox.app-datos` is not "inside".
    static func isInsideBundle(_ url: URL, bundleURL: URL) -> Bool {
        let bundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard bundle.pathExtension == "app" else { return false }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == bundle.path || path.hasPrefix(bundle.path + "/")
    }
}
