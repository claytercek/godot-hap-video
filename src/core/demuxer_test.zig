//! demuxer_test.zig — dedicated test suite for Demuxer.
//!
//! Split out of demuxer.zig per the project convention for large suites
//! (see decoder.zig/decoder_test.zig and how core.zig wires the sibling
//! test files into its test block).
//!
//! Fixture paths are relative to the repo root, which is the test working
//! directory (matches mmap_reader.zig's fixture tests).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const hap_frame = @import("hap_frame.zig");
const demuxer = @import("demuxer.zig");
const test_support = @import("test_support.zig");

const Demuxer = demuxer.Demuxer;
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
    var buf: [buf_len]u8 = @splat(0);
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

/// Shared helper: open `path` via test_support.openFixture (which skips on a
/// missing fixture) and assert the fourcc/width/height/frame_count fields
/// common to all four fixture-open tests below. `extra`, if non-null, runs
/// while the demuxer is still open, for assertions specific to one test
/// (e.g. frame_rate).
fn expectFixtureOpensAs(
    path: []const u8,
    expected_fourcc: FourCC,
    extra: ?*const fn (*const Demuxer) anyerror!void,
) !void {
    var f = try test_support.openFixture(path);
    defer f.deinit();

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
// >4 GB file support.
//
// Regression coverage for vendored minimp4's MP4D_64BIT_SUPPORTED /
// MINIMP4_ALLOW_64BIT macro mixup (see thirdparty/README.md), which rejected
// any 64-bit box size or co64 chunk offset with a nonzero high word --
// i.e. every Hap file larger than 4 GB.
//
// No multi-gigabyte fixture is committed; the test synthesizes one from
// hap1.mov by widening its mdat into a 64-bit box padded with a 4 GiB
// leading hole and rewriting the moov's stco as co64. The file is written
// sparsely (two positional writes around the hole), so it occupies under
// a megabyte of real disk on filesystems with sparse-file support.
// -----------------------------------------------------------------------

/// A raw box located in fixture bytes: absolute offset and declared size.
/// 32-bit sizes only, which is all hap1.mov contains.
const RawBox = struct { off: usize, size: usize };

/// Find the first direct child box named `name` in `[start, end)`.
fn findRawBox(data: []const u8, start: usize, end: usize, name: *const [4]u8) ?RawBox {
    var pos = start;
    while (pos + 8 <= end) {
        const size = std.mem.readInt(u32, data[pos..][0..4], .big);
        if (size < 8 or pos + size > end) return null;
        if (std.mem.eql(u8, data[pos + 4 ..][0..4], name)) return .{ .off = pos, .size = size };
        pos += size;
    }
    return null;
}

test "open parses a synthesized >4 GB file with a 64-bit mdat and co64 offsets" {
    // Sparse-file writing below goes through positional writes; Windows
    // needs explicit FSCTL_SET_SPARSE for holes to stay sparse, so skip
    // there rather than risk materializing 4 GiB on disk.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = test_support.io();
    const allocator = testing.allocator;

    var orig = try test_support.openFixture("tests/fixtures/hap1.mov");
    defer orig.deinit();
    const data = orig.reader.data;

    // Locate the pieces the surgery moves: the top-level mdat and moov, the
    // stco inside the moov, and every ancestor box whose size must grow
    // when stco (20 bytes, one 32-bit entry) becomes co64 (24 bytes).
    const mdat = findRawBox(data, 0, data.len, "mdat") orelse return error.TestUnexpectedResult;
    const moov = findRawBox(data, 0, data.len, "moov") orelse return error.TestUnexpectedResult;

    // The rebuild below only handles hap1.mov's known shape: mdat before a
    // trailing moov, one chunk offset.
    try testing.expect(mdat.off < moov.off);
    try testing.expectEqual(data.len, moov.off + moov.size);

    var ancestors: [5]RawBox = undefined; // moov, trak, mdia, minf, stbl
    ancestors[0] = moov;
    for ([_]*const [4]u8{ "trak", "mdia", "minf", "stbl" }, 1..) |name, i| {
        const parent = ancestors[i - 1];
        ancestors[i] = findRawBox(data, parent.off + 8, parent.off + parent.size, name) orelse
            return error.TestUnexpectedResult;
    }
    const stbl = ancestors[4];
    const stco = findRawBox(data, stbl.off + 8, stbl.off + stbl.size, "stco") orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, data[stco.off + 12 ..][0..4], .big));
    const old_chunk_offset = std.mem.readInt(u32, data[stco.off + 16 ..][0..4], .big);

    // Every byte of the original mdat payload moves forward by `shift`: 8
    // bytes of extra (64-bit) mdat header plus the 4 GiB hole.
    const hole: u64 = 1 << 32;
    const shift: u64 = 8 + hole;
    const payload = data[mdat.off + 8 .. mdat.off + mdat.size];

    // Rebuild the moov with stco replaced by co64 (4 bytes larger) and the
    // five ancestor sizes bumped to match.
    const new_moov = try allocator.alloc(u8, moov.size + 4);
    defer allocator.free(new_moov);
    const stco_rel = stco.off - moov.off;
    @memcpy(new_moov[0..stco_rel], data[moov.off..stco.off]);
    std.mem.writeInt(u32, new_moov[stco_rel..][0..4], 24, .big); // box size
    @memcpy(new_moov[stco_rel + 4 ..][0..4], "co64");
    std.mem.writeInt(u32, new_moov[stco_rel + 8 ..][0..4], 0, .big); // version+flags
    std.mem.writeInt(u32, new_moov[stco_rel + 12 ..][0..4], 1, .big); // entry_count
    std.mem.writeInt(u64, new_moov[stco_rel + 16 ..][0..8], old_chunk_offset + shift, .big);
    @memcpy(new_moov[stco_rel + 24 ..], data[stco.off + stco.size .. moov.off + moov.size]);
    for (ancestors) |box| {
        const rel = box.off - moov.off;
        std.mem.writeInt(u32, new_moov[rel..][0..4], @intCast(box.size + 4), .big);
    }

    // Write the synthesized file: prefix verbatim, 64-bit mdat header, hole
    // (left sparse by writing nothing), relocated payload, patched moov.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var mdat_header: [16]u8 = undefined;
    std.mem.writeInt(u32, mdat_header[0..4], 1, .big); // "size follows as u64"
    @memcpy(mdat_header[4..8], "mdat");
    std.mem.writeInt(u64, mdat_header[8..16], 16 + hole + payload.len, .big);

    const file = try tmp.dir.createFile(io, "hap1_4gb.mov", .{});
    try file.writePositionalAll(io, data[0..mdat.off], 0);
    try file.writePositionalAll(io, &mdat_header, mdat.off);
    try file.writePositionalAll(io, payload, mdat.off + 16 + hole);
    try file.writePositionalAll(io, new_moov, mdat.off + 16 + hole + payload.len);
    file.close(io);

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/hap1_4gb.mov", .{&tmp.sub_path});

    // The synthesized file must parse to the same track as the original,
    // with its samples now living past the 32-bit offset boundary.
    var big = try test_support.openFixture(path);
    defer big.deinit();

    try testing.expect(big.demuxer.track.fourcc.eql(orig.demuxer.track.fourcc));
    try testing.expectEqual(orig.demuxer.track.width, big.demuxer.track.width);
    try testing.expectEqual(orig.demuxer.track.height, big.demuxer.track.height);
    try testing.expectEqual(orig.demuxer.track.frame_count, big.demuxer.track.frame_count);
    try testing.expect(big.demuxer.samples.items[0].offset > hole);
    try testing.expectEqualSlices(u8, try orig.sample(0), try big.sample(0));
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
