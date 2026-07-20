//! decoder_test.zig — dedicated test suite for Decoder.
//!
//! Dedicated test file for Decoder (see decoder.zig doc comment for how it
//! is wired into core.zig's test block -- this follows the project
//! convention for large suites).
//!
//! Fixture paths are relative to the repo root, which is the test working
//! directory (matches demuxer.zig/mmap_reader.zig's fixture tests).

const std = @import("std");
const testing = std.testing;

const hap_frame = @import("hap_frame.zig");
const mmap_reader = @import("mmap_reader.zig");
const demuxer = @import("demuxer.zig");
const decoder = @import("decoder.zig");
const test_support = @import("test_support.zig");

const Decoder = decoder.Decoder;
const DecodedFrame = hap_frame.DecodedFrame;
const HapTextureFormat = hap_frame.HapTextureFormat;

const fixture_hap1 = "tests/fixtures/hap1.mov";
const fixture_hap5 = "tests/fixtures/hap5.mov";
const fixture_hapy = "tests/fixtures/hapy.mov";

// -----------------------------------------------------------------------
// hap.c externs needed only by this test file (HapDecode/
// HapGetFrameTextureCount live in decoder.zig; HapGetFrameTextureCount is
// re-exported from there rather than redeclared here). buildRawFrame/
// createChunkedFrame (and the HapMaxEncodedLength/HapEncode externs they
// need) live in test_support.zig, shared with concurrency_test.zig.
// -----------------------------------------------------------------------

const HapTextureFormat_RGB_DXT1: c_uint = 0x83F0;
const HapTextureFormat_YCoCg_DXT5: c_uint = 0x01;
const HapCompressorSnappy: c_uint = 1;

extern fn HapGetFrameTextureChunkCount(
    input_buffer: ?*const anyopaque,
    input_buffer_bytes: c_ulong,
    index: c_uint,
    chunk_count: *c_int,
) c_uint;

/// Decode frame 0 of a fixture .mov file. Propagates
/// MmapReader.InitError.OpenFailed so callers can treat a missing fixture
/// as a skip.
fn decodeFixtureFrame0(allocator: std.mem.Allocator, path: []const u8, out: *DecodedFrame) !void {
    var reader = try mmap_reader.MmapReader.init(path);
    defer reader.deinit();

    var dem: demuxer.Demuxer = .{};
    defer dem.deinit(allocator);
    try dem.open(allocator, &reader);

    const sample = dem.sampleData(&reader, 0) orelse return error.TestUnexpectedResult;

    var dec: Decoder = .{};
    defer dec.deinit(allocator);
    try dec.decode(allocator, sample, out);
}

// -----------------------------------------------------------------------
// Shared helper: build a synthetic frame with the given type byte, decode
// it, and assert the output is a single texture of the expected format
// whose bytes are identical to the input BC data. Covers the
// byte-identical and golden-frame cases below, which all follow this same
// decode -> assert format -> assert byte-identical shape.
// -----------------------------------------------------------------------
fn expectDecodesTo(type_byte: u8, bc_data: []const u8, expected_format: HapTextureFormat) !void {
    const frame = try test_support.buildRawFrame(testing.allocator, bc_data, type_byte);
    defer testing.allocator.free(frame);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try dec.decode(testing.allocator, frame, &output);
    try testing.expectEqual(@as(usize, 1), output.textures.items.len);

    const tex = output.textures.items[0];
    try testing.expectEqual(expected_format, tex.format);
    try testing.expectEqual(bc_data.len, tex.data.items.len);
    try testing.expectEqualSlices(u8, bc_data, tex.data.items);
}

// -----------------------------------------------------------------------
// Hap1 (BC1/DXT1) tests
// -----------------------------------------------------------------------

test "decoder decodes a single Hap1 BC1 block byte-identical to input" {
    const bc1_block = [8]u8{
        0x00, 0x00, // color0: RGB565 = 0 (black)
        0xFF, 0xFF, // color1: RGB565 = 0xFFFF (white)
        0x00, 0x00, 0x00, 0x00, // all indices = 0 (black)
    };
    try expectDecodesTo(0xAB, &bc1_block, .rgb_dxt1);
}

