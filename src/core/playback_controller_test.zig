//! Test PlaybackController through its public API.

const std = @import("std");
const testing = std.testing;

const PlaybackController = @import("playback_controller.zig").PlaybackController;

test "controller advances playback and requests the current frame" {
    var controller = PlaybackController.init();
    controller.configure(30.0, 300);
    controller.play();

    const tick = controller.tick(0.1);
    const request = tick.request.?;

    try testing.expectApproxEqAbs(@as(f64, 0.1), controller.position(), 1e-9);
    try testing.expectEqual(@as(u32, 3), request.frame_index);
    try testing.expect(request.forward);
    try testing.expect(request.retarget);
    try testing.expect(!tick.looped);
    try testing.expect(!tick.completed);
}

test "seek pause resume and stop share one authoritative position" {
    var controller = PlaybackController.init();
    controller.configure(24.0, 240);

    const seek = controller.seek(5.0);
    try testing.expectEqual(@as(u32, 120), seek.frame_index);
    try testing.expect(seek.retarget);
    try testing.expectApproxEqAbs(@as(f64, 5.0), controller.position(), 1e-9);

    controller.play();
    controller.pause();
    try testing.expect(controller.tick(1.0).request == null);
    try testing.expectApproxEqAbs(@as(f64, 5.0), controller.position(), 1e-9);

    controller.play();
    _ = controller.tick(0.5);
    try testing.expectApproxEqAbs(@as(f64, 5.5), controller.position(), 1e-9);

    const stopped = controller.stop();
    try testing.expectEqual(@as(u32, 0), stopped.frame_index);
    try testing.expect(stopped.retarget);
    try testing.expect(!controller.isPlaying());
    try testing.expect(!controller.isPaused());
}

test "loop and direction changes preserve overshoot and retarget prefetch" {
    var controller = PlaybackController.init();
    controller.configure(10.0, 20);
    controller.setLoop(true);
    _ = controller.seek(1.9);
    controller.play();

    const wrapped = controller.tick(0.2);
    try testing.expect(wrapped.looped);
    try testing.expect(!wrapped.completed);
    try testing.expectApproxEqAbs(@as(f64, 0.1), controller.position(), 1e-9);
    try testing.expect(wrapped.request.?.retarget);

    controller.setPlaybackSpeed(-0.5);
    const reversed = controller.tick(0.1);
    try testing.expect(!reversed.request.?.forward);
    try testing.expect(reversed.request.?.retarget);
    try testing.expectApproxEqAbs(@as(f64, 0.05), controller.position(), 1e-9);

    const reverse_wrap = controller.tick(0.2);
    try testing.expect(reverse_wrap.looped);
    try testing.expectApproxEqAbs(@as(f64, 1.95), controller.position(), 1e-9);
}

test "pre-open seek is retained and frame stepping pauses active playback" {
    var controller = PlaybackController.init();
    _ = controller.seek(3.0);
    try testing.expectApproxEqAbs(@as(f64, 3.0), controller.position(), 1e-9);

    controller.configure(25.0, 250);
    controller.play();
    const stepped = controller.stepFrame(2).?;

    try testing.expectEqual(@as(u32, 77), stepped.frame_index);
    try testing.expect(stepped.forward);
    try testing.expect(stepped.retarget);
    try testing.expect(controller.isPlaying());
    try testing.expect(controller.isPaused());
    try testing.expectApproxEqAbs(@as(f64, 3.08), controller.position(), 1e-9);

    const clamped = controller.stepFrame(-1000).?;
    try testing.expectEqual(@as(u32, 0), clamped.frame_index);
    try testing.expect(!clamped.forward);
    try testing.expectApproxEqAbs(@as(f64, 0.0), controller.position(), 1e-9);
}

