const std = @import("std");
const decoder_mod = @import("decoder.zig");
const Decoder = decoder_mod.Decoder;
const metadata_mod = @import("metadata.zig");
const mastering_mod = @import("mastering.zig");
const pitch_mod = @import("pitch.zig");

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
    if (frame_count <= 0) return 0;
    const decoder: *Decoder = @ptrCast(@alignCast(h));
    return decoder.readFrames(buf[0..@as(usize, @intCast(frame_count)) * @as(usize, @intCast(decoder.channels))], frame_count);
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
        .duration_seconds = if (decoder.sample_rate > 0)
            @as(f64, @floatFromInt(decoder.total_pcm_frames)) / @as(f64, @floatFromInt(decoder.sample_rate))
        else
            0.0,
    };
}

export fn pitch_create(sample_rate: f32, channels: i32) ?*anyopaque {
    const allocator = gpa_instance.allocator();
    const shifter = allocator.create(pitch_mod.PitchShifter) catch return null;
    shifter.init(sample_rate, @intCast(@max(1, channels)));
    return @ptrCast(shifter);
}

export fn pitch_destroy(h: *anyopaque) void {
    const allocator = gpa_instance.allocator();
    const shifter: *pitch_mod.PitchShifter = @ptrCast(@alignCast(h));
    allocator.destroy(shifter);
}

export fn pitch_set_cents(h: *anyopaque, cents: f32) void {
    const shifter: *pitch_mod.PitchShifter = @ptrCast(@alignCast(h));
    shifter.setCents(cents);
}

export fn pitch_reset(h: *anyopaque) void {
    const shifter: *pitch_mod.PitchShifter = @ptrCast(@alignCast(h));
    shifter.reset();
}

export fn pitch_latency_frames(h: *anyopaque) i32 {
    const shifter: *pitch_mod.PitchShifter = @ptrCast(@alignCast(h));
    return @intCast(shifter.latencyFrames());
}

export fn pitch_process(
    h: *anyopaque,
    in_l: ?[*]const f32,
    in_r: ?[*]const f32,
    in_frames: i32,
    out_l: ?[*]f32,
    out_r: ?[*]f32,
    out_cap: i32,
) i32 {
    const shifter: *pitch_mod.PitchShifter = @ptrCast(@alignCast(h));
    const n: usize = if (in_frames > 0) @intCast(in_frames) else 0;
    const cap: usize = if (out_cap > 0) @intCast(out_cap) else 0;
    return @intCast(shifter.process(in_l, in_r, n, out_l, out_r, cap));
}

export fn pitch_flush(h: *anyopaque, out_l: ?[*]f32, out_r: ?[*]f32, out_cap: i32) i32 {
    const shifter: *pitch_mod.PitchShifter = @ptrCast(@alignCast(h));
    const cap: usize = if (out_cap > 0) @intCast(out_cap) else 0;
    return @intCast(shifter.flush(out_l, out_r, cap));
}

export fn metadata_read(path: [*:0]const u8) ?[*:0]u8 {
    const allocator = gpa_instance.allocator();
    const path_slice: [:0]const u8 = std.mem.sliceTo(path, 0);
    const meta = metadata_mod.readMetadata(path_slice, allocator) catch return null;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    std.json.Stringify.value(meta, .{}, &aw.writer) catch return null;
    const result = aw.toOwnedSliceSentinel(0) catch return null;
    return result.ptr;
}

export fn metadata_free(ptr: [*:0]u8) void {
    const allocator = gpa_instance.allocator();
    allocator.free(std.mem.sliceTo(ptr, 0));
}

export fn decode_get_mastering(path: [*:0]const u8) MasteringInfo {
    const path_slice: [:0]const u8 = std.mem.sliceTo(path, 0);
    const m = mastering_mod.analyze(path_slice) catch return .{
        .lufs = 0, .true_peak_db = 0, .peak_db = 0,
        .dynamic_range_db = 0, .phase_correlation = 0,
        .dc_offset_pct = 0, .phase_ok = 0,
    };
    return .{
        .lufs = m.lufs,
        .true_peak_db = m.true_peak_db,
        .peak_db = m.peak_db,
        .dynamic_range_db = m.dynamic_range_db,
        .phase_correlation = m.phase_correlation,
        .dc_offset_pct = m.dc_offset_pct,
        .phase_ok = m.phase_ok,
    };
}
