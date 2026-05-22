const std = @import("std");
const wav_flac = @import("decoders/wav_flac.zig");

pub const MasteringMetrics = struct {
    lufs: f64 = 0,
    true_peak_db: f64 = 0,
    peak_db: f64 = 0,
    dynamic_range_db: f64 = 0,
    phase_correlation: f64 = 1.0,
    dc_offset_pct: f64 = 0,
    phase_ok: i32 = 1,
};

pub fn analyze(path: [:0]const u8) !MasteringMetrics {
    var decoder = try wav_flac.Decoder.open(std.heap.c_allocator, path);
    defer decoder.close();

    const channels = decoder.channels;
    const total_frames = decoder.total_pcm_frames;

    var buf: [4096]f32 = undefined;
    var total_read: i64 = 0;
    var peak: f32 = 0;
    var sum_sq: f64 = 0;
    var dc_l: f64 = 0;
    var dc_r: f64 = 0;
    var dc_n: i64 = 0;
    var corr_sum: f64 = 0;
    var sq_l: f64 = 0;
    var sq_r: f64 = 0;

    while (total_read < total_frames) {
        const remaining = @min(@as(i64, 4096), total_frames - total_read);
        const frames = decoder.readFrames(buf[0..], @intCast(remaining));
        if (frames <= 0) break;

        const samples: usize = @intCast(frames * channels);
        for (buf[0..samples]) |s| {
            const a = @abs(s);
            if (a > peak) peak = a;
            sum_sq += @as(f64, @floatCast(s)) * @as(f64, @floatCast(s));
        }

        if (channels >= 2) {
            var j: usize = 0;
            while (j < @as(usize, @intCast(frames))) : (j += 1) {
                const l = buf[j * 2];
                const r = buf[j * 2 + 1];
                dc_l += l; dc_r += r;
                corr_sum += @as(f64, @floatCast(l)) * @as(f64, @floatCast(r));
                sq_l += @as(f64, @floatCast(l)) * @as(f64, @floatCast(l));
                sq_r += @as(f64, @floatCast(r)) * @as(f64, @floatCast(r));
                dc_n += 1;
            }
        }
        total_read += frames;
    }

    if (total_read == 0) return MasteringMetrics{};

    const peak_db = if (peak > 0) 20.0 * @log10(@as(f64, @floatCast(peak))) else -100.0;
    const rms = @sqrt(sum_sq / @as(f64, @floatFromInt(total_read * channels)));
    const lufs = if (rms > 0) 20.0 * @log10(rms) else -100.0;
    const dyn_range = peak_db - lufs;

    var corr: f64 = 1.0;
    if (channels >= 2 and dc_n > 0) {
        const lrms = @sqrt(sq_l / @as(f64, @floatFromInt(dc_n)));
        const rrms = @sqrt(sq_r / @as(f64, @floatFromInt(dc_n)));
        corr = if (lrms > 0 and rrms > 0) corr_sum / @as(f64, @floatFromInt(dc_n)) / (lrms * rrms) else 1.0;
        corr = @max(-1.0, @min(1.0, corr));
    }

    const dc_offset = if (channels >= 2 and dc_n > 0) ((dc_l + dc_r) / 2.0) / @as(f64, @floatFromInt(dc_n)) else 0;

    return MasteringMetrics{
        .lufs = lufs,
        .true_peak_db = peak_db,
        .peak_db = peak_db,
        .dynamic_range_db = dyn_range,
        .phase_correlation = corr,
        .dc_offset_pct = dc_offset * 100.0,
        .phase_ok = if (@abs(corr) > 0.5) 1 else 0,
    };
}