test "decoder decodes multiple Hap1 BC1 blocks (2x2 grid)" {
    // 8x8 pixels = 4 BC1 blocks (2x2 grid)
    var bc1_blocks = [_]u8{0} ** 32;
    bc1_blocks[0] = 0x00;
    bc1_blocks[1] = 0x00; // Block 0: black
    bc1_blocks[8] = 0xFF;
    bc1_blocks[9] = 0xFF; // Block 1: white
    bc1_blocks[16] = 0x00;
    bc1_blocks[17] = 0xF8; // Block 2: red
    bc1_blocks[24] = 0x1F;
    bc1_blocks[25] = 0x00; // Block 3: blue

    const frame = try test_support.buildRawFrame(testing.allocator, &bc1_blocks, 0xAB);
    defer testing.allocator.free(frame);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try dec.decode(testing.allocator, frame, &output);
    try testing.expectEqual(@as(usize, 1), output.textures.items.len);
    try testing.expectEqual(@as(usize, 32), output.textures.items[0].data.items.len); // 4 blocks x 8 bytes
}

test "decoder Hap1 frame reports a single texture via HapGetFrameTextureCount" {
    const bc1_block = [_]u8{0} ** 8;
    const frame = try test_support.buildRawFrame(testing.allocator, &bc1_block, 0xAB);
    defer testing.allocator.free(frame);

    var tex_count: c_uint = 0;
    const result = decoder.HapGetFrameTextureCount(frame.ptr, @intCast(frame.len), &tex_count);
    try testing.expectEqual(decoder.HapResult_No_Error, result);
    try testing.expectEqual(@as(c_uint, 1), tex_count);
}

// -----------------------------------------------------------------------
// Hap5 (BC3/DXT5) tests
// -----------------------------------------------------------------------

test "decoder decodes a single Hap5 BC3 block byte-identical to input" {
    // A single 4x4 BC3 block (16 bytes): 8 bytes alpha + 8 bytes color.
    const bc3_block = [16]u8{
        0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // alpha: opaque, all indices 0
        0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, // color: black -> white, indices 0
    };
    try expectDecodesTo(0xAE, &bc3_block, .rgba_dxt5);
}

test "decoder Hap5 frame reports a single texture via HapGetFrameTextureCount" {
    const bc3_block = [_]u8{0} ** 16;
    const frame = try test_support.buildRawFrame(testing.allocator, &bc3_block, 0xAE);
    defer testing.allocator.free(frame);

    var tex_count: c_uint = 0;
    const result = decoder.HapGetFrameTextureCount(frame.ptr, @intCast(frame.len), &tex_count);
    try testing.expectEqual(decoder.HapResult_No_Error, result);
    try testing.expectEqual(@as(c_uint, 1), tex_count);
}

// -----------------------------------------------------------------------
// Hap7 (BC7/BPTC) tests
// -----------------------------------------------------------------------

