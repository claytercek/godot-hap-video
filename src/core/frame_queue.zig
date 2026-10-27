//! Bounded SPSC decoded-frame queue: one outer-pool decode worker produces
//! frames; the render thread consumes them. `init()` takes an explicit
//! depth; `default_depth` is 4.
//!
//! Each slot owns a reusable DecodedFrame. A ReadLease holds the queue lock
//! during synchronous reads/uploads, preventing seek drains from recycling
//! a frame in use. The queue retains slot contents; buffer reuse depends
//! on how the producer decodes into each slot.
//!
//! A mutex from sync.zig guards queue operations; decoding takes far longer
//! than locking. Callers must still honor the SPSC contract. Consumers poll
//! acquireRead()/empty(), so no condition variable is needed. Synchronized
//! entry points take a mutable *FrameQueue.

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

    /// Producer: get the frame to decode into. Return null when full; back
    /// off at this seek/prefetch queue-behind boundary. Slot buffers retain
    /// capacity for decoders that resize them instead of reassigning.
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

    /// Consumer: discard prefetched frames for seek/scrub. Wait for any
    /// ReadLease before recycling its frame. Leave any frame currently being
    /// written through beginWrite() untouched.
    pub fn drain(self: *FrameQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.read_pos = self.write_pos;
        self.count = 0;
    }
};

// concurrency_test.zig covers this queue; core.zig imports the tests.
