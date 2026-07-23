//! decode_scheduler_test.zig — dedicated test suite for DecodeScheduler.
//!
//! DecodeScheduler tests: async open, continuous serial prefetch fill,
//! and seek/queue-behind semantics, against real fixture files. Headless,
//! no GPU.
//!
//! Fixture paths are relative to the repo root, which is the test working
//! directory (matches demuxer.zig/mmap_reader.zig/decoder_test.zig's
//! fixture tests); a missing fixture skips the case.

const std = @import("std");
const testing = std.testing;

const decode_scheduler = @import("decode_scheduler.zig");
const outer_thread_pool = @import("outer_thread_pool.zig");
const test_support = @import("test_support.zig");

const DecodeScheduler = decode_scheduler.DecodeScheduler;

const fixture_hap1 = "tests/fixtures/hap1.mov";

/// Bound for the waitFor/drain polls throughout this file: how long a
/// scheduler operation (open, prefetch, seek) gets to complete before a
/// test gives up and fails.
const wait_timeout_ms: i64 = 5000;
/// Bound for the holdsFor check that reverse playback does not emit a
/// frame past index 0 once it has settled there.
const no_further_frame_hold_ms: i64 = 50;

// -----------------------------------------------------------------------
// Shared helpers
// -----------------------------------------------------------------------

fn openSettledPred(scheduler: *DecodeScheduler) bool {
    return switch (scheduler.openStatus()) {
        .not_started, .opening => false,
        .open, .failed => true,
    };
}

/// Open `path` on `scheduler` and block (bounded) for the scheduler-owned
/// completion state to settle. Returns whether it opened successfully.
fn openAndWait(scheduler: *DecodeScheduler, path: []const u8) !bool {
    try scheduler.openAsync(path);
    if (!test_support.waitFor(*DecodeScheduler, scheduler, openSettledPred, wait_timeout_ms)) {
        return error.TestUnexpectedResult;
    }
    return scheduler.isOpen();
}

const HasFramePred = struct {
    scheduler: *DecodeScheduler,
    fn hasFrame(self: @This()) bool {
        var lease = self.scheduler.queue.acquireRead() orelse return false;
        lease.release();
        return true;
    }
};

