import Foundation
import Testing
@testable import MeetingVox

/// The playback inputs of a session's detail data (B1): its tracks, read off
/// the main thread with the rest, and the `onDataChanged` seam the player
/// follows.
@MainActor
@Suite final class SessionDetailPlaybackTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-detail-playback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"files": {"mic": "mic.caf", "system": "system.caf"}, "start_offset_ms": {"mic": 0, "system": 300}}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.meta))
        try Data([1]).write(to: dir.appendingPathComponent("mic.caf"))
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    @Test func loadingReadsThePlayableTracksAndSkipsMissingFiles() {
        let data = SessionDetailData.load(dir, .none)
        #expect(data.playbackTracks.map(\.id) == [.mic])
        #expect(data.playbackTracks.first?.url == dir.appendingPathComponent("mic.caf"))
    }

    @Test func aFolderWithoutMetaHasNoTracks() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("meetingvox-nometa-\(UUID().uuidString)")
        #expect(SessionDetailData.load(empty, .none).playbackTracks.isEmpty)
    }

    @Test func onDataChangedFiresWithTheLoadedDataAndWithNilWhenAnotherSessionIsSelected() async {
        let other = dir.appendingPathComponent("other", isDirectory: true)
        let model = SessionDetailModel(load: { dir, _, _ in SessionDetailData(dir: dir) })
        var seen: [URL?] = []
        model.onDataChanged = { seen.append($0?.dir) }
        await model.select(dir).value
        #expect(seen == [dir])
        await model.select(other).value
        #expect(seen == [dir, nil, other])
        await model.select(nil).value
        #expect(seen == [dir, nil, other, nil])
    }

    @Test func reloadingTheSameSessionDoesNotClearItFirst() async {
        let model = SessionDetailModel(load: { dir, _, _ in SessionDetailData(dir: dir) })
        await model.select(dir).value
        var seen: [URL?] = []
        model.onDataChanged = { seen.append($0?.dir) }
        await model.reload().value
        #expect(seen == [dir])
    }
}
