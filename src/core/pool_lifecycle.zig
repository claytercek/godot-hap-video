//! pool_lifecycle.zig — boilerplate shared by the two process-wide worker
//! pools, InnerThreadPool (thread_pool.zig) and OuterThreadPool
//! (outer_thread_pool.zig): the "stop and join every worker" sequence
//! their destroy() functions both open with, and the lazily-created,
//! never-torn-down module-level singleton pattern both expose via
//! instance(). The pools' actual job-dispatch designs stay separate and
//! are not touched here.

const std = @import("std");

const sync = @import("sync.zig");

const Mutex = sync.Mutex;
const Condition = sync.Condition;

/// Signal shutdown and join every thread in `workers`: lock `mutex`, clear
/// `running`, unlock, wake everything waiting on `cv`, then join.
///
/// Callers still deinit `mutex`/`cv` (and any other synchronization
/// primitives) and free `workers` themselves afterward -- what a pool does
/// past this point differs enough (e.g. InnerThreadPool has a second
/// condition variable and a dispatch mutex to deinit and a partitions
/// slice to free; OuterThreadPool has a stream map to deinit instead) that
/// folding those steps in here would obscure more than the shared prefix
/// saves.
pub fn stopAndJoinWorkers(mutex: *Mutex, running: *bool, cv: *Condition, workers: []std.Thread) void {
    mutex.lock();
    running.* = false;
    mutex.unlock();
    cv.notifyAll();
    for (workers) |w| w.join();
}

/// A lazily-created, process-lifetime singleton of `*T`.
///
/// `T` must expose `create(std.mem.Allocator, u32) !*T`, which both pools'
/// create() already matches. `sizeFn` computes the requested worker count;
/// each pool sizes itself against the hardware differently enough (the
/// inner pool subtracts the outer pool's worker count, the outer pool
/// clamps to its own fixed default) that only the surrounding
/// lock/check-cached/create shape is shared here, not the sizing formula
/// itself.
///
/// The instance is allocated from the page allocator and intentionally
/// never torn down for the process's lifetime, mirroring what each pool's
/// own instance() did before this helper existed.
pub fn LazySingleton(comptime T: type, comptime sizeFn: fn () u32, comptime panic_msg: []const u8) type {
    return struct {
        var mu: Mutex = .{};
        var ptr: std.atomic.Value(?*T) = .init(null);

        pub fn get() *T {
            // Fast path: no lock needed once the singleton is created,
            // since both worker pools call this on hot per-frame paths.
            if (ptr.load(.acquire)) |p| return p;

            mu.lock();
            defer mu.unlock();
            // Re-check under the lock: another thread may have created
            // the instance between the fast-path load above and this
            // lock being acquired.
            if (ptr.load(.monotonic)) |p| return p;

            const p = T.create(std.heap.page_allocator, sizeFn()) catch @panic(panic_msg);
            ptr.store(p, .release);
            return p;
        }
    };
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "stopAndJoinWorkers wakes a cv-waiting worker and joins it" {
    const State = struct {
        mutex: Mutex = .{},
        cv: Condition = .{},
        running: bool = true,
        woke: bool = false,
    };
    var state = State{};

    const Ctx = struct {
        fn worker(s: *State) void {
            s.mutex.lock();
            while (s.running) s.cv.wait(&s.mutex);
            s.woke = true;
            s.mutex.unlock();
        }
    };

    var workers = [_]std.Thread{try std.Thread.spawn(.{}, Ctx.worker, .{&state})};
    stopAndJoinWorkers(&state.mutex, &state.running, &state.cv, workers[0..]);

    try testing.expect(state.woke);

    state.mutex.deinit();
    state.cv.deinit();
}

test "LazySingleton creates exactly once and reuses the instance" {
    const Counter = struct {
        var creations: u32 = 0;

        sized_with: u32,

        fn create(allocator: std.mem.Allocator, n: u32) !*@This() {
            creations += 1;
            const self = try allocator.create(@This());
            self.* = .{ .sized_with = n };
            return self;
        }
    };

    const sizeFn = struct {
        fn get() u32 {
            return 7;
        }
    }.get;

    const Singleton = LazySingleton(Counter, sizeFn, "test singleton init failed");

    const a = Singleton.get();
    const b = Singleton.get();

    try testing.expectEqual(a, b);
    try testing.expectEqual(@as(u32, 7), a.sized_with);
    try testing.expectEqual(@as(u32, 1), Counter.creations);
}
