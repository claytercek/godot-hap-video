//! test_support.zig — shared polling/timing helpers, and synthetic Hap
//! frame builders, for the *_test.zig files that need them
//! (decode_scheduler_test.zig, concurrency_test.zig, decoder_test.zig,
//! fuzz_regressions_test.zig). Not a test file itself (no `test` blocks),
//! so it is not referenced from core.zig's aggregate test block -- it's
//! imported directly by the files that need it, the same way those files
//! import decoder.zig/demuxer.zig etc.
//!
//! Zig 0.16 note: `waitFor`/`holdsFor` use the same std.Io.Clock-based
//! sleep/now idiom as sync.zig's Mutex/Condition wrapper (see also the
//! sibling gdextension-native-media-streams repo's sys_clock.zig, which
//! documents the same Zig-0.16 rationale for wrapping std.Io here).

const std = @import("std");
const testing = std.testing;

const hap_frame = @import("hap_frame.zig");
const mmap_reader = @import("mmap_reader.zig");
const demuxer_mod = @import("demuxer.zig");

const MmapReader = mmap_reader.MmapReader;
const Demuxer = demuxer_mod.Demuxer;

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Monotonic clock reading, in milliseconds.
pub fn nowMs() i64 {
    return std.Io.Clock.awake.now(io()).toMilliseconds();
}

/// Sleep for `ns` nanoseconds (best-effort; errors are ignored, matching
/// std.Thread.sleep's old infallible signature).
pub fn sleepNs(ns: u64) void {
    const duration: std.Io.Clock.Duration = .{ .raw = .fromNanoseconds(@intCast(ns)), .clock = .awake };
    duration.sleep(io()) catch {};
}

/// Poll `pred(ctx)` roughly every millisecond until it returns true or
/// `timeout_ms` elapses. Returns whether it became true in time.
pub fn waitFor(comptime Ctx: type, ctx: Ctx, pred: *const fn (Ctx) bool, timeout_ms: i64) bool {
    const start = nowMs();
    while (!pred(ctx)) {
        if (nowMs() - start > timeout_ms) return false;
        sleepNs(std.time.ns_per_ms);
    }
    return true;
}

/// Poll `pred(ctx)` every ~1ms for `duration_ms`, failing fast the moment
/// it doesn't hold. Use this in place of "sleep a fixed duration, then
/// take a single sample" when the assertion is that a condition holds
/// throughout a window -- a single post-sleep sample can miss a
/// violation that happened and self-corrected inside the sleep.
pub fn holdsFor(comptime Ctx: type, ctx: Ctx, pred: *const fn (Ctx) bool, duration_ms: i64) bool {
    const start = nowMs();
    while (true) {
        if (!pred(ctx)) return false;
        sleepNs(std.time.ns_per_ms);
        if (nowMs() - start >= duration_ms) break;
    }
    return true;
}

/// True if `path` exists and is readable, relative to the process's
/// current working directory (matches the repo-root-relative fixture
/// paths used throughout the test suite).
pub fn fixtureExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io(), path, .{}) catch return false;
    return true;
}

// -----------------------------------------------------------------------
// Synthetic Hap frame builders, shared by decoder_test.zig and
// concurrency_test.zig.
//
// A Hap frame structure:
//   4-byte header: length(3 bytes LE) + type(1 byte)
//   For single-chunk None compressor:
//     type byte = 0xAB (Hap1), 0xAE (Hap5), 0xAC (Hap7)
//   Frame data = raw BC block bytes (pass-through for None compressor)
// -----------------------------------------------------------------------

// Snappy C API (hand-declared, no @cImport per project convention; mirrors
// the extern style hap_decode.zig uses for snappy_uncompress). Needed only
// by createChunkedFrame below, to compress each chunk it builds.
const snappy_ok: c_int = 0;

extern fn snappy_compress(
    input: [*]const u8,
    input_length: usize,
    compressed: [*]u8,
    compressed_length: *usize,
) c_int;

