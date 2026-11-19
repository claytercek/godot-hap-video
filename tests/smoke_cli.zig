const std = @import("std");
const Io = std.Io;
const Mode = enum { pass, exit, timeout };

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    const mode = std.meta.stringToEnum(Mode, args[3]) orelse return error.InvalidMode;
    const cwd = Io.Dir.cwd();
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const probe_path = try Io.Dir.path.join(gpa, &.{ args[4], &std.fmt.bytesToHex(nonce, .lower) });
    const log_path = try Io.Dir.path.join(gpa, &.{ probe_path, "explicit logs" });
    const probe = try cwd.createDirPathOpen(io, probe_path, .{});
    defer probe.close(io);
    try init.environ_map.put("FAKE_GODOT", @tagName(mode));
    try init.environ_map.put("FAKE_GODOT_PROBE", probe_path);

    const argv = &.{ args[1], "--godot", args[2], "--audio", "--log-dir", log_path, "--timeout", "2" };
    const start = Io.Clock.Timestamp.now(io, .awake);
    // Leave CI scheduling headroom without letting either fake process exit naturally.
    const deadline = start.addDuration(.{ .clock = .awake, .raw = .fromSeconds(7) });
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .environ_map = init.environ_map,
        .timeout = .{ .deadline = deadline },
    });
    const finished = Io.Clock.Timestamp.now(io, .awake);
    const elapsed = start.durationTo(finished).raw;
    errdefer std.debug.print("smoke {t} returned {f} after {f}\nstdout:\n{s}\nstderr:\n{s}\n", .{
        mode, result.term, elapsed, result.stdout, result.stderr,
    });

    const audio_started = try exists(probe, io, "audio-started");
    if (audio_started != (mode == .pass)) return error.UnexpectedAudioInvocation;
    if (result.term != .exited or result.term.exited != @as(u8, if (mode == .pass) 0 else 1))
        return error.UnexpectedSmokeExit;

    const logs = try cwd.openDir(io, log_path, .{});
    defer logs.close(io);
    if (!try exists(logs, io, "video-smoke.log")) return error.MissingVideoLog;
    if (try exists(logs, io, "audio-smoke.log") != (mode == .pass)) return error.UnexpectedAudioLog;
    const expected = switch (mode) {
        .pass => "res://audio_smoke.tscn",
        .exit => "exited with code 3",
        .timeout => "SMOKE_TIMEOUT:",
    };
    if (std.mem.indexOf(u8, result.stderr, expected) == null) return error.MissingSmokeDiagnostic;
    if (mode == .pass and std.mem.indexOf(u8, result.stdout, "AUDIO_SMOKE:") == null)
        return error.MissingAudioOutput;
    if (mode == .timeout) {
        if (finished.durationTo(deadline).raw.nanoseconds <= 0) return error.SmokeReturnedTooLate;
        if (!try exists(probe, io, "descendant-started")) return error.DescendantDidNotStart;
        try expectDescendantStopped(probe, io, finished.addDuration(.{ .clock = .awake, .raw = .fromSeconds(1) }));
    }
}

fn exists(dir: Io.Dir, io: Io, name: []const u8) !bool {
    dir.access(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn expectDescendantStopped(probe: Io.Dir, io: Io, deadline: Io.Clock.Timestamp) !void {
    // A dead process releases its lock even if POSIX has not reaped it yet.
    const lease = try probe.openFile(io, "descendant.lock", .{ .mode = .read_write });
    defer lease.close(io);
    while (deadline.durationFromNow(io).raw.nanoseconds > 0) {
        if (try lease.tryLock(io, .exclusive)) {
            if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return error.DescendantCleanupNotObservedInTime;
            return;
        }
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    return error.DescendantStillRunning;
}
