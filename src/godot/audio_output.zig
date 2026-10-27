//! Main-thread PCM output clocked by the MOV controller. Godot consumes
//! bounded copies of stereo PCM; this output runs no extension callbacks on
//! the audio thread. Expected A/V sync is roughly 100 ms on normal devices,
//! without hardware-clock or gapless guarantees. Long stalls drop stale PCM.
//! The small application buffer cannot hide unusually large device latency.
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
// Cover queued audio plus a normal producer frame; Godot's existing ring still
// bounds accepted stock audio. The generator keeps its separate lead budget.
pub const stock_lead_seconds = 0.10;
pub const drain_seconds = 0.10;

pub fn frameAt(seconds: f64, rate: u32) u64 {
    return @intFromFloat(@max(0.0, seconds) * @as(f64, @floatFromInt(rate)));
}

/// Bound startup compensation for device/mixer delay; the controller stays
/// the clock. Exclude the stock path, whose resampler handles speed scaling.
fn outputLatency() f64 {
    return std.math.clamp(godot.class.AudioServer.getOutputLatency() +
        godot.class.AudioServer.getTimeToNextMix(), 0.0, 0.03);
}

/// Advance only by accepted frames. After a partial stock mix, reread the
/// remaining immutable PCM next update without a pending-buffer queue.
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
        const end = frameAt(@min(duration, position + stock_lead_seconds), rate);
        return @intCast(@min(end -| self.next_frame, batch_frames));
    }
};

/// Private AudioStreamPlayer child tracked by ObjectID: Godot may delete it
/// before HapPlayer's extension destructor runs. Own the generator/playback
/// references explicitly.
pub const GeneratorOutput = struct {
    child_id: u64 = 0,
    generator: ?*AudioStreamGenerator = null,
    playback: ?*AudioStreamGeneratorPlayback = null,
    staging: ?PackedVector2Array = null,
    scratch: [batch_frames * 2]f32 = undefined,
    cursor: Cursor = .{},
    capacity: i32 = 0,
    draining_stale: bool = false,
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
        // Server stop is deferred. Never clearBuffer() on old playback:
        // it may remain active even after stream_paused is set.
        if (self.playback != null or self.generator != null) {
            if (self.child()) |player| {
                player.stop();
                // The typed setter forbids null. Clear the Object property
                // so the idle child releases its old generator.
                player.set(StringName.fromComptimeLatin1("stream"), .nil);
            }
        }
        if (self.playback) |pb| ref.releaseEngineRef(pb);
        if (self.generator) |stream| ref.releaseEngineRef(stream);
        self.playback = null;
        self.generator = null;
        self.cursor = .{};
        self.draining_stale = false;
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
            // Parent notifications control eligibility. ALWAYS keeps the
            // child's unpause notification from overriding parent policy.
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
        // Playback holds a raw generator pointer. AudioServer may retain
        // playback for deferred stop/fade after the child and this output
        // release the generator. Retain the source in playback metadata,
        // including for external playback owners. This creates no cycle:
        // the generator does not own playback.
        const source_owner = godot.builtin.Variant.init(*AudioStreamGenerator, stream);
        defer source_owner.deinit();
        pb.setMeta(StringName.fromComptimeLatin1("_hap_generator_owner"), source_owner);
        self.playback = pb; // getStreamPlayback returns an owned engine Ref.
        self.capacity = pb.getFramesAvailable(); // FREE, not queued frames.
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
            // Recover underruns with the same playback. Replacing it would
            // overlap the old player's deferred fade with a full-gain player.
            if (now > head + tolerance or now > self.cursor.next_frame)
                self.draining_stale = true;
            if (self.draining_stale) {
                // Never splice current PCM onto an old queued source range.
                // The bounded ring must drain before rebasing the producer.
                if (queued != 0) return;
                self.cursor.next_frame = now;
                self.draining_stale = false;
            }
        }
        if (self.playback == null and !self.start(parent, info, generation, controller.position())) return;
        self.feed(scheduler, controller.position(), controller.duration(), info);
    }

    fn feed(self: *GeneratorOutput, scheduler: *const DecodeScheduler, position: f64, duration: f64, info: AudioInfo) void {
        const pb = self.playback orelse return;
        if (self.staging == null) self.staging = .init();
        const buffer = &self.staging.?;
        for (0..batches_per_update) |_| {
            // Unlike the stock adapter's Cursor.count, generator production
            // must remain contiguous until reconcile observes an empty ring.
            const end = frameAt(@min(duration, position + lead_seconds), info.sample_rate);
            const pending: usize = @intCast(@min(end -| self.cursor.next_frame, batch_frames));
            const count = @min(pending, @as(usize, @intCast(@max(0, pb.getFramesAvailable()))));
            if (count == 0) break;
            const read = scheduler.readAudio(self.cursor.next_frame, self.scratch[0 .. count * 2]);
            if (read == 0 or buffer.resize(@intCast(read)) != 0) break;
            // gdzig's generated Vector2 index helper omits alignCast in this
            // pinned version. The packed array storage is Vector2-aligned.
            const frames: [*]godot.builtin.Vector2 = @ptrCast(@alignCast(godot.raw.packedVector2ArrayOperatorIndex(buffer.ptr(), 0).?));
            for (frames[0..read], 0..) |*frame, i| frame.* = .{ .x = self.scratch[i * 2], .y = self.scratch[i * 2 + 1] };
            // pushBuffer accepts all or none. On rejection, retry the same
            // cursor; its bool result is not a frame count.
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
