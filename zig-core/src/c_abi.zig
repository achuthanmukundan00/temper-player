const std = @import("std");

pub const SampleFormat = extern struct {
    sample_rate: i32,
    channels: i32,
    bit_depth: i32,
    duration_seconds: f64,
};

pub const MasteringInfo = extern struct {
    lufs: f64,
    true_peak_db: f64,
    peak_db: f64,
    dynamic_range_db: f64,
    phase_correlation: f64,
    dc_offset_pct: f64,
    phase_ok: i32,
};

export fn decode_open(path: [*:0]const u8) ?*anyopaque {
    _ = path;
    return null;
}

export fn decode_read_frames(h: *anyopaque, buf: [*]f32, frame_count: i32) i32 {
    _ = .{ h, buf, frame_count };
    return -1;
}

export fn decode_seek(h: *anyopaque, pcm_frame: i64) i32 {
    _ = .{ h, pcm_frame };
    return -1;
}

export fn decode_close(h: *anyopaque) void {
    _ = h;
}

export fn decode_get_info(h: *anyopaque) SampleFormat {
    _ = h;
    return .{ .sample_rate = 0, .channels = 0, .bit_depth = 0, .duration_seconds = 0 };
}

export fn metadata_read(path: [*:0]const u8) ?[*:0]u8 {
    _ = path;
    return null;
}

export fn metadata_free(ptr: [*:0]u8) void {
    _ = ptr;
}

export fn decode_get_mastering(path: [*:0]const u8) MasteringInfo {
    _ = path;
    return .{
        .lufs = 0, .true_peak_db = 0, .peak_db = 0,
        .dynamic_range_db = 0, .phase_correlation = 0,
        .dc_offset_pct = 0, .phase_ok = 0,
    };
}