/// Drain frames from `scheduler`'s queue for up to `timeout_ms`, calling
/// `check(ctx, idx)` for each observed frame and re-arming prefetch after
/// each pop. Stops as soon as `check` reports the target has been reached,
/// or the timeout elapses. Returns whether it was ever reached.
fn drainUntil(
    scheduler: *DecodeScheduler,
    timeout_ms: i64,
    comptime Ctx: type,
    ctx: Ctx,
    check: *const fn (Ctx, u32) anyerror!bool,
) !bool {
    const start = test_support.nowMs();
    while (test_support.nowMs() - start < timeout_ms) {
        var lease = scheduler.queue.acquireRead() orelse {
            test_support.sleepNs(std.time.ns_per_ms);
            continue;
        };
        const reached = check(ctx, lease.frame_index) catch |err| {
            lease.release();
            return err;
        };
        lease.consume();
        _ = scheduler.notifyCapacityAvailable();
        if (reached) return true;
    }
    return false;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "scheduler open_async does not block caller" {
    if (!test_support.fixtureExists(fixture_hap1)) return error.SkipZigTest;

    var scheduler = try DecodeScheduler.init(testing.allocator);
    defer scheduler.deinit();

    // open_async must return immediately -- it hands the mmap+parse work
    // to the outer pool rather than doing it on the calling thread.
    try scheduler.openAsync(fixture_hap1);

    // The worker publishes completion through the scheduler state.
    try testing.expect(test_support.waitFor(*DecodeScheduler, &scheduler, openSettledPred, wait_timeout_ms));
    try testing.expect(scheduler.isOpen());
    try testing.expectEqual(decode_scheduler.OpenStatus.open, scheduler.openStatus());
    try testing.expect(scheduler.trackInfo().frame_count > 0);
}

test "scheduler open_async reports failure for missing file" {
    var scheduler = try DecodeScheduler.init(testing.allocator);
    defer scheduler.deinit();

    try scheduler.openAsync("tests/fixtures/does_not_exist.mov");

    try testing.expect(test_support.waitFor(*DecodeScheduler, &scheduler, openSettledPred, wait_timeout_ms));
    try testing.expect(!scheduler.isOpen());
    try testing.expectEqual(decode_scheduler.OpenStatus.failed, scheduler.openStatus());
    try testing.expectEqual(error.FileOpenFailed, scheduler.openError().?);
}

test "scheduler open_async is one-shot" {
    var scheduler = try DecodeScheduler.init(testing.allocator);
    defer scheduler.deinit();

    try scheduler.openAsync("tests/fixtures/does_not_exist.mov");
    try testing.expect(test_support.waitFor(*DecodeScheduler, &scheduler, openSettledPred, wait_timeout_ms));
    try testing.expectEqual(decode_scheduler.OpenStatus.failed, scheduler.openStatus());
    try testing.expectError(error.OpenAlreadyStarted, scheduler.openAsync("tests/fixtures/does_not_exist.mov"));
}

test "scheduler prefetches frames in order" {
    if (!test_support.fixtureExists(fixture_hap1)) return error.SkipZigTest;

    var scheduler = try DecodeScheduler.init(testing.allocator);
    defer scheduler.deinit();
    try testing.expect(try openAndWait(&scheduler, fixture_hap1));

    try testing.expect(scheduler.requestFrame(0, true));

    // Consume frames as a render thread would, popping and re-arming
    // prefetch, and check strictly increasing indices with no gaps.
    const frame_count = scheduler.trackInfo().frame_count;
    const to_read = @min(frame_count, 10);

    var expected: u32 = 0;
    while (expected < to_read) {
        try testing.expect(test_support.waitFor(HasFramePred, .{ .scheduler = &scheduler }, HasFramePred.hasFrame, wait_timeout_ms));
        var lease = scheduler.queue.acquireRead().?;
        defer if (lease.active) lease.release();
        try testing.expectEqual(expected, lease.frame_index);
        lease.consume();
        _ = scheduler.notifyCapacityAvailable();
        expected += 1;
    }
}

test "scheduler publishes a terminal error for a corrupt sample" {
    if (!test_support.fixtureExists(fixture_hap1)) return error.SkipZigTest;

    var scheduler = try DecodeScheduler.init(testing.allocator);
    defer scheduler.deinit();
    try testing.expect(try openAndWait(&scheduler, fixture_hap1));

    // Keep the sample inside the validated mmap range but truncate it below
    // the minimum Hap frame header. This deterministically reaches the real
    // decoder's InvalidFrame path without maintaining a second fixture.
    scheduler.demuxer.samples.items[0].size = 1;
    try testing.expect(scheduler.requestFrame(0, true));

    const DecodeFailedPred = struct {
        fn f(sched: *DecodeScheduler) bool {
            return sched.decodeStatus() == .failed;
        }
    };
    try testing.expect(test_support.waitFor(*DecodeScheduler, &scheduler, DecodeFailedPred.f, wait_timeout_ms));
    try testing.expectEqual(error.InvalidFrame, scheduler.decodeError().?);
    try testing.expect(scheduler.queue.empty());

    // Failure is terminal for this scheduler lifetime: no more work may be
    // admitted against the decoder state that rejected the sample.
    try testing.expect(!scheduler.requestFrame(1, true));
    try testing.expect(!scheduler.notifyCapacityAvailable());
}

test "scheduler seek drains and retargets" {
    if (!test_support.fixtureExists(fixture_hap1)) return error.SkipZigTest;

    var scheduler = try DecodeScheduler.init(testing.allocator);
    defer scheduler.deinit();
    try testing.expect(try openAndWait(&scheduler, fixture_hap1));

    const frame_count = scheduler.trackInfo().frame_count;
    if (frame_count < 3) return error.SkipZigTest;

    try testing.expect(scheduler.requestFrame(0, true));
    // Let a frame prefetch, then seek forward. The queue-behind contract
    // only guarantees the *next* frame observed is >= the seek target (an
    // in-flight decode may still land first).
    try testing.expect(test_support.waitFor(HasFramePred, .{ .scheduler = &scheduler }, HasFramePred.hasFrame, wait_timeout_ms));

    const seek_target = frame_count - 1;
    try testing.expect(scheduler.requestFrame(seek_target, true));

    const AtOrPastTargetPred = struct {
        scheduler: *DecodeScheduler,
        seek_target: u32,
        fn f(self: @This()) bool {
            var lease = self.scheduler.queue.acquireRead() orelse return false;
            defer lease.release();
            return lease.frame_index >= self.seek_target;
        }
    };
    const got = test_support.waitFor(AtOrPastTargetPred, .{ .scheduler = &scheduler, .seek_target = seek_target }, AtOrPastTargetPred.f, wait_timeout_ms);
    try testing.expect(got);

    var seek_lease = scheduler.queue.acquireRead().?;
    defer if (seek_lease.active) seek_lease.release();
    try testing.expect(seek_lease.frame_index >= seek_target);
    seek_lease.release();
}

test "scheduler backward seek drains and retargets" {
    if (!test_support.fixtureExists(fixture_hap1)) return error.SkipZigTest;

    var scheduler = try DecodeScheduler.init(testing.allocator);
    defer scheduler.deinit();
    try testing.expect(try openAndWait(&scheduler, fixture_hap1));

    const frame_count = scheduler.trackInfo().frame_count;
    if (frame_count < 15) return error.SkipZigTest;

    try testing.expect(scheduler.requestFrame(0, true));

    // Consume forward far enough that the queue is prefetching well past
    // the backward target, so the drain has stale (higher-index) frames
    // to discard.
    var expected: u32 = 0;
    while (expected < 10) {
        try testing.expect(test_support.waitFor(HasFramePred, .{ .scheduler = &scheduler }, HasFramePred.hasFrame, wait_timeout_ms));
        var lease = scheduler.queue.acquireRead().?;
        defer if (lease.active) lease.release();
        try testing.expectEqual(expected, lease.frame_index);
        lease.consume();
        _ = scheduler.notifyCapacityAvailable();
        expected += 1;
    }

    // Let a little more forward prefetch land in the (now-refilling)
    // queue before seeking backward, so there is real stale, higher-index
    // material to drain.
    try testing.expect(test_support.waitFor(HasFramePred, .{ .scheduler = &scheduler }, HasFramePred.hasFrame, wait_timeout_ms));

    const seek_target: u32 = 5;
    try testing.expect(scheduler.requestFrame(seek_target, false));

    // The queue-behind boundary permits an in-flight forward frame to be
    // observed before the seek takes effect. Once the backward target
    // arrives, though, every subsequent frame must descend one index at a
    // time through frame zero.
    const BackwardSeekCheck = struct {
        seek_target: u32,
        started: bool = false,
        previous: u32 = 0,

        fn f(self: *@This(), idx: u32) !bool {
            if (!self.started) {
                if (idx != self.seek_target) {
                    try testing.expect(idx > self.seek_target);
                    return false;
                }
                self.started = true;
                self.previous = idx;
                return false;
            }

            try testing.expectEqual(self.previous - 1, idx);
            self.previous = idx;
            return idx == 0;
        }
    };
    var check: BackwardSeekCheck = .{ .seek_target = seek_target };
    const reached_zero = try drainUntil(&scheduler, wait_timeout_ms, *BackwardSeekCheck, &check, BackwardSeekCheck.f);
    try testing.expect(reached_zero);
}

test "scheduler rapid seeks resolve to latest target only" {
    if (!test_support.fixtureExists(fixture_hap1)) return error.SkipZigTest;

    var scheduler = try DecodeScheduler.init(testing.allocator);
    defer scheduler.deinit();
    try testing.expect(try openAndWait(&scheduler, fixture_hap1));

    const frame_count = scheduler.trackInfo().frame_count;
    if (frame_count < 45) return error.SkipZigTest;

    try testing.expect(scheduler.requestFrame(0, true));

    // Let one frame land and consume it so a decode is plausibly in
    // flight, then fire a burst of seeks back-to-back with no waiting in
    // between -- only the last one should ever be honored (latest seek
    // wins). The discarded targets are chosen far from both the initial
    // in-flight window and the final target so any of them showing up in
    // the queue is unambiguously a scheduling bug, not a coincidence of
    // sequential decode.
    try testing.expect(test_support.waitFor(HasFramePred, .{ .scheduler = &scheduler }, HasFramePred.hasFrame, wait_timeout_ms));
    var first_lease = scheduler.queue.acquireRead().?;
    defer if (first_lease.active) first_lease.release();
    first_lease.consume();
    _ = scheduler.notifyCapacityAvailable();

    const final_target: u32 = 3;
    const discarded = [_]u32{ frame_count - 5, frame_count - 15, frame_count - 25 };
    for (discarded) |t| try testing.expect(scheduler.requestFrame(t, true));
    try testing.expect(scheduler.requestFrame(final_target, true));

    // Drain everything the scheduler produces for a bounded window,
    // asserting none of the discarded targets is ever served and that the
    // final target eventually is.
    const RapidSeekCheck = struct {
        discarded: []const u32,
        final_target: u32,
        fn f(self: @This(), idx: u32) !bool {
            for (self.discarded) |t| try testing.expect(idx != t);
            return idx == self.final_target;
        }
    };
    const saw_final_target = try drainUntil(&scheduler, wait_timeout_ms, RapidSeekCheck, .{ .discarded = &discarded, .final_target = final_target }, RapidSeekCheck.f);
    try testing.expect(saw_final_target);
}

test "scheduler capacity notification cannot be lost at fill completion" {
    if (!test_support.fixtureExists(fixture_hap1)) return error.SkipZigTest;

    var scheduler = try DecodeScheduler.init(testing.allocator);
    defer scheduler.deinit();
    try testing.expect(try openAndWait(&scheduler, fixture_hap1));

    var gate: DecodeScheduler.TestFillDecisionGate = .{};
    scheduler.setFillDecisionGateForTest(&gate);
    try testing.expect(scheduler.requestFrame(0, true));

    const AtomicTruePred = struct {
        fn f(value: *std.atomic.Value(bool)) bool {
            return value.load(.acquire);
        }
    };
    try testing.expect(test_support.waitFor(*std.atomic.Value(bool), &gate.snapshot_taken, AtomicTruePred.f, wait_timeout_ms));

    var popped = std.atomic.Value(bool).init(false);
    var notified = std.atomic.Value(bool).init(false);
    const Notifier = struct {
        fn run(sched: *DecodeScheduler, popped_: *std.atomic.Value(bool), notified_: *std.atomic.Value(bool)) void {
            var lease = sched.queue.acquireRead() orelse @panic("queue unexpectedly empty");
            lease.consume();
            popped_.store(true, .release);
            _ = sched.notifyCapacityAvailable();
            notified_.store(true, .release);
        }
    };
    const notifier = try std.Thread.spawn(.{}, Notifier.run, .{ &scheduler, &popped, &notified });
    try testing.expect(test_support.waitFor(*std.atomic.Value(bool), &popped, AtomicTruePred.f, 1000));

    // The worker has already observed "full" but has not cleared its latch.
    // Let it finish only after the consumer's notification is in flight.
    gate.proceed.store(true, .release);
    notifier.join();
    try testing.expect(notified.load(.acquire));

    const QueueFullPred = struct {
        fn f(sched: *DecodeScheduler) bool {
            return sched.queue.full();
        }
    };
    try testing.expect(test_support.waitFor(*DecodeScheduler, &scheduler, QueueFullPred.f, wait_timeout_ms));
}

test "scheduler reverse prefetches frames in decreasing order" {
    if (!test_support.fixtureExists(fixture_hap1)) return error.SkipZigTest;

    var scheduler = try DecodeScheduler.init(testing.allocator);
    defer scheduler.deinit();
    try testing.expect(try openAndWait(&scheduler, fixture_hap1));

    const frame_count = scheduler.trackInfo().frame_count;
    if (frame_count < 20) return error.SkipZigTest;

    // Reverse playback: requestFrame's `forward=false` must decode
    // *backward* from the target, i.e. the frame queue fills with
    // strictly decreasing indices, not the scheduler's default forward
    // cursor.
    const start_frame: u32 = 19;
    try testing.expect(scheduler.requestFrame(start_frame, false));

    var expected: u32 = start_frame;
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try testing.expect(test_support.waitFor(HasFramePred, .{ .scheduler = &scheduler }, HasFramePred.hasFrame, wait_timeout_ms));
        var lease = scheduler.queue.acquireRead().?;
        defer if (lease.active) lease.release();
        try testing.expectEqual(expected, lease.frame_index);
        lease.consume();
        _ = scheduler.notifyCapacityAvailable();
        expected -= 1;
    }
}