test "decoder decodes a single Hap7 BC7 block byte-identical to input" {
    const bc7_block = [16]u8{
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    try expectDecodesTo(0xAC, &bc7_block, .rgba_bptc_unorm);
}

test "decoder Hap7 frame reports a single texture via HapGetFrameTextureCount" {
    const bc7_block = [_]u8{0} ** 16;
    const frame = try test_support.buildRawFrame(testing.allocator, &bc7_block, 0xAC);
    defer testing.allocator.free(frame);

    var tex_count: c_uint = 0;
    const result = decoder.HapGetFrameTextureCount(frame.ptr, @intCast(frame.len), &tex_count);
    try testing.expectEqual(decoder.HapResult_No_Error, result);
    try testing.expectEqual(@as(c_uint, 1), tex_count);
}

// -----------------------------------------------------------------------
// Golden-frame tests: byte-exact BC block comparison (16x8 px = 2x2 blocks)
// -----------------------------------------------------------------------

test "decoder golden Hap1 frame: 4 BC1 blocks decode byte-identical" {
    var bc1_blocks: [32]u8 = undefined;
    // Block 0 (top-left): white
    bc1_blocks[0] = 0xFF;
    bc1_blocks[1] = 0xFF;
    bc1_blocks[2] = 0x00;
    bc1_blocks[3] = 0x00;
    bc1_blocks[4] = 0x00;
    bc1_blocks[5] = 0x00;
    bc1_blocks[6] = 0x00;
    bc1_blocks[7] = 0x00;
    // Block 1 (top-right): black
    bc1_blocks[8] = 0x00;
    bc1_blocks[9] = 0x00;
    bc1_blocks[10] = 0xFF;
    bc1_blocks[11] = 0xFF;
    bc1_blocks[12] = 0x00;
    bc1_blocks[13] = 0x00;
    bc1_blocks[14] = 0x00;
    bc1_blocks[15] = 0x00;
    // Block 2 (bottom-left): red
    bc1_blocks[16] = 0x00;
    bc1_blocks[17] = 0xF8;
    bc1_blocks[18] = 0x00;
    bc1_blocks[19] = 0x00;
    bc1_blocks[20] = 0x00;
    bc1_blocks[21] = 0x00;
    bc1_blocks[22] = 0x00;
    bc1_blocks[23] = 0x00;
    // Block 3 (bottom-right): blue
    bc1_blocks[24] = 0x1F;
    bc1_blocks[25] = 0x00;
    bc1_blocks[26] = 0x00;
    bc1_blocks[27] = 0x00;
    bc1_blocks[28] = 0x00;
    bc1_blocks[29] = 0x00;
    bc1_blocks[30] = 0x00;
    bc1_blocks[31] = 0x00;

    try expectDecodesTo(0xAB, &bc1_blocks, .rgb_dxt1);
}

test "decoder golden Hap5 frame: 4 BC3 blocks decode byte-identical" {
    var bc3_blocks: [64]u8 = [_]u8{0} ** 64;
    // Block 0 (top-left): alpha opaque, white
    bc3_blocks[0] = 0xFF;
    bc3_blocks[1] = 0x00;
    bc3_blocks[8] = 0xFF;
    bc3_blocks[9] = 0xFF;
    bc3_blocks[10] = 0x00;
    bc3_blocks[11] = 0x00;
    // Block 1 (top-right): alpha transparent, black
    bc3_blocks[16] = 0x00;
    bc3_blocks[17] = 0xFF;
    bc3_blocks[24] = 0x00;
    bc3_blocks[25] = 0x00;
    bc3_blocks[26] = 0xFF;
    bc3_blocks[27] = 0xFF;
    // Block 2 (bottom-left): alpha opaque, red
    bc3_blocks[32] = 0xFF;
    bc3_blocks[33] = 0x00;
    bc3_blocks[40] = 0x00;
    bc3_blocks[41] = 0xF8;
    // Block 3 (bottom-right): alpha opaque, blue
    bc3_blocks[48] = 0xFF;
    bc3_blocks[49] = 0x00;
    bc3_blocks[56] = 0x1F;
    bc3_blocks[57] = 0x00;

    try expectDecodesTo(0xAE, &bc3_blocks, .rgba_dxt5);
}

test "decoder golden Hap7 frame: 4 BC7 blocks decode byte-identical" {
    var bc7_blocks: [64]u8 = [_]u8{0} ** 64;
    bc7_blocks[0] = 0x01;
    bc7_blocks[16] = 0x01;
    bc7_blocks[32] = 0x01;
    bc7_blocks[48] = 0x01;

    try expectDecodesTo(0xAC, &bc7_blocks, .rgba_bptc_unorm);
}

// -----------------------------------------------------------------------
// Unsupported format tests
// -----------------------------------------------------------------------

test "decoder rejects a frame with an invalid type byte" {
    // Type byte 0x00: compressor = 0x0 (invalid), format = 0x0 (invalid).
    const dummy = [_]u8{0} ** 16;
    const frame = try test_support.buildRawFrame(testing.allocator, &dummy, 0x00);
    defer testing.allocator.free(frame);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try testing.expectError(error.InvalidFrame, dec.decode(testing.allocator, frame, &output));
    try testing.expectEqual(@as(usize, 0), output.textures.items.len);
}

test "decoder rejects a frame with an unsupported compressor nibble" {
    // Type byte 0xD0: compressor = 0xD (invalid), format = 0x0 (invalid).
    const dummy = [_]u8{0} ** 16;
    const frame = try test_support.buildRawFrame(testing.allocator, &dummy, 0xD0);
    defer testing.allocator.free(frame);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try testing.expectError(error.InvalidFrame, dec.decode(testing.allocator, frame, &output));
    try testing.expectEqual(@as(usize, 0), output.textures.items.len);
}

// -----------------------------------------------------------------------
// Multi-image top-level section builder (kHapSectionMultipleImages = 0x0D):
// wraps N sub-sections (each already in buildRawFrame's [len][type][data]
// shape) in a top-level header, matching the on-disk layout hap.c's
// hap_get_section_at_index walks for HapM-style dual-texture frames. Local
// to this test file -- decoder.zig never needs to construct one itself.
// -----------------------------------------------------------------------
fn buildMultiImageFrame(allocator: std.mem.Allocator, sections: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (sections) |s| total += s.len;

    const frame = try allocator.alloc(u8, 4 + total);
    const length: u32 = @intCast(total);
    frame[0] = @truncate(length);
    frame[1] = @truncate(length >> 8);
    frame[2] = @truncate(length >> 16);
    frame[3] = 0x0D; // kHapSectionMultipleImages

    var offset: usize = 4;
    for (sections) |s| {
        @memcpy(frame[offset..][0..s.len], s);
        offset += s.len;
    }
    return frame;
}

test "decoder leaves output empty when a later texture in a multi-image frame is invalid" {
    // Texture 0: valid Hap1 (0xAB) -- decodes successfully.
    const bc1_block = [8]u8{
        0x00, 0x00, // color0: RGB565 = 0 (black)
        0xFF, 0xFF, // color1: RGB565 = 0xFFFF (white)
        0x00, 0x00, 0x00, 0x00, // all indices = 0 (black)
    };
    const sub0 = try test_support.buildRawFrame(testing.allocator, &bc1_block, 0xAB);
    defer testing.allocator.free(sub0);

    // Texture 1: type byte 0x00 -- invalid format nibble, fails
    // HapGetFrameTextureFormat after texture 0 has already been decoded
    // into output. This is the mid-loop failure the "output left empty on
    // failure" contract exists for.
    const dummy = [_]u8{0} ** 16;
    const sub1 = try test_support.buildRawFrame(testing.allocator, &dummy, 0x00);
    defer testing.allocator.free(sub1);

    const frame = try buildMultiImageFrame(testing.allocator, &.{ sub0, sub1 });
    defer testing.allocator.free(frame);

    var tex_count: c_uint = 0;
    const cc_result = decoder.HapGetFrameTextureCount(frame.ptr, @intCast(frame.len), &tex_count);
    try testing.expectEqual(decoder.HapResult_No_Error, cc_result);
    try testing.expectEqual(@as(c_uint, 2), tex_count);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try testing.expectError(error.InvalidFrame, dec.decode(testing.allocator, frame, &output));
    try testing.expectEqual(@as(usize, 0), output.textures.items.len);
}

test "decoder leaves output empty on failure even when it held a prior successful decode" {
    const bc1_block = [8]u8{
        0x00, 0x00,
        0xFF, 0xFF,
        0x00, 0x00,
        0x00, 0x00,
    };
    const good_frame = try test_support.buildRawFrame(testing.allocator, &bc1_block, 0xAB);
    defer testing.allocator.free(good_frame);

    const dummy = [_]u8{0} ** 16;
    const bad_frame = try test_support.buildRawFrame(testing.allocator, &dummy, 0x00);
    defer testing.allocator.free(bad_frame);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try dec.decode(testing.allocator, good_frame, &output);
    try testing.expectEqual(@as(usize, 1), output.textures.items.len);

    try testing.expectError(error.InvalidFrame, dec.decode(testing.allocator, bad_frame, &output));
    try testing.expectEqual(@as(usize, 0), output.textures.items.len);
}

// -----------------------------------------------------------------------
// Fixture-based decode tests: demux + decode frame 0 from real .mov files.
// These exercise the Snappy decompress path (the synthetic tests above use
// the None compressor).
// -----------------------------------------------------------------------

/// Shared helper: demux + decode frame 0 of `path`, and assert it produced
/// a single texture of `expected_format` sized to the track's frame byte
/// count. Covers the two per-codec fixture tests below, which otherwise
/// differ only in path/fourcc/format.
fn expectFixtureDecodesToFormat(path: []const u8, expected_fourcc: hap_frame.FourCC, expected_format: HapTextureFormat) !void {
    var reader = mmap_reader.MmapReader.init(path) catch |err| switch (err) {
        error.OpenFailed => return error.SkipZigTest,
        else => return err,
    };
    defer reader.deinit();

    var dem: demuxer.Demuxer = .{};
    defer dem.deinit(testing.allocator);
    try dem.open(testing.allocator, &reader);
    try testing.expect(dem.track.fourcc.eql(expected_fourcc));
    try testing.expect(dem.track.frame_count > 0);

    const sample = dem.sampleData(&reader, 0) orelse return error.TestUnexpectedResult;

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try dec.decode(testing.allocator, sample, &output);
    try testing.expectEqual(@as(usize, 1), output.textures.items.len);

    const tex = output.textures.items[0];
    try testing.expectEqual(expected_format, tex.format);
    try testing.expectEqual(@as(usize, dem.track.frameBytes()), tex.data.items.len);
}

test "decoder Hap5 fixture frame0 decodes to track-sized RGBA_DXT5" {
    try expectFixtureDecodesToFormat(fixture_hap5, hap_frame.fcc_hap5, .rgba_dxt5);
}

test "decoder Hap7 fixture frame0 decodes to track-sized RGBA_BPTC_UNORM" {
    try expectFixtureDecodesToFormat("tests/fixtures/hap7.mov", hap_frame.fcc_hap7, .rgba_bptc_unorm);
}

// -----------------------------------------------------------------------
// Chunked decode tests
//
// Core assertion: chunking is transport -- the decoded output of a chunked
// frame must be byte-for-byte identical to the output of an unchunked frame
// when both encode the same raw texture data.
// -----------------------------------------------------------------------

test "decoder chunked BC1 (Hap1) decode is byte-identical to unchunked" {
    // 64x32 pixels = 128 BC1 blocks (1024 bytes); large enough for HapEncode
    // to produce a Complex frame.
    var bc1_blocks: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < bc1_blocks.len) : (i += 8) {
        bc1_blocks[i + 0] = 0xFF;
        bc1_blocks[i + 1] = 0xFF; // color0: white
        bc1_blocks[i + 2] = 0x00;
        bc1_blocks[i + 3] = 0x00; // color1: black
        bc1_blocks[i + 4] = 0x00;
        bc1_blocks[i + 5] = 0x00; // indices: all 0
        bc1_blocks[i + 6] = 0x00;
        bc1_blocks[i + 7] = 0x00;
    }

    const unchunked = try test_support.buildRawFrame(testing.allocator, &bc1_blocks, 0xAB);
    defer testing.allocator.free(unchunked);
    try testing.expect(unchunked.len > 0);

    const chunked = try test_support.createChunkedFrame(testing.allocator, &bc1_blocks, 4, HapTextureFormat_RGB_DXT1, HapCompressorSnappy);
    defer testing.allocator.free(chunked);
    try testing.expect(chunked.len > 0);

    // Verify the chunked frame is actually Complex (0xCB header type: Complex|DXT1).
    try testing.expect(chunked.len >= 4);
    try testing.expectEqual(@as(u8, 0xCB), chunked[3]);

    var chunk_count: c_int = 0;
    const cc_result = HapGetFrameTextureChunkCount(chunked.ptr, @intCast(chunked.len), 0, &chunk_count);
    try testing.expectEqual(decoder.HapResult_No_Error, cc_result);
    try testing.expectEqual(@as(c_int, 4), chunk_count);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var out_unchunked: DecodedFrame = .{};
    defer out_unchunked.deinit(testing.allocator);
    var out_chunked: DecodedFrame = .{};
    defer out_chunked.deinit(testing.allocator);

    try dec.decode(testing.allocator, unchunked, &out_unchunked);
    try dec.decode(testing.allocator, chunked, &out_chunked);

    try testing.expectEqual(@as(usize, 1), out_unchunked.textures.items.len);
    try testing.expectEqual(@as(usize, 1), out_chunked.textures.items.len);
    try testing.expectEqual(HapTextureFormat.rgb_dxt1, out_unchunked.textures.items[0].format);
    try testing.expectEqual(HapTextureFormat.rgb_dxt1, out_chunked.textures.items[0].format);

    // Byte-level identity: chunking is transport.
    try testing.expectEqualSlices(u8, out_unchunked.textures.items[0].data.items, out_chunked.textures.items[0].data.items);
}

