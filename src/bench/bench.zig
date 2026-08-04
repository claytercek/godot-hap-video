//! bench.zig
//!
//! Standalone benchmark harness for the core codec: open/close cost and
//! per-frame decode cost across the checked-in Hap fixtures. Builds and runs
//! independently of the Godot extension (`zig build bench`), same as
//! `zig build test`.
//!
//! Methodology: see module-level comments below each measurement function.
//! Missing fixtures are skipped with a stderr note rather than failing the
//! run, since not every checkout necessarily has every fixture.

const std = @import("std");
const core = @import("core");

const MmapReader = core.mmap_reader.MmapReader;
const Demuxer = core.demuxer.Demuxer;
const DecodedFrame = core.hap_frame.DecodedFrame;

/// Open/close fixtures: one of each supported single- and dual-texture
/// variant, non-chunked.
const open_close_fixtures = [_][]const u8{
    "tests/fixtures/hap1.mov",
    "tests/fixtures/hap5.mov",
    "tests/fixtures/hap7.mov",
    "tests/fixtures/hapy.mov",
    "tests/fixtures/hapm.mov",
};

/// Decode fixtures: the open/close set plus the chunked variants, which
/// exercise the parallel inner-thread-pool decode path. No hap7/hapm chunked
/// fixtures exist.
const chunked_fixtures = [_][]const u8{
    "tests/fixtures/hap1_chunked.mov",
    "tests/fixtures/hap5_chunked.mov",
    "tests/fixtures/hapy_chunked.mov",
};

const decode_fixtures = open_close_fixtures ++ chunked_fixtures;

const open_close_iterations = 30;
const decode_passes = 10;

const Result = struct {
    name: []const u8,
    unit: []const u8,
    value: f64,
};

/// Minimal monotonic-clock stopwatch. Zig 0.16 removed `std.time.Timer` in
/// favor of routing all timing through an `std.Io` instance; this codebase
/// deliberately avoids threading `Io` through call sites that don't
/// otherwise need it (see sync.zig's module docs for the same tradeoff),
/// so this wraps `clock_gettime(CLOCK.MONOTONIC, ...)` directly instead,
/// matching mmap_reader.zig's precedent of calling `std.c`/OS primitives
/// straight through for small, self-contained needs.
const Timer = struct {
    last: u64,

    fn start() Timer {
        return .{ .last = nowNs() };
    }

    fn reset(self: *Timer) void {
        self.last = nowNs();
    }

    /// Nanoseconds elapsed since the last `start`/`reset`.
    fn read(self: *const Timer) u64 {
        return nowNs() - self.last;
    }

    fn nowNs() u64 {
        var ts: std.c.timespec = undefined;
        std.debug.assert(std.c.clock_gettime(.MONOTONIC, &ts) == 0);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;

    const json_path = parseArgs(init.minimal.args);

    var results: std.ArrayListUnmanaged(Result) = .empty;
    defer results.deinit(allocator);

    try warmUpThreadPool(allocator);

    for (open_close_fixtures) |path| {
        try benchOpenClose(allocator, path, &results);
    }
    for (decode_fixtures) |path| {
        try benchDecode(allocator, path, &results);
    }

    printTable(results.items);

    if (json_path) |p| try writeJson(allocator, init.io, p, results.items);
}

/// The `--json <path>` argument, if given. Borrows directly from argv (valid
/// for the process lifetime), so no allocation is needed.
fn parseArgs(process_args: std.process.Args) ?[]const u8 {
    var it = process_args.iterate();
    _ = it.next(); // exe name

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            const path = it.next() orelse {
                std.debug.print("--json requires a path argument\n", .{});
                std.process.exit(1);
            };
            return path;
        }
    }
    return null;
}

/// The inner thread pool used for chunked-frame decode is a lazy singleton;
/// its first `instance()` call spawns worker threads. Only chunked frames
/// dispatch to the pool, so decode one frame of the first available chunked
/// fixture, untimed, before any measurement so that spin-up cost never
/// lands inside a timed sample.
fn warmUpThreadPool(allocator: std.mem.Allocator) !void {
    for (chunked_fixtures) |path| {
        var reader = MmapReader.init(path) catch continue;
        defer reader.deinit();

        var dem: Demuxer = .{};
        dem.open(allocator, &reader) catch {
            dem.deinit(allocator);
            continue;
        };
        defer dem.deinit(allocator);

        const sample = dem.sampleData(&reader, 0) orelse continue;

        var frame: DecodedFrame = .{};
        defer frame.deinit(allocator);
        core.decoder.decode(allocator, sample, &frame) catch continue;
        return;
    }
}

