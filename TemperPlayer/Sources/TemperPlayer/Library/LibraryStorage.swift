import Foundation

/// Source builds can opt into a separate library for development and UI smoke tests.
/// The default remains compatible with existing installations.
enum LibraryStorage {
    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["TEMPERPLAYER_LIBRARY_DIRECTORY"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".temperplayer", isDirectory: true)
    }
}
