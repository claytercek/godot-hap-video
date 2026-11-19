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

test "fuzz regressions replay without crash, leak, or hang" {
    for (test_support.regression_paths) |path| try replay(path);
}
