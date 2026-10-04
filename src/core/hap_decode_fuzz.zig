//! hap_decode_fuzz.zig -- zig-native fuzz harness for decoder.decode(), the
//! per-frame Hap parser/decompressor (hap_decode.zig, invoked through
//! decoder.zig). Mirrors demuxer_fuzz.zig's Smith-based pattern -- see that
//! module's doc comment for the shared rationale (corpus replay semantics,
//! why coverage-guided `--fuzz` doesn't link for this project, and the
//! HAP_FUZZ_SECONDS bounded loop as the practical local substitute). This
//! file only covers what's different:
//!
//!  * The target is a single frame's bytes, not a whole MOV container, and
//!    the interesting bugs live deep inside section/table parsing -- raw
//!    random bytes almost never get past the first 4-byte header check
//!    (`readSectionHeader`'s size-vs-buffer bound). So on top of raw random
//!    bytes, this harness also seeds the loop with syntactically valid
//!    frames (built with the same buildRawFrame/createChunkedFrame builders
//!    the unit tests use, covering every supported format nibble, the
//!    Complex/chunked path, and a Multi-Image/HapM frame) and mutates them
//!    (byte flips, truncation, splices) so generated inputs still parse far
//!    enough to stress section-table bounds and chunk decode instructions.
//!  * The invariant checked is decoder.zig's own contract: no crash, no
//!    leak (testing.allocator), no hang, and on error `output` is left
//!    empty (`error.InvalidFrame`/`error.OutOfMemory` are both an expected,
//!    passing outcome -- only a mismatch with that contract, or a crash,
//!    fails the run).
//!  * The existing tests/fixtures/fuzz_regressions/*.bin corpus (whole MOV
//!    files, not Hap frames) is replayed here too -- free coverage; they
//!    should all cleanly fail frame-level parsing with error.InvalidFrame.

const std = @import("std");
const testing = std.testing;

const mmap_reader = @import("mmap_reader.zig");
const decoder_mod = @import("decoder.zig");
const hap_frame = @import("hap_frame.zig");
const test_support = @import("test_support.zig");

const MmapReader = mmap_reader.MmapReader;
const DecodedFrame = hap_frame.DecodedFrame;

/// Cap on the byte buffer handed to decoder.decode() per fuzz iteration. A
/// single Hap frame is far smaller than a whole MOV; 1 MiB is generous and
/// keeps iterations fast.
const max_input_len = 1 << 20; // 1 MiB

/// Section type byte for a top-level Multi-Image (HapM) container --
/// hap_decode.zig's private `section_multi_image`, duplicated here per this
/// project's no-cross-file-export-for-one-constant convention (see
/// hap_decode.zig's own wire-format constants, similarly duplicated in
/// test_support.zig).
const section_multi_image: u8 = 0x0D;

/// Decode `smith`'s bytes through decoder.decode() and check the contract:
/// success, or a typed error with `output` left empty. Anything else
/// (a crash, a leak caught by testing.allocator, or a mismatch here) fails
/// the fuzz run.
fn fuzzDecode(context: void, smith: *testing.Smith) !void {
    _ = context;

    var buf: [max_input_len]u8 = undefined;
    const len = smith.slice(&buf);

    var output: DecodedFrame = .{};
    defer output.deinit(testing.allocator);

    decoder_mod.decode(testing.allocator, buf[0..len], &output) catch {
        try testing.expectEqual(@as(usize, 0), output.textures.items.len);
        return;
    };
}

// -----------------------------------------------------------------------
// Structure-aware seed frames: syntactically valid Hap frames the mutation
// loop below starts from, so it penetrates past the top-level header check
// into section/table parsing.
// -----------------------------------------------------------------------

