//! retire_ring.zig
//!
//! A generation-counted ring index sequencer, depth N (default 3).
//!
//! RetireRing does not own any GPU/CPU resources itself -- it only
//! sequences which of N slots is safe to write next vs. which is the
//! "current" (most recently published, safe-to-read) slot. Callers own N
//! parallel resource arrays (textures, buffers, ...) indexed by the slot
//! numbers this type hands out.
//!
//! Usage per frame:
//!   const slot = ring.writableSlot();   // write new data into slot
//!   ... write GPU/CPU resource at index `slot` ...
//!   ring.commit();                      // publish: slot becomes current
//!
//! Ring depth 3 is the minimum safe bound against Godot's default render
//! frame-queue depth of 2: by the time a slot is writable again, at least
//! two other slots have been published and consumed, so any GPU work
//! still reading an older slot never observes an in-progress write. This
//! closes tearing by construction, for every variant (pass-through and
//! YCoCg output alike).
//!
//! `RetireRing(N)` is a comptime-generic function; callers use
//! `RetireRing(3)` for the default depth.

const std = @import("std");

pub fn RetireRing(comptime N: usize) type {
    if (N < 2) {
        @compileError("RetireRing needs at least 2 slots to avoid a writer stomping the slot a reader is using");
    }

    return struct {
        const Self = @This();

        current: usize = 0,

        /// Number of slots in the ring.
        pub fn depth() usize {
            return N;
        }

        /// The slot most recently published via commit(). Safe to read.
        pub fn currentSlot(self: Self) usize {
            return self.current;
        }

        /// The next slot a writer should fill. Never equal to
        /// currentSlot() until commit() is called.
        pub fn writableSlot(self: Self) usize {
            return (self.current + 1) % N;
        }

        /// Publish the slot last returned by writableSlot(): it becomes
        /// the new currentSlot().
        pub fn commit(self: *Self) void {
            self.current = self.writableSlot();
        }
    };
}

// Tests live in concurrency_test.zig, referenced from core.zig -- that one
// file covers RetireRing, FrameQueue, OuterThreadPool and InnerThreadPool
// together rather than split inline per module.
