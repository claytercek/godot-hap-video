//! Demux Hap MOV files using minimp4 for box traversal and sample tables.
//! Parse `stsd` directly for Hap FourCCs and dimensions because minimp4's
//! allowlist excludes Hap. Classifying tracks by FourCC instead of
//! handler_type avoids minimp4's dual-hdlr bug.
//!
//! Validate and cache video offsets and sizes at open for O(1) random access
//! and SIGBUS mitigation. Embedded PCM owns a separate compact chunk index;
//! unsupported audio produces a warning without failing video open.
//!
//! minimp4_shim.h/.c exposes scalar accessors instead of mirroring
//! MP4D_demux_t/MP4D_track_t in Zig. Their layouts depend on switches such as
//! MINIMP4_ALLOW_64BIT, MP4D_INFO_SUPPORTED, and MP4D_TIMESTAMPS_SUPPORTED;
//! a mismatched field offset would silently corrupt reads.

const std = @import("std");

const hap_frame = @import("hap_frame.zig");
const mmap_reader = @import("mmap_reader.zig");
const pcm_audio = @import("pcm_audio.zig");

const MmapReader = mmap_reader.MmapReader;
const FourCC = hap_frame.FourCC;
const VideoFormat = hap_frame.VideoFormat;
const VideoTrackInfo = hap_frame.VideoTrackInfo;
const SampleEntry = hap_frame.SampleEntry;
const StsdResult = hap_frame.StsdResult;

// -----------------------------------------------------------------------
// minimp4 shim C ABI -- extern decls for minimp4_shim.h, hand-declared (no
// @cImport, per project convention).
// -----------------------------------------------------------------------
const Mp4Ctx = pcm_audio.Mp4Ctx;

extern fn hap_mp4d_open(data: [*]const u8, size: i64) ?*Mp4Ctx;
extern fn hap_mp4d_close(ctx: ?*Mp4Ctx) void;
extern fn hap_mp4d_track_count(ctx: *const Mp4Ctx) c_uint;
extern fn hap_mp4d_track_sample_count(ctx: *const Mp4Ctx, ntrack: c_uint) c_uint;
extern fn hap_mp4d_track_timescale(ctx: *const Mp4Ctx, ntrack: c_uint) c_uint;
extern fn hap_mp4d_frame_offset(
    ctx: *const Mp4Ctx,
    ntrack: c_uint,
    nsample: c_uint,
    frame_bytes: *c_uint,
    timestamp: *c_uint,
    duration: *c_uint,
) u64;

// -----------------------------------------------------------------------
// ISOBMFF box parsing utilities (big-endian) -- pure Zig, no C needed.
// -----------------------------------------------------------------------
const BoxHeader = struct {
    offset: u64,
    size: u64,
    fourcc: u32,
    data_pos: u64,
    // u64, not u32: a >4 GB mdat box is routine for long Hap files, and its
    // header passes through here during the top-level moov scan.
    data_size: u64,
};

const fourcc_moov = FourCC.initChars('m', 'o', 'o', 'v').value;
const fourcc_trak = FourCC.initChars('t', 'r', 'a', 'k').value;
const fourcc_mdia = FourCC.initChars('m', 'd', 'i', 'a').value;
const fourcc_minf = FourCC.initChars('m', 'i', 'n', 'f').value;
const fourcc_stbl = FourCC.initChars('s', 't', 'b', 'l').value;
const fourcc_stsd = FourCC.initChars('s', 't', 's', 'd').value;

