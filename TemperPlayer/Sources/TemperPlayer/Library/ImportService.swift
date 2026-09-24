import SwiftUI
import UniformTypeIdentifiers
import CTemperPlayer
import AVFoundation
import CryptoKit
import os

class ImportService: ObservableObject {
    static let shared = ImportService()
    private static let logger = Logger(subsystem: "com.temperplayer", category: "import")

    private let decoderExtensions: Set<String> = ["flac", "wav"]

    @MainActor @Published var isImporting = false
    @MainActor @Published var importedCount = 0
    /// Unique supported files to process, excluding tracks already in the library.
    @MainActor @Published var foundCount = 0
    @MainActor @Published var importSummary: String?
    @MainActor @Published var currentFile = ""
    @MainActor private var importTask: Task<Void, Never>?

    // Thread-safe artwork cache using os_unfair_lock
    private var artworkCache: [String: Data] = [:]
    private var artworkIndex: [String: String] = [:] // trackId → contentHash
    private let artworkLock = OSAllocatedUnfairLock()

    private let artworkDir: URL

    init(artworkDirectory: URL = LibraryStorage.directory.appendingPathComponent("artwork")) {
        artworkDir = artworkDirectory
    }

    private var artworkIndexURL: URL {
        artworkDir.appendingPathComponent("index.json")
    }

    func artwork(for trackId: String) -> Data? {
        artworkLock.withLock { artworkCache[trackId] }
    }

    @MainActor private var database: Database?

    @MainActor func setDatabase(_ db: Database) {
        guard database !== db else { return }
        database = db
        loadArtworkCache()
    }

    func batchUpdateArtwork(trackIds: [String], from url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let hash = dataHash(data)
        artworkLock.withLock {
            for id in trackIds {
                artworkCache[id] = data
                artworkIndex[id] = hash
            }
        }
        persistArtwork(data, hash: hash)
        saveArtworkIndex()
        Task { @MainActor in self.objectWillChange.send() }
    }

    func updateArtwork(trackId: String, from url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let hash = dataHash(data)
        artworkLock.withLock {
            artworkCache[trackId] = data
            artworkIndex[trackId] = hash
        }
        persistArtwork(data, hash: hash)
        saveArtworkIndex()
        Task { @MainActor in self.objectWillChange.send() }
    }

    // MARK: - Content-addressed artwork storage

