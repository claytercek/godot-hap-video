const std = @import("std");
const windows = @import("builtin").os.tag == .windows;
const Io = std.Io;
const eql = std.mem.eql;
const contains = std.ascii.findIgnoreCase;
const startsWith = std.mem.startsWith;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const Scene = enum { video, audio };
const Driver = enum { default, vulkan, d3d12 };

const usage =
    \\Usage: smoke [--godot PATH] [--driver default|vulkan|d3d12]
    \\             [--audio [--audio-driver DRIVER]] [--log-dir DIR]
    \\             [--timeout SECONDS] [-- --display-driver x11]
    \\Run from the repository root against the installed project extension.
    \\Godot defaults to GODOT_PATH or godot.
    \\Each run gets its own directory under .zig-cache/smoke by default.
    \\Use an explicit --log-dir for only one invocation at a time.
    \\
;

const Options = struct {
    godot: []const u8,
    driver: Driver = .default,
    audio: bool = false,
    audio_driver: ?[]const u8 = null,
    log_dir: ?[]const u8 = null,
    timeout: Io.Duration = .fromSeconds(120),
    x11: bool = false,

    fn parse(args: []const []const u8, godot: []const u8) !Options {
        var options: Options = .{ .godot = if (godot.len == 0) "godot" else godot };
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (eql(u8, arg, "--")) {
                const rest = args[i + 1 ..];
                if (rest.len == 0) break;
                if (rest.len != 2 or !eql(u8, rest[0], "--display-driver") or
                    !eql(u8, rest[1], "x11")) return error.InvalidDisplayArguments;
                options.x11 = true;
                break;
            }
            if (eql(u8, arg, "--audio")) {
                options.audio = true;
                continue;
            }
            i += 1;
            if (i == args.len or args[i].len == 0 or startsWith(u8, args[i], "--")) return error.MissingOptionValue;
            const value = args[i];
            if (eql(u8, arg, "--godot")) {
                options.godot = value;
            } else if (eql(u8, arg, "--driver")) {
                options.driver = std.meta.stringToEnum(Driver, value) orelse return error.InvalidRenderingDriver;
            } else if (eql(u8, arg, "--audio-driver")) {
                options.audio_driver = value;
            } else if (eql(u8, arg, "--log-dir")) {
                options.log_dir = value;
            } else if (eql(u8, arg, "--timeout")) {
                const seconds = std.fmt.parseFloat(f64, value) catch return error.InvalidTimeout;
                if (!std.math.isFinite(seconds) or seconds <= 0 or seconds > std.math.maxInt(u32))
                    return error.InvalidTimeout;
                options.timeout = .fromNanoseconds(@intFromFloat(@ceil(seconds * std.time.ns_per_s)));
            } else return error.UnknownOption;
        }
        if (options.audio_driver) |driver| {
            if (!options.audio or std.ascii.eqlIgnoreCase(driver, "Dummy")) return error.RealAudioDriverRequired;
        }
        return options;
    }

    fn command(options: Options, scene: Scene, buffer: *[16][]const u8) []const []const u8 {
        var argv: std.ArrayList([]const u8) = .initBuffer(buffer);
        argv.appendSliceAssumeCapacity(&.{
            options.godot,                                                         "--path",             "project",
            if (scene == .video) "res://smoke.tscn" else "res://audio_smoke.tscn", "--rendering-method", "forward_plus",
            "--verbose",
        });
        // PCM capture needs a real device and must use Godot's normal cadence.
        if (scene == .video) {
            argv.appendSliceAssumeCapacity(&.{ "--audio-driver", "Dummy", "--max-fps", "60" });
        } else if (options.audio_driver) |driver| {
            argv.appendSliceAssumeCapacity(&.{ "--audio-driver", driver });
        }
        if (options.driver != .default) argv.appendSliceAssumeCapacity(&.{ "--rendering-driver", @tagName(options.driver) });
        if (options.x11) argv.appendSliceAssumeCapacity(&.{ "--display-driver", "x11" });
        return argv.items;
    }
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("SMOKE_FAIL: {t}\n", .{err});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = (try init.minimal.args.toSlice(gpa))[1..];
    if (args.len == 1 and (eql(u8, args[0], "--help") or eql(u8, args[0], "-h"))) {
        try Io.File.stdout().writeStreamingAll(io, usage);
        return 0;
    }
    const options = Options.parse(args, init.environ_map.get("GODOT_PATH") orelse "") catch |err| {
        std.debug.print("{s}", .{usage});
        return err;
    };
    const cwd = Dir.cwd();
    const manifest = cwd.statFile(io, "project/hap_video.gdextension", .{}) catch |err| {
        std.debug.print("Cannot access project/hap_video.gdextension: {t}\n", .{err});
        return 1;
    };
    if (manifest.kind != .file) return error.InvalidExtensionManifest;
    var path_buffer: [default_log_root.len + 1 + 32]u8 = undefined;
    const path = if (options.log_dir) |path| explicit: {
        try cwd.createDirPath(io, path);
        break :explicit path;
    } else try createLogDir(io, cwd, default_log_root, &path_buffer);
    std.debug.print("SMOKE_LOG_DIR {s}\n", .{path});
    const logs = try cwd.openDir(io, path, .{});
    defer logs.close(io);
    if (!try runScene(gpa, io, logs, options, .video)) return 1;
    if (options.audio and !try runScene(gpa, io, logs, options, .audio)) return 1;
    return 0;
}

