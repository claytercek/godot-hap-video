//! hap_decode.zig
//!
//! Clean-room Hap frame parser and decoder, implemented from the Hap
//! bitstream specification (HapVideoDRAFT.md). Parses a single compressed
//! Hap frame -- its section headers, texture format, and (for the Complex
//! compressor) its chunk decode-instructions -- and decompresses one
//! texture at a time into a caller-provided buffer.
//!
//! Three second-stage compressors are handled: None (raw copy), Snappy
//! (single block), and Complex (per-chunk None/Snappy, decompressed in
//! parallel via the shared InnerThreadPool). Supported texture formats are
//! the five with a `hap_frame.HapTextureFormat` tag; the two Hap HDR (BC6H)
//! format nibbles are rejected as invalid, matching the demuxer's rejection
//! of HapHDR -- decoding HDR is a stated limitation.
//!
//! Deliberate behavior changes from the reference C decoder:
//!  * A Complex frame whose decode instructions yield a chunk count of zero
//!    is rejected as an invalid frame. The reference code silently
//!    "succeeds" producing zero output bytes; we treat that as malformed.
//!  * Every chunk's compressed span is bounds-checked against the frame
//!    data before it is read. The reference code trusts the size/offset
//!    tables and can read out of bounds on a malformed frame.

const std = @import("std");

const hap_frame = @import("hap_frame.zig");
const thread_pool = @import("thread_pool.zig");

const HapTextureFormat = hap_frame.HapTextureFormat;

pub const Error = error{InvalidFrame};
pub const DecodeError = error{ InvalidFrame, OutOfMemory };

// -----------------------------------------------------------------------
// Snappy C API (hand-declared, no @cImport per project convention).
// -----------------------------------------------------------------------

/// snappy_status values from thirdparty/snappy/snappy-c.h.
const snappy_ok: c_int = 0;

extern fn snappy_uncompress(
    compressed: [*]const u8,
    compressed_length: usize,
    uncompressed: [*]u8,
    uncompressed_length: *usize,
) c_int;

extern fn snappy_uncompressed_length(
    compressed: [*]const u8,
    compressed_length: usize,
    result: *usize,
) c_int;

// -----------------------------------------------------------------------
// Wire-format constants (from the Hap spec).
// -----------------------------------------------------------------------

/// Top nibble of a texture section's type byte: the second-stage compressor.
const compressor_none: u8 = 0xA;
const compressor_snappy: u8 = 0xB;
const compressor_complex: u8 = 0xC;

/// Section type bytes.
const section_multi_image: u8 = 0x0D;
const section_decode_instructions: u8 = 0x01;
const section_chunk_compressor_table: u8 = 0x02;
const section_chunk_size_table: u8 = 0x03;
const section_chunk_offset_table: u8 = 0x04;

// -----------------------------------------------------------------------
// Little-endian scalar reads.
// -----------------------------------------------------------------------

/// Read a 24-bit little-endian unsigned int. Caller guarantees >= 3 bytes.
fn readU24(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16);
}

/// Read a 32-bit little-endian unsigned int. Caller guarantees >= 4 bytes.
fn readU32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

// -----------------------------------------------------------------------
// Section header parsing.
// -----------------------------------------------------------------------

/// A parsed Hap section header. `size` is the payload length excluding the
/// header; the payload occupies `buf[header_len .. header_len + size]`.
const SectionHeader = struct {
    header_len: usize,
    size: usize,
    type: u8,
};

/// Parse the section header at the start of `buf`. The 24-bit size lives in
/// bytes 0..2; a size of zero selects the 8-byte extended form whose real
/// size is a 32-bit LE value at bytes 4..7. The type byte is always at
/// offset 3. Enforces that `header_len + size` fits within `buf`.
fn readSectionHeader(buf: []const u8) Error!SectionHeader {
    if (buf.len < 4) return error.InvalidFrame;

    var size: usize = readU24(buf);
    var header_len: usize = 4;
    if (size == 0) {
        if (buf.len < 8) return error.InvalidFrame;
        size = readU32(buf[4..8]);
        header_len = 8;
    }
    const type_byte = buf[3];

    if (size > buf.len - header_len) return error.InvalidFrame;

    return .{ .header_len = header_len, .size = size, .type = type_byte };
}

