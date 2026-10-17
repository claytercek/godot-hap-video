//! hap_video_stream_playback.zig — the HapVideoStreamPlayback position engine.
//!
//! Thin Godot adapter over the authoritative core PlaybackController. It owns
//! the async decode and GPU-present pipelines, but playback clock/policy lives
//! in the controller. HapPlayer lends its controller to this adapter; the
//! stock VideoStreamPlayer path asks the adapter to own one itself.
//!
//! open() kicks off an asynchronous open on the shared outer pool and
//! returns immediately; nothing here blocks the main thread. Until the
//! async open completes, playback virtuals report harmless defaults.
//!
//! destroy() blocks (waitForStreamIdle) until any in-flight/queued job for
//! its stream -- including the open job -- has fully completed.
//!
//! Power-user layer (HapPlayer) integration surface: HapPlayer owns this
//! object directly rather than through a VideoStreamPlayer, so the engine
//! never calls the virtuals below automatically; HapPlayer drives them from
//! its own _process() pump instead via the plain (non-virtual-dispatch)
//! functions below rather than through engine-dispatched virtuals.

const HapVideoStreamPlayback = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const VideoStreamPlayback = godot.class.VideoStreamPlayback;
const Texture2d = godot.class.Texture2d;
const RenderingServer = godot.class.RenderingServer;
const ProjectSettings = godot.class.ProjectSettings;
const String = godot.builtin.String;

// Core types come through the "core" named module (build.zig-wired) so they
// match the module instance the rest of the extension hands around.
const core = @import("core");
const DecodeScheduler = core.decode_scheduler.DecodeScheduler;
const OpenError = core.decode_scheduler.OpenError;
const VideoTrackInfo = core.hap_frame.VideoTrackInfo;
const PlaybackController = core.playback_controller.PlaybackController;
const FrameRequest = core.playback_controller.FrameRequest;
const TickResult = core.playback_controller.TickResult;

const gpu_presenter_mod = @import("gpu_presenter.zig");
const GpuPresenter = gpu_presenter_mod.GpuPresenter;
const audio_output = @import("audio_output.zig");
const AudioInfo = audio_output.AudioInfo;
const PackedFloat32Array = godot.builtin.PackedFloat32Array;

const log = std.log.scoped(.hap_video_stream_playback);

const GpuError = enum { initialize, present };

pub fn register(r: *Registry) void {
    // Abstract (non-instantiable from GDScript): playback is created only
    // through the native createOwned()/createBorrowed() paths, which claim
    // the initial reference. HapVideoStream also supports ClassDB creation
    // and must adapt its initial reference claim to the Godot version.
    r.addClass(HapVideoStreamPlayback, r.allocator, .{ .is_abstract = true });
}

pub fn unregister(r: *Registry) void {
    r.removeClass(HapVideoStreamPlayback);
}

allocator: Allocator,
base: *VideoStreamPlayback,

// Async decode pipeline (Godot-free core).
scheduler: DecodeScheduler,

// Exactly one controller is authoritative. The stock path sets
// owns_controller; HapPlayer keeps ownership and lends a stable pointer.
controller: *PlaybackController,
owns_controller: bool = false,

// Track info, valid once the scheduler reports `.open`.
track: VideoTrackInfo = .{},
failure_logged: bool = false,

// Becomes true once track has been captured and GPU resources created for
// it (on the first pollReady() after the scheduler reports `.open`).
playback_initialized: bool = false,
gpu_error: ?GpuError = null,

// GPU presenter for RD-based texture upload + compute.
gpu_presenter: GpuPresenter,

// Captured before stock _instantiatePlayback returns. Godot caches channels
// and mix rate during set_stream, before its first _update call.
audio_info: ?AudioInfo = null,
audio_warning_logged: bool = false,
audio_track_enabled: bool = true,
audio_track_warning_logged: bool = false,
audio_mix_failed: bool = false,
audio_cursor: audio_output.Cursor = .{},
audio_staging: ?PackedFloat32Array = null,
audio_drain_deadline_usec: u64 = 0,
// Stock VideoStreamPlayer queries these virtuals on its audio thread. Never
// dereference the main-thread controller, scheduler, or GPU state there.
transport_snapshot: std.atomic.Value(u8) = .init(0),

