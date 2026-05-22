import Foundation

struct Track: Identifiable, Codable, Equatable {
  let id: String  // SHA-256 of absolute path
  var path: String
  var title: String?
  var artist: String?
  var album: String?
  var albumArtist: String?
  var trackNo: Int?
  var discNo: Int?
  var year: Int?
  var genre: String?
  var duration: Double
  var format: String
  var sampleRate: Int
  var bitDepth: Int
  var channels: Int
  var bitrate: Int
  var fileSize: Int
  var dateAdded: Date
  var lastPlayed: Date?
  var playCount: Int
  var artworkPath: String?
  var dcOffset: Double?
  var lufs: Double?
  var truePeak: Double?
  var dynamicRange: Double?
  var phaseCorrelation: Double?

  static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
}

struct Playlist: Identifiable, Codable {
  let id: String
  var name: String
  var description: String?
  var created: Date
  var modified: Date
  var tracks: [String]  // track IDs in order
}

struct StreamInfo {
  let format: String
  let sampleRate: Int
  let bitDepth: Int
  let channels: Int
  let duration: Double
  let lufs: Double
  let truePeak: Double
  let peak: Double
  let dynamicRange: Double
  let phaseCorrelation: Double
  let dcOffset: Double
  let phaseOk: Bool
}