const default_log_root = ".zig-cache/smoke";

fn createLogDir(io: Io, cwd: Dir, root: []const u8, buffer: []u8) ![]const u8 {
    try cwd.createDirPath(io, root);
    while (true) {
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const path = try std.fmt.bufPrint(buffer, "{s}/{x}", .{ root, &nonce });
        cwd.createDir(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return path;
    }
}

fn runScene(gpa: Allocator, io: Io, logs: Dir, options: Options, scene: Scene) !bool {
    var buffer: [16][]const u8 = undefined;
    const argv = options.command(scene, &buffer);
    const name = if (scene == .video) "video-smoke.log" else "audio-smoke.log";
    const stderr_name = if (windows)
        (if (scene == .video) "video-smoke.stderr.log" else "audio-smoke.stderr.log")
    else
        null;
    const command = try std.mem.join(gpa, " ", argv);
    defer gpa.free(command);
    std.debug.print("SMOKE_COMMAND {s}\n", .{command});
    const outcome = try capture(io, logs, name, stderr_name, argv, options.timeout);
    if (outcome.timed_out) {
        std.debug.print("SMOKE_TIMEOUT: {s} after {f}\n", .{ name, options.timeout });
    } else if (!outcome.term.success()) {
        std.debug.print("SMOKE_FAIL: {s}: {f}\n", .{ name, outcome.term });
    }
    var out_buf: [8192]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    var stderr = Io.File.stderr().writerStreaming(io, &err_buf);
    var validation: Validation = .{ .scene = scene, .driver = options.driver, .requested_audio = options.audio_driver };
    const valid = try inspectLogs(gpa, io, logs, name, stderr_name, &validation, &stdout.interface, &stderr.interface);
    try stderr.interface.flush();
    return valid and outcome.term.success() and !outcome.timed_out;
}

fn inspectLogs(gpa: Allocator, io: Io, logs: Dir, name: []const u8, stderr_name: ?[]const u8, validation: *Validation, replay: *Io.Writer, diagnostics: *Io.Writer) !bool {
    const names = [_]?[]const u8{ name, stderr_name };
    // A 4.6 banner on either stream can allow probes earlier in the output.
    for (names, 0..) |maybe_name, i| {
        const file_name = maybe_name orelse continue;
        if (i != 0) try replay.writeByte('\n');
        try inspectLog(gpa, io, logs, file_name, validation, .replay, replay);
    }
    try replay.flush();
    for (names) |maybe_name| {
        const file_name = maybe_name orelse continue;
        try inspectLog(gpa, io, logs, file_name, validation, .validate, diagnostics);
    }
    return validation.finish(diagnostics);
}

fn inspectLog(gpa: Allocator, io: Io, logs: Dir, name: []const u8, validation: *Validation, pass: enum { replay, validate }, w: *Io.Writer) !void {
    const file = try logs.openFile(io, name, .{});
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var reader = file.reader(io, &buf);
    const r = &reader.interface;
    var long_line: Io.Writer.Allocating = .init(gpa);
    defer long_line.deinit();
    while (true) {
        const raw = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.EndOfStream => if (r.buffered().len == 0) break else r.take(r.buffered().len) catch unreachable,
            error.StreamTooLong => blk: {
                long_line.clearRetainingCapacity();
                _ = r.streamDelimiterEnding(&long_line.writer, '\n') catch |stream_err| switch (stream_err) {
                    error.ReadFailed => return reader.err.?,
                    error.WriteFailed => return error.OutOfMemory,
                };
                if (r.buffered().len != 0) {
                    r.toss(1);
                    long_line.writer.writeByte('\n') catch return error.OutOfMemory;
                }
                break :blk long_line.written();
            },
        };
        const line = if (std.mem.endsWith(u8, raw, "\n")) raw[0 .. raw.len - 1] else raw;
        switch (pass) {
            .replay => {
                try w.writeAll(raw);
                validation.noteVersion(line);
            },
            .validate => try validation.checkLine(line, w),
        }
    }
}