test "scheduler reverse playback stops cleanly at frame zero" {
    if (!test_support.fixtureExists(fixture_hap1)) return error.SkipZigTest;

    var scheduler = try DecodeScheduler.init(testing.allocator);
    defer scheduler.deinit();
    try testing.expect(try openAndWait(&scheduler, fixture_hap1));

    const frame_count = scheduler.trackInfo().frame_count;
    if (frame_count < 5) return error.SkipZigTest;

    // Reverse playback that reaches the start of the stream must present
    // frame 0 exactly once and then settle -- no underflow (frame_index
    // is unsigned), no crash, no runaway re-decode of frame 0 forever.
    try testing.expect(scheduler.requestFrame(4, false));

    var saw_zero = false;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try testing.expect(test_support.waitFor(HasFramePred, .{ .scheduler = &scheduler }, HasFramePred.hasFrame, wait_timeout_ms));
        var lease = scheduler.queue.acquireRead().?;
        defer if (lease.active) lease.release();
        try testing.expectEqual(4 - i, lease.frame_index);
        if (lease.frame_index == 0) saw_zero = true;
        lease.consume();
        _ = scheduler.notifyCapacityAvailable();
        if (saw_zero) break;
    }
    try testing.expect(saw_zero);

    // Give the scheduler a bounded window to (mis)behave: it must not
    // produce another frame after 0 (no wraparound, no duplicate spam).
    // Poll throughout the window rather than sleeping once and sampling
    // at the end, so a spurious frame that appears and is then popped
    // mid-sleep isn't missed.
    const NoFramePred = struct {
        scheduler: *DecodeScheduler,
        fn f(self: @This()) bool {
            var lease = self.scheduler.queue.acquireRead() orelse return true;
            lease.release();
            return false;
        }
    };
    try testing.expect(test_support.holdsFor(NoFramePred, .{ .scheduler = &scheduler }, NoFramePred.f, no_further_frame_hold_ms));
}

