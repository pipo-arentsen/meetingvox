import FluidAudio
import Foundation

/// The live `ModelDownloader`: Parakeet Ultra through FluidAudio. Presence is
/// FluidAudio's own file check on its cache layout (read-only: it writes and
/// deletes nothing); `download` fetches the same files `downloadAndLoad`
/// would, without loading them.
struct FluidAudioModelDownloader: ModelDownloader {
    let directory: URL

    init(directory: URL = AsrModels.defaultCacheDirectory(for: .ultra)) {
        self.directory = directory
    }

    func isPresent() -> Bool {
        AsrModels.modelsExist(at: directory, version: .ultra)
    }

    func download(progress: @escaping @Sendable (Double, ModelProgress.Phase) -> Void) async throws {
        do {
            try await AsrModels.download(to: directory, version: .ultra) { p in
                progress(p.fractionCompleted, ModelProgress.Phase(p.phase))
            }
        } catch {
            throw Self.unwrap(error)
        }
    }

    /// FluidAudio wraps the transport error in `DownloadError.downloadFailed`;
    /// a connectivity cause is surfaced so it classifies as offline. Other
    /// errors keep their own (more informative) description.
    static func unwrap(_ error: Error) -> Error {
        if case DownloadError.downloadFailed(_, let underlying) = error,
            ModelProvisioner.classify(underlying) == .offline
        {
            return underlying
        }
        return error
    }
}

extension ModelProgress.Phase {
    init(_ phase: DownloadPhase) {
        switch phase {
        case .listing, .downloading: self = .descargando
        case .compiling: self = .preparando
        }
    }
}
