import Foundation
import XCTest
@testable import TemperPlayer

final class PlayerStateTests: XCTestCase {
    func testEmptyQueueStaysEmptyAcrossShuffleAndRepeatAll() {
        let state = PlayerState()
        state.repeatMode = .all

        for _ in 0..<8 {
            state.toggleShuffle()
            XCTAssertNil(state.advanceToNext())
            XCTAssertNil(state.playQueueItem(at: 0))
            state.removeQueueItem(at: 0)
            state.moveQueueItem(from: 0, to: 1)
            XCTAssertTrue(state.queue.isEmpty)
            XCTAssertTrue(state.upcomingQueue.isEmpty)
            XCTAssertFalse(state.hasPreviousTrack)
            XCTAssertFalse(state.hasNextTrack)
            assertStopped(state)
        }
    }

    func testRemovingLastCurrentItemClearsPlaybackAndCannotResurrectIt() {
        for shuffled in [false, true] {
            let state = prepared([track("a")])
            state.isPlaying = true
            state.currentTime = 17
            state.repeatMode = .all
            if shuffled { state.toggleShuffle() }

            state.removeQueueItem(at: 0)

            XCTAssertTrue(state.queue.isEmpty)
            XCTAssertEqual(state.queueTitle, "Queue")
            assertStopped(state)
            XCTAssertNil(state.advanceToNext())
            if shuffled { state.toggleShuffle() }
            state.enqueue(track("b"))
            XCTAssertEqual(state.queue.map(\.id), ["b"])
            assertStopped(state)
        }
    }

    func testRemovingCurrentItemDoesNotSelectOrAutoplayAnotherSong() {
        for playing in [false, true] {
            let state = prepared([track("a"), track("b"), track("c")], index: 1)
            state.isPlaying = playing
            state.currentTime = 30
            state.toggleShuffle()

            state.removeQueueItem(at: 1)

            XCTAssertEqual(state.queue.map(\.id), ["a", "c"])
            XCTAssertEqual(state.upcomingQueue.map(\.id), ["a", "c"])
            assertStopped(state)
            state.toggleShuffle()
            XCTAssertEqual(state.queue.map(\.id), ["a", "c"])
            assertStopped(state)
        }
    }

    func testRemovingOtherItemsKeepsCurrentPositionAndPlayback() {
        let state = prepared([track("a"), track("b"), track("c"), track("d")], index: 2)
        state.isPlaying = true
        state.currentTime = 35
        state.toggleShuffle()

        state.removeQueueItem(at: 0)
        state.removeQueueItem(at: 2)
        state.toggleShuffle()

        XCTAssertEqual(state.queue.map(\.id), ["b", "c"])
        XCTAssertEqual(state.queueIndex, 1)
        XCTAssertEqual(state.currentTrack?.id, "c")
        XCTAssertEqual(state.currentTime, 35)
        XCTAssertEqual(state.duration, 120)
        XCTAssertTrue(state.isPlaying)
    }

