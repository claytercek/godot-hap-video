//! Cycle through N resource slots, tracking the current and next writable
//! indices. Callers own the GPU/CPU resource arrays; this type owns no
//! resources and does not track GPU completion.
//!
//! Usage per frame:
//!   const slot = ring.writableSlot();   // write new data into slot
//!   ... write GPU/CPU resource at index `slot` ...
//!   ring.commit();                      // publish: slot becomes current
//!
//! `RetireRing(N)` is comptime-generic. Callers use RetireRing(3) to place
//! two intervening commits between writes to a slot. Callers must ensure
//! prior readers have finished before reusing it.

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

        /// The slot most recently published via commit().
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

// concurrency_test.zig covers the ring, queue, and pools; core.zig imports it.
