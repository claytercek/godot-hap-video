//! Test the compact index and C shim without Godot or the demuxer.
//! Run standalone or through core.zig's test block.
const std = @import("std");
const testing = std.testing;

const Context = opaque {};
extern fn hap_mp4d_open(data: ?[*]const u8, size: i64) ?*Context;
extern fn hap_mp4d_close(ctx: ?*Context) void;
extern fn hap_mp4d_track_count(ctx: ?*const Context) c_uint;
extern fn hap_mp4d_track_sample_count(ctx: ?*const Context, track: c_uint) c_uint;
extern fn hap_mp4d_track_timescale(ctx: ?*const Context, track: c_uint) c_uint;
extern fn hap_mp4d_track_constant_sample_size(ctx: ?*const Context, track: c_uint) c_uint;
extern fn hap_mp4d_track_sample_size(ctx: ?*const Context, track: c_uint, sample: c_uint) c_uint;
extern fn hap_mp4d_track_chunk_count(ctx: ?*const Context, track: c_uint) c_uint;
extern fn hap_mp4d_track_chunk_offset(ctx: ?*const Context, track: c_uint, chunk: c_uint, offset: ?*u64) c_int;
extern fn hap_mp4d_track_stsc_count(ctx: ?*const Context, track: c_uint) c_uint;
extern fn hap_mp4d_track_stsc_entry(ctx: ?*const Context, track: c_uint, entry: c_uint, first: ?*c_uint, samples: ?*c_uint, description: ?*c_uint) c_int;
extern fn hap_mp4d_track_timing_run_count(ctx: ?*const Context, track: c_uint) c_uint;
extern fn hap_mp4d_track_timing_run(ctx: ?*const Context, track: c_uint, entry: c_uint, samples: ?*c_uint, duration: ?*c_uint) c_int;
extern fn hap_mp4d_frame_offset(ctx: ?*const Context, track: c_uint, sample: c_uint, bytes: ?*c_uint, timestamp: ?*c_uint, duration: ?*c_uint) u64;

const Run = struct { samples: u32, duration: u32 };
const ChunkRun = struct { first: u32, samples: u32, description: u32 = 1 };

const Fixture = struct {
    bytes: [4096]u8 = @splat(0),
    len: usize = 0,

    fn init() Fixture {
        var f: Fixture = .{};
        _ = f.begin("moov");
        _ = f.begin("trak");
        return f;
    }

    fn word(f: *Fixture, value: u32) void {
        std.mem.writeInt(u32, f.bytes[f.len..][0..4], value, .big);
        f.len += 4;
    }

    fn begin(f: *Fixture, kind: *const [4]u8) usize {
        const start = f.len;
        f.word(0);
        @memcpy(f.bytes[f.len..][0..4], kind);
        f.len += 4;
        return start;
    }

    fn full(f: *Fixture, kind: *const [4]u8) usize {
        const start = f.begin(kind);
        f.word(0);
        return start;
    }

    fn end(f: *Fixture, start: usize) void {
        std.mem.writeInt(u32, f.bytes[start..][0..4], @intCast(f.len - start), .big);
    }

    fn sizes(f: *Fixture, constant: u32, count: u32, entries: []const u32) void {
        const start = f.full("stsz");
        f.word(constant);
        f.word(count);
        for (entries) |entry| f.word(entry);
        f.end(start);
    }

    fn timing(f: *Fixture, entries: []const Run) void {
        const start = f.full("stts");
        f.word(@intCast(entries.len));
        for (entries) |entry| {
            f.word(entry.samples);
            f.word(entry.duration);
        }
        f.end(start);
    }

    fn chunks(f: *Fixture, entries: []const u64) void {
        const start = f.full("co64");
        f.word(@intCast(entries.len));
        for (entries) |entry| {
            f.word(@truncate(entry >> 32));
            f.word(@truncate(entry));
        }
        f.end(start);
    }

    fn mapping(f: *Fixture, entries: []const ChunkRun) void {
        const start = f.full("stsc");
        f.word(@intCast(entries.len));
        for (entries) |entry| {
            f.word(entry.first);
            f.word(entry.samples);
            f.word(entry.description);
        }
        f.end(start);
    }

    fn finish(f: *Fixture) []const u8 {
        f.end(8); // trak
        f.end(0); // moov
        return f.bytes[0..f.len];
    }

    fn open(f: *Fixture) !*Context {
        const bytes = f.finish();
        return hap_mp4d_open(bytes.ptr, @intCast(bytes.len)) orelse error.ParseFailed;
    }
};