/// A located texture section: its payload bytes and its packed type byte
/// (compressor nibble in the high 4 bits, format nibble in the low 4).
const TextureSection = struct {
    payload: []const u8,
    type: u8,
};

/// Locate the texture section at `index`. For a top-level Multi-Image
/// section (HapM) this walks the back-to-back sub-sections; otherwise the
/// single texture is the top-level section and only index 0 is valid.
fn sectionAtIndex(frame: []const u8, index: u32) Error!TextureSection {
    const top = try readSectionHeader(frame);

    if (top.type == section_multi_image) {
        const body = frame[top.header_len..][0..top.size];
        var offset: usize = 0;
        var i: u32 = 0;
        while (true) : (i += 1) {
            if (offset >= body.len) return error.InvalidFrame;
            const sub = try readSectionHeader(body[offset..]);
            if (i == index) {
                const start = offset + sub.header_len;
                return .{ .payload = body[start..][0..sub.size], .type = sub.type };
            }
            offset += sub.header_len + sub.size;
        }
    }

    if (index != 0) return error.InvalidFrame;
    return .{ .payload = frame[top.header_len..][0..top.size], .type = top.type };
}

/// Map a Hap format nibble to a supported texture format. The two Hap HDR
/// (BC6H) nibbles and any unknown nibble are rejected -- HDR decode is a
/// stated limitation.
fn textureFormatFromNibble(nibble: u8) Error!HapTextureFormat {
    return switch (nibble) {
        0xB => .rgb_dxt1,
        0xE => .rgba_dxt5,
        0xF => .ycocg_dxt5,
        0x1 => .a_rgtc1,
        0xC => .rgba_bptc_unorm,
        else => error.InvalidFrame,
    };
}

// -----------------------------------------------------------------------
// Public queries.
// -----------------------------------------------------------------------

/// Number of textures carried by `frame`: 1 for a single-texture frame, or
/// the count of sub-sections in a Multi-Image (HapM) frame. Does not cap
/// the result -- the caller enforces the 1..=2 supported range.
pub fn frameTextureCount(frame: []const u8) Error!u32 {
    const top = try readSectionHeader(frame);
    if (top.type != section_multi_image) return 1;

    const body = frame[top.header_len..][0..top.size];
    var offset: usize = 0;
    var count: u32 = 0;
    while (offset < body.len) {
        const sub = try readSectionHeader(body[offset..]);
        offset += sub.header_len + sub.size;
        count += 1;
    }
    return count;
}

/// Texture format of the texture at `index`.
pub fn frameTextureFormat(frame: []const u8, index: u32) Error!HapTextureFormat {
    const sec = try sectionAtIndex(frame, index);
    return textureFormatFromNibble(sec.type & 0x0F);
}

/// Number of second-stage chunks for the texture at `index`: the parsed
/// chunk count for a Complex texture, or 1 for None/Snappy.
pub fn frameTextureChunkCount(frame: []const u8, index: u32) Error!u32 {
    const sec = try sectionAtIndex(frame, index);
    const compressor = sec.type >> 4;
    return switch (compressor) {
        compressor_complex => (try parseComplexInstructions(sec.payload)).chunk_count,
        compressor_none, compressor_snappy => 1,
        else => error.InvalidFrame,
    };
}

// -----------------------------------------------------------------------
// Complex (chunked) decode instructions.
// -----------------------------------------------------------------------

/// Parsed contents of a Decode Instructions Container. The compressor and
/// size tables are required; the offset table is optional (absent means
/// chunk offsets are the cumulative sums of the size table). `frame_data`
/// is the compressed chunk data following the container.
const ComplexInstructions = struct {
    chunk_count: u32,
    compressors: []const u8,
    sizes: []const u8,
    offsets: ?[]const u8,
    frame_data: []const u8,
};

