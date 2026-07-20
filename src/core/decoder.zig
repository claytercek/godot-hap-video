//! decoder.zig
//!
//! Decodes a single Hap frame from its compressed bytes into raw texture
//! data. Wraps the Vidvox hap.c decoder (HapDecode, HapGetFrameTextureCount,
//! HapGetFrameTextureFormat) with correct multi-texture handling (fixing the
//! reference Unity plugin's hardcoded index=0 bug: HapM frames carry two
//! textures, and each must be requested/decoded with *its own* index --
//! looping `i` through both HapGetFrameTextureFormat and HapDecode below,
//! rather than hardcoding 0, is that fix).
//!
//! Chunked frames (Complex compressor) are decoded in parallel using the
//! shared InnerThreadPool (thread_pool.zig), which auto-derives its thread
//! count from hardware_concurrency per that module's formula. The
//! HapDecode callback is invoked once per multi-chunk texture and returns
//! only when all chunks are complete. Single-chunk textures bypass the
//! callback entirely (see InnerThreadPool.execute's count <= 1 fast path).
//!
//! The decoder does not copy the caller's input -- it decodes directly from
//! the slice passed in (typically a slice of the mmap region).
//!
//! `decode` returns `error{InvalidFrame,OutOfMemory}!void`:
//! `error.InvalidFrame` means the input is not a valid/supported Hap frame,
//! while `error.OutOfMemory` signals allocation failure -- both leave
//! `output` empty via a single `errdefer`. Re-decoding into an
//! already-populated `DecodedFrame` frees its previous textures first.

const std = @import("std");

const hap_frame = @import("hap_frame.zig");
const thread_pool = @import("thread_pool.zig");

const DecodedFrame = hap_frame.DecodedFrame;
const HapTextureFormat = hap_frame.HapTextureFormat;

/// HapResult -- see thirdparty/hap/hap.h.
pub const HapResult_No_Error: c_uint = 0;
const HapResult_Buffer_Too_Small: c_uint = 2;

/// HapM (dual-texture) frames carry exactly two textures -- e.g.
/// YCoCg_DXT5 + A_RGTC1 for the combined-alpha case documented in
/// thirdparty/hap/hap.h -- so a valid frame never has more than this many.
const max_texture_count: c_uint = 2;

/// Output-buffer growth factor applied both to the initial size guess
/// (from the compressed input size) and to hap.c's reported `bytes_used`
/// on a too-small retry. 1.5x is a safety margin above the worst case
/// (BC-compressed data can be at most the size of the uncompressed input).
const buffer_growth_factor: f64 = 1.5;

/// Floor for the initial output-buffer guess, so tiny frames don't churn
/// through repeated grow-and-retry cycles.
const min_output_buffer_bytes: usize = 1024 * 1024;

pub extern fn HapGetFrameTextureCount(
    input_buffer: ?*const anyopaque,
    input_buffer_bytes: c_ulong,
    output_texture_count: *c_uint,
) c_uint;

extern fn HapGetFrameTextureFormat(
    input_buffer: ?*const anyopaque,
    input_buffer_bytes: c_ulong,
    index: c_uint,
    output_buffer_texture_format: *c_uint,
) c_uint;

extern fn HapDecode(
    input_buffer: ?*const anyopaque,
    input_buffer_bytes: c_ulong,
    index: c_uint,
    callback: ?thread_pool.HapDecodeCallback,
    info: ?*anyopaque,
    output_buffer: ?*anyopaque,
    output_buffer_bytes: c_ulong,
    output_buffer_bytes_used: *c_ulong,
    output_buffer_texture_format: *c_uint,
) c_uint;

/// Frees every texture `output` currently holds and resets it to empty,
/// without touching its outer array's capacity. The sole cleanup primitive
/// `decode()` uses on every path that leaves `output` non-decoded, so
/// "empty on failure" stays enforced from one place.
fn clearOutput(output: *DecodedFrame, allocator: std.mem.Allocator) void {
    for (output.textures.items) |*tex| tex.deinit(allocator);
    output.textures.clearRetainingCapacity();
}

