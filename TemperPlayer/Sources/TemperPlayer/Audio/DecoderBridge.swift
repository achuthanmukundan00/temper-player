import Foundation
import CTemperPlayer

/// Swift wrapper around the Zig C ABI decoder
final class DecoderBridge {
    private var handle: UnsafeMutableRawPointer?

    var sampleRate: Int32 = 0
    var channels: Int32 = 0
    var bitDepth: Int32 = 0
    var durationSeconds: Double = 0

    func open(path: String) -> Bool {
        guard let h = path.withCString({ decode_open($0) }) else { return false }
        handle = h
        let info = decode_get_info(h)
        sampleRate = info.sample_rate
        channels = info.channels
        bitDepth = info.bit_depth
        durationSeconds = info.duration_seconds
        return true
    }

    func readFrames(into buffer: UnsafeMutablePointer<Float>, count: Int32) -> Int32 {
        guard let h = handle else { return -1 }
        return decode_read_frames(h, buffer, count)
    }

    func seek(frame: Int64) -> Bool {
        guard let h = handle else { return false }
        return decode_seek(h, frame) == 0
    }

    func close() {
        guard let h = handle else { return }
        decode_close(h)
        handle = nil
    }

    deinit { close() }

    static func readMetadata(path: String) -> String? {
        return path.withCString { cpath in
            guard let ptr = metadata_read(cpath) else { return nil }
            defer { metadata_free(ptr) }
            return String(cString: ptr)
        }
    }

    static func readMastering(path: String) -> MasteringInfo {
        return path.withCString { decode_get_mastering($0) }
    }
}
