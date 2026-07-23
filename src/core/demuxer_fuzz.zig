//! demuxer_fuzz.zig -- zig-native fuzz harness for Demuxer.open(), the
//! untrusted-structure surface (arbitrary bytes claiming to be a Hap MOV).
//!
//! Zig 0.16 ships a built-in structured fuzzer (`std.testing.fuzz` +
//! `std.testing.Smith`) instead of libFuzzer: rather than handing the
//! target function a raw byte buffer, the test asks a `*Smith` for
//! values/bytes/slices. Under `zig build test --fuzz[=N]` those calls are
//! answered by Zig's own coverage-guided engine (in-process, LLVM SanCov
//! -style edge coverage); under a plain `zig build test` (no --fuzz) they
//! are answered deterministically from each `FuzzInputOptions.corpus`
//! entry (one replay per entry, `Smith.in` set to that entry's bytes) plus
//! one final implicit empty-input smoke run. See
//! lib/zig/compiler/test_runner.zig's `fuzz()` for the exact semantics --
//! that is also where a crash currently surfaces: the child process
//! prints the error/stack trace to stderr and exits, but 0.16 does not
//! persist a crashing input to disk anywhere (no libFuzzer-style
//! `crash-<hash>` artifact file). A real finding must be captured from the
//! run's stderr while it is still on screen (or bisected from the corpus)
//! and turned into a fixture under tests/fixtures/fuzz_regressions/,
//! replayed by fuzz_regressions_test.zig.
//!
//! MmapReader only maps real files by design (a deliberate constraint for
//! production use), but its fields are public, so this harness builds an
//! in-memory `MmapReader{ .data = ..., .path = "<fuzz>" }` directly --
//! functionally identical to a real mmap from Demuxer.open()'s point of
//! view (it only ever reads through `reader.data`) and avoids
//! per-iteration file I/O.
//!
//! Corpus seeding: the real .mov fixtures and the fuzz_regressions crash
//! corpus are read at test-startup via `MmapReader` (same relative-path
//! convention as mmap_reader.zig's and fuzz_regressions_test.zig's fixture
//! tests -- `zig build test` runs with the repo root as its cwd) and
//! passed to `FuzzInputOptions.corpus`. `@embedFile` was tried first but
//! doesn't work here: zig 0.16 enforces that `@embedFile` targets stay
//! within the *compiling module's* package path (the directory containing
//! its root_source_file, src/core/ for this module), so a
//! `@embedFile("../../tests/fixtures/...")` is rejected at comptime with
//! "embed of file outside package path" -- `Module.addEmbedPath` does not
//! help; it only extends the C-source `#embed` search path, not
//! `@embedFile`'s. Reading the corpus at runtime sidesteps the boundary
//! entirely and matches the pattern already used elsewhere in this file's
//! package.
//!
//! Seeding is also not a literal-byte replay: `Smith.slice()` reads a
//! 4-byte little-endian length prefix off the front of each corpus entry
//! before treating the remainder as content, and clamps to the target
//! buffer size. That is a structural property of Zig's Smith-based fuzzer
//! (every `smith.*` accessor consumes a fixed grammar from the backing
//! bytes, not raw pass-through) and is inherently different from
//! AFL/libFuzzer-style raw corpus replay -- there is no way to seed the
//! exact original bytes through the public API in 0.16. It still
//! exercises Demuxer.open() against real MOV byte content on every plain
//! `zig build test` run, just offset and length-capped.
//!
//! `zig build test --fuzz` (the real coverage-guided engine) does not
//! currently link for this module: `-ffuzz` instruments the vendored C
//! sources (hap.c, minimp4.c, snappy.cc) with clang's classic
//! `-fsanitize-coverage=trace-cmp` calls (`__sanitizer_cov_trace_cmp*` /
//! `_switch` / `_const_cmp*`), but Zig's own from-scratch fuzzer runtime
//! doesn't implement that ABI -- only the pure-Zig coverage path does,
//! confirmed with a minimal C-source-free repro on this toolchain
//! (zig 0.16.0, aarch64-macos), which links and fuzzes fine under
//! `--fuzz`. Separately, `--fuzz` in `-Dtest-optimize=Debug` hits an unrelated
//! zig 0.16.0 std lib bug (a `*builtin.StackTrace` / `*debug.StackTrace`
//! type mismatch in `compiler/test_runner.zig`'s failure-reporting path),
//! reproducible even in a pure-Zig project -- so `--fuzz` is only
//! reachable at all in `-Dtest-optimize=ReleaseFast`/`ReleaseSafe`, and even
//! then only for C-source-free modules. Given this module always compiles
//! the vendored C libraries, the coverage-guided engine is unusable here
//! today; the `HAP_FUZZ_SECONDS`-gated test below is the practical local
//! substitute (see its doc comment).

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

    // Fuzz-found inputs are raw bytes, not valid Hap MOVs in most cases --
    // the only thing under test is that open() returns normally (no
    // crash/leak/hang), not that it succeeds. A typed failure is the
    // expected outcome for almost every input.
    dem.open(testing.allocator, &reader) catch {};
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

// Opt-in, time-boxed random fuzz loop -- the practical local substitute
// for `zig build test --fuzz` while that engine can't link against this
// module's vendored C sources (see the module doc comment). No-op unless
// `HAP_FUZZ_SECONDS` is set (skipped, not run, on a plain
// `zig build test`); driven by scripts/fuzz_demuxer.sh.
//
// This is "dumb" (uncoverage-guided) random fuzzing: each iteration
// fills a buffer from a PRNG and feeds it to `Smith.in`, the same
// deterministic-replay path corpus entries take above -- there is no
// feedback loop steering generation toward new coverage, just volume.
// Still meaningfully exercises Demuxer.open()'s bounds/overflow guards
// against a wide spread of malformed inputs per run.
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