/// Constructor required by class registration. Internal callers should use
/// createOwned() or createBorrowed() to make ownership explicit.
pub fn create(allocator: *Allocator) !*HapVideoStreamPlayback {
    return createOwned(allocator);
}

pub fn createOwned(allocator: *Allocator) !*HapVideoStreamPlayback {
    const controller = try allocator.create(PlaybackController);
    errdefer allocator.destroy(controller);
    controller.* = .init();

    const self = try createBorrowed(allocator, controller);
    self.owns_controller = true;
    return self;
}

pub fn createBorrowed(allocator: *Allocator, controller: *PlaybackController) !*HapVideoStreamPlayback {
    var scheduler = try DecodeScheduler.init(allocator.*);
    errdefer scheduler.deinit();
    const self = try allocator.create(HapVideoStreamPlayback);
    self.* = .{
        .allocator = allocator.*,
        // Claims RefCounted's initial reference: this is the sole,
        // internal creation path (the class is abstract, so there is no
        // GDScript `.new()` to also claim it -- see register()). The engine
        // adopts this reference when _instantiatePlayback hands it back.
        .base = .init(),
        .scheduler = scheduler,
        .controller = controller,
        .gpu_presenter = .init(),
    };
    self.base.setInstance(HapVideoStreamPlayback, self);
    return self;
}

pub fn destroy(self: *HapVideoStreamPlayback, allocator: *Allocator) void {
    // Teardown order is not load-bearing: the scheduler's worker threads
    // never touch the presenter's GPU resources (decoded frames cross
    // between them only through the SPSC queue, drained on the main thread),
    // and the presenter owns its RD/RS resources independently of the
    // scheduler. Freeing the presenter first is simply grouped for
    // readability.
    self.gpu_presenter.deinit();
    if (self.audio_staging) |*buffer| buffer.deinit();
    self.scheduler.deinit();
    if (self.owns_controller) self.allocator.destroy(self.controller);
    self.base.destroy();
    allocator.destroy(self);
}

/// Rebind a borrowed controller during HapPlayer's pending-to-active
/// promotion. The scheduler and presenter never retain this pointer.
pub fn rebindController(self: *HapVideoStreamPlayback, controller: *PlaybackController) void {
    self.controller = controller;
}

// -----------------------------------------------------------------------
// Open (async)
// -----------------------------------------------------------------------

/// Begin an asynchronous open of `p_path`. Returns true once the job has
/// been handed to the outer pool (never blocks). `p_path` is borrowed for
/// the duration of this call only.
pub fn open(self: *HapVideoStreamPlayback, p_path: String) bool {
    if (p_path.isEmpty()) {
        log.err("empty path", .{});
        return false;
    }

    // The core demuxer mmaps the file directly, so it needs a real
    // filesystem path -- res:// and user:// are Godot virtual-filesystem
    // prefixes FileAccess resolves internally, but mmap() has no idea
    // about them. Absolute paths pass through globalizePath() unchanged.
    var real_path = ProjectSettings.globalizePath(p_path);
    defer real_path.deinit();
    var buf: [4096]u8 = undefined;
    const utf8 = real_path.toUtf8Buf(&buf);

    // openAsync() only hands the mmap+parse job to the outer pool and
    // returns immediately -- nothing above blocks the main thread.
    self.scheduler.openAsync(utf8) catch return false;
    return true;
}