/// Build a handful of syntactically valid Hap frames covering: every
/// supported None-compressor format nibble, the two rejected BC6H (Hap HDR)
/// nibbles, Complex (chunked) frames with compressible chunk data (so some
/// chunks take the Snappy path), a Multi-Image (HapM) frame wrapping two
/// single-texture sub-sections, and an extended (8-byte) section header.
/// Caller frees each entry and the list itself via freeSeedFrames.
fn buildSeedFrames(allocator: std.mem.Allocator) !std.ArrayListUnmanaged([]u8) {
    var list = std.ArrayListUnmanaged([]u8).empty;
    errdefer freeSeedFrames(allocator, &list);

    const bc: [32]u8 = @splat(0x11);

    // None-compressor, one frame per supported format nibble.
    inline for (.{ 0xAB, 0xAE, 0xAF, 0xA1, 0xAC }) |type_byte| {
        try list.append(allocator, try test_support.buildRawFrame(allocator, &bc, type_byte));
    }

    // BC6H (Hap HDR): known-but-rejected nibbles, a distinct early-reject path.
    inline for (.{ 0xA2, 0xA3 }) |type_byte| {
        try list.append(allocator, try test_support.buildRawFrame(allocator, &bc, type_byte));
    }

    // Complex (chunked): compressible data so createChunkedFrame's own
    // per-chunk none-vs-snappy choice exercises both compressor paths.
    var compressible: [512]u8 = undefined;
    @memset(&compressible, 0x42);
    inline for (.{ 1, 2, 5 }) |chunk_count| {
        try list.append(allocator, try test_support.createChunkedFrame(allocator, &compressible, chunk_count, .rgb_dxt1));
    }

    // Multi-Image (HapM): two single-texture sub-sections back to back,
    // wrapped in a section_multi_image container. buildRawFrame's output
    // shape ([size24][type][payload]) is exactly the generic section
    // encoding, so it doubles as the sub-section/container builder here.
    {
        const sub0 = try test_support.buildRawFrame(allocator, &bc, 0xAF); // None|YCoCg
        defer allocator.free(sub0);
        const sub1 = try test_support.buildRawFrame(allocator, &bc, 0xA1); // None|A_RGTC1
        defer allocator.free(sub1);

        const body = try allocator.alloc(u8, sub0.len + sub1.len);
        defer allocator.free(body);
        @memcpy(body[0..sub0.len], sub0);
        @memcpy(body[sub0.len..], sub1);

        try list.append(allocator, try test_support.buildRawFrame(allocator, body, section_multi_image));
    }

    // Extended (8-byte) section header, zero-length payload -- forces the
    // 24-bit-size-zero branch in readSectionHeader.
    try list.append(allocator, try test_support.buildSectionExt(allocator, 0xAB, &.{}));

    return list;
}

fn freeSeedFrames(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]u8)) void {
    for (list.items) |f| allocator.free(f);
    list.deinit(allocator);
}

// -----------------------------------------------------------------------
// Smoke test: the existing MOV-file regression corpus (replayed here for
// free coverage -- they're whole containers, not Hap frames, so they should
// all cleanly return error.InvalidFrame) plus the synthetic seed frames
// above. Under a plain `zig build test` each corpus entry is replayed once
// (through Smith's length-prefix-quirked read -- see demuxer_fuzz.zig's doc
// comment) plus one implicit empty-input run.
// -----------------------------------------------------------------------

const regression_paths = [_][]const u8{
    "tests/fixtures/fuzz_regressions/crash_0c3b48b5_ts_overflow.bin",
    "tests/fixtures/fuzz_regressions/crash_36735b5f.bin",
    "tests/fixtures/fuzz_regressions/crash_783ca462.bin",
    "tests/fixtures/fuzz_regressions/crash_85883b19.bin",
    "tests/fixtures/fuzz_regressions/leak_9b88d453.bin",
    "tests/fixtures/fuzz_regressions/oom_9c36f721.bin",
};

test "fuzz decoder.decode on arbitrary bytes" {
    var readers: [regression_paths.len]MmapReader = undefined;
    var opened: usize = 0;
    defer for (readers[0..opened]) |*r| r.deinit();

    var seeds = try buildSeedFrames(testing.allocator);
    defer freeSeedFrames(testing.allocator, &seeds);

    var corpus = std.ArrayListUnmanaged([]const u8).empty;
    defer corpus.deinit(testing.allocator);

    for (regression_paths) |path| {
        readers[opened] = MmapReader.init(path) catch continue; // fixture missing: skip, don't fail the suite
        try corpus.append(testing.allocator, readers[opened].data);
        opened += 1;
    }
    for (seeds.items) |frame| try corpus.append(testing.allocator, frame);

    try testing.fuzz({}, fuzzDecode, .{ .corpus = corpus.items });
}

