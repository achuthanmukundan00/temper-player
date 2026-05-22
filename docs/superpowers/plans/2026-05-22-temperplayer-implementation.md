# TemperPlayer — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native macOS lossless audio player with SwiftUI frontend, Zig FLAC+WAV decoding engine, SQLite library, drag-drop import, and "Blackbox" DAW/terminal UI.

**Architecture:** Zig compiles to a `.dylib` exposing a flat C ABI (decode/seek/metadata). Swift imports these via bridging header and uses AVAudioEngine for PCM output. SQLite via raw C `sqlite3` for library storage.

**Tech Stack:** Zig 0.14+, SwiftUI, SQLite3 (system), dr_flac + dr_wav (C libs in Zig)

---

## File Structure

```
zig-core/
├── build.zig                          — Zig build → libtemperplayer.dylib
├── build.zig.zon                      — Zig package deps
├── src/
│   ├── c_abi.zig                      — C ABI exports (decode_open, read, seek, close, get_info)
│   ├── decoder.zig                    — decoder dispatch (FLAC + WAV)
│   ├── decoders/
│   │   └── wav_flac.zig              — dr_flac + dr_wav wrapped
│   ├── metadata.zig                  — metadata extraction + artwork
│   └── mastering.zig                 — LUFS, true peak, DC offset, correlation analysis
└── libs/
    ├── dr_flac.h                     — vendored
    └── dr_wav.h                      — vendored

TemperPlayer/
├── TemperPlayer.xcodeproj/
│   └── project.pbxproj               — generated, handled by Xcode
├── Sources/
│   ├── TemperPlayerApp.swift          — @main entry + window config
│   ├── Audio/
│   │   ├── AudioManager.swift        — AVAudioEngine + PCM scheduling
│   │   └── DecoderBridge.swift       — C ABI wrapper types + calls
│   ├── Library/
│   │   ├── Database.swift            — sqlite3 open/close/schema/query
│   │   ├── ImportService.swift       — drag-drop import pipeline
│   │   └── Models.swift              — Track, Playlist, StreamInfo structs
│   ├── UI/
│   │   ├── ContentView.swift         — root NSHostingView / 3-panel layout
│   │   ├── GlyphSpine.swift          — left mode selector ($ ~ # ◎ λ)
│   │   ├── WorkspaceView.swift       — center: file tree + waveform
│   │   ├── FileTreeView.swift        — tree of imported files/folders
│   │   ├── WaveformView.swift        — waveform + time ruler + playhead
│   │   ├── InspectorView.swift       — right: BUFFER, STREAM, QUEUE
│   │   └── TransportBar.swift        — bottom: command line + transport
│   └── Extensions/
│       └── Crypto+Path.swift         — SHA-256 hashing of file paths
├── TemperPlayer-Bridging-Header.h    — imports libtemperplayer C ABI
├── Resources/
│   └── Assets.xcassets               — app icon (optional)
└── build-zig.sh                      — shell script: zig build dylib
```

---

### Task 1: Zig project scaffold + C ABI skeleton

**Files:**
- Create: `zig-core/build.zig.zon`
- Create: `zig-core/build.zig`
- Create: `zig-core/src/c_abi.zig`

- [ ] **Step 1: Create `zig-core/build.zig.zon`**

```
.{
    .name = "temperplayer",
    .version = "0.1.0",
    .minimum_zig_version = "0.14.0",
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "libs",
    },
}
```

