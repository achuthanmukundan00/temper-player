import SwiftUI
import UniformTypeIdentifiers
import CTemperPlayer

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

class ImportService {
    static let shared = ImportService()

    private let supportedExtensions: Set<String> = ["flac", "wav", "mp3", "m4a", "aac"]

    func importTrack(url: URL) {
        let path = url.path
        let ext = url.pathExtension.lowercased()

        guard supportedExtensions.contains(ext) else { return }

        let fileManager = FileManager.default
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? Int else { return }

        // Read metadata from Zig
        let metaJSON = DecoderBridge.readMetadata(path: path)
        let meta = parseMetadata(json: metaJSON)

        // Read mastering metrics
        let mastering = DecoderBridge.readMastering(path: path)

        // Open decoder for duration + format info
        let decoder = DecoderBridge()
        guard decoder.open(path: path) else { return }
        decoder.close()

        let track = Track(
            id: path.pathHash,
            path: path,
            title: meta.title ?? url.deletingPathExtension().lastPathComponent,
            artist: meta.artist,
            album: meta.album,
            duration: decoder.durationSeconds,
            format: ext,
            sampleRate: Int(decoder.sampleRate),
            bitDepth: Int(decoder.bitDepth),
            channels: Int(decoder.channels),
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
    }

    private weak var database: Database!

    func setDatabase(_ db: Database) {
        database = db
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
}