/// Times `open_close_iterations` open->close cycles for `path`, reporting
/// the median open time and median close time separately. Open is
/// MmapReader.init + Demuxer.open; close is Demuxer.deinit + reader.deinit.
fn benchOpenClose(allocator: std.mem.Allocator, path: []const u8, results: *std.ArrayListUnmanaged(Result)) !void {
    if (!fixtureExists(path)) {
        std.debug.print("skip (missing fixture): {s}\n", .{path});
        return;
    }

    var open_ms: [open_close_iterations]f64 = undefined;
    var close_ms: [open_close_iterations]f64 = undefined;
    var timer = Timer.start();

    for (0..open_close_iterations) |i| {
        timer.reset();
        var reader = try MmapReader.init(path);
        var dem: Demuxer = .{};
        try dem.open(allocator, &reader);
        open_ms[i] = nsToMs(timer.read());

        timer.reset();
        dem.deinit(allocator);
        reader.deinit();
        close_ms[i] = nsToMs(timer.read());
    }

    const name = fixtureName(path);
    try results.append(allocator, .{
        .name = try std.fmt.allocPrint(allocator, "open/{s}", .{name}),
        .unit = "ms",
        .value = median(&open_ms),
    });
    try results.append(allocator, .{
        .name = try std.fmt.allocPrint(allocator, "close/{s}", .{name}),
        .unit = "ms",
        .value = median(&close_ms),
    });
}

/// Times `decode_passes` whole-file decode passes over `path`'s frames,
/// reusing one DecodedFrame across calls (decode() clears/repopulates it),
/// and reports the median pass time divided by frame count as ms/frame.
fn benchDecode(allocator: std.mem.Allocator, path: []const u8, results: *std.ArrayListUnmanaged(Result)) !void {
    if (!fixtureExists(path)) {
        std.debug.print("skip (missing fixture): {s}\n", .{path});
        return;
    }

    var reader = try MmapReader.init(path);
    defer reader.deinit();

    var dem: Demuxer = .{};
    try dem.open(allocator, &reader);
    defer dem.deinit(allocator);

    const frame_count = dem.track.frame_count;
    if (frame_count == 0) return;

    var frame: DecodedFrame = .{};
    defer frame.deinit(allocator);

    // Untimed warm-up pass: touches every sample's mmap pages and primes
    // the decode path so the page-cache/allocator cost doesn't land in a
    // timed sample.
    for (0..frame_count) |i| {
        const sample = dem.sampleData(&reader, @intCast(i)) orelse continue;
        try core.decoder.decode(allocator, sample, &frame);
    }

    var pass_ms: [decode_passes]f64 = undefined;
    var timer = Timer.start();

    for (0..decode_passes) |p| {
        timer.reset();
        for (0..frame_count) |i| {
            const sample = dem.sampleData(&reader, @intCast(i)) orelse continue;
            try core.decoder.decode(allocator, sample, &frame);
        }
        pass_ms[p] = nsToMs(timer.read());
    }

    const ms_per_frame = median(&pass_ms) / @as(f64, @floatFromInt(frame_count));

    try results.append(allocator, .{
        .name = try std.fmt.allocPrint(allocator, "decode/{s}", .{fixtureName(path)}),
        .unit = "ms/frame",
        .value = ms_per_frame,
    });
}

fn fixtureExists(path: []const u8) bool {
    var reader = MmapReader.init(path) catch return false;
    reader.deinit();
    return true;
}

/// The bare filename ("hap1.mov") from a "tests/fixtures/hap1.mov" path, for
/// use in metric names.
fn fixtureName(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// Sorts `samples` in place and returns the median. `samples.len` is always
/// one of this file's fixed iteration counts, so no empty-slice guard.
fn median(samples: []f64) f64 {
    std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    const mid = samples.len / 2;
    if (samples.len % 2 == 0) {
        return (samples[mid - 1] + samples[mid]) / 2.0;
    }
    return samples[mid];
}

fn printTable(results: []const Result) void {
    std.debug.print("{s:<28} {s:>12} {s:>10}\n", .{ "name", "value", "unit" });
    for (results) |r| {
        std.debug.print("{s:<28} {d:>12.4} {s:>10}\n", .{ r.name, r.value, r.unit });
    }
}

/// Writes `results` as a github-action-benchmark `customSmallerIsBetter`
/// JSON array: `[{"name", "unit", "value"}, ...]`.
fn writeJson(allocator: std.mem.Allocator, io: std.Io, path: []const u8, results: []const Result) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(results, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
}
