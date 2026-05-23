import Foundation
import SQLite3

class Database: ObservableObject {
  private var db: OpaquePointer?

  @Published var tracks: [Track] = []
  @Published var selectedTrack: Track?
  @Published var playlists: [Playlist] = []

  init() {
    open()
    createSchema()
    loadTracks()
    loadPlaylists()
  }

  private func open() {
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".temperplayer")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let path = dir.appendingPathComponent("library.db").path
    sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
  }

  private func createSchema() {
    let sql = """
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
      """
    _ = sqlite3_exec(db, sql, nil, nil, nil)
  }

  func insert(track: Track) {
    let insert = """
      INSERT OR REPLACE INTO tracks
      (id, path, title, artist, album, album_artist, track_no, disc_no, year, genre,
       duration, format, sample_rate, bit_depth, channels, bitrate, file_size, date_added,
       artwork_path, dc_offset, lufs, true_peak, dynamic_range, phase_correlation)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      """
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, insert, -1, &stmt, nil)

    let iso = ISO8601DateFormatter()

    sqlite3_bind_text(stmt, 1, (track.id as NSString).utf8String, -1, nil)
    sqlite3_bind_text(stmt, 2, (track.path as NSString).utf8String, -1, nil)
    sqlite3_bind_text(stmt, 3, (track.title as NSString?)?.utf8String, -1, nil)
    sqlite3_bind_text(stmt, 4, (track.artist as NSString?)?.utf8String, -1, nil)
    sqlite3_bind_text(stmt, 5, (track.album as NSString?)?.utf8String, -1, nil)
    sqlite3_bind_text(stmt, 6, (track.albumArtist as NSString?)?.utf8String, -1, nil)
    sqlite3_bind_int(stmt, 7, Int32(track.trackNo ?? 0))
    sqlite3_bind_int(stmt, 8, Int32(track.discNo ?? 0))
    sqlite3_bind_int(stmt, 9, Int32(track.year ?? 0))
    sqlite3_bind_text(stmt, 10, (track.genre as NSString?)?.utf8String, -1, nil)
    sqlite3_bind_double(stmt, 11, track.duration)
    sqlite3_bind_text(stmt, 12, (track.format as NSString).utf8String, -1, nil)
    sqlite3_bind_int(stmt, 13, Int32(track.sampleRate))
    sqlite3_bind_int(stmt, 14, Int32(track.bitDepth))
    sqlite3_bind_int(stmt, 15, Int32(track.channels))
    sqlite3_bind_int(stmt, 16, Int32(track.bitrate))
    sqlite3_bind_int(stmt, 17, Int32(track.fileSize))
    sqlite3_bind_text(stmt, 18, (iso.string(from: track.dateAdded) as NSString).utf8String, -1, nil)
    sqlite3_bind_text(stmt, 19, (track.artworkPath as NSString?)?.utf8String, -1, nil)
    sqlite3_bind_double(stmt, 20, track.dcOffset ?? 0)
    sqlite3_bind_double(stmt, 21, track.lufs ?? 0)
    sqlite3_bind_double(stmt, 22, track.truePeak ?? 0)
    sqlite3_bind_double(stmt, 23, track.dynamicRange ?? 0)
    sqlite3_bind_double(stmt, 24, track.phaseCorrelation ?? 0)

    sqlite3_step(stmt)
    sqlite3_finalize(stmt)
    loadTracks()
  }

  func loadTracks() {
    var results: [Track] = []
    let sql = "SELECT * FROM tracks ORDER BY date_added DESC"
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &stmt, nil)

    let iso = ISO8601DateFormatter()

    while sqlite3_step(stmt) == SQLITE_ROW {
      let id = String(cString: sqlite3_column_text(stmt, 0))
      let path = String(cString: sqlite3_column_text(stmt, 1))
      let title = optStr(stmt, 2)
      let artist = optStr(stmt, 3)
      let album = optStr(stmt, 4)
      let albumArtist = optStr(stmt, 5)
      let trackNo = optInt(stmt, 6)
      let discNo = optInt(stmt, 7)
      let year = optInt(stmt, 8)
      let genre = optStr(stmt, 9)
      let duration = sqlite3_column_double(stmt, 10)
      let format = optStr(stmt, 11) ?? ""
      let sampleRate = Int(sqlite3_column_int(stmt, 12))
      let bitDepth = Int(sqlite3_column_int(stmt, 13))
      let channels = Int(sqlite3_column_int(stmt, 14))
      let bitrate = Int(sqlite3_column_int(stmt, 15))
      let fileSize = Int(sqlite3_column_int(stmt, 16))
      let dateStr = String(cString: sqlite3_column_text(stmt, 17))
      let dateAdded = iso.date(from: dateStr) ?? Date()
      let lastPlayedStr = optStr(stmt, 18)
      let lastPlayed: Date? = lastPlayedStr.flatMap { iso.date(from: $0) }
      let playCount = Int(sqlite3_column_int(stmt, 19))
      let artworkPath = optStr(stmt, 20)
      let dcOffset = optDouble(stmt, 21)
      let lufs = optDouble(stmt, 22)
      let truePeak = optDouble(stmt, 23)
      let dynamicRange = optDouble(stmt, 24)
      let phaseCorrelation = optDouble(stmt, 25)

      results.append(
        Track(
          id: id, path: path, title: title, artist: artist, album: album,
          albumArtist: albumArtist, trackNo: trackNo, discNo: discNo, year: year,
          genre: genre, duration: duration, format: format, sampleRate: sampleRate,
          bitDepth: bitDepth, channels: channels, bitrate: bitrate, fileSize: fileSize,
          dateAdded: dateAdded, lastPlayed: lastPlayed, playCount: playCount,
          artworkPath: artworkPath, dcOffset: dcOffset, lufs: lufs, truePeak: truePeak,
          dynamicRange: dynamicRange, phaseCorrelation: phaseCorrelation
        ))
    }
    sqlite3_finalize(stmt)
    self.tracks = results
  }

  private func optStr(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
    guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
    return String(cString: sqlite3_column_text(stmt, idx))
  }

  private func optInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
    guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
    return Int(sqlite3_column_int(stmt, idx))
  }

  private func optDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
    guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(stmt, idx)
  }

  // MARK: - Playlists

  func loadPlaylists() {
    var results: [Playlist] = []
    let sql = "SELECT * FROM playlists ORDER BY name ASC"
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &stmt, nil)

    let iso = ISO8601DateFormatter()

    while sqlite3_step(stmt) == SQLITE_ROW {
      let id = String(cString: sqlite3_column_text(stmt, 0))
      let name = String(cString: sqlite3_column_text(stmt, 1))
      let desc = optStr(stmt, 2)
      let createdStr = String(cString: sqlite3_column_text(stmt, 3))
      let created = iso.date(from: createdStr) ?? Date()
      let modifiedStr = String(cString: sqlite3_column_text(stmt, 4))
      let modified = iso.date(from: modifiedStr) ?? Date()
      let trackIds = trackIdsForPlaylist(playlistId: id)
      results.append(Playlist(id: id, name: name, description: desc, created: created, modified: modified, tracks: trackIds))
    }
    sqlite3_finalize(stmt)
    self.playlists = results
  }

  private func trackIdsForPlaylist(playlistId: String) -> [String] {
    var results: [String] = []
    let sql = "SELECT track_id FROM playlist_tracks WHERE playlist_id = ? ORDER BY position ASC"
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    sqlite3_bind_text(stmt, 1, (playlistId as NSString).utf8String, -1, nil)
    while sqlite3_step(stmt) == SQLITE_ROW {
      results.append(String(cString: sqlite3_column_text(stmt, 0)))
    }
    sqlite3_finalize(stmt)
    return results
  }

  func createPlaylist(name: String) -> Playlist {
    let id = UUID().uuidString
    let now = ISO8601DateFormatter().string(from: Date())
    let sql = "INSERT INTO playlists (id, name, created, modified) VALUES (?,?,?,?)"
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
    sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
    sqlite3_bind_text(stmt, 3, (now as NSString).utf8String, -1, nil)
    sqlite3_bind_text(stmt, 4, (now as NSString).utf8String, -1, nil)
    sqlite3_step(stmt)
    sqlite3_finalize(stmt)
    let p = Playlist(id: id, name: name, description: nil, created: Date(), modified: Date(), tracks: [])
    DispatchQueue.main.async { self.loadPlaylists() }
    return p
  }

  func deletePlaylist(id: String) {
    let delTracks = "DELETE FROM playlist_tracks WHERE playlist_id = ?"
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, delTracks, -1, &stmt, nil)
    sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
    sqlite3_step(stmt)
    sqlite3_finalize(stmt)

    let del = "DELETE FROM playlists WHERE id = ?"
    sqlite3_prepare_v2(db, del, -1, &stmt, nil)
    sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
    sqlite3_step(stmt)
    sqlite3_finalize(stmt)
    DispatchQueue.main.async { self.loadPlaylists() }
  }

  func addTrackToPlaylist(trackId: String, playlistId: String) {
    let position = trackIdsForPlaylist(playlistId: playlistId).count
    let sql = "INSERT OR IGNORE INTO playlist_tracks (playlist_id, track_id, position) VALUES (?,?,?)"
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    sqlite3_bind_text(stmt, 1, (playlistId as NSString).utf8String, -1, nil)
    sqlite3_bind_text(stmt, 2, (trackId as NSString).utf8String, -1, nil)
    sqlite3_bind_int(stmt, 3, Int32(position))
    sqlite3_step(stmt)
    sqlite3_finalize(stmt)
    DispatchQueue.main.async { self.loadPlaylists() }
  }

  func removeTrackFromPlaylist(trackId: String, playlistId: String) {
    let sql = "DELETE FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?"
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    sqlite3_bind_text(stmt, 1, (playlistId as NSString).utf8String, -1, nil)
    sqlite3_bind_text(stmt, 2, (trackId as NSString).utf8String, -1, nil)
    sqlite3_step(stmt)
    sqlite3_finalize(stmt)
    reindexPlaylist(playlistId: playlistId)
    DispatchQueue.main.async { self.loadPlaylists() }
  }

  func tracksForPlaylist(_ playlistId: String) -> [Track] {
    trackIdsForPlaylist(playlistId: playlistId).compactMap { tid in
      tracks.first { $0.id == tid }
    }
  }

  func renamePlaylist(id: String, name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let sql = "UPDATE playlists SET name = ?, modified = ? WHERE id = ?"
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    let now = ISO8601DateFormatter().string(from: Date())
    sqlite3_bind_text(stmt, 1, (trimmed as NSString).utf8String, -1, nil)
    sqlite3_bind_text(stmt, 2, (now as NSString).utf8String, -1, nil)
    sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, nil)
    sqlite3_step(stmt)
    sqlite3_finalize(stmt)
    loadPlaylists()
  }

  func batchUpdateTrackMetadata(ids: [String], title: String?, artist: String?, album: String?) {
    guard !ids.isEmpty else { return }
    let sql = "UPDATE tracks SET title = ?, artist = ?, album = ? WHERE id = ?"
    var stmt: OpaquePointer?
    sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
    for id in ids {
      sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
      sqlite3_bind_text(stmt, 1, (title as NSString?)?.utf8String, -1, nil)
      sqlite3_bind_text(stmt, 2, (artist as NSString?)?.utf8String, -1, nil)
      sqlite3_bind_text(stmt, 3, (album as NSString?)?.utf8String, -1, nil)
      sqlite3_bind_text(stmt, 4, (id as NSString).utf8String, -1, nil)
      sqlite3_step(stmt)
      sqlite3_finalize(stmt)
    }
    sqlite3_exec(db, "COMMIT", nil, nil, nil)
    loadTracks()
  }

  func updateTrackMetadata(id: String, title: String?, artist: String?, album: String?) {
    let sql = "UPDATE tracks SET title = ?, artist = ?, album = ? WHERE id = ?"
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    sqlite3_bind_text(stmt, 1, (title as NSString?)?.utf8String, -1, nil)
    sqlite3_bind_text(stmt, 2, (artist as NSString?)?.utf8String, -1, nil)
    sqlite3_bind_text(stmt, 3, (album as NSString?)?.utf8String, -1, nil)
    sqlite3_bind_text(stmt, 4, (id as NSString).utf8String, -1, nil)
    sqlite3_step(stmt)
    sqlite3_finalize(stmt)
    loadTracks()
  }

  func clearPlaylist(id: String) {
    let sql = "DELETE FROM playlist_tracks WHERE playlist_id = ?"
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
    sqlite3_step(stmt)
    sqlite3_finalize(stmt)
    loadPlaylists()
  }

  func moveTrackInPlaylist(playlistId: String, trackId: String, by offset: Int) {
    var ids = trackIdsForPlaylist(playlistId: playlistId)
    guard let index = ids.firstIndex(of: trackId) else { return }
    let newIndex = max(0, min(ids.count - 1, index + offset))
    guard newIndex != index else { return }
    ids.remove(at: index)
    ids.insert(trackId, at: newIndex)
    updatePlaylistOrder(playlistId: playlistId, trackIds: ids)
    loadPlaylists()
  }

  func recordPlayback(trackId: String) {
    let iso = ISO8601DateFormatter()
    let nowDate = Date()
    let now = iso.string(from: nowDate)

    var stmt: OpaquePointer?
    let insert = "INSERT INTO play_history (track_id, played_at) VALUES (?,?)"
    sqlite3_prepare_v2(db, insert, -1, &stmt, nil)
    sqlite3_bind_text(stmt, 1, (trackId as NSString).utf8String, -1, nil)
    sqlite3_bind_text(stmt, 2, (now as NSString).utf8String, -1, nil)
    sqlite3_step(stmt)
    sqlite3_finalize(stmt)

    let update = "UPDATE tracks SET last_played = ?, play_count = play_count + 1 WHERE id = ?"
    sqlite3_prepare_v2(db, update, -1, &stmt, nil)
    sqlite3_bind_text(stmt, 1, (now as NSString).utf8String, -1, nil)
    sqlite3_bind_text(stmt, 2, (trackId as NSString).utf8String, -1, nil)
    sqlite3_step(stmt)
    sqlite3_finalize(stmt)

    if let index = tracks.firstIndex(where: { $0.id == trackId }) {
      tracks[index].lastPlayed = nowDate
      tracks[index].playCount += 1
      // Re-assign to trigger @Published update in SwiftUI
      self.tracks = self.tracks
    }
  }

  private func reindexPlaylist(playlistId: String) {
    let ids = trackIdsForPlaylist(playlistId: playlistId)
    updatePlaylistOrder(playlistId: playlistId, trackIds: ids)
  }

  private func updatePlaylistOrder(playlistId: String, trackIds: [String]) {
    let sql = "UPDATE playlist_tracks SET position = ? WHERE playlist_id = ? AND track_id = ?"
    var stmt: OpaquePointer?
    for (position, trackId) in trackIds.enumerated() {
      sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
      sqlite3_bind_int(stmt, 1, Int32(position))
      sqlite3_bind_text(stmt, 2, (playlistId as NSString).utf8String, -1, nil)
      sqlite3_bind_text(stmt, 3, (trackId as NSString).utf8String, -1, nil)
      sqlite3_step(stmt)
      sqlite3_finalize(stmt)
    }
  }

  deinit {
    if let db { sqlite3_close(db) }
  }
}
