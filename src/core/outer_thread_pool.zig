//! Shared, bounded worker pool. `submit()` accepts one-shot jobs without a
//! stream lifetime. `submitForStream()` runs open/decode jobs serially in
//! submission order for each stream key. This ties teardown accounting to
//! the same key and preserves FrameQueue's SPSC contract. Different streams
//! may run concurrently.
//!
//! The process-wide singleton defaults to `kDefaultWorkers` (3), shared by
//! all streams. thread_pool.zig imports this constant to size InnerThreadPool.
//!
//! Submission heap-allocates a closure with an intrusive Job node, captures
//! args by value, and frees the closure after running. Call sites capture
//! stable pointers (e.g. *DecodeScheduler) and small values, as with
//! std.Thread.Pool.spawn.
//!
//! Mutex/Condition come from sync.zig; see its Zig 0.16 compatibility notes.

const std = @import("std");

const pool_lifecycle = @import("pool_lifecycle.zig");
const sync = @import("sync.zig");

const Mutex = sync.Mutex;
const Condition = sync.Condition;

/// Default worker count, shared process-wide. InnerThreadPool derives its
/// own size as max(1, hardware_concurrency - kDefaultWorkers), so both
/// pools stay consistent from this single definition (see thread_pool.zig).
pub const kDefaultWorkers: u32 = 3;

/// First field of each heap-allocated job closure. runFn invokes the user's
/// function with captured arguments, then frees the closure.
pub const Job = struct {
    node: std.DoublyLinkedList.Node = .{},
    runFn: *const fn (*Job) void,
};

/// Per-stream job queue and "is something running for this stream"
/// latch. Guarded by OuterThreadPool.mutex. An entry exists only while
/// its stream has queued or running work; it is removed once drained.
const StreamState = struct {
    pending: std.DoublyLinkedList = .{},
    active: bool = false,
};