const Outcome = struct { term: std.process.Child.Term, timed_out: bool };

fn capture(io: Io, logs: Dir, name: []const u8, stderr_name: ?[]const u8, argv: []const []const u8, timeout: Io.Duration) !Outcome {
    const output = try logs.createFile(io, name, .{});
    defer output.close(io);
    // Zig's Windows spawn reopens each handle, giving it a separate file offset.
    // POSIX shares the open file so both streams keep their original order.
    const errors = if (stderr_name) |separate| try logs.createFile(io, separate, .{}) else output;
    defer if (stderr_name != null) errors.close(io);
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdout = .{ .file = output },
        .stderr = .{ .file = errors },
        .pgid = if (windows) null else 0,
        .start_suspended = windows,
    }) catch |err| {
        std.debug.print("Cannot launch {s}: {t}\n", .{ argv[0], err });
        return err;
    };
    if (windows) return Windows.run(child, timeout);
    defer child.kill(io);
    const deadline = Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .clock = .awake, .raw = timeout });
    const pid = child.id.?;
    const posix = std.posix;
    // Only the waiter signals the process group, before its PID can be reaped and reused.
    while (true) {
        var status: u32 = undefined;
        const rc = posix.system.wait4(pid, @ptrCast(&status), posix.W.NOHANG, null);
        switch (posix.errno(rc)) {
            .SUCCESS => if (rc != 0) {
                child.id = null;
                const term: std.process.Child.Term = if (posix.W.IFEXITED(status))
                    .{ .exited = posix.W.EXITSTATUS(status) }
                else if (posix.W.IFSIGNALED(status))
                    .{ .signal = posix.W.TERMSIG(status) }
                else
                    .{ .unknown = status };
                return .{ .term = term, .timed_out = false };
            },
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
        const ns = deadline.durationFromNow(io).raw.nanoseconds;
        if (ns <= 0) {
            try posix.kill(-pid, .KILL);
            return .{ .term = try child.wait(io), .timed_out = true };
        }
        try io.sleep(.fromNanoseconds(@min(ns, 20 * std.time.ns_per_ms)), .awake);
    }
}

