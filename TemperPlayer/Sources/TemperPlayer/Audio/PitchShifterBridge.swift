import Foundation
import CTemperPlayer

/// Swift wrapper around the Zig peak-locked phase vocoder pitch shifter.
/// Not thread-safe: callers must serialize access (AudioManager uses pumpQueue).
final class PitchShifterBridge {
    private let handle: UnsafeMutableRawPointer

    init?(sampleRate: Double, channels: Int) {
        guard let h = pitch_create(Float(sampleRate), Int32(channels)) else { return nil }
        handle = h
    }

    func setCents(_ cents: Float) {
        pitch_set_cents(handle, cents)
    }

    func reset() {
        pitch_reset(handle)
    }

    var latencyFrames: Int {
        Int(pitch_latency_frames(handle))
    }

    func process(
        inL: UnsafePointer<Float>?, inR: UnsafePointer<Float>?, inFrames: Int,
        outL: UnsafeMutablePointer<Float>?, outR: UnsafeMutablePointer<Float>?, outCap: Int
    ) -> Int {
        Int(pitch_process(handle, inL, inR, Int32(inFrames), outL, outR, Int32(outCap)))
    }

    func flush(
        outL: UnsafeMutablePointer<Float>?, outR: UnsafeMutablePointer<Float>?, outCap: Int
    ) -> Int {
        Int(pitch_flush(handle, outL, outR, Int32(outCap)))
    }

    deinit {
        pitch_destroy(handle)
    }
}