// -----------------------------------------------------------------------
// Opt-in, time-boxed random fuzz loop -- see demuxer_fuzz.zig's doc comment
// for why this "dumb" (uncoverage-guided) loop is the practical local
// substitute for `zig build test --fuzz` on this module. Each iteration
// picks one of two generation strategies: raw random bytes, or a mutated
// copy of one of the seed frames above (byte flip / truncate / splice).
// -----------------------------------------------------------------------

/// Cap on the random-bytes strategy's generated length -- large enough to
/// reach deep into a frame, small enough to keep iterations fast.
const random_bytes_cap = 1 << 17; // 128 KiB

fn fillRandomBytes(random: std.Random, buf: []u8) usize {
    const cap = @min(buf.len, random_bytes_cap);
    const len = random.intRangeAtMost(usize, 0, cap);
    random.bytes(buf[0..len]);
    return len;
}

/// Copy a random seed frame into `buf` and apply a small number of random
/// mutations (byte flip, truncation, or a short random splice), returning
/// the resulting length. Mutating real frames -- rather than only ever
/// generating fresh random bytes -- is what lets this loop reach
/// section-table and chunk-bounds logic that a valid header alone gates.
fn mutateSeed(random: std.Random, seeds: []const []const u8, buf: []u8) usize {
    if (seeds.len == 0) return 0;

    const seed = seeds[random.intRangeLessThan(usize, 0, seeds.len)];
    var len = @min(seed.len, buf.len);
    @memcpy(buf[0..len], seed[0..len]);

    const mutation_count = random.intRangeAtMost(u32, 1, 8);
    var i: u32 = 0;
    while (i < mutation_count) : (i += 1) {
        if (len == 0) break;
        switch (random.intRangeLessThan(u8, 0, 3)) {
            0 => { // flip a random byte
                const idx = random.intRangeLessThan(usize, 0, len);
                buf[idx] = random.int(u8);
            },
            1 => { // truncate to a random shorter (or equal) length
                len = random.intRangeAtMost(usize, 0, len);
            },
            2 => { // splice a few random bytes in at a random offset
                const splice_len = random.intRangeAtMost(usize, 1, 16);
                if (len + splice_len > buf.len) continue;
                const at = random.intRangeAtMost(usize, 0, len);
                std.mem.copyBackwards(u8, buf[at + splice_len ..][0 .. len - at], buf[at..len]);
                random.bytes(buf[at..][0..splice_len]);
                len += splice_len;
            },
            else => unreachable,
        }
    }
    return len;
}

test "bounded randomized fuzz (opt-in via HAP_FUZZ_SECONDS)" {
    const raw = std.c.getenv("HAP_FUZZ_SECONDS") orelse return error.SkipZigTest;
    const seconds = std.fmt.parseInt(u32, std.mem.span(raw), 10) catch return error.SkipZigTest;

    var seeds = try buildSeedFrames(testing.allocator);
    defer freeSeedFrames(testing.allocator, &seeds);

    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();

    const start_ms = test_support.nowMs();
    const deadline_ms = start_ms + @as(i64, seconds) * std.time.ms_per_s;

    var iterations: u64 = 0;
    var buf: [max_input_len]u8 = undefined;
    while (test_support.nowMs() < deadline_ms) : (iterations += 1) {
        const len = if (random.boolean())
            fillRandomBytes(random, &buf)
        else
            mutateSeed(random, seeds.items, &buf);

        var smith: testing.Smith = .{ .in = buf[0..len] };
        try fuzzDecode({}, &smith);
    }

    std.debug.print(
        "bounded randomized fuzz (decoder): {d} iterations in {d}s\n",
        .{ iterations, seconds },
    );
}
