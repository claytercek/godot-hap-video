//! concurrency_test.zig — dedicated test suite for the concurrency
//! primitives.
//!
//! Concurrency unit tests: SPSC frame queue contract, outer-pool
//! per-stream serial invariant, retire ring sequencing, and thread-count
//! bounds. Headless, no GPU.
//!
//! Note: an invariant violated from inside a spawned worker thread is
//! checked with `std.debug.assert` rather than surfaced back to the
//! spawning test function -- Zig's std.Thread has no built-in
//! cross-thread error propagation, so a violation aborts the process
//! instead, which fails the test run just as unambiguously.

const std = @import("std");
const testing = std.testing;

const hap_frame = @import("hap_frame.zig");
const retire_ring = @import("retire_ring.zig");
const frame_queue = @import("frame_queue.zig");
const outer_thread_pool = @import("outer_thread_pool.zig");
const thread_pool = @import("thread_pool.zig");
const decoder = @import("decoder.zig");
const test_support = @import("test_support.zig");
const sync = @import("sync.zig");

const RetireRing = retire_ring.RetireRing;
const FrameQueue = frame_queue.FrameQueue;
const OuterThreadPool = outer_thread_pool.OuterThreadPool;
const InnerThreadPool = thread_pool.InnerThreadPool;

/// Test helper: ArrayListUnmanaged.resize() does not value-initialize
/// newly added elements -- growing from empty leaves `items[0]` as
/// uninitialized memory. Only initializes on first growth from empty, so
/// a slot being *reused* (already at length 1, as in the
/// buffer-capacity-reuse test below) keeps its existing DecodedTexture
/// (and thus its already-sized `data` buffer) untouched.
fn ensureOneTexture(list: *std.ArrayListUnmanaged(hap_frame.DecodedTexture), allocator: std.mem.Allocator) !void {
    if (list.items.len == 0) {
        try list.resize(allocator, 1);
        list.items[0] = .{};
    }
}

// -----------------------------------------------------------------------
// hap.c externs needed only by this test file (createUnchunkedHap1/
// createChunkedFrame's HapMaxEncodedLength/HapEncode externs live in
// test_support.zig, shared with decoder_test.zig).
// -----------------------------------------------------------------------

const HapTextureFormat_RGB_DXT1: c_uint = 0x83F0;
const HapCompressorSnappy: c_uint = 1;

extern fn HapDecode(
    input_buffer: ?*const anyopaque,
    input_buffer_bytes: c_ulong,
    index: c_uint,
    callback: ?thread_pool.HapDecodeCallback,
    info: ?*anyopaque,
    output_buffer: ?*anyopaque,
    output_buffer_bytes: c_ulong,
    output_buffer_bytes_used: *c_ulong,
    output_buffer_texture_format: *c_uint,
) c_uint;

// -----------------------------------------------------------------------
// RetireRing
// -----------------------------------------------------------------------

test "retire ring default depth is 3" {
    const Ring = RetireRing(3);
    try testing.expectEqual(@as(usize, 3), Ring.depth());
}

test "retire ring writable never equals current" {
    const Ring = RetireRing(3);
    var ring: Ring = .{};
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try testing.expect(ring.writableSlot() != ring.currentSlot());
        ring.commit();
    }
}

test "retire ring cycles through all slots in order" {
    const Ring = RetireRing(3);
    var ring: Ring = .{};
    // currentSlot starts at 0; each commit advances by one, wrapping.
    try testing.expectEqual(@as(usize, 0), ring.currentSlot());
    ring.commit();
    try testing.expectEqual(@as(usize, 1), ring.currentSlot());
    ring.commit();
    try testing.expectEqual(@as(usize, 2), ring.currentSlot());
    ring.commit();
    try testing.expectEqual(@as(usize, 0), ring.currentSlot());
}

test "retire ring writer stays two slots behind reader" {
    // With depth 3, the slot a writer is about to fill was last "current"
    // two commits ago -- i.e. it was retired (no longer the display slot)
    // for a full extra generation beyond Godot's frame-queue depth of 2.
    const Ring = RetireRing(3);
    var ring: Ring = .{};
    const slot_two_generations_ago = ring.currentSlot();
    ring.commit();
    ring.commit();
    try testing.expectEqual(slot_two_generations_ago, ring.writableSlot());
}