const Windows = struct {
    const win = std.os.windows;
    extern "kernel32" fn CreateJobObjectW(?*const win.SECURITY_ATTRIBUTES, ?[*:0]const u16) callconv(.winapi) ?win.HANDLE;
    extern "kernel32" fn AssignProcessToJobObject(win.HANDLE, win.HANDLE) callconv(.winapi) win.BOOL;
    extern "kernel32" fn TerminateJobObject(win.HANDLE, u32) callconv(.winapi) win.BOOL;
    extern "kernel32" fn GetExitCodeProcess(win.HANDLE, *u32) callconv(.winapi) win.BOOL;

    fn run(child: std.process.Child, timeout: Io.Duration) !Outcome {
        const process = child.id.?;
        defer win.CloseHandle(process);
        defer win.CloseHandle(child.thread_handle);
        errdefer _ = win.ntdll.NtTerminateProcess(process, .UNSUCCESSFUL);

        // Assign the suspended process before a Godot launcher can spawn children.
        const job = CreateJobObjectW(null, null) orelse return error.CreateJobFailed;
        defer win.CloseHandle(job);
        if (!AssignProcessToJobObject(job, process).toBool()) return error.AssignJobFailed;
        defer _ = TerminateJobObject(job, 1);
        const resumed = win.ntdll.NtResumeThread(child.thread_handle, null);
        if (resumed != .SUCCESS) return win.unexpectedStatus(resumed);

        if (!try wait(process, timeout)) {
            if (!TerminateJobObject(job, 1).toBool()) return error.TerminateJobFailed;
            if (!try wait(process, .fromSeconds(2))) return error.JobCleanupTimedOut;
            return .{ .term = .{ .unknown = 0 }, .timed_out = true };
        }
        // Child.wait narrows Windows exit status to u8.
        var code: u32 = undefined;
        if (!GetExitCodeProcess(process, &code).toBool()) return error.ExitCodeUnavailable;
        return .{ .term = if (code > 255) .{ .unknown = code } else .{ .exited = @intCast(code) }, .timed_out = false };
    }

    fn wait(process: win.HANDLE, timeout: Io.Duration) !bool {
        const ticks: i64 = @intCast(-@divFloor(timeout.nanoseconds + 99, 100));
        return switch (win.ntdll.NtWaitForSingleObject(process, .FALSE, &ticks)) {
            .WAIT_0 => true,
            .TIMEOUT => false,
            else => |s| win.unexpectedStatus(s),
        };
    }
};

pub const video_marker = "SMOKE: Hap fixture opened, played, sought, cleared, and rejected synchronous/asynchronous invalid replacements";
pub const audio_marker = "AUDIO_SMOKE: mono16, stereo16BE, stereo24BE captured from both players; seek/loop content, controls, unsupported audio, and teardown passed";
const audio_prefix = "AUDIO_SMOKE_DRIVER: ";
const probes_46 = [_][]const u8{
    "ERROR: Attempt to get non-existent interface function: 'variant_get_type_by_name'.",
    "ERROR: Attempt to get non-existent interface function: 'classdb_construct_object3'.",
    "ERROR: Attempt to get non-existent interface function: 'classdb_register_extension_class6'.",
};
const video_errors = [_][]const u8{
    "error(hap_video_stream_playback): empty path",
    "error(hap_player): failed to open stream: ",
};
const audio_errors = [_][]const u8{
    "error(hap_video_stream_playback): Failed to decode invalid Hap frame",
};

fn exactLine(text: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, text, "\r")) text[0 .. text.len - 1] else text;
}

fn deviceBanner(line: []const u8, driver: Driver) bool {
    const prefixes: []const []const u8 = switch (driver) {
        .default => &.{ "Metal ", "Vulkan ", "D3D12 ", "Direct3D 12 " },
        .vulkan => &.{"Vulkan "},
        .d3d12 => &.{ "D3D12 ", "Direct3D 12 " },
    };
    for (prefixes) |prefix| {
        if (startsWith(u8, line, prefix) and
            std.mem.find(u8, line[prefix.len..], " - Forward+ - Using Device") != null) return true;
    }
    return false;
}