fn expectFrame(ctx: *const Context, sample: u32, offset: u64, bytes: u32, timestamp: u32, duration: u32) !void {
    var actual_bytes: c_uint = 999;
    var actual_timestamp: c_uint = 999;
    var actual_duration: c_uint = 999;
    try testing.expectEqual(offset, hap_mp4d_frame_offset(ctx, 0, sample, &actual_bytes, &actual_timestamp, &actual_duration));
    try testing.expectEqual(bytes, actual_bytes);
    try testing.expectEqual(timestamp, actual_timestamp);
    try testing.expectEqual(duration, actual_duration);
}

test "constant PCM hour retains scalar sizes and one compact timing run" {
    // Even one expanded u32 array would require 691 MiB, exceeding the
    // unchanged 256 MiB metadata budget. Successful parsing of this tiny
    // fixture therefore also guards against per-PCM-sample expansion.
    const count = 48_000 * 60 * 60;
    var f = Fixture.init();
    f.sizes(4, count, &.{});
    f.timing(&.{.{ .samples = count, .duration = 1 }});
    f.mapping(&.{.{ .first = 1, .samples = count, .description = 7 }});
    f.chunks(&.{4096});
    const ctx = try f.open();
    defer hap_mp4d_close(ctx);
    try testing.expectEqual(count, hap_mp4d_track_sample_count(ctx, 0));
    try testing.expectEqual(4, hap_mp4d_track_constant_sample_size(ctx, 0));
    try testing.expectEqual(4, hap_mp4d_track_sample_size(ctx, 0, count - 1));
    try testing.expectEqual(1, hap_mp4d_track_timing_run_count(ctx, 0));
    try expectFrame(ctx, count - 1, 4096 + @as(u64, count - 1) * 4, 4, count - 1, 1);
}

test "timing and chunk prefixes are 64 bit with legacy low 32 bit timestamps" {
    const max = std.math.maxInt(u32);
    const large_offset: u64 = (@as(u64, 1) << 32) + 123;
    var f = Fixture.init();
    f.sizes(8, max, &.{});
    f.timing(&.{
        .{ .samples = 0, .duration = 99 },
        .{ .samples = max - 2, .duration = max },
        .{ .samples = 2, .duration = 7 },
        .{ .samples = 10, .duration = 11 },
    });
    f.mapping(&.{
        .{ .first = 1, .samples = max - 2 },
        .{ .first = 2, .samples = max, .description = 3 },
    });
    f.chunks(&.{ large_offset, large_offset + 1000, large_offset + 2000 });
    const ctx = try f.open();
    defer hap_mp4d_close(ctx);
    try expectFrame(ctx, max - 1, large_offset + 1008, 8, 10, 7);
    try expectFrame(ctx, 0, large_offset, 8, 0, max);
    try expectFrame(ctx, max - 2, large_offset + 1000, 8, 3, 7);
    try expectFrame(ctx, max - 1, large_offset + 1008, 8, 10, 7);
}

test "variable video sizes and random or sequential frame lookup remain compatible" {
    var f = Fixture.init();
    f.sizes(0, 6, &.{ 11, 22, 33, 44, 55, 66 });
    f.timing(&.{ .{ .samples = 2, .duration = 40 }, .{ .samples = 4, .duration = 41 } });
    f.mapping(&.{ .{ .first = 1, .samples = 2 }, .{ .first = 3, .samples = 2, .description = 7 } });
    f.chunks(&.{ 500, 1000, 2000 });
    const ctx = try f.open();
    defer hap_mp4d_close(ctx);
    try testing.expectEqual(0, hap_mp4d_track_constant_sample_size(ctx, 0));
    try testing.expectEqual(3, hap_mp4d_track_chunk_count(ctx, 0));
    try testing.expectEqual(2, hap_mp4d_track_stsc_count(ctx, 0));
    var first: c_uint = 0;
    var samples: c_uint = 0;
    var description: c_uint = 0;
    try testing.expectEqual(1, hap_mp4d_track_stsc_entry(ctx, 0, 1, &first, &samples, &description));
    try testing.expectEqual(3, first);
    try testing.expectEqual(2, samples);
    try testing.expectEqual(7, description);
    try testing.expectEqual(1, hap_mp4d_track_timing_run(ctx, 0, 1, &samples, &description));
    try testing.expectEqual(4, samples);
    try testing.expectEqual(41, description);
    var offset: u64 = 0;
    try testing.expectEqual(1, hap_mp4d_track_chunk_offset(ctx, 0, 2, &offset));
    try testing.expectEqual(2000, offset);

    const offsets = [_]u64{ 500, 511, 1000, 1033, 2000, 2055 };
    const timestamps = [_]u32{ 0, 40, 80, 121, 162, 203 };
    for ([_]u32{ 0, 1, 2, 5, 3, 4, 0 }) |sample| {
        try testing.expectEqual((sample + 1) * 11, hap_mp4d_track_sample_size(ctx, 0, sample));
        try expectFrame(ctx, sample, offsets[sample], (sample + 1) * 11, timestamps[sample], if (sample < 2) 40 else 41);
    }
}