/// One-time setup once the async open has completed: captures metadata,
/// computes duration, and initializes GPU resources.
fn initializeAfterOpen(self: *HapVideoStreamPlayback) void {
    self.track = self.scheduler.trackInfo();
    self.audio_info = self.scheduler.audioInfo();
    self.warnAudioOnce();

    self.controller.configure(self.track.frame_rate, self.track.frame_count);

    const variant = core.hap_frame.classify(self.track.fourcc) orelse {
        const fourcc = self.track.fourcc.toString();
        log.err("demuxer returned an unrecognized Hap variant: {s}", .{fourcc});
        self.gpu_error = .initialize;
        return;
    };
    const rd = RenderingServer.getRenderingDevice();
    if (!self.gpu_presenter.initialize(rd, @intCast(self.track.width), @intCast(self.track.height), variant)) {
        log.err("Failed to initialize GPU presenter", .{});
        self.gpu_error = .initialize;
        return;
    }

    self.playback_initialized = true;
    self.advance(self.controller.frameRequest(true));
}

/// Block until the async open settles (ready or failed). Used by the
/// drop-in layer only: the stock VideoStreamPlayer caches the display
/// texture when the stream is set and expects it to already have its real
/// size, so that path needs synchronous-open semantics. HapPlayer never
/// calls this. Returns whether the open succeeded.
///
/// The moov parse is milliseconds even for multi-gigabyte files; the bound
/// only guards against a pathological stall (e.g. a dead network mount),
/// turning it into a clean open failure instead of hanging the main thread.
pub fn waitForOpen(self: *HapVideoStreamPlayback) bool {
    const max_wait_ms = 30000;
    var waited: u32 = 0;
    while (waited < max_wait_ms) : (waited += 1) {
        switch (self.scheduler.openStatus()) {
            .not_started, .failed => return false,
            .open => return true,
            .opening => sleepOneMs(),
        }
    }
    return false;
}

/// Sleep for one millisecond (best-effort; errors are ignored). Zig 0.16
/// routes blocking sleeps through std.Io rather than a plain
/// std.Thread.sleep; mirrors src/core/test_support.zig's sleepNs idiom
/// (that helper is test-only and not exported from core.zig, so this is a
/// small local duplicate rather than a cross-module reach-in).
fn sleepOneMs() void {
    const one_ms: std.Io.Clock.Duration = .{ .raw = .fromNanoseconds(std.time.ns_per_ms), .clock = .awake };
    one_ms.sleep(std.Io.Threaded.global_single_threaded.io()) catch {};
}

/// Poll for async-open + GPU-init completion, running initializeAfterOpen()
/// the first time it's ready. Safe to call every tick before open
/// completes; a no-op afterward. Returns isReady().
pub fn pollReady(self: *HapVideoStreamPlayback) bool {
    if (self.scheduler.openStatus() != .open) return false;
    if (!self.playback_initialized and self.gpu_error == null) self.initializeAfterOpen();
    return self.isReady();
}

/// True once metadata and the presented texture are valid (post async-open
/// + GPU init).
pub fn isReady(self: *const HapVideoStreamPlayback) bool {
    return self.playback_initialized and
        self.gpu_error == null and
        self.scheduler.decodeStatus() != .failed;
}

/// True once the async open or GPU init has failed permanently.
pub fn hasFailed(self: *const HapVideoStreamPlayback) bool {
    return self.scheduler.openStatus() == .failed or
        self.scheduler.decodeStatus() == .failed or
        self.gpu_error != null;
}

/// Human-readable error, valid once hasFailed() is true.
pub fn getError(self: *const HapVideoStreamPlayback) String {
    if (self.scheduler.openError()) |err| return self.formatOpenError(err);
    if (self.scheduler.decodeError()) |err| return switch (err) {
        error.SampleUnavailable => String.fromLatin1("Failed to read Hap frame sample"),
        error.InvalidFrame => String.fromLatin1("Failed to decode invalid Hap frame"),
        error.OutOfMemory => String.fromLatin1("Out of memory decoding Hap frame"),
    };
    if (self.gpu_error) |err| return switch (err) {
        .initialize => String.fromLatin1("Failed to initialize GPU presenter"),
        .present => String.fromLatin1("Failed to present Hap frame"),
    };
    return String.empty;
}