test "non-loop completion clamps at each playback boundary" {
    const Case = struct {
        start: f64,
        speed: f64,
        expected_position: f64,
        expected_frame: u32,
        forward: bool,
    };
    const cases = [_]Case{
        .{ .start = 1.8, .speed = 1.0, .expected_position = 2.0, .expected_frame = 19, .forward = true },
        .{ .start = 0.2, .speed = -1.0, .expected_position = 0.0, .expected_frame = 0, .forward = false },
    };

    for (cases) |case| {
        var controller = PlaybackController.init();
        controller.configure(10.0, 20);
        controller.setPlaybackSpeed(case.speed);
        _ = controller.seek(case.start);
        controller.play();

        const tick = controller.tick(0.2);
        try testing.expect(tick.completed);
        try testing.expect(!tick.looped);
        try testing.expect(!controller.isPlaying());
        try testing.expectEqual(case.forward, tick.request.?.forward);
        try testing.expectEqual(case.expected_frame, tick.request.?.frame_index);
        try testing.expectApproxEqAbs(case.expected_position, controller.position(), 1e-9);
    }
}

test "loop wraps exactly at each playback boundary" {
    const Case = struct {
        start: f64,
        speed: f64,
        delta: f64,
        expected_position: f64,
        expected_frame: u32,
        forward: bool,
    };
    const cases = [_]Case{
        .{ .start = 2.0, .speed = 1.0, .delta = 0.0, .expected_position = 0.0, .expected_frame = 0, .forward = true },
        .{ .start = 0.0, .speed = -1.0, .delta = 0.0, .expected_position = 2.0, .expected_frame = 19, .forward = false },
    };

    for (cases) |case| {
        var controller = PlaybackController.init();
        controller.configure(10.0, 20);
        controller.setLoop(true);
        controller.setPlaybackSpeed(case.speed);
        _ = controller.seek(case.start);
        controller.play();

        const tick = controller.tick(case.delta);
        try testing.expect(tick.looped);
        try testing.expect(!tick.completed);
        try testing.expect(controller.isPlaying());
        try testing.expectEqual(case.forward, tick.request.?.forward);
        try testing.expectEqual(case.expected_frame, tick.request.?.frame_index);
        try testing.expectApproxEqAbs(case.expected_position, controller.position(), 1e-9);
    }
}

test "restart resumes from frame zero after completion" {
    var controller = PlaybackController.init();
    controller.configure(10.0, 20);
    _ = controller.seek(1.8);
    controller.play();
    try testing.expect(controller.tick(0.2).completed);

    const restarted = controller.restart();
    try testing.expectEqual(@as(u32, 0), restarted.frame_index);
    try testing.expect(restarted.retarget);
    try testing.expect(controller.isPlaying());
    try testing.expect(!controller.isPaused());

    const tick = controller.tick(0.1);
    try testing.expect(!tick.completed);
    try testing.expectEqual(@as(u32, 1), tick.request.?.frame_index);
}

test "zero-frame and zero-speed streams have stable tick results" {
    var empty = PlaybackController.init();
    empty.configure(30.0, 0);
    empty.play();
    const empty_tick = empty.tick(0.1);
    try testing.expect(empty_tick.completed);
    try testing.expectEqual(@as(u32, 0), empty_tick.request.?.frame_index);
    try testing.expect(!empty.isPlaying());

    var stationary = PlaybackController.init();
    stationary.configure(30.0, 30);
    stationary.setPlaybackSpeed(0.0);
    _ = stationary.seek(0.5);
    stationary.play();
    const stationary_tick = stationary.tick(1.0);
    try testing.expect(!stationary_tick.completed);
    try testing.expect(!stationary_tick.looped);
    try testing.expect(stationary.isPlaying());
    try testing.expectEqual(@as(u32, 15), stationary_tick.request.?.frame_index);
    try testing.expectApproxEqAbs(@as(f64, 0.5), stationary.position(), 1e-9);
}

