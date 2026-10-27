//! Read PCM from a mapped MOV without Godot. The open worker builds an
//! immutable O(chunks + table runs) index. read() allocates nothing and
//! never calls minimp4; use it for bounded main-thread batches, never a
//! real-time audio callback. The mmap must outlive Source.
const std = @import("std");

pub const AudioInfo = struct {
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,
    /// End of the MOV presentation timeline in source-rate frames, including
    /// initial empty edits/silence. This is not the number of stored frames.
    frame_count: u64,
};

pub const AudioWarning = enum {
    malformed_audio,
    unsupported_codec,
    unsupported_format,
    unsupported_channels,
    unsupported_rate,
    unsupported_packet_geometry,
    unsupported_edits,
    incompatible_video_timing,
    invalid_audio_offsets,
    out_of_memory,

    pub fn message(self: AudioWarning) []const u8 {
        return switch (self) {
            .malformed_audio => "Audio disabled: malformed MOV audio metadata.",
            .unsupported_codec => "Audio disabled: only embedded signed 16/24-bit PCM is supported (no compressed audio decoder).",
            .unsupported_format => "Audio disabled: PCM must be signed, packed and interleaved, with 16 or 24 bits per sample.",
            .unsupported_channels => "Audio disabled: only mono and stereo PCM are supported.",
            .unsupported_rate => "Audio disabled: PCM sample rate must be an integer from 8000 to 192000 Hz.",
            .unsupported_packet_geometry => "Audio disabled: unsupported PCM sample descriptions or packet/chunk geometry.",
            .unsupported_edits => "Audio disabled: only one forward, frame-aligned audio trim, optionally preceded by an empty edit, is supported.",
            .incompatible_video_timing => "Audio disabled: video timing/edits are incompatible with the player's zero-origin CFR timeline.",
            .invalid_audio_offsets => "Audio disabled: PCM chunk data is outside the mapped file.",
            .out_of_memory => "Audio disabled: insufficient memory for the compact PCM index.",
        };
    }
};

pub const OpenError = error{
    MalformedAudio,
    UnsupportedCodec,
    UnsupportedFormat,
    UnsupportedChannels,
    UnsupportedRate,
    UnsupportedPacketGeometry,
    UnsupportedEdits,
    IncompatibleVideoTiming,
    InvalidAudioOffsets,
    OutOfMemory,
};

pub fn warningFor(err: OpenError) AudioWarning {
    return switch (err) {
        error.MalformedAudio => .malformed_audio,
        error.UnsupportedCodec => .unsupported_codec,
        error.UnsupportedFormat => .unsupported_format,
        error.UnsupportedChannels => .unsupported_channels,
        error.UnsupportedRate => .unsupported_rate,
        error.UnsupportedPacketGeometry => .unsupported_packet_geometry,
        error.UnsupportedEdits => .unsupported_edits,
        error.IncompatibleVideoTiming => .incompatible_video_timing,
        error.InvalidAudioOffsets => .invalid_audio_offsets,
        error.OutOfMemory => .out_of_memory,
    };
}

// Same opaque-handle/scalar-ABI convention as demuxer.zig. These accessors
// are used only while constructing the index on the open worker.
pub const Mp4Ctx = opaque {};
extern fn hap_mp4d_track_count(ctx: *const Mp4Ctx) c_uint;
extern fn hap_mp4d_track_sample_count(ctx: *const Mp4Ctx, track: c_uint) c_uint;
extern fn hap_mp4d_track_timescale(ctx: *const Mp4Ctx, track: c_uint) c_uint;
extern fn hap_mp4d_track_constant_sample_size(ctx: *const Mp4Ctx, track: c_uint) c_uint;
extern fn hap_mp4d_track_chunk_count(ctx: *const Mp4Ctx, track: c_uint) c_uint;
extern fn hap_mp4d_track_chunk_offset(ctx: *const Mp4Ctx, track: c_uint, chunk: c_uint, offset: *u64) c_int;
extern fn hap_mp4d_track_stsc_count(ctx: *const Mp4Ctx, track: c_uint) c_uint;
extern fn hap_mp4d_track_stsc_entry(ctx: *const Mp4Ctx, track: c_uint, entry: c_uint, first: *c_uint, samples: *c_uint, description: *c_uint) c_int;
extern fn hap_mp4d_track_timing_run_count(ctx: *const Mp4Ctx, track: c_uint) c_uint;
extern fn hap_mp4d_track_timing_run(ctx: *const Mp4Ctx, track: c_uint, entry: c_uint, count: *c_uint, duration: *c_uint) c_int;