extern fn snappy_max_compressed_length(source_length: usize) usize;

// Wire-format constants (from the Hap spec; mirrors hap_decode.zig's
// private copies -- these are test-only, so duplicating a handful of `u8`
// constants beats making hap_decode.zig's export them for a single caller).
const compressor_none: u8 = 0xA;
const compressor_snappy: u8 = 0xB;
const compressor_complex: u8 = 0xC;

const section_decode_instructions: u8 = 0x01;
const section_chunk_compressor_table: u8 = 0x02;
const section_chunk_size_table: u8 = 0x03;

/// Build a synthetic Hap frame with a given type byte (None compressor,
/// single chunk): the 4-byte header wraps `bc_data` unmodified.
pub fn buildRawFrame(allocator: std.mem.Allocator, bc_data: []const u8, type_byte: u8) ![]u8 {
    const frame = try allocator.alloc(u8, 4 + bc_data.len);
    const length: u32 = @intCast(bc_data.len);
    frame[0] = @truncate(length);
    frame[1] = @truncate(length >> 8);
    frame[2] = @truncate(length >> 16);
    frame[3] = type_byte;
    @memcpy(frame[4..], bc_data);
    return frame;
}

/// Map a HapTextureFormat to its section-type-byte format nibble (the
/// inverse of hap_decode.zig's private textureFormatFromNibble).
fn formatNibble(format: hap_frame.HapTextureFormat) u8 {
    return switch (format) {
        .rgb_dxt1 => 0xB,
        .rgba_dxt5 => 0xE,
        .ycocg_dxt5 => 0xF,
        .a_rgtc1 => 0x1,
        .rgba_bptc_unorm => 0xC,
    };
}

/// Build a [size24][type] section header wrapping `payload`, using the short
/// 4-byte header form. Shared by every *_test.zig / *_fuzz.zig file that
/// needs to hand-build Hap wire bytes (decoder_test.zig, hap_decode.zig's
/// own inline tests, hap_decode_fuzz.zig's seed frames).
pub fn buildSection(allocator: std.mem.Allocator, type_byte: u8, payload: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, 4 + payload.len);
    const len: u32 = @intCast(payload.len);
    out[0] = @truncate(len);
    out[1] = @truncate(len >> 8);
    out[2] = @truncate(len >> 16);
    out[3] = type_byte;
    @memcpy(out[4..], payload);
    return out;
}

/// Build a section using the extended 8-byte header form (24-bit size zero,
/// real size in bytes 4..7). The only way to encode a zero-length section,
/// since the short form's zero size selects this extended form.
pub fn buildSectionExt(allocator: std.mem.Allocator, type_byte: u8, payload: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, 8 + payload.len);
    out[0] = 0;
    out[1] = 0;
    out[2] = 0;
    out[3] = type_byte;
    std.mem.writeInt(u32, out[4..8], @intCast(payload.len), .little);
    @memcpy(out[8..], payload);
    return out;
}