/// A shared, bounded worker pool. See module docs for the two job kinds
/// and the per-stream serialization invariant.
pub const OuterThreadPool = struct {
    allocator: std.mem.Allocator,

    mutex: Mutex = .{},
    cv: Condition = .{},

    /// Jobs ready to run (or currently running, accounted via `in_flight`).
    ready: std.DoublyLinkedList = .{},

    streams: std.AutoHashMapUnmanaged(u64, StreamState) = .empty,

    workers: []std.Thread,
    num_workers: u32 = 0,
    running: bool = true,

    /// Bookkeeping so waitIdle() can tell when nothing is in flight.
    /// Incremented exactly when a job enters `ready` (whether from
    /// `submit` or from a stream advancing to its next pending job),
    /// decremented once that job's runFn returns.
    in_flight: u32 = 0,

    /// Create at least one worker and return a heap-allocated pool. Workers
    /// capture its address, so it must remain stable. Call `destroy` exactly
    /// once; the pointer is invalid afterward.
    pub fn create(allocator: std.mem.Allocator, requested_workers: u32) !*OuterThreadPool {
        const n = @max(@as(u32, 1), requested_workers);

        const self = try allocator.create(OuterThreadPool);
        errdefer allocator.destroy(self);

        const workers = try allocator.alloc(std.Thread, n);
        errdefer allocator.free(workers);

        self.* = .{
            .allocator = allocator,
            .workers = workers,
            .num_workers = n,
        };

        // Worker-spawn failure is unrecoverable -- the pool's purpose is
        // these threads -- so panic rather than degrade.
        for (0..n) |i| {
            workers[i] = std.Thread.spawn(.{}, workerLoop, .{self}) catch
                @panic("OuterThreadPool: failed to spawn worker thread");
        }

        return self;
    }

    /// Stop and join all worker threads, then free the pool. Invalidates
    /// the pointer returned by `create`. Test-only in practice: the
    /// shared singleton (`instance()`) is intentionally never torn down for
    /// the process lifetime.
    pub fn destroy(self: *OuterThreadPool) void {
        pool_lifecycle.stopAndJoinWorkers(&self.mutex, &self.running, &self.cv, self.workers);

        self.cv.deinit();
        self.mutex.deinit();

        const allocator = self.allocator;
        self.streams.deinit(allocator);
        allocator.free(self.workers);
        allocator.destroy(self);
    }

    /// Number of worker threads in the pool.
    pub fn workerCount(self: *const OuterThreadPool) u32 {
        return self.num_workers;
    }

    fn enqueueReadyLocked(self: *OuterThreadPool, job: *Job) void {
        self.ready.append(&job.node);
        self.in_flight += 1;
        self.cv.notifyOne();
    }

    /// Internal: allocate a closure wrapping `func(args)`, optionally
    /// bound to `stream_id` for per-stream serialization.
    fn submitClosure(self: *OuterThreadPool, comptime func: anytype, args: anytype, stream_id: ?u64) void {
        const Args = @TypeOf(args);
        const Closure = struct {
            job: Job = .{ .runFn = run },
            pool: *OuterThreadPool,
            stream_id: ?u64,
            arguments: Args,

            fn run(job: *Job) void {
                const closure: *@This() = @fieldParentPtr("job", job);
                const pool = closure.pool;
                const sid = closure.stream_id;
                @call(.auto, func, closure.arguments);
                pool.allocator.destroy(closure);
                if (sid) |id| pool.onStreamJobDone(id);
            }
        };

        const closure = self.allocator.create(Closure) catch
            @panic("OuterThreadPool: out of memory submitting job");
        closure.* = .{ .pool = self, .stream_id = stream_id, .arguments = args };

        self.mutex.lock();
        defer self.mutex.unlock();

        if (stream_id) |id| {
            const gop = self.streams.getOrPut(self.allocator, id) catch
                @panic("OuterThreadPool: out of memory registering stream");
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const st = gop.value_ptr;
            st.pending.append(&closure.job.node);
            if (!st.active) {
                st.active = true;
                const node = st.pending.popFirst().?;
                const j: *Job = @fieldParentPtr("node", node);
                self.enqueueReadyLocked(j);
            }
        } else {
            self.enqueueReadyLocked(&closure.job);
        }
    }

    /// Submit a job with no stream affinity. May run concurrently with
    /// anything else, subject to worker availability.
    pub fn submit(self: *OuterThreadPool, comptime func: anytype, args: anytype) void {
        self.submitClosure(func, args, null);
    }

    /// Submit a job bound to `stream_id`. Jobs sharing a stream_id run
    /// strictly one at a time, in submission order. Different stream_ids
    /// may run concurrently across the pool's workers.
    pub fn submitForStream(self: *OuterThreadPool, stream_id: u64, comptime func: anytype, args: anytype) void {
        self.submitClosure(func, args, stream_id);
    }

    /// Called (without holding mutex) after a stream-bound job finishes;
    /// activates the next queued job for that stream, if any.
    fn onStreamJobDone(self: *OuterThreadPool, stream_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const st = self.streams.getPtr(stream_id) orelse return;
        if (st.pending.popFirst()) |node| {
            const j: *Job = @fieldParentPtr("node", node);
            self.enqueueReadyLocked(j);
        } else {
            // Drained: drop the map entry, or a long-lived pool accumulates
            // one entry per stream id ever used (ids are never reused).
            _ = self.streams.remove(stream_id);
            self.cv.notifyAll();
        }
    }

    fn workerLoop(self: *OuterThreadPool) void {
        while (true) {
            self.mutex.lock();
            while (self.running and self.ready.first == null) {
                self.cv.wait(&self.mutex);
            }
            if (!self.running and self.ready.first == null) {
                self.mutex.unlock();
                return;
            }

            const node = self.ready.popFirst().?;
            self.mutex.unlock();

            const job: *Job = @fieldParentPtr("node", node);
            job.runFn(job);

            self.mutex.lock();
            self.in_flight -= 1;
            if (self.in_flight == 0) self.cv.notifyAll();
            self.mutex.unlock();
        }
    }

    /// Block until the pool has no ready or pending work left. Test-only
    /// convenience; production code should not need to wait on the pool.
    pub fn waitIdle(self: *OuterThreadPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!(self.in_flight == 0 and self.ready.first == null)) {
            self.cv.wait(&self.mutex);
        }
    }

    /// Wait until `stream_id` has no queued or running jobs. Call before
    /// destroying anything those jobs may access: jobs capture owner
    /// pointers and cannot be cancelled after submission.
    pub fn waitForStreamIdle(self: *OuterThreadPool, stream_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            const st = self.streams.getPtr(stream_id) orelse return;
            if (!st.active and st.pending.first == null) return;
            self.cv.wait(&self.mutex);
        }
    }
};

