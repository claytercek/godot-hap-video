//! Main-thread PCM output. The MOV controller remains the clock; Godot only
//! consumes bounded, copied stereo buffers. No extension callback runs on the
//! audio thread. This is pragmatic A/V sync (roughly 100 ms on normal devices),
//! not a hardware-clock or gapless-playback guarantee. Long stalls drop stale
//! sound rather than replaying it late; unusually large device latency cannot
//! be hidden by a small application buffer.
const std = @import("std");
const godot = @import("godot");
const core = @import("core");
const ref = @import("ref.zig");

const AudioStreamPlayer = godot.class.AudioStreamPlayer;
const AudioStreamGenerator = godot.class.AudioStreamGenerator;
const AudioStreamGeneratorPlayback = godot.class.AudioStreamGeneratorPlayback;
const Node = godot.class.Node;
const StringName = godot.builtin.StringName;
const PackedVector2Array = godot.builtin.PackedVector2Array;
const DecodeScheduler = core.decode_scheduler.DecodeScheduler;
pub const AudioInfo = core.pcm_audio.AudioInfo;

pub const batch_frames = 4096;
pub const batches_per_update = 4;
pub const lead_seconds = 0.06;
pub const drain_seconds = 0.10;

pub fn frameAt(seconds: f64, rate: u32) u64 {
    return @intFromFloat(@max(0.0, seconds) * @as(f64, @floatFromInt(rate)));
}

/// Device/mixer delay is only a bounded startup compensation, never a second
/// clock. Keep this out of the stock path: its resampler owns speed scaling.
fn outputLatency() f64 {
    return std.math.clamp(godot.class.AudioServer.getOutputLatency() +
        godot.class.AudioServer.getTimeToNextMix(), 0.0, 0.03);
}

/// Cursor advances ONLY by frames accepted by the sink. A partial stock mix
/// can reread the remaining immutable PCM on the next update without losing it
/// or allocating another pending-buffer queue.
pub const Cursor = struct {
    generation: ?u64 = null,
    next_frame: u64 = 0,

    pub fn reset(self: *Cursor, generation: u64, position: f64, rate: u32) void {
        self.* = .{ .generation = generation, .next_frame = frameAt(position, rate) };
    }

    pub fn count(self: *Cursor, position: f64, duration: f64, rate: u32) usize {
        const now = frameAt(position, rate);
        // A starved producer must catch up, not replay an old pending batch.
        self.next_frame = @max(self.next_frame, now);
        const end = frameAt(@min(duration, position + lead_seconds), rate);
        return @intCast(@min(end -| self.next_frame, batch_frames));
    }
};

