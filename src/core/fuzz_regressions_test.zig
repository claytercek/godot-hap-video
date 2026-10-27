//! Replay exact inputs from tests/fixtures/fuzz_regressions/ that once
//! crashed, hung, leaked, or exhausted memory in Demuxer.open(). Regressions
//! fail the ordinary test suite without needing a fuzz run.
//!
//! Directory iteration uses std.Io.Dir and an Io instance; Zig 0.16 moved
//! this API out of std.fs.Dir.

const std = @import("std");
const testing = std.testing;

const mmap_reader = @import("mmap_reader.zig");
const demuxer_mod = @import("demuxer.zig");
const test_support = @import("test_support.zig");

const MmapReader = mmap_reader.MmapReader;
const Demuxer = demuxer_mod.Demuxer;
const io = test_support.io;

/// Require open() to return without crashing, leaking, or hanging.
/// Most fuzz inputs are invalid MOVs; a typed error is acceptable.
fn replay(path: []const u8) !void {
    var reader = try MmapReader.init(path);
    defer reader.deinit();

    var dem: Demuxer = .{};
    defer dem.deinit(testing.allocator);
    dem.open(testing.allocator, &reader) catch {};
}

test "fuzz regressions replay without crash, leak, or hang" {
    const dir_path = "tests/fixtures/fuzz_regressions";

    var dir = std.Io.Dir.cwd().openDir(io(), dir_path, .{ .iterate = true }) catch {
        return error.SkipZigTest; // no fuzz_regressions fixtures found
    };
    defer dir.close(io());

    var replayed: u32 = 0;
    var it = dir.iterate();
    while (try it.next(io())) |entry| {
        if (entry.kind != .file) continue;

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });

        try replay(full_path);
        replayed += 1;
    }

    // Guard against a typo'd path silently turning this into a no-op test.
    try testing.expect(replayed > 0);
}
