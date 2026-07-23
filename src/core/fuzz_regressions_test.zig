//! fuzz_regressions_test.zig — replays fixed fuzzer-found crash inputs.
//!
//! Each fixture under tests/fixtures/fuzz_regressions/ is a raw input
//! that previously crashed, hung, leaked, or OOM'd Demuxer.open(); the
//! bugs are fixed and this replays the exact inputs deterministically, so
//! a regression shows up as an ordinary crash/leak/hang in this suite
//! instead of only in an occasional local fuzz run.
//!
//! Zig adaptation: directory iteration goes through std.Io.Dir (0.16
//! moved std.fs.Dir's iteration API there, gated behind an `Io`
//! instance -- see test_support.zig's module docs for the same
//! Zig-0.16-idiom rationale used elsewhere in this suite).

const std = @import("std");
const testing = std.testing;

const mmap_reader = @import("mmap_reader.zig");
const demuxer_mod = @import("demuxer.zig");
const test_support = @import("test_support.zig");

const MmapReader = mmap_reader.MmapReader;
const Demuxer = demuxer_mod.Demuxer;
const io = test_support.io;

/// Fuzz-found inputs are raw bytes, not valid Hap MOVs in most cases --
/// the only thing under test is that open() returns normally (no
/// crash/leak/hang), not that it succeeds.
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