test "audio generation tracks discontinuities but preserves pause resume buffers" {
    var c = PlaybackController.init();
    try testing.expect(!c.audioEnabled());
    c.configure(10, 20);
    var generation = c.audioGeneration();
    c.play();
    try testing.expect(c.audioGeneration() != generation);
    try testing.expect(c.audioEnabled());
    generation = c.audioGeneration();
    _ = c.tick(0.1);
    c.pause();
    try testing.expect(!c.audioEnabled());
    try testing.expectEqual(generation, c.audioGeneration());
    c.play();
    try testing.expect(c.audioEnabled());
    try testing.expectEqual(generation, c.audioGeneration());
    c.setPaused(true);
    c.setPaused(false);
    try testing.expectEqual(generation, c.audioGeneration());
    _ = c.seek(0.5);
    try testing.expect(c.audioGeneration() != generation);
    generation = c.audioGeneration();
    _ = c.stepFrame(1);
    try testing.expect(c.audioGeneration() != generation);
    try testing.expect(!c.audioEnabled());
    generation = c.audioGeneration();
    _ = c.restart();
    try testing.expect(c.audioEnabled());
    try testing.expect(c.audioGeneration() != generation);
    generation = c.audioGeneration();
    _ = c.stop();
    try testing.expect(!c.audioEnabled());
    try testing.expect(c.audioGeneration() != generation);
    generation = c.audioGeneration();
    c.resetStream();
    try testing.expect(c.audioGeneration() != generation);
    const pending_copy = c;
    try testing.expectEqual(c.audioGeneration(), pending_copy.audioGeneration());
}

test "audio mute speed policy and loop generations follow the authoritative clock" {
    var c = PlaybackController.init();
    c.configure(10, 20);
    c.play();
    for ([_]f64{ -1, -0.5, 0, 0.5, 2, 1 }) |speed| {
        const generation = c.audioGeneration();
        c.setPlaybackSpeed(speed);
        try testing.expect(c.audioGeneration() != generation);
        try testing.expectEqual(speed == 1, c.audioEnabled());
        const unchanged = c.audioGeneration();
        c.setPlaybackSpeed(speed);
        try testing.expectEqual(unchanged, c.audioGeneration());
    }
    c.setLoop(true);
    _ = c.seek(1.9);
    var generation = c.audioGeneration();
    try testing.expect(c.tick(0.2).looped);
    try testing.expect(c.audioGeneration() != generation);
    c.setPlaybackSpeed(-1);
    generation = c.audioGeneration();
    try testing.expect(c.tick(0.2).looped);
    try testing.expect(c.audioGeneration() != generation);
    try testing.expect(!c.audioEnabled());
    c.setLoop(false);
    c.setPlaybackSpeed(1);
    _ = c.tick(10);
    try testing.expect(!c.audioEnabled());
    generation = c.audioGeneration();
    c.play();
    try testing.expect(c.audioGeneration() != generation);
}

test "extreme frame steps saturate before clamping and invalidate audio" {
    var controller = PlaybackController.init();
    controller.configure(30, 300);
    controller.play();
    _ = controller.seek(1);
    var generation = controller.audioGeneration();
    const last = controller.stepFrame(std.math.maxInt(i64)).?;
    try testing.expectEqual(@as(u32, 299), last.frame_index);
    try testing.expect(controller.audioGeneration() != generation);
    try testing.expect(!controller.audioEnabled());
    generation = controller.audioGeneration();
    const first = controller.stepFrame(std.math.minInt(i64)).?;
    try testing.expectEqual(@as(u32, 0), first.frame_index);
    try testing.expect(controller.audioGeneration() != generation);
}

test "nonfinite controls cannot poison the authoritative audio clock" {
    var controller = PlaybackController.init();
    controller.configure(30, 300);
    controller.play();
    _ = controller.seek(1);
    _ = controller.seek(std.math.nan(f64));
    try testing.expectEqual(@as(f64, 1), controller.position());
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |value| {
        controller.setPlaybackSpeed(value);
        try testing.expectEqual(@as(f64, 1), controller.playbackSpeed());
        try testing.expect(controller.audioEnabled());
        _ = controller.tick(value);
        try testing.expectEqual(@as(f64, 1), controller.position());
    }
    controller.setLoop(true);
    controller.setPlaybackSpeed(std.math.floatMax(f64));
    _ = controller.tick(2);
    try testing.expectEqual(@as(f64, 1), controller.position());
}
