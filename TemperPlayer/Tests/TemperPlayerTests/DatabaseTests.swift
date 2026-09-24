import Combine
import Foundation
import SQLite3
import XCTest
@testable import TemperPlayer

final class DatabaseTests: XCTestCase {
  private var directory: URL!
  private var databaseURL: URL!
  private var library: Database!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("TemperPlayer-DatabaseTests-\(UUID().uuidString)")
    databaseURL = directory.appendingPathComponent("library.db")
    library = Database(databaseURL: databaseURL)
    XCTAssertNil(library.lastError)
  }

  override func tearDownWithError() throws {
    library = nil
    if let directory { try FileManager.default.removeItem(at: directory) }
  }

  func testUnicodeNullsAndLargeFileSizeRoundTrip() throws {
    var original = track("音楽-🎵-'quote'")
    original.path = directory.appendingPathComponent("Björk/夜の歌 🎶.flac").path
    original.title = "e\u{301} — 東京 🎧 'quoted'\u{0000}tail"
    original.artist = String(repeating: "தமிழ் / Björk / 演奏者 🎻 ", count: 50)
    original.album = "Álbum • 音楽"
    original.albumArtist = "合集"
    original.genre = "実験音楽"
    original.artworkPath = "/art/封面🎨.png"
    original.fileSize = 5_000_000_123
    original.trackNo = nil
    original.discNo = nil
    original.year = nil
    original.dcOffset = 0
    original.lufs = nil
    original.truePeak = nil
    original.dynamicRange = nil
    original.phaseCorrelation = nil
    library.insert(track: original)
    XCTAssertNil(library.lastError)

    let reopened = Database(databaseURL: databaseURL)
    XCTAssertNil(reopened.lastError)
    let saved = try XCTUnwrap(reopened.tracks.first)
    XCTAssertEqual(saved.id, original.id)
    XCTAssertEqual(saved.path, original.path)
    XCTAssertEqual(saved.title, original.title)
    XCTAssertEqual(saved.artist, original.artist)
    XCTAssertEqual(saved.album, original.album)
    XCTAssertEqual(saved.albumArtist, original.albumArtist)
    XCTAssertEqual(saved.genre, original.genre)
    XCTAssertEqual(saved.artworkPath, original.artworkPath)
    XCTAssertEqual(saved.fileSize, original.fileSize)
    XCTAssertEqual(try scalar("SELECT file_size FROM tracks"), 5_000_000_123)
    XCTAssertNil(saved.trackNo)
    XCTAssertNil(saved.discNo)
    XCTAssertNil(saved.year)
    XCTAssertEqual(saved.dcOffset, 0)
    XCTAssertNil(saved.lufs)
    XCTAssertNil(saved.truePeak)
    XCTAssertNil(saved.dynamicRange)
    XCTAssertNil(saved.phaseCorrelation)
    XCTAssertNil(saved.lastPlayed)
  }

  func testReimportPreservesAddedDatePlaybackAndPlaylistMembership() throws {
    var original = track("a")
    original.playCount = 4
    library.insert(track: original)
    let playlist = library.createPlaylist(name: "Favorites")
    XCTAssertTrue(library.addTracksToPlaylist(trackIds: ["a"], playlistId: playlist.id))
    library.recordPlayback(trackId: "a")
    // Existing installations used ISO timestamps without fractional seconds.
    try execute("UPDATE tracks SET date_added = '2020-01-02T03:04:05Z', last_played = '2021-02-03T04:05:06Z'")
    library.loadTracks()
    let before = try XCTUnwrap(library.tracks.first)
    var reimported = track("a")
    reimported.dateAdded = Date()
    reimported.title = "Refreshed metadata"
    reimported.fileSize = 8_000_000_000
    reimported.playCount = 0
    reimported.lastPlayed = nil
    library.insert(track: reimported)
    XCTAssertNil(library.lastError)

    for database in [library!, Database(databaseURL: databaseURL)] {
      let saved = try XCTUnwrap(database.tracks.first)
      XCTAssertEqual(saved.dateAdded, before.dateAdded)
      XCTAssertEqual(saved.lastPlayed, before.lastPlayed)
      XCTAssertEqual(saved.playCount, 5)
      XCTAssertEqual(saved.title, reimported.title)
      XCTAssertEqual(saved.fileSize, reimported.fileSize)
      XCTAssertEqual(database.playlists.first?.tracks, ["a"])
    }
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM play_history WHERE track_id = 'a'"), 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM playlist_tracks"), 1)
  }

  func testMetadataClearingAndBatchUnchangedFieldsPersist() throws {
    library.insert(track: track("a"))
    library.insert(track: track("b"))
    library.selectedTrack = library.tracks.first { $0.id == "a" }
    library.updateTrackMetadata(id: "a", title: nil, artist: "", album: "New album")
    XCTAssertNil(library.lastError)
    XCTAssertNil(library.selectedTrack?.title)
    XCTAssertNil(library.selectedTrack?.artist)
    XCTAssertEqual(try scalar("SELECT title IS NULL AND artist IS NULL FROM tracks WHERE id = 'a'"), 1)

    library.batchUpdateTrackMetadata(ids: ["a", "b"], title: nil, artist: "歌手 🎤", album: "")
    XCTAssertNil(library.lastError)
    let beforeNoOp = try snapshot()
    library.batchUpdateTrackMetadata(ids: ["a", "b"], title: nil, artist: nil, album: nil)
    XCTAssertEqual(try snapshot(), beforeNoOp)
    for database in [library!, Database(databaseURL: databaseURL)] {
      let first = try XCTUnwrap(database.tracks.first { $0.id == "a" })
      let second = try XCTUnwrap(database.tracks.first { $0.id == "b" })
      XCTAssertNil(first.title)
      XCTAssertEqual(second.title, "Title b")
      XCTAssertEqual(first.artist, "歌手 🎤")
      XCTAssertEqual(second.artist, "歌手 🎤")
      XCTAssertNil(first.album)
      XCTAssertNil(second.album)
    }
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tracks WHERE album IS NULL"), 2)
  }

  func testDeletingMultipleTracksCascadesAndReindexesWithoutDeletingFiles() throws {
    for id in ["a", "b", "c", "d"] {
      let item = track(id)
      try Data("audio fixture".utf8).write(to: URL(fileURLWithPath: item.path))
      library.insert(track: item)
      library.recordPlayback(trackId: id)
    }
    let first = library.createPlaylist(name: "First")
    let second = library.createPlaylist(name: "Second")
    XCTAssertTrue(library.addTracksToPlaylist(trackIds: ["a", "b", "c", "d"], playlistId: first.id))
    XCTAssertTrue(library.addTracksToPlaylist(trackIds: ["d", "c", "b", "a"], playlistId: second.id))
    let previousModified = try agePlaylists()
    library.selectedTrack = library.tracks.first { $0.id == "b" }

    XCTAssertTrue(library.deleteTracks(ids: ["b", "d"]))
    XCTAssertNil(library.lastError)
    XCTAssertNil(library.selectedTrack)
    XCTAssertEqual(Set(library.tracks.map(\.id)), ["a", "c"])
    XCTAssertEqual(library.tracksForPlaylist(first.id).map(\.id), ["a", "c"])
    XCTAssertEqual(library.tracksForPlaylist(second.id).map(\.id), ["c", "a"])
    for playlist in library.playlists {
      XCTAssertGreaterThan(playlist.modified, previousModified)
      XCTAssertEqual(try integers("SELECT position FROM playlist_tracks WHERE playlist_id = '\(playlist.id)' ORDER BY position"), [0, 1])
    }
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM play_history"), 2)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM playlist_tracks"), 4)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: track("b").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: track("d").path))
    let reopened = Database(databaseURL: databaseURL)
    XCTAssertEqual(Set(reopened.tracks.map(\.id)), ["a", "c"])
    XCTAssertEqual(reopened.tracksForPlaylist(second.id).map(\.id), ["c", "a"])
  }

  func testFailedMultiTrackDeleteRollsBackHistoryMembershipAndPublishedState() throws {
    for id in ["a", "b", "c"] {
      library.insert(track: track(id))
      library.recordPlayback(trackId: id)
    }
    let playlist = library.createPlaylist(name: "Keep intact")
    XCTAssertTrue(library.addTracksToPlaylist(trackIds: ["a", "b", "c"], playlistId: playlist.id))
    library.selectedTrack = library.tracks.first { $0.id == "a" }
    let before = try snapshot()
    try execute("""
      CREATE TRIGGER fail_delete BEFORE DELETE ON tracks WHEN OLD.id = 'b'
      BEGIN SELECT RAISE(ABORT, 'injected deletion failure'); END;
      """)
    var trackPublications = 0
    var playlistPublications = 0
    let tracksSubscription = library.$tracks.dropFirst().sink { _ in trackPublications += 1 }
    let playlistsSubscription = library.$playlists.dropFirst().sink { _ in playlistPublications += 1 }
    defer { tracksSubscription.cancel(); playlistsSubscription.cancel() }

    XCTAssertFalse(library.deleteTracks(ids: ["a", "b"]))
    XCTAssertNotNil(library.lastError)
    XCTAssertEqual(try snapshot(), before)
    XCTAssertEqual(trackPublications, 0)
    XCTAssertEqual(playlistPublications, 0)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tracks"), 3)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM play_history"), 3)
    XCTAssertEqual(try integers("SELECT position FROM playlist_tracks ORDER BY position"), [0, 1, 2])
    try execute("DROP TRIGGER fail_delete")
    XCTAssertTrue(library.deleteTracks(ids: ["a", "b"]))
    XCTAssertNil(library.lastError)
    XCTAssertEqual(library.playlists.first?.tracks, ["c"])
  }

  func testPlaylistOrderDeduplicationAndModifiedTimestamps() throws {
    for id in ["a", "b", "c", "d"] { library.insert(track: track(id)) }
    let playlist = library.createPlaylist(name: "  夜の音楽 🎶  ")
    XCTAssertEqual(playlist.name, "夜の音楽 🎶")
    XCTAssertEqual(library.playlists.first?.id, playlist.id)
    var previousModified = try agePlaylists()
    XCTAssertTrue(library.addTracksToPlaylist(trackIds: ["c", "a", "c", "b"], playlistId: playlist.id))
    XCTAssertEqual(library.playlists.first?.tracks, ["c", "a", "b"])
    XCTAssertGreaterThan(try XCTUnwrap(library.playlists.first).modified, previousModified)
    XCTAssertTrue(library.addTracksToPlaylist(trackIds: ["a", "d", "d"], playlistId: playlist.id))
    XCTAssertEqual(library.tracksForPlaylist(playlist.id).map(\.id), ["c", "a", "b", "d"])

    previousModified = try agePlaylists()
    library.moveTrackInPlaylist(playlistId: playlist.id, trackId: "d", by: Int.min)
    XCTAssertNil(library.lastError)
    XCTAssertEqual(library.playlists.first?.tracks, ["d", "c", "a", "b"])
    XCTAssertGreaterThan(try XCTUnwrap(library.playlists.first).modified, previousModified)
    library.moveTrackInPlaylist(playlistId: playlist.id, trackId: "d", by: Int.max)
    XCTAssertEqual(library.playlists.first?.tracks, ["c", "a", "b", "d"])

    previousModified = try agePlaylists()
    XCTAssertTrue(library.removeTracksFromPlaylist(trackIds: ["a", "d"], playlistId: playlist.id))
    XCTAssertEqual(library.playlists.first?.tracks, ["c", "b"])
    XCTAssertEqual(try integers("SELECT position FROM playlist_tracks ORDER BY position"), [0, 1])
    XCTAssertGreaterThan(try XCTUnwrap(library.playlists.first).modified, previousModified)
    previousModified = try agePlaylists()
    library.renamePlaylist(id: playlist.id, name: "  新しい名前  ")
    XCTAssertNil(library.lastError)
    XCTAssertEqual(library.playlists.first?.name, "新しい名前")
    XCTAssertGreaterThan(try XCTUnwrap(library.playlists.first).modified, previousModified)
    previousModified = try agePlaylists()
    library.clearPlaylist(id: playlist.id)
    XCTAssertNil(library.lastError)
    XCTAssertEqual(library.playlists.first?.tracks, [])
    XCTAssertGreaterThan(try XCTUnwrap(library.playlists.first).modified, previousModified)
    XCTAssertEqual(library.tracks.count, 4)
  }

  func testAddingMissingTrackOrPlaylistDoesNotPartiallyAppend() throws {
    for id in ["a", "b"] { library.insert(track: track(id)) }
    let playlist = library.createPlaylist(name: "Atomic append")
    XCTAssertTrue(library.addTracksToPlaylist(trackIds: ["a"], playlistId: playlist.id))
    let before = try snapshot()
    XCTAssertFalse(library.addTracksToPlaylist(trackIds: ["b", "missing"], playlistId: playlist.id))
    XCTAssertNotNil(library.lastError)
    XCTAssertEqual(try snapshot(), before)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM playlist_tracks"), 1)
    XCTAssertFalse(library.addTracksToPlaylist(trackIds: ["b"], playlistId: "missing"))
    XCTAssertNotNil(library.lastError)
    XCTAssertEqual(try snapshot(), before)
    XCTAssertTrue(library.addTracksToPlaylist(trackIds: ["b"], playlistId: playlist.id))
    XCTAssertNil(library.lastError)
    XCTAssertEqual(library.playlists.first?.tracks, ["a", "b"])
  }

  func testReindexFailureRollsBackRemovalAndReordering() throws {
    for id in ["a", "b", "c"] { library.insert(track: track(id)) }
    let playlist = library.createPlaylist(name: "Atomic order")
    XCTAssertTrue(library.addTracksToPlaylist(trackIds: ["a", "b", "c"], playlistId: playlist.id))
    let before = try snapshot()
    try execute("""
      CREATE TRIGGER fail_reindex BEFORE UPDATE OF position ON playlist_tracks WHEN OLD.track_id = 'c'
      BEGIN SELECT RAISE(ABORT, 'injected reindex failure'); END;
      """)
    XCTAssertFalse(library.removeTracksFromPlaylist(trackIds: ["b"], playlistId: playlist.id))
    XCTAssertNotNil(library.lastError)
    XCTAssertEqual(try snapshot(), before)
    XCTAssertFalse(library.deleteTracks(ids: ["b"]))
    XCTAssertNotNil(library.lastError)
    XCTAssertEqual(try snapshot(), before)
    library.moveTrackInPlaylist(playlistId: playlist.id, trackId: "a", by: 2)
    XCTAssertNotNil(library.lastError)
    XCTAssertEqual(try snapshot(), before)
    XCTAssertEqual(try integers("SELECT position FROM playlist_tracks ORDER BY track_id"), [0, 1, 2])
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tracks"), 3)
  }

  func testPlaylistCreationDeletionAndClearFailuresDoNotPublishOrLoseMemberships() throws {
    library.insert(track: track("a"))
    let playlist = library.createPlaylist(name: "Existing")
    XCTAssertTrue(library.addTracksToPlaylist(trackIds: ["a"], playlistId: playlist.id))
    let before = try snapshot()
    try execute("""
      CREATE TRIGGER fail_create BEFORE INSERT ON playlists
      BEGIN SELECT RAISE(ABORT, 'injected creation failure'); END;
      CREATE TRIGGER fail_playlist_delete BEFORE DELETE ON playlists
      BEGIN SELECT RAISE(ABORT, 'injected playlist deletion failure'); END;
      CREATE TRIGGER fail_touch BEFORE UPDATE ON playlists
      BEGIN SELECT RAISE(ABORT, 'injected timestamp failure'); END;
      """)
    let unsaved = library.createPlaylist(name: "Cannot save")
    XCTAssertNotNil(library.lastError)
    XCTAssertFalse(library.playlists.contains { $0.id == unsaved.id })
    XCTAssertEqual(try snapshot(), before)
    library.deletePlaylist(id: playlist.id)
    XCTAssertNotNil(library.lastError)
    XCTAssertEqual(try snapshot(), before)
    library.clearPlaylist(id: playlist.id)
    XCTAssertNotNil(library.lastError)
    XCTAssertEqual(try snapshot(), before)
    library.renamePlaylist(id: playlist.id, name: "Cannot rename")
    XCTAssertNotNil(library.lastError)
    XCTAssertEqual(try snapshot(), before)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM playlist_tracks"), 1)
    try execute("DROP TRIGGER fail_playlist_delete")
    library.deletePlaylist(id: playlist.id)
    XCTAssertNil(library.lastError)
    XCTAssertTrue(library.playlists.isEmpty)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM playlist_tracks"), 0)
    XCTAssertEqual(library.tracks.count, 1)
  }

  func testMetadataBatchFailureRollsBackAllTracks() throws {
    for id in ["a", "b"] { library.insert(track: track(id)) }
    let before = try snapshot()
    try execute("""
      CREATE TRIGGER fail_metadata BEFORE UPDATE OF title ON tracks WHEN OLD.id = 'b'
      BEGIN SELECT RAISE(ABORT, 'injected metadata failure'); END;
      """)
    library.batchUpdateTrackMetadata(ids: ["a", "b"], title: "changed", artist: "", album: nil)
    XCTAssertNotNil(library.lastError)
    XCTAssertEqual(try snapshot(), before)
    let reopened = Database(databaseURL: databaseURL)
    XCTAssertEqual(reopened.tracks.first { $0.id == "a" }?.title, "Title a")
    XCTAssertEqual(reopened.tracks.first { $0.id == "a" }?.artist, "Artist a")
    library.updateTrackMetadata(id: "b", title: nil, artist: nil, album: nil)
    XCTAssertNotNil(library.lastError)
    XCTAssertEqual(try snapshot(), before)
    try execute("DROP TRIGGER fail_metadata")
    library.batchUpdateTrackMetadata(ids: ["a", "b"], title: "", artist: nil, album: nil)
    XCTAssertNil(library.lastError)
    XCTAssertTrue(library.tracks.allSatisfy { $0.title == nil })
  }

  func testPlaybackFailureRollsBackHistoryAndCount() throws {
    library.insert(track: track("a"))
    let before = try snapshot()
    try execute("""
      CREATE TRIGGER fail_playback BEFORE UPDATE OF play_count ON tracks
      BEGIN SELECT RAISE(ABORT, 'injected playback failure'); END;
      """)
    library.recordPlayback(trackId: "a")
    let failure = try XCTUnwrap(library.lastError)
    XCTAssertEqual(try snapshot(), before)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM play_history"), 0)
    try execute("DROP TRIGGER fail_playback")
    library.recordPlayback(trackId: "a")
    XCTAssertEqual(library.lastError, failure)
    XCTAssertEqual(library.tracks.first?.playCount, 1)
    XCTAssertNotNil(library.tracks.first?.lastPlayed)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM play_history"), 1)
  }

  func testCommitFailureRollsBackAndDoesNotPublishInsertedTrack() throws {
    try execute("""
      CREATE TABLE deferred_guard (track_id TEXT REFERENCES tracks(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER fail_commit AFTER INSERT ON tracks WHEN NEW.id = 'a'
      BEGIN INSERT INTO deferred_guard (track_id) VALUES ('missing'); END;
      """)
    var publications = 0
    let subscription = library.$tracks.dropFirst().sink { _ in publications += 1 }
    defer { subscription.cancel() }
    library.insert(track: track("a"))
    XCTAssertNotNil(library.lastError)
    XCTAssertTrue(library.tracks.isEmpty)
    XCTAssertEqual(publications, 0)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tracks"), 0)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM deferred_guard"), 0)
    try execute("DROP TRIGGER fail_commit")
    library.insert(track: track("a"))
    XCTAssertNil(library.lastError)
    XCTAssertEqual(library.tracks.count, 1)
  }

  func testFailedReadRetainsPreviouslyPublishedTracks() throws {
    library.insert(track: track("a"))
    let before = try snapshot()
    try execute("ALTER TABLE tracks RENAME TO unavailable_tracks")
    library.loadTracks()
    let failure = try XCTUnwrap(library.lastError)
    XCTAssertEqual(try snapshot(), before)
    try execute("ALTER TABLE unavailable_tracks RENAME TO tracks")
    library.loadTracks()
    XCTAssertEqual(library.lastError, failure)
    XCTAssertEqual(try snapshot(), before)
    library.lastError = nil
    library.loadTracks()
    XCTAssertNil(library.lastError)
  }

  func testSuccessfulReadsAndPlaybackDoNotDismissMutationErrors() throws {
    library.insert(track: track("a"))
    try execute("""
      CREATE TRIGGER fail_metadata BEFORE UPDATE OF title ON tracks
      BEGIN SELECT RAISE(ABORT, 'injected metadata failure'); END;
      """)
    library.updateTrackMetadata(id: "a", title: "Cannot save", artist: nil, album: nil)
    let failure = try XCTUnwrap(library.lastError)
    library.loadTracks()
    XCTAssertEqual(library.lastError, failure)
    library.loadPlaylists()
    XCTAssertEqual(library.lastError, failure)
    library.recordPlayback(trackId: "a")
    XCTAssertEqual(library.lastError, failure)
    XCTAssertEqual(library.tracks.first?.playCount, 1)
    try execute("DROP TRIGGER fail_metadata")
    library.updateTrackMetadata(id: "a", title: "Saved", artist: nil, album: nil)
    XCTAssertNil(library.lastError)
    XCTAssertEqual(library.tracks.first?.title, "Saved")
  }

  func testInvalidDatabaseLocationReportsFailureWithoutPublishingDrafts() throws {
    let invalid = Database(databaseURL: directory)
    XCTAssertNotNil(invalid.lastError)
    invalid.insert(track: track("a"))
    XCTAssertNotNil(invalid.lastError)
    XCTAssertTrue(invalid.tracks.isEmpty)
    _ = invalid.createPlaylist(name: "Not saved")
    XCTAssertNotNil(invalid.lastError)
    XCTAssertTrue(invalid.playlists.isEmpty)
    XCTAssertFalse(invalid.deleteTracks(ids: ["a"]))
  }

  // MARK: - Isolated fixtures and direct persistence assertions

  private func track(_ id: String) -> Track {
    Track(id: id, path: directory.appendingPathComponent("\(id).flac").path,
          title: "Title \(id)", artist: "Artist \(id)", album: "Album \(id)", albumArtist: nil,
          trackNo: 1, discNo: 1, year: 2024, genre: nil, duration: 123.5,
          format: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 2, bitrate: 2_000_000,
          fileSize: 123_456, dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
          lastPlayed: nil, playCount: 0, artworkPath: nil, dcOffset: nil,
          lufs: nil, truePeak: nil, dynamicRange: nil, phaseCorrelation: nil)
  }

  private struct Snapshot: Encodable {
    let tracks: [Track]
    let playlists: [Playlist]
    let selectedTrack: Track?
  }

  private func snapshot() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    // Track.== intentionally compares only IDs, so compare the complete encoded state.
    return try encoder.encode(Snapshot(tracks: library.tracks, playlists: library.playlists, selectedTrack: library.selectedTrack))
  }

  private func agePlaylists() throws -> Date {
    try execute("UPDATE playlists SET modified = '2000-01-01T00:00:00Z'")
    library.loadPlaylists()
    XCTAssertNil(library.lastError)
    return try XCTUnwrap(library.playlists.first).modified
  }

  private func withConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    var handle: OpaquePointer?
    let result = sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    defer { sqlite3_close(handle) }
    guard result == SQLITE_OK, let handle else { throw sqlError(handle) }
    guard sqlite3_exec(handle, "PRAGMA foreign_keys=ON", nil, nil, nil) == SQLITE_OK else { throw sqlError(handle) }
    return try body(handle)
  }

  private func execute(_ sql: String) throws {
    try withConnection { handle in
      guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw sqlError(handle) }
    }
  }

  private func integers(_ sql: String) throws -> [Int64] {
    try withConnection { handle in
      var statement: OpaquePointer?
      let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
      defer { sqlite3_finalize(statement) }
      guard result == SQLITE_OK else { throw sqlError(handle) }
      var values: [Int64] = []
      while true {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: values.append(sqlite3_column_int64(statement, 0))
        case SQLITE_DONE: return values
        default: throw sqlError(handle)
        }
      }
    }
  }

  private func scalar(_ sql: String) throws -> Int64 {
    try XCTUnwrap(integers(sql).first)
  }

  private func sqlError(_ handle: OpaquePointer?) -> NSError {
    let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "No SQLite connection"
    return NSError(domain: "DatabaseTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