fn failureSignature(line: []const u8) bool {
    for (line, 0..) |_, i| {
        if (i != 0 and !std.ascii.isWhitespace(line[i - 1])) continue;
        const rest = line[i..];
        if (std.ascii.startsWithIgnoreCase(rest, "error:") or std.ascii.startsWithIgnoreCase(rest, "panic:")) return true;
        if (std.ascii.startsWithIgnoreCase(rest, "error(")) {
            if (std.mem.findScalar(u8, rest, ')')) |end| {
                if (startsWith(u8, rest[end + 1 ..], ":")) return true;
            }
        }
    }
    if (containsAny(line, &.{ "undefined symbol", "error loading extension", "leaked at exit", "ObjectDB instances leaked", "Segmentation fault" })) return true;
    if (contains(line, "failed to load")) |i| {
        if (containsAny(line[i + "failed to load".len ..], &.{ "gdextension", "libhap_video", "hap_video.dll" })) return true;
    }
    if (contains(line, "memory address ")) |i| {
        if (contains(line[i + "memory address ".len ..], " leaked") != null) return true;
    }
    return false;
}

fn containsAny(line: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (contains(line, needle) != null) return true;
    return false;
}

fn fallback(line: []const u8) bool {
    return containsAny(line, &.{ "falling back", "fallback", "fell back" }) and
        containsAny(line, &.{ "audio", "alsa", "driver" });
}

fn validate(text: []const u8, scene: Scene, driver: Driver, requested_audio: ?[]const u8, w: *Io.Writer) Io.Writer.Error!bool {
    var validation: Validation = .{ .scene = scene, .driver = driver, .requested_audio = requested_audio };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| validation.noteVersion(line);
    lines.reset();
    while (lines.next()) |line| try validation.checkLine(line, w);
    return validation.finish(w);
}

