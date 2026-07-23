//! Root of the pure-Zig engine core.
//! No Godot dependency; only the vendored C libraries (hap, snappy,
//! minimp4) compiled alongside this module (see build.zig).

const std = @import("std");

pub const hap_frame = @import("hap_frame.zig");
pub const mmap_reader = @import("mmap_reader.zig");
pub const demuxer = @import("demuxer.zig");
pub const thread_pool = @import("thread_pool.zig");
pub const decoder = @import("decoder.zig");
pub const outer_thread_pool = @import("outer_thread_pool.zig");
pub const pool_lifecycle = @import("pool_lifecycle.zig");
pub const frame_queue = @import("frame_queue.zig");
pub const retire_ring = @import("retire_ring.zig");
pub const decode_scheduler = @import("decode_scheduler.zig");
pub const playback_controller = @import("playback_controller.zig");

test {
    _ = hap_frame;
    _ = mmap_reader;
    _ = demuxer;
    _ = @import("demuxer_test.zig");
    _ = thread_pool;
    _ = decoder;
    _ = @import("decoder_test.zig");
    _ = outer_thread_pool;
    _ = pool_lifecycle;
    _ = frame_queue;
    _ = retire_ring;
    _ = @import("concurrency_test.zig");
    _ = decode_scheduler;
    _ = playback_controller;
    _ = @import("playback_controller_test.zig");
    _ = @import("decode_scheduler_test.zig");
    _ = @import("fuzz_regressions_test.zig");
    _ = @import("demuxer_fuzz.zig");
}