/// Render a typed open failure into a display string. UnsupportedHapVariant
/// is enriched with the offending fourcc the demuxer parked on the track
/// info before rejecting the file.
fn formatOpenError(self: *const HapVideoStreamPlayback, err: OpenError) String {
    return switch (err) {
        error.FileOpenFailed => String.fromLatin1("Failed to open file"),
        error.MalformedMp4 => String.fromLatin1("Failed to open/parse MOV file"),
        error.NoMoovBox => String.fromLatin1("No moov box found in MOV file"),
        error.NoHapTrack => String.fromLatin1("No Hap video track found in file"),
        error.ZeroSamples => String.fromLatin1("Hap video track has zero samples"),
        error.TooManySamples => String.fromLatin1("Sample count exceeds file size (broken file?)"),
        error.SamplesExceedFileSize => String.fromLatin1("Sample offset/size exceeds file size (broken file?)"),
        error.OutOfMemory => String.fromLatin1("Out of memory allocating sample cache"),
        error.UnsupportedHapVariant => blk: {
            const fourcc = self.scheduler.trackInfo().fourcc.toString();
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "Unsupported Hap variant ({s}) found in file \u{2014} only Hap1, Hap5, HapY, HapM, Hap7 are supported",
                .{fourcc},
            ) catch "Unsupported Hap variant found in file";
            break :blk String.fromUtf8(msg) catch String.fromLatin1(msg);
        },
    };
}

// Metadata, valid once isReady() is true.
pub fn getFrameRate(self: *const HapVideoStreamPlayback) f64 {
    return self.track.frame_rate;
}
pub fn getWidth(self: *const HapVideoStreamPlayback) i32 {
    return @intCast(self.track.width);
}
pub fn getHeight(self: *const HapVideoStreamPlayback) i32 {
    return @intCast(self.track.height);
}
pub fn getFrameCount(self: *const HapVideoStreamPlayback) i32 {
    return @intCast(self.track.frame_count);
}

pub fn audioInfo(self: *const HapVideoStreamPlayback) ?AudioInfo {
    return self.audio_info;
}

fn warnAudioOnce(self: *HapVideoStreamPlayback) void {
    if (self.audio_warning_logged) return;
    if (self.scheduler.audioWarning()) |warning| {
        log.warn("{s}; continuing video without audio", .{warning.message()});
        self.audio_warning_logged = true;
    }
}

fn publishTransport(self: *HapVideoStreamPlayback) void {
    if (self.hasFailed()) {
        self.failStockPlayback();
        return;
    }
    const playing = self.controller.isPlaying() or self.audio_drain_deadline_usec > 0;
    const paused = self.controller.isPaused() or self.audio_mix_failed;
    self.transport_snapshot.store(@as(u8, @intFromBool(playing)) | (@as(u8, @intFromBool(paused)) << 1), .release);
}

/// Main-thread PCM reads, capped at four 4096-frame batches. mixAudio returns
/// accepted FRAMES, not floats. Keep the cursor on partial acceptance and
/// abandon stale leftovers after a stall instead of replaying them late.
fn feedStockAudio(self: *HapVideoStreamPlayback) void {
    const info = self.audio_info orelse return;
    if (self.audio_mix_failed or !self.controller.audioEnabled()) return;
    const generation = self.controller.audioGeneration();
    if (self.audio_cursor.generation != generation)
        self.audio_cursor.reset(generation, self.controller.position(), info.sample_rate);
    if (self.audio_staging == null) self.audio_staging = .init();
    const buffer = &self.audio_staging.?;
    for (0..audio_output.batches_per_update) |_| {
        const count = self.audio_cursor.count(self.controller.position(), self.duration(), info.sample_rate);
        if (count == 0 or buffer.resize(@intCast(count * 2)) != 0) break;
        const floats: [*]f32 = @ptrCast(buffer.index(0));
        // A disabled track still feeds silence and lets the stock resampler
        // consume its bounded queue. Advertising an artificial pause would
        // freeze old PCM there, replaying it when track 0 is selected again.
        const read = if (self.audio_track_enabled)
            self.scheduler.readAudio(self.audio_cursor.next_frame, floats[0 .. count * 2])
        else blk: {
            @memset(floats[0 .. count * 2], 0);
            break :blk count;
        };
        if (read == 0) break;
        const accepted = self.base.mixAudio(@intCast(read), .{ .buffer = buffer.*, .offset = 0 });
        if (accepted < 0) {
            log.warn("Godot rejected the PCM mix callback; continuing video without audio", .{});
            self.audio_mix_failed = true;
            break;
        }
        self.audio_cursor.next_frame += @min(read, @as(usize, @intCast(accepted)));
        if (accepted < read) break;
    }
}

