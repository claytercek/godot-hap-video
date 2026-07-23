//! thread_pool.zig
//!
//! The "inner" thread pool implementing hap.c's callback-based parallel
//! chunk-decode contract (`HapDecodeCallback` / `HapDecodeWorkFunction`, see
//! thirdparty/hap/hap.h): `HapDecode` invokes the callback once per
//! multi-chunk ("Complex" compressor) texture, handing it a work function to
//! call once per chunk index; the callback must dispatch all `count` calls
//! and return only once they are all complete.
//!
//! Sizing: max(1, hardware_concurrency - kOuterWorkers), clamped to a
//! minimum of 1. `kOuterWorkers` is imported from outer_thread_pool.zig's
//! `kDefaultWorkers`, which owns that constant.
//!
//! Singleton: shared by all streams. The outer pool runs up to
//! kOuterWorkers streams concurrently, so multiple streams' chunked frames
//! can call execute() at the same time; execute() itself serializes those
//! calls (dispatch_mutex) so the shared work-batch state is never touched by
//! two callers at once. This trades chunk-level parallelism across
//! simultaneously-chunk-decoding streams for correctness -- the thread count
//! stays bounded either way.
//!
//! Mutex/Condition: shared with outer_thread_pool.zig via sync.zig (see
//! that module's docs for the full Zig-0.16 rationale for wrapping native
//! OS primitives instead of the removed std.Thread.Mutex/Condition).

const std = @import("std");

const outer_thread_pool = @import("outer_thread_pool.zig");
const pool_lifecycle = @import("pool_lifecycle.zig");
const sync = @import("sync.zig");

const Mutex = sync.Mutex;
const Condition = sync.Condition;

/// HapDecodeWorkFunction / HapDecodeCallback -- see thirdparty/hap/hap.h.
/// Hand-declared (no @cImport, per project convention) with an explicit
/// `.c` calling convention so they pass directly to `HapDecode`.
pub const HapDecodeWorkFunction = *const fn (p: ?*anyopaque, index: c_uint) callconv(.c) void;
pub const HapDecodeCallback = *const fn (
    function: HapDecodeWorkFunction,
    p: ?*anyopaque,
    count: c_uint,
    info: ?*anyopaque,
) callconv(.c) void;

/// Matches OuterThreadPool.kDefaultWorkers (see outer_thread_pool.zig,
/// which owns this constant).
const kOuterWorkers: u32 = outer_thread_pool.kDefaultWorkers;

/// Per-worker partition: start index (inclusive) and end index (exclusive).
const Partition = struct {
    start: u32,
    end: u32,
};