/// Build a synthetic Complex (chunked) Hap frame carrying `tex_data`, split
/// into exactly `chunk_count` roughly-equal contiguous chunks (clamped to a
/// minimum of 1). Each chunk is Snappy-compressed; a chunk whose compressed
/// form isn't smaller than the original is instead stored uncompressed
/// (compressor byte 0xA). No offset table is emitted -- chunks are
/// contiguous in frame-data order, which hap_decode.zig's parser derives on
/// its own when the offset table is absent.
///
/// Unlike the old HapEncode-backed version, the chunk count here never
/// collapses: the caller always gets back exactly `chunk_count` chunks,
/// even over incompressible or tiny input.
pub fn createChunkedFrame(
    allocator: std.mem.Allocator,
    tex_data: []const u8,
    chunk_count: u32,
    format: hap_frame.HapTextureFormat,
) ![]u8 {
    const n = @max(chunk_count, 1);

    const compressor_tbl = try allocator.alloc(u8, n);
    defer allocator.free(compressor_tbl);
    const size_tbl = try allocator.alloc(u8, n * 4);
    defer allocator.free(size_tbl);

    var frame_data = std.ArrayListUnmanaged(u8).empty;
    defer frame_data.deinit(allocator);

    const base = tex_data.len / n;
    const remainder = tex_data.len % n;

    var start: usize = 0;
    for (0..n) |i| {
        const extra: usize = if (i < remainder) 1 else 0;
        const end = start + base + extra;
        const chunk = tex_data[start..end];
        start = end;

        const max_compressed = snappy_max_compressed_length(chunk.len);
        const scratch = try allocator.alloc(u8, max_compressed);
        defer allocator.free(scratch);

        var out_len: usize = scratch.len;
        const status = snappy_compress(chunk.ptr, chunk.len, scratch.ptr, &out_len);

        if (status == snappy_ok and out_len < chunk.len) {
            compressor_tbl[i] = compressor_snappy;
            std.mem.writeInt(u32, size_tbl[i * 4 ..][0..4], @intCast(out_len), .little);
            try frame_data.appendSlice(allocator, scratch[0..out_len]);
        } else {
            compressor_tbl[i] = compressor_none;
            std.mem.writeInt(u32, size_tbl[i * 4 ..][0..4], @intCast(chunk.len), .little);
            try frame_data.appendSlice(allocator, chunk);
        }
    }

    const sec_comp = try buildSection(allocator, section_chunk_compressor_table, compressor_tbl);
    defer allocator.free(sec_comp);
    const sec_size = try buildSection(allocator, section_chunk_size_table, size_tbl);
    defer allocator.free(sec_size);

    var container_body = std.ArrayListUnmanaged(u8).empty;
    defer container_body.deinit(allocator);
    try container_body.appendSlice(allocator, sec_comp);
    try container_body.appendSlice(allocator, sec_size);

    const container = try buildSection(allocator, section_decode_instructions, container_body.items);
    defer allocator.free(container);

    var payload = std.ArrayListUnmanaged(u8).empty;
    defer payload.deinit(allocator);
    try payload.appendSlice(allocator, container);
    try payload.appendSlice(allocator, frame_data.items);

    const type_byte = (compressor_complex << 4) | formatNibble(format);
    return buildSection(allocator, type_byte, payload.items);
}

// -----------------------------------------------------------------------
// Fixture helpers.
//
// Fixture paths are relative to the repo root, which is the test working
// directory (matches mmap_reader.zig's fixture tests). A missing fixture
// skips the test rather than failing it, so a stripped checkout still runs
// the synthetic suites.
// -----------------------------------------------------------------------

/// An open fixture: the mapped file plus the demuxer that parsed it.
pub const Fixture = struct {
    reader: MmapReader,
    demuxer: Demuxer,

    pub fn deinit(self: *Fixture) void {
        self.demuxer.deinit(testing.allocator);
        self.reader.deinit();
    }

    /// Compressed sample bytes of frame `index`.
    pub fn sample(self: *const Fixture, index: u32) ![]const u8 {
        return self.demuxer.sampleData(&self.reader, index) orelse error.TestUnexpectedResult;
    }
};

/// Map and demux the fixture at `path`. A missing file yields
/// `error.SkipZigTest`, which a whole test can propagate and a per-case loop
/// can catch to skip just that case.
pub fn openFixture(path: []const u8) !Fixture {
    var reader = MmapReader.init(path) catch |err| switch (err) {
        error.OpenFailed => return error.SkipZigTest,
        else => return err,
    };
    errdefer reader.deinit();

    var dem: Demuxer = .{};
    errdefer dem.deinit(testing.allocator);
    try dem.open(testing.allocator, &reader);

    return .{ .reader = reader, .demuxer = dem };
}