/// A private AudioStreamPlayer child, addressed by ObjectID because children
/// can already have been deleted when HapPlayer's extension destructor runs.
/// Generator/playback references, unlike the child, are explicitly ours.
pub const GeneratorOutput = struct {
    child_id: u64 = 0,
    generator: ?*AudioStreamGenerator = null,
    playback: ?*AudioStreamGeneratorPlayback = null,
    staging: ?PackedVector2Array = null,
    scratch: [batch_frames * 2]f32 = undefined,
    cursor: Cursor = .{},
    capacity: i32 = 0,
    skips: i32 = 0,
    drain_deadline_usec: u64 = 0,
    bus: ?StringName = null,
    volume_db: f64 = 0,

    fn child(self: *GeneratorOutput) ?*AudioStreamPlayer {
        if (self.child_id == 0) return null;
        const obj = godot.general.instanceFromId(@bitCast(self.child_id)) orelse return null;
        return AudioStreamPlayer.downcast(obj);
    }

    pub fn setBus(self: *GeneratorOutput, value: StringName) void {
        const copy = value.copy();
        if (self.bus) |*bus| bus.deinit();
        self.bus = copy;
        if (self.child()) |player| player.setBus(copy);
    }

    pub fn getBus(self: *GeneratorOutput) StringName {
        return if (self.bus) |bus| bus.copy() else StringName.fromLatin1("Master", false);
    }

    pub fn setVolumeDb(self: *GeneratorOutput, value: f64) void {
        self.volume_db = value;
        if (self.child()) |player| player.setVolumeDb(value);
    }

    pub fn stop(self: *GeneratorOutput) void {
        // stop is deferred on the server. NEVER clearBuffer() on the old
        // playback, even after setting stream_paused: it may still be active.
        if (self.playback != null or self.generator != null) {
            if (self.child()) |player| {
                player.stop();
                // The generated typed setter takes a non-null pointer even
                // though Godot permits null. Clear via the Object property so
                // an idle child does not retain the old generator indefinitely.
                player.set(StringName.fromComptimeLatin1("stream"), .nil);
            }
        }
        if (self.playback) |pb| ref.releaseEngineRef(pb);
        if (self.generator) |stream| ref.releaseEngineRef(stream);
        self.playback = null;
        self.generator = null;
        self.cursor = .{};
        self.drain_deadline_usec = 0;
    }

    pub fn deinit(self: *GeneratorOutput) void {
        self.stop();
        if (self.staging) |*buffer| buffer.deinit();
        if (self.bus) |*bus| bus.deinit();
        self.generator = null;
        self.staging = null;
        self.bus = null;
    }

    fn start(self: *GeneratorOutput, parent: *Node, info: AudioInfo, generation: u64, position: f64) bool {
        self.stop();
        const player = self.child() orelse blk: {
            const player = AudioStreamPlayer.init();
            self.child_id = player.getInstanceId();
            // Parent notifications handle eligibility. Making this internal
            // child ALWAYS prevents its unpause notification from overriding
            // the parent's explicit pause policy.
            player.setProcessMode(.process_mode_always);
            parent.addChild(.upcast(player), .{ .internal = .internal_mode_back });
            break :blk player;
        };

        const stream = AudioStreamGenerator.init();
        stream.setMixRateMode(.mix_rate_custom);
        stream.setMixRate(@floatFromInt(info.sample_rate));
        stream.setBufferLength(0.08);
        player.setStream(.upcast(stream));
        self.generator = stream;
        var bus = self.getBus();
        defer bus.deinit();
        player.setBus(bus);
        player.setVolumeDb(self.volume_db);
        player.setStreamPaused(false);
        player.play(.{});
        const owned = player.getStreamPlayback() orelse {
            player.stop();
            return false;
        };
        const pb = AudioStreamGeneratorPlayback.downcast(owned) orelse {
            ref.releaseEngineRef(owned);
            player.stop();
            return false;
        };
        // Godot's generator playback keeps only a RAW generator pointer.
        // AudioServer retains the playback for its deferred stop/fade, after
        // the child and our own generator reference may already be gone.
        // Tie the source lifetime to that playback (no cycle: the generator
        // does not own its playback), including externally retained playbacks.
        const source_owner = godot.builtin.Variant.init(*AudioStreamGenerator, stream);
        defer source_owner.deinit();
        pb.setMeta(StringName.fromComptimeLatin1("_hap_generator_owner"), source_owner);
        self.playback = pb; // getStreamPlayback returns an owned engine Ref.
        self.capacity = pb.getFramesAvailable(); // FREE, not queued frames.
        self.skips = pb.getSkips();
        self.cursor.reset(generation, position + outputLatency(), info.sample_rate);
        return true;
    }

    /// Reconcile immediately from public controls as well as once per frame.
    /// Only the promoted scheduler/controller is ever passed here.
    pub fn reconcile(self: *GeneratorOutput, parent: *Node, scheduler: *const DecodeScheduler, controller: *const core.playback_controller.PlaybackController, eligible: bool) void {
        const info = scheduler.audioInfo() orelse {
            self.stop();
            return;
        };
        if (self.cursor.generation != null and self.cursor.generation != controller.audioGeneration()) self.stop();
        if (!eligible or !controller.audioEnabled()) {
            if (self.drain_deadline_usec == 0 or !eligible or controller.isPaused()) self.stop();
            return;
        }
        const generation = controller.audioGeneration();
        const now = frameAt(controller.position(), info.sample_rate);
        if (self.playback) |pb| {
            const free = pb.getFramesAvailable();
            const queued: u64 = @intCast(@max(0, self.capacity - free));
            const head = self.cursor.next_frame -| queued;
            const tolerance = info.sample_rate / 20; // 50 ms + bounded device delay
            const drifted = now > head + tolerance or head > now + tolerance;
            if (self.cursor.generation != generation or drifted or pb.getSkips() != self.skips) self.stop();
        }
        if (self.playback == null and !self.start(parent, info, generation, controller.position())) return;
        self.feed(scheduler, controller.position(), controller.duration(), info);
    }

    fn feed(self: *GeneratorOutput, scheduler: *const DecodeScheduler, position: f64, duration: f64, info: AudioInfo) void {
        const pb = self.playback orelse return;
        if (self.staging == null) self.staging = .init();
        const buffer = &self.staging.?;
        for (0..batches_per_update) |_| {
            const count = @min(self.cursor.count(position, duration, info.sample_rate), @as(usize, @intCast(@max(0, pb.getFramesAvailable()))));
            if (count == 0) break;
            const read = scheduler.readAudio(self.cursor.next_frame, self.scratch[0 .. count * 2]);
            if (read == 0 or buffer.resize(@intCast(read)) != 0) break;
            // gdzig's generated Vector2 index helper omits alignCast in this
            // pinned version. The packed array storage is Vector2-aligned.
            const frames: [*]godot.builtin.Vector2 = @ptrCast(@alignCast(godot.raw.packedVector2ArrayOperatorIndex(buffer.ptr(), 0).?));
            for (frames[0..read], 0..) |*frame, i| frame.* = .{ .x = self.scratch[i * 2], .y = self.scratch[i * 2 + 1] };
            // pushBuffer is all-or-nothing. Re-read the SAME cursor next time
            // on rejection; never interpret its bool as a frame count.
            if (!pb.pushBuffer(buffer.*)) break;
            self.cursor.next_frame += read;
        }
    }

    pub fn completed(self: *GeneratorOutput) void {
        if (self.playback != null)
            self.drain_deadline_usec = godot.class.Time.getTicksUsec() + @as(u64, @intFromFloat(drain_seconds * 1_000_000));
    }

    pub fn tickDrain(self: *GeneratorOutput) void {
        if (self.drain_deadline_usec != 0 and godot.class.Time.getTicksUsec() >= self.drain_deadline_usec) self.stop();
    }
};