/// A thread pool for parallel chunk decode within a single frame.
///
/// See the module docs for the HapDecodeCallback contract and sizing rules.
pub const InnerThreadPool = struct {
    allocator: std.mem.Allocator,

    /// Worker threads (fixed-size, sized at create() time).
    workers: []std.Thread,

    /// Number of worker threads (pool size, excluding the calling thread).
    num_workers: u32,

    /// Serializes execute() calls across concurrent outer-pool workers.
    /// Held for the full duration of one batch's dispatch-and-wait.
    dispatch_mutex: Mutex = .{},

    /// Synchronization.
    mutex: Mutex = .{},
    cv_start: Condition = .{},
    cv_done: Condition = .{},

    /// Shared work state, set by execute() before waking workers. Guarded
    /// by `mutex`.
    func: ?HapDecodeWorkFunction = null,
    p: ?*anyopaque = null,
    remaining: u32 = 0,

    /// Monotonically increasing batch counter. Workers track their last
    /// seen batch and only proceed when the counter changes, preventing
    /// re-entry within the same batch. Guarded by `mutex` -- every read and
    /// write happens with `mutex` held, so this is plain state, not atomic.
    work_batch: u32 = 0,

    /// Per-worker partition: index `num_workers` (the last slot) is the
    /// calling thread's own share.
    partitions: []Partition,

    /// Pool lifecycle flag. Guarded by `mutex`.
    running: bool = true,

    /// Create a pool with the given number of worker threads (clamped to a
    /// minimum of 1). Returns a heap-allocated pool (held by pointer): the
    /// worker threads capture the pool's address, so it must live at a
    /// stable location -- callers must call `destroy` exactly once, after
    /// which the pointer is invalid.
    pub fn create(allocator: std.mem.Allocator, requested_workers: u32) !*InnerThreadPool {
        const n = @max(@as(u32, 1), requested_workers);

        const self = try allocator.create(InnerThreadPool);
        errdefer allocator.destroy(self);

        const partitions = try allocator.alloc(Partition, n + 1); // +1 for the calling thread
        errdefer allocator.free(partitions);

        const workers = try allocator.alloc(std.Thread, n);
        errdefer allocator.free(workers);

        self.* = .{
            .allocator = allocator,
            .workers = workers,
            .num_workers = n,
            .partitions = partitions,
        };

        // Worker-spawn failure is unrecoverable -- the pool's purpose is
        // these threads -- so panic rather than degrade.
        for (0..n) |i| {
            workers[i] = std.Thread.spawn(.{}, workerLoop, .{ self, @as(u32, @intCast(i)) }) catch
                @panic("InnerThreadPool: failed to spawn worker thread");
        }

        return self;
    }

    /// Stop and join all worker threads, then free the pool. Invalidates
    /// the pointer returned by `create`.
    pub fn destroy(self: *InnerThreadPool) void {
        pool_lifecycle.stopAndJoinWorkers(&self.mutex, &self.running, &self.cv_start, self.workers);

        self.cv_done.deinit();
        self.cv_start.deinit();
        self.mutex.deinit();
        self.dispatch_mutex.deinit();

        const allocator = self.allocator;
        allocator.free(self.workers);
        allocator.free(self.partitions);
        allocator.destroy(self);
    }

    /// Number of worker threads in the pool (excluding the calling thread).
    pub fn workerCount(self: *const InnerThreadPool) u32 {
        return self.num_workers;
    }

    /// Execute `count` work items across the thread pool. Blocks until all
    /// items complete. Safe to call concurrently from multiple outer-pool
    /// workers -- calls are internally serialized.
    pub fn execute(self: *InnerThreadPool, func: HapDecodeWorkFunction, p: ?*anyopaque, count: u32) void {
        if (count <= 1) {
            func(p, 0);
            return;
        }

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const total_workers = self.num_workers + 1; // calling thread + pool

        const base = count / total_workers;
        const remainder = count % total_workers;
        var pos: u32 = 0;
        for (0..total_workers) |i| {
            const extra: u32 = if (i < remainder) 1 else 0;
            const size = base + extra;
            self.partitions[i] = .{ .start = pos, .end = pos + size };
            pos += size;
        }

        {
            self.mutex.lock();
            self.func = func;
            self.p = p;
            self.remaining = self.num_workers;
            self.work_batch += 1;
            self.mutex.unlock();
        }
        self.cv_start.notifyAll();

        const my_part = self.partitions[self.num_workers];
        var i = my_part.start;
        while (i < my_part.end) : (i += 1) {
            func(p, i);
        }

        {
            self.mutex.lock();
            while (self.remaining != 0) self.cv_done.wait(&self.mutex);
            self.func = null;
            self.p = null;
            self.mutex.unlock();
        }
    }

    /// Worker thread entry point.
    fn workerLoop(self: *InnerThreadPool, worker_id: u32) void {
        var my_batch: u32 = 0; // last batch this worker processed

        while (true) {
            self.mutex.lock();
            while (self.running and self.work_batch == my_batch) {
                self.cv_start.wait(&self.mutex);
            }
            if (!self.running) {
                self.mutex.unlock();
                return;
            }

            my_batch = self.work_batch;

            const part = self.partitions[worker_id];
            const func = self.func.?;
            const p = self.p;

            self.mutex.unlock();

            var i = part.start;
            while (i < part.end) : (i += 1) {
                func(p, i);
            }

            self.mutex.lock();
            self.remaining -= 1;
            self.mutex.unlock();
            self.cv_done.notifyOne();
        }
    }
};

/// Sizing formula for the shared singleton -- see the module docs.
fn singletonWorkerCount() u32 {
    const hw: u32 = @intCast(std.Thread.getCpuCount() catch 1);
    var num_workers: u32 = if (hw <= kOuterWorkers) 1 else hw - kOuterWorkers;
    if (num_workers < 1) num_workers = 1;
    return num_workers;
}

const Singleton = pool_lifecycle.LazySingleton(InnerThreadPool, singletonWorkerCount, "InnerThreadPool: singleton init failed");

