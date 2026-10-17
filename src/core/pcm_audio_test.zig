const std = @import("std");
const testing = std.testing;
const pcm = @import("pcm_audio.zig");
const demuxer = @import("demuxer.zig");
const MmapReader = @import("mmap_reader.zig").MmapReader;
const support = @import("test_support.zig");

test "signed 16 and 24 bit boundary vectors in both byte orders" {
    inline for (.{ 16, 24 }) |bits| {
        const T = if (bits == 16) i16 else i24;
        const values = [_]T{ std.math.minInt(T), -1, 0, 1, std.math.maxInt(T) };
        inline for (.{ .little, .big }) |order| {
            for (values) |value| {
                var bytes: [bits / 8]u8 = undefined;
                std.mem.writeInt(T, &bytes, value, order);
                const expected = @as(f32, @floatFromInt(value)) / @as(f32, @floatFromInt(@as(u32, 1) << (bits - 1)));
                try testing.expectEqual(expected, pcm.convert(&bytes, bits, order));
            }
        }
    }
}

fn put(comptime T: type, data: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, data[offset..][0..@sizeOf(T)], value, .big);
}

const Description = struct {
    codec: *const [4]u8 = "sowt",
    version: u16 = 0,
    channels: u16 = 1,
    bits: u16 = 16,
    sample_rate: u32 = 8000,
    flags: u32 = 12,
    wave_enda: ?u16 = null,
};

fn description(options: Description) ![]u8 {
    const entry_len: usize = (switch (options.version) {
        0 => @as(usize, 36),
        1 => @as(usize, 52),
        else => @as(usize, 72),
    }) + (if (options.wave_enda != null) @as(usize, 18) else 0);
    const data = try testing.allocator.alloc(u8, 8 + entry_len);
    @memset(data, 0);
    put(u32, data, 4, 1);
    const e = data[8..];
    put(u32, e, 0, @intCast(entry_len));
    @memcpy(e[4..8], options.codec);
    put(u16, e, 14, 1);
    put(u16, e, 16, options.version);
    put(u16, e, 24, options.channels);
    put(u16, e, 26, options.bits);
    put(u32, e, 32, (options.sample_rate & 0xffff) << 16);
    const actual_bits: u32 = if (std.mem.eql(u8, options.codec, "in24")) 24 else options.bits;
    if (options.version == 1) {
        put(u32, e, 36, 1);
        put(u32, e, 40, actual_bits / 8);
        put(u32, e, 44, (actual_bits / 8) * options.channels);
        put(u32, e, 48, options.bits / 8);
    } else if (options.version == 2) {
        put(u32, e, 36, 72);
        put(u64, e, 40, @bitCast(@as(f64, @floatFromInt(options.sample_rate))));
        put(u32, e, 48, options.channels);
        put(u32, e, 52, 0x7f000000);
        put(u32, e, 56, options.bits);
        put(u32, e, 60, options.flags);
        put(u32, e, 64, actual_bits / 8 * options.channels);
        put(u32, e, 68, 1);
    }
    if (options.wave_enda) |value| {
        const pos = entry_len - 18;
        put(u32, e, pos, 18);
        @memcpy(e[pos + 4 ..][0..4], "wave");
        put(u32, e, pos + 8, 10);
        @memcpy(e[pos + 12 ..][0..4], "enda");
        put(u16, e, pos + 16, value);
    }
    return data;
}

test "classic v0 v1 in24 legacy and v2 packed PCM layouts" {
    const cases = [_]struct { description: Description, endian: std.builtin.Endian, bits: u8 }{
        .{ .description = .{}, .endian = .little, .bits = 16 },
        .{ .description = .{ .codec = "twos", .bits = 24, .channels = 2 }, .endian = .big, .bits = 24 },
        .{ .description = .{ .codec = "sowt", .version = 1, .channels = 2 }, .endian = .little, .bits = 16 },
        .{ .description = .{ .codec = "in24", .version = 1, .bits = 16, .channels = 2 }, .endian = .big, .bits = 24 },
        .{ .description = .{ .codec = "in24", .version = 1, .wave_enda = 1 }, .endian = .little, .bits = 24 },
        .{ .description = .{ .codec = "lpcm", .version = 2, .sample_rate = 192000, .bits = 24, .channels = 2 }, .endian = .little, .bits = 24 },
        .{ .description = .{ .codec = "lpcm", .version = 2, .flags = 14 }, .endian = .big, .bits = 16 },
    };
    for (cases) |case| {
        const data = try description(case.description);
        defer testing.allocator.free(data);
        const fmt = try pcm.parseSampleDescription(data);
        try testing.expectEqual(case.endian, fmt.endian);
        try testing.expectEqual(case.bits, fmt.bits);
        try testing.expectEqual(case.description.sample_rate, fmt.sample_rate);
        try testing.expectEqual(case.description.channels, fmt.channels);
    }
}

