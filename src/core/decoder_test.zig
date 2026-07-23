//! decoder_test.zig — port of tests/core/test_decoder.cpp.
//!
//! Dedicated test file for Decoder (see decoder.zig doc comment for how it
//! is wired into core.zig's test block -- this mirrors the project
//! convention for large suites).
//!
//! Every test case from test_decoder.cpp that doesn't depend on C++-only
//! test-harness machinery is ported here. See the bottom of this file for
//! a summary of what was intentionally not ported and why.
//!
//! Fixture paths are relative to the repo root, which is the test working
//! directory (matches demuxer.zig/mmap_reader.zig's fixture tests).

const std = @import("std");
const testing = std.testing;

const hap_frame = @import("hap_frame.zig");
const mmap_reader = @import("mmap_reader.zig");
const demuxer = @import("demuxer.zig");
const decoder = @import("decoder.zig");

const Decoder = decoder.Decoder;
const DecodedFrame = hap_frame.DecodedFrame;
const HapTextureFormat = hap_frame.HapTextureFormat;

// -----------------------------------------------------------------------
// hap.c externs needed only by this test file (HapDecode/
// HapGetFrameTextureCount live in decoder.zig; HapGetFrameTextureCount is
// re-exported from there rather than redeclared here).
// -----------------------------------------------------------------------

const HapTextureFormat_RGB_DXT1: c_uint = 0x83F0;
const HapTextureFormat_YCoCg_DXT5: c_uint = 0x01;
const HapCompressorSnappy: c_uint = 1;

extern fn HapMaxEncodedLength(
    count: c_uint,
    lengths: [*]c_ulong,
    texture_formats: [*]c_uint,
    chunk_counts: [*]c_uint,
) c_ulong;

extern fn HapEncode(
    count: c_uint,
    input_buffers: [*]const ?*const anyopaque,
    input_buffers_bytes: [*]c_ulong,
    texture_formats: [*]c_uint,
    compressors: [*]c_uint,
    chunk_counts: [*]c_uint,
    output_buffer: ?*anyopaque,
    output_buffer_bytes: c_ulong,
    output_buffer_bytes_used: *c_ulong,
) c_uint;

extern fn HapGetFrameTextureChunkCount(
    input_buffer: ?*const anyopaque,
    input_buffer_bytes: c_ulong,
    index: c_uint,
    chunk_count: *c_int,
) c_uint;

// -----------------------------------------------------------------------
// Helper: build a synthetic Hap frame with a given type byte.
//
// A Hap frame structure:
//   4-byte header: length(3 bytes LE) + type(1 byte)
//   For single-chunk None compressor:
//     type byte = 0xAB (Hap1), 0xAE (Hap5), 0xAC (Hap7)
//   Frame data = raw BC block bytes (pass-through for None compressor)
// -----------------------------------------------------------------------
fn buildRawFrame(allocator: std.mem.Allocator, bc_data: []const u8, type_byte: u8) ![]u8 {
    const frame = try allocator.alloc(u8, 4 + bc_data.len);
    const length: u32 = @intCast(bc_data.len);
    frame[0] = @truncate(length);
    frame[1] = @truncate(length >> 8);
    frame[2] = @truncate(length >> 16);
    frame[3] = type_byte;
    @memcpy(frame[4..], bc_data);
    return frame;
}

/// Encode `tex_data` into a real (HapEncode-produced) Hap frame with the
/// given chunk count / texture format / compressor. Mirrors
/// tests/core/test_hap_frames.h's create_chunked_frame -- exercises the
/// real encode path so decode tests see authentic chunk layouts.
fn createChunkedFrame(
    allocator: std.mem.Allocator,
    tex_data: []const u8,
    chunk_count: u32,
    texture_format: c_uint,
    compressor: c_uint,
) ![]u8 {
    var lengths = [_]c_ulong{@intCast(tex_data.len)};
    var tex_fmts = [_]c_uint{texture_format};
    var chunk_counts = [_]c_uint{chunk_count};

    const max_size = HapMaxEncodedLength(1, &lengths, &tex_fmts, &chunk_counts);
    if (max_size == 0) return error.EncodeFailed;

    const scratch = try allocator.alloc(u8, max_size);
    defer allocator.free(scratch);

    var bytes_used: c_ulong = 0;
    const input_bufs = [_]?*const anyopaque{tex_data.ptr};
    var input_sizes = [_]c_ulong{@intCast(tex_data.len)};
    var compressors = [_]c_uint{compressor};

    const result = HapEncode(
        1,
        &input_bufs,
        &input_sizes,
        &tex_fmts,
        &compressors,
        &chunk_counts,
        scratch.ptr,
        @intCast(scratch.len),
        &bytes_used,
    );
    if (result != decoder.HapResult_No_Error) return error.EncodeFailed;

    return try allocator.dupe(u8, scratch[0..bytes_used]);
}