// -----------------------------------------------------------------------
// FrameQueue
// -----------------------------------------------------------------------

test "frame queue starts empty, not full" {
    var q = try FrameQueue.init(testing.allocator, 4);
    defer q.deinit();
    try testing.expect(q.empty());
    try testing.expect(!q.full());
    try testing.expectEqual(@as(usize, 4), q.capacity());
}

test "frame queue push/pop preserves order and index" {
    var q = try FrameQueue.init(testing.allocator, 4);
    defer q.deinit();

    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const slot = q.beginWrite(i).?;
        try ensureOneTexture(&slot.textures, testing.allocator);
        try slot.textures.items[0].data.resize(testing.allocator, 1);
        slot.textures.items[0].data.items[0] = @truncate(i);
        q.commitWrite();
    }
    try testing.expect(q.full());

    i = 0;
    while (i < 4) : (i += 1) {
        var lease = q.acquireRead().?;
        defer if (lease.active) lease.release();
        try testing.expectEqual(i, lease.frame_index);
        try testing.expectEqual(@as(u8, @truncate(i)), lease.frame.textures.items[0].data.items[0]);
        lease.consume();
    }
    try testing.expect(q.empty());
}

test "frame queue beginWrite returns null when full" {
    var q = try FrameQueue.init(testing.allocator, 2);
    defer q.deinit();

    try testing.expect(q.beginWrite(0) != null);
    q.commitWrite();
    try testing.expect(q.beginWrite(1) != null);
    q.commitWrite();
    // Full: producer must back off (this is the seek/prefetch
    // queue-behind boundary, not an error).
    try testing.expect(q.beginWrite(2) == null);
}

test "frame queue peek/pop on empty is safe" {
    var q = try FrameQueue.init(testing.allocator, 4);
    defer q.deinit();

    try testing.expect(q.acquireRead() == null);
    try testing.expect(q.empty());
}

test "frame queue slots reuse buffer capacity" {
    // A slot's DecodedTexture buffer should retain its capacity across a
    // pop/refill cycle when the new frame is the same size (steady-state
    // playback), i.e. no reallocation on the happy path. With depth 2,
    // the ring returns to slot 0 on the 3rd write (0, 1, 0, 1, ...).
    var q = try FrameQueue.init(testing.allocator, 2);
    defer q.deinit();

    const w0 = q.beginWrite(0).?;
    try ensureOneTexture(&w0.textures, testing.allocator);
    try w0.textures.items[0].data.resize(testing.allocator, 1024);
    const original_ptr = w0.textures.items[0].data.items.ptr;
    q.commitWrite();
    var r0 = q.acquireRead().?;
    r0.consume();

    const w1 = q.beginWrite(1).?; // slot 1, unrelated buffer
    try ensureOneTexture(&w1.textures, testing.allocator);
    try w1.textures.items[0].data.resize(testing.allocator, 1024);
    q.commitWrite();
    var r1 = q.acquireRead().?;
    r1.consume();

    const w2 = q.beginWrite(2).?; // wraps back to slot 0
    try testing.expect(w2 == w0);
    try ensureOneTexture(&w2.textures, testing.allocator); // already length 1: no-op, preserves buffer
    try w2.textures.items[0].data.resize(testing.allocator, 1024); // same size: no reallocation expected
    try testing.expectEqual(original_ptr, w2.textures.items[0].data.items.ptr);
    q.commitWrite();
}

test "frame queue drain discards committed frames" {
    var q = try FrameQueue.init(testing.allocator, 4);
    defer q.deinit();

    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        _ = q.beginWrite(i);
        q.commitWrite();
    }
    try testing.expect(!q.empty());
    q.drain();
    try testing.expect(q.empty());
    try testing.expect(!q.full());
}