test "PCM descriptions reject compressed float unsigned planar padded and ambiguous formats" {
    const codecs = [_]*const [4]u8{ "mp4a", "alac", "fl32", "raw ", "NONE" };
    for (codecs) |codec| {
        const data = try description(.{ .codec = codec });
        defer testing.allocator.free(data);
        try testing.expectError(error.UnsupportedCodec, pcm.parseSampleDescription(data));
    }
    for ([_]u32{ 13, 8, 44, 28, 4, 140 }) |flags| {
        const data = try description(.{ .codec = "lpcm", .version = 2, .flags = flags });
        defer testing.allocator.free(data);
        try testing.expectError(error.UnsupportedFormat, pcm.parseSampleDescription(data));
    }
    const data = try description(.{ .codec = "in24", .version = 1, .wave_enda = 1 });
    defer testing.allocator.free(data);
    put(u32, data, 8 + 44, 2); // nominal 16-bit frame bytes are NOT actual geometry
    try testing.expectError(error.UnsupportedPacketGeometry, pcm.parseSampleDescription(data));
    const v2 = try description(.{ .codec = "lpcm", .version = 2 });
    defer testing.allocator.free(v2);
    put(u64, v2, 8 + 40, @bitCast(std.math.nan(f64)));
    try testing.expectError(error.UnsupportedRate, pcm.parseSampleDescription(v2));
    put(u64, v2, 8 + 40, @bitCast(@as(f64, 44100.5)));
    try testing.expectError(error.UnsupportedRate, pcm.parseSampleDescription(v2));
    put(u64, v2, 8 + 40, @bitCast(@as(f64, 44100)));
    put(u32, v2, 8 + 64, 4);
    try testing.expectError(error.UnsupportedPacketGeometry, pcm.parseSampleDescription(v2));
    const conflicting = try description(.{ .codec = "sowt", .wave_enda = 0 });
    defer testing.allocator.free(conflicting);
    try testing.expectError(error.UnsupportedFormat, pcm.parseSampleDescription(conflicting));
}

test "sample entry and wave child boxes cannot escape their parents" {
    const data = try description(.{ .codec = "in24", .version = 1, .wave_enda = 1 });
    defer testing.allocator.free(data);
    put(u32, data, data.len - 10, 11);
    try testing.expectError(error.MalformedAudio, pcm.parseSampleDescription(data));
    put(u32, data, data.len - 10, 10);
    put(u32, data, 4, std.math.maxInt(u32));
    try testing.expectError(error.UnsupportedPacketGeometry, pcm.parseSampleDescription(data));
}

test "compact chunk reads duplicate mono and honor delayed trimmed presentation silence" {
    var bytes: [20]u8 = @splat(0xcc);
    for ([_]i16{ 1000, 2000, -3000, 4000 }, 0..) |value, i| {
        const offset: usize = if (i < 2) 2 + i * 2 else 12 + (i - 2) * 2;
        std.mem.writeInt(i16, bytes[offset..][0..2], value, .little);
    }
    const chunks = try testing.allocator.dupe(pcm.Chunk, &.{
        .{ .offset = 2, .first_frame = 0, .frame_count = 2 },
        .{ .offset = 12, .first_frame = 2, .frame_count = 2 },
    });
    var source: pcm.Source = .{
        .allocator = testing.allocator,
        .data = &bytes,
        .chunks = chunks,
        .format = .{ .sample_rate = 8000, .channels = 1, .bits = 16, .endian = .little },
        .info = .{ .sample_rate = 8000, .channels = 1, .bits_per_sample = 16, .frame_count = 6 },
        .timeline_start = 3,
        .source_start = 1,
        .window_frames = 2,
    };
    defer source.deinit();
    var out: [17]f32 = @splat(999);
    try testing.expectEqual(@as(usize, 8), source.read(0, &out));
    const values = [_]f32{ 0, 0, 0, 2000.0 / 32768.0, -3000.0 / 32768.0, 0, 0, 0 };
    for (values, 0..) |value, i| {
        try testing.expectEqual(value, out[i * 2]);
        try testing.expectEqual(value, out[i * 2 + 1]);
    }
    try testing.expectEqual(@as(f32, 999), out[16]);
    _ = source.read(4, &out);
    try testing.expectEqual(@as(f32, -3000.0 / 32768.0), out[0]);
    _ = source.read(std.math.maxInt(u64), &out);
    for (out[0..16]) |value| try testing.expectEqual(@as(f32, 0), value);
    try testing.expectEqual(@as(usize, 0), source.read(0, out[0..1]));
    var large: [8195]f32 = @splat(999);
    try testing.expectEqual(@as(usize, 4096), source.read(0, &large));
    for (large[8192..]) |value| try testing.expectEqual(@as(f32, 999), value);
}