/// Parse the Decode Instructions Container at the start of a Complex
/// texture section's payload. Sub-sections may appear in any order; unknown
/// ones are skipped. Chunk counts derived from each present table must
/// agree.
fn parseComplexInstructions(payload: []const u8) Error!ComplexInstructions {
    const container = try readSectionHeader(payload);
    if (container.type != section_decode_instructions) return error.InvalidFrame;

    // Frame data begins immediately after the container.
    const frame_data = payload[container.header_len + container.size ..];

    const body = payload[container.header_len..][0..container.size];
    var compressors: ?[]const u8 = null;
    var sizes: ?[]const u8 = null;
    var offsets: ?[]const u8 = null;
    var chunk_count: u32 = 0;

    var offset: usize = 0;
    while (offset < body.len) {
        const sub = try readSectionHeader(body[offset..]);
        const data = body[offset + sub.header_len ..][0..sub.size];

        // `@intCast` to u32 below cannot wrap: `sub.size` is bounded by
        // `readSectionHeader` to fit within the enclosing buffer, which is
        // ultimately a slice of one MP4 sample (see demuxer.zig/hap_frame.zig
        // `SampleEntry.size: u32`, sourced from minimp4's 32-bit stsz/stz2
        // fields) -- so no section can be larger than u32 max to begin with.
        var section_chunk_count: u32 = 0;
        switch (sub.type) {
            section_chunk_compressor_table => {
                compressors = data;
                section_chunk_count = @intCast(sub.size);
            },
            section_chunk_size_table => {
                sizes = data;
                section_chunk_count = @intCast(sub.size / 4);
            },
            section_chunk_offset_table => {
                offsets = data;
                section_chunk_count = @intCast(sub.size / 4);
            },
            else => {}, // skip unknown sub-section
        }

        if (section_chunk_count != 0) {
            if (chunk_count != 0 and section_chunk_count != chunk_count) {
                return error.InvalidFrame;
            }
            chunk_count = section_chunk_count;
        }

        offset += sub.header_len + sub.size;
    }

    if (compressors == null or sizes == null) return error.InvalidFrame;

    return .{
        .chunk_count = chunk_count,
        .compressors = compressors.?,
        .sizes = sizes.?,
        .offsets = offsets,
        .frame_data = frame_data,
    };
}

// -----------------------------------------------------------------------
// Chunked decode worker (driven by the shared InnerThreadPool).
// -----------------------------------------------------------------------

/// One chunk's decode plan. `dst` is filled in after the output buffer is
/// sized (resizing may move the buffer, so slices are bound afterwards).
const ChunkJob = struct {
    compressor: u8,
    src: []const u8,
    dst_off: usize,
    dst: []u8 = &.{},
    ok: bool = false,
};

/// Context handed to the per-chunk worker. Each worker invocation touches a
/// distinct job, so no synchronization is needed within a batch -- the pool
/// establishes the happens-before edge around `execute`.
const ChunkBatch = struct {
    jobs: []ChunkJob,
};

/// InnerThreadPool work function: decode chunk `index` of the batch.
fn decodeChunkWorker(p: ?*anyopaque, index: c_uint) void {
    const batch: *ChunkBatch = @ptrCast(@alignCast(p.?));
    const job = &batch.jobs[index];
    switch (job.compressor) {
        compressor_snappy => {
            var out_len: usize = job.dst.len;
            const status = snappy_uncompress(job.src.ptr, job.src.len, job.dst.ptr, &out_len);
            job.ok = status == snappy_ok and out_len == job.dst.len;
        },
        compressor_none => {
            if (job.src.len == job.dst.len) {
                @memcpy(job.dst, job.src);
                job.ok = true;
            }
        },
        else => {}, // job.ok stays false
    }
}

