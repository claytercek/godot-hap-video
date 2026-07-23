//! demuxer_test.zig — dedicated test suite for Demuxer.
//!
//! Split out of demuxer.zig per the project convention for large suites
//! (see decoder.zig/decoder_test.zig and how core.zig wires the sibling
//! test files into its test block).
//!
//! Fixture paths are relative to the repo root, which is the test working
//! directory (matches mmap_reader.zig's fixture tests).

const std = @import("std");
const testing = std.testing;

const hap_frame = @import("hap_frame.zig");
const mmap_reader = @import("mmap_reader.zig");
const demuxer = @import("demuxer.zig");

const Demuxer = demuxer.Demuxer;
const MmapReader = mmap_reader.MmapReader;
const FourCC = hap_frame.FourCC;
const VideoFormat = hap_frame.VideoFormat;
const VideoTrackInfo = hap_frame.VideoTrackInfo;
const SampleEntry = hap_frame.SampleEntry;
const StsdResult = hap_frame.StsdResult;

fn buildStsdEntry(
    comptime buf_len: usize,
    fourcc: FourCC,
    width: u16,
    height: u16,
    entry_size: u32,
) [buf_len]u8 {
    var buf: [buf_len]u8 = [_]u8{0} ** buf_len;
    var pos: usize = 0;

    const putU32 = struct {
        fn f(b: []u8, p: *usize, v: u32) void {
            std.mem.writeInt(u32, b[p.*..][0..4], v, .big);
            p.* += 4;
        }
    }.f;
    const putU16 = struct {
        fn f(b: []u8, p: *usize, v: u16) void {
            std.mem.writeInt(u16, b[p.*..][0..2], v, .big);
            p.* += 2;
        }
    }.f;
    const putBytes = struct {
        fn f(b: []u8, p: *usize, bytes: []const u8) void {
            @memcpy(b[p.*..][0..bytes.len], bytes);
            p.* += bytes.len;
        }
    }.f;
    const skip = struct {
        fn f(p: *usize, n: usize) void {
            p.* += n;
        }
    }.f;

    const stsd_payload_size: u32 = 4 + 4 + entry_size;

    // Full box header: size(4) + type(4) = 8 bytes.
    putU32(&buf, &pos, 8 + stsd_payload_size);
    putBytes(&buf, &pos, "stsd");
    putU32(&buf, &pos, 0); // version=0, flags=0
    putU32(&buf, &pos, 1); // entry_count = 1

    // SampleEntry: size(4) + type(4) + reserved(6) + data_reference_index(2)
    putU32(&buf, &pos, entry_size);
    putU32(&buf, &pos, fourcc.value);
    skip(&pos, 6); // reserved (already zeroed)
    putU16(&buf, &pos, 1); // data_reference_index

    // VisualSampleEntry fields up to width/height:
    // pre_defined(2) + reserved(2) + pre_defined(12) = 16 bytes
    skip(&pos, 16);

    // Width + height at offset 32 from entry start.
    putU16(&buf, &pos, width);
    putU16(&buf, &pos, height);

    return buf;
}

test "parseStsd finds Hap1" {
    const buf = buildStsdEntry(8 + 4 + 4 + 86, hap_frame.fcc_hap1, 640, 360, 86);
    var fmt: VideoFormat = .{};
    const result = Demuxer.parseStsd(buf[8..], &fmt);
    try testing.expectEqual(StsdResult.found, result);
    try testing.expect(fmt.fourcc.eql(hap_frame.fcc_hap1));
    try testing.expectEqual(@as(u32, 640), fmt.width);
    try testing.expectEqual(@as(u32, 360), fmt.height);
}

test "parseStsd finds Hap5" {
    const buf = buildStsdEntry(8 + 4 + 4 + 86, hap_frame.fcc_hap5, 640, 360, 86);
    var fmt: VideoFormat = .{};
    const result = Demuxer.parseStsd(buf[8..], &fmt);
    try testing.expectEqual(StsdResult.found, result);
    try testing.expect(fmt.fourcc.eql(hap_frame.fcc_hap5));
    try testing.expectEqual(@as(u32, 640), fmt.width);
    try testing.expectEqual(@as(u32, 360), fmt.height);
}