test "decoder chunked HapY (YCoCg-DXT5) decode is byte-identical to unchunked" {
    // 64x32 pixels = 128 BC3 blocks (2048 bytes); large enough for Complex compression.
    var bc3_blocks: [2048]u8 = [_]u8{0} ** 2048;
    var i: usize = 0;
    while (i < bc3_blocks.len) : (i += 16) {
        bc3_blocks[i + 0] = 0xFF;
        bc3_blocks[i + 1] = 0xFF; // alpha endpoints: opaque
        bc3_blocks[i + 8] = 0xFF;
        bc3_blocks[i + 9] = 0xFF; // color endpoints: white
    }

    // Encode unchunked via HapEncode (1 chunk, Snappy).
    const unchunked = try test_support.createChunkedFrame(testing.allocator, &bc3_blocks, 1, HapTextureFormat_YCoCg_DXT5, HapCompressorSnappy);
    defer testing.allocator.free(unchunked);
    try testing.expect(unchunked.len > 0);

    // Encode chunked via HapEncode (4 chunks, Snappy).
    const chunked = try test_support.createChunkedFrame(testing.allocator, &bc3_blocks, 4, HapTextureFormat_YCoCg_DXT5, HapCompressorSnappy);
    defer testing.allocator.free(chunked);
    try testing.expect(chunked.len > 0);

    // Verify it's Complex (0xCF = Complex|YCoCg-DXT5).
    try testing.expect(chunked.len >= 4);
    try testing.expectEqual(@as(u8, 0xCF), chunked[3]);

    var chunk_count: c_int = 0;
    const cc_result = HapGetFrameTextureChunkCount(chunked.ptr, @intCast(chunked.len), 0, &chunk_count);
    try testing.expectEqual(decoder.HapResult_No_Error, cc_result);
    try testing.expect(chunk_count >= 2);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var out_unchunked: DecodedFrame = .{};
    defer out_unchunked.deinit(testing.allocator);
    var out_chunked: DecodedFrame = .{};
    defer out_chunked.deinit(testing.allocator);

    try dec.decode(testing.allocator, unchunked, &out_unchunked);
    try dec.decode(testing.allocator, chunked, &out_chunked);

    try testing.expectEqual(@as(usize, 1), out_unchunked.textures.items.len);
    try testing.expectEqual(@as(usize, 1), out_chunked.textures.items.len);

    try testing.expectEqualSlices(u8, out_unchunked.textures.items[0].data.items, out_chunked.textures.items[0].data.items);
}

