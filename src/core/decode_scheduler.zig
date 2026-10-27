//! Open a stream asynchronously and decode serially into its FrameQueue
//! on the shared OuterThreadPool. Each scheduler owns its stream's mmap,
//! demuxer, decoder, and queue. submitForStream(stream_id) permits one fill
//! step per stream at a time, as required by the SPSC queue; other streams
//! can decode concurrently.
//!
//! Usage:
//!   var scheduler = try DecodeScheduler.init(allocator);
//!   defer scheduler.deinit();
//!   try scheduler.openAsync(path);
//!   // once opened (poll isOpen()):
//!   _ = scheduler.requestFrame(0, true); // start prefetching from frame 0
//!   ... consumer thread ...
//!   var frame = scheduler.queue.acquireRead();
//!   ...use frame.?.frame...
//!   frame.?.consume();
//!   _ = scheduler.notifyCapacityAvailable(); // resume prefetch
//!
//! Seek with requestFrame(). In-flight decode finishes before the queue
//! drains and refills: Snappy and hap_decode.zig parsing cannot be safely
//! cancelled. A new request replaces any pending seek; the latest wins.
//!
//! Poll `openStatus()` and inspect `openError()` on failure. Completion
//! stays in scheduler-owned state, so no callback can outlive its owner or
//! destroy the scheduler from its own stream job. `openAsync` copies the
//! path until `deinit`, keeping it alive for deferred jobs. The scheduler
//! passes its allocator to demuxer.open() and decoder.decode().
//!
//! `deinit` waits for OuterThreadPool.waitForStreamIdle(), then releases
//! queue -> demuxer -> mmap. Queued and running jobs capture `self` and
//! must finish before destruction.

const std = @import("std");
const builtin = @import("builtin");

const hap_frame = @import("hap_frame.zig");
const mmap_reader = @import("mmap_reader.zig");
const demuxer_mod = @import("demuxer.zig");
const decoder_mod = @import("decoder.zig");
const frame_queue = @import("frame_queue.zig");
const outer_thread_pool = @import("outer_thread_pool.zig");
const sync = @import("sync.zig");
const pcm_audio = @import("pcm_audio.zig");

const MmapReader = mmap_reader.MmapReader;
const Demuxer = demuxer_mod.Demuxer;
const FrameQueue = frame_queue.FrameQueue;
const VideoTrackInfo = hap_frame.VideoTrackInfo;
const Mutex = sync.Mutex;

/// Async open failures: mmap failure or a typed demuxer error. The display
/// layer formats messages; no borrowed scratch string crosses threads.
pub const OpenError = demuxer_mod.OpenError || error{FileOpenFailed};

/// Errors returned synchronously by `openAsync` before its completion is
/// published. Once an open has been started, the scheduler's source and
/// lifecycle are fixed for its lifetime.
pub const OpenAsyncError = std.mem.Allocator.Error || error{ OpenAlreadyStarted, SchedulerClosing };

/// Lifecycle state for the one asynchronous open attempt. `failed` makes a
/// typed error available through `openError()`; all other states return null.
pub const OpenStatus = enum(u8) { not_started, opening, open, failed };

/// A terminal failure encountered after open while reading or decoding a
/// sample. The scheduler does not admit more decode work after publishing
/// one of these errors; callers may replace the stream or tear it down.
pub const DecodeError = error{ SampleUnavailable, InvalidFrame, OutOfMemory };

/// Decode-work lifecycle. `failed` is terminal for a scheduler instance and
/// makes a typed `decodeError()` available.
pub const DecodeStatus = enum(u8) { idle, filling, failed };

var g_next_stream_id = std.atomic.Value(u64).init(1);