/// Decode frame 0 of a fixture .mov file. Propagates
/// MmapReader.InitError.OpenFailed so callers can treat a missing fixture
/// as a skip (matching the C++ suite's find_fixture()-empty SKIP path).
fn decodeFixtureFrame0(allocator: std.mem.Allocator, path: []const u8, out: *DecodedFrame) !void {
    var reader = try mmap_reader.MmapReader.init(path);
    defer reader.deinit();

    var dem: demuxer.Demuxer = .{};
    defer dem.deinit(allocator);
    const result = dem.open(allocator, &reader);
    try testing.expect(result.valid);

    const sample = dem.sampleData(&reader, 0) orelse return error.TestUnexpectedResult;

    var dec: Decoder = .{};
    defer dec.deinit(allocator);
    const ok = try dec.decode(allocator, sample, out);
    try testing.expect(ok);
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
    const frame = try buildRawFrame(testing.allocator, &bc1_block, 0xAB);
    defer testing.allocator.free(frame);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try testing.expect(try dec.decode(testing.allocator, frame, &output));
    try testing.expectEqual(@as(usize, 1), output.textures.items.len);

    const tex = output.textures.items[0];
    try testing.expectEqual(HapTextureFormat.rgb_dxt1, tex.format);
    try testing.expectEqual(@as(usize, 8), tex.data.items.len);
    try testing.expectEqualSlices(u8, &bc1_block, tex.data.items);
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

    const frame = try buildRawFrame(testing.allocator, &bc1_blocks, 0xAB);
    defer testing.allocator.free(frame);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try testing.expect(try dec.decode(testing.allocator, frame, &output));
    try testing.expectEqual(@as(usize, 1), output.textures.items.len);
    try testing.expectEqual(@as(usize, 32), output.textures.items[0].data.items.len); // 4 blocks x 8 bytes
}

test "decoder Hap1 frame reports a single texture via HapGetFrameTextureCount" {
    const bc1_block = [_]u8{0} ** 8;
    const frame = try buildRawFrame(testing.allocator, &bc1_block, 0xAB);
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
    const frame = try buildRawFrame(testing.allocator, &bc3_block, 0xAE);
    defer testing.allocator.free(frame);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try testing.expect(try dec.decode(testing.allocator, frame, &output));
    try testing.expectEqual(@as(usize, 1), output.textures.items.len);

    const tex = output.textures.items[0];
    try testing.expectEqual(HapTextureFormat.rgba_dxt5, tex.format);
    try testing.expectEqual(@as(usize, 16), tex.data.items.len);
    try testing.expectEqualSlices(u8, &bc3_block, tex.data.items);
}

test "decoder Hap5 frame reports a single texture via HapGetFrameTextureCount" {
    const bc3_block = [_]u8{0} ** 16;
    const frame = try buildRawFrame(testing.allocator, &bc3_block, 0xAE);
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
    const frame = try buildRawFrame(testing.allocator, &bc7_block, 0xAC);
    defer testing.allocator.free(frame);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try testing.expect(try dec.decode(testing.allocator, frame, &output));
    try testing.expectEqual(@as(usize, 1), output.textures.items.len);

    const tex = output.textures.items[0];
    try testing.expectEqual(HapTextureFormat.rgba_bptc_unorm, tex.format);
    try testing.expectEqual(@as(usize, 16), tex.data.items.len);
    try testing.expectEqualSlices(u8, &bc7_block, tex.data.items);
}