/// Decode a Complex (chunked) texture section into `out`, sized exactly to
/// the summed uncompressed chunk lengths.
fn decodeComplex(allocator: std.mem.Allocator, payload: []const u8, out: *std.ArrayListUnmanaged(u8)) DecodeError!void {
    const instr = try parseComplexInstructions(payload);
    const n = instr.chunk_count;
    if (n == 0) return error.InvalidFrame;

    const jobs = try allocator.alloc(ChunkJob, n);
    defer allocator.free(jobs);

    // Plan every chunk: validate its compressor, bound its compressed span
    // against the frame data, and accumulate the exact output size.
    var total: usize = 0;
    var running_compressed: usize = 0;
    for (jobs, 0..) |*job, i| {
        const comp = instr.compressors[i];
        if (comp != compressor_none and comp != compressor_snappy) return error.InvalidFrame;

        const csize: usize = readU32(instr.sizes[i * 4 ..][0..4]);
        const coffset: usize = if (instr.offsets) |o| readU32(o[i * 4 ..][0..4]) else running_compressed;
        running_compressed += csize;

        // Bounds check (an improvement over the reference decoder, which
        // trusts the tables and can read past the frame data).
        if (coffset > instr.frame_data.len or csize > instr.frame_data.len - coffset) {
            return error.InvalidFrame;
        }
        const src = instr.frame_data[coffset..][0..csize];

        const usize_out: usize = switch (comp) {
            compressor_snappy => blk: {
                var ul: usize = 0;
                if (snappy_uncompressed_length(src.ptr, src.len, &ul) != snappy_ok) return error.InvalidFrame;
                break :blk ul;
            },
            else => csize, // None: uncompressed size == compressed size
        };

        job.* = .{ .compressor = comp, .src = src, .dst_off = total };
        total += usize_out;
    }

    try out.resize(allocator, total);

    // Bind destination slices now that the buffer is at its final address.
    for (jobs, 0..) |*job, i| {
        const end = if (i + 1 < jobs.len) jobs[i + 1].dst_off else total;
        job.dst = out.items[job.dst_off..end];
    }

    var batch = ChunkBatch{ .jobs = jobs };
    // count <= 1 decodes inline on the calling thread (no pool involvement).
    thread_pool.instance().execute(decodeChunkWorker, &batch, n);

    for (jobs) |job| {
        if (!job.ok) return error.InvalidFrame;
    }
}

// -----------------------------------------------------------------------
// Public single-texture decode.
// -----------------------------------------------------------------------