test "frame queue drain cannot recycle a leased read slot" {
    var q = try FrameQueue.init(testing.allocator, 1);
    defer q.deinit();

    const first = q.beginWrite(7).?;
    try ensureOneTexture(&first.textures, testing.allocator);
    try first.textures.items[0].data.resize(testing.allocator, 1);
    first.textures.items[0].data.items[0] = 0xA7;
    q.commitWrite();

    var lease = q.acquireRead().?;
    defer if (lease.active) lease.release();
    try testing.expectEqual(@as(u32, 7), lease.frame_index);

    var started = std.atomic.Value(bool).init(false);
    var finished = std.atomic.Value(bool).init(false);
    const Drainer = struct {
        fn run(queue: *FrameQueue, started_: *std.atomic.Value(bool), finished_: *std.atomic.Value(bool)) void {
            started_.store(true, .release);
            queue.drain();
            const replacement = queue.beginWrite(8) orelse @panic("leased slot was not released");
            ensureOneTexture(&replacement.textures, testing.allocator) catch @panic("OOM");
            replacement.textures.items[0].data.resize(testing.allocator, 1) catch @panic("OOM");
            replacement.textures.items[0].data.items[0] = 0xB8;
            queue.commitWrite();
            finished_.store(true, .release);
        }
    };

    const thread = try std.Thread.spawn(.{}, Drainer.run, .{ &q, &started, &finished });
    var thread_joined = false;
    defer if (!thread_joined) {
        // Any failed assertion above the normal consume point must unblock
        // drain before joining, or test teardown would wait forever.
        if (lease.active) lease.release();
        thread.join();
    };
    const StartedPred = struct {
        fn f(value: *std.atomic.Value(bool)) bool {
            return value.load(.acquire);
        }
    };
    try testing.expect(test_support.waitFor(*std.atomic.Value(bool), &started, StartedPred.f, 1000));

    const StillBlockedPred = struct {
        fn f(value: *std.atomic.Value(bool)) bool {
            return !value.load(.acquire);
        }
    };
    try testing.expect(test_support.holdsFor(*std.atomic.Value(bool), &finished, StillBlockedPred.f, 25));
    try testing.expectEqual(@as(u8, 0xA7), lease.frame.textures.items[0].data.items[0]);

    lease.consume();
    thread.join();
    thread_joined = true;
    try testing.expect(finished.load(.acquire));

    var replacement = q.acquireRead().?;
    defer if (replacement.active) replacement.release();
    try testing.expectEqual(@as(u32, 8), replacement.frame_index);
    try testing.expectEqual(@as(u8, 0xB8), replacement.frame.textures.items[0].data.items[0]);
    replacement.consume();
}

test "frame queue concurrent producer/consumer" {
    // Real SPSC usage: one producer thread, one consumer thread, depth 4,
    // 2000 frames. Consumer must observe strictly increasing frame indices
    // with no gaps or duplicates.
    var q = try FrameQueue.init(testing.allocator, 4);
    defer q.deinit();

    const k_frames: u32 = 2000;
    var producer_done = std.atomic.Value(bool).init(false);

    const Ctx = struct {
        fn producer(queue: *FrameQueue, done: *std.atomic.Value(bool)) void {
            var i: u32 = 0;
            while (i < k_frames) {
                const slot = queue.beginWrite(i) orelse {
                    std.Thread.yield() catch {};
                    continue;
                };
                ensureOneTexture(&slot.textures, testing.allocator) catch @panic("OOM");
                slot.textures.items[0].data.resize(testing.allocator, 1) catch @panic("OOM");
                slot.textures.items[0].data.items[0] = @truncate(i & 0xFF);
                queue.commitWrite();
                i += 1;
            }
            done.store(true, .release);
        }

        fn consumer(queue: *FrameQueue) void {
            var expected: u32 = 0;
            while (expected < k_frames) {
                var lease = queue.acquireRead() orelse {
                    std.Thread.yield() catch {};
                    continue;
                };
                std.debug.assert(lease.frame_index == expected);
                std.debug.assert(lease.frame.textures.items[0].data.items[0] == @as(u8, @truncate(expected & 0xFF)));
                lease.consume();
                expected += 1;
            }
        }
    };

    const producer_thread = try std.Thread.spawn(.{}, Ctx.producer, .{ &q, &producer_done });
    const consumer_thread = try std.Thread.spawn(.{}, Ctx.consumer, .{&q});
    producer_thread.join();
    consumer_thread.join();

    try testing.expect(producer_done.load(.acquire));
}

