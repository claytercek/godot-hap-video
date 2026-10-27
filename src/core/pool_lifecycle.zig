//! Shared worker shutdown and lazy process-lifetime singletons for
//! InnerThreadPool and OuterThreadPool. Each pool handles its own dispatch.

const std = @import("std");

const sync = @import("sync.zig");

const Mutex = sync.Mutex;
const Condition = sync.Condition;

/// Lock `mutex`, clear `running`, unlock, wake all waiters on `cv`, and
/// join every thread in `workers`. Callers must then deinit synchronization
/// primitives, free `workers`, and release their pool-specific state.
pub fn stopAndJoinWorkers(mutex: *Mutex, running: *bool, cv: *Condition, workers: []std.Thread) void {
    mutex.lock();
    running.* = false;
    mutex.unlock();
    cv.notifyAll();
    for (workers) |w| w.join();
}

/// Lazily create a process-lifetime *T using the page allocator; never
/// destroy it. T must expose `create(std.mem.Allocator, u32) !*T`.
/// `sizeFn` supplies each pool's worker count: the inner pool subtracts
/// outer workers from hardware concurrency; the outer pool clamps to its
/// fixed default.
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