/// Decode the texture at `index` into `out`, sized exactly to the decoded
/// data, and return its format. `out` is resized (its prior contents are
/// overwritten). On error `out` is left in an unspecified but valid state;
/// callers that need it emptied on failure must clear it themselves (the
/// decoder does, via its errdefer).
pub fn decodeTexture(
    allocator: std.mem.Allocator,
    frame: []const u8,
    index: u32,
    out: *std.ArrayListUnmanaged(u8),
) DecodeError!HapTextureFormat {
    const sec = try sectionAtIndex(frame, index);
    // Validate the texture format before decoding (matches the reference
    // decoder's ordering: a bad format nibble fails before any output).
    const format = try textureFormatFromNibble(sec.type & 0x0F);

    switch (sec.type >> 4) {
        compressor_none => {
            try out.resize(allocator, sec.payload.len);
            @memcpy(out.items, sec.payload);
        },
        compressor_snappy => {
            var decoded_len: usize = 0;
            if (snappy_uncompressed_length(sec.payload.ptr, sec.payload.len, &decoded_len) != snappy_ok) {
                return error.InvalidFrame;
            }
            try out.resize(allocator, decoded_len);
            var got: usize = decoded_len;
            if (snappy_uncompress(sec.payload.ptr, sec.payload.len, out.items.ptr, &got) != snappy_ok) {
                return error.InvalidFrame;
            }
        },
        compressor_complex => try decodeComplex(allocator, sec.payload, out),
        else => return error.InvalidFrame,
    }

    return format;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;
const test_support = @import("test_support.zig");

/// Build a Complex texture frame (single top-level texture) from None-
/// compressor chunks. When `with_offsets` is true an offset table (equal to
/// the cumulative chunk offsets) is emitted as well.
fn buildComplexNone(
    allocator: std.mem.Allocator,
    format_nibble: u8,
    chunks: []const []const u8,
    with_offsets: bool,
) ![]u8 {
    const n = chunks.len;

    const compressor_tbl = try allocator.alloc(u8, n);
    defer allocator.free(compressor_tbl);
    @memset(compressor_tbl, compressor_none);

    const size_tbl = try allocator.alloc(u8, n * 4);
    defer allocator.free(size_tbl);
    const offset_tbl = try allocator.alloc(u8, n * 4);
    defer allocator.free(offset_tbl);

    var frame_data = std.ArrayListUnmanaged(u8).empty;
    defer frame_data.deinit(allocator);

    var running: u32 = 0;
    for (chunks, 0..) |chunk, i| {
        std.mem.writeInt(u32, size_tbl[i * 4 ..][0..4], @intCast(chunk.len), .little);
        std.mem.writeInt(u32, offset_tbl[i * 4 ..][0..4], running, .little);
        running += @intCast(chunk.len);
        try frame_data.appendSlice(allocator, chunk);
    }

    const sec_comp = try test_support.buildSection(allocator, section_chunk_compressor_table, compressor_tbl);
    defer allocator.free(sec_comp);
    const sec_size = try test_support.buildSection(allocator, section_chunk_size_table, size_tbl);
    defer allocator.free(sec_size);
    const sec_off = try test_support.buildSection(allocator, section_chunk_offset_table, offset_tbl);
    defer allocator.free(sec_off);

    var container_body = std.ArrayListUnmanaged(u8).empty;
    defer container_body.deinit(allocator);
    try container_body.appendSlice(allocator, sec_comp);
    try container_body.appendSlice(allocator, sec_size);
    if (with_offsets) try container_body.appendSlice(allocator, sec_off);

    const container = try test_support.buildSection(allocator, section_decode_instructions, container_body.items);
    defer allocator.free(container);

    var payload = std.ArrayListUnmanaged(u8).empty;
    defer payload.deinit(allocator);
    try payload.appendSlice(allocator, container);
    try payload.appendSlice(allocator, frame_data.items);

    const type_byte = (compressor_complex << 4) | (format_nibble & 0x0F);
    return test_support.buildSection(allocator, type_byte, payload.items);
}

test "readSectionHeader parses a 4-byte header" {
    const buf = [_]u8{ 0x03, 0x00, 0x00, 0xAB, 0x11, 0x22, 0x33 };
    const h = try readSectionHeader(&buf);
    try testing.expectEqual(@as(usize, 4), h.header_len);
    try testing.expectEqual(@as(usize, 3), h.size);
    try testing.expectEqual(@as(u8, 0xAB), h.type);
}

test "readSectionHeader parses an extended 8-byte header" {
    // 24-bit size zero -> real size in bytes 4..7 (LE). type at byte 3.
    var buf: [12]u8 = @splat(0);
    buf[3] = 0xAB;
    std.mem.writeInt(u32, buf[4..8], 4, .little);
    const h = try readSectionHeader(&buf);
    try testing.expectEqual(@as(usize, 8), h.header_len);
    try testing.expectEqual(@as(usize, 4), h.size);
    try testing.expectEqual(@as(u8, 0xAB), h.type);
}

test "readSectionHeader rejects a truncated 4-byte header" {
    const buf = [_]u8{ 0x01, 0x00, 0x00 };
    try testing.expectError(error.InvalidFrame, readSectionHeader(&buf));
}

test "readSectionHeader rejects a truncated extended header" {
    // 24-bit size zero selects the 8-byte form, but only 5 bytes present.
    const buf = [_]u8{ 0x00, 0x00, 0x00, 0xAB, 0x00 };
    try testing.expectError(error.InvalidFrame, readSectionHeader(&buf));
}

test "readSectionHeader rejects a size that overruns the buffer" {
    // Declares 16 payload bytes but only 4 follow.
    const buf = [_]u8{ 0x10, 0x00, 0x00, 0xAB, 0, 0, 0, 0 };
    try testing.expectError(error.InvalidFrame, readSectionHeader(&buf));
}

test "frameTextureCount returns 1 for a single-texture frame" {
    const payload: [8]u8 = @splat(0);
    const frame = try test_support.buildSection(testing.allocator, 0xAB, &payload);
    defer testing.allocator.free(frame);
    try testing.expectEqual(@as(u32, 1), try frameTextureCount(frame));
}

test "frameTextureCount walks multi-image sub-sections" {
    const block: [8]u8 = @splat(0);
    const sub0 = try test_support.buildSection(testing.allocator, 0xAB, &block);
    defer testing.allocator.free(sub0);
    const sub1 = try test_support.buildSection(testing.allocator, 0xAB, &block);
    defer testing.allocator.free(sub1);

    var body = std.ArrayListUnmanaged(u8).empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, sub0);
    try body.appendSlice(testing.allocator, sub1);

    const frame = try test_support.buildSection(testing.allocator, section_multi_image, body.items);
    defer testing.allocator.free(frame);

    try testing.expectEqual(@as(u32, 2), try frameTextureCount(frame));
}