test "scheduler destruction waits for an in-flight open" {
    if (!test_support.fixtureExists(fixture_hap1)) return error.SkipZigTest;

    const Shared = struct {
        done: std.atomic.Value(bool) = .init(false),
    };
    var shared: Shared = .{};

    const Runner = struct {
        fn run(path: []const u8, shared_: *Shared) void {
            var i: u32 = 0;
            while (i < 20) : (i += 1) {
                var scheduler = DecodeScheduler.init(testing.allocator) catch @panic("OOM");
                scheduler.openAsync(path) catch @panic("OOM");
                scheduler.deinit();
            }
            shared_.done.store(true, .release);
        }
    };

    const thread = try std.Thread.spawn(.{}, Runner.run, .{ fixture_hap1, &shared });
    thread.join();
    try testing.expect(shared.done.load(.acquire));
}

test "scheduler closing rejects new work before teardown drains" {
    var scheduler = try DecodeScheduler.init(testing.allocator);
    var gate: DecodeScheduler.TestCloseGate = .{};
    scheduler.setCloseGateForTest(&gate);

    var close_finished = std.atomic.Value(bool).init(false);
    const Closer = struct {
        fn run(sched: *DecodeScheduler, finished: *std.atomic.Value(bool)) void {
            sched.deinit();
            finished.store(true, .release);
        }
    };
    const closer = try std.Thread.spawn(.{}, Closer.run, .{ &scheduler, &close_finished });

    const AtomicTruePred = struct {
        fn f(value: *std.atomic.Value(bool)) bool {
            return value.load(.acquire);
        }
    };
    try testing.expect(test_support.waitFor(*std.atomic.Value(bool), &gate.closing_set, AtomicTruePred.f, 1000));

    try testing.expect(!scheduler.requestFrame(2, false));
    try testing.expectError(error.SchedulerClosing, scheduler.openAsync(fixture_hap1));
    try testing.expect(!scheduler.notifyCapacityAvailable());
    try testing.expect(!close_finished.load(.acquire));

    gate.proceed.store(true, .release);
    closer.join();
    try testing.expect(close_finished.load(.acquire));
}

