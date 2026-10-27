//! Decode one Hap frame into raw texture data using the clean-room parser
//! in hap_decode.zig. HapM carries two textures; each uses its own index,
//! unlike the reference Unity plugin's hardcoded index 0.
//!
//! Multi-chunk Complex textures use the shared InnerThreadPool; see
//! thread_pool.zig for hardware-based sizing. Single-chunk and non-chunked
//! textures decode on the calling thread.
//!
//! Input is read directly from the caller's slice, usually an mmap region.
//! Parsing determines each output buffer's exact decoded length.
//! `decode` frees any previous output textures before decoding and returns
//! `error{InvalidFrame,OutOfMemory}!void`. Invalid or unsupported frames and
//! allocation failures both leave `output` empty through one `errdefer`.

const std = @import("std");

const hap_frame = @import("hap_frame.zig");
const hap_decode = @import("hap_decode.zig");

const DecodedFrame = hap_frame.DecodedFrame;

/// HapM (dual-texture) frames carry exactly two textures -- e.g.
/// YCoCg_DXT5 + A_RGTC1 for the combined-alpha case -- so a valid frame
/// never has more than this many.
const max_texture_count: u32 = 2;

/// Free all output textures and empty the outer array while retaining its
/// capacity. All decode cleanup paths use this to keep output empty on error.
fn clearOutput(output: *DecodedFrame, allocator: std.mem.Allocator) void {
    for (output.textures.items) |*tex| tex.deinit(allocator);
    output.textures.clearRetainingCapacity();
}

/// Decode compressed `input` into `output`, freeing any previous textures
/// first. Return `error.InvalidFrame` for invalid or unsupported input.
/// Every error, including allocation failure, leaves `output` empty.
pub fn decode(allocator: std.mem.Allocator, input: []const u8, output: *DecodedFrame) error{ InvalidFrame, OutOfMemory }!void {
    clearOutput(output, allocator);

    // Empty output on every error, including allocation and mid-loop failures.
    errdefer clearOutput(output, allocator);

    const texture_count = try hap_decode.frameTextureCount(input);
    if (texture_count == 0 or texture_count > max_texture_count) {
        return error.InvalidFrame;
    }

    try output.textures.resize(allocator, texture_count);
    for (output.textures.items) |*tex| tex.* = .{};

    var i: u32 = 0;
    while (i < texture_count) : (i += 1) {
        // Use each texture's own index. decodeTexture sizes its buffer
        // exactly and returns the parsed format.
        const tex = &output.textures.items[i];
        tex.format = try hap_decode.decodeTexture(allocator, input, i, &tex.data);
    }
}