/// Sizing formula for the shared singleton: min(kDefaultWorkers,
/// max(1, hardware_concurrency)).
fn singletonWorkerCount() u32 {
    var hw: u32 = @intCast(std.Thread.getCpuCount() catch 0);
    if (hw == 0) hw = kDefaultWorkers;
    var n = @min(kDefaultWorkers, hw);
    if (n < 1) n = 1;
    return n;
}

const Singleton = pool_lifecycle.LazySingleton(OuterThreadPool, singletonWorkerCount, "OuterThreadPool: singleton init failed");

/// Access the shared instance. Created on first access, sized per
/// singletonWorkerCount() (see LazySingleton in pool_lifecycle.zig for the
/// lazy-init/never-torn-down mechanics).
pub fn instance() *OuterThreadPool {
    return Singleton.get();
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "OuterThreadPool.create/destroy round-trips cleanly" {
    const pool = try OuterThreadPool.create(testing.allocator, 2);
    try testing.expectEqual(@as(u32, 2), pool.workerCount());
    pool.destroy();
}

test "OuterThreadPool.create clamps a zero worker count to 1" {
    const pool = try OuterThreadPool.create(testing.allocator, 0);
    try testing.expectEqual(@as(u32, 1), pool.workerCount());
    pool.destroy();
}

test "OuterThreadPool.submit runs a one-shot job" {
    const pool = try OuterThreadPool.create(testing.allocator, 2);
    defer pool.destroy();

    var done = std.atomic.Value(bool).init(false);

    const Ctx = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            flag.store(true, .release);
        }
    };
    pool.submit(Ctx.run, .{&done});
    pool.waitIdle();

    try testing.expect(done.load(.acquire));
}

test "OuterThreadPool.waitForStreamIdle returns once a stream drains" {
    const pool = try OuterThreadPool.create(testing.allocator, 2);
    defer pool.destroy();

    var ran = std.atomic.Value(bool).init(false);
    const Ctx = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            flag.store(true, .release);
        }
    };
    pool.submitForStream(42, Ctx.run, .{&ran});
    pool.waitForStreamIdle(42);
    try testing.expect(ran.load(.acquire));
}

test "OuterThreadPool removes drained stream entries" {
    const pool = try OuterThreadPool.create(testing.allocator, 2);
    defer pool.destroy();

    var ran = std.atomic.Value(bool).init(false);
    const Ctx = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            flag.store(true, .release);
        }
    };
    pool.submitForStream(7, Ctx.run, .{&ran});
    pool.waitForStreamIdle(7);
    try testing.expect(ran.load(.acquire));

    pool.mutex.lock();
    const count = pool.streams.count();
    pool.mutex.unlock();
    try testing.expectEqual(@as(u32, 0), count);
}

// The per-stream serialization invariant, cross-stream concurrency, and
// the shared-singleton worker-count formula are exercised (via the actual
// `instance()` singleton) in concurrency_test.zig.