    private func dataHash(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Detect image format from magic bytes and return the correct extension.
    private func artworkExtension(for data: Data) -> String {
        let magic = data.prefix(4)
        if magic.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if magic.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if magic.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if magic.starts(with: [0x42, 0x4D]) { return "bmp" }
        // Default to jpg for unknown formats; most embedded art is JPEG.
        return "jpg"
    }

    /// Write artwork data keyed by content hash. Only one copy per unique image.
    private func persistArtwork(_ data: Data, hash: String) {
        try? FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        let ext = artworkExtension(for: data)
        let dest = artworkDir.appendingPathComponent("\(hash).\(ext)")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        try? data.write(to: dest, options: .atomic)
    }

    @discardableResult
    private func saveArtworkIndex() -> Bool {
        // Keep the snapshot and its write ordered: an older concurrent save must
        // not replace a newer index. Atomic replacement also survives interruption.
        artworkLock.withLock {
            do {
                let json = try JSONEncoder().encode(artworkIndex)
                try FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
                try json.write(to: artworkIndexURL, options: .atomic)
                return true
            } catch {
                Self.logger.error("Could not save artwork index: \(error.localizedDescription)")
                return false
            }
        }
    }

    private func loadArtworkCache() {
        // Load index: trackId → contentHash
        if let data = try? Data(contentsOf: artworkIndexURL),
           let index = try? JSONDecoder().decode([String: String].self, from: data) {
            artworkLock.withLock { artworkIndex = index }
        }

        // Load artwork data from content-addressed files (try multiple extensions).
        let extensions = ["jpg", "png", "gif", "bmp"]
        for (trackId, hash) in artworkLock.withLock({ artworkIndex }) {
            for ext in extensions {
                let fileURL = artworkDir.appendingPathComponent("\(hash).\(ext)")
                if let data = try? Data(contentsOf: fileURL) {
                    artworkLock.withLock { artworkCache[trackId] = data }
                    break
                }
            }
        }

        // Migrate legacy artwork files (named by track ID) to content-addressed
        migrateLegacyArtwork()
    }

    /// Migrate old `{trackId}.jpg` files to content-addressed `{hash}.jpg`
    private func migrateLegacyArtwork() {
        // If we already have a populated index, nothing to migrate
        let existingIndex = artworkLock.withLock { artworkIndex }
        if !existingIndex.isEmpty { return }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: artworkDir, includingPropertiesForKeys: nil
        ) else { return }

        var newMappings: [(trackId: String, hash: String, data: Data)] = []
        var filesToDelete: [URL] = []

        for file in files where ["jpg", "png", "gif", "bmp"].contains(file.pathExtension) {
            let name = file.deletingPathExtension().lastPathComponent
            if name == "index" { continue }

            guard let data = try? Data(contentsOf: file) else { continue }
            let hash = dataHash(data)

            // Already content-addressed — nothing to do
            if name == hash { continue }

            // Write content-addressed copy with correct extension
            let ext = artworkExtension(for: data)
            let hashFile = artworkDir.appendingPathComponent("\(hash).\(ext)")
            if !FileManager.default.fileExists(atPath: hashFile.path) {
                do {
                    try data.write(to: hashFile, options: .atomic)
                } catch {
                    continue // skip this file if we can't write the new one
                }
            }

            newMappings.append((name, hash, data))
            filesToDelete.append(file)
        }

        // Save index BEFORE deleting legacy files (crash-safe)
        if !newMappings.isEmpty {
            let mappings = newMappings // capture for sendable closure
            artworkLock.withLock {
                for m in mappings {
                    artworkCache[m.trackId] = m.data
                    artworkIndex[m.trackId] = m.hash
                }
            }
            guard saveArtworkIndex() else { return }

            // Now safe to delete legacy files
            for file in filesToDelete {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private struct PreparedTrack {
        var track: Track
        var artwork: Data?
    }

    private enum ImportError: LocalizedError {
        case invalidAudio
        case unsupportedChannels

        var errorDescription: String? {
            switch self {
            case .invalidAudio: return "The file does not contain readable, playable audio with a valid duration."
            case .unsupportedChannels: return "Only mono and stereo audio are supported. Convert surround audio before importing."
            }
        }
    }

    /// Reads and validates without writing to the library. Runs on the import worker.
    private func readTrack(url: URL) async throws -> PreparedTrack {
        try Task.checkCancellation()
        let path = url.path
        let ext = url.pathExtension.lowercased()
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        guard let fileSize = attrs[.size] as? Int, fileSize > 0 else {
            throw ImportError.invalidAudio
        }

        // AVAudioFile is also the playback backend. Opening an AVAsset alone
        // can accept video-only containers or headers whose audio cannot decode.
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0,
              format.sampleRate < Double(Int.max), format.channelCount > 0 else {
            throw ImportError.invalidAudio
        }
        guard format.channelCount <= 2 else { throw ImportError.unsupportedChannels }
        let dur = Double(audioFile.length) / format.sampleRate
        guard dur.isFinite, dur > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
            throw ImportError.invalidAudio
        }
        try audioFile.read(into: buffer, frameCount: 1024)
        guard buffer.frameLength > 0 else { throw ImportError.invalidAudio }
        try Task.checkCancellation()


        let isDecoderFormat = decoderExtensions.contains(ext)

        var meta: MetadataJSON
        var duration: Double = 0
        var sampleRate: Int = 0
        var bitDepth: Int = 0
        var channels: Int = 0
        var mastering: MasteringInfo = MasteringInfo(
            lufs: 0, true_peak_db: 0, peak_db: 0,
            dynamic_range_db: 0, phase_correlation: 0,
            dc_offset_pct: 0, phase_ok: 0
        )

        if isDecoderFormat {
            let decoder = DecoderBridge()
            guard decoder.open(path: path) else { throw ImportError.invalidAudio }
            defer { decoder.close() }
            duration = decoder.durationSeconds
            sampleRate = Int(decoder.sampleRate)
            bitDepth = Int(decoder.bitDepth)
            channels = Int(decoder.channels)
            guard duration.isFinite, duration > 0, sampleRate > 0, channels > 0,
                  AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: Double(sampleRate),
                                channels: AVAudioChannelCount(channels),
                                interleaved: true) != nil else {
                throw ImportError.invalidAudio
            }
            // Probe the analysis decoder as well, not just its header.
            var samples = [Float](repeating: 0, count: channels)
            let framesRead = samples.withUnsafeMutableBufferPointer {
                decoder.readFrames(into: $0.baseAddress!, count: 1)
            }
            guard framesRead > 0 else { throw ImportError.invalidAudio }
            try Task.checkCancellation()
            meta = parseMetadata(json: DecoderBridge.readMetadata(path: path))
            try Task.checkCancellation()
            mastering = DecoderBridge.readMastering(path: path)
            try Task.checkCancellation()
        } else {

            let asset = AVAsset(url: url)
            var metadataFailed = false
            let aSampleRate = Int(format.sampleRate)
            let aBitDepth = Int(audioFile.fileFormat.streamDescription.pointee.mBitsPerChannel)
            let aChannels = Int(format.channelCount)
            var aTitle: String?
            var aArtist: String?
            var aAlbum: String?
            var aAlbumArtist: String?
            var aGenre: String?
            var aYear: Int?
            var aTrackNo: Int?
            var aDiscNo: Int?
            var artworkData: Data?

            do {
                let commonMeta = try await asset.load(.commonMetadata)
                for item in commonMeta {
                    if Task.isCancelled { break }
                    guard let key = item.commonKey else { continue }
                    do {
                        let val = try await item.load(.value)
                        if key == .commonKeyTitle { aTitle = val as? String }
                        else if key == .commonKeyArtist { aArtist = val as? String }
                        else if key == .commonKeyAlbumName { aAlbum = val as? String }
                        else if key == .commonKeyArtwork { artworkData = val as? Data }
                    } catch {
                        metadataFailed = true
                    }
                }
            } catch {
                Self.logger.warning("importTrack: failed to load common metadata for \(path): \(error.localizedDescription)")
                metadataFailed = true
            }

            try Task.checkCancellation()
            let allMeta = try? await asset.load(.metadata)
            for item in allMeta ?? [] {
                try Task.checkCancellation()
                let keyText = metadataKeyText(item)
                guard let stringValue = await metadataString(from: item) else { continue }

                if keyText.contains("albumartist") || keyText.contains("album artist") {
                    aAlbumArtist = aAlbumArtist ?? stringValue
                } else if keyText.contains("genre") {
                    aGenre = aGenre ?? stringValue
                } else if keyText.contains("tracknumber") || keyText.contains("track number") || keyText.contains("trkn") {
                    aTrackNo = aTrackNo ?? parseLeadingInt(stringValue)
                } else if keyText.contains("discnumber") || keyText.contains("disc number") || keyText.contains("disk") {
                    aDiscNo = aDiscNo ?? parseLeadingInt(stringValue)
                } else if keyText.contains("year") || keyText.contains("date") {
                    aYear = aYear ?? parseLeadingInt(stringValue)
                }
            }

            try Task.checkCancellation()

            if metadataFailed {
                Self.logger.warning("importTrack: partial metadata for \(path) — some fields could not be read")
            }

            let track = Track(
                id: path.pathHash, path: path,
                title: aTitle ?? url.deletingPathExtension().lastPathComponent,
                artist: aArtist, album: aAlbum,
                albumArtist: aAlbumArtist, trackNo: aTrackNo, discNo: aDiscNo,
                year: aYear, genre: aGenre,
                duration: dur, format: ext,
                sampleRate: aSampleRate, bitDepth: aBitDepth,
                channels: aChannels, bitrate: estimateBitrate(fileSize: fileSize, duration: dur),
                fileSize: fileSize, dateAdded: Date(), playCount: 0
            )
            return PreparedTrack(track: track, artwork: artworkData)
        }

        let track = Track(
            id: path.pathHash,
            path: path,
            title: meta.resolvedTitle ?? url.deletingPathExtension().lastPathComponent,
            artist: meta.artist,
            album: meta.album,
            albumArtist: meta.resolvedAlbumArtist,
            trackNo: meta.resolvedTrackNo,
            discNo: meta.resolvedDiscNo,
            year: meta.year,
            genre: meta.genre,
            duration: duration,
            format: ext,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            bitrate: estimateBitrate(fileSize: fileSize, duration: duration),
            fileSize: fileSize,
            dateAdded: Date(),
            playCount: 0,
            dcOffset: mastering.dc_offset_pct,
            lufs: mastering.lufs,
            truePeak: mastering.true_peak_db,
            dynamicRange: mastering.dynamic_range_db,
            phaseCorrelation: mastering.phase_correlation
        )

        return PreparedTrack(track: track, artwork: nil)
    }

    /// One serialized, cancellable job for picker, menu and drop imports alike.
    /// A second request is ignored while the current job is running or cancelling.
    @MainActor func importURLs(_ urls: [URL]) {
        guard !isImporting, !urls.isEmpty else { return }
        guard let database else {
            importSummary = "Could not import: the music library is unavailable."
            return
        }
        isImporting = true
        importedCount = 0
        foundCount = 0
        importSummary = nil
        currentFile = "Scanning files…"
        let existingPaths = database.tracks.map(\.path)
        importTask = Task.detached(priority: .userInitiated) { [self] in
            let result = await runImport(urls: urls, existingPaths: existingPaths, database: database)
            await MainActor.run {
                var completedResult = result
                completedResult.wasCancelled = completedResult.wasCancelled || Task.isCancelled
                self.importSummary = completedResult.summary
                self.currentFile = ""
                self.importTask = nil
                self.isImporting = false
            }
        }
    }

    @MainActor func importFolder(url: URL) {
        importURLs([url])
    }

    @MainActor func cancelImport() {
        guard isImporting else { return }
        importTask?.cancel()
        currentFile = "Cancelling…"
        // Keep the job occupied (and scopes open) until its worker actually exits.
    }

    @MainActor func presentImportPanel() {
        guard !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Audio"
        panel.message = "Choose audio files or folders. Folders are searched recursively."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ImportSelection.supportedExtensions.sorted().compactMap {
            UTType(filenameExtension: $0)
        }
        if panel.runModal() == .OK {
            importURLs(panel.urls)
        }
    }

    private func runImport(urls: [URL], existingPaths: [String], database: Database) async -> ImportResult {
        // Keep the ORIGINAL selections scoped, especially directory roots: child
        // URLs do not carry their parent's security-scoped grant themselves.
        let scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }

        let selection = ImportSelection.enumerate(urls, existingPaths: existingPaths) { Task.isCancelled }
        var result = selection.result
        await MainActor.run { self.foundCount = selection.files.count }
        var processedCount = 0
        for file in selection.files {
            if Task.isCancelled { break }
            await MainActor.run {
                if !Task.isCancelled { self.currentFile = file.lastPathComponent }
            }
            do {
                let prepared = try await readTrack(url: file)
                try Task.checkCancellation()
                let insertion = await MainActor.run { () -> (saved: Bool, error: String?) in
                    guard !Task.isCancelled else { return (false, nil) }
                    database.insert(track: prepared.track)
                    // Snapshot the error in the same actor turn as the write;
                    // another library action may clear lastError afterwards.
                    return (database.lastError == nil, database.lastError)
                }
                if insertion.saved {
                    result.importedCount += 1
                    await MainActor.run { self.importedCount += 1 }
                    // A completed insertion is retained even if cancellation now
                    // skips optional artwork work; never report it as a failure.
                    if !Task.isCancelled {
                        if let data = prepared.artwork {
                            cacheArtwork(data, id: prepared.track.id)
                        } else {
                            await extractArtwork(path: prepared.track.path, id: prepared.track.id)
                        }
                    }
                } else {
                    try Task.checkCancellation()
                    result.recordFailure(file: file, reason: insertion.error ?? "The library could not save this track.")
                }
                processedCount += 1
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled { break }
                Self.logger.warning("Import failed for \(file.path, privacy: .private): \(error.localizedDescription)")
                result.recordFailure(file: file, reason: error.localizedDescription)
                processedCount += 1
            }
        }
        result.wasCancelled = result.wasCancelled || Task.isCancelled
        result.notProcessedCount = selection.files.count - processedCount
        return result
    }

