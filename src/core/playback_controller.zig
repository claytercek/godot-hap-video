//! PlaybackController is the authoritative, Godot-free playback clock and
//! policy for both the stock VideoStreamPlayer adapter and HapPlayer.

pub const PlaybackController = @This();

pub const FrameRequest = struct {
    frame_index: u32,
    forward: bool,
    retarget: bool,
};

pub const TickResult = struct {
    request: ?FrameRequest = null,
    looped: bool = false,
    completed: bool = false,
};

frame_rate: f64 = 0.0,
frame_count: u32 = 0,
duration_seconds: f64 = 0.0,
configured: bool = false,
current_position: f64 = 0.0,
playing: bool = false,
paused: bool = false,
loop: bool = false,
playback_speed: f64 = 1.0,
needs_retarget: bool = true,
last_direction_forward: bool = true,
// Scalar invalidation token only: controllers remain resource-free/copyable.
audio_generation: u64 = 0,

pub fn init() PlaybackController {
    return .{};
}

pub fn configure(self: *PlaybackController, frame_rate: f64, frame_count: u32) void {
    self.invalidateAudio();
    self.frame_rate = frame_rate;
    self.frame_count = frame_count;
    self.duration_seconds = if (frame_rate > 0.0)
        @as(f64, @floatFromInt(frame_count)) / frame_rate
    else
        0.0;
    self.configured = true;
    self.current_position = @min(self.current_position, self.duration_seconds);
    self.needs_retarget = true;
}

/// Reset stream-derived state while preserving caller-selected playback
/// policy such as loop and playback speed.
pub fn resetStream(self: *PlaybackController) void {
    const loop = self.loop;
    const speed = self.playback_speed;
    const generation = self.audio_generation +% 1;
    self.* = .{
        .loop = loop,
        .playback_speed = speed,
        .audio_generation = generation,
    };
}

pub fn play(self: *PlaybackController) void {
    if (!self.playing) self.invalidateAudio();
    self.playing = true;
    self.paused = false;
    self.needs_retarget = true;
}

pub fn pause(self: *PlaybackController) void {
    self.paused = true;
}

pub fn setPaused(self: *PlaybackController, value: bool) void {
    self.paused = value;
}

/// Start the stock-player path from the beginning rather than resuming.
pub fn restart(self: *PlaybackController) FrameRequest {
    self.invalidateAudio();
    self.current_position = 0.0;
    self.playing = true;
    self.paused = false;
    self.needs_retarget = true;
    return self.takeFrameRequest(true);
}

pub fn stop(self: *PlaybackController) FrameRequest {
    self.invalidateAudio();
    self.playing = false;
    self.paused = false;
    self.current_position = 0.0;
    self.needs_retarget = true;
    return self.takeFrameRequest(true);
}

pub fn seek(self: *PlaybackController, requested_position: f64) FrameRequest {
    self.invalidateAudio();
    const target_position = if (std.math.isNan(requested_position)) self.current_position else requested_position;
    self.current_position = if (self.configured)
        std.math.clamp(target_position, 0.0, self.duration_seconds)
    else
        @max(0.0, target_position);
    self.needs_retarget = true;
    return self.takeFrameRequest(self.playback_speed >= 0.0);
}

pub fn stepFrame(self: *PlaybackController, offset: i64) ?FrameRequest {
    if (!self.configured or self.frame_count == 0) return null;
    self.invalidateAudio();
    if (self.playing and !self.paused) self.paused = true;

    const current: i64 = @intCast(self.frameFromTime(self.current_position));
    const last: i64 = @as(i64, @intCast(self.frame_count)) - 1;
    const target = std.math.clamp(current +| offset, 0, last);
    self.current_position = @as(f64, @floatFromInt(target)) / self.frame_rate;
    self.needs_retarget = true;
    return self.takeFrameRequest(offset >= 0);
}

pub fn isPlaying(self: *const PlaybackController) bool {
    return self.playing;
}

pub fn isPaused(self: *const PlaybackController) bool {
    return self.paused;
}