test "decoder Hap7 frame reports a single texture via HapGetFrameTextureCount" {
    const bc7_block = [_]u8{0} ** 16;
    const frame = try buildRawFrame(testing.allocator, &bc7_block, 0xAC);
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

    const frame = try buildRawFrame(testing.allocator, &bc1_blocks, 0xAB);
    defer testing.allocator.free(frame);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try testing.expect(try dec.decode(testing.allocator, frame, &output));
    try testing.expectEqual(@as(usize, 1), output.textures.items.len);
    const tex = output.textures.items[0];
    try testing.expectEqual(HapTextureFormat.rgb_dxt1, tex.format);
    try testing.expectEqual(@as(usize, 32), tex.data.items.len);
    try testing.expectEqualSlices(u8, &bc1_blocks, tex.data.items);
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

    const frame = try buildRawFrame(testing.allocator, &bc3_blocks, 0xAE);
    defer testing.allocator.free(frame);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try testing.expect(try dec.decode(testing.allocator, frame, &output));
    try testing.expectEqual(@as(usize, 1), output.textures.items.len);
    const tex = output.textures.items[0];
    try testing.expectEqual(HapTextureFormat.rgba_dxt5, tex.format);
    try testing.expectEqual(@as(usize, 64), tex.data.items.len);
    try testing.expectEqualSlices(u8, &bc3_blocks, tex.data.items);
}

test "decoder golden Hap7 frame: 4 BC7 blocks decode byte-identical" {
    var bc7_blocks: [64]u8 = [_]u8{0} ** 64;
    bc7_blocks[0] = 0x01;
    bc7_blocks[16] = 0x01;
    bc7_blocks[32] = 0x01;
    bc7_blocks[48] = 0x01;

    const frame = try buildRawFrame(testing.allocator, &bc7_blocks, 0xAC);
    defer testing.allocator.free(frame);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try testing.expect(try dec.decode(testing.allocator, frame, &output));
    try testing.expectEqual(@as(usize, 1), output.textures.items.len);
    const tex = output.textures.items[0];
    try testing.expectEqual(HapTextureFormat.rgba_bptc_unorm, tex.format);
    try testing.expectEqual(@as(usize, 64), tex.data.items.len);
    try testing.expectEqualSlices(u8, &bc7_blocks, tex.data.items);
}

// -----------------------------------------------------------------------
// Unsupported format tests
// -----------------------------------------------------------------------

test "decoder rejects a frame with an invalid type byte" {
    // Type byte 0x00: compressor = 0x0 (invalid), format = 0x0 (invalid).
    const dummy = [_]u8{0} ** 16;
    const frame = try buildRawFrame(testing.allocator, &dummy, 0x00);
    defer testing.allocator.free(frame);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try testing.expect(!(try dec.decode(testing.allocator, frame, &output)));
}

test "decoder rejects a frame with an unsupported compressor nibble" {
    // Type byte 0xD0: compressor = 0xD (invalid), format = 0x0 (invalid).
    const dummy = [_]u8{0} ** 16;
    const frame = try buildRawFrame(testing.allocator, &dummy, 0xD0);
    defer testing.allocator.free(frame);

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try testing.expect(!(try dec.decode(testing.allocator, frame, &output)));
}

// -----------------------------------------------------------------------
// Fixture-based decode tests: demux + decode frame 0 from real .mov files.
// These exercise the Snappy decompress path (the synthetic tests above use
// the None compressor).
// -----------------------------------------------------------------------

test "decoder Hap5 fixture frame0 decodes to track-sized RGBA_DXT5" {
    var reader = mmap_reader.MmapReader.init("tests/fixtures/hap5.mov") catch |err| switch (err) {
        error.OpenFailed => return error.SkipZigTest,
        else => return err,
    };
    defer reader.deinit();

    var dem: demuxer.Demuxer = .{};
    defer dem.deinit(testing.allocator);
    const result = dem.open(testing.allocator, &reader);
    try testing.expect(result.valid);
    try testing.expect(dem.track.fourcc.eql(hap_frame.fcc_hap5));
    try testing.expect(dem.track.frame_count > 0);

    const sample = dem.sampleData(&reader, 0) orelse return error.TestUnexpectedResult;

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try testing.expect(try dec.decode(testing.allocator, sample, &output));
    try testing.expectEqual(@as(usize, 1), output.textures.items.len);

    const tex = output.textures.items[0];
    try testing.expectEqual(HapTextureFormat.rgba_dxt5, tex.format);
    try testing.expectEqual(@as(usize, dem.track.frameBytes()), tex.data.items.len);
}