const Validation = struct {
    scene: Scene,
    driver: Driver,
    requested_audio: ?[]const u8,
    is_46: bool = false,
    seen: [video_errors.len]bool = @splat(false),
    found_marker: bool = false,
    found_banner: bool = false,
    audio_count: u2 = 0,
    dummy_audio: bool = false,
    matches_requested_audio: bool = false,
    ok: bool = true,

    fn noteVersion(v: *Validation, line: []const u8) void {
        v.is_46 = v.is_46 or startsWith(u8, line, "Godot Engine v4.6.");
    }

    fn marker(v: *const Validation) []const u8 {
        return if (v.scene == .video) video_marker else audio_marker;
    }

    fn checkLine(v: *Validation, raw: []const u8, w: *Io.Writer) Io.Writer.Error!void {
        const line = exactLine(raw);
        v.found_marker = v.found_marker or eql(u8, line, v.marker());
        v.found_banner = v.found_banner or deviceBanner(line, v.driver);
        if (v.is_46) for (probes_46) |probe| {
            if (eql(u8, line, probe)) return;
        };
        const allowed: []const []const u8 = if (v.scene == .video) &video_errors else &audio_errors;
        for (allowed, 0..) |intentional, i| {
            if (!eql(u8, line, intentional)) continue;
            if (v.seen[i]) {
                try w.print("SMOKE_FAIL: Repeated intentional error: {s}\n", .{line});
                v.ok = false;
            }
            v.seen[i] = true;
            return;
        }
        if (failureSignature(line)) {
            try w.print("SMOKE_FAIL: {s}\n", .{line});
            v.ok = false;
        }
        if (v.scene == .audio) {
            if (startsWith(u8, line, audio_prefix) and line.len > audio_prefix.len) {
                v.audio_count +|= 1;
                const actual_audio = line[audio_prefix.len..];
                v.dummy_audio = std.ascii.eqlIgnoreCase(actual_audio, "Dummy");
                if (v.requested_audio) |requested| v.matches_requested_audio = eql(u8, actual_audio, requested);
            }
            if (contains(line, "AudioDriverDummy") != null or
                (contains(line, "audio driver") != null and contains(line, "Dummy") != null))
            {
                try w.print("SMOKE_FAIL: PCM capture requires a real audio driver: {s}\n", .{line});
                v.ok = false;
            }
            if (fallback(line)) {
                try w.print("SMOKE_FAIL: Audio driver fallback is not allowed: {s}\n", .{line});
                v.ok = false;
            }
        }
    }
    fn finish(v: *const Validation, w: *Io.Writer) Io.Writer.Error!bool {
        if (!v.found_marker) try w.print("SMOKE_FAIL: Missing exact success marker: {s}\n", .{v.marker()});
        if (!v.found_banner) try w.print("SMOKE_FAIL: No {t} Forward+ RenderingDevice in engine output\n", .{v.driver});
        var ok = v.ok and v.found_marker and v.found_banner;
        if (v.scene == .audio) {
            if (v.audio_count != 1 or v.dummy_audio) {
                try w.writeAll("SMOKE_FAIL: PCM capture requires one exact real audio driver marker\n");
                ok = false;
            }
            if (v.requested_audio) |requested| {
                if (v.audio_count != 1 or !v.matches_requested_audio) {
                    try w.print("SMOKE_FAIL: Missing exact requested audio driver marker: {s}{s}\n", .{ audio_prefix, requested });
                    ok = false;
                }
            }
        }
        return ok;
    }
};

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const video_log = "Godot Engine v4.7.2.stable\nVulkan 1.3 - Forward+ - Using Device #0\n" ++ video_marker ++ "\n";
const audio_log = "Godot Engine v4.7.2.stable\r\nMetal 4.0 - Forward+ - Using Device #0\r\n" ++ audio_marker ++ "\r\n";

test "renderer and display command keeps PCM at normal cadence with real audio" {
    const options = try Options.parse(&.{ "--audio", "--audio-driver", "PulseAudio", "--driver", "vulkan", "--", "--display-driver", "x11" }, "/opt/Godot with spaces");
    var buffer: [16][]const u8 = undefined;
    const wanted_video = [_][]const u8{
        "/opt/Godot with spaces", "--path",           "project",   "res://smoke.tscn",
        "--rendering-method",     "forward_plus",     "--verbose", "--audio-driver",
        "Dummy",                  "--max-fps",        "60",        "--rendering-driver",
        "vulkan",                 "--display-driver", "x11",
    };
    const wanted_audio = [_][]const u8{
        "/opt/Godot with spaces", "--path",             "project",   "res://audio_smoke.tscn",
        "--rendering-method",     "forward_plus",       "--verbose", "--audio-driver",
        "PulseAudio",             "--rendering-driver", "vulkan",    "--display-driver",
        "x11",
    };
    for (options.command(.video, &buffer), wanted_video) |actual, wanted| try expectEqualStrings(wanted, actual);
    for (options.command(.audio, &buffer), wanted_audio) |actual, wanted| try expectEqualStrings(wanted, actual);
}

test "CLI rejects weakening prerequisites and invalid timeouts" {
    try std.testing.expectError(error.InvalidDisplayArguments, Options.parse(&.{ "--", "--headless" }, ""));
    try std.testing.expectError(error.RealAudioDriverRequired, Options.parse(&.{ "--audio", "--audio-driver", "dummy" }, ""));
    try std.testing.expectError(error.RealAudioDriverRequired, Options.parse(&.{ "--audio-driver", "PulseAudio" }, ""));
    for ([_][]const u8{ "0", "-1", "nan", "inf" }) |bad| {
        try std.testing.expectError(error.InvalidTimeout, Options.parse(&.{ "--timeout", bad }, ""));
    }
    const defaults = try Options.parse(&.{}, "");
    try expectEqualStrings("godot", defaults.godot);
    try expectEqualStrings("my-godot", (try Options.parse(&.{ "--godot", "my-godot" }, "env-godot")).godot);
}