fn be(comptime T: type, data: []const u8, offset: usize) T {
    return std.mem.readInt(T, data[offset..][0..@sizeOf(T)], .big);
}

const Box = struct { kind: u32, payload: []const u8 };
const Boxes = struct {
    remaining: []const u8,

    fn next(self: *Boxes) OpenError!?Box {
        if (self.remaining.len == 0) return null;
        const data = self.remaining;
        if (data.len < 8) return error.MalformedAudio;
        const short = be(u32, data, 0);
        const header: usize = if (short == 1) 16 else 8;
        if (data.len < header) return error.MalformedAudio;
        const size: u64 = if (short == 0) data.len else if (short == 1) be(u64, data, 8) else short;
        // Every child is contained by its parent slice, including size=0 and
        // extended-size boxes. No unchecked offset+size arithmetic.
        if (size < header or size > data.len) return error.MalformedAudio;
        self.remaining = data[@intCast(size)..];
        return .{ .kind = be(u32, data, 4), .payload = data[header..@intCast(size)] };
    }
};

fn tag(comptime name: *const [4]u8) u32 {
    return std.mem.readInt(u32, name, .big);
}

fn child(data: []const u8, comptime name: *const [4]u8) OpenError!?[]const u8 {
    var it: Boxes = .{ .remaining = data };
    var result: ?[]const u8 = null;
    while (try it.next()) |box| if (box.kind == tag(name)) {
        // The C demuxer replaces duplicate metadata while this parser used
        // to select the first occurrence. Never combine an earlier format,
        // edit or composition timeline with a later table interpretation.
        if (result != null) return error.MalformedAudio;
        result = box.payload;
    };
    return result;
}

fn required(data: []const u8, comptime name: *const [4]u8) OpenError![]const u8 {
    return (try child(data, name)) orelse error.MalformedAudio;
}

pub const Format = struct {
    sample_rate: u32,
    channels: u8,
    bits: u8,
    endian: std.builtin.Endian,
    frames_per_packet: ?u32 = null,

    fn frameBytes(self: Format) u32 {
        return @as(u32, self.channels) * (self.bits / 8);
    }
};

fn rate(value: f64) OpenError!u32 {
    if (!std.math.isFinite(value) or value < 8000 or value > 192000 or @floor(value) != value)
        return error.UnsupportedRate;
    return @intFromFloat(value);
}

fn enda(data: []const u8, depth: u8, found: *?std.builtin.Endian) OpenError!void {
    var it: Boxes = .{ .remaining = data };
    while (try it.next()) |box| {
        if (box.kind == tag("enda")) {
            if (box.payload.len != 2) return error.MalformedAudio;
            const value = be(u16, box.payload, 0);
            if (value > 1) return error.UnsupportedFormat;
            const order: std.builtin.Endian = if (value == 1) .little else .big;
            if (found.* != null and found.*.? != order) return error.UnsupportedFormat;
            found.* = order;
        } else if (box.kind == tag("wave")) {
            if (depth != 0) return error.UnsupportedFormat;
            try enda(box.payload, depth + 1, found);
        }
    }
}