/// Apply a controller-issued frame request to decode/present. A no-op until
/// the stream is ready.
pub fn advance(self: *HapVideoStreamPlayback, request: FrameRequest) void {
    if (!self.playback_initialized) return;

    var frame_index = request.frame_index;
    if (self.track.frame_count > 0 and frame_index >= self.track.frame_count)
        frame_index = self.track.frame_count - 1;

    if (request.retarget) _ = self.scheduler.requestFrame(frame_index, request.forward);

    self.presentUpToFrame(frame_index, request.forward);
}

/// Keep draining the decoder toward the controller's current target even
/// while its clock is paused or stopped.
pub fn presentCurrent(self: *HapVideoStreamPlayback) void {
    if (!self.playback_initialized) return;
    self.presentUpToFrame(self.controller.currentFrame(), self.controller.directionForward());
}

/// Advance the shared controller and apply its request to the pipelines.
pub fn updateController(self: *HapVideoStreamPlayback, delta: f64) TickResult {
    const tick = self.controller.tick(delta);
    if (tick.request) |request| self.advance(request) else self.presentCurrent();
    return tick;
}

/// Drain the frame queue up to (and including) `target_frame`, presenting
/// the first frame found at or after it (or, when `forward` is false, at
/// or before it). Frames on the wrong side of the target are stale
/// prefetch and are discarded.
fn presentUpToFrame(self: *HapVideoStreamPlayback, target_frame: u32, forward: bool) void {
    var lease = self.scheduler.queue.acquireRead();
    while (lease != null and (if (forward) lease.?.frame_index < target_frame else lease.?.frame_index > target_frame)) {
        // Stale prefetch: behind the target when advancing forward, or
        // ahead of it (i.e. from before a reverse seek caught up) when
        // advancing backward.
        lease.?.consume();
        _ = self.scheduler.notifyCapacityAvailable();
        lease = self.scheduler.queue.acquireRead();
    }

    if (lease) |*frame| {
        if (frame.frame_index == target_frame) {
            if (!self.gpu_presenter.present(frame.frame)) self.gpu_error = .present;
            frame.consume();
            _ = self.scheduler.notifyCapacityAvailable();
        } else {
            frame.release();
        }
    }
    // else: decode hasn't caught up yet -- keep showing the previous frame
    // rather than blocking; the next update tick will retry.
}

// -----------------------------------------------------------------------
// VideoStreamPlayback virtuals
// -----------------------------------------------------------------------

pub fn _play(self: *HapVideoStreamPlayback) void {
    // VideoStreamPlayer may call play again automatically when looping. A
    // terminal decoder/GPU failure must not restart a PCM-only loop forever.
    if (self.hasFailed()) {
        self.failStockPlayback();
        return;
    }
    self.audio_drain_deadline_usec = 0;
    // The stock node owns its paused property and does not resend it when
    // play/stop is called. Keep that state across the core's restart policy.
    const paused = self.controller.isPaused();
    const request = self.controller.restart();
    self.controller.setPaused(paused);
    self.advance(request);
    self.feedStockAudio();
    self.publishTransport();
}

pub fn _stop(self: *HapVideoStreamPlayback) void {
    const paused = self.controller.isPaused();
    _ = self.controller.stop();
    self.controller.setPaused(paused);
    self.audio_cursor = .{};
    self.audio_drain_deadline_usec = 0;
    self.publishTransport();
}

pub fn _isPlaying(self: *const HapVideoStreamPlayback) bool {
    return self.transport_snapshot.load(.acquire) & 1 != 0;
}