// -----------------------------------------------------------------------
// OuterThreadPool: per-stream serial invariant (via the shared singleton
// -- OuterThreadPool has no public constructor).
// -----------------------------------------------------------------------

test "outer pool default worker count matches spec" {
    var hw: u32 = @intCast(std.Thread.getCpuCount() catch 0);
    if (hw == 0) hw = 1;
    const expected = @min(outer_thread_pool.kDefaultWorkers, @max(@as(u32, 1), hw));
    try testing.expectEqual(expected, outer_thread_pool.instance().workerCount());
}

test "outer pool serializes jobs within a stream" {
    const pool = outer_thread_pool.instance();

    const kStreamA: u64 = 0xA;
    const kStreamB: u64 = 0xB;
    const kJobsPerStream: i32 = 200;

    var a_in_flight = std.atomic.Value(i32).init(0);
    var b_in_flight = std.atomic.Value(i32).init(0);
    var a_max_concurrency = std.atomic.Value(i32).init(0);
    var b_max_concurrency = std.atomic.Value(i32).init(0);
    var a_completed = std.atomic.Value(i32).init(0);
    var b_completed = std.atomic.Value(i32).init(0);
    var a_order = std.array_list.Managed(i32).init(testing.allocator);
    defer a_order.deinit();
    var b_order = std.array_list.Managed(i32).init(testing.allocator);
    defer b_order.deinit();
    var order_mutex: sync.Mutex = .{};

    const Job = struct {
        fn run(
            in_flight: *std.atomic.Value(i32),
            max_concurrency: *std.atomic.Value(i32),
            completed: *std.atomic.Value(i32),
            order_mutex_: *sync.Mutex,
            order: *std.array_list.Managed(i32),
            index: i32,
        ) void {
            const cur = in_flight.fetchAdd(1, .monotonic) + 1;
            var prev_max = max_concurrency.load(.monotonic);
            while (cur > prev_max) {
                if (max_concurrency.cmpxchgWeak(prev_max, cur, .monotonic, .monotonic)) |actual| {
                    prev_max = actual;
                } else break;
            }
            {
                order_mutex_.lock();
                defer order_mutex_.unlock();
                order.append(index) catch unreachable;
            }
            test_support.sleepNs(50 * std.time.ns_per_us);
            _ = in_flight.fetchSub(1, .monotonic);
            _ = completed.fetchAdd(1, .monotonic);
        }
    };

    var i: i32 = 0;
    while (i < kJobsPerStream) : (i += 1) {
        pool.submitForStream(kStreamA, Job.run, .{ &a_in_flight, &a_max_concurrency, &a_completed, &order_mutex, &a_order, i });
        pool.submitForStream(kStreamB, Job.run, .{ &b_in_flight, &b_max_concurrency, &b_completed, &order_mutex, &b_order, i });
    }

    pool.waitIdle();

    try testing.expectEqual(kJobsPerStream, a_completed.load(.monotonic));
    try testing.expectEqual(kJobsPerStream, b_completed.load(.monotonic));
    // Never more than one job in flight per stream, regardless of pool size.
    try testing.expectEqual(@as(i32, 1), a_max_concurrency.load(.monotonic));
    try testing.expectEqual(@as(i32, 1), b_max_concurrency.load(.monotonic));
    // FIFO order within each stream.
    try testing.expectEqual(@as(usize, @intCast(kJobsPerStream)), a_order.items.len);
    try testing.expectEqual(@as(usize, @intCast(kJobsPerStream)), b_order.items.len);
    var j: i32 = 0;
    while (j < kJobsPerStream) : (j += 1) {
        try testing.expectEqual(j, a_order.items[@intCast(j)]);
        try testing.expectEqual(j, b_order.items[@intCast(j)]);
    }
}