test "rendered video requires an exact success marker and the requested device" {
    var discard: Io.Writer.Discarding = .init(&.{});
    const w = &discard.writer;
    try expect(try validate(video_log, .video, .vulkan, null, w));
    try expect(try validate("D3D12 12 - Forward+ - Using Device #0\n" ++ video_marker, .video, .d3d12, null, w));
    try expect(try validate("D3D12 12 - Forward+ - Using Device #0\n" ++ video_marker, .video, .default, null, w));
    try expect(try validate("Direct3D 12 12 - Forward+ - Using Device #0\n" ++ video_marker, .video, .d3d12, null, w));
    try expect(try validate("Direct3D 12 12 - Forward+ - Using Device #0\n" ++ video_marker, .video, .default, null, w));
    try expect(!try validate(video_log, .video, .d3d12, null, w));
    try expect(!try validate("Vulkan 1.3 - Forward+ - Using Device #0\nprefix " ++ video_marker, .video, .vulkan, null, w));
    try expect(!try validate("Vulkan 1.3 - Compatibility - Using Device #0\n" ++ video_marker, .video, .vulkan, null, w));
}

test "negative fixture errors are exact, once per scene; probing is 4.6 only" {
    var discard: Io.Writer.Discarding = .init(&.{});
    const w = &discard.writer;
    const intentional = video_errors[0] ++ "\n" ++ video_errors[1] ++ "\n";
    try expect(try validate(video_log ++ intentional, .video, .default, null, w));
    try expect(!try validate(video_log ++ intentional ++ intentional, .video, .default, null, w));
    try expect(!try validate(video_log ++ video_errors[1] ++ "other.mov\n", .video, .default, null, w));
    try expect(!try validate(video_log ++ audio_errors[0], .video, .default, null, w));
    const probes = probes_46[0] ++ "\n" ++ probes_46[1] ++ "\n" ++ probes_46[2] ++ "\n";
    const rest = video_log["Godot Engine v4.7.2.stable".len..];
    try expect(try validate("Godot Engine v4.6.3.stable" ++ rest ++ probes, .video, .default, null, w));
    try expect(!try validate("Godot Engine v4.6.3.stable" ++ rest ++ "ERROR: Attempt to get non-existent interface function: 'other'.", .video, .default, null, w));
    try expect(!try validate(video_log ++ probes, .video, .default, null, w));
}

test "success marker cannot mask error, loader, crash, or leak signatures" {
    var discard: Io.Writer.Discarding = .init(&.{});
    const w = &discard.writer;
    inline for (.{
        "  ERROR: unexpected",    "SCRIPT ERROR: bad",       "user error: bad",                "panic: bad",                "error(other): bad",
        "undefined symbol: bad",  "Error loading extension", "Failed to load ./hap_video.dll", "Memory address 0x1 leaked", "ObjectDB instances leaked",
        "library leaked at exit", "Segmentation fault",
    }) |bad| try expect(!try validate(video_log ++ bad, .video, .default, null, w));
}

test "audio requires one exact real driver and rejects fallback" {
    var discard: Io.Writer.Discarding = .init(&.{});
    const w = &discard.writer;
    const pulse = audio_prefix ++ "PulseAudio\r\n";
    try expect(try validate(audio_log ++ pulse ++ audio_errors[0], .audio, .default, "PulseAudio", w));
    inline for (.{
        "",                                                "prefix " ++ pulse, audio_prefix ++ "Dummy\r\n",                  audio_prefix ++ "ALSA\r\n",
        audio_prefix ++ "PulseAudio extra\r\n",            pulse ++ pulse,     pulse ++ "WARNING: Using audio driver Dummy", pulse ++ "WARNING: PulseAudio driver failed. Falling back to ALSA driver.",
        pulse ++ "WARNING: Audio driver fallback to ALSA",
    }) |bad| try expect(!try validate(audio_log ++ bad, .audio, .default, "PulseAudio", w));
    try expect(!try validate(audio_log ++ audio_prefix ++ "dummy\r\n", .audio, .default, null, w));
    try expect(!try validate(audio_log ++ pulse ++ "Using AudioDriverDummy\n", .audio, .default, null, w));
    try expect(!try validate(audio_log ++ pulse ++ "Fallback configuration: fell back to ALSA\n", .audio, .default, null, w));
}