test "parseStsd finds Hap7" {
    const buf = buildStsdEntry(8 + 4 + 4 + 86, hap_frame.fcc_hap7, 1920, 1080, 86);
    var fmt: VideoFormat = .{};
    const result = Demuxer.parseStsd(buf[8..], &fmt);
    try testing.expectEqual(StsdResult.found, result);
    try testing.expect(fmt.fourcc.eql(hap_frame.fcc_hap7));
    try testing.expectEqual(@as(u32, 1920), fmt.width);
    try testing.expectEqual(@as(u32, 1080), fmt.height);
}

test "parseStsd rejects a Hap entry shorter than its VisualSampleEntry fields" {
    // The surrounding payload contains the width and height, but the entry
    // itself declares only the SampleEntry header. parseStsd must not read
    // fields that lie outside the declared entry.
    var buf = buildStsdEntry(8 + 4 + 4 + 86, hap_frame.fcc_hap1, 640, 360, 86);
    std.mem.writeInt(u32, buf[16..20], 8, .big);

    var fmt: VideoFormat = .{};
    try testing.expectEqual(StsdResult.no_match, Demuxer.parseStsd(buf[8..], &fmt));
}

test "parseStsd rejects an entry whose declared extent exceeds its payload" {
    var buf = buildStsdEntry(8 + 4 + 4 + 86, hap_frame.fcc_hap1, 640, 360, 86);
    std.mem.writeInt(u32, buf[16..20], 87, .big);

    var fmt: VideoFormat = .{};
    try testing.expectEqual(StsdResult.no_match, Demuxer.parseStsd(buf[8..], &fmt));
}

test "parseStsd reports HapA as unsupported" {
    const buf = buildStsdEntry(8 + 4 + 4 + 86, hap_frame.fcc_hapa, 640, 360, 86);
    var fmt: VideoFormat = .{};
    const result = Demuxer.parseStsd(buf[8..], &fmt);
    try testing.expectEqual(StsdResult.unsupported, result);
    try testing.expect(fmt.fourcc.eql(hap_frame.fcc_hapa));
}

test "parseStsd reports Hap HDR as unsupported" {
    const buf = buildStsdEntry(8 + 4 + 4 + 86, hap_frame.fcc_haphdr, 640, 360, 86);
    var fmt: VideoFormat = .{};
    const result = Demuxer.parseStsd(buf[8..], &fmt);
    try testing.expectEqual(StsdResult.unsupported, result);
    try testing.expect(fmt.fourcc.eql(hap_frame.fcc_haphdr));
}

test "parseStsd ignores non-Hap codecs" {
    // 'raw ' is a common video format that should not be detected as Hap.
    const buf = buildStsdEntry(8 + 4 + 4 + 86, FourCC.initChars('r', 'a', 'w', ' '), 640, 360, 86);
    var fmt: VideoFormat = .{};
    const result = Demuxer.parseStsd(buf[8..], &fmt);
    try testing.expectEqual(StsdResult.no_match, result);
}

// -----------------------------------------------------------------------
// validateSamples: 64-bit offset tests (synthetic, no multi-GB fixture
// needed -- file_size is just a parameter).
// -----------------------------------------------------------------------

test "validateSamples accepts an offset beyond 4 GB" {
    // A sample living entirely past the 32-bit boundary in a >4 GB file.
    const four_gb: u64 = 1 << 32;
    const samples = [_]SampleEntry{.{ .offset = four_gb + 1024, .size = 4096 }};
    const file_size = four_gb + 1024 + 4096;

    try Demuxer.validateSamples(&samples, file_size);
}

test "validateSamples rejects an offset beyond 4 GB that is out of range" {
    // Same >4 GB offset, but the file is one byte too short to hold it --
    // must be caught by 64-bit arithmetic, not wrap/truncate to a
    // spuriously "in range" 32-bit value.
    const four_gb: u64 = 1 << 32;
    const samples = [_]SampleEntry{.{ .offset = four_gb + 1024, .size = 4096 }};
    const file_size = four_gb + 1024 + 4096 - 1; // one byte short

    try testing.expectError(error.SamplesExceedFileSize, Demuxer.validateSamples(&samples, file_size));
}

