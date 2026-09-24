import Foundation
import XCTest
@testable import TemperPlayer

final class ImportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TemperImportTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testMixedFilesAndRecursiveFoldersFilterExtensionsAndDirectories() throws {
        let folder = directory.appendingPathComponent("album.wav", isDirectory: true)
        let nested = folder.appendingPathComponent("disc", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let direct = try fixture("direct.MP3")
        let nestedAudio = try fixture("album.wav/disc/song.FLAC")
        _ = try fixture("album.wav/notes.txt")
        _ = try fixture("album.wav/.hidden.mp3")

        let selection = ImportSelection.enumerate([direct, folder])

        XCTAssertEqual(Set(selection.files), Set([direct, nestedAudio].map(ImportSelection.canonicalURL)))
        XCTAssertEqual(selection.result.unsupportedCount, 1)
        XCTAssertEqual(selection.result.failedCount, 0)
    }

    func testOverlappingSelectionsAndSymlinksDeduplicateCanonicalPaths() throws {
        let song = try fixture("song.wav")
        let alias = directory.appendingPathComponent("alias.wav")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: song)

        let selection = ImportSelection.enumerate([song, directory, alias])

        XCTAssertEqual(selection.files, [ImportSelection.canonicalURL(song)])
        XCTAssertEqual(selection.result.duplicateCount, 3)
    }

    func testExistingLibraryPathsAreCanonicalizedBeforeImport() throws {
        let song = try fixture("song.wav")
        let alias = directory.appendingPathComponent("alias.wav")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: song)

        let selection = ImportSelection.enumerate([song], existingPaths: [alias.path])

        XCTAssertTrue(selection.files.isEmpty)
        XCTAssertEqual(selection.result.duplicateCount, 1)
    }

    func testMissingAndNonFileURLsAreReportedAsFailures() {
        let selection = ImportSelection.enumerate([
            directory.appendingPathComponent("missing.mp3"),
            URL(string: "https://example.com/remote.mp3")!,
        ])

        XCTAssertTrue(selection.files.isEmpty)
        XCTAssertEqual(selection.result.failedCount, 2)
        XCTAssertNotNil(selection.result.firstFailure)
    }

    func testEnumerationHonorsCancellation() throws {
        for index in 0..<30 { _ = try fixture("\(index).wav") }
        var checks = 0
        let selection = ImportSelection.enumerate([directory]) {
            checks += 1
            return checks > 6
        }

        XCTAssertTrue(selection.result.wasCancelled)
        XCTAssertLessThan(selection.files.count, 30)
        XCTAssertEqual(selection.result.failedCount, 0)
    }

    func testSummaryDistinguishesFailuresSkipsAndCancellation() {
        var result = ImportResult()
        result.importedCount = 2
        result.duplicateCount = 3
        result.unsupportedCount = 1
        result.recordFailure(file: directory.appendingPathComponent("broken.mp3"), reason: "Unreadable audio")
        result.wasCancelled = true
        result.notProcessedCount = 4

        XCTAssertTrue(result.summary.contains("Import cancelled"))
        XCTAssertTrue(result.summary.contains("2 imported, 4 skipped, 1 failed"))
        XCTAssertTrue(result.summary.contains("3 duplicate, 1 unsupported"))
        XCTAssertTrue(result.summary.contains("4 discovered files not processed"))
        XCTAssertTrue(result.summary.contains("broken.mp3: Unreadable audio"))
    }

    @MainActor
    func testValidAudioImportsButCorruptAndZeroDurationAudioDoNot() async throws {
        let database = Database(databaseURL: directory.appendingPathComponent("library.db"))
        let service = makeService(database: database)
        let valid = directory.appendingPathComponent("valid.wav")
        try writeWAV(to: valid)
        let empty = directory.appendingPathComponent("empty.wav")
        try writeWAV(to: empty, frames: 0)
        var urls = [valid, empty]
        for ext in ImportSelection.supportedExtensions.sorted() {
            urls.append(try fixture("corrupt.\(ext)"))
        }
        urls.append(try fixture("notes.txt"))

        service.importURLs(urls)
        try await waitForImport(service)

        XCTAssertEqual(service.foundCount, 8)
        XCTAssertEqual(service.importedCount, 1)
        XCTAssertEqual(database.tracks.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(database.tracks.first).duration, 0)
        XCTAssertTrue(service.importSummary?.contains("1 imported, 1 skipped, 7 failed") == true)
        XCTAssertTrue(service.currentFile.isEmpty)
    }

    @MainActor
    func testReimportPreservesEditedMetadataPlaybackAndPlaylistMembership() async throws {
        let database = Database(databaseURL: directory.appendingPathComponent("library.db"))
        let service = makeService(database: database)
        let song = directory.appendingPathComponent("song.wav")
        try writeWAV(to: song)
        service.importURLs([song])
        try await waitForImport(service)
        let id = try XCTUnwrap(database.tracks.first).id
        database.updateTrackMetadata(id: id, title: "My title", artist: "My artist", album: "My album")
        database.recordPlayback(trackId: id)
        let playlist = database.createPlaylist(name: "Favorites")
        database.addTrackToPlaylist(trackId: id, playlistId: playlist.id)
        XCTAssertNil(database.lastError)
        let before = try XCTUnwrap(database.tracks.first)
        let alias = directory.appendingPathComponent("alias.wav")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: song)

        service.importURLs([alias, song])
        try await waitForImport(service)

        XCTAssertEqual(service.foundCount, 0)
        XCTAssertEqual(service.importedCount, 0)
        XCTAssertTrue(service.importSummary?.contains("0 imported, 2 skipped, 0 failed") == true)
        let after = try XCTUnwrap(database.tracks.first)
        XCTAssertEqual(database.tracks.count, 1)
        XCTAssertEqual(after.title, before.title)
        XCTAssertEqual(after.artist, before.artist)
        XCTAssertEqual(after.album, before.album)
        XCTAssertEqual(after.dateAdded, before.dateAdded)
        XCTAssertEqual(after.lastPlayed, before.lastPlayed)
        XCTAssertEqual(after.playCount, before.playCount)
        XCTAssertEqual(database.tracksForPlaylist(playlist.id).map(\.id), [id])
    }

    @MainActor
    func testCancellationKeepsSingleJobOccupiedUntilWorkerFinishesAndAllowsRetry() async throws {
        let database = Database(databaseURL: directory.appendingPathComponent("library.db"))
        let service = makeService(database: database)
        let first = directory.appendingPathComponent("first.wav")
        let second = directory.appendingPathComponent("second.wav")
        try writeWAV(to: first)
        try writeWAV(to: second)

        service.importURLs([first])
        XCTAssertTrue(service.isImporting)
        service.cancelImport()
        service.importURLs([second])
        XCTAssertTrue(service.isImporting)
        XCTAssertEqual(service.currentFile, "Cancelling…")
        try await waitForImport(service)
        XCTAssertTrue(database.tracks.isEmpty)
        XCTAssertEqual(service.importedCount, 0)
        XCTAssertTrue(service.importSummary?.contains("Import cancelled") == true)

        service.importURLs([second])
        try await waitForImport(service)
        XCTAssertEqual(database.tracks.map(\.path), [ImportSelection.canonicalURL(second).path])
        XCTAssertEqual(service.importedCount, 1)
    }

    @MainActor
    func testDatabaseWriteFailureIsNotCountedAsImported() async throws {
        // An existing directory cannot be opened as a SQLite file.
        let database = Database(databaseURL: directory)
        XCTAssertNotNil(database.lastError)
        let service = makeService(database: database)
        let song = directory.appendingPathComponent("song.wav")
        try writeWAV(to: song)

        service.importURLs([song])
        try await waitForImport(service)

        XCTAssertEqual(service.importedCount, 0)
        XCTAssertTrue(database.tracks.isEmpty)
        XCTAssertTrue(service.importSummary?.contains("0 imported, 0 skipped, 1 failed") == true)
    }

    @MainActor
    func testSettingSameDatabaseDoesNotReloadArtwork() async throws {
        let database = Database(databaseURL: directory.appendingPathComponent("library.db"))
        let service = makeService(database: database)
        let source = directory.appendingPathComponent("source.jpg")
        let original = Data([0xFF, 0xD8, 0xFF, 0x01])
        try original.write(to: source)
        service.updateArtwork(trackId: "track", from: source)
        let artworkDirectory = directory.appendingPathComponent("artwork")
        let index = try JSONDecoder().decode([String: String].self, from:
            Data(contentsOf: artworkDirectory.appendingPathComponent("index.json")))
        let hash = try XCTUnwrap(index["track"])
        try Data([0xFF, 0xD8, 0xFF, 0x02]).write(to: artworkDirectory.appendingPathComponent("\(hash).jpg"))

        service.setDatabase(database)

        XCTAssertEqual(service.artwork(for: "track"), original)
    }

    @MainActor
    func testArtworkMigrationRetainsLegacyFilesUntilIndexSaveSucceeds() async throws {
        let database = Database(databaseURL: directory.appendingPathComponent("library.db"))
        let artworkDirectory = directory.appendingPathComponent("artwork")
        let indexURL = artworkDirectory.appendingPathComponent("index.json")
        // A directory at the index path deterministically makes its write fail.
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)
        try Data("block index replacement".utf8).write(to: indexURL.appendingPathComponent("blocker"))
        let legacy = artworkDirectory.appendingPathComponent("legacy.jpg")
        let data = Data([0xFF, 0xD8, 0xFF, 0x01])
        try data.write(to: legacy)

        let service = makeService(database: database)

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(service.artwork(for: "legacy"), data)

        // Simulate the next launch after the filesystem problem is resolved.
        try FileManager.default.removeItem(at: indexURL)
        let retry = makeService(database: database)
        let index = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: indexURL))
        XCTAssertNotNil(index["legacy"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(retry.artwork(for: "legacy"), data)
    }

    @MainActor
    func testSurroundAudioIsRejectedBeforeStereoOnlyPlayback() async throws {
        let database = Database(databaseURL: directory.appendingPathComponent("library.db"))
        let service = makeService(database: database)
        let file = directory.appendingPathComponent("surround.wav")
        try writeWAV(to: file, channels: 6)
        service.importURLs([file])
        try await waitForImport(service)
        XCTAssertTrue(database.tracks.isEmpty)
        XCTAssertEqual(service.importedCount, 0)
        XCTAssertTrue(service.importSummary?.contains("Only mono and stereo audio are supported") == true)
    }

    @MainActor
    private func makeService(database: Database) -> ImportService {
        // Never read or write the user's real artwork cache or library in tests.
        let service = ImportService(artworkDirectory: directory.appendingPathComponent("artwork"))
        service.setDatabase(database)
        return service
    }

    @MainActor
    private func waitForImport(_ service: ImportService) async throws {
        let deadline = Date().addingTimeInterval(10)
        while service.isImporting && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if service.isImporting {
            service.cancelImport()
            XCTFail("Import did not finish within 10 seconds")
            throw CancellationError()
        }
    }

    private func fixture(_ path: String) throws -> URL {
        let url = directory.appendingPathComponent(path)
        try Data("not audio".utf8).write(to: url)
        return url
    }

    /// A short, silent mono PCM WAV, generated entirely inside the test folder.
    private func writeWAV(to url: URL, frames: UInt32 = 441, channels: UInt16 = 1) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + frames * UInt32(channels) * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(channels)
        append(UInt32(44_100))
        append(UInt32(88_200) * UInt32(channels))
        append(UInt16(2) * channels)
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(frames * UInt32(channels) * 2)
        data.append(Data(repeating: 0, count: Int(frames * UInt32(channels) * 2)))
        try data.write(to: url)
    }
}
