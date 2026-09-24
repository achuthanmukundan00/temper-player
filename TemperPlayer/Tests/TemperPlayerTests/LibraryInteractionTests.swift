import XCTest
@testable import TemperPlayer

final class LibraryInteractionTests: XCTestCase {
    private func track(_ id: String) -> Track {
        Track(id: id, path: "/Music/\(id).wav", duration: 60, format: "wav", sampleRate: 44100,
              bitDepth: 16, channels: 2, bitrate: 1411, fileSize: 1024, dateAdded: Date(), playCount: 0)
    }

    @MainActor func testNewPresentationCannotReplacePlaylistSelectionOrOpenSiblingSheet() {
        let actions = LibraryActions()
        actions.requestPlaylist([track("a")])
        actions.requestPlaylist([])
        actions.presentManager()
        actions.presentQueue()
        actions.requestRemoval([track("a")])
        XCTAssertEqual(actions.playlistTracks.map(\.id), ["a"])
        XCTAssertTrue(actions.isCreatingPlaylist)
        XCTAssertFalse(actions.showingManager)
        XCTAssertFalse(actions.showingQueue)
        XCTAssertFalse(actions.isConfirmingRemoval)
        actions.isCreatingPlaylist = false
        actions.presentManager()
        XCTAssertTrue(actions.showingManager)
    }

    func testChangingVisibleTracksPrunesHiddenSelectionEvenWhenPrimaryRemains() {
        let state = PlayerState()
        let a = track("a"), b = track("b"), c = track("c")
        state.setVisibleTracks([a, b, c])
        state.selectedTrackId = a.id
        state.selectedTrackIds = [a.id, b.id, c.id]
        state.setVisibleTracks([a, b])
        XCTAssertEqual(state.selectedTrackId, a.id)
        XCTAssertEqual(state.selectedTrackIds, [a.id, b.id])
        state.setVisibleTracks([])
        XCTAssertNil(state.selectedTrackId)
        XCTAssertTrue(state.selectedTrackIds.isEmpty)
    }

    func testArrowSelectionCollapsesPreviousGroup() {
        let state = PlayerState()
        state.setVisibleTracks([track("a"), track("b"), track("c")])
        state.selectedTrackId = "a"
        state.selectedTrackIds = ["a", "b", "c"]
        state.selectVisibleTrack(offset: 1)
        XCTAssertEqual(state.selectedTrackId, "b")
        XCTAssertEqual(state.selectedTrackIds, ["b"])
    }

    func testCreatePlaylistWithTracksIsAtomicAndDeduplicatesInOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = Database(databaseURL: directory.appendingPathComponent("library.db"))
        database.insert(track: track("a"))
        database.insert(track: track("b"))
        let failed = database.createPlaylist(name: "Failed", trackIds: ["a", "missing", "b"])
        XCTAssertNotNil(database.lastError)
        XCTAssertFalse(database.playlists.contains { $0.id == failed.id })
        let saved = database.createPlaylist(name: "Saved", trackIds: ["b", "a", "b"])
        XCTAssertNil(database.lastError)
        XCTAssertEqual(saved.tracks, ["b", "a"])
        database.loadPlaylists()
        XCTAssertEqual(database.playlists.count, 1)
        XCTAssertEqual(database.playlists.first?.tracks, ["b", "a"])
    }
}
