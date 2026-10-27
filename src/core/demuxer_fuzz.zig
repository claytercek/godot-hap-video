//! Fuzz Demuxer.open() with arbitrary bytes presented as Hap MOV files.
//! Construct `MmapReader{ .data = ..., .path = "<fuzz>" }` in memory to avoid
//! per-iteration file I/O; the demuxer reads only reader.data.
//!
//! Zig 0.16's std.testing.fuzz/Smith API generates structured values and
//! slices. `zig build test --fuzz[=N]` uses its in-process coverage-guided
//! engine with LLVM SanCov-style edge coverage. Plain `zig build test`
//! replays each FuzzInputOptions.corpus entry through Smith.in, then runs
//! one implicit empty-input case (see lib/zig/compiler/test_runner.zig).
//! Crashes print errors and stack traces to stderr; Zig 0.16 does not save
//! crash-<hash> files. Capture findings from stderr or bisect the corpus,
//! then add fixtures to tests/fixtures/fuzz_regressions/ for exact replay
//! by fuzz_regressions_test.zig.
//!
//! Load MOV fixtures and regression inputs at startup with MmapReader;
//! paths are relative to the repo root, the test working directory.
//! Zig 0.16 restricts @embedFile to the compiling module's package path
//! (src/core/). `@embedFile("../../tests/fixtures/...")` fails with
//! "embed of file outside package path". Module.addEmbedPath only extends
//! C #embed searches, so the corpus must be loaded at runtime.
//!
//! Smith replay transforms corpus bytes: Smith.slice() consumes a 4-byte
//! little-endian length prefix and clamps the remainder to the target
//! buffer. Smith accessors consume a grammar; Zig 0.16's public API cannot
//! replay seed bytes verbatim. Plain tests therefore exercise offset,
//! length-capped MOV content rather than exact original files.
//!
//! `zig build test --fuzz` fails to link this module: -ffuzz instruments
//! minimp4.c/snappy.cc with clang -fsanitize-coverage=trace-cmp calls
//! (__sanitizer_cov_trace_cmp*, _switch, _const_cmp*) that Zig's fuzzer
//! runtime does not implement. This also failed on Zig 0.17.0,
//! aarch64-macos. scripts/fuzz_demuxer.sh tries coverage-guided fuzzing with
//! -Dtest-optimize=fast, then falls back to the HAP_FUZZ_SECONDS bounded loop.

const std = @import("std");
const testing = std.testing;

const mmap_reader = @import("mmap_reader.zig");
const demuxer_mod = @import("demuxer.zig");
const test_support = @import("test_support.zig");

const MmapReader = mmap_reader.MmapReader;
const Demuxer = demuxer_mod.Demuxer;

/// Cap on the byte buffer handed to Demuxer.open() per fuzz iteration.
/// Comfortably covers every corpus fixture below (largest is ~1.4 MiB).
const max_input_len = 2 << 20; // 2 MiB

fn fuzzOpen(context: void, smith: *testing.Smith) !void {
    _ = context;

    var buf: [max_input_len]u8 = undefined;
    const len = smith.slice(&buf);

    var reader: MmapReader = .{ .data = buf[0..len], .path = "<fuzz>" };
    var dem: Demuxer = .{};
    defer dem.deinit(testing.allocator);

    // Most inputs are invalid MOVs. A typed error is acceptable; crashes,
    // leaks, and hangs fail the run.
    dem.open(testing.allocator, &reader) catch {};
    if (dem.audio) |*audio| {
        var output: [67]f32 = @splat(123);
        const starts = [_]u64{ 0, 1, audio.info.frame_count, std.math.maxInt(u64) };
        for (starts) |start| {
            try testing.expectEqual(@as(usize, 33), audio.read(start, &output));
            try testing.expectEqual(@as(f32, 123), output[66]);
        }
    }
}

const fixture_paths = [_][]const u8{
    "tests/fixtures/hap1.mov",
    "tests/fixtures/hap5.mov",
    "tests/fixtures/hap7.mov",
    "tests/fixtures/hapy.mov",
    "tests/fixtures/hap1_audio.mov",
    "tests/fixtures/hap1_chunked.mov",
    "tests/fixtures/hap5_chunked.mov",
    "tests/fixtures/hapy_chunked.mov",
};

const regression_paths = [_][]const u8{
    "tests/fixtures/fuzz_regressions/crash_0c3b48b5_ts_overflow.bin",
    "tests/fixtures/fuzz_regressions/crash_36735b5f.bin",
    "tests/fixtures/fuzz_regressions/crash_783ca462.bin",
    "tests/fixtures/fuzz_regressions/crash_85883b19.bin",
    "tests/fixtures/fuzz_regressions/leak_9b88d453.bin",
    "tests/fixtures/fuzz_regressions/oom_9c36f721.bin",
};

const corpus_paths = fixture_paths ++ regression_paths;

test "fuzz Demuxer.open on arbitrary bytes" {
    var readers: [corpus_paths.len]MmapReader = undefined;
    var opened: usize = 0;
    defer for (readers[0..opened]) |*r| r.deinit();

    var corpus: [corpus_paths.len][]const u8 = undefined;
    var corpus_len: usize = 0;

    for (corpus_paths) |path| {
        readers[opened] = MmapReader.init(path) catch continue; // fixture missing: skip, don't fail the suite
        corpus[corpus_len] = readers[opened].data;
        opened += 1;
        corpus_len += 1;
    }

    try testing.fuzz({}, fuzzOpen, .{ .corpus = corpus[0..corpus_len] });
}

// Bounded random loop driven by scripts/fuzz_demuxer.sh; skip unless
// HAP_FUZZ_SECONDS is set. Feed PRNG bytes through Smith.in to exercise
// bounds/overflow checks. Generation uses no coverage feedback; this
// substitutes for --fuzz while the vendored C sources prevent linking.
test "bounded randomized fuzz (opt-in via HAP_FUZZ_SECONDS)" {
    const raw = std.c.getenv("HAP_FUZZ_SECONDS") orelse return error.SkipZigTest;
    const seconds = std.fmt.parseInt(u32, std.mem.span(raw), 10) catch return error.SkipZigTest;

    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();

    const start_ms = test_support.nowMs();
    const deadline_ms = start_ms + @as(i64, seconds) * std.time.ms_per_s;

    var iterations: u64 = 0;
    var random_buf: [1 << 17]u8 = undefined; // 128 KiB: fast to fill, plenty to reach header/box parsing
    while (test_support.nowMs() < deadline_ms) : (iterations += 1) {
        const len = random.intRangeAtMost(usize, 0, random_buf.len);
        random.bytes(random_buf[0..len]);

        var smith: testing.Smith = .{ .in = random_buf[0..len] };
        try fuzzOpen({}, &smith);
    }

    std.debug.print(
        "bounded randomized fuzz: {d} iterations in {d}s\n",
        .{ iterations, seconds },
    );
}