/// Parse the stsd FullBox payload. Deliberately accepts only one sample
/// description: description changes must never silently reinterpret PCM.
pub fn parseSampleDescription(data: []const u8) OpenError!Format {
    if (data.len < 8 or be(u32, data, 0) != 0) return error.MalformedAudio;
    if (be(u32, data, 4) != 1) return error.UnsupportedPacketGeometry;
    var entries: Boxes = .{ .remaining = data[8..] };
    const entry = (try entries.next()) orelse return error.MalformedAudio;
    if (entries.remaining.len != 0) return error.MalformedAudio;
    // AudioSampleEntry offsets below include the ordinary 8-byte box header.
    // An extended-size sample entry is deliberately not accepted.
    const e = data[8..];
    if (e.len < 36 or be(u32, e, 0) != e.len) return error.MalformedAudio;
    if (be(u16, e, 14) != 1) return error.UnsupportedPacketGeometry;
    const version = be(u16, e, 16);
    var fmt: Format = .{ .sample_rate = 0, .channels = 0, .bits = 0, .endian = .big };
    var extension_start: usize = 36;

    if (entry.kind == tag("lpcm")) {
        if (version != 2 or e.len < 72 or be(u32, e, 36) != 72) return error.UnsupportedFormat;
        fmt.sample_rate = try rate(@bitCast(be(u64, e, 40)));
        const channels = be(u32, e, 48);
        if (channels != 1 and channels != 2) return error.UnsupportedChannels;
        fmt.channels = @intCast(channels);
        const bits = be(u32, e, 56);
        if (bits != 16 and bits != 24) return error.UnsupportedFormat;
        fmt.bits = @intCast(bits);
        const flags = be(u32, e, 60);
        // Float, unsigned, planar, aligned-high/padded and unknown layouts
        // are rejected. Nonmixable is a policy hint, not a storage layout.
        if (flags & (4 | 8) != (4 | 8) or flags & ~@as(u32, 2 | 4 | 8 | 64) != 0)
            return error.UnsupportedFormat;
        fmt.endian = if (flags & 2 != 0) .big else .little;
        const packet_frames = be(u32, e, 68);
        if (packet_frames == 0 or @as(u64, packet_frames) * fmt.frameBytes() != be(u32, e, 64))
            return error.UnsupportedPacketGeometry;
        fmt.frames_per_packet = packet_frames;
        extension_start = 72;
    } else {
        if (entry.kind != tag("sowt") and entry.kind != tag("twos") and entry.kind != tag("in24"))
            return error.UnsupportedCodec;
        if (version > 1 or (version == 1 and e.len < 52)) return error.UnsupportedFormat;
        const compression_id = be(i16, e, 28);
        if ((compression_id != 0 and !(version == 1 and compression_id == -2)) or be(u16, e, 30) != 0)
            return error.UnsupportedFormat;
        const channels = be(u16, e, 24);
        if (channels != 1 and channels != 2) return error.UnsupportedChannels;
        fmt.channels = @intCast(channels);
        // in24's codec is authoritative. Legacy version-1 entries commonly
        // carry a nominal 16-bit sampleSize/bytesPerSample placeholder.
        const nominal_bits = be(u16, e, 26);
        const bits: u16 = if (entry.kind == tag("in24")) 24 else nominal_bits;
        if (bits != 16 and bits != 24) return error.UnsupportedFormat;
        fmt.bits = @intCast(bits);
        const fixed_rate = be(u32, e, 32);
        if (fixed_rate & 0xffff != 0) return error.UnsupportedRate;
        fmt.sample_rate = try rate(@floatFromInt(fixed_rate >> 16));
        fmt.endian = if (entry.kind == tag("sowt")) .little else .big;
        if (version == 1) {
            const bytes = bits / 8;
            const nominal_bytes = nominal_bits / 8;
            if (be(u32, e, 36) != 1 or be(u32, e, 40) != bytes or
                be(u32, e, 44) != fmt.frameBytes() or
                (be(u32, e, 48) != bytes and be(u32, e, 48) != nominal_bytes))
                return error.UnsupportedPacketGeometry;
            fmt.frames_per_packet = 1;
            extension_start = 52;
        }
    }
    var order: ?std.builtin.Endian = null;
    try enda(e[extension_start..], 0, &order);
    if (order) |override| {
        if (entry.kind != tag("in24") and override != fmt.endian) return error.UnsupportedFormat;
        fmt.endian = override;
    }
    return fmt;
}