test "scheduler concurrent seeks never tear target and direction" {
    if (!test_support.fixtureExists(fixture_hap1)) return error.SkipZigTest;

    var scheduler = try DecodeScheduler.init(testing.allocator);
    defer scheduler.deinit();
    try testing.expect(try openAndWait(&scheduler, fixture_hap1));

    const frame_count = scheduler.trackInfo().frame_count;
    if (frame_count < 12) return error.SkipZigTest;

    // Two coherent (target, direction) pairs. requestFrame writes target,
    // direction, and the pending flag in one critical section, so a torn
    // application -- one call's target paired with the other's direction,
    // e.g. (5, backward) or (10, forward) -- must be impossible. Two
    // threads hammer the two pairs with no spacing to maximize
    // interleaving.
    const target_a: u32 = 5; // forward  -> queue fills 5, 6, 7, ...
    const target_b: u32 = 10; // backward -> queue fills 10, 9, 8, ...

    var stop = std.atomic.Value(bool).init(false);

    const Runner = struct {
        fn hammerForward(sched: *DecodeScheduler, stop_: *std.atomic.Value(bool)) void {
            while (!stop_.load(.monotonic)) _ = sched.requestFrame(target_a, true);
        }
        fn hammerBackward(sched: *DecodeScheduler, stop_: *std.atomic.Value(bool)) void {
            while (!stop_.load(.monotonic)) _ = sched.requestFrame(target_b, false);
        }
    };

    const ta = try std.Thread.spawn(.{}, Runner.hammerForward, .{ &scheduler, &stop });
    const tb = try std.Thread.spawn(.{}, Runner.hammerBackward, .{ &scheduler, &stop });

    // Bounds the entire interleaving budget: how long the two threads get
    // to race requestFrame calls against each other before we stop them
    // and inspect which (target, direction) pair won.
    const hammer_window_ms = 100;
    test_support.sleepNs(hammer_window_ms * std.time.ns_per_ms);
    stop.store(true, .release);
    ta.join();
    tb.join();

    // Let the last applied seek's fill run to completion, then inspect
    // the now-static queue (no consumer re-arms prefetch, so it won't
    // change).
    outer_thread_pool.instance().waitIdle();

    var first_lease = scheduler.queue.acquireRead().?;
    defer if (first_lease.active) first_lease.release();
    const first = first_lease.frame_index;
    // The oldest frame is the winning pair's target; the direction of the
    // frames after it must match that same pair. 5-descending or
    // 10-ascending would mean a torn (target, direction) pair.
    try testing.expect(first == target_a or first == target_b);
    const expect_forward = first == target_a;

    first_lease.consume();
    var prev = first;
    while (scheduler.queue.acquireRead()) |lease_value| {
        var lease = lease_value;
        defer if (lease.active) lease.release();
        const next = lease.frame_index;
        if (expect_forward) {
            try testing.expectEqual(prev + 1, next);
        } else {
            try testing.expectEqual(prev - 1, next);
        }
        prev = next;
        lease.consume();
    }
}
