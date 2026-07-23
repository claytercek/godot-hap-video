//! hap_player.zig — the HapPlayer Control node.
//!
//! Power-user layer: a Control node that owns the authoritative Godot-free
//! PlaybackController and drives a thin HapVideoStreamPlayback adapter.
//!
//! The GDScript surface (methods/properties/signals) is exercised
//! end-to-end by project/demo/hap_player_demo.gd: stream, loop, autoplay, opened,
//! playback_completed, error_occurred, frame_count, stream_position,
//! frame_rate, playback_speed, paused, get_texture(), play(), pause(),
//! step_frame(n).
//!
const HapPlayer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const Control = godot.class.Control;
const Texture2d = godot.class.Texture2d;
const String = godot.builtin.String;
const PropertyUsageFlags = godot.global.PropertyUsageFlags;

// Core types come through the "core" named module (build.zig-wired) so they
// match the module instance the rest of the extension hands around.
const core = @import("core");
const PlaybackController = core.playback_controller.PlaybackController;

const HapVideoStream = @import("hap_video_stream.zig");
const HapVideoStreamPlayback = @import("hap_video_stream_playback.zig");
const ref = @import("ref.zig");

const log = std.log.scoped(.hap_player);

/// Usage for the read-only metadata properties below (frame_rate, width,
/// height, duration, frame_count). Read-only: storage and editor visibility
/// both off.
const read_only_usage: PropertyUsageFlags = .{
    .property_usage_storage = false,
    .property_usage_editor = false,
    .property_usage_read_only = true,
};

pub fn register(r: *Registry) void {
    const class = r.createClass(HapPlayer, r.allocator, .auto);

    class.addMethod("play", .auto);
    class.addMethod("pause", .auto);
    class.addMethod("stop", .auto);
    class.addMethod("step_frame", .auto);
    class.addMethod("get_texture", .auto);

    class.addProperty("stream", .{
        .hint = .property_hint_resource_type,
        .hint_string = String.fromLatin1("HapVideoStream"),
    });

    // "loop"/"paused"/"autoplay" use is_x()/set_x() naming (Godot's bool
    // convention), which gdzig's property auto-detect (getX/setX only)
    // can't find on its own -- register the methods explicitly and wire
    // them to the property by pointer.
    const is_loop = class.createMethod("is_loop", .auto);
    const set_loop = class.createMethod("set_loop", .auto);
    class.addProperty("loop", .{ .getter = .{ .method = is_loop }, .setter = .{ .method = set_loop } });

    class.addProperty("playback_speed", .auto);

    const is_autoplay = class.createMethod("is_autoplay", .auto);
    const set_autoplay = class.createMethod("set_autoplay", .auto);
    class.addProperty("autoplay", .{ .getter = .{ .method = is_autoplay }, .setter = .{ .method = set_autoplay } });

    class.addProperty("stream_position", .auto);

    const is_paused = class.createMethod("is_paused", .auto);
    const set_paused = class.createMethod("set_paused", .auto);
    class.addProperty("paused", .{ .getter = .{ .method = is_paused }, .setter = .{ .method = set_paused } });

    // Read-only metadata, valid after `opened` -- no setter.
    class.addProperty("frame_rate", .{ .setter = .none, .usage = read_only_usage });
    class.addProperty("width", .{ .setter = .none, .usage = read_only_usage });
    class.addProperty("height", .{ .setter = .none, .usage = read_only_usage });
    class.addProperty("duration", .{ .setter = .none, .usage = read_only_usage });
    class.addProperty("frame_count", .{ .setter = .none, .usage = read_only_usage });

    class.addSignal(Opened);
    class.addSignal(PlaybackCompleted);
    class.addSignal(PlaybackLooped);
    class.addSignal(ErrorOccurred);
}

pub fn unregister(r: *Registry) void {
    r.removeClass(HapPlayer);
}

pub const Opened = struct {};
pub const PlaybackCompleted = struct {};
pub const PlaybackLooped = struct {};
pub const ErrorOccurred = struct { message: String };

allocator: Allocator,
base: *Control,

stream: ?*HapVideoStream = null,
playback: ?*HapVideoStreamPlayback = null,
controller: PlaybackController = .init(),

// A replacement remains private until its asynchronous open and GPU setup
// both succeed. It uses a separate controller so candidate initialization
// cannot reconfigure the still-active playback's clock.
pending_stream: ?*HapVideoStream = null,
pending_playback: ?*HapVideoStreamPlayback = null,
pending_controller: PlaybackController = .init(),
autoplay: bool = false,

error_fired: bool = false,