test "stereo 24 bit reads keep channels distinct across chunks" {
    inline for (.{ .little, .big }) |order| {
        var bytes: [12]u8 = undefined;
        const values = [_]i24{ -8388608, 8388607, -1, 1 };
        for (values, 0..) |value, i| std.mem.writeInt(i24, bytes[i * 3 ..][0..3], value, order);
        var source: pcm.Source = .{
            .allocator = testing.allocator,
            .data = &bytes,
            .chunks = try testing.allocator.dupe(pcm.Chunk, &.{
                .{ .offset = 0, .first_frame = 0, .frame_count = 1 },
                .{ .offset = 6, .first_frame = 1, .frame_count = 1 },
            }),
            .format = .{ .sample_rate = 48000, .channels = 2, .bits = 24, .endian = order },
            .info = .{ .sample_rate = 48000, .channels = 2, .bits_per_sample = 24, .frame_count = 2 },
            .window_frames = 2,
        };
        defer source.deinit();
        var out: [6]f32 = undefined;
        try testing.expectEqual(@as(usize, 3), source.read(0, &out));
        for (values, 0..) |value, i| try testing.expectEqual(@as(f32, @floatFromInt(value)) / 8388608, out[i]);
        try testing.expectEqual(@as(f32, 0), out[4]);
        try testing.expectEqual(@as(f32, 0), out[5]);
    }
}

test "PCM range validation keeps offsets and addition 64 bit" {
    try pcm.validateChunk((@as(u64, 1) << 32) + 9, 6, (@as(u64, 1) << 32) + 15);
    try testing.expectError(error.InvalidAudioOffsets, pcm.validateChunk((@as(u64, 1) << 32) + 9, 6, (@as(u64, 1) << 32) + 14));
    try testing.expectError(error.InvalidAudioOffsets, pcm.validateChunk(std.math.maxInt(u64) - 2, 6, std.math.maxInt(u64)));
}

// Synthetic MOV metadata uses the fixture's existing Hap video payload only;
// every audio table/layout/edit below is generated here, with no codec tools.
const Buffer = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    fn deinit(self: *Buffer) void {
        self.bytes.deinit(testing.allocator);
    }
    fn add(self: *Buffer, data: []const u8) !void {
        try self.bytes.appendSlice(testing.allocator, data);
    }
    fn int(self: *Buffer, comptime T: type, value: T) !void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .big);
        try self.add(&bytes);
    }
    fn begin(self: *Buffer, name: *const [4]u8) !usize {
        const offset = self.bytes.items.len;
        try self.int(u32, 0);
        try self.add(name);
        return offset;
    }
    fn end(self: *Buffer, offset: usize) void {
        put(u32, self.bytes.items, offset, @intCast(self.bytes.items.len - offset));
    }
    fn box(self: *Buffer, name: *const [4]u8, data: []const u8) !void {
        const offset = try self.begin(name);
        try self.add(data);
        self.end(offset);
    }
};

const Raw = struct { offset: usize, size: usize };
fn rawChild(data: []const u8, name: *const [4]u8, occurrence: usize) !Raw {
    var offset: usize = 0;
    var count: usize = 0;
    while (offset + 8 <= data.len) {
        const size = std.mem.readInt(u32, data[offset..][0..4], .big);
        if (size < 8 or size > data.len - offset) return error.TestUnexpectedResult;
        if (std.mem.eql(u8, data[offset + 4 ..][0..4], name)) {
            if (count == occurrence) return .{ .offset = offset, .size = size };
            count += 1;
        }
        offset += size;
    }
    return error.TestUnexpectedResult;
}

const Edit = struct { duration: u64, media_time: i64, rate: u32 = 0x10000 };
const Movie = struct {
    format: Description = .{},
    samples: u32 = 32,
    packet_bytes: u32 = 2,
    duration: u32 = 1,
    timescale: u32 = 8000,
    chunk_samples: []const u32 = &.{ 8, 8, 8, 8 },
    edits: []const Edit = &.{},
    edit_version: u8 = 0,
    invalid_offset: ?u64 = null,
    description_index: u32 = 1,
    second_audio: bool = false,
    video_trim: bool = false,
    composition_offset: ?i32 = null,
    duplicate_composition_offset: ?i32 = null,
    duplicate_media_header: bool = false,
    shadow_chunk_offsets: bool = false,
};