const MediaHeader = struct { timescale: u32, duration: u64 };

fn mediaHeader(data: []const u8) OpenError!MediaHeader {
    if (data.len < 4 or be(u32, data, 0) & 0x00ffffff != 0) return error.MalformedAudio;
    const time_offset: usize = switch (data[0]) {
        0 => 12,
        1 => 20,
        else => return error.MalformedAudio,
    };
    const duration_size: usize = if (data[0] == 1) 8 else 4;
    if (data.len < time_offset + 4 + duration_size) return error.MalformedAudio;
    const scale = be(u32, data, time_offset);
    if (scale == 0) return error.MalformedAudio;
    return .{ .timescale = scale, .duration = if (data[0] == 1) be(u64, data, time_offset + 4) else be(u32, data, time_offset + 4) };
}

const Edit = struct { duration: u64, media_time: i64 };
const Edits = struct { entries: [2]Edit = undefined, count: usize = 0 };

fn edits(trak: []const u8) OpenError!Edits {
    var result: Edits = .{};
    const edts = (try child(trak, "edts")) orelse return result;
    const elst = try required(edts, "elst");
    if (elst.len < 8 or elst[0] > 1 or be(u32, elst, 0) & 0x00ffffff != 0) return error.UnsupportedEdits;
    const count = be(u32, elst, 4);
    const stride: usize = if (elst[0] == 1) 20 else 12;
    if (count == 0 or count > 2 or elst.len - 8 != @as(u64, count) * stride) return error.UnsupportedEdits;
    for (0..count) |i| {
        const e = elst[8 + i * stride ..][0..stride];
        if (be(u32, e, stride - 4) != 0x00010000) return error.UnsupportedEdits;
        result.entries[i] = if (elst[0] == 1)
            .{ .duration = be(u64, e, 0), .media_time = be(i64, e, 8) }
        else
            .{ .duration = be(u32, e, 0), .media_time = be(i32, e, 4) };
    }
    result.count = count;
    return result;
}

fn scaledFrames(ticks: u64, scale: u32, sample_rate: u32, exact: bool) OpenError!u64 {
    const product = @as(u128, ticks) * sample_rate;
    if (scale == 0 or (exact and product % scale != 0)) return error.UnsupportedEdits;
    // Presentation windows begin/end at the first source-rate frame at or
    // after their movie-time boundary. Source trims must be frame-aligned.
    const frames = (product + scale - 1) / scale;
    return std.math.cast(u64, frames) orelse error.UnsupportedEdits;
}

pub const Chunk = struct {
    offset: u64,
    first_frame: u64,
    frame_count: u64,
};

pub fn validateChunk(offset: u64, bytes: u64, file_size: u64) OpenError!void {
    if (offset > file_size or bytes > file_size - offset) return error.InvalidAudioOffsets;
}