test "all shim accessors reject null and out of range indices without changing entry outputs" {
    var f = Fixture.init();
    f.sizes(4, 1, &.{});
    f.timing(&.{.{ .samples = 1, .duration = 1 }});
    f.mapping(&.{.{ .first = 1, .samples = 1 }});
    f.chunks(&.{123});
    const ctx = try f.open();
    defer hap_mp4d_close(ctx);
    const max = std.math.maxInt(c_uint);
    for ([_]?*const Context{ null, ctx }) |handle| {
        const track: c_uint = if (handle == null) 0 else max;
        try testing.expectEqual(0, hap_mp4d_track_sample_count(handle, track));
        try testing.expectEqual(0, hap_mp4d_track_timescale(handle, track));
        try testing.expectEqual(0, hap_mp4d_track_constant_sample_size(handle, track));
        try testing.expectEqual(0, hap_mp4d_track_sample_size(handle, track, 0));
        try testing.expectEqual(0, hap_mp4d_track_chunk_count(handle, track));
        try testing.expectEqual(0, hap_mp4d_track_stsc_count(handle, track));
        try testing.expectEqual(0, hap_mp4d_track_timing_run_count(handle, track));
        var value: c_uint = 123;
        var offset: u64 = 456;
        try testing.expectEqual(0, hap_mp4d_track_chunk_offset(handle, track, 0, &offset));
        try testing.expectEqual(0, hap_mp4d_track_stsc_entry(handle, track, 0, &value, &value, &value));
        try testing.expectEqual(0, hap_mp4d_track_timing_run(handle, track, 0, &value, &value));
        try testing.expectEqual(123, value);
        try testing.expectEqual(456, offset);
        try testing.expectEqual(0, hap_mp4d_frame_offset(handle, track, 0, &value, null, null));
        try testing.expectEqual(0, value);
    }
    try testing.expectEqual(0, hap_mp4d_track_count(null));
    try testing.expectEqual(0, hap_mp4d_track_sample_size(ctx, 0, 1));
    try testing.expectEqual(0, hap_mp4d_track_sample_size(ctx, 0, max));
    var value: c_uint = 123;
    var offset: u64 = 456;
    try testing.expectEqual(0, hap_mp4d_track_chunk_offset(ctx, 0, 1, &offset));
    try testing.expectEqual(0, hap_mp4d_track_chunk_offset(ctx, 0, 0, null));
    try testing.expectEqual(0, hap_mp4d_track_stsc_entry(ctx, 0, 1, &value, &value, &value));
    try testing.expectEqual(0, hap_mp4d_track_stsc_entry(ctx, 0, 0, null, &value, &value));
    try testing.expectEqual(0, hap_mp4d_track_stsc_entry(ctx, 0, 0, &value, null, &value));
    try testing.expectEqual(0, hap_mp4d_track_stsc_entry(ctx, 0, 0, &value, &value, null));
    try testing.expectEqual(0, hap_mp4d_track_timing_run(ctx, 0, 1, &value, &value));
    try testing.expectEqual(0, hap_mp4d_track_timing_run(ctx, 0, 0, null, &value));
    try testing.expectEqual(0, hap_mp4d_track_timing_run(ctx, 0, 0, &value, null));
    try testing.expectEqual(123, value);
    try testing.expectEqual(456, offset);
    try expectFrame(ctx, 1, 0, 0, 0, 0);
    try testing.expectEqual(123, hap_mp4d_frame_offset(ctx, 0, 0, null, null, null));
    hap_mp4d_close(null);
    try testing.expect(hap_mp4d_open(null, 1) == null);
    try testing.expect(hap_mp4d_open(f.bytes[0..].ptr, -1) == null);
    try testing.expect(hap_mp4d_open(f.bytes[0..].ptr, 0) == null);
}