fn readBoxHeader(file_data: []const u8, offset: u64) ?BoxHeader {
    const file_size: u64 = file_data.len;
    const header_min_end = std.math.add(u64, offset, 8) catch return null;
    if (header_min_end > file_size) return null;

    const size_raw = std.mem.readInt(u32, file_data[offset..][0..4], .big);
    const box_type = std.mem.readInt(u32, file_data[offset + 4 ..][0..4], .big);

    var box_size: u64 = undefined;
    var header_size: u64 = undefined;

    if (size_raw == 1) {
        const ext_header_end = std.math.add(u64, offset, 16) catch return null;
        if (ext_header_end > file_size) return null;
        box_size = std.mem.readInt(u64, file_data[offset + 8 ..][0..8], .big);
        header_size = 16;
    } else if (size_raw == 0) {
        box_size = file_size - offset;
        header_size = 8;
    } else {
        box_size = size_raw;
        header_size = 8;
    }

    // box_size is attacker-controlled (read from the file), so guard the
    // add against u64 wraparound before comparing to file_size.
    const end = std.math.add(u64, offset, box_size) catch return null;
    if (box_size < header_size or end > file_size) return null;

    return BoxHeader{
        .offset = offset,
        .size = box_size,
        .fourcc = box_type,
        .data_pos = offset + header_size,
        .data_size = box_size - header_size,
    };
}

/// Iterates the direct children of a box's `[pos, end)` byte range,
/// encapsulating the bounds guard and header-advance logic shared by
/// `findChild` and `findTrakAt`.
const BoxIter = struct {
    file_data: []const u8,
    pos: u64,
    end: u64,

    fn next(it: *BoxIter) ?BoxHeader {
        if (it.pos > it.end or it.end - it.pos < 8) return null;
        const child = readBoxHeader(it.file_data, it.pos) orelse return null;
        if (child.size > it.end - it.pos) return null;
        it.pos += child.size;
        return child;
    }
};

/// Find the first direct child in `[start, end)` whose type matches `fourcc`.
fn findChild(file_data: []const u8, start: u64, end: u64, fourcc: u32) ?BoxHeader {
    var it = BoxIter{ .file_data = file_data, .pos = start, .end = end };
    while (it.next()) |child| {
        if (child.fourcc == fourcc) return child;
    }
    return null;
}

fn findTrakAt(file_data: []const u8, start: u64, end: u64, track_index: u32) ?BoxHeader {
    var it = BoxIter{ .file_data = file_data, .pos = start, .end = end };
    var count: u32 = 0;
    while (it.next()) |child| {
        if (child.fourcc == fourcc_trak) {
            if (count == track_index) return child;
            count += 1;
        }
    }
    return null;
}

fn findStsdInTrak(file_data: []const u8, trak: BoxHeader) ?BoxHeader {
    const path = [_]u32{ fourcc_mdia, fourcc_minf, fourcc_stbl, fourcc_stsd };
    var current = trak;
    for (path) |fourcc| {
        current = findChild(file_data, current.data_pos, current.offset + current.size, fourcc) orelse return null;
    }
    return current;
}

/// Demuxer.open() failures. The Godot playback layer formats messages from
/// these tags; UnsupportedHapVariant leaves the offending FourCC in
/// `Demuxer.track.fourcc` for callers to inspect.
pub const OpenError = error{
    /// minimp4 could not parse the file as an MP4/MOV container at all.
    MalformedMp4,
    /// No top-level `moov` box was found.
    NoMoovBox,
    /// The container parsed, but held no Hap video track.
    NoHapTrack,
    /// A Hap track was found, but its variant isn't one this extension can
    /// decode (fourcc is stored on `Demuxer.track.fourcc`).
    UnsupportedHapVariant,
    /// The Hap track reported zero samples.
    ZeroSamples,
    /// The reported sample count is larger than the file itself (corrupt
    /// stsz), which would otherwise drive an absurd allocation.
    TooManySamples,
    /// A cached sample's offset+size runs past the end of the file.
    SamplesExceedFileSize,
} || std.mem.Allocator.Error;