fn syntheticMovie(options: Movie) ![]u8 {
    var fixture = try support.openFixture("tests/fixtures/hap1_audio.mov");
    defer fixture.deinit();
    const original = fixture.reader.data;
    const moov = try rawChild(original, "moov", 0);
    const old_moov = original[moov.offset + 8 ..][0 .. moov.size - 8];
    const mvhd = try rawChild(old_moov, "mvhd", 0);
    const video = try rawChild(old_moov, "trak", 0);
    const audio = try rawChild(old_moov, "trak", 1);
    const old_audio = old_moov[audio.offset + 8 ..][0 .. audio.size - 8];
    const tkhd = try rawChild(old_audio, "tkhd", 0);
    var out: Buffer = .{};
    errdefer out.deinit();
    try out.add(original[0..moov.offset]);
    const mdat = try out.begin("mdat");
    const audio_offset = out.bytes.items.len;
    // Keep the stored payload bounded even for corrupt oversized sample counts.
    const stored_bytes = @min(@as(u64, options.samples) * options.packet_bytes, 4096);
    for (0..@intCast(stored_bytes)) |i| try out.int(u8, @intCast((i % 127) + 1));
    out.end(mdat);
    const new_moov = try out.begin("moov");
    try out.add(old_moov[mvhd.offset..][0..mvhd.size]);
    const new_video = out.bytes.items.len;
    try out.add(old_moov[video.offset..][0..video.size]);
    if (options.video_trim) {
        const relative = std.mem.indexOf(u8, out.bytes.items[new_video..], "elst") orelse return error.TestUnexpectedResult;
        put(u32, out.bytes.items, new_video + relative + 16, 1);
    }
    const trak = try out.begin("trak");
    try out.add(old_audio[tkhd.offset..][0..tkhd.size]);
    if (options.edits.len > 0) {
        const edts = try out.begin("edts");
        const elst = try out.begin("elst");
        try out.int(u32, @as(u32, options.edit_version) << 24);
        try out.int(u32, @intCast(options.edits.len));
        for (options.edits) |edit| {
            if (options.edit_version == 1) {
                try out.int(u64, edit.duration);
                try out.int(i64, edit.media_time);
            } else {
                try out.int(u32, @intCast(edit.duration));
                try out.int(i32, @intCast(edit.media_time));
            }
            try out.int(u32, edit.rate);
        }
        out.end(elst);
        out.end(edts);
    }
    const mdia = try out.begin("mdia");
    const mdhd = try out.begin("mdhd");
    try out.int(u32, 0x01000000);
    try out.int(u64, 0);
    try out.int(u64, 0);
    try out.int(u32, options.timescale);
    try out.int(u64, @as(u64, options.samples) * options.duration);
    try out.int(u32, 0);
    out.end(mdhd);
    if (options.duplicate_media_header) {
        const copy = try testing.allocator.dupe(u8, out.bytes.items[mdhd..]);
        defer testing.allocator.free(copy);
        try out.add(copy);
    }
    const hdlr = try out.begin("hdlr");
    try out.int(u64, 0);
    try out.add("soun");
    try out.int(u64, 0);
    try out.int(u32, 0);
    out.end(hdlr);
    const minf = try out.begin("minf");
    const stbl = try out.begin("stbl");
    const desc = try description(options.format);
    defer testing.allocator.free(desc);
    try out.box("stsd", desc);
    const stts = try out.begin("stts");
    try out.int(u32, 0);
    try out.int(u32, 1);
    try out.int(u32, options.samples);
    try out.int(u32, options.duration);
    out.end(stts);
    for ([_]?i32{ options.composition_offset, options.duplicate_composition_offset }) |maybe_offset| if (maybe_offset) |offset| {
        const ctts = try out.begin("ctts");
        try out.int(u32, 0);
        try out.int(u32, 1);
        try out.int(u32, options.samples);
        try out.int(i32, offset);
        out.end(ctts);
    };
    const stsc = try out.begin("stsc");
    try out.int(u32, 0);
    try out.int(u32, @intCast(options.chunk_samples.len));
    for (options.chunk_samples, 1..) |samples, i| {
        try out.int(u32, @intCast(i));
        try out.int(u32, samples);
        try out.int(u32, options.description_index);
    }
    out.end(stsc);
    const stsz = try out.begin("stsz");
    try out.int(u32, 0);
    try out.int(u32, options.packet_bytes);
    try out.int(u32, options.samples);
    if (options.packet_bytes == 0) for (0..options.samples) |_| try out.int(u32, 2);
    out.end(stsz);
    const co64 = try out.begin("co64");
    try out.int(u32, 0);
    try out.int(u32, @intCast(options.chunk_samples.len));
    var chunk_offset: u64 = audio_offset;
    for (options.chunk_samples) |samples| {
        try out.int(u64, options.invalid_offset orelse chunk_offset);
        chunk_offset += @as(u64, samples) * options.packet_bytes;
    }
    out.end(co64);
    out.end(stbl);
    if (options.shadow_chunk_offsets) {
        // minimp4 also accepts a misplaced table outside stbl and replaces
        // the in-parent one. Matching counts alone cannot identify it.
        const copy = try testing.allocator.dupe(u8, out.bytes.items[co64..]);
        defer testing.allocator.free(copy);
        for (options.chunk_samples, 0..) |_, i| put(u64, copy, 16 + i * 8, 0);
        try out.add(copy);
    }
    out.end(minf);
    out.end(mdia);
    out.end(trak);
    if (options.second_audio) try out.add(old_moov[audio.offset..][0..audio.size]);
    out.end(new_moov);
    return out.bytes.toOwnedSlice(testing.allocator);
}

