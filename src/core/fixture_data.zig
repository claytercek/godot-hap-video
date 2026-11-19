const std = @import("std");
const MmapReader = @import("mmap_reader.zig").MmapReader;

pub fn open(path: []const u8) !MmapReader {
    var reader = MmapReader.init(path) catch |err| {
        std.debug.print("Cannot open required fixture {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    errdefer reader.deinit();

    if (std.mem.startsWith(u8, reader.data, "version https://git-lfs.github.com/spec/v1")) {
        std.debug.print("Required fixture {s} is a Git LFS pointer; run `git lfs pull`.\n", .{path});
        return error.LfsPointer;
    }
    if (reader.data.len == 0) {
        std.debug.print("Required fixture {s} is empty.\n", .{path});
        return error.EmptyFixture;
    }
    return reader;
}

pub fn require(path: []const u8) !void {
    var reader = try open(path);
    reader.deinit();
}
