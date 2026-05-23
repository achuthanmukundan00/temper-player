const std = @import("std");
const c = @cImport({
    @cInclude("dr_flac.h");
    @cInclude("dr_wav.h");
    @cInclude("dr_flac_zig.h");
});

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    format: Format,
    sample_rate: i32,
    channels: i32,
    bit_depth: i32,
    total_pcm_frames: i64,
    flac: ?*c.drflac = null,
    wav: c.drwav = undefined,

    pub const Format = enum { flac, wav };

    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) !Decoder {
        // Try FLAC first
        if (c.drflac_open_file(path.ptr, null)) |f| {
            return Decoder{
                .allocator = allocator,
                .format = .flac,
                .sample_rate = @intCast(c.drflac_zig_get_sample_rate(f)),
                .channels = @intCast(c.drflac_zig_get_channels(f)),
                .bit_depth = @intCast(c.drflac_zig_get_bits_per_sample(f)),
                .total_pcm_frames = @intCast(c.drflac_zig_get_total_pcm_frame_count(f)),
                .flac = f,
            };
        }
        // Try WAV (in-place init)
        var wav: c.drwav = undefined;
        if (c.drwav_init_file(&wav, path.ptr, null) != 0) {
            return Decoder{
                .allocator = allocator,
                .format = .wav,
                .sample_rate = @intCast(wav.sampleRate),
                .channels = @intCast(wav.channels),
                .bit_depth = @intCast(wav.bitsPerSample),
                .total_pcm_frames = @intCast(wav.totalPCMFrameCount),
                .wav = wav,
            };
        }
        return error.OpenFailed;
    }

    pub fn readFrames(self: *Decoder, buf: []f32, frame_count: i32) i32 {
        if (buf.len < @as(usize, @intCast(frame_count)) * @as(usize, @intCast(self.channels))) {
            @panic("readFrames: buffer too small for frame_count * channels");
        }
        switch (self.format) {
            .flac => if (self.flac) |f| {
                return @intCast(c.drflac_read_pcm_frames_f32(
                    f,
                    @intCast(frame_count),
                    buf.ptr,
                ));
            },
            .wav => {
                return @intCast(c.drwav_read_pcm_frames_f32(
                    &self.wav,
                    @intCast(frame_count),
                    buf.ptr,
                ));
            },
        }
        return -1;
    }

    pub fn seek(self: *Decoder, pcm_frame: i64) bool {
        switch (self.format) {
            .flac => if (self.flac) |f| {
                return c.drflac_seek_to_pcm_frame(f, @intCast(pcm_frame)) != 0;
            },
            .wav => {
                return c.drwav_seek_to_pcm_frame(&self.wav, @intCast(pcm_frame)) != 0;
            },
        }
        return false;
    }

    pub fn close(self: *Decoder) void {
        switch (self.format) {
            .flac => if (self.flac) |f| c.drflac_close(f),
            .wav => {
                _ = c.drwav_uninit(&self.wav);
            },
        }
        self.* = undefined;
    }
};
