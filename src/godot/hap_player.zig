//! HapPlayer Control node. Owns the Godot-free PlaybackController and
//! drives the HapVideoStreamPlayback adapter.
//!
//! project/demo/hap_player_demo.gd exercises the GDScript API: stream, loop,
//! autoplay, opened, playback_completed, error_occurred, frame_count,
//! stream_position, frame_rate, playback_speed, paused, get_texture(),
//! play(), pause(), step_frame(n).
const HapPlayer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const Control = godot.class.Control;
const Texture2d = godot.class.Texture2d;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const Node = godot.class.Node;
const PropertyUsageFlags = godot.global.PropertyUsageFlags;

// Share build.zig's core module instance with the rest of the extension.
const core = @import("core");
const PlaybackController = core.playback_controller.PlaybackController;

const HapVideoStream = @import("hap_video_stream.zig");
const HapVideoStreamPlayback = @import("hap_video_stream_playback.zig");
const ref = @import("ref.zig");
const audio_output = @import("audio_output.zig");

const log = std.log.scoped(.hap_player);

/// Read-only metadata: omit storage and editor visibility.
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

    // Register bool accessors explicitly: Godot uses is_x()/set_x(), but
    // gdzig only auto-detects getX/setX. Bind each property by method pointer.
    const is_loop = class.createMethod("is_loop", .auto);
    const set_loop = class.createMethod("set_loop", .auto);
    class.addProperty("loop", .{ .getter = .{ .method = is_loop }, .setter = .{ .method = set_loop } });

    class.addProperty("playback_speed", .auto);
    class.addProperty("bus", .auto);
    class.addProperty("volume_db", .{ .hint = .property_hint_range, .hint_string = String.fromLatin1("-80,24,0.01,suffix:dB") });

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
    class.addProperty("has_audio", .{ .setter = .none, .usage = read_only_usage });
    class.addProperty("audio_sample_rate", .{ .setter = .none, .usage = read_only_usage });
    class.addProperty("audio_channels", .{ .setter = .none, .usage = read_only_usage });

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

// Publish a replacement only after async open and GPU setup succeed.
// Its separate controller keeps setup from changing the active clock.
pending_stream: ?*HapVideoStream = null,
pending_playback: ?*HapVideoStreamPlayback = null,
pending_controller: PlaybackController = .init(),
autoplay: bool = false,

error_fired: bool = false,
audio: audio_output.GeneratorOutput = .{},
audio_tree_enabled: bool = false,

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
    self.audio.deinit();
    self.base.destroy();
    allocator.destroy(self);
}

pub fn setStream(self: *HapPlayer, new_stream: ?*HapVideoStream) void {
    // A get/set round trip may return the stored resource. Keep its adapter
    // and owning reference intact when the resource is unchanged.
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

    // Keep one pending candidate. Cancellation may wait for its running
    // stream job; the active playback pair stays unchanged.
    self.clearPendingStream();

    self.pending_controller = self.controller;
    self.pending_controller.resetStream();

    // Object arguments are borrowed for the call. Retain an independent
    // reference because pending_stream outlives this setter.
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
    self.audio.stop();
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

/// Route controls to the opening replacement while preserving active state
/// and texture. Promote those controls on success; keep the active controller
/// authoritative on failure.
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
    self.reconcileAudio();
}

pub fn getBus(self: *HapPlayer) StringName {
    return self.audio.getBus();
}
pub fn setBus(self: *HapPlayer, value: StringName) void {
    self.audio.setBus(value);
}
pub fn getVolumeDb(self: *HapPlayer) f64 {
    return self.audio.volume_db;
}
pub fn setVolumeDb(self: *HapPlayer, value: f64) void {
    self.audio.setVolumeDb(value);
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
    self.reconcileAudio();
}

pub fn isPaused(self: *HapPlayer) bool {
    return self.selectedController().isPaused();
}
pub fn setPaused(self: *HapPlayer, value: bool) void {
    self.selectedController().setPaused(value);
    self.reconcileAudio();
}