// -----------------------------------------------------------------------
// Fixture-based tests using real (ffmpeg-generated) MOV files.
// -----------------------------------------------------------------------

test "decoder per-codec fixtures decode to the expected format and byte count" {
    const Case = struct {
        filename: []const u8,
        format: HapTextureFormat,
        expected_bytes: usize, // 640x360 at the format's BC block size
    };
    const cases = [_]Case{
        .{ .filename = fixture_hap1, .format = .rgb_dxt1, .expected_bytes = 115200 },
        .{ .filename = fixture_hapy, .format = .ycocg_dxt5, .expected_bytes = 230400 },
        .{ .filename = fixture_hap5, .format = .rgba_dxt5, .expected_bytes = 230400 },
    };

    for (cases) |c| {
        var frame: DecodedFrame = .{};
        defer frame.deinit(testing.allocator);

        decodeFixtureFrame0(testing.allocator, c.filename, &frame) catch |err| switch (err) {
            error.OpenFailed => continue, // fixture missing: skip this case
            else => return err,
        };

        try testing.expectEqual(@as(usize, 1), frame.textures.items.len);
        try testing.expectEqual(c.format, frame.textures.items[0].format);
        try testing.expectEqual(c.expected_bytes, frame.textures.items[0].data.items.len);
    }
}