    func testRemovingDuplicateOccurrenceDoesNotRemoveCurrentOccurrence() {
        let first = track("a", title: "first")
        let second = track("a", title: "second")
        let state = prepared([first, track("b"), second, track("c")], index: 2)
        state.isPlaying = true
        state.currentTime = 18
        state.toggleShuffle()

        state.removeQueueItem(at: 0)
        state.toggleShuffle()

        XCTAssertEqual(state.queue.map(\.title), ["b", "second", "c"])
        XCTAssertEqual(state.queueIndex, 1)
        XCTAssertEqual(state.currentTrack?.title, "second")
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.currentTime, 18)
    }

    func testUnshufflePreservesCurrentDuplicateOccurrence() throws {
        let tracks = [track("a", title: "first"), track("b"), track("a", title: "second"), track("c")]
        for chooseAfterShuffle in [false, true] {
            let state = prepared(tracks, index: chooseAfterShuffle ? 0 : 2)
            state.toggleShuffle()
            if chooseAfterShuffle {
                let index = try XCTUnwrap(state.queue.firstIndex { $0.title == "second" })
                _ = state.playQueueItem(at: index)
            }
            state.currentTime = 23
            state.toggleShuffle()

            XCTAssertEqual(state.queue.map(\.title), tracks.map(\.title))
            XCTAssertEqual(state.queueIndex, 2)
            XCTAssertEqual(state.currentTrack?.title, "second")
            XCTAssertEqual(state.currentTime, 23)
        }
    }

    func testShuffledEnqueuesSurviveUnshuffleIncludingDuplicates() {
        let state = prepared([track("a"), track("b"), track("c")])
        state.toggleShuffle()

        state.enqueue(track("d"))
        state.enqueue([track("a", title: "new occurrence"), track("e")])
        state.toggleShuffle()

        XCTAssertEqual(state.queue.map(\.title), ["a", "b", "c", "d", "new occurrence", "e"])
        XCTAssertEqual(state.queueIndex, 0)
    }

    func testShuffledEnqueueNextUsesCurrentOccurrenceInBothOrders() throws {
        let state = prepared([track("a", title: "first"), track("b"), track("a", title: "second"), track("c")])
        state.toggleShuffle()
        let currentIndex = try XCTUnwrap(state.queue.firstIndex { $0.title == "second" })
        _ = state.playQueueItem(at: currentIndex)

        state.enqueueNext(track("x"))
        state.enqueueNext(track("y"))
        XCTAssertEqual(Array(state.upcomingQueue.prefix(2)).map(\.id), ["y", "x"])
        state.toggleShuffle()

        XCTAssertEqual(state.queue.map(\.title), ["first", "b", "second", "y", "x", "c"])
        XCTAssertEqual(state.queueIndex, 2)
        XCTAssertEqual(state.currentTrack?.title, "second")
    }

    func testUnstartedShuffledQueueDoesNotInventACurrentItem() {
        let state = PlayerState()
        state.enqueue([track("a"), track("b"), track("c")])
        state.toggleShuffle()
        state.enqueueNext(track("next"))
        state.toggleShuffle()

        XCTAssertEqual(state.queue.map(\.id), ["next", "a", "b", "c"])
        assertStopped(state)
        XCTAssertTrue(state.hasNextTrack)
        XCTAssertEqual(state.advanceToNext()?.id, "next")
        XCTAssertEqual(state.queueIndex, 0)
        XCTAssertFalse(state.isPlaying)
    }

    func testShuffledMovesPreserveOccurrencesAndCurrentItemInBothOrders() throws {
        let tracks = [track("a", title: "first"), track("b"), track("a", title: "second"), track("c"), track("d")]
        // Exercise forward/backward moves, moving the current occurrence, and
        // moving other occurrences across it. Assertions do not depend on RNG.
        for source in tracks.indices {
            for destination in tracks.indices where source != destination {
                let state = prepared(tracks)
                state.toggleShuffle()
                let currentIndex = try XCTUnwrap(state.queue.firstIndex { $0.title == "second" })
                _ = state.playQueueItem(at: currentIndex)
                state.isPlaying = true
                state.currentTime = 29
                let movedTitle = state.queue[source].title
                let targetTitle = state.queue[destination].title
                var expected = tracks
                let originalSource = try XCTUnwrap(expected.firstIndex { $0.title == movedTitle })
                let movedTrack = expected.remove(at: originalSource)
                let target = try XCTUnwrap(expected.firstIndex { $0.title == targetTitle })
                expected.insert(movedTrack, at: target + (source < destination ? 1 : 0))

                state.moveQueueItem(from: source, to: destination)
                XCTAssertEqual(state.queue[destination].title, movedTitle)
                let shuffledCurrent = try XCTUnwrap(state.queueIndex)
                XCTAssertEqual(state.queue[shuffledCurrent].title, "second")
                state.toggleShuffle()

                XCTAssertEqual(state.queue.map(\.title), expected.map(\.title))
                XCTAssertEqual(state.queueIndex, expected.firstIndex { $0.title == "second" })
                XCTAssertEqual(state.currentTrack?.title, "second")
                XCTAssertEqual(state.currentTime, 29)
                XCTAssertTrue(state.isPlaying)
            }
        }
    }

    func testClearShuffledQueueKeepsOnlyCurrentDuplicateOccurrence() {
        let state = prepared([track("a", title: "first"), track("b"), track("a", title: "second"), track("c")], index: 2)
        state.isPlaying = true
        state.currentTime = 14
        state.toggleShuffle()

        state.clearUpcomingQueue()
        state.enqueue(track("new"))
        state.toggleShuffle()

        XCTAssertEqual(state.queue.map(\.title), ["second", "new"])
        XCTAssertEqual(state.queueIndex, 0)
        XCTAssertEqual(state.currentTrack?.title, "second")
        XCTAssertEqual(state.currentTime, 14)
        XCTAssertTrue(state.isPlaying)
    }

    func testClearingUnstartedShuffledQueueAlsoClearsSavedOrder() {
        let state = PlayerState()
        state.enqueue([track("a"), track("b")])
        state.toggleShuffle()

        state.clearUpcomingQueue()
        XCTAssertTrue(state.queue.isEmpty)
        assertStopped(state)
        state.enqueue(track("new"))
        state.toggleShuffle()

        XCTAssertEqual(state.queue.map(\.id), ["new"])
        assertStopped(state)
    }

    func testEmptyShuffledQueueAcceptsEditsWithoutLosingNewItems() {
        let state = PlayerState()
        state.toggleShuffle()
        state.enqueue(track("a"))
        state.enqueueNext(track("b"))
        state.enqueue([track("c"), track("d")])
        state.removeQueueItem(at: 1)
        state.toggleShuffle()

        XCTAssertEqual(state.queue.map(\.id), ["b", "c", "d"])
        assertStopped(state)
    }

    func testShuffledRepeatAllWrapPreservesCurrentOccurrenceOnUnshuffle() {
        let tracks = [track("a", title: "first"), track("b"), track("a", title: "second"), track("c")]
        for _ in 0..<20 {
            let state = prepared(tracks)
            state.repeatMode = .all
            state.toggleShuffle()
            _ = state.playQueueItem(at: state.queue.count - 1)

            let wrapped = state.advanceToNext()
            XCTAssertEqual(state.queueIndex, 0)
            XCTAssertEqual(state.currentTrack?.title, wrapped?.title)
            state.toggleShuffle()

            XCTAssertEqual(state.queue.map(\.title), tracks.map(\.title))
            XCTAssertEqual(state.queueIndex, tracks.firstIndex { $0.title == wrapped?.title })
        }
    }

    func testFailureScanCanWrapWithoutReshuffling() {
        let state = prepared([track("a", title: "first"), track("a", title: "second"), track("b"), track("c")])
        state.repeatMode = .all
        state.toggleShuffle()
        let order = state.queue.map(\.title)
        _ = state.playQueueItem(at: state.queue.count - 1)

        for index in state.queue.indices {
            XCTAssertEqual(state.advanceToNext(reshuffleOnRepeat: false)?.title, order[index])
            XCTAssertEqual(state.queueIndex, index)
        }
        XCTAssertEqual(state.queue.map(\.title), order)
    }

    func testLibraryDeletionRemovesAllOccurrencesAndSelectionWithoutAutoplay() {
        let state = prepared([track("a"), track("b"), track("a"), track("c"), track("d")], index: 2)
        state.setVisibleTracks([track("a"), track("b"), track("c"), track("d")])
        state.selectedTrackId = "a"
        state.selectedTrackIds = ["a", "b", "c", "d"]
        state.isPlaying = true
        state.currentTime = 40
        state.toggleShuffle()

        state.removeTracks(ids: ["a", "b"])

        assertStopped(state)
        XCTAssertEqual(Set(state.queue.map(\.id)), ["c", "d"])
        XCTAssertEqual(state.visibleTracks.map(\.id), ["c", "d"])
        XCTAssertEqual(state.selectedTrackId, "c")
        XCTAssertEqual(state.selectedTrackIds, ["c", "d"])
        state.toggleShuffle()
        XCTAssertEqual(state.queue.map(\.id), ["c", "d"])
        assertStopped(state)
    }

    func testLibraryDeletionPreservesSurvivingCurrentOccurrenceAndPlayback() {
        let state = prepared([track("a"), track("b"), track("a"), track("c"), track("d"), track("b")], index: 3)
        state.isPlaying = true
        state.currentTime = 50
        state.selectedTrackId = "c"
        state.selectedTrackIds = ["a", "c", "d"]
        state.toggleShuffle()

        state.removeTracks(ids: ["a", "b"])
        state.toggleShuffle()

        XCTAssertEqual(state.queue.map(\.id), ["c", "d"])
        XCTAssertEqual(state.queueIndex, 0)
        XCTAssertEqual(state.currentTrack?.id, "c")
        XCTAssertEqual(state.currentTime, 50)
        XCTAssertEqual(state.duration, 120)
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.selectedTrackId, "c")
        XCTAssertEqual(state.selectedTrackIds, ["c", "d"])
    }

    func testDeletingEntireLibraryClearsAllStateAndSavedQueue() {
        let state = prepared([track("a"), track("b"), track("a")])
        state.setVisibleTracks([track("a"), track("b")])
        state.selectedTrackIds = ["a", "b"]
        state.isPlaying = true
        state.toggleShuffle()

        state.removeTracks(ids: ["a", "b"])
        state.toggleShuffle()

        XCTAssertTrue(state.queue.isEmpty)
        XCTAssertTrue(state.visibleTracks.isEmpty)
        XCTAssertTrue(state.selectedTrackIds.isEmpty)
        XCTAssertNil(state.selectedTrackId)
        assertStopped(state)
        XCTAssertNil(state.advanceToNext())
    }

    func testDeletingCurrentSnapshotWithoutAQueueAlsoClearsPlayback() {
        let state = PlayerState()
        state.currentTrack = track("a")
        state.isPlaying = true
        state.currentTime = 20
        state.duration = 120

        state.removeTracks(ids: ["a"])

        assertStopped(state)
        XCTAssertNil(state.advanceToNext())
    }

    func testEmptyAndUnknownLibraryDeletionsAreNoOps() {
        let state = prepared([track("a"), track("b")])
        state.setVisibleTracks(state.queue)
        state.isPlaying = true
        state.currentTime = 7
        state.toggleShuffle()
        state.removeTracks(ids: [])
        state.removeTracks(ids: ["unknown"])
        state.toggleShuffle()

        XCTAssertEqual(state.queue.map(\.id), ["a", "b"])
        XCTAssertEqual(state.visibleTracks.map(\.id), ["a", "b"])
        XCTAssertEqual(state.selectedTrackId, "a")
        XCTAssertEqual(state.selectedTrackIds, ["a"])
        XCTAssertEqual(state.queueIndex, 0)
        XCTAssertEqual(state.currentTime, 7)
        XCTAssertTrue(state.isPlaying)
    }

    func testReconciliationUpdatesEverySnapshotWithoutChangingPlaybackOrMembership() {
        let state = prepared([track("a"), track("b"), track("a"), track("c")], index: 2)
        state.setVisibleTracks([track("a"), track("c")])
        state.selectedTrackIds = ["a", "c"]
        state.isPlaying = true
        state.currentTime = 48
        state.duration = 125
        state.toggleShuffle()
        var updated = track("a", title: "Edited title")
        updated.artist = "Edited artist"
        updated.duration = 999

        state.reconcileLibraryTracks([updated, track("new library item")])

        XCTAssertEqual(state.currentTrack?.title, "Edited title")
        XCTAssertEqual(state.currentTrack?.artist, "Edited artist")
        XCTAssertEqual(state.queue.filter { $0.id == "a" }.map(\.title), ["Edited title", "Edited title"])
        XCTAssertEqual(state.visibleTracks.first?.title, "Edited title")
        XCTAssertEqual(state.visibleTracks.map(\.id), ["a", "c"])
        XCTAssertEqual(state.selectedTrackIds, ["a", "c"])
        XCTAssertEqual(state.selectedTrackId, "a")
        XCTAssertEqual(state.currentTime, 48)
        XCTAssertEqual(state.duration, 125)
        XCTAssertTrue(state.isPlaying)
        state.toggleShuffle()
        XCTAssertEqual(state.queue.map(\.title), ["Edited title", "b", "Edited title", "c"])
        XCTAssertEqual(state.queueIndex, 2)
    }

    func testEmptyReconciliationIsNotADeletion() {
        let state = prepared([track("a"), track("b")])
        state.setVisibleTracks(state.queue)
        state.isPlaying = true
        state.currentTime = 9
        state.toggleShuffle()
        state.reconcileLibraryTracks([])
        state.toggleShuffle()

        XCTAssertEqual(state.queue.map(\.id), ["a", "b"])
        XCTAssertEqual(state.visibleTracks.map(\.id), ["a", "b"])
        XCTAssertEqual(state.currentTrack?.id, "a")
        XCTAssertEqual(state.queueIndex, 0)
        XCTAssertEqual(state.currentTime, 9)
        XCTAssertTrue(state.isPlaying)
    }

    func testPreparingAnotherContextWhileShuffledReplacesSavedOrder() {
        let state = prepared([track("old"), track("older")])
        state.toggleShuffle()
        let newTracks = [track("a"), track("b"), track("c")]
        state.prepareToPlay(track: newTracks[1], context: newTracks, title: "New queue")
        state.toggleShuffle()

        XCTAssertEqual(state.queue.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(state.queueIndex, 1)
        XCTAssertEqual(state.currentTrack?.id, "b")
        XCTAssertEqual(state.queueTitle, "New queue")
    }

    func testPreparingTrackOutsideContextInsertsItAtFront() {
        let state = PlayerState()
        state.toggleShuffle()
        state.prepareToPlay(track: track("a"), context: [track("b"), track("c")], title: "Context")
        state.toggleShuffle()

        XCTAssertEqual(state.queue.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(state.queueIndex, 0)
        XCTAssertEqual(state.currentTrack?.id, "a")
        XCTAssertEqual(state.currentTime, 0)
    }

    func testFinishingQueueKeepsCurrentOccurrenceAvailableForReplay() {
        let state = prepared([track("a"), track("b"), track("a", title: "second")], index: 2)
        state.isPlaying = true
        state.finishCurrentTrack()

        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.currentTime, state.duration)
        XCTAssertEqual(state.currentTrack?.title, "second")
        XCTAssertEqual(state.queueIndex, 2)
        XCTAssertNil(state.advanceToNext())
        XCTAssertEqual(state.playQueueItem(at: 2)?.title, "second")
        XCTAssertEqual(state.currentTime, 0)
    }

    private func prepared(_ tracks: [Track], index: Int = 0) -> PlayerState {
        let state = PlayerState()
        state.prepareToPlay(track: tracks[0], context: tracks, title: "Test queue")
        _ = state.playQueueItem(at: index)
        return state
    }

    private func assertStopped(_ state: PlayerState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(state.currentTrack, file: file, line: line)
        XCTAssertNil(state.queueIndex, file: file, line: line)
        XCTAssertFalse(state.isPlaying, file: file, line: line)
        XCTAssertEqual(state.currentTime, 0, file: file, line: line)
        XCTAssertEqual(state.duration, 0, file: file, line: line)
    }

    private func track(_ id: String, title: String? = nil) -> Track {
        Track(
            id: id, path: "/test/\(id).wav", title: title ?? id,
            artist: nil, album: nil, albumArtist: nil, trackNo: nil,
            discNo: nil, year: nil, genre: nil, duration: 120, format: "wav",
            sampleRate: 44_100, bitDepth: 16, channels: 2, bitrate: 1_411,
            fileSize: 1_000, dateAdded: Date(timeIntervalSince1970: 0),
            lastPlayed: nil, playCount: 0, artworkPath: nil, dcOffset: nil,
            lufs: nil, truePeak: nil, dynamicRange: nil, phaseCorrelation: nil
        )
    }
}
