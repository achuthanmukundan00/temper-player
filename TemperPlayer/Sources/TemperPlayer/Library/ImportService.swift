import SwiftUI
import UniformTypeIdentifiers
import CTemperPlayer
import AVFoundation

struct ImportDropDelegate: DropDelegate {
    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    ImportService.shared.importTrack(url: url)
                }
            }
        }
        return true
    }
}

class ImportService: ObservableObject {
    static let shared = ImportService()

    private let supportedExtensions: Set<String> = ["flac", "wav", "mp3", "m4a", "aac", "mp4"]
    private let decoderExtensions: Set<String> = ["flac", "wav"]

    @Published var isImporting = false
    @Published var importedCount = 0
    @Published var foundCount = 0
    var artworkCache: [String: Data] = [:]

    private var database: Database!

    func setDatabase(_ db: Database) {
        database = db
    }

    func importTrack(url: URL) {
        let path = url.path
        let ext = url.pathExtension.lowercased()

        guard supportedExtensions.contains(ext) else { return }

        let fileManager = FileManager.default
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? Int else { return }

        let isDecoderFormat = decoderExtensions.contains(ext)

        var meta: (title: String?, artist: String?, album: String?)
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
            let parsed = parseMetadata(json: metaJSON)
            meta = (parsed.title, parsed.artist, parsed.album)

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

                let commonMeta = try? await asset.load(.commonMetadata)
                for item in commonMeta ?? [] {
                    guard let key = item.commonKey else { continue }
                    let val = try? await item.load(.value)
                    if key == .commonKeyTitle { aTitle = val as? String }
                    else if key == .commonKeyArtist { aArtist = val as? String }
                    else if key == .commonKeyAlbumName { aAlbum = val as? String }
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
                    duration: dur ?? 0, format: ext,
                    sampleRate: aSampleRate, bitDepth: aBitDepth,
                    channels: aChannels, bitrate: 0,
                    fileSize: fileSize, dateAdded: Date(), playCount: 0
                )
                await MainActor.run { self.database.insert(track: track) }
                self.extractArtwork(path: path, id: track.id)
            }
            return
        }

        let track = Track(
            id: path.pathHash,
            path: path,
            title: meta.title ?? url.deletingPathExtension().lastPathComponent,
            artist: meta.artist,
            album: meta.album,
            duration: duration,
            format: ext,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            bitrate: 0,
            fileSize: fileSize,
            dateAdded: Date(),
            playCount: 0,
            dcOffset: mastering.dc_offset_pct,
            lufs: mastering.lufs,
            truePeak: mastering.true_peak_db,
            dynamicRange: mastering.dynamic_range_db,
            phaseCorrelation: mastering.phase_correlation
        )

        DispatchQueue.main.async {
            self.database.insert(track: track)
        }
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
    }

    private func parseMetadata(json: String?) -> MetadataJSON {
        guard let json, let data = json.data(using: .utf8),
              let meta = try? JSONDecoder().decode(MetadataJSON.self, from: data) else {
            return MetadataJSON()
        }
        return meta
    }

    private func extractArtwork(path: String, id: String) {
        guard artworkCache[id] == nil else { return }
        let asset = AVAsset(url: URL(fileURLWithPath: path))
        Task {
            let metas = try? await asset.load(.commonMetadata)
            for item in metas ?? [] {
                if item.commonKey == .commonKeyArtwork, let data = try? await item.load(.value) as? Data {
                    await MainActor.run { self.artworkCache[id] = data }
                    break
                }
            }
        }
    }
}