test "frameTextureFormat maps the format nibble" {
    const payload: [8]u8 = @splat(0);
    const frame = try test_support.buildSection(testing.allocator, 0xAF, &payload); // None|YCoCg
    defer testing.allocator.free(frame);
    try testing.expectEqual(HapTextureFormat.ycocg_dxt5, try frameTextureFormat(frame, 0));
}

test "decodeTexture rejects BC6H (Hap HDR) format nibbles" {
    const payload: [8]u8 = @splat(0);
    inline for (.{ 0xA2, 0xA3 }) |type_byte| { // None|BC6H-unsigned / -signed
        const frame = try test_support.buildSection(testing.allocator, type_byte, &payload);
        defer testing.allocator.free(frame);
        var out = std.ArrayListUnmanaged(u8).empty;
        defer out.deinit(testing.allocator);
        try testing.expectError(error.InvalidFrame, decodeTexture(testing.allocator, frame, 0, &out));
    }
}

test "decodeTexture copies a None-compressor texture verbatim" {
    const bc = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const frame = try test_support.buildSection(testing.allocator, 0xAB, &bc);
    defer testing.allocator.free(frame);

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(testing.allocator);
    const fmt = try decodeTexture(testing.allocator, frame, 0, &out);
    try testing.expectEqual(HapTextureFormat.rgb_dxt1, fmt);
    try testing.expectEqualSlices(u8, &bc, out.items);
}

test "decodeTexture decodes a multi-chunk None Complex frame (offset table absent)" {
    const c0 = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const c1 = [_]u8{ 0x11, 0x22 };
    const c2 = [_]u8{ 0x77, 0x88, 0x99 };
    const frame = try buildComplexNone(testing.allocator, 0xB, &.{ &c0, &c1, &c2 }, false);
    defer testing.allocator.free(frame);

    try testing.expectEqual(@as(u32, 3), try frameTextureChunkCount(frame, 0));

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(testing.allocator);
    const fmt = try decodeTexture(testing.allocator, frame, 0, &out);
    try testing.expectEqual(HapTextureFormat.rgb_dxt1, fmt);
    try testing.expectEqualSlices(u8, &(c0 ++ c1 ++ c2), out.items);
}