test "missing or short timing coverage returns zero without indexing beyond runs" {
    for ([_]bool{ false, true }) |has_timing| {
        var f = Fixture.init();
        f.sizes(4, 3, &.{});
        if (has_timing) f.timing(&.{.{ .samples = 1, .duration = 40 }});
        f.chunks(&.{100});
        const ctx = try f.open();
        defer hap_mp4d_close(ctx);
        try expectFrame(ctx, 2, 108, 4, 0, 0);
    }
}

test "compact stz2 tables support 4 8 and 16 bit fields including an odd nibble" {
    for ([_]u32{ 4, 8, 16 }) |bits| {
        var f = Fixture.init();
        const start = f.full("stz2");
        f.word(bits);
        f.word(3);
        if (bits == 4) {
            f.bytes[f.len] = 0x12;
            f.bytes[f.len + 1] = 0x3f;
            f.len += 2;
        } else {
            for ([_]u8{ 1, 2, 3 }) |value| {
                if (bits == 16) {
                    f.bytes[f.len] = 0;
                    f.len += 1;
                }
                f.bytes[f.len] = value;
                f.len += 1;
            }
        }
        f.end(start);
        f.chunks(&.{100});
        const ctx = try f.open();
        defer hap_mp4d_close(ctx);
        try testing.expectEqual(0, hap_mp4d_track_constant_sample_size(ctx, 0));
        try testing.expectEqual(1, hap_mp4d_track_sample_size(ctx, 0, 0));
        try testing.expectEqual(2, hap_mp4d_track_sample_size(ctx, 0, 1));
        try testing.expectEqual(3, hap_mp4d_track_sample_size(ctx, 0, 2));
        try expectFrame(ctx, 2, 103, 3, 0, 0);
    }
}

test "duplicate index tables replace counts and permit empty tables" {
    var f = Fixture.init();
    f.sizes(4, 48_000 * 3600, &.{});
    f.sizes(0, 2, &.{ 10, 20 });
    f.sizes(8, 2, &.{});
    f.timing(&.{.{ .samples = 48_000 * 3600, .duration = 1 }});
    f.timing(&.{});
    f.mapping(&.{.{ .first = 1, .samples = 2 }});
    f.mapping(&.{});
    f.chunks(&.{100});
    f.chunks(&.{});
    const ctx = try f.open();
    defer hap_mp4d_close(ctx);
    try testing.expectEqual(2, hap_mp4d_track_sample_count(ctx, 0));
    try testing.expectEqual(8, hap_mp4d_track_sample_size(ctx, 0, 1));
    try testing.expectEqual(0, hap_mp4d_track_timing_run_count(ctx, 0));
    try testing.expectEqual(0, hap_mp4d_track_stsc_count(ctx, 0));
    try testing.expectEqual(0, hap_mp4d_track_chunk_count(ctx, 0));
    try expectFrame(ctx, 0, 0, 0, 0, 0);

    var empty = Fixture.init();
    empty.sizes(0, 0, &.{});
    const empty_ctx = try empty.open();
    defer hap_mp4d_close(empty_ctx);
    try testing.expectEqual(0, hap_mp4d_track_sample_count(empty_ctx, 0));
    try testing.expectEqual(0, hap_mp4d_track_sample_size(empty_ctx, 0, 0));
}