test "validateSamples handles offset and size summing past 4 GB" {
    // offset itself fits in 32 bits, but offset + size overflows a 32-bit
    // sum; must be computed in 64-bit to avoid a false negative.
    const four_gb: u64 = 1 << 32;
    const samples = [_]SampleEntry{.{ .offset = four_gb - 100, .size = 200 }}; // end = four_gb + 100

    try testing.expectError(error.SamplesExceedFileSize, Demuxer.validateSamples(&samples, four_gb));
    try Demuxer.validateSamples(&samples, four_gb + 100);
}

// -----------------------------------------------------------------------
// Demuxer tests with fixture files.
//
// Paths are relative to the repo root, which is the test working directory
// (matches mmap_reader.zig's fixture tests).
// -----------------------------------------------------------------------

fn openFixture(path: []const u8) !struct { reader: MmapReader, demuxer: Demuxer } {
    var reader = try MmapReader.init(path);
    errdefer reader.deinit();

    var dem: Demuxer = .{};
    errdefer dem.deinit(testing.allocator);
    try dem.open(testing.allocator, &reader);

    return .{ .reader = reader, .demuxer = dem };
}

/// Shared helper: open `path` via openFixture, skip on a missing fixture,
/// and assert the fourcc/width/height/frame_count fields common to all
/// four fixture-open tests below. `extra`, if non-null, runs while the
/// demuxer is still open, for assertions specific to one test (e.g.
/// frame_rate).
fn expectFixtureOpensAs(
    path: []const u8,
    expected_fourcc: FourCC,
    extra: ?*const fn (*const Demuxer) anyerror!void,
) !void {
    var f = openFixture(path) catch |err| switch (err) {
        error.OpenFailed => return error.SkipZigTest,
        else => return err,
    };
    defer f.reader.deinit();
    defer f.demuxer.deinit(testing.allocator);

    try testing.expect(f.demuxer.track.fourcc.eql(expected_fourcc));
    try testing.expect(f.demuxer.track.width > 0);
    try testing.expect(f.demuxer.track.height > 0);
    try testing.expect(f.demuxer.track.frame_count > 0);

    if (extra) |check| try check(&f.demuxer);
}

test "open parses a Hap1 fixture" {
    try expectFixtureOpensAs("tests/fixtures/hap1.mov", hap_frame.fcc_hap1, struct {
        fn check(d: *const Demuxer) !void {
            try testing.expect(d.track.frame_rate > 0.0);
        }
    }.check);
}

test "open parses a Hap5 fixture" {
    try expectFixtureOpensAs("tests/fixtures/hap5.mov", hap_frame.fcc_hap5, null);
}

test "open parses a Hap7 fixture" {
    try expectFixtureOpensAs("tests/fixtures/hap7.mov", hap_frame.fcc_hap7, null);
}

test "open skips an audio track and finds the Hap1 video track" {
    // MOV with both video and audio tracks: demuxer must find and return
    // the video track despite the audio track's presence.
    try expectFixtureOpensAs("tests/fixtures/hap1_audio.mov", hap_frame.fcc_hap1, null);
}

// -----------------------------------------------------------------------
// blockSize() regression: switch cases use fcc_*.value (well-defined).
// Verify each supported FourCC maps to its documented block size.
// -----------------------------------------------------------------------
test "VideoTrackInfo.blockSize matches each supported FourCC" {
    var info: VideoTrackInfo = .{};

    info.fourcc = hap_frame.fcc_hap1;
    try testing.expectEqual(@as(u32, 8), info.blockSize());

    info.fourcc = hap_frame.fcc_hap5;
    try testing.expectEqual(@as(u32, 16), info.blockSize());

    info.fourcc = hap_frame.fcc_hapy;
    try testing.expectEqual(@as(u32, 16), info.blockSize());

    info.fourcc = hap_frame.fcc_hapm;
    try testing.expectEqual(@as(u32, 16), info.blockSize());

    info.fourcc = hap_frame.fcc_hap7;
    try testing.expectEqual(@as(u32, 16), info.blockSize());
}
