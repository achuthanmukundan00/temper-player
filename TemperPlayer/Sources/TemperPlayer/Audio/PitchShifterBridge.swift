import Foundation
import CTemperPlayer

/// Swift wrapper around the Zig peak-locked phase vocoder pitch shifter.
/// Not thread-safe: callers must serialize access (AudioManager uses pumpQueue).
final class PitchShifterBridge {
    private var handle: UnsafeMutableRawPointer?

    init?(sampleRate: Double, channels: Int) {
        guard let h = pitch_create(Float(sampleRate), Int32(channels)) else { return nil }
        handle = h
    }

    /// Must be called before the instance is released.  Safe to call more than once.
    func destroy() {
        guard let h = handle else { return }
        pitch_destroy(h)
        handle = nil
    }

    deinit {
        if let h = handle {
            pitch_destroy(h)
        }
    }

    func setCents(_ cents: Float) {
        guard let h = handle else { return }
        pitch_set_cents(h, cents)
    }

    func reset() {
        guard let h = handle else { return }
        pitch_reset(h)
    }

    var latencyFrames: Int {
        guard let h = handle else { return 0 }
        return Int(pitch_latency_frames(h))
    }

    func process(
        inL: UnsafePointer<Float>?, inR: UnsafePointer<Float>?, inFrames: Int,
        outL: UnsafeMutablePointer<Float>?, outR: UnsafeMutablePointer<Float>?, outCap: Int
    ) -> Int {
        guard let h = handle else { return 0 }
        return Int(pitch_process(h, inL, inR, Int32(inFrames), outL, outR, Int32(outCap)))
    }

    func flush(
        outL: UnsafeMutablePointer<Float>?, outR: UnsafeMutablePointer<Float>?, outCap: Int
    ) -> Int {
        guard let h = handle else { return 0 }
        return Int(pitch_flush(h, outL, outR, Int32(outCap)))
    }
}