pub fn create(allocator: *Allocator) !*HapPlayer {
    const self = try allocator.create(HapPlayer);
    self.* = .{
        .allocator = allocator.*,
        .base = .init(),
    };
    self.base.setInstance(HapPlayer, self);
    return self;
}

pub fn destroy(self: *HapPlayer, allocator: *Allocator) void {
    self.clearPendingStream();
    self.clearStream();
    self.base.destroy();
    allocator.destroy(self);
}

pub fn setStream(self: *HapPlayer, new_stream: ?*HapVideoStream) void {
    // A property get/set round trip can pass our own stored resource back to
    // us. Keep the active adapter intact rather than releasing the only
    // persistent reference before we retain the replacement.
    if (new_stream != null and self.pending_stream == new_stream) return;
    if (self.stream == new_stream) {
        self.clearPendingStream();
        return;
    }

    const stream = new_stream orelse {
        self.clearPendingStream();
        self.clearStream();
        return;
    };

    // There can be only one unpublished candidate. Cancelling an older open
    // may wait for its already-running stream job, but never disturbs the
    // active playback pair.
    self.clearPendingStream();

    self.pending_controller = self.controller;
    self.pending_controller.resetStream();

    // Take our own persistent share: `new_stream` is a borrowed pointer
    // for the duration of this setter call only (matches every other
    // Object-typed method argument here), but we're storing it beyond
    // that, so we need an independent owning reference.
    _ = stream.base.reference();

    const pb = HapVideoStreamPlayback.createBorrowed(&self.allocator, &self.pending_controller) catch {
        ref.releaseAndDestroy(HapVideoStream, stream, &self.allocator);
        self.emitStreamError("Failed to create playback");
        return;
    };

    var file = stream.getFile();
    defer file.deinit();
    if (!pb.open(file)) {
        var buf: [1024]u8 = undefined;
        log.err("failed to open stream: {s}", .{file.toUtf8Buf(&buf)});
        ref.releaseAndDestroy(HapVideoStreamPlayback, pb, &self.allocator);
        ref.releaseAndDestroy(HapVideoStream, stream, &self.allocator);
        self.emitStreamError("Failed to start stream open");
        return;
    }

    self.pending_playback = pb;
    self.pending_stream = stream;
}

fn clearPendingStream(self: *HapPlayer) void {
    if (self.pending_playback) |pb| {
        self.pending_playback = null;
        ref.releaseAndDestroy(HapVideoStreamPlayback, pb, &self.allocator);
    }
    if (self.pending_stream) |stream| {
        self.pending_stream = null;
        ref.releaseAndDestroy(HapVideoStream, stream, &self.allocator);
    }
    self.pending_controller = .init();
}

fn clearStream(self: *HapPlayer) void {
    if (self.playback) |pb| {
        self.playback = null;
        ref.releaseAndDestroy(HapVideoStreamPlayback, pb, &self.allocator);
    }
    if (self.stream) |stream| {
        self.stream = null;
        ref.releaseAndDestroy(HapVideoStream, stream, &self.allocator);
    }
    self.error_fired = false;
    self.controller.resetStream();
}

fn emitStreamError(self: *HapPlayer, text: []const u8) void {
    var message = String.fromLatin1(text);
    defer message.deinit();
    self.base.emit(ErrorOccurred, .{ .message = message }) catch {};
}

pub fn getStream(self: *HapPlayer) ?*HapVideoStream {
    return self.pending_stream orelse self.stream;
}

/// Public controls target the selected replacement while it is opening. The
/// old playback remains a visual placeholder and keeps its existing state;
/// if the candidate succeeds these pre-open controls are promoted with it,
/// and if it fails the untouched active state becomes authoritative again.
fn selectedController(self: *HapPlayer) *PlaybackController {
    return if (self.pending_stream != null) &self.pending_controller else &self.controller;
}

fn selectedPlayback(self: *HapPlayer) ?*HapVideoStreamPlayback {
    return self.pending_playback orelse self.playback;
}

pub fn isLoop(self: *HapPlayer) bool {
    return self.selectedController().isLooping();
}
pub fn setLoop(self: *HapPlayer, value: bool) void {
    self.selectedController().setLoop(value);
}

pub fn getPlaybackSpeed(self: *HapPlayer) f64 {
    return self.selectedController().playbackSpeed();
}
pub fn setPlaybackSpeed(self: *HapPlayer, value: f64) void {
    self.selectedController().setPlaybackSpeed(value);
}

pub fn isAutoplay(self: *HapPlayer) bool {
    return self.autoplay;
}
pub fn setAutoplay(self: *HapPlayer, value: bool) void {
    self.autoplay = value;
}