test "decodeTexture decodes a Complex frame with an explicit offset table" {
    const c0 = [_]u8{ 0xDE, 0xAD };
    const c1 = [_]u8{ 0xBE, 0xEF, 0x00 };
    const frame = try buildComplexNone(testing.allocator, 0xB, &.{ &c0, &c1 }, true);
    defer testing.allocator.free(frame);

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(testing.allocator);
    _ = try decodeTexture(testing.allocator, frame, 0, &out);
    try testing.expectEqualSlices(u8, &(c0 ++ c1), out.items);
}

test "parseComplexInstructions skips unknown sub-sections" {
    const c0 = [_]u8{ 0x01, 0x02 };
    // Build a normal frame, then splice an unknown (type 0x7F) sub-section
    // into the container before the required tables.
    const chunk_slices = [_][]const u8{&c0};

    var compressor_tbl = [_]u8{compressor_none};
    var size_tbl: [4]u8 = undefined;
    std.mem.writeInt(u32, &size_tbl, c0.len, .little);

    const unknown = try test_support.buildSection(testing.allocator, 0x7F, &[_]u8{ 0xFF, 0xFF });
    defer testing.allocator.free(unknown);
    const sec_comp = try test_support.buildSection(testing.allocator, section_chunk_compressor_table, &compressor_tbl);
    defer testing.allocator.free(sec_comp);
    const sec_size = try test_support.buildSection(testing.allocator, section_chunk_size_table, &size_tbl);
    defer testing.allocator.free(sec_size);

    var container_body = std.ArrayListUnmanaged(u8).empty;
    defer container_body.deinit(testing.allocator);
    try container_body.appendSlice(testing.allocator, unknown);
    try container_body.appendSlice(testing.allocator, sec_comp);
    try container_body.appendSlice(testing.allocator, sec_size);

    const container = try test_support.buildSection(testing.allocator, section_decode_instructions, container_body.items);
    defer testing.allocator.free(container);

    var payload = std.ArrayListUnmanaged(u8).empty;
    defer payload.deinit(testing.allocator);
    try payload.appendSlice(testing.allocator, container);
    try payload.appendSlice(testing.allocator, &c0);

    const frame = try test_support.buildSection(testing.allocator, 0xCB, payload.items);
    defer testing.allocator.free(frame);

    _ = chunk_slices;
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(testing.allocator);
    _ = try decodeTexture(testing.allocator, frame, 0, &out);
    try testing.expectEqualSlices(u8, &c0, out.items);
}

test "parseComplexInstructions rejects mismatched table chunk counts" {
    // Compressor table says 2 chunks, size table says 1.
    var compressor_tbl = [_]u8{ compressor_none, compressor_none };
    var size_tbl: [4]u8 = undefined;
    std.mem.writeInt(u32, &size_tbl, 4, .little);

    const sec_comp = try test_support.buildSection(testing.allocator, section_chunk_compressor_table, &compressor_tbl);
    defer testing.allocator.free(sec_comp);
    const sec_size = try test_support.buildSection(testing.allocator, section_chunk_size_table, &size_tbl);
    defer testing.allocator.free(sec_size);

    var container_body = std.ArrayListUnmanaged(u8).empty;
    defer container_body.deinit(testing.allocator);
    try container_body.appendSlice(testing.allocator, sec_comp);
    try container_body.appendSlice(testing.allocator, sec_size);

    const container = try test_support.buildSection(testing.allocator, section_decode_instructions, container_body.items);
    defer testing.allocator.free(container);

    const frame = try test_support.buildSection(testing.allocator, 0xCB, container);
    defer testing.allocator.free(frame);

    try testing.expectError(error.InvalidFrame, frameTextureChunkCount(frame, 0));
}