/// Independently bound the audio table boxes to stbl, and require their raw
/// entries to agree with the shim. In particular, a child's claimed length
/// cannot borrow bytes from a sibling/parent or select a duplicate table.
fn validateTables(stbl: []const u8, ctx: *const Mp4Ctx, track: u32) OpenError!void {
    var seen: u8 = 0;
    var it: Boxes = .{ .remaining = stbl };
    while (try it.next()) |box| {
        const bit: u8 = switch (box.kind) {
            tag("stsd") => 1,
            tag("stsz"), tag("stz2") => 2,
            tag("stts") => 4,
            tag("stsc") => 8,
            tag("stco"), tag("co64") => 16,
            else => continue,
        };
        if (seen & bit != 0) return error.UnsupportedPacketGeometry;
        seen |= bit;
        const bytes = box.payload;
        if (bytes.len < 8 or be(u32, bytes, 0) != 0) return error.MalformedAudio;
        if (bit == 1) continue; // fully checked by parseSampleDescription
        if (bit == 2) {
            if (bytes.len < 12) return error.MalformedAudio;
            const size = be(u32, bytes, 4);
            const count = be(u32, bytes, 8);
            const expected: u64 = 12 + (if (size == 0) @as(u64, count) * 4 else 0);
            if (expected != bytes.len or size != hap_mp4d_track_constant_sample_size(ctx, track) or
                count != hap_mp4d_track_sample_count(ctx, track)) return error.UnsupportedPacketGeometry;
        } else {
            const count = be(u32, bytes, 4);
            const stride: u64 = if (bit == 4) 8 else if (bit == 8) 12 else if (box.kind == tag("co64")) 8 else 4;
            const shim_count = if (bit == 4) hap_mp4d_track_timing_run_count(ctx, track) else if (bit == 8) hap_mp4d_track_stsc_count(ctx, track) else hap_mp4d_track_chunk_count(ctx, track);
            if (8 + @as(u64, count) * stride != bytes.len or count != shim_count) return error.UnsupportedPacketGeometry;
            // minimp4 is deliberately permissive about nesting. A table
            // misplaced after stbl can replace its index with the same
            // count but different values. Never read those shadow entries.
            for (0..count) |i| {
                const pos = 8 + i * @as(usize, @intCast(stride));
                if (bit == 4) {
                    var samples: c_uint = 0;
                    var duration: c_uint = 0;
                    if (hap_mp4d_track_timing_run(ctx, track, @intCast(i), &samples, &duration) == 0 or
                        samples != be(u32, bytes, pos) or duration != be(u32, bytes, pos + 4))
                        return error.UnsupportedPacketGeometry;
                } else if (bit == 8) {
                    var first: c_uint = 0;
                    var samples: c_uint = 0;
                    var description: c_uint = 0;
                    if (hap_mp4d_track_stsc_entry(ctx, track, @intCast(i), &first, &samples, &description) == 0 or
                        first != be(u32, bytes, pos) or samples != be(u32, bytes, pos + 4) or
                        description != be(u32, bytes, pos + 8)) return error.UnsupportedPacketGeometry;
                } else {
                    var offset: u64 = 0;
                    const raw = if (box.kind == tag("co64")) be(u64, bytes, pos) else be(u32, bytes, pos);
                    if (hap_mp4d_track_chunk_offset(ctx, track, @intCast(i), &offset) == 0 or offset != raw)
                        return error.UnsupportedPacketGeometry;
                }
            }
        }
    }
    if (seen != 31) return error.UnsupportedPacketGeometry;
}

fn zeroCompositionOffsets(stbl: []const u8) OpenError!bool {
    const ctts = (try child(stbl, "ctts")) orelse return true;
    if (ctts.len < 8 or ctts[0] > 1 or be(u32, ctts, 0) & 0x00ffffff != 0 or
        @as(u64, be(u32, ctts, 4)) * 8 != ctts.len - 8) return false;
    var pos: usize = 8;
    while (pos < ctts.len) : (pos += 8) if (be(u32, ctts, pos + 4) != 0) return false;
    return true;
}

