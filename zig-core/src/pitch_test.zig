const std = @import("std");
const PitchShifter = @import("pitch.zig").PitchShifter;

var shifter: PitchShifter = undefined;

fn freqOf(buf: []const f32, sr: f32) f32 {
    // zero-crossing estimate over the analysis span
    var crossings: usize = 0;
    var first: usize = 0;
    var last: usize = 0;
    for (1..buf.len) |i| {
        if (buf[i - 1] <= 0 and buf[i] > 0) {
            if (crossings == 0) first = i;
            last = i;
            crossings += 1;
        }
    }
    if (crossings < 2) return 0;
    return sr * @as(f32, @floatFromInt(crossings - 1)) / @as(f32, @floatFromInt(last - first));
}

pub fn main() !void {
    const sr: f32 = 48000;
    const n: usize = 48000;
    const alloc = std.heap.page_allocator;
    const input = try alloc.alloc(f32, n);
    const output = try alloc.alloc(f32, n);
    defer alloc.free(input);
    defer alloc.free(output);

    // --- Test 1: unity transparency ---
    for (0..n) |i| {
        input[i] = @sin(two_pi() * 1000.0 * @as(f32, @floatFromInt(i)) / sr) * 0.5;
    }
    shifter.init(sr, 1);
    shifter.setCents(0);
    var got: usize = 0;
    var fed: usize = 0;
    const chunk: usize = 512;
    while (fed < n and got < n) {
        const m = @min(chunk, n - fed);
        got += shifter.process(input.ptr + fed, null, m, output.ptr + got, null, n - got);
        fed += m;
    }
    got += shifter.flush(output.ptr + got, null, n - got);
    var max_err: f32 = 0;
    var count: usize = 0;
    // content-aligned by construction: output[i] corresponds to input[i]
    for (8192..n - 8192) |i| {
        if (i >= got) break;
        const err = @abs(output[i] - input[i]);
        max_err = @max(max_err, err);
        count += 1;
    }
    std.debug.print("unity: produced={d} compared={d} max_err={e:.3}\n", .{ got, count, max_err });

    // --- Test 2: +700 cents on 1 kHz -> expect ~1498 Hz ---
    shifter.init(sr, 1);
    shifter.setCents(700);
    got = 0;
    fed = 0;
    while (fed < n and got < n) {
        const m = @min(chunk, n - fed);
        got += shifter.process(input.ptr + fed, null, m, output.ptr + got, null, n - got);
        fed += m;
    }
    const f_in = freqOf(input[8192 .. n - 8192], sr);
    const f_out = freqOf(output[8192..@min(got, n) - 8192], sr);
    const expected = 1000.0 * std.math.exp2(@as(f32, 700.0 / 1200.0));
    std.debug.print("shift+700: in={d:.1}Hz out={d:.1}Hz expected={d:.1}Hz produced={d}\n", .{ f_in, f_out, expected, got });

    // --- Test 3: -500 cents ---
    shifter.init(sr, 1);
    shifter.setCents(-500);
    got = 0;
    fed = 0;
    while (fed < n and got < n) {
        const m = @min(chunk, n - fed);
        got += shifter.process(input.ptr + fed, null, m, output.ptr + got, null, n - got);
        fed += m;
    }
    const f_out2 = freqOf(output[8192..@min(got, n) - 8192], sr);
    const expected2 = 1000.0 * std.math.exp2(@as(f32, -500.0 / 1200.0));
    std.debug.print("shift-500: out={d:.1}Hz expected={d:.1}Hz produced={d}\n", .{ f_out2, expected2, got });

    // --- Test 4: throughput benchmark ---
    shifter.init(sr, 2);
    shifter.setCents(300);
    const t0 = nowNs();
    fed = 0;
    got = 0;
    while (fed < n) {
        const m = @min(chunk, n - fed);
        const cap = n - got;
        got += shifter.process(input.ptr + fed, input.ptr + fed, m, output.ptr + got, output.ptr + got, cap);
        fed += m;
    }
    const ns = nowNs() - t0;
    const realtime = @as(f64, @floatFromInt(n)) / 48000.0;
    const elapsed = @as(f64, @floatFromInt(ns)) / 1e9;
    std.debug.print("bench: stereo 1s processed in {d:.1}ms ({d:.0}x realtime)\n", .{ elapsed * 1000.0, realtime / elapsed });
}

fn two_pi() f32 {
    return 2.0 * std.math.pi;
}

extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;

fn nowNs() u64 {
    return clock_gettime_nsec_np(4); // CLOCK_MONOTONIC_RAW
}