    private struct MetadataJSON: Decodable {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var album_artist: String?
        var trackNo: Int?
        var track_no: Int?
        var discNo: Int?
        var disc_no: Int?
        var year: Int?
        var genre: String?

        var resolvedTitle: String? { clean(title) }
        var resolvedAlbumArtist: String? { clean(albumArtist) ?? clean(album_artist) }
        var resolvedTrackNo: Int? { trackNo ?? track_no }
        var resolvedDiscNo: Int? { discNo ?? disc_no }

        private func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
    }

    private func parseMetadata(json: String?) -> MetadataJSON {
        guard let json, let data = json.data(using: .utf8),
              let meta = try? JSONDecoder().decode(MetadataJSON.self, from: data) else {
            return MetadataJSON()
        }
        return meta
    }

    private func extractArtwork(path: String, id: String) async {
        // Check cache under lock
        let cached = artworkLock.withLock { artworkCache[id] }
        guard cached == nil, !Task.isCancelled else { return }
        let asset = AVAsset(url: URL(fileURLWithPath: path))
        let metas = try? await asset.load(.commonMetadata)
        for item in metas ?? [] {
            if Task.isCancelled { return }
            if item.commonKey == .commonKeyArtwork, let data = try? await item.load(.value) as? Data {
                guard !Task.isCancelled else { return }
                self.cacheArtwork(data, id: id)
                break
            }
        }
    }

    private func cacheArtwork(_ data: Data, id: String) {
        let hash = dataHash(data)
        artworkLock.withLock {
            artworkCache[id] = data
            artworkIndex[id] = hash
        }
        persistArtwork(data, hash: hash)
        saveArtworkIndex()
        Task { @MainActor in self.objectWillChange.send() }
    }

    private func metadataKeyText(_ item: AVMetadataItem) -> String {
        [
            item.commonKey?.rawValue,
            item.identifier?.rawValue,
            item.keySpace?.rawValue,
            item.key.map { String(describing: $0) }
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }

    private func metadataString(from item: AVMetadataItem) async -> String? {
        guard let value = try? await item.load(.value) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let data = value as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    private func parseLeadingInt(_ value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.prefix { $0.isNumber }
        if !digits.isEmpty { return Int(digits) }
        let parts = value.split(whereSeparator: { !$0.isNumber })
        return parts.compactMap { Int($0) }.first
    }

    private func estimateBitrate(fileSize: Int, duration: Double) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        let bitrate = (Double(fileSize) * 8) / duration
        guard bitrate.isFinite, bitrate < Double(Int.max) else { return 0 }
        return Int(bitrate)
    }
}