fn openSynthetic(bytes: []const u8) !demuxer.Demuxer {
    const reader: MmapReader = .{ .data = bytes, .path = "<synthetic PCM MOV>" };
    var dem: demuxer.Demuxer = .{};
    errdefer dem.deinit(testing.allocator);
    try dem.open(testing.allocator, &reader);
    return dem;
}

test "MOV compact PCM index no edit identity delayed trim and EOS silence" {
    const edit_lists = [_][]const Edit{
        &.{},
        &.{.{ .duration = 4, .media_time = 0 }},
        &.{ .{ .duration = 1, .media_time = -1 }, .{ .duration = 2, .media_time = 8 } },
        &.{.{ .duration = 2, .media_time = 8 }},
    };
    inline for (.{ 0, 1 }) |version| {
        for (edit_lists, 0..) |edit_list, case| {
            const bytes = try syntheticMovie(.{ .edits = edit_list, .edit_version = version });
            defer testing.allocator.free(bytes);
            var dem = try openSynthetic(bytes);
            defer dem.deinit(testing.allocator);
            try testing.expect(dem.valid);
            try testing.expect(dem.audio_warning == null);
            const audio = &dem.audio.?;
            try testing.expectEqual(@as(usize, 4), audio.chunks.len);
            try testing.expectEqual(@as(u64, if (case < 2) 32 else if (case == 2) 24 else 16), audio.info.frame_count);
            const delay: u64 = if (case == 2) 8 else 0;
            const trim: u64 = if (case >= 2) 8 else 0;
            var output: [84]f32 = undefined;
            _ = audio.read(0, &output);
            for (0..42) |i| {
                const active = i >= delay and i < audio.info.frame_count;
                const expected: f32 = if (active) blk: {
                    const source_frame = i - delay + trim;
                    const chunk = audio.chunks[source_frame / 8];
                    const offset = chunk.offset + source_frame % 8 * 2;
                    break :blk pcm.convert(bytes[offset..][0..2], 16, .little);
                } else 0;
                try testing.expectEqual(expected, output[i * 2]);
                try testing.expectEqual(expected, output[i * 2 + 1]);
            }
            _ = audio.read(delay + 7, &output);
            const source_frame = trim + 7;
            const chunk = audio.chunks[source_frame / 8];
            const offset = chunk.offset + source_frame % 8 * 2;
            try testing.expectEqual(pcm.convert(bytes[offset..][0..2], 16, .little), output[0]);
            _ = audio.read(std.math.maxInt(u64) - 1, &output);
            for (output) |sample| try testing.expectEqual(@as(f32, 0), sample);
        }
    }
}

test "MOV PCM geometry permits packetized PCM and differing media timescales" {
    const bytes = try syntheticMovie(.{ .samples = 16, .packet_bytes = 4, .timescale = 48000, .duration = 12, .chunk_samples = &.{ 8, 8 } });
    defer testing.allocator.free(bytes);
    var dem = try openSynthetic(bytes);
    defer dem.deinit(testing.allocator);
    try testing.expect(dem.audio_warning == null);
    try testing.expectEqual(@as(u64, 32), dem.audio.?.info.frame_count);
    try testing.expectEqual(@as(usize, 2), dem.audio.?.chunks.len);
}

test "audio edits use ceiling presentation boundaries and reject unaligned media trims" {
    const bytes = try syntheticMovie(.{
        .format = .{ .sample_rate = 11025 },
        .timescale = 11025,
        .edits = &.{ .{ .duration = 1, .media_time = -1 }, .{ .duration = 1, .media_time = 0 } },
    });
    defer testing.allocator.free(bytes);
    var dem = try openSynthetic(bytes);
    defer dem.deinit(testing.allocator);
    try testing.expect(dem.audio_warning == null);
    try testing.expectEqual(@as(u64, 12), dem.audio.?.timeline_start);
    try testing.expectEqual(@as(u64, 23), dem.audio.?.info.frame_count);
    var output: [4]f32 = undefined;
    _ = dem.audio.?.read(11, &output);
    try testing.expectEqual(@as(f32, 0), output[0]);
    try testing.expect(output[2] != 0);
    const unaligned = try syntheticMovie(.{
        .samples = 16,
        .packet_bytes = 4,
        .timescale = 48000,
        .duration = 12,
        .chunk_samples = &.{ 8, 8 },
        .edits = &.{.{ .duration = 1, .media_time = 1 }},
    });
    defer testing.allocator.free(unaligned);
    var invalid = try openSynthetic(unaligned);
    defer invalid.deinit(testing.allocator);
    try testing.expect(invalid.valid);
    try testing.expectEqual(pcm.AudioWarning.unsupported_edits, invalid.audio_warning.?);
}