/// Demuxer for Hap-encoded MOV files.
pub const Demuxer = struct {
    mp4: ?*Mp4Ctx = null,
    valid: bool = false,
    track: VideoTrackInfo = .{},
    samples: std.ArrayListUnmanaged(SampleEntry) = .empty,
    audio: ?pcm_audio.Source = null,
    audio_warning: ?pcm_audio.AudioWarning = null,

    /// Releases the PCM index, minimp4 context and cached video sample table.
    /// Safe to call on a zero-value/already-deinited Demuxer.
    pub fn deinit(self: *Demuxer, allocator: std.mem.Allocator) void {
        if (self.audio) |*audio| audio.deinit();
        self.cleanupMp4();
        self.samples.deinit(allocator);
        self.* = .{};
    }

    fn cleanupMp4(self: *Demuxer) void {
        if (self.mp4) |ctx| {
            hap_mp4d_close(ctx);
            self.mp4 = null;
        }
    }

    /// Returns a pointer to the sample data for the given frame index, or
    /// null if the demuxer is not valid or the index is out of range.
    pub fn sampleData(self: *const Demuxer, reader: *const MmapReader, index: u32) ?[]const u8 {
        if (!self.valid or index >= self.samples.items.len) return null;
        const entry = self.samples.items[index];
        return reader.data[entry.offset..][0..entry.size];
    }

    // -----------------------------------------------------------------------
    // stsd box parsing
    //
    // stsd is a FullBox: version(1) + flags(3) + entry_count(4)
    // For each entry (SampleEntry):
    //   size(4) + type(4 {FourCC}) + reserved(6) + data_reference_index(2)
    // VisualSampleEntry (video) continues:
    //   pre_defined(2) + reserved(2) + pre_defined(12) + width(2) + height(2)
    // -----------------------------------------------------------------------

    /// Parse the stsd box payload (i.e. the data past the box header) to
    /// extract FourCC and dimensions. Static/free-standing so it can be
    /// tested without opening a file.
    pub fn parseStsd(data: []const u8, out_format: *VideoFormat) StsdResult {
        const visual_sample_entry_min_size: u32 = 36;

        if (data.len < 8) return .no_match;

        const entry_count = std.mem.readInt(u32, data[4..8], .big);
        var offset: usize = 8; // past full-box header (version+flags+entry_count)

        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            if (offset > data.len or data.len - offset < 8) return .no_match;

            const entry_size = std.mem.readInt(u32, data[offset..][0..4], .big);
            if (entry_size < visual_sample_entry_min_size) return .no_match;

            const entry_end = std.math.add(usize, offset, entry_size) catch return .no_match;
            if (entry_end > data.len) return .no_match;

            const fourcc = FourCC.init(std.mem.readInt(u32, data[offset + 4 ..][0..4], .big));

            if (hap_frame.classify(fourcc) != null) {
                // Dimensions at offset+32: after SampleEntry(16 bytes) +
                // pre_defined(2) + reserved(2) + pre_defined(12) = 32 bytes.
                // The entry-size check above guarantees these fields are
                // contained by this specific sample entry, not merely stsd.
                const dim_offset = offset + 32;
                out_format.width = std.mem.readInt(u16, data[dim_offset..][0..2], .big);
                out_format.height = std.mem.readInt(u16, data[dim_offset + 2 ..][0..2], .big);
                out_format.fourcc = fourcc;
                return .found;
            }

            if (hap_frame.isUnsupportedHapFourcc(fourcc)) {
                out_format.fourcc = fourcc;
                return .unsupported;
            }

            offset = entry_end;
        }

        return .no_match;
    }

    /// Validate sample offsets and sizes with 64-bit arithmetic, preventing
    /// wraparound at 4 GB. Public and static for synthetic large-offset tests
    /// that need no multi-gigabyte fixture.
    pub fn validateSamples(samples: []const SampleEntry, file_size: u64) error{SamplesExceedFileSize}!void {
        for (samples) |sample| {
            // sample.offset/size come from minimp4's parse of attacker-
            // controlled stco/stsz tables, so guard against u64 wraparound.
            const end = std.math.add(u64, sample.offset, @as(u64, sample.size)) catch return error.SamplesExceedFileSize;
            if (end > file_size) return error.SamplesExceedFileSize;
        }
    }

    // -----------------------------------------------------------------------
    // Open: parse the MOV file, find Hap video track, cache all samples
    // -----------------------------------------------------------------------

    /// Open and demux a Hap MOV file from a memory-mapped reader. On success
    /// the parsed track/sample cache is available via `self.track` /
    /// `self.samples`; on failure a precise `OpenError` is returned (and, for
    /// UnsupportedHapVariant, the offending fourcc is left on
    /// `self.track.fourcc`). The reader must outlive the Demuxer.
    pub fn open(self: *Demuxer, allocator: std.mem.Allocator, reader: *const MmapReader) OpenError!void {
        if (self.audio) |*audio| audio.deinit();
        self.audio = null;
        self.audio_warning = null;
        self.cleanupMp4();
        self.samples.clearRetainingCapacity();
        self.track = .{};
        self.valid = false;

        const file_data = reader.data;
        const file_size: u64 = reader.data.len;

        const ctx = hap_mp4d_open(file_data.ptr, @intCast(file_size)) orelse return error.MalformedMp4;
        self.mp4 = ctx;
        errdefer self.cleanupMp4();

        // Find the moov box in the raw file by scanning top-level boxes.
        const moov = findChild(file_data, 0, file_size, fourcc_moov) orelse return error.NoMoovBox;

        // Walk tracks to find the Hap video track. For each track index t
        // (matching minimp4 track order), manually find and parse its stsd
        // box to check for Hap FourCCs.
        const track_count: u32 = @intCast(hap_mp4d_track_count(ctx));
        var hap_track_index: ?u32 = null;
        var unsupported_hap_fourcc: ?FourCC = null;
        var hap_format: VideoFormat = .{};

        var t: u32 = 0;
        while (t < track_count) : (t += 1) {
            const trak = findTrakAt(file_data, moov.data_pos, moov.offset + moov.size, t) orelse continue;
            const stsd = findStsdInTrak(file_data, trak) orelse continue;

            const stsd_data = file_data[stsd.data_pos..][0..stsd.data_size];
            const stsd_result = parseStsd(stsd_data, &hap_format);

            if (stsd_result == .found) {
                hap_track_index = t;
                break;
            }

            if (stsd_result == .unsupported) {
                unsupported_hap_fourcc = hap_format.fourcc;
            }
        }

        const track_index = hap_track_index orelse {
            if (unsupported_hap_fourcc) |fourcc| {
                // Park the offending fourcc so the caller can format a rich
                // "unsupported variant (XXXX)" message on demand.
                self.track.fourcc = fourcc;
                return error.UnsupportedHapVariant;
            }
            return error.NoHapTrack;
        };

        // Extract sample info from minimp4 for the found Hap track.
        const num_samples: u32 = @intCast(hap_mp4d_track_sample_count(ctx, track_index));

        if (num_samples == 0) return error.ZeroSamples;

        // Bound samples by file bytes before reserve(). minimp4's stsz limit
        // (256 MB of 4-byte entries) allowed a small crafted file to trigger
        // a ~1 GB allocation during fuzzing.
        if (@as(u64, num_samples) > file_size) return error.TooManySamples;

        // Cache all sample offsets/sizes, capturing the first sample's
        // duration for the frame-rate computation below.
        var first_sample_duration: u32 = 0;
        try self.samples.ensureTotalCapacityPrecise(allocator, num_samples);

        var i: u32 = 0;
        while (i < num_samples) : (i += 1) {
            var frame_bytes: c_uint = 0;
            var timestamp: c_uint = 0;
            var duration: c_uint = 0;
            const offset = hap_mp4d_frame_offset(ctx, track_index, i, &frame_bytes, &timestamp, &duration);

            if (i == 0) first_sample_duration = duration;

            self.samples.appendAssumeCapacity(.{ .offset = offset, .size = @intCast(frame_bytes) });
        }

        // Validate all samples against file size.
        try validateSamples(self.samples.items, file_size);

        // Populate track info.
        self.track.fourcc = hap_format.fourcc;
        self.track.width = hap_format.width;
        self.track.height = hap_format.height;
        self.track.frame_count = num_samples;
        self.track.timescale = @intCast(hap_mp4d_track_timescale(ctx, track_index));

        // Compute frame rate from the first sample's duration (captured
        // above).
        if (first_sample_duration > 0 and self.track.timescale > 0) {
            self.track.frame_rate = @as(f64, @floatFromInt(self.track.timescale)) /
                @as(f64, @floatFromInt(first_sample_duration));
        }

        self.valid = true;
        self.audio = pcm_audio.Source.open(allocator, file_data, ctx, track_index) catch |err| blk: {
            self.audio_warning = pcm_audio.warningFor(err);
            break :blk null;
        };
    }
};