pub fn _setPaused(self: *HapVideoStreamPlayback, p_paused: bool) void {
    self.controller.setPaused(p_paused);
    self.publishTransport();
}

pub fn _isPaused(self: *const HapVideoStreamPlayback) bool {
    return self.transport_snapshot.load(.acquire) & 2 != 0;
}

/// Total playback duration in seconds. Shared implementation behind the
/// _getLength() engine virtual and HapPlayer's direct-call surface.
pub fn duration(self: *const HapVideoStreamPlayback) f64 {
    return self.controller.duration();
}

pub fn _getLength(self: *const HapVideoStreamPlayback) f64 {
    return self.duration();
}

pub fn _getPlaybackPosition(self: *const HapVideoStreamPlayback) f64 {
    return self.controller.position();
}

pub fn _seek(self: *HapVideoStreamPlayback, p_time: f64) void {
    self.audio_drain_deadline_usec = 0;
    self.audio_cursor = .{};
    self.advance(self.controller.seek(p_time));
    self.publishTransport();
}

pub fn _setAudioTrack(self: *HapVideoStreamPlayback, p_idx: i32) void {
    self.audio_track_enabled = p_idx == 0;
    if (p_idx != 0 and !self.audio_track_warning_logged) {
        log.warn("Only the first embedded audio track (index 0) is supported; audio disabled", .{});
        self.audio_track_warning_logged = true;
    }
    self.publishTransport();
}

/// The presented Texture2D, returned with a SEPARATE +1 reference for the
/// caller to adopt: the presenter keeps its own persistent reference to
/// display_texture, so this hands out an independent one that the engine
/// adopts. Shared implementation behind the _getTexture() engine virtual and
/// HapPlayer's direct-call surface.
pub fn texture(self: *HapVideoStreamPlayback) ?*Texture2d {
    if (!self.playback_initialized) return null;
    return .upcast(self.gpu_presenter.getTexture());
}

pub fn _getTexture(self: *HapVideoStreamPlayback) ?*Texture2d {
    const tex = self.texture() orelse return null;
    _ = tex.reference();
    return tex;
}

fn failStockPlayback(self: *HapVideoStreamPlayback) void {
    // Video/GPU failure is terminal, unlike optional PCM failure. Let the
    // stock player stop and flush instead of keeping a stale playing flag.
    self.audio_drain_deadline_usec = 0;
    self.transport_snapshot.store(0, .release);
    if (!self.failure_logged) {
        var err = self.getError();
        defer err.deinit();
        var buf: [512]u8 = undefined;
        log.err("{s}", .{err.toUtf8Buf(&buf)});
        self.failure_logged = true;
    }
}

pub fn _update(self: *HapVideoStreamPlayback, p_delta: f64) void {
    if (!self.pollReady()) {
        if (self.hasFailed()) self.failStockPlayback();
        return;
    }

    if (self.audio_drain_deadline_usec > 0 and godot.class.Time.getTicksUsec() >= self.audio_drain_deadline_usec)
        self.audio_drain_deadline_usec = 0;
    self.feedStockAudio();
    const tick = self.updateController(p_delta);
    if (tick.completed and self.audio_info != null and !self.audio_mix_failed) {
        // The stock player flushes its resampler as soon as isPlaying turns
        // false. Keep ONLY the atomic transport alive for a bounded tail drain;
        // the controller still completes normally at the video endpoint.
        // Wall time, not p_delta: stock speed_scale is folded into p_delta
        // (including zero), and must never make the drain last indefinitely.
        self.audio_drain_deadline_usec = godot.class.Time.getTicksUsec() + @as(u64, @intFromFloat(audio_output.drain_seconds * 1_000_000));
    }
    self.publishTransport();
}

pub fn _getChannels(self: *const HapVideoStreamPlayback) i32 {
    return if (self.audio_info != null) 2 else 0;
}

pub fn _getMixRate(self: *const HapVideoStreamPlayback) i32 {
    return if (self.audio_info) |info| @intCast(info.sample_rate) else 0;
}
