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
    \\Godot defaults to GODOT_PATH or godot; logs default to .zig-cache/smoke.
    \\
;

const Options = struct {
    godot: []const u8,
    driver: Driver = .default,
    audio: bool = false,
    audio_driver: ?[]const u8 = null,
    log_dir: []const u8 = ".zig-cache/smoke",
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
    try cwd.createDirPath(io, options.log_dir);
    const logs = try cwd.openDir(io, options.log_dir, .{});
    defer logs.close(io);
    if (!try runScene(gpa, io, logs, options, .video)) return 1;
    if (options.audio and !try runScene(gpa, io, logs, options, .audio)) return 1;
    return 0;
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
    const text = try readLogs(gpa, io, logs, name, stderr_name);
    defer gpa.free(text);
    try Io.File.stdout().writeStreamingAll(io, text);
    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &buf);
    const valid = try validate(text, scene, options.driver, options.audio_driver, &stderr.interface);
    try stderr.interface.flush();
    return valid and outcome.term.success() and !outcome.timed_out;
}

fn readLogs(gpa: Allocator, io: Io, logs: Dir, name: []const u8, stderr_name: ?[]const u8) ![]u8 {
    const limit: Io.Limit = .limited(8 * 1024 * 1024);
    const output = try logs.readFileAlloc(io, name, gpa, limit);
    const separate = stderr_name orelse return output;
    defer gpa.free(output);
    const errors = try logs.readFileAlloc(io, separate, gpa, limit);
    defer gpa.free(errors);
    // A missing final newline on either stream must not hide a signature.
    return std.mem.join(gpa, "\n", &.{ output, errors });
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
    }) catch |err| {
        std.debug.print("Cannot launch {s}: {t}\n", .{ argv[0], err });
        return err;
    };
    defer child.kill(io);
    if (windows) return waitWindows(io, &child, timeout);
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

fn waitWindows(io: Io, child: *std.process.Child, timeout: Io.Duration) !Outcome {
    const win = std.os.windows;
    const ticks: i64 = @intCast(-@divFloor(timeout.nanoseconds + 99, 100));
    const waited = win.ntdll.NtWaitForSingleObject(child.id.?, .FALSE, &ticks);
    var info: win.PROCESS.BASIC_INFORMATION = undefined;
    const status = win.ntdll.NtQueryInformationProcess(child.id.?, .BasicInformation, &info, @sizeOf(@TypeOf(info)), null);
    if (status != .SUCCESS) return win.unexpectedStatus(status);
    switch (waited) {
        .WAIT_0 => {
            // Child.wait narrows Windows exit status to u8.
            const code: u32 = @bitCast(@backingInt(info.ExitStatus));
            const term = try child.wait(io);
            return .{ .term = if (code > 255) .{ .unknown = code } else term, .timed_out = false };
        },
        .TIMEOUT => {
            var buf: [32]u8 = undefined;
            const pid = try std.fmt.bufPrint(&buf, "{d}", .{info.UniqueProcessId});
            var taskkill = try std.process.spawn(io, .{ .argv = &.{ "taskkill.exe", "/F", "/T", "/PID", pid } });
            defer taskkill.kill(io);
            _ = try taskkill.wait(io);
            child.kill(io);
            return .{ .term = .{ .unknown = 0 }, .timed_out = true };
        },
        else => return win.unexpectedStatus(waited),
    }
}

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
    var lines = std.mem.splitScalar(u8, text, '\n');
    var is_46 = false;
    while (lines.next()) |line| {
        if (startsWith(u8, line, "Godot Engine v4.6.")) is_46 = true;
    }
    lines.reset();
    const marker = if (scene == .video) video_marker else audio_marker;
    const allowed: []const []const u8 = if (scene == .video) &video_errors else &audio_errors;
    var seen: [video_errors.len]bool = @splat(false);
    var found_marker = false;
    var found_banner = false;
    var audio_count: usize = 0;
    var actual_audio: []const u8 = "";
    var ok = true;
    next_line: while (lines.next()) |raw| {
        const line = exactLine(raw);
        found_marker = found_marker or eql(u8, line, marker);
        found_banner = found_banner or deviceBanner(line, driver);
        if (is_46) for (probes_46) |probe| {
            if (eql(u8, line, probe)) continue :next_line;
        };
        for (allowed, 0..) |intentional, i| {
            if (!eql(u8, line, intentional)) continue;
            if (seen[i]) {
                try w.print("SMOKE_FAIL: Repeated intentional error: {s}\n", .{line});
                ok = false;
            }
            seen[i] = true;
            continue :next_line;
        }
        if (failureSignature(line)) {
            try w.print("SMOKE_FAIL: {s}\n", .{line});
            ok = false;
        }
        if (scene == .audio) {
            if (startsWith(u8, line, audio_prefix) and line.len > audio_prefix.len) {
                audio_count += 1;
                actual_audio = line[audio_prefix.len..];
            }
            if (contains(line, "AudioDriverDummy") != null or
                (contains(line, "audio driver") != null and contains(line, "Dummy") != null))
            {
                try w.print("SMOKE_FAIL: PCM capture requires a real audio driver: {s}\n", .{line});
                ok = false;
            }
            if (fallback(line)) {
                try w.print("SMOKE_FAIL: Audio driver fallback is not allowed: {s}\n", .{line});
                ok = false;
            }
        }
    }
    if (!found_marker) try w.print("SMOKE_FAIL: Missing exact success marker: {s}\n", .{marker});
    if (!found_banner) try w.print("SMOKE_FAIL: No {t} Forward+ RenderingDevice in engine output\n", .{driver});
    ok = ok and found_marker and found_banner;
    if (scene == .audio) {
        if (audio_count != 1 or std.ascii.eqlIgnoreCase(actual_audio, "Dummy")) {
            try w.writeAll("SMOKE_FAIL: PCM capture requires one exact real audio driver marker\n");
            ok = false;
        }
        if (requested_audio) |requested| {
            if (audio_count != 1 or !eql(u8, requested, actual_audio)) {
                try w.print("SMOKE_FAIL: Missing exact requested audio driver marker: {s}{s}\n", .{ audio_prefix, requested });
                ok = false;
            }
        }
    }
    return ok;
}

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
    var discard: Io.Writer.Discarding = .init(&.{});
    try tmp.dir.writeFile(io, .{ .sub_path = "stdout.log", .data = video_log[0 .. video_log.len - 1] });
    try tmp.dir.writeFile(io, .{ .sub_path = "stderr.log", .data = "ERROR: unexpected" });
    const text = try readLogs(gpa, io, tmp.dir, "stdout.log", "stderr.log");
    defer gpa.free(text);
    try expectEqualStrings(video_log ++ "ERROR: unexpected", text);
    try expect(!try validate(text, .video, .default, null, &discard.writer));
}