/// Access the shared instance. Created on first access, sized from the
/// hardware per the module docs' formula (see LazySingleton in
/// pool_lifecycle.zig for the lazy-init/never-torn-down mechanics).
pub fn instance() *InnerThreadPool {
    return Singleton.get();
}

/// HapDecodeCallback-compatible function that uses the shared
/// InnerThreadPool singleton. Pass this as the callback argument to
/// HapDecode. The `info` argument is unused. The callback is invoked only
/// for multi-chunk textures (Complex compressor) and returns only when all
/// chunks are decoded.
pub fn hapInnerDecodeCallback(
    function: HapDecodeWorkFunction,
    p: ?*anyopaque,
    count: c_uint,
    info: ?*anyopaque,
) callconv(.c) void {
    _ = info;
    instance().execute(function, p, count);
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "InnerThreadPool.create/destroy round-trips cleanly" {
    const pool = try InnerThreadPool.create(testing.allocator, 2);
    try testing.expectEqual(@as(u32, 2), pool.workerCount());
    pool.destroy();
}

test "InnerThreadPool.create clamps a zero worker count to 1" {
    const pool = try InnerThreadPool.create(testing.allocator, 0);
    try testing.expectEqual(@as(u32, 1), pool.workerCount());
    pool.destroy();
}

test "InnerThreadPool.execute calls the work function directly for count <= 1" {
    const pool = try InnerThreadPool.create(testing.allocator, 2);
    defer pool.destroy();

    var seen: u32 = 0;

    const Ctx = struct {
        fn work(p: ?*anyopaque, index: c_uint) callconv(.c) void {
            const counter: *u32 = @ptrCast(@alignCast(p.?));
            counter.* += 1;
            try_expect_zero_index(index);
        }
        fn try_expect_zero_index(index: c_uint) void {
            std.debug.assert(index == 0);
        }
    };

    pool.execute(Ctx.work, &seen, 1);
    try testing.expectEqual(@as(u32, 1), seen);

    pool.execute(Ctx.work, &seen, 0);
    try testing.expectEqual(@as(u32, 2), seen);
}

test "InnerThreadPool.execute dispatches every index exactly once across workers" {
    const pool = try InnerThreadPool.create(testing.allocator, 3);
    defer pool.destroy();

    const count: u32 = 37;
    var seen = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** count;

    const Ctx = struct {
        fn work(p: ?*anyopaque, index: c_uint) callconv(.c) void {
            const arr: [*]std.atomic.Value(u32) = @ptrCast(@alignCast(p.?));
            _ = arr[index].fetchAdd(1, .monotonic);
        }
    };

    pool.execute(Ctx.work, &seen, count);

    for (&seen) |*v| {
        try testing.expectEqual(@as(u32, 1), v.load(.monotonic));
    }
}

test "InnerThreadPool.execute can be called repeatedly (batch counter advances)" {
    const pool = try InnerThreadPool.create(testing.allocator, 2);
    defer pool.destroy();

    const count: u32 = 10;
    var totals = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** count;

    const Ctx = struct {
        fn work(p: ?*anyopaque, index: c_uint) callconv(.c) void {
            const arr: [*]std.atomic.Value(u32) = @ptrCast(@alignCast(p.?));
            _ = arr[index].fetchAdd(1, .monotonic);
        }
    };

    var round: u32 = 0;
    while (round < 5) : (round += 1) {
        pool.execute(Ctx.work, &totals, count);
    }

    for (&totals) |*v| {
        try testing.expectEqual(@as(u32, 5), v.load(.monotonic));
    }
}

test "InnerThreadPool singleton instance() is reachable and sized at least 1" {
    const pool = instance();
    try testing.expect(pool.workerCount() >= 1);
}

test "hapInnerDecodeCallback drives the singleton pool for a multi-chunk batch" {
    const count: u32 = 8;
    var seen = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** count;

    const Ctx = struct {
        fn work(p: ?*anyopaque, index: c_uint) callconv(.c) void {
            const arr: [*]std.atomic.Value(u32) = @ptrCast(@alignCast(p.?));
            _ = arr[index].fetchAdd(1, .monotonic);
        }
    };

    hapInnerDecodeCallback(Ctx.work, &seen, count, null);

    for (&seen) |*v| {
        try testing.expectEqual(@as(u32, 1), v.load(.monotonic));
    }
}
