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
const decoder = @import("decoder.zig");

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

// hap.c externs needed only by createChunkedFrame below.
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

/// Encode `tex_data` into a real (HapEncode-produced) Hap frame with the
/// given chunk count / texture format / compressor -- exercises the real
/// encode path so decode tests see authentic chunk layouts.
pub fn createChunkedFrame(
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
