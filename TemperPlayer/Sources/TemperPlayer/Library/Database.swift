import Combine
import Foundation
import SQLite3
import os

class Database: ObservableObject {
  private static let logger = Logger(subsystem: "com.temperplayer", category: "database")
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  private var db: OpaquePointer?
  private let iso = ISO8601DateFormatter()
  private let legacyISO = ISO8601DateFormatter()

  @Published var tracks: [Track] = []
  @Published var selectedTrack: Track?
  @Published var playlists: [Playlist] = []
  @Published var lastError: String?

  init(databaseURL: URL? = nil) {
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let opened = perform("Open library") {
      let url = databaseURL ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".temperplayer/library.db")
      guard url.isFileURL else { throw DatabaseError("The database URL must be a local file.") }
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
        let error = sqliteError("Open database")
        if let db { sqlite3_close(db) }
        db = nil
        throw error
      }
      guard sqlite3_busy_timeout(db, 3_000) == SQLITE_OK else { throw sqliteError("Set busy timeout") }
      try executeSQL("PRAGMA journal_mode=WAL")
      try executeSQL("PRAGMA foreign_keys=ON")
      let loaded = try transaction {
        try createSchema()
        return (try fetchTracks(), try fetchPlaylists())
      }
      tracks = loaded.0
      playlists = loaded.1
    }
    if !opened {
      if let db { sqlite3_close(db) }
      db = nil
    }
  }

  private func createSchema() throws {
    try executeSQL("""
      CREATE TABLE IF NOT EXISTS tracks (
          id              TEXT PRIMARY KEY,
          path            TEXT NOT NULL,
          title           TEXT,
          artist          TEXT,
          album           TEXT,
          album_artist    TEXT,
          track_no        INTEGER,
          disc_no         INTEGER,
          year            INTEGER,
          genre           TEXT,
          duration        REAL,
          format          TEXT,
          sample_rate     INTEGER,
          bit_depth       INTEGER,
          channels        INTEGER,
          bitrate         INTEGER,
          file_size       INTEGER,
          date_added      TEXT NOT NULL,
          last_played     TEXT,
          play_count      INTEGER DEFAULT 0,
          artwork_path    TEXT,
          dc_offset       REAL,
          lufs            REAL,
          true_peak       REAL,
          dynamic_range   REAL,
          phase_correlation REAL
      );
      CREATE TABLE IF NOT EXISTS playlists (
          id          TEXT PRIMARY KEY,
          name        TEXT NOT NULL,
          description TEXT,
          created     TEXT NOT NULL,
          modified    TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS playlist_tracks (
          playlist_id TEXT NOT NULL,
          track_id    TEXT NOT NULL,
          position    INTEGER NOT NULL,
          PRIMARY KEY (playlist_id, track_id),
          FOREIGN KEY (playlist_id) REFERENCES playlists(id),
          FOREIGN KEY (track_id) REFERENCES tracks(id)
      );
      CREATE TABLE IF NOT EXISTS play_history (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          track_id  TEXT NOT NULL,
          played_at TEXT NOT NULL,
          FOREIGN KEY (track_id) REFERENCES tracks(id)
      );
      CREATE INDEX IF NOT EXISTS idx_tracks_artist ON tracks(artist);
      CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album);
      CREATE INDEX IF NOT EXISTS idx_tracks_date_added ON tracks(date_added);
      CREATE INDEX IF NOT EXISTS idx_play_history_played_at ON play_history(played_at);
      CREATE INDEX IF NOT EXISTS idx_playlist_tracks_position ON playlist_tracks(playlist_id, position);
      """)
  }

  func insert(track: Track) {
    perform("Save track") {
      let saved = try transaction {
        // Updating the existing row keeps its history and playlist foreign keys intact.
        try execute("""
          INSERT INTO tracks
          (id, path, title, artist, album, album_artist, track_no, disc_no, year, genre,
           duration, format, sample_rate, bit_depth, channels, bitrate, file_size, date_added,
           last_played, play_count, artwork_path, dc_offset, lufs, true_peak, dynamic_range, phase_correlation)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
          ON CONFLICT(id) DO UPDATE SET
            path = excluded.path, title = excluded.title, artist = excluded.artist,
            album = excluded.album, album_artist = excluded.album_artist,
            track_no = excluded.track_no, disc_no = excluded.disc_no, year = excluded.year,
            genre = excluded.genre, duration = excluded.duration, format = excluded.format,
            sample_rate = excluded.sample_rate, bit_depth = excluded.bit_depth,
            channels = excluded.channels, bitrate = excluded.bitrate, file_size = excluded.file_size,
            artwork_path = excluded.artwork_path, dc_offset = excluded.dc_offset,
            lufs = excluded.lufs, true_peak = excluded.true_peak,
            dynamic_range = excluded.dynamic_range, phase_correlation = excluded.phase_correlation
          """, [
            .text(track.id), .text(track.path), .text(track.title), .text(track.artist),
            .text(track.album), .text(track.albumArtist), .integer(track.trackNo),
            .integer(track.discNo), .integer(track.year), .text(track.genre), .real(track.duration),
            .text(track.format), .integer(track.sampleRate), .integer(track.bitDepth),
            .integer(track.channels), .integer(track.bitrate), .integer(track.fileSize),
            .text(iso.string(from: track.dateAdded)), .text(track.lastPlayed.map { iso.string(from: $0) }),
            .integer(track.playCount), .text(track.artworkPath), .real(track.dcOffset),
            .real(track.lufs), .real(track.truePeak), .real(track.dynamicRange), .real(track.phaseCorrelation),
          ])
        return try fetchTrack(id: track.id)
      }
      publishTracks([saved])
    }
  }

  func loadTracks() {
    perform("Load tracks", clearErrorOnSuccess: false) {
      let loaded = try fetchTracks()
      tracks = loaded
      if let selectedTrack { self.selectedTrack = loaded.first { $0.id == selectedTrack.id } }
    }
  }

  func deleteTrack(id: String) {
    deleteTracks(ids: [id])
  }

  /// Removes only library records, never the audio files on disk.
  @discardableResult
  func deleteTracks(ids: Set<String>) -> Bool {
    perform("Remove tracks") {
      guard !ids.isEmpty else { return }
      let updatedPlaylists = try transaction {
        var affectedPlaylists = Set<String>()
        for id in ids.sorted() {
          let memberships: [String] = try query(
            "SELECT playlist_id FROM playlist_tracks WHERE track_id = ?", [.text(id)]
          ) { self.string($0, 0)! }
          affectedPlaylists.formUnion(memberships)
          // Explicit cascades also work with the schema used by existing libraries.
          try execute("DELETE FROM play_history WHERE track_id = ?", [.text(id)])
          try execute("DELETE FROM playlist_tracks WHERE track_id = ?", [.text(id)])
          try execute("DELETE FROM tracks WHERE id = ?", [.text(id)])
        }
        for playlistId in affectedPlaylists.sorted() {
          try reindexPlaylist(playlistId: playlistId)
          try touchPlaylist(id: playlistId)
        }
        return try fetchPlaylists()
      }
      tracks.removeAll { ids.contains($0.id) }
      if let selectedTrack, ids.contains(selectedTrack.id) { self.selectedTrack = nil }
      playlists = updatedPlaylists
    }
  }

  /// Replaces all three fields; nil and empty strings both clear a field.
  func updateTrackMetadata(id: String, title: String?, artist: String?, album: String?) {
    perform("Update track metadata") {
      let updated = try transaction {
        try execute("UPDATE tracks SET title = ?, artist = ?, album = ? WHERE id = ?", [
          .text(metadataValue(title)), .text(metadataValue(artist)), .text(metadataValue(album)), .text(id),
        ])
        return try fetchTrack(id: id)
      }
      publishTracks([updated])
    }
  }

  /// In a batch nil leaves a field unchanged; an empty string explicitly clears it.
  func batchUpdateTrackMetadata(ids: [String], title: String?, artist: String?, album: String?) {
    perform("Update track metadata") {
      let columns: [(String, String?)] = [("title", title), ("artist", artist), ("album", album)]
      let active = columns.filter { $0.1 != nil }
      guard !ids.isEmpty, !active.isEmpty else { return }
      // Column names come only from the fixed list above, never user input.
      let sql = "UPDATE tracks SET " + active.map { "\($0.0) = ?" }.joined(separator: ", ") + " WHERE id = ?"
      let values = active.map { Value.text(metadataValue($0.1)) }
      let updated = try transaction {
        try ids.map { id in
          try execute(sql, values + [.text(id)])
          return try fetchTrack(id: id)
        }
      }
      publishTracks(updated)
    }
  }

  func recordPlayback(trackId: String) {
    perform("Record playback", clearErrorOnSuccess: false) {
      let updated = try transaction {
        let now = iso.string(from: Date())
        try execute("INSERT INTO play_history (track_id, played_at) VALUES (?,?)", [.text(trackId), .text(now)])
        try execute("UPDATE tracks SET last_played = ?, play_count = play_count + 1 WHERE id = ?", [.text(now), .text(trackId)])
        return try fetchTrack(id: trackId)
      }
      publishTracks([updated])
    }
  }

  // MARK: - Playlists

  func loadPlaylists() {
    perform("Load playlists", clearErrorOnSuccess: false) { playlists = try fetchPlaylists() }
  }

  /// Kept source-compatible: the returned draft is saved only when lastError is nil.
  func createPlaylist(name: String, trackIds: [String] = []) -> Playlist {
    let now = Date()
    let playlist = Playlist(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            description: nil, created: now, modified: now, tracks: [])
    mutatePlaylists("Create playlist") {
      guard !playlist.name.isEmpty else { throw DatabaseError("A playlist name cannot be empty.") }
      let timestamp = iso.string(from: now)
      try execute("INSERT INTO playlists (id, name, created, modified) VALUES (?,?,?,?)", [
        .text(playlist.id), .text(playlist.name), .text(timestamp), .text(timestamp),
      ])
      var added = Set<String>()
      for trackId in trackIds where added.insert(trackId).inserted {
        try execute("INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?,?,?)", [
          .text(playlist.id), .text(trackId), .integer(added.count - 1),
        ])
      }
    }
    return playlists.first { $0.id == playlist.id } ?? playlist
  }

  func deletePlaylist(id: String) {
    mutatePlaylists("Delete playlist") {
      try execute("DELETE FROM playlist_tracks WHERE playlist_id = ?", [.text(id)])
      try execute("DELETE FROM playlists WHERE id = ?", [.text(id)])
    }
  }

  func renamePlaylist(id: String, name: String) {
    mutatePlaylists("Rename playlist") {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw DatabaseError("A playlist name cannot be empty.") }
      try requirePlaylist(id: id)
      try execute("UPDATE playlists SET name = ?, modified = ? WHERE id = ?", [
        .text(trimmed), .text(iso.string(from: Date())), .text(id),
      ])
    }
  }

  func addTrackToPlaylist(trackId: String, playlistId: String) {
    addTracksToPlaylist(trackIds: [trackId], playlistId: playlistId)
  }

  @discardableResult
  func addTracksToPlaylist(trackIds: [String], playlistId: String) -> Bool {
    mutatePlaylists("Add tracks to playlist") {
      try requirePlaylist(id: playlistId)
      var ids = try trackIdsForPlaylist(playlistId: playlistId)
      var existing = Set(ids)
      let originalCount = ids.count
      for trackId in trackIds where existing.insert(trackId).inserted {
        try execute("INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?,?,?)", [
          .text(playlistId), .text(trackId), .integer(ids.count),
        ])
        ids.append(trackId)
      }
      if ids.count != originalCount {
        try updatePlaylistOrder(playlistId: playlistId, trackIds: ids)
        try touchPlaylist(id: playlistId)
      }
    }
  }

  func removeTrackFromPlaylist(trackId: String, playlistId: String) {
    removeTracksFromPlaylist(trackIds: [trackId], playlistId: playlistId)
  }

  @discardableResult
  func removeTracksFromPlaylist(trackIds: Set<String>, playlistId: String) -> Bool {
    mutatePlaylists("Remove tracks from playlist") {
      try requirePlaylist(id: playlistId)
      let existing = try trackIdsForPlaylist(playlistId: playlistId)
      let removed = existing.filter { trackIds.contains($0) }
      for trackId in removed {
        try execute("DELETE FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?", [.text(playlistId), .text(trackId)])
      }
      if !removed.isEmpty {
        try reindexPlaylist(playlistId: playlistId)
        try touchPlaylist(id: playlistId)
      }
    }
  }

  func clearPlaylist(id: String) {
    mutatePlaylists("Clear playlist") {
      try requirePlaylist(id: id)
      try execute("DELETE FROM playlist_tracks WHERE playlist_id = ?", [.text(id)])
      try touchPlaylist(id: id)
    }
  }

  func moveTrackInPlaylist(playlistId: String, trackId: String, by offset: Int) {
    mutatePlaylists("Reorder playlist") {
      try requirePlaylist(id: playlistId)
      var ids = try trackIdsForPlaylist(playlistId: playlistId)
      guard let index = ids.firstIndex(of: trackId) else { throw DatabaseError("The track is not in this playlist.") }
      let distance = max(-index, min(ids.count - 1 - index, offset))
      guard distance != 0 else { return }
      ids.remove(at: index)
      ids.insert(trackId, at: index + distance)
      try updatePlaylistOrder(playlistId: playlistId, trackIds: ids)
      try touchPlaylist(id: playlistId)
    }
  }

  func tracksForPlaylist(_ playlistId: String) -> [Track] {
    let byId = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    return playlists.first { $0.id == playlistId }?.tracks.compactMap { byId[$0] } ?? []
  }

  @discardableResult
  private func mutatePlaylists(_ operation: String, _ body: () throws -> Void) -> Bool {
    perform(operation) {
      let updated = try transaction {
        try body()
        return try fetchPlaylists()
      }
      playlists = updated
    }
  }

  private func requirePlaylist(id: String) throws {
    let ids: [String] = try query("SELECT id FROM playlists WHERE id = ?", [.text(id)]) { self.string($0, 0)! }
    guard !ids.isEmpty else { throw DatabaseError("The playlist no longer exists.") }
  }

  private func touchPlaylist(id: String) throws {
    try execute("UPDATE playlists SET modified = ? WHERE id = ?", [.text(iso.string(from: Date())), .text(id)])
  }

  private func reindexPlaylist(playlistId: String) throws {
    try updatePlaylistOrder(playlistId: playlistId, trackIds: trackIdsForPlaylist(playlistId: playlistId))
  }

  private func updatePlaylistOrder(playlistId: String, trackIds: [String]) throws {
    for (position, trackId) in trackIds.enumerated() {
      try execute("UPDATE playlist_tracks SET position = ? WHERE playlist_id = ? AND track_id = ?", [
        .integer(position), .text(playlistId), .text(trackId),
      ])
    }
  }

  // MARK: - Reading and publishing

  private func fetchTracks() throws -> [Track] {
    try query("SELECT * FROM tracks ORDER BY date_added DESC, id ASC") { self.readTrack($0) }
  }

  private func fetchTrack(id: String) throws -> Track {
    let found = try query("SELECT * FROM tracks WHERE id = ?", [.text(id)]) { self.readTrack($0) }
    guard let track = found.first else { throw DatabaseError("The track no longer exists.") }
    return track
  }

  private func readTrack(_ stmt: OpaquePointer) -> Track {
    Track(
      id: string(stmt, 0)!, path: string(stmt, 1)!, title: string(stmt, 2), artist: string(stmt, 3),
      album: string(stmt, 4), albumArtist: string(stmt, 5), trackNo: integer(stmt, 6),
      discNo: integer(stmt, 7), year: integer(stmt, 8), genre: string(stmt, 9),
      duration: sqlite3_column_double(stmt, 10), format: string(stmt, 11) ?? "",
      sampleRate: Int(sqlite3_column_int64(stmt, 12)), bitDepth: Int(sqlite3_column_int64(stmt, 13)),
      channels: Int(sqlite3_column_int64(stmt, 14)), bitrate: Int(sqlite3_column_int64(stmt, 15)),
      fileSize: Int(sqlite3_column_int64(stmt, 16)), dateAdded: date(string(stmt, 17)) ?? .distantPast,
      lastPlayed: date(string(stmt, 18)), playCount: Int(sqlite3_column_int64(stmt, 19)),
      artworkPath: string(stmt, 20), dcOffset: real(stmt, 21), lufs: real(stmt, 22),
      truePeak: real(stmt, 23), dynamicRange: real(stmt, 24), phaseCorrelation: real(stmt, 25)
    )
  }

  private func fetchPlaylists() throws -> [Playlist] {
    try query("SELECT id, name, description, created, modified FROM playlists ORDER BY name ASC, id ASC") { stmt in
      let id = self.string(stmt, 0)!
      return Playlist(id: id, name: self.string(stmt, 1)!, description: self.string(stmt, 2),
                      created: self.date(self.string(stmt, 3)) ?? .distantPast,
                      modified: self.date(self.string(stmt, 4)) ?? .distantPast,
                      tracks: try self.trackIdsForPlaylist(playlistId: id))
    }
  }

  private func trackIdsForPlaylist(playlistId: String) throws -> [String] {
    try query("SELECT track_id FROM playlist_tracks WHERE playlist_id = ? ORDER BY position ASC, track_id ASC", [.text(playlistId)]) {
      self.string($0, 0)!
    }
  }

  private func publishTracks(_ updated: [Track]) {
    var remaining = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    var result = tracks.map { remaining.removeValue(forKey: $0.id) ?? $0 }
    // Metadata/playback updates do not change the import order; sort only new inserts.
    if !remaining.isEmpty {
      result.append(contentsOf: remaining.values)
      result.sort { $0.dateAdded == $1.dateAdded ? $0.id < $1.id : $0.dateAdded > $1.dateAdded }
    }
    tracks = result
    if let selectedTrack { self.selectedTrack = result.first { $0.id == selectedTrack.id } }
  }

  private func metadataValue(_ value: String?) -> String? {
    value?.isEmpty == false ? value : nil
  }

  private func date(_ value: String?) -> Date? {
    value.flatMap { iso.date(from: $0) ?? legacyISO.date(from: $0) }
  }

  private func string(_ stmt: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
          let bytes = sqlite3_column_text(stmt, index) else { return nil }
    return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(stmt, index))), as: UTF8.self)
  }

  private func integer(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
    sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, index))
  }

  private func real(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
    sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
  }

  // MARK: - Checked SQLite operations

  private struct DatabaseError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }

  private enum Value {
    case text(String?)
    case integer(Int?)
    case real(Double?)
  }

  @discardableResult
  private func perform(_ operation: String, clearErrorOnSuccess: Bool = true, _ body: () throws -> Void) -> Bool {
    do {
      try body()
      // Background playback and refreshes must not dismiss an outstanding UI error.
      if clearErrorOnSuccess { lastError = nil }
      return true
    } catch {
      let message = "\(operation): \(error.localizedDescription)"
      Self.logger.error("\(message)")
      lastError = message
      return false
    }
  }

  private func sqliteError(_ operation: String) -> DatabaseError {
    let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is not open."
    return DatabaseError("\(operation): \(detail)")
  }

  private func executeSQL(_ sql: String) throws {
    guard let db else { throw sqliteError("Execute SQL") }
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(db, sql, nil, nil, &message)
    defer { sqlite3_free(message) }
    guard result == SQLITE_OK else {
      throw DatabaseError(message.map { String(cString: $0) } ?? sqliteError("Execute SQL").message)
    }
  }

  private func withStatement<T>(_ sql: String, _ values: [Value], _ body: (OpaquePointer) throws -> T) throws -> T {
    guard let db else { throw sqliteError("Prepare SQL") }
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    guard result == SQLITE_OK, let statement else { throw sqliteError("Prepare SQL") }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case .text(let text?):
        let bytes = text.utf8CString
        guard let count = Int32(exactly: bytes.count - 1) else { throw DatabaseError("Text exceeds SQLite's size limit.") }
        result = bytes.withUnsafeBufferPointer {
          sqlite3_bind_text(statement, index, $0.baseAddress, count, Self.transient)
        }
      case .integer(let number?):
        result = sqlite3_bind_int64(statement, index, Int64(number))
      case .real(let number?):
        result = sqlite3_bind_double(statement, index, number)
      default:
        result = sqlite3_bind_null(statement, index)
      }
      guard result == SQLITE_OK else { throw sqliteError("Bind SQL value") }
    }
    return try body(statement)
  }

  private func execute(_ sql: String, _ values: [Value] = []) throws {
    try withStatement(sql, values) { statement in
      guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError("Write SQL") }
    }
  }

  private func query<T>(_ sql: String, _ values: [Value] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
    try withStatement(sql, values) { statement in
      var rows: [T] = []
      while true {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: rows.append(try row(statement))
        case SQLITE_DONE: return rows
        default: throw sqliteError("Read SQL")
        }
      }
    }
  }

  private func transaction<T>(_ body: () throws -> T) throws -> T {
    try executeSQL("BEGIN IMMEDIATE TRANSACTION")
    do {
      let result = try body()
      try executeSQL("COMMIT")
      return result
    } catch {
      // A failed COMMIT still owns a transaction; a RAISE(ROLLBACK) trigger may not.
      if sqlite3_get_autocommit(db) == 0 {
        do {
          try executeSQL("ROLLBACK")
        } catch let rollbackError {
          throw DatabaseError("\(error.localizedDescription); rollback failed: \(rollbackError.localizedDescription)")
        }
      }
      throw error
    }
  }

  deinit {
    if let db { sqlite3_close(db) }
  }
}
