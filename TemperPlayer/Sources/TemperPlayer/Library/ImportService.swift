import SwiftUI
import UniformTypeIdentifiers
import CTemperPlayer
import AVFoundation
import CryptoKit
import os

class ImportService: ObservableObject {
    static let shared = ImportService()

    private let supportedExtensions: Set<String> = ["flac", "wav", "mp3", "m4a", "aac", "mp4"]
    private let decoderExtensions: Set<String> = ["flac", "wav"]

    @Published var isImporting = false
    @Published var importedCount = 0
    @Published var foundCount = 0

    // Thread-safe artwork cache using os_unfair_lock
    private var artworkCache: [String: Data] = [:]
    private var artworkIndex: [String: String] = [:] // trackId → contentHash
    private let artworkLock = OSAllocatedUnfairLock()

    private var artworkDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".temperplayer/artwork")
    }

    private var artworkIndexURL: URL {
        artworkDir.appendingPathComponent("index.json")
    }

    func artwork(for trackId: String) -> Data? {
        artworkLock.withLock { artworkCache[trackId] }
    }

    private var database: Database?

    func setDatabase(_ db: Database) {
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

    /// Write artwork data keyed by content hash. Only one copy per unique image.
    private func persistArtwork(_ data: Data, hash: String) {
        try? FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        let dest = artworkDir.appendingPathComponent("\(hash).jpg")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        try? data.write(to: dest)
    }

    private func saveArtworkIndex() {
        let index = artworkLock.withLock { artworkIndex }
        guard let json = try? JSONEncoder().encode(index) else { return }
        try? FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        try? json.write(to: artworkIndexURL)
    }

    private func loadArtworkCache() {
        // Load index: trackId → contentHash
        if let data = try? Data(contentsOf: artworkIndexURL),
           let index = try? JSONDecoder().decode([String: String].self, from: data) {
            artworkLock.withLock { artworkIndex = index }
        }

        // Load artwork data from content-addressed files
        for (trackId, hash) in artworkLock.withLock({ artworkIndex }) {
            let fileURL = artworkDir.appendingPathComponent("\(hash).jpg")
            if let data = try? Data(contentsOf: fileURL) {
                artworkLock.withLock { artworkCache[trackId] = data }
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

        for file in files where file.pathExtension == "jpg" {
            let name = file.deletingPathExtension().lastPathComponent
            if name == "index" { continue }

            guard let data = try? Data(contentsOf: file) else { continue }
            let hash = dataHash(data)

            // Already content-addressed — nothing to do
            if name == hash { continue }

            // Write content-addressed copy
            let hashFile = artworkDir.appendingPathComponent("\(hash).jpg")
            if !FileManager.default.fileExists(atPath: hashFile.path) {
                do {
                    try data.write(to: hashFile)
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
            saveArtworkIndex()

            // Now safe to delete legacy files
            for file in filesToDelete {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func importTrack(url: URL) {
        let path = url.path
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { return }

        let fileManager = FileManager.default
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? Int else { return }

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
            // Zig decoder path: metadata + mastering + duration
            let metaJSON = DecoderBridge.readMetadata(path: path)
            meta = parseMetadata(json: metaJSON)

            mastering = DecoderBridge.readMastering(path: path)

            let decoder = DecoderBridge()
            if decoder.open(path: path) {
                duration = decoder.durationSeconds
                sampleRate = Int(decoder.sampleRate)
                bitDepth = Int(decoder.bitDepth)
                channels = Int(decoder.channels)
                decoder.close()
            }
        } else {
            // AVFoundation path: metadata + duration via AVAsset
            let asset = AVAsset(url: url)
            Task {
                let dur = try? await asset.load(.duration).seconds
                var aSampleRate = 0, aBitDepth = 0, aChannels = 0
                var aTitle: String?
                var aArtist: String?
                var aAlbum: String?
                var aAlbumArtist: String?
                var aGenre: String?
                var aYear: Int?
                var aTrackNo: Int?
                var aDiscNo: Int?
                var artworkData: Data?

                let commonMeta = try? await asset.load(.commonMetadata)
                for item in commonMeta ?? [] {
                    guard let key = item.commonKey else { continue }
                    let val = try? await item.load(.value)
                    if key == .commonKeyTitle { aTitle = val as? String }
                    else if key == .commonKeyArtist { aArtist = val as? String }
                    else if key == .commonKeyAlbumName { aAlbum = val as? String }
                    else if key == .commonKeyArtwork { artworkData = val as? Data }
                }

                let allMeta = try? await asset.load(.metadata)
                for item in allMeta ?? [] {
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

                if let t = try? await asset.load(.tracks).first {
                    if let desc = try? await t.load(.formatDescriptions).first {
                        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee
                        aSampleRate = Int(asbd?.mSampleRate ?? 0)
                        aBitDepth = Int(asbd?.mBitsPerChannel ?? 0)
                        aChannels = Int(asbd?.mChannelsPerFrame ?? 0)
                    }
                }

                let track = Track(
                    id: path.pathHash, path: path,
                    title: aTitle ?? url.deletingPathExtension().lastPathComponent,
                    artist: aArtist, album: aAlbum,
                    albumArtist: aAlbumArtist, trackNo: aTrackNo, discNo: aDiscNo,
                    year: aYear, genre: aGenre,
                    duration: dur ?? 0, format: ext,
                    sampleRate: aSampleRate, bitDepth: aBitDepth,
                    channels: aChannels, bitrate: estimateBitrate(fileSize: fileSize, duration: dur ?? 0),
                    fileSize: fileSize, dateAdded: Date(), playCount: 0
                )
                await MainActor.run { self.database?.insert(track: track) }
                if let artworkData {
                    self.cacheArtwork(artworkData, id: track.id)
                } else {
                    self.extractArtwork(path: path, id: track.id)
                }
            }
            return
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

        DispatchQueue.main.async { self.database?.insert(track: track) }
        extractArtwork(path: path, id: track.id)
    }

    func importFolder(url: URL) {
        guard !isImporting else { return }
        isImporting = true
        importedCount = 0
        foundCount = 0

        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var files: [URL] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            if supportedExtensions.contains(ext) {
                files.append(fileURL)
            }
        }
        foundCount = files.count

        Task.detached(priority: .userInitiated) { [self] in
            for file in files {
                self.importTrack(url: file)
                await MainActor.run { self.importedCount += 1 }
            }
            await MainActor.run { self.isImporting = false }
        }
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

    private func extractArtwork(path: String, id: String) {
        // Check cache under lock
        let cached = artworkLock.withLock { artworkCache[id] }
        guard cached == nil else { return }
        let asset = AVAsset(url: URL(fileURLWithPath: path))
        Task {
            let metas = try? await asset.load(.commonMetadata)
            for item in metas ?? [] {
                if item.commonKey == .commonKeyArtwork, let data = try? await item.load(.value) as? Data {
                    self.cacheArtwork(data, id: id)
                    break
                }
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
        guard duration > 0 else { return 0 }
        return Int((Double(fileSize) * 8) / duration)
    }
}
