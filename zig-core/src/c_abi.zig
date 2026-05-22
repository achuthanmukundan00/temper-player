const std = @import("std");
const decoder_mod = @import("decoder.zig");
const Decoder = decoder_mod.Decoder;

threadlocal var gpa_instance: std.heap.DebugAllocator(.{}) = .{};

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
    const path_slice: [:0]const u8 = std.mem.sliceTo(path, 0);
    const allocator = gpa_instance.allocator();
    const decoder = allocator.create(Decoder) catch return null;
    decoder.* = Decoder.open(allocator, path_slice) catch {
        allocator.destroy(decoder);
        return null;
    };
    return @ptrCast(decoder);
}

export fn decode_read_frames(h: *anyopaque, buf: [*]f32, frame_count: i32) i32 {
    const decoder: *Decoder = @ptrCast(@alignCast(h));
    return decoder.readFrames(buf[0..@intCast(frame_count)], frame_count);
}

export fn decode_seek(h: *anyopaque, pcm_frame: i64) i32 {
    const decoder: *Decoder = @ptrCast(@alignCast(h));
    return if (decoder.seek(pcm_frame)) 0 else -1;
}

export fn decode_close(h: *anyopaque) void {
    const allocator = gpa_instance.allocator();
    const decoder: *Decoder = @ptrCast(@alignCast(h));
    decoder.close();
    allocator.destroy(decoder);
}

export fn decode_get_info(h: *anyopaque) SampleFormat {
    const decoder: *Decoder = @ptrCast(@alignCast(h));
    return .{
        .sample_rate = decoder.sample_rate,
        .channels = decoder.channels,
        .bit_depth = decoder.bit_depth,
        .duration_seconds = @as(f64, @floatFromInt(decoder.total_pcm_frames)) / @as(f64, @floatFromInt(decoder.sample_rate)),
    };
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
