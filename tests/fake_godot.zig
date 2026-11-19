const std = @import("std");
const smoke = @import("smoke");

pub fn main(init: std.process.Init) !u8 {
    const mode = init.environ_map.get("FAKE_GODOT") orelse return error.MissingMode;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    try std.Io.File.stdout().writeStreamingAll(init.io, "Vulkan 1.3 - Forward+ - Using Device #0\n");
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "res://audio_smoke.tscn")) {
            try std.Io.File.stderr().writeStreamingAll(init.io, "AUDIO_SMOKE_DRIVER: TestDriver\n" ++ smoke.audio_marker ++ "\n");
            return 0;
        }
    }
    try std.Io.File.stderr().writeStreamingAll(init.io, smoke.video_marker ++ "\n");
    if (std.mem.eql(u8, mode, "timeout")) try init.io.sleep(.fromSeconds(10), .awake);
    return if (std.mem.eql(u8, mode, "exit")) 3 else 0;
}
