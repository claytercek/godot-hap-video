//! Replay exact inputs from tests/fixtures/fuzz_regressions/ that once
//! crashed, hung, leaked, or exhausted memory in Demuxer.open(). Regressions
//! fail the ordinary test suite without needing a fuzz run.

const std = @import("std");
const testing = std.testing;

const demuxer_mod = @import("demuxer.zig");
const test_support = @import("test_support.zig");

const Demuxer = demuxer_mod.Demuxer;

/// Require open() to return without crashing, leaking, or hanging.
/// Most fuzz inputs are invalid MOVs; a typed error is acceptable.
fn replay(path: []const u8) !void {
    var reader = try @import("fixture_data.zig").open(path);
    defer reader.deinit();

    var dem: Demuxer = .{};
    defer dem.deinit(testing.allocator);
    dem.open(testing.allocator, &reader) catch {};
}

fn firstUnregisteredFile(entries: *std.Io.Dir.Iterator, io: std.Io, paths: []const []const u8) !?[]const u8 {
    next_entry: while (try entries.next(io)) |entry| {
        if (entry.kind != .file or std.mem.eql(u8, entry.name, ".DS_Store")) continue;
        for (paths) |path| {
            if (std.mem.eql(u8, entry.name, std.fs.path.basename(path))) continue :next_entry;
        }
        return entry.name;
    }
    return null;
}

test "fuzz regressions replay without crash, leak, or hang" {
    for (test_support.regression_paths) |path| try replay(path);

    // The fuzzers and compact-index tests also depend on the shared list.
    const io = test_support.io();
    const dir = try std.Io.Dir.cwd().openDir(io, test_support.regression_dir, .{ .iterate = true });
    defer dir.close(io);
    var entries = dir.iterate();
    if (try firstUnregisteredFile(&entries, io, &test_support.regression_paths)) |name| {
        std.debug.print("Register fuzz regression {s} in test_support.regression_paths.\n", .{name});
        return error.UnregisteredRegressionFixture;
    }
}

test "fuzz regression registration rejects a new binary" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const io = testing.io;
    const paths = &.{"fixtures/registered.bin"};
    try tmp.dir.writeFile(io, .{ .sub_path = "registered.bin", .data = "listing only" });
    var entries = tmp.dir.iterate();
    try testing.expect(try firstUnregisteredFile(&entries, io, paths) == null);

    try tmp.dir.writeFile(io, .{ .sub_path = "new-input", .data = "listing only" });
    entries = tmp.dir.iterate();
    const name = try firstUnregisteredFile(&entries, io, paths) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("new-input", name);
}
