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
    _ = allocator;
    const base = std.fs.path.basename(path);
    const ext = std.fs.path.extension(base);
    const stem = base[0 .. base.len - ext.len];
    return TrackMetadata{
        .title = stem,
    };
}