pub const DecodeScheduler = struct {
    allocator: std.mem.Allocator,

    mmap: MmapReader = .{},
    demuxer: Demuxer = .{},
    queue: FrameQueue,

    stream_id: u64,

    // Open completion crosses the worker/caller boundary through this
    // release/acquire-published state. `open_error` is written before
    // publishing `.failed` and never modified afterwards.
    open_status: std.atomic.Value(OpenStatus) = .init(.not_started),
    open_error: ?OpenError = null,

    // Decode failures use the same release/acquire publication pattern as
    // async-open failures: write the typed error first, then publish failed.
    decode_status: std.atomic.Value(DecodeStatus) = .init(.idle),
    decode_error: ?DecodeError = null,

    // mutex guards all seek/cursor state below. requestFrame() writes the
    // pending (target, direction) pair in one critical section; fillStep()
    // consumes it under the same lock, preventing mixed concurrent requests.
    mutex: Mutex = .{},

    // Set under mutex before teardown waits for stream work. Every public
    // work-admission path checks this under the same mutex and submits while
    // still holding it, so no new self-capturing job can appear after the
    // idle wait begins.
    closing: bool = false,

    // Pending seek, applied by the next fillStep invocation.
    pending_seek: ?PendingSeek = null,

    // Next frame to decode. Signed so reverse fill can step from 0 to -1;
    // can_decode rejects it without unsigned underflow or an exhausted flag.
    cursor: i64 = 0,

    // Active decode direction, latched from the pending seek's direction
    // when it is applied in fillStep().
    forward: bool = true,

    // True while a fillStep is queued or running for this stream, so
    // notifyCapacityAvailable()/requestFrame() don't over-submit.
    fill_scheduled: bool = false,

    // openAsync() state, owned by self and read back by runOpenJob() on
    // the pool worker thread (see module docs).
    open_path: []u8 = &.{},

    // Test-only one-shot barrier at the capacity-decision boundary. It has
    // zero size in production builds and lets the concurrency regression
    // force the notification/latch interleaving without timing guesses.
    test_fill_decision_gate: if (builtin.is_test) ?*TestFillDecisionGate else void = if (builtin.is_test) null else {},
    test_close_gate: if (builtin.is_test) ?*TestCloseGate else void = if (builtin.is_test) null else {},

    /// A seek request awaiting application by the next fillStep. Bundling
    /// target and direction into one optional makes the pair structurally
    /// atomic -- there is no way to observe one half applied without the
    /// other.
    const PendingSeek = struct { target: u32, forward: bool };

    pub const TestFillDecisionGate = struct {
        snapshot_taken: std.atomic.Value(bool) = .init(false),
        proceed: std.atomic.Value(bool) = .init(false),
    };

    pub const TestCloseGate = struct {
        closing_set: std.atomic.Value(bool) = .init(false),
        proceed: std.atomic.Value(bool) = .init(false),
    };

    pub fn setFillDecisionGateForTest(self: *DecodeScheduler, gate: *TestFillDecisionGate) void {
        if (!builtin.is_test) @compileError("fill-decision gate is test-only");
        self.test_fill_decision_gate = gate;
    }

    pub fn setCloseGateForTest(self: *DecodeScheduler, gate: *TestCloseGate) void {
        if (!builtin.is_test) @compileError("close gate is test-only");
        self.test_close_gate = gate;
    }

    pub fn init(allocator: std.mem.Allocator) !DecodeScheduler {
        return .{
            .allocator = allocator,
            .queue = try FrameQueue.init(allocator, FrameQueue.default_depth),
            .stream_id = g_next_stream_id.fetchAdd(1, .monotonic),
        };
    }

    /// Blocks until no fillStep/open job is queued or running for this
    /// stream on the shared OuterThreadPool, then releases owned
    /// resources queue → demuxer → mmap (see module docs).
    pub fn deinit(self: *DecodeScheduler) void {
        self.mutex.lock();
        self.closing = true;
        self.pending_seek = null;
        self.mutex.unlock();

        if (builtin.is_test) {
            if (self.test_close_gate) |gate| {
                gate.closing_set.store(true, .release);
                while (!gate.proceed.load(.acquire)) std.Thread.yield() catch {};
                self.test_close_gate = null;
            }
        }

        outer_thread_pool.instance().waitForStreamIdle(self.stream_id);

        self.queue.deinit();
        self.demuxer.deinit(self.allocator);
        self.mmap.deinit();
        if (self.open_path.len > 0) self.allocator.free(self.open_path);
        self.mutex.deinit();

        self.* = undefined;
    }

    /// True once openAsync's job has completed successfully. Safe to
    /// poll from any thread.
    pub fn isOpen(self: *const DecodeScheduler) bool {
        return self.openStatus() == .open;
    }

    /// Lock-free snapshot of the one-shot async open lifecycle. A caller
    /// observing `.failed` may immediately read the typed `openError()`.
    pub fn openStatus(self: *const DecodeScheduler) OpenStatus {
        return self.open_status.load(.acquire);
    }

    /// Typed failure from the completed open attempt, if one occurred.
    /// The release/acquire hand-off through `openStatus()` makes this safe
    /// to read after it observes `.failed`.
    pub fn openError(self: *const DecodeScheduler) ?OpenError {
        if (self.openStatus() != .failed) return null;
        return self.open_error;
    }

    /// Lock-free snapshot of decode work. `failed` is terminal for this
    /// scheduler instance; callers may immediately inspect `decodeError()`.
    pub fn decodeStatus(self: *const DecodeScheduler) DecodeStatus {
        return self.decode_status.load(.acquire);
    }

    /// Typed terminal decode failure, or null while decode remains usable.
    pub fn decodeError(self: *const DecodeScheduler) ?DecodeError {
        if (self.decodeStatus() != .failed) return null;
        return self.decode_error;
    }

    /// Valid only once isOpen() is true.
    pub fn trackInfo(self: *const DecodeScheduler) VideoTrackInfo {
        return self.demuxer.track;
    }

    pub fn audioInfo(self: *const DecodeScheduler) ?pcm_audio.AudioInfo {
        if (!self.isOpen()) return null;
        if (self.demuxer.audio) |*audio| return audio.info;
        return null;
    }

    pub fn audioWarning(self: *const DecodeScheduler) ?pcm_audio.AudioWarning {
        if (!self.isOpen()) return null;
        return self.demuxer.audio_warning;
    }

    /// Bounded main-thread PCM conversion, never a real-time audio callback.
    /// Independent of the video worker's mutable minimp4 frame-offset cache.
    /// The caller must serialize this with scheduler teardown, as for queue use.
    pub fn readAudio(self: *const DecodeScheduler, start_frame: u64, out_stereo: []f32) usize {
        if (!self.isOpen()) return 0;
        const audio = if (self.demuxer.audio) |*audio| audio else return 0;
        return audio.read(start_frame, out_stereo);
    }

    /// Unique id used for outer-pool per-stream serialization. Exposed
    /// for tests.
    pub fn streamId(self: *const DecodeScheduler) u64 {
        return self.stream_id;
    }

    /// Map, demux, and validate asynchronously on the outer pool. Bind the
    /// job to this stream so deinit's waitForStreamIdle() also waits for open.
    /// Poll `openStatus()` and `openError()` for completion; no callback runs.
    pub fn openAsync(self: *DecodeScheduler, path: []const u8) OpenAsyncError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing) return error.SchedulerClosing;
        if (self.open_status.load(.acquire) != .not_started) return error.OpenAlreadyStarted;
        self.open_status.store(.opening, .release);
        errdefer self.open_status.store(.not_started, .release);

        self.open_path = try self.allocator.dupe(u8, path);
        outer_thread_pool.instance().submitForStream(self.stream_id, runOpenJob, .{self});
    }

    fn failOpen(self: *DecodeScheduler, err: OpenError) void {
        self.open_error = err;
        self.open_status.store(.failed, .release);
    }

    fn runOpenJob(self: *DecodeScheduler) void {
        self.mmap = MmapReader.init(self.open_path) catch {
            self.failOpen(error.FileOpenFailed);
            return;
        };

        self.demuxer.open(self.allocator, &self.mmap) catch |err| {
            self.failOpen(err);
            return;
        };

        self.open_status.store(.open, .release);
    }

    /// Prefetch from `frame_index` in the requested direction. Later calls
    /// seek: finish in-flight decode, then drain and refill from the new
    /// position/direction. `forward = false` decodes frame_index,
    /// frame_index-1, ... through frame 0. Hap is all-keyframe, so reverse
    /// uses the same decoder with different queue ordering.
    /// Return false after teardown closes admission or decode fails terminally.
    pub fn requestFrame(self: *DecodeScheduler, frame_index: u32, forward: bool) bool {
        // Target + direction land in one struct assignment, in one critical
        // section, so a concurrent requestFrame() can only ever leave a
        // coherent pair behind -- never this call's target with the other's
        // direction. Submission happens before releasing the admission gate.
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing or self.decode_status.load(.acquire) == .failed) return false;
        self.pending_seek = .{ .target = frame_index, .forward = forward };
        self.scheduleFillIfNeededLocked();
        return true;
    }

    /// Call after consuming a frame lease from `queue` to allow prefetch to
    /// continue filling the now-open slot. A no-op if a fill is already
    /// scheduled or in flight.
    /// Returns false once teardown has closed work admission or decode has
    /// entered its terminal failed state.
    pub fn notifyCapacityAvailable(self: *DecodeScheduler) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing or self.decode_status.load(.acquire) == .failed) return false;
        self.scheduleFillIfNeededLocked();
        return true;
    }

    /// Called with mutex held. Submitting before releasing mutex makes the
    /// closing gate and the outer-pool admission one atomic operation from
    /// deinit's perspective.
    fn scheduleFillIfNeededLocked(self: *DecodeScheduler) void {
        if (!self.isOpen()) return;
        if (self.decode_status.load(.acquire) == .failed) return;
        if (self.fill_scheduled) return; // already scheduled/in flight
        self.fill_scheduled = true;
        self.decode_status.store(.filling, .release);
        outer_thread_pool.instance().submitForStream(self.stream_id, fillStep, .{self});
    }

    fn fillStep(self: *DecodeScheduler) void {
        // Phase 1: consume the latest pending seek and snapshot the cursor
        // under lock. Only fillStep mutates cursor/forward, and per-stream
        // serialization keeps the snapshot valid during unlocked decode.
        // Any earlier decode has finished at this queue-behind boundary.
        var do_drain = false;
        var frame_index: i64 = undefined;
        var forward: bool = undefined;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closing) {
                self.fill_scheduled = false;
                return;
            }
            if (self.pending_seek) |s| {
                self.cursor = @intCast(s.target);
                self.forward = s.forward;
                self.pending_seek = null;
                do_drain = true;
            }
            frame_index = self.cursor;
            forward = self.forward;
        }

        // Drain stale prefetched frames outside the lock (the queue is
        // self-synchronized).
        if (do_drain) self.queue.drain();

        // Phase 2: attempt a single decode without holding mutex -- decode()
        // and the queue operations must never run under the seek lock.
        const samples = self.demuxer.samples.items;
        var decoded_one = false;
        var decode_failure: ?DecodeError = null;
        const can_decode = frame_index >= 0 and frame_index < @as(i64, @intCast(samples.len)) and !self.queue.full();
        if (can_decode) {
            const frame_index_u32: u32 = @intCast(frame_index);
            if (self.demuxer.sampleData(&self.mmap, frame_index_u32)) |sample| {
                if (self.queue.beginWrite(frame_index_u32)) |slot| {
                    if (decoder_mod.decode(self.allocator, sample, slot)) |_| {
                        self.queue.commitWrite();
                        decoded_one = true;
                    } else |err| {
                        decode_failure = err;
                    }
                }
            } else {
                decode_failure = error.SampleUnavailable;
            }
        }

        // Phase 3: under the lock, advance the cursor from the snapshot
        // and decide whether to re-submit. A seek that arrived during the
        // decode wins on the next fillStep, which re-consumes pending_seek
        // and overwrites cursor.
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (decode_failure) |err| {
                self.pending_seek = null;
                self.fill_scheduled = false;
                self.decode_error = err;
                self.decode_status.store(.failed, .release);
                return;
            }

            // Advance past the decoded frame. Reverse reaches -1 after
            // frame 0; can_decode rejects it next time. A later seek replaces
            // cursor via pending_seek, allowing forward playback to resume.
            if (decoded_one) {
                self.cursor = if (forward) frame_index + 1 else frame_index - 1;
            }

            const has_more_in_direction = if (forward) self.cursor < @as(i64, @intCast(samples.len)) else self.cursor >= 0;

            // Capacity and the fill latch are observed under one lock. If a
            // consumer pops before this snapshot, capacity is visible here;
            // if it pops afterward, its notification waits for this decision
            // and then sees the cleared latch.
            const queue_full = self.queue.full();
            if (builtin.is_test and queue_full) {
                if (self.test_fill_decision_gate) |gate| {
                    gate.snapshot_taken.store(true, .release);
                    while (!gate.proceed.load(.acquire)) std.Thread.yield() catch {};
                    self.test_fill_decision_gate = null;
                }
            }

            var more_to_do = decoded_one and !queue_full and has_more_in_direction;
            more_to_do = more_to_do or self.pending_seek != null;

            if (!self.closing and more_to_do) {
                // Keep the latch set and submit before releasing the admission
                // gate, so deinit cannot start its idle wait in between.
                outer_thread_pool.instance().submitForStream(self.stream_id, fillStep, .{self});
            } else {
                self.fill_scheduled = false;
                self.decode_status.store(.idle, .release);
            }
        }
    }
};

// Tests live in decode_scheduler_test.zig, referenced from core.zig.