test "decoder chunked fixture decode is byte-identical to its unchunked counterpart" {
    const Case = struct {
        unchunked: []const u8,
        chunked: []const u8,
    };
    const cases = [_]Case{
        .{ .unchunked = fixture_hap1, .chunked = "tests/fixtures/hap1_chunked.mov" },
        .{ .unchunked = fixture_hapy, .chunked = "tests/fixtures/hapy_chunked.mov" },
        .{ .unchunked = fixture_hap5, .chunked = "tests/fixtures/hap5_chunked.mov" },
    };

    for (cases) |c| {
        var unc: DecodedFrame = .{};
        defer unc.deinit(testing.allocator);
        var chk: DecodedFrame = .{};
        defer chk.deinit(testing.allocator);

        decodeFixtureFrame0(testing.allocator, c.unchunked, &unc) catch |err| switch (err) {
            error.OpenFailed => continue, // fixture pair missing: skip this case
            else => return err,
        };
        try decodeFixtureFrame0(testing.allocator, c.chunked, &chk);

        try testing.expectEqual(unc.textures.items.len, chk.textures.items.len);
        for (unc.textures.items, chk.textures.items) |ut, ct| {
            try testing.expectEqualSlices(u8, ut.data.items, ct.data.items);
        }
    }
}

test "decoder Hap1 fixture frame0 matches the committed golden reference" {
    var frame: DecodedFrame = .{};
    defer frame.deinit(testing.allocator);

    decodeFixtureFrame0(testing.allocator, fixture_hap1, &frame) catch |err| switch (err) {
        error.OpenFailed => return error.SkipZigTest,
        else => return err,
    };
    try testing.expect(frame.textures.items.len > 0);

    var golden = mmap_reader.MmapReader.init("tests/fixtures/hap1_golden.bin") catch |err| switch (err) {
        error.OpenFailed => return error.SkipZigTest,
        else => return err,
    };
    defer golden.deinit();

    const tex = frame.textures.items[0];
    try testing.expectEqual(golden.data.len, tex.data.items.len);
    try testing.expectEqualSlices(u8, golden.data, tex.data.items);
}

// -----------------------------------------------------------------------
// Known limitation: no dedicated real-file test for HapM (dual-texture)
// decoding. There is no committed hapm.mov fixture (tests/fixtures/
// README.md documents it as conditional/optional), so the multi-texture
// cases above only assert HapGetFrameTextureCount == 1 for Hap1/5/7,
// never exercising the count == 2 path. The multi-texture index fix
// itself is preserved in decoder.zig's loop (see its doc comment); a
// synthetic HapM round-trip test would need HapEncode's two-texture
// (YCoCg_DXT5 + A_RGTC1) combination.
// -----------------------------------------------------------------------
