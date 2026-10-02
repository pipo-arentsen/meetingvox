import FluidAudio
import Foundation
import Testing

@testable import MeetingVox

/// The live downloader's pure edges: presence is a filesystem read of the
/// cache layout, FluidAudio's phases map to ours and its wrapped download
/// errors are unwrapped before classification. `download` itself is never
/// called from a test (it would hit the network).
@Suite("FluidAudioModelDownloader")
struct FluidAudioModelDownloaderTests {
    /// FluidAudio resolves presence at `<parent of directory>/<repo folder>`,
    /// so the fake cache uses the real folder name.
    private static let repoFolder = AsrModels.defaultCacheDirectory(for: .ultra).lastPathComponent

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mv-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fill(_ repo: URL, files: [String]) throws {
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for f in files {
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(f), withIntermediateDirectories: true)
        }
    }

    @Test func theDefaultDirectoryIsFluidAudiosUltraCache() {
        #expect(FluidAudioModelDownloader().directory == AsrModels.defaultCacheDirectory(for: .ultra))
    }

    @Test func aMissingOrEmptyCacheIsNotPresent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(Self.repoFolder)
        #expect(FluidAudioModelDownloader(directory: dir).isPresent() == false)
        try fill(dir, files: [])
        #expect(FluidAudioModelDownloader(directory: dir).isPresent() == false)
    }

    @Test func aCacheMissingTheVocabularyIsNotPresent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(Self.repoFolder)
        try fill(dir, files: Array(ModelNames.ASR.requiredModelsV3()))
        #expect(FluidAudioModelDownloader(directory: dir).isPresent() == false)
    }

    @Test func aCompleteCacheIsPresentAndTheCheckWritesNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(Self.repoFolder)
        try fill(dir, files: Array(ModelNames.ASR.requiredModelsV3()) + [ModelNames.ASR.vocabularyFile])
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        #expect(FluidAudioModelDownloader(directory: dir).isPresent())
        #expect(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() == before)
    }

    @Test func phasesMapToOurTwoPhases() {
        #expect(ModelProgress.Phase(.listing) == .descargando)
        #expect(ModelProgress.Phase(.downloading(completedFiles: 1, totalFiles: 4)) == .descargando)
        #expect(ModelProgress.Phase(.compiling(modelName: "Encoder")) == .preparando)
    }

    @Test func aWrappedDownloadErrorIsUnwrappedToItsCause() {
        let cause = URLError(.notConnectedToInternet)
        let wrapped = DownloadError.downloadFailed(path: "Encoder.mlmodelc", underlying: cause)
        let unwrapped = FluidAudioModelDownloader.unwrap(wrapped)
        #expect((unwrapped as? URLError)?.code == .notConnectedToInternet)
        #expect(ModelProvisioner.classify(unwrapped) == .offline)
        // Anything else passes through untouched.
        let plain = URLError(.timedOut)
        #expect((FluidAudioModelDownloader.unwrap(plain) as? URLError)?.code == .timedOut)
    }
}