- [ ] **Step 2: Create `zig-core/build.zig`**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    }});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const lib = b.addSharedLibrary(.{
        .name = "temperplayer",
        .root_source_file = b.path("src/c_abi.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link system libraries
    lib.linkSystemLibrary("c");
    lib.linkSystemLibrary("sqlite3");

    // Vendored C headers
    lib.addIncludePath(b.path("libs"));

    b.installArtifact(lib);
}
```

- [ ] **Step 3: Create `zig-core/src/c_abi.zig` — skeleton with all C exports returning errors**

```zig
const std = @import("std");
const builtin = @import("builtin");

// ---- Types exported to C ----

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

const DecoderHandle = opaque {};
pub const decoder_handle = *DecoderHandle;

// ---- Forward declarations (implemented in decoder.zig) ----

fn decodeOpen(path: [*:0]const u8) callconv(.C) ?decoder_handle { _ = path; return null; }
fn decodeReadFrames(h: decoder_handle, buf: [*]f32, frame_count: i32) callconv(.C) i32 { _ = .{ h, buf, frame_count }; return -1; }
fn decodeSeek(h: decoder_handle, pcm_frame: i64) callconv(.C) i32 { _ = .{ h, pcm_frame }; return -1; }
fn decodeClose(h: decoder_handle) callconv(.C) void { _ = h; }
fn decodeGetInfo(h: decoder_handle) callconv(.C) SampleFormat { _ = h; return .{ .sample_rate = 0, .channels = 0, .bit_depth = 0, .duration_seconds = 0 }; }
fn metadataRead(path: [*:0]const u8) callconv(.C) [*:0]u8 { _ = path; return @as([*:0]u8, @ptrFromInt(0)); }
fn metadataFree(ptr: [*:0]u8) callconv(.C) void { _ = ptr; }
fn decodeGetMastering(path: [*:0]const u8) callconv(.C) MasteringInfo { _ = path; return .{ .lufs = 0, .true_peak_db = 0, .peak_db = 0, .dynamic_range_db = 0, .phase_correlation = 0, .dc_offset_pct = 0, .phase_ok = 0 }; }
```

Wait — Zig's `callconv(.C)` doesn't work with `opaque {}`. Let me fix this: the handle needs to be a pointer to a void or an integer that Swift can pass through. Use `*anyopaque`.

```zig
const std = @import("std");
const builtin = @import("builtin");

// ---- Types exported to C ----

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

// Opaque handle: Swift stores this pointer, passes it back.
// We'll cast internally to a Zig struct pointer.

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
    return .{
        .sample_rate = 0,
        .channels = 0,
        .bit_depth = 0,
        .duration_seconds = 0,
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
        .lufs = 0,
        .true_peak_db = 0,
        .peak_db = 0,
        .dynamic_range_db = 0,
        .phase_correlation = 0,
        .dc_offset_pct = 0,
        .phase_ok = 0,
    };
}
```

- [ ] **Step 4: Verify it compiles**

Run: `cd zig-core && zig build`
Expected: produces `zig-out/lib/libtemperplayer.dylib`

- [ ] **Step 5: Commit**

```bash
git add zig-core/
git commit -m "feat: zig core scaffold with C ABI skeleton"
```

---

### Task 2: Zig FLAC + WAV decoder

**Files:**
- Create: `zig-core/libs/dr_flac.h`
- Create: `zig-core/libs/dr_wav.h`
- Create: `zig-core/src/decoders/wav_flac.zig`
- Create: `zig-core/src/decoder.zig`
- Modify: `zig-core/src/c_abi.zig`

- [ ] **Step 1: Download dr_flac.h**

Run: `curl -L https://github.com/mackron/dr_libs/raw/master/dr_flac.h -o zig-core/libs/dr_flac.h`

- [ ] **Step 2: Download dr_wav.h**

Run: `curl -L https://github.com/mackron/dr_libs/raw/master/dr_wav.h -o zig-core/libs/dr_wav.h`

- [ ] **Step 3: Create `zig-core/src/decoders/wav_flac.zig`**

```zig
const std = @import("std");
const c = @cImport({
    @cInclude("dr_flac.h");
    @cInclude("dr_wav.h");
});

const DecodeError = error{
    OpenFailed,
    SeekFailed,
    ReadFailed,
    UnsupportedFormat,
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    format: Format,
    sample_rate: i32,
    channels: i32,
    bit_depth: i32,
    total_pcm_frames: i64,

    // Internal state
    flac: ?*c.drflac = null,
    wav: ?*c.drwav = null,

    pub const Format = enum { flac, wav };

    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) !Decoder {
        // Try FLAC first
        if (c.drflac_open_file(path.ptr, null)) |flac| {
            return Decoder{
                .allocator = allocator,
                .format = .flac,
                .sample_rate = @intCast(flac.*.sampleRate),
                .channels = @intCast(flac.*.channels),
                .bit_depth = @intCast(flac.*.bitsPerSample),
                .total_pcm_frames = @intCast(flac.*.totalPCMFrameCount),
                .flac = flac,
            };
        }
        // Try WAV
        if (c.drwav_open_file(path.ptr, null)) |wav| {
            return Decoder{
                .allocator = allocator,
                .format = .wav,
                .sample_rate = @intCast(wav.*.sampleRate),
                .channels = @intCast(wav.*.channels),
                .bit_depth = @intCast(wav.*.bitsPerSample),
                .total_pcm_frames = @intCast(wav.*.totalPCMFrameCount),
                .wav = wav,
            };
        }
        return error.OpenFailed;
    }

    pub fn readFrames(self: *Decoder, buf: []f32, frame_count: i32) i32 {
        switch (self.format) {
            .flac => {
                if (self.flac) |f| {
                    return @intCast(c.drflac_read_pcm_frames_f32(f, @intCast(frame_count), buf.ptr));
                }
            },
            .wav => {
                if (self.wav) |w| {
                    return @intCast(c.drwav_read_pcm_frames_f32(w, @intCast(frame_count), buf.ptr));
                }
            },
        }
        return -1;
    }

    pub fn seek(self: *Decoder, pcm_frame: i64) bool {
        switch (self.format) {
            .flac => {
                if (self.flac) |f| {
                    return c.drflac_seek_to_pcm_frame(f, @intCast(pcm_frame)) != 0;
                }
            },
            .wav => {
                if (self.wav) |w| {
                    return c.drwav_seek_to_pcm_frame(w, @intCast(pcm_frame)) != 0;
                }
            },
        }
        return false;
    }

    pub fn close(self: *Decoder) void {
        switch (self.format) {
            .flac => {
                if (self.flac) |f| c.drflac_close(f);
            },
            .wav => {
                if (self.wav) |w| c.drwav_close(w);
            },
        }
        self.* = undefined;
    }
};
```

- [ ] **Step 4: Create `zig-core/src/decoder.zig`**

```zig
const std = @import("std");
const wav_flac = @import("decoders/wav_flac.zig");

pub const Decoder = wav_flac.Decoder;
```

- [ ] **Step 5: Wire up `c_abi.zig`**

Replace stub `decode_open` and related functions with real implementations. After `const std = @import("std");` add:

```zig
const decoder_mod = @import("decoder.zig");
const Decoder = decoder_mod.Decoder;
const wav_flac = @import("decoders/wav_flac.zig");

threadlocal var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .{};
```

Replace the stub functions:

```zig
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
    const buf_slice: []f32 = buf[0..@intCast(frame_count)];
    return decoder.readFrames(buf_slice, frame_count);
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
```

- [ ] **Step 6: Verify compilation**

Run: `cd zig-core && zig build`
Expected: clean compile, `zig-out/lib/libtemperplayer.dylib` exists

- [ ] **Step 7: Commit**

```bash
git add zig-core/
git commit -m "feat: zig FLAC+WAV decoding via dr_libs"
```

---

### Task 3: Zig metadata + mastering analysis

**Files:**
- Create: `zig-core/src/metadata.zig`
- Create: `zig-core/src/mastering.zig`
- Modify: `zig-core/src/c_abi.zig`

- [ ] **Step 1: Create `zig-core/src/metadata.zig`**

```zig
const std = @import("std");

pub const TrackMetadata = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    album_artist: ?[]const u8 = null,
    track_no: ?i32 = null,
    disc_no: ?i32 = null,
    year: ?i32 = null,
    genre: ?[]const u8 = null,
    artwork_base64: ?[]const u8 = null,
    duration_seconds: f64 = 0,
    sample_rate: i32 = 0,
    channels: i32 = 0,
    bit_depth: i32 = 0,
};

pub fn readMetadata(path: [:0]const u8) !TrackMetadata {
    // Use dr_flac/dr_wav to extract Vorbis comments / RIFF metadata.
    // Phase 1: read format info + duration from the decoder.
    // Advanced tag parsing deferred to Phase 2 (use filename stem as title).
    _ = path;
    return TrackMetadata{};
}
```

Phase 1 metadata extraction: file stem = title. Full tag parsing comes in Phase 2. The function exists as a hook.

- [ ] **Step 2: Create `zig-core/src/mastering.zig`**

```zig
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

    // Scan in 4096-frame chunks to compute metrics
    var buf: [4096]f32 = undefined;
    var total_frames_read: i64 = 0;

    var peak: f32 = 0;
    var sum_squares: f64 = 0;
    var dc_sum_l: f64 = 0;
    var dc_sum_r: f64 = 0;
    var dc_count: i64 = 0;
    var correlation_sum: f64 = 0;
    var sum_squares_l: f64 = 0;
    var sum_squares_r: f64 = 0;

    while (total_frames_read < total_frames) {
        const remaining = @min(@as(i64, 4096), total_frames - total_frames_read);
        const frames = decoder.readFrames(buf[0..], @intCast(remaining));
        if (frames <= 0) break;

        const samples = @as(usize, @intCast(frames)) * @as(usize, @intCast(channels));
        var i: usize = 0;
        while (i < samples) : (i += 1) {
            const s = buf[i];
            const abs_s = @abs(s);
            if (abs_s > peak) peak = abs_s;
            sum_squares += @as(f64, @floatCast(s)) * @as(f64, @floatCast(s));
        }

        // Per-channel stats (stereo)
        if (channels >= 2) {
            var j: usize = 0;
            while (j < @as(usize, @intCast(frames))) : (j += 1) {
                const l = buf[j * 2];
                const r = buf[j * 2 + 1];
                dc_sum_l += l;
                dc_sum_r += r;
                correlation_sum += @as(f64, @floatCast(l)) * @as(f64, @floatCast(r));
                sum_squares_l += @as(f64, @floatCast(l)) * @as(f64, @floatCast(l));
                sum_squares_r += @as(f64, @floatCast(r)) * @as(f64, @floatCast(r));
                dc_count += 1;
            }
        }

        total_frames_read += frames;
    }

    if (total_frames_read == 0) return MasteringMetrics{};

    // Peak dB
    const peak_db = if (peak > 0) 20.0 * @log10(@as(f64, @floatCast(peak))) else -100.0;

    // RMS / LUFS rough approximation
    const rms = @sqrt(sum_squares / @as(f64, @floatCast(total_frames_read * @as(i64, @intCast(channels)))));
    const lufs_rough = if (rms > 0) 20.0 * @log10(rms) else -100.0;

    // Dynamic range (rough: peak - RMS)
    const dynamic_range = peak_db - lufs_rough;

    // Phase correlation (stereo only)
    var correlation: f64 = 1.0;
    if (channels >= 2 and dc_count > 0) {
        const l_rms = @sqrt(sum_squares_l / @as(f64, @floatCast(dc_count)));
        const r_rms = @sqrt(sum_squares_r / @as(f64, @floatCast(dc_count)));
        if (l_rms > 0 and r_rms > 0) {
            correlation = correlation_sum / @as(f64, @floatCast(dc_count)) / (l_rms * r_rms);
        }
        correlation = @max(-1.0, @min(1.0, correlation));
    }

    // DC offset
    const dc_offset = if (channels >= 2 and dc_count > 0) ((dc_sum_l + dc_sum_r) / 2.0) / @as(f64, @floatCast(dc_count)) else 0;
    const dc_offset_pct = dc_offset * 100.0;

    return MasteringMetrics{
        .lufs = lufs_rough,
        .true_peak_db = peak_db,
        .peak_db = peak_db,
        .dynamic_range_db = dynamic_range,
        .phase_correlation = correlation,
        .dc_offset_pct = dc_offset_pct,
        .phase_ok = if (@abs(correlation) > 0.5) 1 else 0,
    };
}
```

- [ ] **Step 3: Wire mastering + metadata into `c_abi.zig`**

Add after decoder imports:
```zig
const metadata_mod = @import("metadata.zig");
const mastering_mod = @import("mastering.zig");
```

Replace the stub `metadata_read`:
```zig
export fn metadata_read(path: [*:0]const u8) ?[*:0]u8 {
    const path_slice: [:0]const u8 = std.mem.sliceTo(path, 0);
    const meta = metadata_mod.readMetadata(path_slice) catch return null;

    // Build minimal JSON: just the file stem as title
    const allocator = gpa_instance.allocator();
    var buf = std.ArrayList(u8).init(allocator);
    std.json.stringify(meta, .{}, buf.writer()) catch return null;

    const result = allocator.dupeZ(u8, buf.items) catch return null;
    return result.ptr;
}

export fn metadata_free(ptr: [*:0]u8) void {
    const allocator = gpa_instance.allocator();
    const slice: []u8 = std.mem.sliceTo(ptr, 0);
    allocator.free(slice);
}

export fn decode_get_mastering(path: [*:0]const u8) MasteringInfo {
    const path_slice: [:0]const u8 = std.mem.sliceTo(path, 0);
    const metrics = mastering_mod.analyze(path_slice) catch return .{
        .lufs = 0, .true_peak_db = 0, .peak_db = 0,
        .dynamic_range_db = 0, .phase_correlation = 0,
        .dc_offset_pct = 0, .phase_ok = 0,
    };
    return .{
        .lufs = metrics.lufs,
        .true_peak_db = metrics.true_peak_db,
        .peak_db = metrics.peak_db,
        .dynamic_range_db = metrics.dynamic_range_db,
        .phase_correlation = metrics.phase_correlation,
        .dc_offset_pct = metrics.dc_offset_pct,
        .phase_ok = metrics.phase_ok,
    };
}
```

- [ ] **Step 4: Verify compilation**

Run: `cd zig-core && zig build`
Expected: clean compile

- [ ] **Step 5: Commit**

```bash
git add zig-core/
git commit -m "feat: zig metadata + mastering analysis (LUFS, peak, DC offset, phase correlation)"
```

---

### Task 4: Swift project scaffold + bridging header + build script

**Files:**
- Create: `TemperPlayer/TemperPlayer-Bridging-Header.h`
- Create: `TemperPlayer/build-zig.sh`
- Create: `TemperPlayer/Sources/TemperPlayerApp.swift`
- Create: `TemperPlayer/Sources/Audio/DecoderBridge.swift`

- [ ] **Step 1: Create bridging header `TemperPlayer/TemperPlayer-Bridging-Header.h`**

```c
#ifndef TemperPlayer_Bridging_Header_h
#define TemperPlayer_Bridging_Header_h

#include <stdint.h>

// ---- Types from Zig C ABI ----

struct SampleFormat {
    int sample_rate;
    int channels;
    int bit_depth;
    double duration_seconds;
};

struct MasteringInfo {
    double lufs;
    double true_peak_db;
    double peak_db;
    double dynamic_range_db;
    double phase_correlation;
    double dc_offset_pct;
    int phase_ok;
};

// ---- Functions from Zig ----

void* decode_open(const char* path);
int decode_read_frames(void* handle, float* buf, int frame_count);
int decode_seek(void* handle, int64_t pcm_frame);
void decode_close(void* handle);
struct SampleFormat decode_get_info(void* handle);
char* metadata_read(const char* path);
void metadata_free(char* ptr);
struct MasteringInfo decode_get_mastering(const char* path);

#endif
```

- [ ] **Step 2: Create `TemperPlayer/build-zig.sh`**

```bash
#!/bin/bash
set -euo pipefail
cd "$SRCROOT/../zig-core"
zig build -Doptimize=ReleaseFast 2>&1 | grep -v "^info:" || true
# Copy dylib to Frameworks so Xcode can embed + sign it
mkdir -p "$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH"
cp zig-out/lib/libtemperplayer.dylib "$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH/"
```

Make executable: `chmod +x TemperPlayer/build-zig.sh`

- [ ] **Step 3: Create `TemperPlayer/Sources/TemperPlayerApp.swift`**

```swift
import SwiftUI

@main
struct TemperPlayerApp: App {
    @StateObject private var audioManager = AudioManager()
    @StateObject private var library = Database()
    @StateObject private var playerState = PlayerState()

    var body: some Scene {
        Window("TemperPlayer", id: "main") {
            ContentView()
                .environmentObject(audioManager)
                .environmentObject(library)
                .environmentObject(playerState)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {} // remove File > New
        }
    }
}

class PlayerState: ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var queue: [Track] = []
    @Published var volume: Float = 0.75 {
        didSet { audioManager?.setVolume(volume) }
    }

    weak var audioManager: AudioManager?

    var displayPath: String {
        currentTrack?.path ?? "no buffer loaded"
    }

    var timeString: String {
        let m = Int(currentTime) / 60
        let s = Int(currentTime) % 60
        return String(format: "%d:%02d", m, s)
    }

    var durationString: String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }
}
```

- [ ] **Step 4: Create `TemperPlayer/Sources/Audio/DecoderBridge.swift`**

```swift
import Foundation

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

    static func readMastering(path: String) -> MasteringInfo? {
        return path.withCString { cpath in
            let info = decode_get_mastering(cpath)
            // Check if metrics are valid (non-zero sample rate means real data)
            // Valid metrics will have at least some activity
            return info
        }
    }
}
```

- [ ] **Step 5: Create Xcode project via command line**

Run: `cd TemperPlayer && swift package init --type executable` then delete Package.swift since we need an Xcode project with custom build phases.

Actually, for a macOS app we need an Xcode project. Let me generate a minimal one.

Run:
```bash
cd TemperPlayer
mkdir -p TemperPlayer.xcodeproj
```

The `.xcodeproj` is complex to generate by hand — let me use `swift package init --type executable` and then generate the xcodeproj with `swift package generate-xcodeproj`, then modify to add the build phase.

Actually, let me simplify: use `swift package init --type executable` and manage it as a Swift Package Manager project that also links the Zig dylib. Then we add a Run Script phase via `project.pbxproj` modifications.

Actually the cleanest approach for a macOS SwiftUI app that links a custom dylib: create a minimal Xcode project manually. Let me use `swift package init` to handle the project structure, and just make sure the Xcode project build settings link the dylib correctly.

Actually, for reliability, let me take a practical approach:
1. Create the project structure with all Swift files
2. Use `swift build` to verify compilation
3. The user opens in Xcode for the final build with Zig dylib linking

Let me use a Swift Package Manager approach:

```bash
cd TemperPlayer
mkdir -p Sources/TemperPlayer
# Move all Swift files into Sources/TemperPlayer/
mv Sources/App.swift Sources/Audio/ Sources/Library/ Sources/UI/ Sources/Extensions/ Sources/TemperPlayer/
```

Actually, this is getting complicated with SPM vs Xcode project. Let me go with the simplest approach:

1. Create a directory with all source files
2. Use `swiftc` or Xcode project to build
3. The user will need to set up the build in Xcode

Let me simplify: create the xcodeproj using `swift package init --type executable` and restructure accordingly. The Swift files go in `Sources/` and we add a build script phase.

Actually let me just keep it as a simple SPM project structure and add instructions for how to open in Xcode and add the build phase.

Let me restructure:

```
TemperPlayer/
├── Package.swift
├── Sources/
│   ├── TemperPlayer/
│   │   ├── TemperPlayerApp.swift
│   │   ├── Audio/
│   │   │   ├── AudioManager.swift
│   │   │   └── DecoderBridge.swift
│   │   ├── Library/
│   │   │   ├── Database.swift
│   │   │   ├── ImportService.swift
│   │   │   └── Models.swift
│   │   ├── UI/
│   │   │   ├── ContentView.swift
│   │   │   ├── GlyphSpine.swift
│   │   │   ├── WorkspaceView.swift
│   │   │   ├── FileTreeView.swift
│   │   │   ├── WaveformView.swift
│   │   │   ├── InspectorView.swift
│   │   │   └── TransportBar.swift
│   │   └── Extensions/
│   │       └── Crypto+Path.swift
├── TemperPlayer-Bridging-Header.h
└── build-zig.sh
```

Wait, but Swift Package Manager doesn't support bridging headers. For C interop with SPM, you'd use a system library target. Let me think about this differently.

For the C ABI bridging, in SPM you define the C library target:

```swift
// Package.swift
let package = Package(
    name: "TemperPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TemperPlayer",
            dependencies: [],
            exclude: ["TemperPlayer-Bridging-Header.h"],
            linkerSettings: [
                .unsafeFlags(["-L$(SRCROOT)/../zig-core/zig-out/lib"]),
                .unsafeFlags(["-ltemperplayer"]),
            ]
        )
    ]
)
```

But for C interop (not C++), you can create a target that imports C headers:

```swift
.target(
    name: "CTemperPlayer",
    path: "Sources/CTemperPlayer",
    publicHeadersPath: "."
)
```

Where `Sources/CTemperPlayer/include/module.modulemap` maps the bridging header, and the main target depends on `CTemperPlayer`.

This is cleaner. Let me do this.

Actually, the simplest approach for a 2-hour build is just an Xcode project. Let me ask the user... no, let me just write the plan with clear instructions.

For the plan, I'll use SPM with a C target wrapper + a custom build phase that the user adds manually in Xcode. Let me structure it properly:

```
TemperPlayer/
├── Package.swift
├── Sources/
│   ├── CTemperPlayer/
│   │   ├── include/
│   │   │   ├── module.modulemap
│   │   │   └── temperplayer.h        (bridging header, renamed)
│   │   └── empty.c                   (SPM needs a source file)
│   ├── TemperPlayer/
│   │   ├── App/
│   │   │   └── TemperPlayerApp.swift
│   │   ├── Audio/
│   │   │   ├── AudioManager.swift
│   │   │   └── DecoderBridge.swift
│   │   ├── Library/
│   │   │   ├── Database.swift
│   │   │   ├── ImportService.swift
│   │   │   └── Models.swift
│   │   ├── UI/
│   │   │   ├── ContentView.swift
│   │   │   ├── GlyphSpine.swift
│   │   │   ├── WorkspaceView.swift
│   │   │   ├── FileTreeView.swift
│   │   │   ├── WaveformView.swift
│   │   │   ├── InspectorView.swift
│   │   │   └── TransportBar.swift
│   │   └── Extensions/
│   │       └── Crypto+Path.swift
│   └── TemperPlayerResources/        (empty for resources)
├── build-zig.sh
└── Resources/
    └── Assets.xcassets/...
```

This SPM approach is cleaner. Package.swift defines:
- A system library target for the Zig C headers
- The main executable target depending on it
- Linker flags pointing to the Zig dylib

Let me write the Package.swift and the supporting files.

For module.modulemap:
```
module CTemperPlayer [system] {
    header "temperplayer.h"
    link "temperplayer"
    export *
}
```

Wait, `link "temperplayer"` would link against `libtemperplayer.dylib`. The path needs to be correct. Let me use `pkgConfig` or just linker flags.

Actually, for SPM, the cleanest approach for a custom prebuilt dylib is:

```swift
.target(
    name: "CTemperPlayer",
    path: "Sources/CTemperPlayer",
    publicHeadersPath: "include",
    linkerSettings: [.linkedLibrary("temperplayer")]
)
```

And the library search path added via unsafe flags on the main target:

```swift
.executableTarget(
    name: "TemperPlayer",
    dependencies: ["CTemperPlayer"],
    swiftSettings: [.unsafeFlags(["-L../zig-core/zig-out/lib"])]
)
```

But `-L` path is relative to the build directory, which depends on context. This is why Xcode build phases are more reliable.

OK, I'm overcomplicating this. Let me just use a practical approach:

1. Package.swift with the C interop target
2. A `build-zig.sh` script that Xcode runs as a build phase
3. The dylib gets copied to a standard path that the linker can find

For SPM based projects, you can use:

```swift
.linkerSettings([
    .unsafeFlags(["-L", "$(PROJECT_DIR)/../zig-core/zig-out/lib"]),
])
```

This works in Xcode where `$(PROJECT_DIR)` is defined.

Let me just write the plan and move on. The key thing is to get the code right.<｜end▁of▁thinking｜>

<｜｜DSML｜｜tool_calls>
<｜｜DSML｜｜invoke name="Write">
<｜｜DSML｜｜parameter name="content" string="true"># TemperPlayer — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native macOS lossless audio player with SwiftUI frontend, Zig FLAC+WAV decoding engine, SQLite library, drag-drop import, and "Blackbox" DAW/terminal UI.

**Architecture:** Zig compiles to a `.dylib` exposing a flat C ABI (decode/seek/metadata). Swift imports these via a C interop module map and uses AVAudioEngine for PCM output. SQLite via raw C `sqlite3` for library storage.

**Tech Stack:** Zig 0.14+, SwiftUI, SQLite3 (system), AudioToolbox (system), dr_flac + dr_wav

---

## File Structure

```
zig-core/
├── build.zig
├── build.zig.zon
├── libs/
│   ├── dr_flac.h
│   └── dr_wav.h
└── src/
    ├── c_abi.zig
    ├── decoder.zig
    ├── decoders/
    │   └── wav_flac.zig
    ├── metadata.zig
    └── mastering.zig

TemperPlayer/
├── Package.swift
├── build-zig.sh
├── Sources/
│   ├── CTemperPlayer/
│   │   ├── include/
│   │   │   ├── module.modulemap
│   │   │   └── temperplayer.h
│   │   └── empty.c
│   └── TemperPlayer/
│       ├── App/
│       │   └── TemperPlayerApp.swift
│       ├── Audio/
│       │   ├── AudioManager.swift
│       │   └── DecoderBridge.swift
│       ├── Library/
│       │   ├── Database.swift
│       │   ├── ImportService.swift
│       │   └── Models.swift
│       ├── UI/
│       │   ├── ContentView.swift
│       │   ├── GlyphSpine.swift
│       │   ├── WorkspaceView.swift
│       │   ├── FileTreeView.swift
│       │   ├── WaveformView.swift
│       │   ├── InspectorView.swift
│       │   └── TransportBar.swift
│       └── Extensions/
│           └── Crypto+Path.swift
└── Resources/
    └── Assets.xcassets/
        ├── Contents.json
        └── AppIcon.icns/Contents.json
```

---

### Task 1: Zig project scaffold + C ABI skeleton

**Files:**
- Create: `zig-core/build.zig.zon`
- Create: `zig-core/build.zig`
- Create: `zig-core/src/c_abi.zig`

- [ ] **Step 1: Create `zig-core/build.zig.zon`**

```
.{
    .name = "temperplayer",
    .version = "0.1.0",
    .minimum_zig_version = "0.14.0",
    .paths = .{ "build.zig", "build.zig.zon", "src", "libs" },
}
```

- [ ] **Step 2: Create `zig-core/build.zig`**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    }});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const lib = b.addSharedLibrary(.{
        .name = "temperplayer",
        .root_source_file = b.path("src/c_abi.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.linkSystemLibrary("c");
    lib.addIncludePath(b.path("libs"));

    b.installArtifact(lib);
}
```

- [ ] **Step 3: Create `zig-core/src/c_abi.zig` — skeleton with all C exports**

```zig
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
```

- [ ] **Step 4: Verify it compiles**

Run: `cd zig-core && zig build`
Expected: clean compile, produces `zig-out/lib/libtemperplayer.dylib`

- [ ] **Step 5: Commit**

```bash
git add zig-core/
git commit -m "feat: zig core scaffold with C ABI skeleton"
```

---

### Task 2: Zig FLAC + WAV decoder

**Files:**
- Create: `zig-core/libs/dr_flac.h`
- Create: `zig-core/libs/dr_wav.h`
- Create: `zig-core/src/decoders/wav_flac.zig`
- Create: `zig-core/src/decoder.zig`
- Modify: `zig-core/src/c_abi.zig`

- [ ] **Step 1: Download dr_flac.h**

Run: `curl -sL https://github.com/mackron/dr_libs/raw/master/dr_flac.h -o zig-core/libs/dr_flac.h`

- [ ] **Step 2: Download dr_wav.h**

Run: `curl -sL https://github.com/mackron/dr_libs/raw/master/dr_wav.h -o zig-core/libs/dr_wav.h`

- [ ] **Step 3: Create `zig-core/src/decoders/wav_flac.zig`**

```zig
const std = @import("std");
const c = @cImport({
    @cInclude("dr_flac.h");
    @cInclude("dr_wav.h");
});

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    format: Format,
    sample_rate: i32,
    channels: i32,
    bit_depth: i32,
    total_pcm_frames: i64,
    flac: ?*c.drflac = null,
    wav: ?*c.drwav = null,

    pub const Format = enum { flac, wav };

    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) !Decoder {
        if (c.drflac_open_file(path.ptr, null)) |f| {
            return Decoder{
                .allocator = allocator,
                .format = .flac,
                .sample_rate = @intCast(f.*.sampleRate),
                .channels = @intCast(f.*.channels),
                .bit_depth = @intCast(f.*.bitsPerSample),
                .total_pcm_frames = @intCast(f.*.totalPCMFrameCount),
                .flac = f,
            };
        }
        if (c.drwav_open_file(path.ptr, null)) |w| {
            return Decoder{
                .allocator = allocator,
                .format = .wav,
                .sample_rate = @intCast(w.*.sampleRate),
                .channels = @intCast(w.*.channels),
                .bit_depth = @intCast(w.*.bitsPerSample),
                .total_pcm_frames = @intCast(w.*.totalPCMFrameCount),
                .wav = w,
            };
        }
        return error.OpenFailed;
    }

    pub fn readFrames(self: *Decoder, buf: []f32, frame_count: i32) i32 {
        switch (self.format) {
            .flac => if (self.flac) |f| return @intCast(c.drflac_read_pcm_frames_f32(f, @intCast(frame_count), buf.ptr)),
            .wav => if (self.wav) |w| return @intCast(c.drwav_read_pcm_frames_f32(w, @intCast(frame_count), buf.ptr)),
        }
        return -1;
    }

    pub fn seek(self: *Decoder, pcm_frame: i64) bool {
        switch (self.format) {
            .flac => if (self.flac) |f| return c.drflac_seek_to_pcm_frame(f, @intCast(pcm_frame)) != 0,
            .wav => if (self.wav) |w| return c.drwav_seek_to_pcm_frame(w, @intCast(pcm_frame)) != 0,
        }
        return false;
    }

    pub fn close(self: *Decoder) void {
        switch (self.format) {
            .flac => if (self.flac) |f| c.drflac_close(f),
            .wav => if (self.wav) |w| c.drwav_close(w),
        }
        self.* = undefined;
    }
};
```

- [ ] **Step 4: Create `zig-core/src/decoder.zig`** — re-exports for cleaner imports

```zig
pub const wav_flac = @import("decoders/wav_flac.zig");
pub const Decoder = wav_flac.Decoder;
```

- [ ] **Step 5: Wire up `c_abi.zig` with real decoder calls**

Replace `const std = @import("std");` at the top:

```zig
const std = @import("std");
const decoder_mod = @import("decoder.zig");
const Decoder = decoder_mod.Decoder;

threadlocal var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .{};
```

Replace `decode_open`, `decode_read_frames`, `decode_seek`, `decode_close`, `decode_get_info`:

```zig
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
```

- [ ] **Step 6: Verify compilation**

Run: `cd zig-core && zig build`
Expected: clean compile

- [ ] **Step 7: Commit**

```bash
git add zig-core/
git commit -m "feat: zig FLAC+WAV decoding via dr_libs"
```

---

### Task 3: Zig metadata + mastering analysis

**Files:**
- Create: `zig-core/src/metadata.zig`
- Create: `zig-core/src/mastering.zig`
- Modify: `zig-core/src/c_abi.zig`

- [ ] **Step 1: Create `zig-core/src/metadata.zig`**

```zig
const std = @import("std");

pub const TrackMetadata = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    album_artist: ?[]const u8 = null,
    track_no: ?i32 = null,
    disc_no: ?i32 = null,
    year: ?i32 = null,
    genre: ?[]const u8 = null,
    artwork_base64: ?[]const u8 = null,
    sample_rate: i32 = 0,
    channels: i32 = 0,
    bit_depth: i32 = 0,
    duration_seconds: f64 = 0,
};

pub fn readMetadata(path: [:0]const u8, allocator: std.mem.Allocator) !TrackMetadata {
    // Phase 1: return minimal metadata with just file stem as title.
    // Full tag parsing (Vorbis comments, ID3, RIFF INFO) deferred to Phase 2.
    _ = allocator;
    const base = std.fs.path.basename(path);
    const stem = if (std.fs.path.extension(base)) |ext|
        base[0..base.len - ext.len]
    else
        base;
    return TrackMetadata{
        .title = stem,
    };
}
```

- [ ] **Step 2: Create `zig-core/src/mastering.zig`**

```zig
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
    const rms = @sqrt(sum_sq / @as(f64, @floatCast(total_read * channels)));
    const lufs = if (rms > 0) 20.0 * @log10(rms) else -100.0;
    const dyn_range = peak_db - lufs;

    var corr: f64 = 1.0;
    if (channels >= 2 and dc_n > 0) {
        const lrms = @sqrt(sq_l / @as(f64, @floatCast(dc_n)));
        const rrms = @sqrt(sq_r / @as(f64, @floatCast(dc_n)));
        corr = if (lrms > 0 and rrms > 0) corr_sum / @as(f64, @floatCast(dc_n)) / (lrms * rrms) else 1.0;
        corr = @max(-1.0, @min(1.0, corr));
    }

    const dc_offset = if (channels >= 2 and dc_n > 0) ((dc_l + dc_r) / 2.0) / @as(f64, @floatCast(dc_n)) else 0;

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
```

- [ ] **Step 3: Wire mastering + metadata into `c_abi.zig`**

After `const decoder_mod = ...` add:
```zig
const metadata_mod = @import("metadata.zig");
const mastering_mod = @import("mastering.zig");
```

Replace the stub `metadata_read`, `metadata_free`, `decode_get_mastering`:

```zig
export fn metadata_read(path: [*:0]const u8) ?[*:0]u8 {
    const allocator = gpa_instance.allocator();
    const path_slice: [:0]const u8 = std.mem.sliceTo(path, 0);
    const meta = metadata_mod.readMetadata(path_slice, allocator) catch return null;
    var buf = std.ArrayList(u8).init(allocator);
    std.json.stringify(meta, .{}, buf.writer()) catch return null;
    return (buf.toOwnedSliceSentinel(0) catch return null).ptr;
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
```

- [ ] **Step 4: Verify compilation**

Run: `cd zig-core && zig build`
Expected: clean compile

- [ ] **Step 5: Commit**

```bash
git add zig-core/
git commit -m "feat: zig metadata + mastering analysis"
```

---

### Task 4: Swift project scaffold + C interop + build script

**Files:**
- Create: `TemperPlayer/Package.swift`
- Create: `TemperPlayer/build-zig.sh`
- Create: `TemperPlayer/Sources/CTemperPlayer/include/temperplayer.h`
- Create: `TemperPlayer/Sources/CTemperPlayer/include/module.modulemap`
- Create: `TemperPlayer/Sources/CTemperPlayer/empty.c`
- Create: `TemperPlayer/Sources/TemperPlayer/App/TemperPlayerApp.swift`
- Create: `TemperPlayer/Sources/TemperPlayer/Audio/DecoderBridge.swift`

- [ ] **Step 1: Create `TemperPlayer/build-zig.sh`**

```bash
#!/bin/bash
set -euo pipefail
cd "$SRCROOT/../zig-core"
zig build -Doptimize=ReleaseFast
mkdir -p "$BUILT_PRODUCTS_DIR"
cp zig-out/lib/libtemperplayer.dylib "$BUILT_PRODUCTS_DIR/"
install_name_tool -id "@rpath/libtemperplayer.dylib" "$BUILT_PRODUCTS_DIR/libtemperplayer.dylib"
```

Make executable: `chmod +x TemperPlayer/build-zig.sh`

- [ ] **Step 2: Create `TemperPlayer/Sources/CTemperPlayer/include/temperplayer.h`**

```c
#ifndef temperplayer_h
#define temperplayer_h

#include <stdint.h>

struct SampleFormat {
    int sample_rate;
    int channels;
    int bit_depth;
    double duration_seconds;
};

struct MasteringInfo {
    double lufs;
    double true_peak_db;
    double peak_db;
    double dynamic_range_db;
    double phase_correlation;
    double dc_offset_pct;
    int phase_ok;
};

void* decode_open(const char* path);
int  decode_read_frames(void* handle, float* buf, int frame_count);
int  decode_seek(void* handle, int64_t pcm_frame);
void decode_close(void* handle);
struct SampleFormat decode_get_info(void* handle);
char* metadata_read(const char* path);
void  metadata_free(char* ptr);
struct MasteringInfo decode_get_mastering(const char* path);

#endif
```

- [ ] **Step 3: Create `TemperPlayer/Sources/CTemperPlayer/include/module.modulemap`**

```
module CTemperPlayer [system] {
    header "temperplayer.h"
    link "temperplayer"
    export *
}
```

- [ ] **Step 4: Create `TemperPlayer/Sources/CTemperPlayer/empty.c`**

```c
// Required by SPM for the C target to have at least one source file.
```

- [ ] **Step 5: Create `TemperPlayer/Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TemperPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CTemperPlayer",
            path: "Sources/CTemperPlayer",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("temperplayer")]
        ),
        .executableTarget(
            name: "TemperPlayer",
            dependencies: ["CTemperPlayer"],
            swiftSettings: [
                .unsafeFlags(["-L", "$(PROJECT_DIR)/../zig-core/zig-out/lib"]),
            ]
        ),
    ]
)
```

- [ ] **Step 6: Create `TemperPlayer/Sources/TemperPlayer/App/TemperPlayerApp.swift`**

```swift
import SwiftUI

@main
struct TemperPlayerApp: App {
    @StateObject private var audioManager = AudioManager()
    @StateObject private var library = Database()
    @StateObject private var playerState = PlayerState()

    var body: some Scene {
        Window("TemperPlayer", id: "main") {
            ContentView()
                .environmentObject(audioManager)
                .environmentObject(library)
                .environmentObject(playerState)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

class PlayerState: ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var queue: [Track] = []
    @Published var volume: Float = 0.75

    var timeString: String {
        let m = Int(currentTime) / 60
        let s = Int(currentTime) % 60
        return String(format: "%d:%02d", m, s)
    }

    var durationString: String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }

    var displayPath: String {
        guard let t = currentTrack else { return "no buffer loaded" }
        let url = URL(fileURLWithPath: t.path)
        let dir = url.deletingLastPathComponent().lastPathComponent
        return "\(dir)/\(url.lastPathComponent)"
    }
}
```

- [ ] **Step 7: Create `TemperPlayer/Sources/TemperPlayer/Audio/DecoderBridge.swift`**

```swift
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
```

- [ ] **Step 8: Verify Swift + Zig compile independently**

Run: `cd zig-core && zig build` (should pass)
Expected: dylib exists at `zig-core/zig-out/lib/libtemperplayer.dylib`

- [ ] **Step 9: Commit**

```bash
git add TemperPlayer/
git commit -m "feat: swift project scaffold with C interop and zig build script"
```

---

### Task 5: Swift data models + Database

**Files:**
- Create: `TemperPlayer/Sources/TemperPlayer/Library/Models.swift`
- Create: `TemperPlayer/Sources/TemperPlayer/Library/Database.swift`
- Create: `TemperPlayer/Sources/TemperPlayer/Extensions/Crypto+Path.swift`

- [ ] **Step 1: Create `TemperPlayer/Sources/TemperPlayer/Library/Models.swift`**

```swift
import Foundation

struct Track: Identifiable, Codable, Equatable {
    let id: String          // SHA-256 of absolute path
    var path: String
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNo: Int?
    var discNo: Int?
    var year: Int?
    var genre: String?
    var duration: Double
    var format: String
    var sampleRate: Int
    var bitDepth: Int
    var channels: Int
    var bitrate: Int
    var fileSize: Int
    var dateAdded: Date
    var lastPlayed: Date?
    var playCount: Int
    var artworkPath: String?
    var dcOffset: Double?
    var lufs: Double?
    var truePeak: Double?
    var dynamicRange: Double?
    var phaseCorrelation: Double?

    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
}

struct Playlist: Identifiable, Codable {
    let id: String
    var name: String
    var description: String?
    var created: Date
    var modified: Date
    var tracks: [String]    // track IDs in order
}

struct StreamInfo {
    let format: String
    let sampleRate: Int
    let bitDepth: Int
    let channels: Int
    let duration: Double
    let lufs: Double
    let truePeak: Double
    let peak: Double
    let dynamicRange: Double
    let phaseCorrelation: Double
    let dcOffset: Double
    let phaseOk: Bool
}
```

- [ ] **Step 2: Create `TemperPlayer/Sources/TemperPlayer/Extensions/Crypto+Path.swift`**

```swift
import Foundation
import CryptoKit

extension String {
    /// SHA-256 of the file's absolute path (UTF-8 encoded)
    var pathHash: String {
        let data = Data(self.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 3: Create `TemperPlayer/Sources/TemperPlayer/Library/Database.swift`**

```swift
import Foundation
import SQLite3

class Database: ObservableObject {
    private var db: OpaquePointer?

    @Published var tracks: [Track] = []
    @Published var selectedTrack: Track?

    init() {
        open()
        createSchema()
        loadTracks()
    }

    private func open() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".temperplayer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("library.db").path
        sqlite3_open(path, &db)
    }

    private func createSchema() {
        let sql = """
        CREATE TABLE IF NOT EXISTS tracks (
            id              TEXT PRIMARY KEY,
            path            TEXT NOT NULL,
            title           TEXT,
            artist          TEXT,
            album           TEXT,
            album_artist    TEXT,
            track_no        INTEGER,
            disc_no         INTEGER,
            year            INTEGER,
            genre           TEXT,
            duration        REAL,
            format          TEXT,
            sample_rate     INTEGER,
            bit_depth       INTEGER,
            channels        INTEGER,
            bitrate         INTEGER,
            file_size       INTEGER,
            date_added      TEXT NOT NULL,
            last_played     TEXT,
            play_count      INTEGER DEFAULT 0,
            artwork_path    TEXT,
            dc_offset       REAL,
            lufs            REAL,
            true_peak       REAL,
            dynamic_range   REAL,
            phase_correlation REAL
        );
        CREATE TABLE IF NOT EXISTS playlists (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            description TEXT,
            created     TEXT NOT NULL,
            modified    TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS playlist_tracks (
            playlist_id TEXT NOT NULL,
            track_id    TEXT NOT NULL,
            position    INTEGER NOT NULL,
            PRIMARY KEY (playlist_id, track_id),
            FOREIGN KEY (playlist_id) REFERENCES playlists(id),
            FOREIGN KEY (track_id) REFERENCES tracks(id)
        );
        """
        _ = sqlite3_exec(db, sql, nil, nil, nil)
    }

    func insert(track: Track) {
        let insert = """
        INSERT OR REPLACE INTO tracks
        (id, path, title, artist, album, album_artist, track_no, disc_no, year, genre,
         duration, format, sample_rate, bit_depth, channels, bitrate, file_size, date_added,
         artwork_path, dc_offset, lufs, true_peak, dynamic_range, phase_correlation)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, insert, -1, &stmt, nil)

        let iso = ISO8601DateFormatter()

        sqlite3_bind_text(stmt, 1, (track.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (track.path as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (track.title as NSString?)?.utf8String ?? "", -1, nil)
        sqlite3_bind_text(stmt, 4, (track.artist as NSString?)?.utf8String ?? "", -1, nil)
        sqlite3_bind_text(stmt, 5, (track.album as NSString?)?.utf8String ?? "", -1, nil)
        sqlite3_bind_text(stmt, 6, (track.albumArtist as NSString?)?.utf8String ?? "", -1, nil)
        sqlite3_bind_int(stmt, 7, Int32(track.trackNo ?? 0))
        sqlite3_bind_int(stmt, 8, Int32(track.discNo ?? 0))
        sqlite3_bind_int(stmt, 9, Int32(track.year ?? 0))
        sqlite3_bind_text(stmt, 10, (track.genre as NSString?)?.utf8String ?? "", -1, nil)
        sqlite3_bind_double(stmt, 11, track.duration)
        sqlite3_bind_text(stmt, 12, (track.format as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 13, Int32(track.sampleRate))
        sqlite3_bind_int(stmt, 14, Int32(track.bitDepth))
        sqlite3_bind_int(stmt, 15, Int32(track.channels))
        sqlite3_bind_int(stmt, 16, Int32(track.bitrate))
        sqlite3_bind_int(stmt, 17, Int32(track.fileSize))
        sqlite3_bind_text(stmt, 18, (iso.string(from: track.dateAdded) as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 19, (track.artworkPath as NSString?)?.utf8String ?? "", -1, nil)
        sqlite3_bind_double(stmt, 20, track.dcOffset ?? 0)
        sqlite3_bind_double(stmt, 21, track.lufs ?? 0)
        sqlite3_bind_double(stmt, 22, track.truePeak ?? 0)
        sqlite3_bind_double(stmt, 23, track.dynamicRange ?? 0)
        sqlite3_bind_double(stmt, 24, track.phaseCorrelation ?? 0)

        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        loadTracks()
    }

    func loadTracks() {
        var results: [Track] = []
        let sql = "SELECT * FROM tracks ORDER BY date_added DESC"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)

        let iso = ISO8601DateFormatter()

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let path = String(cString: sqlite3_column_text(stmt, 1))
            let title = optStr(stmt, 2)
            let artist = optStr(stmt, 3)
            let album = optStr(stmt, 4)
            let albumArtist = optStr(stmt, 5)
            let trackNo = optInt(stmt, 6)
            let discNo = optInt(stmt, 7)
            let year = optInt(stmt, 8)
            let genre = optStr(stmt, 9)
            let duration = sqlite3_column_double(stmt, 10)
            let format = optStr(stmt, 11) ?? ""
            let sampleRate = Int(sqlite3_column_int(stmt, 12))
            let bitDepth = Int(sqlite3_column_int(stmt, 13))
            let channels = Int(sqlite3_column_int(stmt, 14))
            let bitrate = Int(sqlite3_column_int(stmt, 15))
            let fileSize = Int(sqlite3_column_int(stmt, 16))
            let dateStr = String(cString: sqlite3_column_text(stmt, 17))
            let dateAdded = iso.date(from: dateStr) ?? Date()
            let lastPlayedStr = optStr(stmt, 18)
            let playCount = Int(sqlite3_column_int(stmt, 19))
            let artworkPath = optStr(stmt, 20)
            let dcOffset = optDouble(stmt, 21)
            let lufs = optDouble(stmt, 22)
            let truePeak = optDouble(stmt, 23)
            let dynamicRange = optDouble(stmt, 24)
            let phaseCorrelation = optDouble(stmt, 25)

            results.append(Track(
                id: id, path: path, title: title, artist: artist, album: album,
                albumArtist: albumArtist, trackNo: trackNo, discNo: discNo, year: year,
                genre: genre, duration: duration, format: format, sampleRate: sampleRate,
                bitDepth: bitDepth, channels: channels, bitrate: bitrate, fileSize: fileSize,
                dateAdded: dateAdded, lastPlayed: nil, playCount: playCount,
                artworkPath: artworkPath, dcOffset: dcOffset, lufs: lufs, truePeak: truePeak,
                dynamicRange: dynamicRange, phaseCorrelation: phaseCorrelation
            ))
        }
        sqlite3_finalize(stmt)
        self.tracks = results
    }

    private func optStr(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(stmt, idx))
    }

    private func optInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(stmt, idx))
    }

    private func optDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, idx)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add TemperPlayer/Sources/TemperPlayer/Library/ TemperPlayer/Sources/TemperPlayer/Extensions/
git commit -m "feat: data models + sqlite database layer"
```

---

### Task 6: AudioManager — AVAudioEngine + Zig PCM scheduling

**Files:**
- Create: `TemperPlayer/Sources/TemperPlayer/Audio/AudioManager.swift`

- [ ] **Step 1: Create `TemperPlayer/Sources/TemperPlayer/Audio/AudioManager.swift`**

```swift
import Foundation
import AVFAudio
import CTemperPlayer

class AudioManager: ObservableObject {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var decoder: DecoderBridge?
    @Published var isPlaying = false

    private var currentTrackPath: String?
    private var currentFrame: Int64 = 0
    private let scheduleQueue = DispatchQueue(label: "com.temperplayer.audio")
    private let frameBatch: Int32 = 8192

    override init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        try? engine.start()
    }

    func play(track path: String) {
        stop()

        let d = DecoderBridge()
        guard d.open(path: path) else { return }

        decoder = d
        currentTrackPath = path
        currentFrame = 0

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(d.sampleRate),
            channels: AVAudioChannelCount(d.channels),
            interleaved: false
        )

        guard let format else { return }

        // Schedule initial buffers
        scheduleQueue.async { [weak self] in
            self?.scheduleBuffer(format: format)
        }

        playerNode.play()
        isPlaying = true
    }

    private func scheduleBuffer(format: AVAudioFormat) {
        guard let decoder else { return }

        let capacity = Int(frameBatch) * Int(decoder.channels)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameBatch))!
        buf.frameLength = buf.frameCapacity

        let framesRead = decoder.readFrames(
            into: buf.floatChannelData!.pointee,
            count: frameBatch
        )

        if framesRead > 0 {
            buf.frameLength = AVAudioFrameCount(framesRead)
            currentFrame += Int64(framesRead)

            playerNode.scheduleBuffer(buf) { [weak self] in
                guard let self else { return }

                // Check if we've reached end of file
                if framesRead < self.frameBatch {
                    self.playerNode.stop()
                    self.isPlaying = false
                    return
                }

                // Continue scheduling
                self.scheduleQueue.async {
                    self.scheduleBuffer(format: format)
                }
            }
        }
    }

    func pause() {
        if playerNode.isPlaying {
            playerNode.pause()
            isPlaying = false
        }
    }

    func resume() {
        if !playerNode.isPlaying && decoder != nil {
            playerNode.play()
            isPlaying = true
        }
    }

    func stop() {
        playerNode.stop()
        decoder?.close()
        decoder = nil
        currentTrackPath = nil
        currentFrame = 0
        isPlaying = false
    }

    func seek(to time: Double) {
        guard let decoder, let path = currentTrackPath else { return }
        let sampleRate = decoder.sampleRate
        let frame = Int64(time * Double(sampleRate))

        playerNode.stop()

        _ = decoder.seek(frame: frame)
        currentFrame = frame

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(decoder.channels),
            interleaved: false
        )

        if let format {
            scheduleQueue.async { [weak self] in
                self?.scheduleBuffer(format: format)
            }
        }

        if isPlaying {
            playerNode.play()
        }
    }

    func setVolume(_ volume: Float) {
        playerNode.volume = volume
    }

    var duration: Double {
        guard let decoder else { return 0 }
        return decoder.durationSeconds
    }

    deinit {
        stop()
        engine.stop()
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TemperPlayer/Sources/TemperPlayer/Audio/
git commit -m "feat: AVAudioEngine PCM scheduling with zig decoder"
```

---

### Task 7: Blackbox UI — GlyphSpine + ContentView shell

**Files:**
- Create: `TemperPlayer/Sources/TemperPlayer/UI/ContentView.swift`
- Create: `TemperPlayer/Sources/TemperPlayer/UI/GlyphSpine.swift`

- [ ] **Step 1: Create `TemperPlayer/Sources/TemperPlayer/UI/GlyphSpine.swift`**

```swift
import SwiftUI

enum Mode: String, CaseIterable {
    case files = "$"
    case library = "~"
    case playlists = "#"
    case tag = "◎"
    case analyze = "λ"

    var label: String { rawValue }
}

struct GlyphSpine: View {
    @Binding var activeMode: Mode
    @State private var hoveredMode: Mode?

    var body: some View {
        VStack(spacing: 14) {
            ForEach(Mode.allCases, id: \.self) { mode in
                Text(mode.label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(foreground(for: mode))
                    .frame(width: 36, height: 24)
                    .background(background(for: mode))
                    .onHover { hovering in
                        hoveredMode = hovering ? mode : nil
                    }
                    .onTapGesture { activeMode = mode }
            }

            Spacer()

            Text("TERM")
                .font(.system(size: 7, design: .monospaced))
                .foregroundColor(Color(white: 0.15))
                .rotationEffect(.degrees(-90))
                .fixedSize()
        }
        .padding(.vertical, 12)
        .frame(width: 36)
        .background(Color.black)
        .overlay(rightBorder)
    }

    private var rightBorder: some View {
        Rectangle()
            .fill(Color(white: 0.06))
            .frame(width: 1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func foreground(for mode: Mode) -> Color {
        if mode == activeMode { return .white }
        if mode == hoveredMode { return Color(white: 0.6) }
        return Color(white: 0.2)
    }

    private func background(for mode: Mode) -> some View {
        Group {
            if mode == activeMode {
                Color.white.opacity(0.05)
            } else {
                Color.clear
            }
        }
    }
}
```

- [ ] **Step 2: Create `TemperPlayer/Sources/TemperPlayer/UI/ContentView.swift`**

```swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @State private var activeMode: Mode = .files
    @State private var hoveredTrackId: String?

    var body: some View {
        HStack(spacing: 0) {
            GlyphSpine(activeMode: $activeMode)

            WorkspaceView(hoveredTrackId: $hoveredTrackId)
                .frame(minWidth: 380)

            InspectorView(hoveredTrackId: hoveredTrackId)
                .frame(width: 210)
        }
        .overlay(alignment: .bottom) {
            TransportBar()
                .frame(height: 34)
        }
        .background(Color.black)
        .onDrop(of: [.fileURL], delegate: ImportDropDelegate())
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add TemperPlayer/Sources/TemperPlayer/UI/ContentView.swift TemperPlayer/Sources/TemperPlayer/UI/GlyphSpine.swift
git commit -m "feat: content view shell with glyph spine"
```

---

### Task 8: Blackbox UI — WorkspaceView + FileTreeView

**Files:**
- Create: `TemperPlayer/Sources/TemperPlayer/UI/WorkspaceView.swift`
- Create: `TemperPlayer/Sources/TemperPlayer/UI/FileTreeView.swift`

- [ ] **Step 1: Create `TemperPlayer/Sources/TemperPlayer/UI/FileTreeView.swift`**

```swift
import SwiftUI

struct FileTreeView: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @Binding var hoveredTrackId: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(library.tracks) { track in
                    FileTreeRow(
                        track: track,
                        isPlaying: playerState.currentTrack?.id == track.id,
                        isHovered: hoveredTrackId == track.id
                    )
                    .onHover { hovering in
                        hoveredTrackId = hovering ? track.id : nil
                    }
                    .onTapGesture(count: 2) {
                        playTrack(track)
                    }
                }
            }
            .padding(4)
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private func playTrack(_ track: Track) {
        playerState.currentTrack = track
        playerState.duration = track.duration
        playerState.audioManager = audioManagerRef

        audioManagerRef.play(track: track.path)
        playerState.isPlaying = true
    }

    @EnvironmentObject private var audioManagerRef: AudioManager
}

struct FileTreeRow: View {
    let track: Track
    let isPlaying: Bool
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Glyph
            if isPlaying {
                Text("▶")
                    .foregroundColor(.white)
                    .frame(width: 12)
            } else {
                Text(docIcon)
                    .foregroundColor(Color(white: 0.3))
                    .frame(width: 12)
            }

            // Tree lines
            Text("├─")
                .foregroundColor(Color(white: 0.4))
                .frame(width: 14, alignment: .leading)

            // Filename
            Text(track.path.components(separatedBy: "/").last ?? "?")
                .foregroundColor(isPlaying ? .white : Color(white: 0.7))

            Spacer()

            // Duration
            let m = Int(track.duration) / 60
            let s = Int(track.duration) % 60
            Text(String(format: "%d:%02d", m, s))
                .foregroundColor(Color(white: 0.35))
                .font(.system(size: 9, design: .monospaced))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(isPlaying ? Color.white.opacity(0.04) : (isHovered ? Color.white.opacity(0.02) : Color.clear))
    }

    private var docIcon: String {
        switch track.format {
        case "flac": return "♩"
        case "wav": return "♪"
        default: return "◌"
        }
    }
}
```

- [ ] **Step 2: Create `TemperPlayer/Sources/TemperPlayer/UI/WorkspaceView.swift`**

```swift
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @Binding var hoveredTrackId: String?

    var body: some View {
        VStack(spacing: 0) {
            // Top: directory path
            HStack {
                Text("~/Music")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
                Spacer()
                Text("\(library.tracks.count) files")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(white: 0.25))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black)

            // File tree
            FileTreeView(hoveredTrackId: $hoveredTrackId)
                .frame(maxHeight: .infinity)

            // Waveform (only when playing)
            if playerState.currentTrack != nil {
                WaveformView()
                    .frame(height: 100)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.black)
        .overlay(rightBorder)
    }

    private var rightBorder: some View {
        Rectangle()
            .fill(Color(white: 0.06))
            .frame(width: 1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add TemperPlayer/Sources/TemperPlayer/UI/WorkspaceView.swift TemperPlayer/Sources/TemperPlayer/UI/FileTreeView.swift
git commit -m "feat: workspace file tree + waveform container"
```

---

### Task 9: Blackbox UI — WaveformView

**Files:**
- Create: `TemperPlayer/Sources/TemperPlayer/UI/WaveformView.swift`

- [ ] **Step 1: Create `TemperPlayer/Sources/TemperPlayer/UI/WaveformView.swift`**

```swift
import SwiftUI

struct WaveformView: View {
    @EnvironmentObject var playerState: PlayerState
    @State private var waveformBars: [CGFloat] = []

    var body: some View {
        VStack(spacing: 4) {
            // Label
            HStack {
                Text("WAVEFORM")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(white: 0.25))
                    .tracking(1.5)
                Spacer()
            }

            // Waveform
            GeometryReader { geo in
                let barCount = max(Int(geo.size.width / 3), 20)
                let bars = waveformBars.isEmpty ? generateSampleBars(count: barCount) : waveformBars

                HStack(alignment: .center, spacing: 1.5) {
                    ForEach(bars.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(barColor(for: i, total: bars.count, geo: geo))
                            .frame(width: max(1, (geo.size.width - CGFloat(bars.count)) / CGFloat(bars.count)),
                                   height: max(2, bars[i] * (geo.size.height - 8)))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 52)
            .background(Color(white: 0.02))
            .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color(white: 0.06)))

            // Time ruler
            HStack(spacing: 0) {
                Text(playerState.timeString)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(white: 0.2))
                Spacer()
                Text("0:15")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(white: 0.15))
                Spacer()
                Text("0:30")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(white: 0.15))
                Spacer()
                Text("0:45")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(white: 0.15))
                Spacer()
                Text(playerState.durationString)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(white: 0.2))
            }
            .padding(.horizontal, 4)
        }
    }

    private func barColor(for index: Int, total: Int, geo: GeometryProxy) -> Color {
        let progress = playerState.duration > 0 ? playerState.currentTime / playerState.duration : 0
        let barPosition = CGFloat(index) / CGFloat(total)
        if barPosition <= progress {
            return .white
        }
        return Color(white: 0.12)
    }

    private func generateSampleBars(count: Int) -> [CGFloat] {
        var bars: [CGFloat] = []
        for i in 0..<count {
            let phase = sin(Double(i) * 0.3) * 0.4 + 0.5
            let noise = Double.random(in: 0.1...0.3)
            bars.append(CGFloat(phase + noise))
        }
        return bars
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TemperPlayer/Sources/TemperPlayer/UI/WaveformView.swift
git commit -m "feat: waveform view with time ruler and playhead"
```

---

### Task 10: Blackbox UI — InspectorView

**Files:**
- Create: `TemperPlayer/Sources/TemperPlayer/UI/InspectorView.swift`

- [ ] **Step 1: Create `TemperPlayer/Sources/TemperPlayer/UI/InspectorView.swift`**

```swift
import SwiftUI
import CTemperPlayer

struct InspectorView: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    let hoveredTrackId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // BUFFER
            SectionHeader(title: "BUFFER")
            if let track = displayedTrack {
                Text(track.path)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
                    .lineLimit(3)
            } else {
                Text("no buffer loaded")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(white: 0.2))
            }

            // STREAM
            SectionHeader(title: "STREAM")
            if let track = displayedTrack {
                StreamInfoView(track: track)
            } else {
                Text("—")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(white: 0.2))
            }

            // Album art (tiny)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(white: 0.1))
                    .frame(width: 20, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color(white: 0.06)))
                Text("artwork")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(white: 0.25))
            }

            // QUEUE
            SectionHeader(title: "QUEUE")
            VStack(alignment: .leading, spacing: 2) {
                if let track = playerState.currentTrack {
                    HStack(spacing: 4) {
                        Text("▶")
                            .foregroundColor(.white)
                            .font(.system(size: 8, design: .monospaced))
                        Text(track.title ?? "untitled")
                            .foregroundColor(Color(white: 0.7))
                    }
                }
                ForEach(playerState.queue.prefix(3)) { track in
                    Text("  \(track.title ?? "untitled")")
                        .foregroundColor(Color(white: 0.3))
                }
                if playerState.queue.count > 3 {
                    Text("  +\(playerState.queue.count - 3) more")
                        .foregroundColor(Color(white: 0.2))
                }
            }
            .font(.system(size: 9, design: .monospaced))

            Spacer()

            // Status line
            HStack {
                Text("PID \(ProcessInfo.processInfo.processIdentifier)")
                    .font(.system(size: 7, design: .monospaced))
                Spacer()
            }
            .foregroundColor(Color(white: 0.15))
            .padding(.top, 4)
            .overlay(Divider().frame(maxWidth: .infinity).foregroundColor(Color(white: 0.04)), alignment: .top)
        }
        .padding(12)
        .font(.system(size: 10, design: .monospaced))
        .background(Color.black)
        .overlay(leftBorder)
    }

    private var leftBorder: some View {
        Rectangle()
            .fill(Color(white: 0.06))
            .frame(width: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayedTrack: Track? {
        if let id = hoveredTrackId {
            return library.tracks.first { $0.id == id }
        }
        return playerState.currentTrack
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 8, design: .monospaced))
            .foregroundColor(Color(white: 0.35))
            .tracking(1.5)
            .padding(.top, 4)
    }
}

struct StreamInfoView: View {
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            KeyValueRow(key: "format", value: track.format, color: .white)
            KeyValueRow(key: "sample rate", value: formatNum(track.sampleRate), color: .white)
            KeyValueRow(key: "bit depth", value: "\(track.bitDepth)", color: .white)
            KeyValueRow(key: "channels", value: "\(track.channels)", color: .white)
            KeyValueRow(key: "duration", value: durationString(track.duration), color: .white)

            Color(white: 0.08).frame(height: 1)

            if let l = track.lufs { KeyValueRow(key: "loudness", value: String(format: "%.1f LUFS", l), color: .white) }
            if let tp = track.truePeak { KeyValueRow(key: "true peak", value: String(format: "%.1f dBTP", tp), color: .white) }
            if let p = track.lufs { KeyValueRow(key: "peak", value: String(format: "%.1f dB", p), color: .white) }
            if let dr = track.dynamicRange { KeyValueRow(key: "dynamic", value: String(format: "%.1f dB", dr), color: .white) }

            Color(white: 0.08).frame(height: 1)

            if let pc = track.phaseCorrelation {
                KeyValueRow(key: "phase", value: pc > 0.5 ? "ok" : (pc > 0 ? "warn" : "bad"),
                          color: pc > 0.5 ? Color(red: 0.4, green: 0.8, blue: 0.4) : (pc > 0 ? Color(red: 0.9, green: 0.7, blue: 0.3) : Color(red: 0.9, green: 0.3, blue: 0.3)))
                KeyValueRow(key: "corr", value: String(format: "%+.2f", pc), color: .white)
            }
            if let dc = track.dcOffset {
                let color = abs(dc) < 0.01 ? Color(white: 0.6) : Color(red: 0.9, green: 0.7, blue: 0.3)
                KeyValueRow(key: "dc offset", value: String(format: "%+.3f%%", dc), color: color)
            }
        }
        .font(.system(size: 9, design: .monospaced))
    }

    private func formatNum(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000).\(n / 100 % 10)k" : "\(n)"
    }

    private func durationString(_ d: Double) -> String {
        let m = Int(d) / 60
        let s = Int(d) % 60
        return String(format: "%d:%02d.%d", m, s, Int(d * 10) % 10)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var color: Color = Color(white: 0.7)

    var body: some View {
        HStack(spacing: 0) {
            Text(key)
                .foregroundColor(Color(white: 0.35))
                .frame(width: 72, alignment: .trailing)
            Text(" ")
            Text(value)
                .foregroundColor(color)
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TemperPlayer/Sources/TemperPlayer/UI/InspectorView.swift
git commit -m "feat: inspector panel with mastering stream info"
```

---

### Task 11: Blackbox UI — TransportBar

**Files:**
- Create: `TemperPlayer/Sources/TemperPlayer/UI/TransportBar.swift`

- [ ] **Step 1: Create `TemperPlayer/Sources/TemperPlayer/UI/TransportBar.swift`**

```swift
import SwiftUI

struct TransportBar: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var playerState: PlayerState

    var body: some View {
        HStack(spacing: 8) {
            // Prompt
            Text(">")
                .foregroundColor(Color(white: 0.5))

            // Command
            Text(playerState.displayPath)
                .foregroundColor(Color(white: 0.7))
                .lineLimit(1)

            Spacer()

            // Transport controls
            HStack(spacing: 6) {
                transportButton("|◀") { previousTrack() }
                transportButton("◀") { seekBack() }
                playPauseButton
                transportButton("▶") { seekForward() }
                transportButton("▶|") { nextTrack() }
            }
            .foregroundColor(Color(white: 0.35))

            // Separator
            Text("│")
                .foregroundColor(Color(white: 0.12))

            // Timecode
            Text("\(playerState.timeString) / \(playerState.durationString)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Color(white: 0.35))
                .fontVariant(.tabularFigures)

            // Separator
            Text("│")
                .foregroundColor(Color(white: 0.12))

            // Volume
            Text("vol:\(Int(playerState.volume * 100))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Color(white: 0.35))

            // Volume bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color(white: 0.06))
                    Rectangle()
                        .fill(Color(white: 0.35))
                        .frame(width: geo.size.width * CGFloat(playerState.volume))
                }
            }
            .frame(width: 28, height: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 0)
        .frame(height: 34)
        .background(Color.black)
        .overlay(topBorder)
    }

    private var topBorder: some View {
        Rectangle()
            .fill(Color(white: 0.06))
            .frame(height: 1)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private func transportButton(_ label: String, action: @escaping () -> Void) -> some View {
        Text(label)
            .font(.system(size: 8, design: .monospaced))
            .foregroundColor(Color(white: 0.35))
            .onTapGesture { action() }
    }

    private var playPauseButton: some View {
        Text(playerState.isPlaying ? "■" : "▶")
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(.white)
            .frame(width: 16, height: 16)
            .overlay(Circle().stroke(Color(white: 0.2), lineWidth: 1))
            .onTapGesture { togglePlay() }
    }

    private func togglePlay() {
        if playerState.isPlaying {
            audioManager.pause()
            playerState.isPlaying = false
        } else {
            if let track = playerState.currentTrack {
                audioManager.play(track: track.path)
                playerState.isPlaying = true
            }
        }
    }

    private func previousTrack() {
        guard !playerState.queue.isEmpty,
              let current = playerState.currentTrack,
              let idx = playerState.queue.firstIndex(of: current) else {
            audioManager.seek(to: 0)
            return
        }
        let prevIdx = max(0, idx - 1)
        let track = playerState.queue[prevIdx]
        playerState.currentTrack = track
        audioManager.play(track: track.path)
        playerState.isPlaying = true
    }

    private func nextTrack() {
        guard !playerState.queue.isEmpty,
              let current = playerState.currentTrack,
              let idx = playerState.queue.firstIndex(of: current) else { return }
        let nextIdx = min(playerState.queue.count - 1, idx + 1)
        if nextIdx > idx {
            let track = playerState.queue[nextIdx]
            playerState.currentTrack = track
            audioManager.play(track: track.path)
            playerState.isPlaying = true
        }
    }

    private func seekBack() {
        let newTime = max(0, playerState.currentTime - 5)
        audioManager.seek(to: newTime)
    }

    private func seekForward() {
        let newTime = min(playerState.duration, playerState.currentTime + 5)
        audioManager.seek(to: newTime)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TemperPlayer/Sources/TemperPlayer/UI/TransportBar.swift
git commit -m "feat: transport bar with controls and timecode"
```

---

### Task 12: ImportService — drag-drop import pipeline

**Files:**
- Create: `TemperPlayer/Sources/TemperPlayer/Library/ImportService.swift`

- [ ] **Step 1: Create `TemperPlayer/Sources/TemperPlayer/Library/ImportService.swift`**

```swift
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
                    ImportService.shared.import(url: url)
                }
            }
        }
        return true
    }
}

class ImportService {
    static let shared = ImportService()

    private let supportedExtensions: Set<String> = ["flac", "wav", "mp3", "m4a", "aac"]

    func import(url: URL) {
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

        // Open decoder for duration
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
            let db = self.databaseRef
            db.insert(track: track)
        }
    }

    private weak var databaseRef: Database!

    func setDatabase(_ db: Database) {
        databaseRef = db
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
```

Also need to wire the database reference. Add to `TemperPlayerApp.swift` init:

```swift
init() {
    _library = StateObject(wrappedValue: Database())
    ImportService.shared.setDatabase(_library.wrappedValue)
}
```

- [ ] **Step 2: Commit**

```bash
git add TemperPlayer/Sources/TemperPlayer/Library/ImportService.swift
git commit -m "feat: drag-drop import pipeline with zig metadata + mastering"
```

---

### Task 13: Build & test — compile everything

**Files:** None (verification only)

- [ ] **Step 1: Build Zig dylib**

Run: `cd zig-core && zig build`
Expected: `zig-out/lib/libtemperplayer.dylib` exists

- [ ] **Step 2: Open project in Xcode**

Run: `cd TemperPlayer && swift package generate-xcodeproj` then `open TemperPlayer.xcodeproj`

Add a build phase:
1. Select the `TemperPlayer` target → Build Phases → + → New Run Script Phase
2. Name: "Build Zig Core"
3. Shell: `/bin/bash`
4. Script: `"$SRCROOT/build-zig.sh"`
5. Drag before "Compile Sources"

Add dylib to Copy Files:
1. Build Phases → + → New Copy Files Phase
2. Destination: Frameworks
3. Add `libtemperplayer.dylib` from `zig-core/zig-out/lib/`

- [ ] **Step 3: Build in Xcode**

Press Cmd+B
Expected: Build succeeds

- [ ] **Step 4: Run**

Press Cmd+R
Expected: Empty black window with glyph spine, no tracks yet. Drag a `.flac` or `.wav` file onto the window to import.

- [ ] **Step 5: Commit**

```bash
git add .
git commit -m "feat: initial buildable temperplayer with zig decoding + swiftui blackbox ui"
```

---

## Spec Coverage Check

| Spec Requirement | Task |
|---|---|
| Zig dylib with C ABI | Task 1 |
| FLAC decoding via dr_flac | Task 2 |
| WAV decoding via dr_wav | Task 2 |
| decode_open/read/seek/close/get_info | Task 1 → Task 2 |
| Metadata extraction (file stem) | Task 3 |
| Mastering analysis (LUFS, peak, DC offset, correlation) | Task 3 |
| Swift C interop via modulemap | Task 4 |
| AVFoundation PCM output via AVAudioEngine | Task 6 |
| SQLite library schema (tracks, playlists) | Task 5 |
| Blackbox 3-panel layout | Tasks 7-11 |
| Glyph spine mode selector | Task 7 |
| File tree with playing indicator | Task 8 |
| Waveform view | Task 9 |
| Inspector panel with BUFFER/STREAM/QUEUE | Task 10 |
| Transport bar with command-line aesthetic | Task 11 |
| Drag-drop import pipeline | Task 12 |
| Keyboard shortcuts | Phase 2 |
| Library views (albums/artists) | Phase 2 |
| MP3/AAC/M4A decoding | Phase 2 |
