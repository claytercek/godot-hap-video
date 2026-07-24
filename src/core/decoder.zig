//! decoder.zig
//!
//! Decodes a single Hap frame from its compressed bytes into raw texture
//! data. Delegates parsing and per-texture decompression to hap_decode.zig
//! (a clean-room Zig implementation of the Hap bitstream), with correct
//! multi-texture handling (fixing the reference Unity plugin's hardcoded
//! index=0 bug: HapM frames carry two textures, and each must be decoded
//! with *its own* index -- looping `i` through decodeTexture below, rather
//! than hardcoding 0, is that fix).
//!
//! Chunked frames (Complex compressor) are decoded in parallel by
//! hap_decode via the shared InnerThreadPool (thread_pool.zig), which
//! auto-derives its thread count from hardware_concurrency per that
//! module's formula. Single-chunk and non-chunked textures decode inline
//! on the calling thread.
//!
//! The decoder does not copy the caller's input -- it decodes directly from
//! the slice passed in (typically a slice of the mmap region). Each
//! texture's output buffer is sized to the exact decoded length up front,
//! computed by hap_decode during parse.
//!
//! `decode` returns `error{InvalidFrame,OutOfMemory}!void`:
//! `error.InvalidFrame` means the input is not a valid/supported Hap frame,
//! while `error.OutOfMemory` signals allocation failure -- both leave
//! `output` empty via a single `errdefer`. Re-decoding into an
//! already-populated `DecodedFrame` frees its previous textures first.

const std = @import("std");

const hap_frame = @import("hap_frame.zig");
const hap_decode = @import("hap_decode.zig");

const DecodedFrame = hap_frame.DecodedFrame;

/// HapM (dual-texture) frames carry exactly two textures -- e.g.
/// YCoCg_DXT5 + A_RGTC1 for the combined-alpha case -- so a valid frame
/// never has more than this many.
const max_texture_count: u32 = 2;

/// Frees every texture `output` currently holds and resets it to empty,
/// without touching its outer array's capacity. The sole cleanup primitive
/// `decode()` uses on every path that leaves `output` non-decoded, so
/// "empty on failure" stays enforced from one place.
fn clearOutput(output: *DecodedFrame, allocator: std.mem.Allocator) void {
    for (output.textures.items) |*tex| tex.deinit(allocator);
    output.textures.clearRetainingCapacity();
}

/// Decode a single Hap frame. See module docs for the multi-texture fix and
/// chunked-decode dispatch through the shared InnerThreadPool.
///
/// `input` is the compressed frame data (e.g. a slice of the mmap
/// region). `output` receives the decoded textures; any textures it
/// already holds are freed first. On success, `output` holds the newly
/// decoded textures. Returns `error.InvalidFrame` if `input` is not a
/// valid/supported Hap frame; on any error, `output` is left empty
/// (never partially populated from a mid-loop error).
pub fn decode(allocator: std.mem.Allocator, input: []const u8, output: *DecodedFrame) error{ InvalidFrame, OutOfMemory }!void {
    clearOutput(output, allocator);

    // Also empty `output` on error paths (e.g. allocation failure),
    // not just on rejected frames -- callers shouldn't have to
    // distinguish "rejected frame" from "ran out of memory" to know
    // whether output is trustworthy.
    errdefer clearOutput(output, allocator);

    const texture_count = try hap_decode.frameTextureCount(input);
    if (texture_count == 0 or texture_count > max_texture_count) {
        return error.InvalidFrame;
    }

    try output.textures.resize(allocator, texture_count);
    for (output.textures.items) |*tex| tex.* = .{};

    var i: u32 = 0;
    while (i < texture_count) : (i += 1) {
        // Multi-texture fix: decode texture `i`, not a hardcoded 0.
        // decodeTexture sizes tex.data to the exact decoded length and
        // returns the parsed texture format.
        const tex = &output.textures.items[i];
        tex.format = try hap_decode.decodeTexture(allocator, input, i, &tex.data);
    }
}