/// Decodes a single Hap frame from its compressed bytes into raw texture
/// data. See module docs for the multi-texture fix and chunked-decode
/// dispatch through the shared InnerThreadPool.
pub const Decoder = struct {
    /// Temporary output buffer for the decoded texture data. Reused across
    /// decode() calls to avoid reallocation.
    temp_buffer: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *Decoder, allocator: std.mem.Allocator) void {
        self.temp_buffer.deinit(allocator);
    }

    /// Decode a single Hap frame.
    ///
    /// `input` is the compressed frame data (e.g. a slice of the mmap
    /// region). `output` receives the decoded textures; any textures it
    /// already holds are freed first. On success, `output` holds the newly
    /// decoded textures. Returns `error.InvalidFrame` if `input` is not a
    /// valid/supported Hap frame; on any error, `output` is left empty
    /// (never partially populated from a mid-loop error).
    pub fn decode(self: *Decoder, allocator: std.mem.Allocator, input: []const u8, output: *DecodedFrame) error{ InvalidFrame, OutOfMemory }!void {
        clearOutput(output, allocator);

        // Also empty `output` on error paths (e.g. allocation failure),
        // not just on `false` returns -- callers shouldn't have to
        // distinguish "rejected frame" from "ran out of memory" to know
        // whether output is trustworthy.
        errdefer clearOutput(output, allocator);

        // Determine number of textures in this frame.
        var texture_count: c_uint = 0;
        var result = HapGetFrameTextureCount(input.ptr, @intCast(input.len), &texture_count);
        if (result != HapResult_No_Error or texture_count == 0 or texture_count > max_texture_count) {
            return error.InvalidFrame;
        }

        try output.textures.resize(allocator, texture_count);
        for (output.textures.items) |*tex| tex.* = .{};

        var i: c_uint = 0;
        while (i < texture_count) : (i += 1) {
            // Peek at the texture format to determine the output buffer
            // size. Multi-texture fix: pass `i`, not a hardcoded 0.
            var texture_format: c_uint = 0;
            result = HapGetFrameTextureFormat(input.ptr, @intCast(input.len), i, &texture_format);
            if (result != HapResult_No_Error) {
                return error.InvalidFrame;
            }

            // Allocate a generous output buffer. We grow it as needed. The
            // maximum size for BC-compressed data is the full input size
            // (uncompressed worst case). For safety, use input_size *
            // buffer_growth_factor.
            var max_size: usize = @intFromFloat(@as(f64, @floatFromInt(input.len)) * buffer_growth_factor);
            if (max_size < min_output_buffer_bytes) max_size = min_output_buffer_bytes;
            if (self.temp_buffer.items.len < max_size) {
                try self.temp_buffer.resize(allocator, max_size);
            }

            // Decode into temp_buffer. If it's too small, hap.c reports the
            // exact bytes needed via bytes_used; grow to 1.5x that and
            // retry once.
            var bytes_used: c_ulong = 0;
            var decoded = false;
            var attempt: u32 = 0;
            while (attempt < 2) : (attempt += 1) {
                result = HapDecode(
                    input.ptr,
                    @intCast(input.len),
                    i,
                    thread_pool.hapInnerDecodeCallback,
                    null,
                    self.temp_buffer.items.ptr,
                    @intCast(self.temp_buffer.items.len),
                    &bytes_used,
                    &texture_format,
                );
                if (result == HapResult_No_Error) {
                    decoded = true;
                    break;
                }
                if (result != HapResult_Buffer_Too_Small) {
                    return error.InvalidFrame;
                }
                const grown: usize = @intFromFloat(@as(f64, @floatFromInt(bytes_used)) * buffer_growth_factor);
                try self.temp_buffer.resize(allocator, grown);
            }
            if (!decoded) {
                return error.InvalidFrame;
            }

            // Copy decoded data into the output.
            const tex = &output.textures.items[@intCast(i)];
            try tex.data.resize(allocator, bytes_used);
            @memcpy(tex.data.items, self.temp_buffer.items[0..bytes_used]);
            tex.format = @enumFromInt(texture_format);
        }
    }
};