test "truncated or oversized table counts fail before allocation" {
    const kinds = [_]*const [4]u8{ "stsz", "stts", "ctts", "stsc", "stco", "co64", "stz2" };
    for (kinds) |kind| {
        for ([_]u32{ 2, std.math.maxInt(u32) }) |count| {
            var f = Fixture.init();
            // A malformed duplicate must also clean up its prior allocation.
            f.sizes(0, 1, &.{4});
            f.timing(&.{.{ .samples = 1, .duration = 1 }});
            f.mapping(&.{.{ .first = 1, .samples = 1 }});
            f.chunks(&.{100});
            const start = f.full(kind);
            if (std.mem.eql(u8, kind, "stsz") or std.mem.eql(u8, kind, "stz2")) {
                f.word(if (std.mem.eql(u8, kind, "stz2")) 16 else 0);
            }
            f.word(count);
            f.end(start);
            const bytes = f.finish();
            try testing.expect(hap_mp4d_open(bytes.ptr, @intCast(bytes.len)) == null);
        }
    }
    var f = Fixture.init();
    f.sizes(4, 1, &.{});
    f.timing(&.{.{ .samples = 1, .duration = 1 }});
    f.chunks(&.{100});
    const bytes = f.finish();
    // Claimed payload size is sufficient but the actual buffer is short.
    try testing.expect(hap_mp4d_open(bytes.ptr, @intCast(bytes.len - 1)) == null);

    var missing_count = Fixture.init();
    const size_start = missing_count.full("stsz");
    missing_count.word(4);
    missing_count.end(size_start);
    const missing_bytes = missing_count.finish();
    try testing.expect(hap_mp4d_open(missing_bytes.ptr, @intCast(missing_bytes.len)) == null);

    // A partial ctts entry must terminate, not retain a nonzero remaining
    // payload and repeatedly attempt reads for its huge declared count.
    var partial = Fixture.init();
    const timing_start = partial.full("ctts");
    partial.word(std.math.maxInt(u32));
    partial.bytes[partial.len] = 1;
    partial.len += 1;
    partial.end(timing_start);
    const partial_bytes = partial.finish();
    try testing.expect(hap_mp4d_open(partial_bytes.ptr, @intCast(partial_bytes.len)) == null);
}

test "malformed stz2 fields timing overflow and byte offset overflow fail safely" {
    var bad_field = Fixture.init();
    const start = bad_field.full("stz2");
    bad_field.word(12);
    bad_field.word(1);
    bad_field.word(0);
    bad_field.end(start);
    const bad_bytes = bad_field.finish();
    try testing.expect(hap_mp4d_open(bad_bytes.ptr, @intCast(bad_bytes.len)) == null);

    const max = std.math.maxInt(u32);
    var overflow = Fixture.init();
    overflow.sizes(4, 1, &.{});
    overflow.timing(&.{ .{ .samples = max, .duration = max }, .{ .samples = max, .duration = max } });
    const overflow_bytes = overflow.finish();
    try testing.expect(hap_mp4d_open(overflow_bytes.ptr, @intCast(overflow_bytes.len)) == null);

    for ([_]bool{ false, true }) |constant| {
        var bad_offset = Fixture.init();
        if (constant) bad_offset.sizes(8, 2, &.{}) else bad_offset.sizes(0, 2, &.{ 8, 8 });
        bad_offset.chunks(&.{std.math.maxInt(u64) - 4});
        const ctx = try bad_offset.open();
        defer hap_mp4d_close(ctx);
        try expectFrame(ctx, 0, 0, 0, 0, 0);
        try expectFrame(ctx, 1, 0, 0, 0, 0);
    }
}

test "compact parser replays the existing demuxer fuzz regression corpus" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const paths = [_][]const u8{
        "tests/fixtures/fuzz_regressions/crash_0c3b48b5_ts_overflow.bin",
        "tests/fixtures/fuzz_regressions/crash_36735b5f.bin",
        "tests/fixtures/fuzz_regressions/crash_783ca462.bin",
        "tests/fixtures/fuzz_regressions/crash_85883b19.bin",
        "tests/fixtures/fuzz_regressions/leak_9b88d453.bin",
        "tests/fixtures/fuzz_regressions/oom_9c36f721.bin",
    };
    var replayed: usize = 0;
    for (paths) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer testing.allocator.free(bytes);
        if (hap_mp4d_open(bytes.ptr, @intCast(bytes.len))) |ctx| {
            defer hap_mp4d_close(ctx);
            for (0..hap_mp4d_track_count(ctx)) |track_index| {
                const track: c_uint = @intCast(track_index);
                const count = hap_mp4d_track_sample_count(ctx, track);
                _ = hap_mp4d_frame_offset(ctx, track, 0, null, null, null);
                if (count != 0) _ = hap_mp4d_frame_offset(ctx, track, count - 1, null, null, null);
                _ = hap_mp4d_frame_offset(ctx, track, count, null, null, null);
            }
        }
        replayed += 1;
    }
    if (replayed == 0) return error.SkipZigTest;
    try testing.expectEqual(paths.len, replayed);
}