test "MOV classic in24 legacy enda and v2 lpcm construct valid source geometry" {
    for ([_]Movie{
        .{ .format = .{ .codec = "in24", .version = 1 }, .packet_bytes = 3 },
        .{ .format = .{ .codec = "in24", .version = 1, .wave_enda = 1 }, .packet_bytes = 3 },
        .{ .format = .{ .codec = "in24", .version = 1, .channels = 2, .wave_enda = 1 }, .packet_bytes = 6 },
        .{ .format = .{ .codec = "lpcm", .version = 2, .bits = 24, .channels = 2, .flags = 14 }, .packet_bytes = 6 },
    }) |options| {
        const bytes = try syntheticMovie(options);
        defer testing.allocator.free(bytes);
        var dem = try openSynthetic(bytes);
        defer dem.deinit(testing.allocator);
        try testing.expect(dem.audio_warning == null);
        const audio = &dem.audio.?;
        try testing.expectEqual(@as(u8, 24), audio.info.bits_per_sample);
        var output: [4]f32 = undefined;
        _ = audio.read(8, &output);
        const offset = audio.chunks[1].offset;
        try testing.expectEqual(pcm.convert(bytes[offset..][0..3], 24, audio.format.endian), output[0]);
    }
}

test "unsupported first audio and malformed PCM do not fail Hap video" {
    const cases = [_]struct { options: Movie, warning: pcm.AudioWarning }{
        .{ .options = .{ .format = .{ .codec = "mp4a" }, .second_audio = true }, .warning = .unsupported_codec },
        .{ .options = .{ .format = .{ .channels = 3 } }, .warning = .unsupported_channels },
        .{ .options = .{ .format = .{ .sample_rate = 4000 } }, .warning = .unsupported_rate },
        .{ .options = .{ .format = .{ .codec = "lpcm", .version = 2, .flags = 13 } }, .warning = .unsupported_format },
        .{ .options = .{ .invalid_offset = (@as(u64, 1) << 32) + 50 }, .warning = .invalid_audio_offsets },
        .{ .options = .{ .invalid_offset = std.math.maxInt(u64) - 3 }, .warning = .invalid_audio_offsets },
        .{ .options = .{ .description_index = 2 }, .warning = .unsupported_packet_geometry },
        .{ .options = .{ .shadow_chunk_offsets = true }, .warning = .unsupported_packet_geometry },
        .{ .options = .{ .packet_bytes = 0 }, .warning = .unsupported_packet_geometry },
        .{ .options = .{ .format = .{ .version = 1 }, .packet_bytes = 4, .duration = 2 }, .warning = .unsupported_packet_geometry },
        .{ .options = .{ .samples = std.math.maxInt(u32), .chunk_samples = &.{std.math.maxInt(u32)} }, .warning = .unsupported_packet_geometry },
        .{ .options = .{ .chunk_samples = &.{ 8, 8, 8, 7 } }, .warning = .unsupported_packet_geometry },
        .{ .options = .{ .duration = 2 }, .warning = .unsupported_packet_geometry },
        .{ .options = .{ .composition_offset = 1 }, .warning = .unsupported_edits },
        .{ .options = .{ .video_trim = true }, .warning = .incompatible_video_timing },
        .{ .options = .{ .edits = &.{.{ .duration = 4, .media_time = 0, .rate = 0x8000 }} }, .warning = .unsupported_edits },
        .{ .options = .{ .edits = &.{ .{ .duration = 1, .media_time = 1 }, .{ .duration = 2, .media_time = 8 } } }, .warning = .unsupported_edits },
        .{ .options = .{ .edits = &.{.{ .duration = 4, .media_time = 33 }} }, .warning = .unsupported_edits },
        .{ .options = .{ .edit_version = 1, .edits = &.{ .{ .duration = std.math.maxInt(u64), .media_time = -1 }, .{ .duration = 4, .media_time = 0 } } }, .warning = .unsupported_edits },
    };
    for (cases, 0..) |case, case_index| {
        const bytes = try syntheticMovie(case.options);
        defer testing.allocator.free(bytes);
        var dem = openSynthetic(bytes) catch |err| {
            std.debug.print("PCM warning case {d} rejected video: {t}\n", .{ case_index, err });
            return err;
        };
        defer dem.deinit(testing.allocator);
        try testing.expect(dem.valid);
        try testing.expect(dem.track.frame_count > 0);
        try testing.expect(dem.audio == null);
        try testing.expectEqual(case.warning, dem.audio_warning.?);
        try testing.expect(case.warning.message().len > 0);
    }
}

test "malformed nested audio metadata warns without failing video open" {
    const bytes = try syntheticMovie(.{ .format = .{ .codec = "in24", .version = 1, .wave_enda = 1 }, .packet_bytes = 3 });
    defer testing.allocator.free(bytes);
    const enda_type = std.mem.lastIndexOf(u8, bytes, "enda") orelse return error.TestUnexpectedResult;
    put(u32, bytes, enda_type - 4, 11); // escapes its wave parent by one byte
    var dem = try openSynthetic(bytes);
    defer dem.deinit(testing.allocator);
    try testing.expect(dem.valid);
    try testing.expect(dem.audio == null);
    try testing.expectEqual(pcm.AudioWarning.malformed_audio, dem.audio_warning.?);
}