pub const Source = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    info: AudioInfo,
    format: Format,
    chunks: []const Chunk,
    timeline_start: u64 = 0,
    source_start: u64 = 0,
    window_frames: u64,

    pub fn deinit(self: *Source) void {
        self.allocator.free(self.chunks);
        self.* = undefined;
    }

    /// Select only the FIRST audio track, including when its codec is not
    /// supported. All failures here disable audio, never the Hap video.
    pub fn open(allocator: std.mem.Allocator, data: []const u8, ctx: *const Mp4Ctx, video_track: u32) OpenError!?Source {
        const moov = try required(data, "moov");
        var tracks: Boxes = .{ .remaining = moov };
        var index: u32 = 0;
        var audio_track: ?u32 = null;
        var audio_trak: ?[]const u8 = null;
        var video_trak: ?[]const u8 = null;
        while (try tracks.next()) |box| {
            if (box.kind != tag("trak")) continue;
            if (index == video_track) video_trak = box.payload;
            if (audio_track == null) {
                const mdia = try required(box.payload, "mdia");
                if (try child(mdia, "hdlr")) |handler| {
                    if (handler.len < 12) return error.MalformedAudio;
                    if (be(u32, handler, 8) == tag("soun")) {
                        audio_track = index;
                        audio_trak = box.payload;
                    }
                }
            }
            index = std.math.add(u32, index, 1) catch return error.MalformedAudio;
        }
        const track = audio_track orelse return null;
        if (index != hap_mp4d_track_count(ctx) or video_trak == null) return error.MalformedAudio;
        const trak = audio_trak.?;
        const mdia = try required(trak, "mdia");
        const minf = try required(mdia, "minf");
        const stbl = try required(minf, "stbl");
        const fmt = try parseSampleDescription(try required(stbl, "stsd"));
        try validateTables(stbl, ctx, track);
        if (!try zeroCompositionOffsets(stbl)) return error.UnsupportedEdits;
        const media = try mediaHeader(try required(mdia, "mdhd"));
        if (media.timescale != hap_mp4d_track_timescale(ctx, track)) return error.MalformedAudio;
        const movie = try mediaHeader(try required(moov, "mvhd"));
        try validateVideo(ctx, video_track, video_trak.?, movie.timescale);

        const count = hap_mp4d_track_sample_count(ctx, track);
        const packet_bytes = hap_mp4d_track_constant_sample_size(ctx, track);
        const chunk_count = hap_mp4d_track_chunk_count(ctx, track);
        const stsc_count = hap_mp4d_track_stsc_count(ctx, track);
        const timing_count = hap_mp4d_track_timing_run_count(ctx, track);
        // Variable-size packet tables and ambiguous legacy byte geometries
        // are explicitly unsupported rather than expanded per PCM sample.
        if (count == 0 or packet_bytes == 0 or packet_bytes % fmt.frameBytes() != 0 or
            chunk_count == 0 or chunk_count > count or chunk_count > data.len / 8 or
            stsc_count == 0 or stsc_count > chunk_count or timing_count == 0 or timing_count > data.len / 8 or
            @as(u64, count) * packet_bytes > data.len)
            return error.UnsupportedPacketGeometry;
        const packet_frames = packet_bytes / fmt.frameBytes();
        if (fmt.frames_per_packet) |declared| {
            if (packet_frames != declared) return error.UnsupportedPacketGeometry;
        }
        var timed_samples: u64 = 0;
        var duration_ticks: u64 = 0;
        for (0..timing_count) |i| {
            var samples: c_uint = 0;
            var duration: c_uint = 0;
            if (hap_mp4d_track_timing_run(ctx, track, @intCast(i), &samples, &duration) == 0 or samples == 0 or
                @as(u64, duration) * fmt.sample_rate != @as(u64, packet_frames) * media.timescale)
                return error.UnsupportedPacketGeometry;
            timed_samples = std.math.add(u64, timed_samples, samples) catch return error.UnsupportedPacketGeometry;
            duration_ticks = std.math.add(u64, duration_ticks, @as(u64, samples) * duration) catch return error.UnsupportedPacketGeometry;
        }
        if (timed_samples != count or duration_ticks != media.duration) return error.UnsupportedPacketGeometry;

        const chunks = try allocator.alloc(Chunk, chunk_count);
        errdefer allocator.free(chunks);
        var sample_cursor: u64 = 0;
        var chunk_cursor: u32 = 0;
        var previous_first: u32 = 0;
        for (0..stsc_count) |i| {
            var first: c_uint = 0;
            var samples: c_uint = 0;
            var description: c_uint = 0;
            if (hap_mp4d_track_stsc_entry(ctx, track, @intCast(i), &first, &samples, &description) == 0 or
                first == 0 or first > chunk_count or first <= previous_first or samples == 0 or description != 1 or
                (i == 0 and first != 1)) return error.UnsupportedPacketGeometry;
            previous_first = first;
            var next: c_uint = chunk_count;
            if (i + 1 < stsc_count) {
                var unused_samples: c_uint = 0;
                var unused_description: c_uint = 0;
                if (hap_mp4d_track_stsc_entry(ctx, track, @intCast(i + 1), &next, &unused_samples, &unused_description) == 0 or
                    next <= first or next > chunk_count) return error.UnsupportedPacketGeometry;
                next -= 1;
            }
            while (chunk_cursor < next) : (chunk_cursor += 1) {
                if (@as(u64, samples) > @as(u64, count) - sample_cursor) return error.UnsupportedPacketGeometry;
                var offset: u64 = 0;
                if (hap_mp4d_track_chunk_offset(ctx, track, chunk_cursor, &offset) == 0) return error.InvalidAudioOffsets;
                try validateChunk(offset, @as(u64, samples) * packet_bytes, data.len);
                chunks[chunk_cursor] = .{
                    .offset = offset,
                    .first_frame = sample_cursor * packet_frames,
                    .frame_count = @as(u64, samples) * packet_frames,
                };
                sample_cursor += samples;
            }
        }
        if (chunk_cursor != chunk_count or sample_cursor != count) return error.UnsupportedPacketGeometry;
        const stored_frames = @as(u64, count) * packet_frames;
        var source: Source = .{
            .allocator = allocator,
            .data = data,
            .format = fmt,
            .chunks = chunks,
            .info = .{ .sample_rate = fmt.sample_rate, .channels = fmt.channels, .bits_per_sample = fmt.bits, .frame_count = stored_frames },
            .window_frames = stored_frames,
        };
        const list = try edits(trak);
        if (list.count > 0) {
            var empty_ticks: u64 = 0;
            if (list.count == 2) {
                if (list.entries[0].media_time != -1) return error.UnsupportedEdits;
                empty_ticks = list.entries[0].duration;
            }
            const trim = list.entries[list.count - 1];
            if (trim.media_time < 0) return error.UnsupportedEdits;
            source.source_start = try scaledFrames(@intCast(trim.media_time), media.timescale, fmt.sample_rate, true);
            if (source.source_start > stored_frames) return error.UnsupportedEdits;
            source.timeline_start = try scaledFrames(empty_ticks, movie.timescale, fmt.sample_rate, false);
            const end_ticks = std.math.add(u64, empty_ticks, trim.duration) catch return error.UnsupportedEdits;
            source.info.frame_count = try scaledFrames(end_ticks, movie.timescale, fmt.sample_rate, false);
            source.window_frames = @min(source.info.frame_count - source.timeline_start, stored_frames - source.source_start);
        }
        return source;
    }

    /// Absolute presentation frames -> interleaved stereo float. Mono is
    /// duplicated. Silence is returned before/after the edited source window,
    /// even beyond info.frame_count. Odd trailing output elements are untouched.
    /// At most 4096 frames are written; enormous start positions cannot wrap.
    pub fn read(self: *const Source, start_frame: u64, out_stereo: []f32) usize {
        const frames: usize = @min(out_stereo.len / 2, 4096);
        @memset(out_stereo[0 .. frames * 2], 0);
        if (frames == 0) return 0;
        var output: usize = 0;
        if (start_frame < self.timeline_start) {
            const silence = @min(@as(u64, frames), self.timeline_start - start_frame);
            output = @intCast(silence);
            if (output == frames) return frames;
        }
        const presentation = std.math.add(u64, start_frame, output) catch return frames;
        const relative = presentation - self.timeline_start;
        if (relative >= self.window_frames) return frames;
        var source_frame = self.source_start + relative;
        const active_frames: usize = @intCast(@min(@as(u64, frames - output), self.window_frames - relative));
        const end_output = output + active_frames;
        var low: usize = 0;
        var high = self.chunks.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.chunks[mid].first_frame <= source_frame) low = mid + 1 else high = mid;
        }
        var chunk_index = low - 1; // nonempty, contiguous, validated at open
        const sample_bytes: usize = self.format.bits / 8;
        const frame_bytes = self.format.frameBytes();
        while (output < end_output) : (chunk_index += 1) {
            const chunk = self.chunks[chunk_index];
            const in_chunk = source_frame - chunk.first_frame;
            const take: usize = @intCast(@min(@as(u64, end_output - output), chunk.frame_count - in_chunk));
            var offset: usize = @intCast(chunk.offset + in_chunk * frame_bytes);
            for (0..take) |_| {
                const left = convert(self.data[offset..][0..sample_bytes], self.format.bits, self.format.endian);
                const right = if (self.format.channels == 1) left else convert(self.data[offset + sample_bytes ..][0..sample_bytes], self.format.bits, self.format.endian);
                out_stereo[output * 2] = left;
                out_stereo[output * 2 + 1] = right;
                output += 1;
                offset += frame_bytes;
            }
            source_frame += take;
        }
        return frames;
    }
};