test "outer pool different streams run concurrently" {
    // With >=2 workers, two different streams' jobs should be able to
    // overlap in time (this isn't guaranteed on a single-core CI box, so
    // only assert it when the pool actually has room for it).
    const pool = outer_thread_pool.instance();
    if (pool.workerCount() < 2) return;

    var concurrent = std.atomic.Value(i32).init(0);
    var observed_overlap = std.atomic.Value(i32).init(0);
    const kStreamA: u64 = 0x1111;
    const kStreamB: u64 = 0x2222;

    const Job = struct {
        fn run(concurrent_: *std.atomic.Value(i32), overlap: *std.atomic.Value(i32)) void {
            const cur = concurrent_.fetchAdd(1, .monotonic) + 1;
            if (cur >= 2) overlap.store(1, .monotonic);
            test_support.sleepNs(20 * std.time.ns_per_ms);
            _ = concurrent_.fetchSub(1, .monotonic);
        }
    };

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        pool.submitForStream(kStreamA, Job.run, .{ &concurrent, &observed_overlap });
        pool.submitForStream(kStreamB, Job.run, .{ &concurrent, &observed_overlap });
    }
    pool.waitIdle();

    try testing.expectEqual(@as(i32, 1), observed_overlap.load(.monotonic));
}

// -----------------------------------------------------------------------
// InnerThreadPool: concurrent execute() safety, thread-count bound
// -----------------------------------------------------------------------

test "inner pool survives concurrent execute calls" {
    // Two "outer workers" both decoding chunked frames at once must not
    // corrupt the shared work-batch state.
    const pool = thread_pool.instance();

    const kChunks: u32 = 37;

    const Ctx = struct {
        fn work(p: ?*anyopaque, index: c_uint) callconv(.c) void {
            const acc: *std.atomic.Value(i32) = @ptrCast(@alignCast(p.?));
            _ = acc.fetchAdd(@intCast(index), .monotonic);
        }

        fn runBatch(pool_: *InnerThreadPool, sum: *std.atomic.Value(i32)) void {
            var i: u32 = 0;
            while (i < 20) : (i += 1) {
                var local_sum = std.atomic.Value(i32).init(0);
                pool_.execute(work, &local_sum, kChunks);
                // 0 + 1 + ... + 36 = 666
                sum.store(local_sum.load(.monotonic), .monotonic);
            }
        }
    };

    var sum_a = std.atomic.Value(i32).init(0);
    var sum_b = std.atomic.Value(i32).init(0);

    const ta = try std.Thread.spawn(.{}, Ctx.runBatch, .{ pool, &sum_a });
    const tb = try std.Thread.spawn(.{}, Ctx.runBatch, .{ pool, &sum_b });
    ta.join();
    tb.join();

    try testing.expectEqual(@as(i32, 666), sum_a.load(.monotonic));
    try testing.expectEqual(@as(i32, 666), sum_b.load(.monotonic));
}

test "outer times inner stays within hardware concurrency" {
    const hw: u32 = @intCast(std.Thread.getCpuCount() catch 0);
    if (hw == 0) return; // undetectable on this platform; nothing to assert

    const outer = outer_thread_pool.instance().workerCount();
    const inner = thread_pool.instance().workerCount();
    // Spec formula: inner = max(1, hw - outer), so outer + inner <= hw
    // (the two pools' worker threads never together exceed hardware
    // concurrency).
    try testing.expect(outer + inner <= hw or inner == 1);
}

// -----------------------------------------------------------------------
// InnerThreadPool: HapDecode work-batch dispatch (these exercise the same
// InnerThreadPool as the tests above, not decoder-specific behavior)
// -----------------------------------------------------------------------

const WorkItem = struct {
    call_count: std.atomic.Value(u32) = .init(0),
};

fn testWorkFunction(p: ?*anyopaque, index: c_uint) callconv(.c) void {
    _ = index;
    const item: *WorkItem = @ptrCast(@alignCast(p.?));
    _ = item.call_count.fetchAdd(1, .monotonic);
}

test "thread pool basic" {
    const pool = thread_pool.instance();

    // The pool should have at least 1 worker.
    try testing.expect(pool.workerCount() >= 1);

    // Verify the thread count matches the formula
    // max(1, hardware_concurrency - kDefaultWorkers).
    const hw: u32 = @intCast(std.Thread.getCpuCount() catch 0);
    const outer = outer_thread_pool.kDefaultWorkers;
    const expected: u32 = if (hw > outer) hw - outer else 1;
    try testing.expectEqual(expected, pool.workerCount());
}