test "separate logs preserve errors and markers at stream boundaries" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    var replay: Io.Writer.Allocating = .init(gpa);
    defer replay.deinit();
    var diagnostics: Io.Writer.Allocating = .init(gpa);
    defer diagnostics.deinit();
    const output = probes_46[0] ++ "\r\n" ++ video_log[0 .. video_log.len - 1];
    try tmp.dir.writeFile(io, .{ .sub_path = "stdout.log", .data = output });
    try tmp.dir.writeFile(io, .{ .sub_path = "stderr.log", .data = "Godot Engine v4.6.3.stable" });
    var validation: Validation = .{ .scene = .video, .driver = .default, .requested_audio = null };
    try expect(try inspectLogs(gpa, io, tmp.dir, "stdout.log", "stderr.log", &validation, &replay.writer, &diagnostics.writer));
    try expectEqualStrings(output ++ "\nGodot Engine v4.6.3.stable", replay.written());
    try expectEqualStrings("", diagnostics.written());

    try tmp.dir.writeFile(io, .{ .sub_path = "stderr.log", .data = "ERROR: unexpected" });
    replay.clearRetainingCapacity();
    validation = .{ .scene = .video, .driver = .default, .requested_audio = null };
    try expect(!try inspectLogs(gpa, io, tmp.dir, "stdout.log", "stderr.log", &validation, &replay.writer, &diagnostics.writer));
    try expectEqualStrings(output ++ "\nERROR: unexpected", replay.written());
    try expectEqualStrings("SMOKE_FAIL: " ++ probes_46[0] ++ "\nSMOKE_FAIL: ERROR: unexpected\n", diagnostics.written());
}

test "large logs replay and validate with memory bounded by line length" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const line = "verbose update " ++ @as([9000]u8, @splat('x')) ++ "\r\n";
    const count = 1024;
    {
        const file = try tmp.dir.createFile(io, "merged.log", .{});
        defer file.close(io);
        for (0..count) |_| try file.writeStreamingAll(io, line);
        try file.writeStreamingAll(io, video_log[0 .. video_log.len - 1]);
    }
    var memory: [32 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    var replay: Io.Writer.Discarding = .init(&.{});
    var diagnostics: Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    var validation: Validation = .{ .scene = .video, .driver = .vulkan, .requested_audio = null };
    try expect(try inspectLogs(fba.allocator(), io, tmp.dir, "merged.log", null, &validation, &replay.writer, &diagnostics.writer));
    try std.testing.expectEqual(count * line.len + video_log.len - 1, replay.count);
    try expectEqualStrings("", diagnostics.written());
}

test "default runs reserve separate directories with the same log file names" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = ".zig-cache/smoke";
    var path_buffers: [2][root.len + 1 + 32]u8 = undefined;
    const first = try createLogDir(io, tmp.dir, root, &path_buffers[0]);
    const second = try createLogDir(io, tmp.dir, root, &path_buffers[1]);
    try expect(!eql(u8, first, second));
    for ([_][]const u8{ first, second }) |path| {
        const logs = try tmp.dir.openDir(io, path, .{});
        defer logs.close(io);
        const file = try logs.createFile(io, "video-smoke.log", .{ .exclusive = true });
        file.close(io);
    }
}