/// Exact signed normalization: minimum -> -1, maximum -> 1 - 1/2^(bits-1).
pub fn convert(bytes: []const u8, bits: u8, endian: std.builtin.Endian) f32 {
    if (bits == 16) {
        const value = switch (endian) {
            .little => std.mem.readInt(i16, bytes[0..2], .little),
            .big => std.mem.readInt(i16, bytes[0..2], .big),
        };
        return @as(f32, @floatFromInt(value)) / 32768.0;
    }
    const value: i24 = switch (endian) {
        .little => std.mem.readInt(i24, bytes[0..3], .little),
        .big => std.mem.readInt(i24, bytes[0..3], .big),
    };
    return @as(f32, @floatFromInt(value)) / 8388608.0;
}

fn validateVideo(ctx: *const Mp4Ctx, track: u32, trak: []const u8, movie_scale: u32) OpenError!void {
    const count = hap_mp4d_track_timing_run_count(ctx, track);
    const samples = hap_mp4d_track_sample_count(ctx, track);
    if (count == 0 or count > samples) return error.IncompatibleVideoTiming;
    var total: u64 = 0;
    var frame_ticks: u32 = 0;
    for (0..count) |i| {
        var n: c_uint = 0;
        var ticks: c_uint = 0;
        if (hap_mp4d_track_timing_run(ctx, track, @intCast(i), &n, &ticks) == 0 or n == 0 or ticks == 0 or
            (i > 0 and ticks != frame_ticks)) return error.IncompatibleVideoTiming;
        frame_ticks = ticks;
        total = std.math.add(u64, total, n) catch return error.IncompatibleVideoTiming;
    }
    if (total != samples) return error.IncompatibleVideoTiming;
    const mdia = try required(trak, "mdia");
    const media = mediaHeader(try required(mdia, "mdhd")) catch return error.IncompatibleVideoTiming;
    const scale = hap_mp4d_track_timescale(ctx, track);
    if (media.timescale != scale or media.duration != total * frame_ticks) return error.IncompatibleVideoTiming;
    const minf = try required(mdia, "minf");
    const stbl = try required(minf, "stbl");
    _ = required(stbl, "stts") catch return error.IncompatibleVideoTiming;
    if (!(zeroCompositionOffsets(stbl) catch return error.IncompatibleVideoTiming)) return error.IncompatibleVideoTiming;
    const list = edits(trak) catch return error.IncompatibleVideoTiming;
    if (list.count == 0) return;
    if (list.count != 1 or list.entries[0].media_time != 0 or scale == 0) return error.IncompatibleVideoTiming;
    const edited = @as(u128, list.entries[0].duration) * scale;
    const full = @as(u128, total) * frame_ticks * movie_scale;
    const difference = @max(edited, full) - @min(edited, full);
    // A whole-track identity edit commonly rounds its duration to movie
    // ticks. Accept <1 movie tick of endpoint rounding, never a start shift.
    if (difference >= scale) return error.IncompatibleVideoTiming;
}
