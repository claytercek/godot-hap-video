//! frame_queue.zig
//!
//! A bounded single-producer/single-consumer queue of decoded frames.
//!
//! One decode worker (the outer-pool worker currently owning a stream)
//! pushes; the render thread pops. Depth defaults to 4 (`default_depth`),
//! per spec.
//!
//! Each slot owns a reusable DecodedFrame. A consumer acquires a ReadLease
//! while it reads or uploads a frame; the lease holds the queue lock so a
//! concurrent seek drain cannot recycle that slot until the consumer has
//! finished. DecodedTexture.data buffers are only reallocated when the
//! producer writes a frame whose size differs from what a slot's buffer already
//! holds (dimension/variant change) -- ArrayListUnmanaged.resize() is a
//! no-op on capacity when shrinking or matching, so steady-state playback
//! never reallocates.
//!
//! Internally guarded by a mutex rather than lock-free atomics: decode
//! times (microseconds-to-milliseconds) dwarf lock overhead, and the SPSC
//! *usage* contract (one producer thread, one consumer thread) is what
//! callers must honor -- the mutex only makes violations safe rather than
//! undefined. The consumer polls (acquireRead/empty) rather than blocking, so
//! there is no condition variable to wait on.
//!
//! `init()` takes `depth` explicitly and `default_depth` is exposed for
//! callers that want the spec default. Every entry point synchronizes, so all
//! take a non-const `*FrameQueue`. `Mutex` is imported from sync.zig (see that
//! module's docs for the Zig-0.16 Mutex/Condition wrapper rationale)
//! rather than duplicated here.

const std = @import("std");

const hap_frame = @import("hap_frame.zig");
const sync = @import("sync.zig");

const DecodedFrame = hap_frame.DecodedFrame;
const Mutex = sync.Mutex;

pub const FrameQueue = struct {
    allocator: std.mem.Allocator,
    mutex: Mutex = .{},
    slots: []Slot,
    write_pos: usize = 0,
    read_pos: usize = 0,
    count: usize = 0,

    /// Spec default queue depth.
    pub const default_depth: usize = 4;

    const Slot = struct {
        frame: DecodedFrame = .{},
        frame_index: u32 = 0,
    };

    /// Exclusive, short-lived access to the oldest committed frame. The
    /// queue remains locked until release() or consume(), so leases must not
    /// be copied or retained beyond the synchronous read/upload operation.
    pub const ReadLease = struct {
        queue: *FrameQueue,
        frame: *const DecodedFrame,
        frame_index: u32,
        active: bool = true,

        /// Keep the frame queued and relinquish read access.
        pub fn release(self: *ReadLease) void {
            std.debug.assert(self.active);
            self.active = false;
            self.queue.mutex.unlock();
        }

        /// Remove the leased frame from the queue and relinquish read access.
        pub fn consume(self: *ReadLease) void {
            std.debug.assert(self.active);
            std.debug.assert(self.queue.count > 0);
            self.queue.read_pos = (self.queue.read_pos + 1) % self.queue.slots.len;
            self.queue.count -= 1;
            self.active = false;
            self.queue.mutex.unlock();
        }
    };

    /// Allocate a queue with `depth` slots (each initially an empty
    /// DecodedFrame).
    pub fn init(allocator: std.mem.Allocator, depth: usize) !FrameQueue {
        const slots = try allocator.alloc(Slot, depth);
        for (slots) |*s| s.* = .{};
        return .{ .allocator = allocator, .slots = slots };
    }

    /// Free every slot's DecodedFrame contents and the slot array itself.
    pub fn deinit(self: *FrameQueue) void {
        // Wait for any active consumer lease before freeing its slot. The
        // scheduler separately guarantees its producer has stopped first.
        self.mutex.lock();
        for (self.slots) |*s| s.frame.deinit(self.allocator);
        self.allocator.free(self.slots);
        self.mutex.unlock();
        self.mutex.deinit();
        self.* = undefined;
    }

    pub fn capacity(self: *const FrameQueue) usize {
        return self.slots.len;
    }

    /// Producer: true if there is room to beginWrite() without blocking.
    pub fn full(self: *FrameQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count == self.slots.len;
    }

    /// Consumer: true if there is nothing to pop.
    pub fn empty(self: *FrameQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count == 0;
    }

    /// Producer: get a pointer to the DecodedFrame the caller should
    /// decode into. Returns null if the queue is full (caller should back
    /// off; this is the seek/prefetch "queue-behind" boundary, not an
    /// error). The returned frame's buffers retain their prior capacity --
    /// decode() implementations that resize() rather than reassign reuse
    /// it.
    pub fn beginWrite(self: *FrameQueue, frame_index: u32) ?*DecodedFrame {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count == self.slots.len) return null;
        const slot = &self.slots[self.write_pos];
        slot.frame_index = frame_index;
        return &slot.frame;
    }

    /// Producer: publish the frame written via the last beginWrite() call.
    pub fn commitWrite(self: *FrameQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.write_pos = (self.write_pos + 1) % self.slots.len;
        self.count += 1;
    }

    /// Consumer: lease the oldest committed frame without removing it.
    /// Returns null if empty. The caller must call release() or consume()
    /// before making any other queue call.
    pub fn acquireRead(self: *FrameQueue) ?ReadLease {
        self.mutex.lock();
        if (self.count == 0) {
            self.mutex.unlock();
            return null;
        }
        const slot = &self.slots[self.read_pos];
        return .{ .queue = self, .frame = &slot.frame, .frame_index = slot.frame_index };
    }

    /// Consumer: drop all queued frames (used by seek/scrub to discard
    /// stale prefetched frames before refilling from the new position).
    /// Blocks behind any active ReadLease, so a leased frame is never
    /// recycled while the consumer is still reading it. Does not touch a
    /// frame the producer may currently be writing via beginWrite().
    pub fn drain(self: *FrameQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.read_pos = self.write_pos;
        self.count = 0;
    }
};

// Tests live in concurrency_test.zig, referenced from core.zig -- see
// retire_ring.zig's module docs for why this whole family of tests lives
// in one dedicated file.
