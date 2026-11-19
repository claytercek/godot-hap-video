const std = @import("std");
const smoke = @import("smoke");
const natural_exit = std.Io.Duration.fromSeconds(12);

pub fn main(init: std.process.Init) !u8 {
    const mode = init.environ_map.get("FAKE_GODOT") orelse return error.MissingMode;
    const probe_path = init.environ_map.get("FAKE_GODOT_PROBE") orelse return error.MissingProbePath;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const io = init.io;
    const probe = try std.Io.Dir.cwd().openDir(io, probe_path, .{});
    defer probe.close(io);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--descendant")) {
        const lease = try probe.createFile(io, "descendant.lock", .{ .lock = .exclusive });
        defer lease.close(io);
        try probe.writeFile(io, .{ .sub_path = "descendant-started", .data = "" });
        try io.sleep(natural_exit, .awake);
        return 0;
    }

    try std.Io.File.stdout().writeStreamingAll(init.io, "Vulkan 1.3 - Forward+ - Using Device #0\n");
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "res://audio_smoke.tscn")) {
            try probe.writeFile(io, .{ .sub_path = "audio-started", .data = "" });
            try std.Io.File.stderr().writeStreamingAll(init.io, "AUDIO_SMOKE_DRIVER: TestDriver\n" ++ smoke.audio_marker ++ "\n");
            return 0;
        }
    }
    try std.Io.File.stderr().writeStreamingAll(init.io, smoke.video_marker ++ "\n");
    if (std.mem.eql(u8, mode, "timeout")) {
        var descendant = try std.process.spawn(io, .{
            .argv = &.{ args[0], "--descendant" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        defer descendant.kill(io);
        try io.sleep(natural_exit, .awake);
    }
    return if (std.mem.eql(u8, mode, "exit")) 3 else 0;
}