/// Start or resume at stream_position, including after pause/completion.
/// playback_speed's sign sets the direction; position stays unchanged.
pub fn play(self: *HapPlayer) void {
    self.selectedController().play();
    self.reconcileAudio();
}

/// Pause without changing the texture or stream_position. Same as set_paused(true).
pub fn pause(self: *HapPlayer) void {
    self.selectedController().pause();
    self.reconcileAudio();
}

/// Halt playback and reset stream_position to 0.
pub fn stop(self: *HapPlayer) void {
    const request = self.selectedController().stop();
    if (self.selectedPlayback()) |pb| {
        if (pb.isReady()) pb.advance(request);
    }
    self.reconcileAudio();
}

/// Auto-pause, then priority-seek by n frames; negative n steps backward.
/// Use i64 because gdzig bound methods require it and GDScript int is 64-bit.
pub fn stepFrame(self: *HapPlayer, n: i64) void {
    const pb = self.selectedPlayback() orelse return;
    if (!pb.isReady()) return;
    if (self.selectedController().stepFrame(n)) |request| pb.advance(request);
    self.reconcileAudio();
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

pub fn getHasAudio(self: *HapPlayer) bool {
    return if (self.selectedPlayback()) |pb| pb.audioInfo() != null else false;
}
pub fn getAudioSampleRate(self: *HapPlayer) i64 {
    const pb = self.selectedPlayback() orelse return 0;
    return if (pb.audioInfo()) |info| info.sample_rate else 0;
}
pub fn getAudioChannels(self: *HapPlayer) i64 {
    const pb = self.selectedPlayback() orelse return 0;
    return if (pb.audioInfo()) |info| info.channels else 0;
}

fn reconcileAudio(self: *HapPlayer) void {
    const pb = self.playback orelse {
        self.audio.stop();
        return;
    };
    self.audio.reconcile(.upcast(self.base), &pb.scheduler, &self.controller, self.audio_tree_enabled and self.base.isInsideTree() and self.base.canProcess() and pb.isReady());
}

pub fn _notification(self: *HapPlayer, what: i32, _: bool) void {
    switch (what) {
        Node.NOTIFICATION_ENTER_TREE => self.audio_tree_enabled = true,
        Node.NOTIFICATION_EXIT_TREE => {
            self.audio_tree_enabled = false;
            self.audio.stop();
        },
        Node.NOTIFICATION_PAUSED, Node.NOTIFICATION_DISABLED => self.audio.stop(),
        Node.NOTIFICATION_UNPAUSED, Node.NOTIFICATION_ENABLED => self.reconcileAudio(),
        else => {},
    }
}

pub fn _ready(self: *HapPlayer) void {
    self.base.setProcess(true);
    self.reconcileAudio();
}

pub fn _process(self: *HapPlayer, delta: f64) void {
    self.audio.tickDrain();
    self.pollPendingStream();

    const pb = self.playback orelse return;

    const was_ready = pb.isReady();
    const now_ready = pb.pollReady();

    if (now_ready and !was_ready) {
        // Request the current (possibly pre-set) frame before opened
        // handlers can query getTexture() or call play().
        pb.advance(self.controller.frameRequest(true));

        self.base.emit(Opened, .{}) catch {};
        if (self.autoplay) self.play();
    }

    if (pb.hasFailed()) {
        self.audio.stop();
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
    if (step.completed) self.audio.completed();
    self.reconcileAudio();

    if (step.looped) self.base.emit(PlaybackLooped, .{}) catch {};
    if (step.completed) self.base.emit(PlaybackCompleted, .{}) catch {};
}

/// Poll pending open and GPU setup. Release only the candidate on failure.
/// On success, swap the pair and rebind to the stable active-controller address.
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

    self.reconcileAudio();

    self.base.emit(Opened, .{}) catch {};
    if (self.autoplay) self.play();
}