test "duplicate audio media and composition boxes cannot select conflicting interpretations" {
    for ([_]Movie{
        .{ .duplicate_media_header = true },
        .{ .composition_offset = 0, .duplicate_composition_offset = 1 },
    }) |options| {
        const bytes = try syntheticMovie(options);
        defer testing.allocator.free(bytes);
        var dem = try openSynthetic(bytes);
        defer dem.deinit(testing.allocator);
        try testing.expect(dem.valid);
        try testing.expect(dem.audio == null);
        try testing.expectEqual(pcm.AudioWarning.malformed_audio, dem.audio_warning.?);
        try testing.expect(dem.sampleData(&.{ .data = bytes, .path = "<duplicate audio>" }, 0) != null);
    }
}

test "bundled audio fixture is 88200 mono frames in 60 compact chunks" {
    var fixture = try support.openFixture("tests/fixtures/hap1_audio.mov");
    defer fixture.deinit();
    try testing.expect(fixture.demuxer.audio_warning == null);
    const audio = &fixture.demuxer.audio.?;
    try testing.expectEqual(@as(u32, 44100), audio.info.sample_rate);
    try testing.expectEqual(@as(u8, 1), audio.info.channels);
    try testing.expectEqual(@as(u8, 16), audio.info.bits_per_sample);
    try testing.expectEqual(@as(u64, 88200), audio.info.frame_count);
    try testing.expectEqual(@as(usize, 60), audio.chunks.len);
    var output: [2048]f32 = undefined;
    _ = audio.read(1024, &output);
    var nonzero = false;
    for (0..1024) |i| {
        try testing.expectEqual(output[i * 2], output[i * 2 + 1]);
        nonzero = nonzero or output[i * 2] != 0;
    }
    try testing.expect(nonzero);
    _ = audio.read(88199, &output);
    for (output[2..]) |value| try testing.expectEqual(@as(f32, 0), value);
}

test "generated big endian stereo fixtures retain distinct channels and late source content" {
    const fixtures = [_]struct { path: []const u8, bits: u8 }{
        .{ .path = "tests/fixtures/hap1_pcm16be_stereo.mov", .bits = 16 },
        .{ .path = "tests/fixtures/hap1_pcm24be_stereo.mov", .bits = 24 },
    };
    for (fixtures) |case| {
        var fixture = try support.openFixture(case.path);
        defer fixture.deinit();
        try testing.expect(fixture.demuxer.audio_warning == null);
        const audio = &fixture.demuxer.audio.?;
        try testing.expectEqual(@as(u32, 48000), audio.info.sample_rate);
        try testing.expectEqual(@as(u8, 2), audio.info.channels);
        try testing.expectEqual(case.bits, audio.info.bits_per_sample);
        try testing.expectEqual(@as(u64, 96000), audio.info.frame_count);
        try testing.expectEqual(std.builtin.Endian.big, audio.format.endian);
        var output: [400]f32 = undefined;
        for ([_]u64{ 24000, 72000 }, 0..) |start, index| {
            try testing.expectEqual(@as(usize, 200), audio.read(start, &output));
            var left: f64 = 0;
            var right: f64 = 0;
            for (0..200) |frame| {
                left += @as(f64, output[frame * 2]) * output[frame * 2];
                right += @as(f64, output[frame * 2 + 1]) * output[frame * 2 + 1];
            }
            if (index == 0) try testing.expect(left > right * 8) else try testing.expect(right > left * 8);
        }
    }
}

test "audio index allocation failure is a warning and preserves playable video" {
    const bytes = try syntheticMovie(.{});
    defer testing.allocator.free(bytes);
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    const allocator = failing.allocator();
    const reader: MmapReader = .{ .data = bytes, .path = "<PCM allocation failure>" };
    var dem: demuxer.Demuxer = .{};
    defer dem.deinit(allocator);
    try dem.open(allocator, &reader);
    try testing.expect(dem.valid);
    try testing.expect(dem.audio == null);
    try testing.expectEqual(pcm.AudioWarning.out_of_memory, dem.audio_warning.?);
    try testing.expect(dem.sampleData(&reader, 0) != null);
}