test "decoder Hap7 fixture frame0 decodes to track-sized RGBA_BPTC_UNORM" {
    var reader = mmap_reader.MmapReader.init("tests/fixtures/hap7.mov") catch |err| switch (err) {
        error.OpenFailed => return error.SkipZigTest,
        else => return err,
    };
    defer reader.deinit();

    var dem: demuxer.Demuxer = .{};
    defer dem.deinit(testing.allocator);
    const result = dem.open(testing.allocator, &reader);
    try testing.expect(result.valid);
    try testing.expect(dem.track.fourcc.eql(hap_frame.fcc_hap7));
    try testing.expect(dem.track.frame_count > 0);

    const sample = dem.sampleData(&reader, 0) orelse return error.TestUnexpectedResult;

    var dec: Decoder = .{};
    defer dec.deinit(testing.allocator);
    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    try testing.expect(try dec.decode(testing.allocator, sample, &output));
    try testing.expectEqual(@as(usize, 1), output.textures.items.len);

    const tex = output.textures.items[0];
    try testing.expectEqual(HapTextureFormat.rgba_bptc_unorm, tex.format);
    try testing.expectEqual(@as(usize, dem.track.frameBytes()), tex.data.items.len);
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

    const unchunked = try buildRawFrame(testing.allocator, &bc1_blocks, 0xAB);
    defer testing.allocator.free(unchunked);
    try testing.expect(unchunked.len > 0);

    const chunked = try createChunkedFrame(testing.allocator, &bc1_blocks, 4, HapTextureFormat_RGB_DXT1, HapCompressorSnappy);
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

    try testing.expect(try dec.decode(testing.allocator, unchunked, &out_unchunked));
    try testing.expect(try dec.decode(testing.allocator, chunked, &out_chunked));

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
    const unchunked = try createChunkedFrame(testing.allocator, &bc3_blocks, 1, HapTextureFormat_YCoCg_DXT5, HapCompressorSnappy);
    defer testing.allocator.free(unchunked);
    try testing.expect(unchunked.len > 0);

    // Encode chunked via HapEncode (4 chunks, Snappy).
    const chunked = try createChunkedFrame(testing.allocator, &bc3_blocks, 4, HapTextureFormat_YCoCg_DXT5, HapCompressorSnappy);
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

    try testing.expect(try dec.decode(testing.allocator, unchunked, &out_unchunked));
    try testing.expect(try dec.decode(testing.allocator, chunked, &out_chunked));

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
        .{ .filename = "tests/fixtures/hap1.mov", .format = .rgb_dxt1, .expected_bytes = 115200 },
        .{ .filename = "tests/fixtures/hapy.mov", .format = .ycocg_dxt5, .expected_bytes = 230400 },
        .{ .filename = "tests/fixtures/hap5.mov", .format = .rgba_dxt5, .expected_bytes = 230400 },
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
        .{ .unchunked = "tests/fixtures/hap1.mov", .chunked = "tests/fixtures/hap1_chunked.mov" },
        .{ .unchunked = "tests/fixtures/hapy.mov", .chunked = "tests/fixtures/hapy_chunked.mov" },
        .{ .unchunked = "tests/fixtures/hap5.mov", .chunked = "tests/fixtures/hap5_chunked.mov" },
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

    decodeFixtureFrame0(testing.allocator, "tests/fixtures/hap1.mov", &frame) catch |err| switch (err) {
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
// Not ported, with reasons:
//
//  - main()/hap::test::run_all() harness (test.h): superseded by the Zig
//    test runner.
//  - No dedicated real-file test for HapM (dual-texture) decoding: the C++
//    suite itself has none either -- there is no committed hapm.mov fixture
//    (tests/fixtures/README.md documents it as conditional/optional), and
//    test_decoder.cpp's own multi-texture cases only assert
//    HapGetFrameTextureCount == 1 for Hap1/5/7 (ported above), never
//    exercising the count == 2 path. The multi-texture index fix itself is
//    preserved in decoder.zig's loop (see its doc comment); a synthetic
//    HapM round-trip test would need HapEncode's two-texture
//    (YCoCg_DXT5 + A_RGTC1) combination, which the upstream suite never
//    tries either -- left as a known gap matching the source suite, not one
//    introduced by this port.
// -----------------------------------------------------------------------