pub fn setLoop(self: *PlaybackController, enabled: bool) void {
    self.loop = enabled;
}

pub fn isLooping(self: *const PlaybackController) bool {
    return self.loop;
}

pub fn setPlaybackSpeed(self: *PlaybackController, speed: f64) void {
    if (!std.math.isFinite(speed)) return;
    if (speed != self.playback_speed) self.invalidateAudio();
    self.playback_speed = speed;
}

pub fn audioGeneration(self: *const PlaybackController) u64 {
    return self.audio_generation;
}

/// Only ordinary forward playback is audible. Pause/resume preserve queued
/// audio when there is no position discontinuity; the adapter pauses output.
pub fn audioEnabled(self: *const PlaybackController) bool {
    return self.playing and !self.paused and self.playback_speed == 1.0;
}

fn invalidateAudio(self: *PlaybackController) void {
    self.audio_generation +%= 1;
}

pub fn playbackSpeed(self: *const PlaybackController) f64 {
    return self.playback_speed;
}

pub fn duration(self: *const PlaybackController) f64 {
    return self.duration_seconds;
}

pub fn frameRate(self: *const PlaybackController) f64 {
    return self.frame_rate;
}

pub fn frameCount(self: *const PlaybackController) u32 {
    return self.frame_count;
}

pub fn currentFrame(self: *const PlaybackController) u32 {
    return self.frameFromTime(self.current_position);
}

pub fn directionForward(self: *const PlaybackController) bool {
    return self.playback_speed >= 0.0;
}

/// Snapshot the current target for an explicit present. `force_retarget`
/// marks discontinuities such as stream-open materialization.
pub fn frameRequest(self: *PlaybackController, force_retarget: bool) FrameRequest {
    self.needs_retarget = self.needs_retarget or force_retarget;
    return self.takeFrameRequest(self.directionForward());
}

pub fn position(self: *const PlaybackController) f64 {
    return self.current_position;
}

pub fn tick(self: *PlaybackController, delta: f64) TickResult {
    if (!self.playing or self.paused or !std.math.isFinite(delta)) return .{};

    const forward = self.playback_speed >= 0.0;
    const next_position = self.current_position + self.playback_speed * delta;
    // Invalid controls and finite products that overflow must not become a
    // NaN after loop modulo, then escape as the audio adapter's clock.
    if (!std.math.isFinite(next_position)) return .{};
    self.current_position = next_position;

    var result: TickResult = .{};
    if (forward and self.current_position >= self.duration_seconds) {
        if (self.loop and self.duration_seconds > 0.0) {
            self.current_position = @mod(self.current_position, self.duration_seconds);
            self.needs_retarget = true;
            self.invalidateAudio();
            result.looped = true;
        } else {
            self.current_position = self.duration_seconds;
            self.playing = false;
            result.completed = true;
        }
    } else if (!forward and self.current_position <= 0.0) {
        if (self.loop and self.duration_seconds > 0.0) {
            self.current_position = self.duration_seconds - @mod(-self.current_position, self.duration_seconds);
            self.needs_retarget = true;
            self.invalidateAudio();
            result.looped = true;
        } else {
            self.current_position = 0.0;
            self.playing = false;
            result.completed = true;
        }
    }

    result.request = self.takeFrameRequest(forward);
    return result;
}

fn takeFrameRequest(self: *PlaybackController, forward: bool) FrameRequest {
    const retarget = self.needs_retarget or forward != self.last_direction_forward;
    self.needs_retarget = false;
    self.last_direction_forward = forward;
    return .{
        .frame_index = self.frameFromTime(self.current_position),
        .forward = forward,
        .retarget = retarget,
    };
}

fn frameFromTime(self: *const PlaybackController, time: f64) u32 {
    var frame: u32 = if (self.frame_rate > 0.0)
        @intFromFloat(@max(0.0, time * self.frame_rate))
    else
        0;
    if (self.frame_count > 0 and frame >= self.frame_count) frame = self.frame_count - 1;
    return frame;
}

pub const Controller = PlaybackController;

const std = @import("std");