test "decodeTexture rejects a chunk with a bad compressor byte" {
    // Hand-build a 1-chunk Complex frame whose compressor byte is 0xC.
    var compressor_tbl = [_]u8{0xC};
    var size_tbl: [4]u8 = undefined;
    std.mem.writeInt(u32, &size_tbl, 2, .little);
    const chunk = [_]u8{ 0x01, 0x02 };

    const sec_comp = try test_support.buildSection(testing.allocator, section_chunk_compressor_table, &compressor_tbl);
    defer testing.allocator.free(sec_comp);
    const sec_size = try test_support.buildSection(testing.allocator, section_chunk_size_table, &size_tbl);
    defer testing.allocator.free(sec_size);

    var container_body = std.ArrayListUnmanaged(u8).empty;
    defer container_body.deinit(testing.allocator);
    try container_body.appendSlice(testing.allocator, sec_comp);
    try container_body.appendSlice(testing.allocator, sec_size);

    const container = try test_support.buildSection(testing.allocator, section_decode_instructions, container_body.items);
    defer testing.allocator.free(container);

    var payload = std.ArrayListUnmanaged(u8).empty;
    defer payload.deinit(testing.allocator);
    try payload.appendSlice(testing.allocator, container);
    try payload.appendSlice(testing.allocator, &chunk);

    const frame = try test_support.buildSection(testing.allocator, 0xCB, payload.items);
    defer testing.allocator.free(frame);

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.InvalidFrame, decodeTexture(testing.allocator, frame, 0, &out));
}

test "decodeTexture rejects a Complex frame with zero chunks" {
    // Empty compressor and size tables -> chunk count 0. A zero-length
    // section must use the extended 8-byte header form.
    const empty = [_]u8{};
    const sec_comp = try test_support.buildSectionExt(testing.allocator, section_chunk_compressor_table, &empty);
    defer testing.allocator.free(sec_comp);
    const sec_size = try test_support.buildSectionExt(testing.allocator, section_chunk_size_table, &empty);
    defer testing.allocator.free(sec_size);

    var container_body = std.ArrayListUnmanaged(u8).empty;
    defer container_body.deinit(testing.allocator);
    try container_body.appendSlice(testing.allocator, sec_comp);
    try container_body.appendSlice(testing.allocator, sec_size);

    const container = try test_support.buildSection(testing.allocator, section_decode_instructions, container_body.items);
    defer testing.allocator.free(container);

    const frame = try test_support.buildSection(testing.allocator, 0xCB, container);
    defer testing.allocator.free(frame);

    // The query reports 0; decode rejects it.
    try testing.expectEqual(@as(u32, 0), try frameTextureChunkCount(frame, 0));

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.InvalidFrame, decodeTexture(testing.allocator, frame, 0, &out));
}

test "decodeComplex bounds-checks a chunk size against the frame data" {
    // Size table claims a 16-byte chunk but only 2 frame-data bytes follow.
    var compressor_tbl = [_]u8{compressor_none};
    var size_tbl: [4]u8 = undefined;
    std.mem.writeInt(u32, &size_tbl, 16, .little);
    const chunk = [_]u8{ 0x01, 0x02 };

    const sec_comp = try test_support.buildSection(testing.allocator, section_chunk_compressor_table, &compressor_tbl);
    defer testing.allocator.free(sec_comp);
    const sec_size = try test_support.buildSection(testing.allocator, section_chunk_size_table, &size_tbl);
    defer testing.allocator.free(sec_size);

    var container_body = std.ArrayListUnmanaged(u8).empty;
    defer container_body.deinit(testing.allocator);
    try container_body.appendSlice(testing.allocator, sec_comp);
    try container_body.appendSlice(testing.allocator, sec_size);

    const container = try test_support.buildSection(testing.allocator, section_decode_instructions, container_body.items);
    defer testing.allocator.free(container);

    var payload = std.ArrayListUnmanaged(u8).empty;
    defer payload.deinit(testing.allocator);
    try payload.appendSlice(testing.allocator, container);
    try payload.appendSlice(testing.allocator, &chunk);

    const frame = try test_support.buildSection(testing.allocator, 0xCB, payload.items);
    defer testing.allocator.free(frame);

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.InvalidFrame, decodeTexture(testing.allocator, frame, 0, &out));
}