test "PCM stbl parent containment and duplicate descriptions are validated independently" {
    const bytes = try syntheticMovie(.{});
    defer testing.allocator.free(bytes);
    var dem = try openSynthetic(bytes);
    defer dem.deinit(testing.allocator);
    const moov = try rawChild(bytes, "moov", 0);
    const moov_data = bytes[moov.offset + 8 ..][0 .. moov.size - 8];
    const audio = try rawChild(moov_data, "trak", 1);
    const trak_offset = moov.offset + 8 + audio.offset;
    const trak = bytes[trak_offset + 8 ..][0 .. audio.size - 8];
    const mdia = try rawChild(trak, "mdia", 0);
    const mdia_offset = trak_offset + 8 + mdia.offset;
    const minf = try rawChild(bytes[mdia_offset + 8 ..][0 .. mdia.size - 8], "minf", 0);
    const minf_offset = mdia_offset + 8 + minf.offset;
    const stbl = try rawChild(bytes[minf_offset + 8 ..][0 .. minf.size - 8], "stbl", 0);
    const stbl_offset = minf_offset + 8 + stbl.offset;
    const stbl_data = bytes[stbl_offset + 8 ..][0 .. stbl.size - 8];
    const offsets = try rawChild(stbl_data, "co64", 0);
    const table_offset = stbl_offset + 8 + offsets.offset;
    put(u32, bytes, table_offset, @intCast(offsets.size + 1));
    try testing.expectError(error.MalformedAudio, pcm.Source.open(testing.allocator, bytes, dem.mp4.?, 0));
    put(u32, bytes, table_offset, @intCast(offsets.size));
    const stsd = try rawChild(stbl_data, "stsd", 0);
    put(u32, bytes, stbl_offset + 8 + stsd.offset + 12, 2);
    try testing.expectError(error.UnsupportedPacketGeometry, pcm.Source.open(testing.allocator, bytes, dem.mp4.?, 0));
}

test "bounded randomized PCM reads cover odd empty EOS and huge starts" {
    var fixture = try support.openFixture("tests/fixtures/hap1_audio.mov");
    defer fixture.deinit();
    const audio = &fixture.demuxer.audio.?;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    var output: [135]f32 = undefined;
    for (0..2048) |i| {
        const start = if (i % 16 == 0) random.int(u64) else random.intRangeAtMost(u64, 0, 180000);
        const len = random.intRangeAtMost(usize, 0, output.len);
        @memset(&output, 987);
        const written = audio.read(start, output[0..len]);
        try testing.expectEqual(len / 2, written);
        for (0..written) |frame| {
            const position = std.math.add(u64, start, frame) catch std.math.maxInt(u64);
            var expected: f32 = 0;
            if (position < audio.info.frame_count) {
                for (audio.chunks) |chunk| {
                    if (position >= chunk.first_frame and position - chunk.first_frame < chunk.frame_count) {
                        const offset = chunk.offset + (position - chunk.first_frame) * 2;
                        expected = pcm.convert(fixture.reader.data[offset..][0..2], 16, .little);
                        break;
                    }
                }
            }
            try testing.expectEqual(expected, output[frame * 2]);
            try testing.expectEqual(expected, output[frame * 2 + 1]);
        }
        for (output[written * 2 ..]) |value| try testing.expectEqual(@as(f32, 987), value);
    }
}

test "scheduler PCM facade is published with open and independent of video decode" {
    const Scheduler = @import("decode_scheduler.zig").DecodeScheduler;
    const pool = @import("outer_thread_pool.zig");
    if (!support.fixtureExists("tests/fixtures/hap1_audio.mov")) return error.SkipZigTest;
    var scheduler = try Scheduler.init(testing.allocator);
    defer scheduler.deinit();
    var output: [133]f32 = @splat(123);
    try testing.expect(scheduler.audioInfo() == null);
    try testing.expect(scheduler.audioWarning() == null);
    try testing.expectEqual(@as(usize, 0), scheduler.readAudio(0, &output));
    try testing.expectEqual(@as(f32, 123), output[0]);
    try scheduler.openAsync("tests/fixtures/hap1_audio.mov");
    const Opened = struct {
        fn check(s: *Scheduler) bool {
            return s.openStatus() == .open or s.openStatus() == .failed;
        }
    };
    try testing.expect(support.waitFor(*Scheduler, &scheduler, Opened.check, 5000));
    try testing.expect(scheduler.isOpen());
    try testing.expectEqual(@as(u64, 88200), scheduler.audioInfo().?.frame_count);
    try testing.expect(scheduler.audioWarning() == null);
    for (0..128) |i| {
        // Retarget the existing video worker while main-thread PCM reads use
        // only the immutable chunk index, not MP4D_frame_offset's caches.
        try testing.expect(scheduler.requestFrame(@intCast(i % 60), i % 2 == 0));
        const start = i * 617 % 88200;
        try testing.expectEqual(@as(usize, 66), scheduler.readAudio(start, &output));
        try testing.expectEqual(@as(f32, 123), output[132]);
        const audio = &scheduler.demuxer.audio.?;
        var expected: [132]f32 = undefined;
        _ = audio.read(start, &expected);
        try testing.expectEqualSlices(f32, &expected, output[0..132]);
    }
    pool.instance().waitForStreamIdle(scheduler.streamId());
    try testing.expect(scheduler.decodeError() == null);
    _ = scheduler.readAudio(std.math.maxInt(u64), &output);
    for (output[0..132]) |value| try testing.expectEqual(@as(f32, 0), value);
}