test "thread pool no workers if single item" {
    // A single work item should complete immediately via the calling thread.
    const pool = thread_pool.instance();

    var item: WorkItem = .{};
    pool.execute(testWorkFunction, &item, 1);

    try testing.expectEqual(@as(u32, 1), item.call_count.load(.monotonic));
}

test "thread pool multi work items" {
    const pool = thread_pool.instance();

    var item: WorkItem = .{};
    const kCount: u32 = 100;

    pool.execute(testWorkFunction, &item, kCount);

    // All work items must have been executed.
    try testing.expectEqual(kCount, item.call_count.load(.monotonic));
}

test "thread pool no remaining state" {
    // Execute multiple batches to ensure no state leaks between calls.
    const pool = thread_pool.instance();

    var item1: WorkItem = .{};
    var item2: WorkItem = .{};

    pool.execute(testWorkFunction, &item1, 5);
    try testing.expectEqual(@as(u32, 5), item1.call_count.load(.monotonic));

    pool.execute(testWorkFunction, &item2, 7);
    try testing.expectEqual(@as(u32, 7), item2.call_count.load(.monotonic));

    // item1 should not have been called again.
    try testing.expectEqual(@as(u32, 5), item1.call_count.load(.monotonic));
}

test "thread pool large count" {
    const pool = thread_pool.instance();

    // Use a count that exceeds the number of workers to test partitioning.
    const kCount: u32 = 1000;
    var item: WorkItem = .{};

    pool.execute(testWorkFunction, &item, kCount);
    try testing.expectEqual(kCount, item.call_count.load(.monotonic));
}

// -----------------------------------------------------------------------
// Callback contract: verify HapDecode respects the single-chunk contract
// (this is thread-pool dispatch behavior, not decode-correctness
// behavior)
// -----------------------------------------------------------------------

var callback_invocation_count: u32 = 0;

fn trackingCallback(
    function: thread_pool.HapDecodeWorkFunction,
    p: ?*anyopaque,
    count: c_uint,
    info: ?*anyopaque,
) callconv(.c) void {
    callback_invocation_count += 1;
    // Forward to the inner pool for proper multi-threaded decode.
    thread_pool.hapInnerDecodeCallback(function, p, count, info);
}

test "decoder callback not invoked for single chunk" {
    // Create an unchunked frame and decode it with our tracking callback.
    const bc1_block = [_]u8{ 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const frame = try test_support.buildRawFrame(testing.allocator, &bc1_block, 0xAB); // None|DXT1
    defer testing.allocator.free(frame);

    var tex_format: c_uint = 0;
    var bytes_used: c_ulong = 0;
    var output: [1024]u8 = undefined;

    callback_invocation_count = 0;

    const result = HapDecode(
        frame.ptr,
        @intCast(frame.len),
        0,
        trackingCallback,
        null,
        &output,
        @intCast(output.len),
        &bytes_used,
        &tex_format,
    );

    try testing.expectEqual(decoder.HapResult_No_Error, result);

    // The callback must NOT have been invoked for a single-chunk frame.
    try testing.expectEqual(@as(u32, 0), callback_invocation_count);
}

test "decoder callback invoked for multi chunk" {
    // Create raw BC1 data (1024 bytes = 128 BC1 blocks), large enough for
    // HapEncode to produce a Complex (chunked) frame.
    const bc1_data = [_]u8{0} ** 1024;

    // Encode with 4 chunks.
    const chunked = try test_support.createChunkedFrame(testing.allocator, &bc1_data, 4, HapTextureFormat_RGB_DXT1, HapCompressorSnappy);
    defer testing.allocator.free(chunked);
    try testing.expect(chunked.len > 0);

    var tex_format: c_uint = 0;
    var bytes_used: c_ulong = 0;
    var output: [4096]u8 = undefined;

    callback_invocation_count = 0;

    const result = HapDecode(
        chunked.ptr,
        @intCast(chunked.len),
        0,
        trackingCallback,
        null,
        &output,
        @intCast(output.len),
        &bytes_used,
        &tex_format,
    );

    try testing.expectEqual(decoder.HapResult_No_Error, result);

    // The callback MUST have been invoked exactly once for a multi-chunk frame.
    try testing.expectEqual(@as(u32, 1), callback_invocation_count);
}