pub fn getStreamPosition(self: *HapPlayer) f64 {
    return self.selectedController().position();
}
pub fn setStreamPosition(self: *HapPlayer, position: f64) void {
    const request = self.selectedController().seek(position);
    if (self.selectedPlayback()) |pb| {
        if (pb.isReady()) pb.advance(request);
    }
}

pub fn isPaused(self: *HapPlayer) bool {
    return self.selectedController().isPaused();
}
pub fn setPaused(self: *HapPlayer, value: bool) void {
    self.selectedController().setPaused(value);
}

/// Start (or resume) playback from the current stream_position, in the
/// direction implied by playback_speed's sign. Does not reset position --
/// resuming after pause/completion continues from where playback left off.
pub fn play(self: *HapPlayer) void {
    self.selectedController().play();
}

/// Freeze the pump in place; texture and stream_position are retained.
/// Equivalent to set_paused(true).
pub fn pause(self: *HapPlayer) void {
    self.selectedController().pause();
}

/// Halt playback and reset stream_position to 0.
pub fn stop(self: *HapPlayer) void {
    const request = self.selectedController().stop();
    if (self.selectedPlayback()) |pb| {
        if (pb.isReady()) pb.advance(request);
    }
}

/// Pause-gated: auto-pauses if playing, then moves exactly n frames (n may
/// be negative) via a priority seek. `n` is `i64`: gdzig bound-method
/// marshalling supports only i64 integers; GDScript int is 64-bit anyway.
pub fn stepFrame(self: *HapPlayer, n: i64) void {
    const pb = self.playback orelse return;
    if (!pb.isReady()) return;
    if (self.controller.stepFrame(n)) |request| pb.advance(request);
}

pub fn getTexture(self: *HapPlayer) ?*Texture2d {
    const pb = self.playback orelse return null;
    return pb.texture();
}

// Read-only metadata, valid after the `opened` signal. `i64` return types
// for the same reason as step_frame's `n` above.
pub fn getFrameRate(self: *HapPlayer) f64 {
    return if (self.selectedPlayback()) |pb| pb.getFrameRate() else 0.0;
}
pub fn getWidth(self: *HapPlayer) i64 {
    return if (self.selectedPlayback()) |pb| @intCast(pb.getWidth()) else 0;
}
pub fn getHeight(self: *HapPlayer) i64 {
    return if (self.selectedPlayback()) |pb| @intCast(pb.getHeight()) else 0;
}
pub fn getDuration(self: *HapPlayer) f64 {
    return self.selectedController().duration();
}
pub fn getFrameCount(self: *HapPlayer) i64 {
    return if (self.selectedPlayback()) |pb| @intCast(pb.getFrameCount()) else 0;
}

pub fn _ready(self: *HapPlayer) void {
    self.base.setProcess(true);
}

pub fn _process(self: *HapPlayer, delta: f64) void {
    self.pollPendingStream();

    const pb = self.playback orelse return;

    const was_ready = pb.isReady();
    const now_ready = pb.pollReady();

    if (now_ready and !was_ready) {
        // Materialize the current (possibly pre-set) position's frame
        // immediately, so getTexture() is valid the instant `opened` fires
        // -- before any handler calls play().
        pb.advance(self.controller.frameRequest(true));

        self.base.emit(Opened, .{}) catch {};
        if (self.autoplay) self.play();
    }

    if (pb.hasFailed()) {
        if (!self.error_fired) {
            self.error_fired = true;
            var message = pb.getError();
            defer message.deinit();
            self.base.emit(ErrorOccurred, .{ .message = message }) catch {};
        }
        return;
    }

    if (!now_ready) return;

    const step = pb.updateController(delta);

    if (step.looped) self.base.emit(PlaybackLooped, .{}) catch {};
    if (step.completed) self.base.emit(PlaybackCompleted, .{}) catch {};
}

/// Advance an unpublished replacement through async open and GPU setup. A
/// failure releases only the candidate; success swaps the complete pair and
/// rebinds its controller to the player's stable active-controller address.
fn pollPendingStream(self: *HapPlayer) void {
    const pb = self.pending_playback orelse return;

    const ready = pb.pollReady();
    if (pb.hasFailed()) {
        var message = pb.getError();
        defer message.deinit();
        self.clearPendingStream();
        self.base.emit(ErrorOccurred, .{ .message = message }) catch {};
        return;
    }
    if (!ready) return;

    const stream = self.pending_stream.?;
    const controller = self.pending_controller;
    self.pending_playback = null;
    self.pending_stream = null;
    self.pending_controller = .init();

    self.clearStream();
    self.controller = controller;
    pb.rebindController(&self.controller);
    self.playback = pb;
    self.stream = stream;
    self.error_fired = false;

    self.base.emit(Opened, .{}) catch {};
    if (self.autoplay) self.play();
}
