//! hap_frame.zig
//!
//! Pure data types shared by the demuxer/decoder: texture format tags,
//! decoded-frame containers, FourCC handling and video-track metadata.
//! No behavior beyond a couple of small helpers.

const std = @import("std");

/// Hap texture format identifiers (subset of HapTextureFormat from hap.h).
pub const HapTextureFormat = enum(u32) {
    rgb_dxt1 = 0x83F0,
    rgba_dxt5 = 0x83F3,
    ycocg_dxt5 = 0x01,
    a_rgtc1 = 0x8DBB,
    rgba_bptc_unorm = 0x8E8C,
};

/// Decoded texture data for one texture in a frame.
pub const DecodedTexture = struct {
    data: std.ArrayListUnmanaged(u8) = .empty,
    format: HapTextureFormat = .rgb_dxt1,

    pub fn deinit(self: *DecodedTexture, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }
};

/// A single decoded Hap frame, carrying one or two textures.
pub const DecodedFrame = struct {
    textures: std.ArrayListUnmanaged(DecodedTexture) = .empty,

    pub fn deinit(self: *DecodedFrame, allocator: std.mem.Allocator) void {
        for (self.textures.items) |*texture| texture.deinit(allocator);
        self.textures.deinit(allocator);
    }
};

/// FourCC code as a 32-bit integer (big-endian in file, stored host-endian).
pub const FourCC = struct {
    value: u32 = 0,

    pub fn init(value: u32) FourCC {
        return .{ .value = value };
    }

    pub fn initChars(a: u8, b: u8, c: u8, d: u8) FourCC {
        return .{
            .value = (@as(u32, a) << 24) | (@as(u32, b) << 16) |
                (@as(u32, c) << 8) | @as(u32, d),
        };
    }

    pub fn eql(self: FourCC, other: FourCC) bool {
        return self.value == other.value;
    }

    /// Renders the four bytes as ASCII into a stack-allocated fixed array;
    /// no allocation.
    pub fn toString(self: FourCC) [4]u8 {
        return .{
            @truncate(self.value >> 24),
            @truncate(self.value >> 16),
            @truncate(self.value >> 8),
            @truncate(self.value),
        };
    }
};

// Known Hap FourCCs
pub const fcc_hap1 = FourCC.initChars('H', 'a', 'p', '1'); // Hap (BC1/DXT1)
pub const fcc_hap5 = FourCC.initChars('H', 'a', 'p', '5'); // Hap Alpha (BC3/DXT5)
pub const fcc_hapy = FourCC.initChars('H', 'a', 'p', 'Y'); // Hap Q (YCoCg-DXT5)
pub const fcc_hapm = FourCC.initChars('H', 'a', 'p', 'M'); // Hap Q Alpha (dual texture)
pub const fcc_hap7 = FourCC.initChars('H', 'a', 'p', '7'); // Hap R (BC7/BPTC)

// Unsupported Hap FourCCs (used for testing the error path)
pub const fcc_hapa = FourCC.initChars('H', 'a', 'p', 'A'); // HapA (alpha-only, unsupported)
pub const fcc_haphdr = FourCC.initChars('H', 'a', 'p', 'H'); // Hap HDR (BC6, unsupported)

/// Single source of truth for every supported Hap variant used by the
/// decoder and presenter. Known-but-unsupported FourCCs intentionally have
/// no enum tag, so they cannot cross the demux boundary as an operational
/// format. Adding or retiring a supported Hap variant should only ever
/// require editing this enum plus the corresponding godot-format switch in
/// gpu_presenter.zig.
pub const HapVariant = enum {
    hap1, // Hap (BC1/DXT1)
    hap5, // Hap Alpha (BC3/DXT5)
    hapy, // Hap Q (YCoCg-DXT5)
    hapm, // Hap Q Alpha (dual texture)
    hap7, // Hap R (BC7/BPTC)

    /// True for the variants that decode via the YCoCg->RGB compute path
    /// (HapY, HapM) rather than being presented pass-through.
    pub fn isYcocg(self: HapVariant) bool {
        return self == .hapy or self == .hapm;
    }

    /// True for variants whose frame carries an alpha channel.
    pub fn hasAlpha(self: HapVariant) bool {
        return self == .hapm or self == .hap5;
    }

    /// Compressed texture block size in bytes for this variant's primary
    /// (color) texture.
    pub fn blockSize(self: HapVariant) u32 {
        return switch (self) {
            .hap1 => 8, // BC1: 8 bytes per 4x4 block
            .hap5, .hapy, .hapm, .hap7 => 16, // BC3/BC7: 16 bytes per 4x4 block
        };
    }

    /// Fixed compressed texture format for the pass-through variants. Null
    /// for HapY/HapM (format is data-dependent -- read per-frame from the
    /// decoded Hap section header).
    pub fn textureFormat(self: HapVariant) ?HapTextureFormat {
        return switch (self) {
            .hap1 => .rgb_dxt1,
            .hap5 => .rgba_dxt5,
            .hap7 => .rgba_bptc_unorm,
            .hapy, .hapm => null,
        };
    }
};

/// Classify a FourCC as a supported Hap variant. Known-but-unsupported and
/// unrelated FourCCs both return null; use isUnsupportedHapFourcc when the
/// demuxer needs to distinguish them for an error message.
pub fn classify(fourcc: FourCC) ?HapVariant {
    return switch (fourcc.value) {
        fcc_hap1.value => .hap1,
        fcc_hap5.value => .hap5,
        fcc_hapy.value => .hapy,
        fcc_hapm.value => .hapm,
        fcc_hap7.value => .hap7,
        else => null,
    };
}

/// Check if a FourCC is a known (supported) Hap variant.
pub fn isKnownHapFourcc(fourcc: FourCC) bool {
    return classify(fourcc) != null;
}

/// Check whether a FourCC identifies a Hap codec this extension recognizes
/// but cannot decode or present.
pub fn isUnsupportedHapFourcc(fourcc: FourCC) bool {
    return switch (fourcc.value) {
        fcc_hapa.value, fcc_haphdr.value => true,
        else => false,
    };
}

/// Result of parsing an stsd box.
pub const StsdResult = enum {
    no_match, // No Hap variant found in this stsd.
    found, // A supported Hap variant was found.
    unsupported, // An unsupported Hap variant was found (HapA, Hap HDR, etc.).
};

/// Parsed track dimensions and FourCC from stsd.
pub const VideoFormat = struct {
    fourcc: FourCC = .{},
    width: u32 = 0,
    height: u32 = 0,
};

/// Video track metadata extracted from the MOV container.
pub const VideoTrackInfo = struct {
    fourcc: FourCC = .{}, // The stsd sample entry FourCC
    width: u32 = 0, // Frame width in pixels
    height: u32 = 0, // Frame height in pixels
    frame_count: u32 = 0, // Number of frames/samples
    frame_rate: f64 = 0.0, // Computed from timescale/duration
    timescale: u32 = 0, // Media timescale (tick rate)

    /// Block size for this format's compressed texture data. Falls back to
    /// 8 (BC1's block size) for a fourcc `classify()` doesn't recognize at
    /// all, matching the pre-refactor default.
    pub fn blockSize(self: VideoTrackInfo) u32 {
        const variant = classify(self.fourcc) orelse return 8;
        return variant.blockSize();
    }

    /// Bytes per frame for single-texture variants.
    pub fn frameBytes(self: VideoTrackInfo) u32 {
        const blocks_x = (self.width + 3) / 4;
        const blocks_y = (self.height + 3) / 4;
        return blocks_x * blocks_y * self.blockSize();
    }
};

/// A cached sample entry: offset into the file and byte size.
pub const SampleEntry = struct {
    offset: u64 = 0,
    size: u32 = 0,
};

test "FourCC.initChars packs bytes big-endian" {
    const fourcc = FourCC.initChars('H', 'a', 'p', '1');
    try std.testing.expectEqual(@as(u32, 0x48617031), fourcc.value);
}

test "FourCC.eql compares by value" {
    const a = FourCC.initChars('H', 'a', 'p', '1');
    const b = FourCC.init(0x48617031);
    const c = FourCC.initChars('H', 'a', 'p', '5');
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "FourCC.toString renders ASCII bytes" {
    const fourcc = FourCC.initChars('H', 'a', 'p', 'Y');
    try std.testing.expectEqualSlices(u8, "HapY", &fourcc.toString());
}

test "isKnownHapFourcc accepts supported variants" {
    try std.testing.expect(isKnownHapFourcc(fcc_hap1));
    try std.testing.expect(isKnownHapFourcc(fcc_hap5));
    try std.testing.expect(isKnownHapFourcc(fcc_hapy));
    try std.testing.expect(isKnownHapFourcc(fcc_hapm));
    try std.testing.expect(isKnownHapFourcc(fcc_hap7));
}

test "isKnownHapFourcc rejects unsupported variants" {
    try std.testing.expect(!isKnownHapFourcc(fcc_hapa));
    try std.testing.expect(!isKnownHapFourcc(fcc_haphdr));
    try std.testing.expect(!isKnownHapFourcc(FourCC.initChars('X', 'X', 'X', 'X')));
}

test "classify maps only supported FourCCs to operational variants" {
    try std.testing.expectEqual(HapVariant.hap1, classify(fcc_hap1).?);
    try std.testing.expectEqual(HapVariant.hap5, classify(fcc_hap5).?);
    try std.testing.expectEqual(HapVariant.hapy, classify(fcc_hapy).?);
    try std.testing.expectEqual(HapVariant.hapm, classify(fcc_hapm).?);
    try std.testing.expectEqual(HapVariant.hap7, classify(fcc_hap7).?);
    try std.testing.expectEqual(@as(?HapVariant, null), classify(fcc_hapa));
    try std.testing.expectEqual(@as(?HapVariant, null), classify(fcc_haphdr));
    try std.testing.expectEqual(@as(?HapVariant, null), classify(FourCC.initChars('X', 'X', 'X', 'X')));
}

test "isUnsupportedHapFourcc recognizes known unsupported variants" {
    try std.testing.expect(isUnsupportedHapFourcc(fcc_hapa));
    try std.testing.expect(isUnsupportedHapFourcc(fcc_haphdr));
    try std.testing.expect(!isUnsupportedHapFourcc(fcc_hap1));
    try std.testing.expect(!isUnsupportedHapFourcc(FourCC.initChars('X', 'X', 'X', 'X')));
}

test "HapVariant.isYcocg/hasAlpha/textureFormat match the format spec" {
    try std.testing.expect(!HapVariant.hap1.isYcocg());
    try std.testing.expect(!HapVariant.hap1.hasAlpha());
    try std.testing.expectEqual(HapTextureFormat.rgb_dxt1, HapVariant.hap1.textureFormat().?);

    try std.testing.expect(!HapVariant.hap5.isYcocg());
    try std.testing.expect(HapVariant.hap5.hasAlpha());
    try std.testing.expectEqual(HapTextureFormat.rgba_dxt5, HapVariant.hap5.textureFormat().?);

    try std.testing.expect(HapVariant.hapy.isYcocg());
    try std.testing.expect(!HapVariant.hapy.hasAlpha());
    try std.testing.expectEqual(@as(?HapTextureFormat, null), HapVariant.hapy.textureFormat());

    try std.testing.expect(HapVariant.hapm.isYcocg());
    try std.testing.expect(HapVariant.hapm.hasAlpha());
    try std.testing.expectEqual(@as(?HapTextureFormat, null), HapVariant.hapm.textureFormat());

    try std.testing.expect(!HapVariant.hap7.isYcocg());
    try std.testing.expect(!HapVariant.hap7.hasAlpha());
    try std.testing.expectEqual(HapTextureFormat.rgba_bptc_unorm, HapVariant.hap7.textureFormat().?);
}

test "VideoTrackInfo.blockSize matches known Hap variants" {
    var info: VideoTrackInfo = .{ .fourcc = fcc_hap1 };
    try std.testing.expectEqual(@as(u32, 8), info.blockSize());

    info.fourcc = fcc_hap5;
    try std.testing.expectEqual(@as(u32, 16), info.blockSize());

    info.fourcc = fcc_hapy;
    try std.testing.expectEqual(@as(u32, 16), info.blockSize());

    info.fourcc = fcc_hapm;
    try std.testing.expectEqual(@as(u32, 16), info.blockSize());

    info.fourcc = fcc_hap7;
    try std.testing.expectEqual(@as(u32, 16), info.blockSize());

    info.fourcc = FourCC.initChars('X', 'X', 'X', 'X');
    try std.testing.expectEqual(@as(u32, 8), info.blockSize());
}

test "VideoTrackInfo.frameBytes rounds dimensions up to block multiples" {
    // 6x6 pixels rounds up to 2x2 blocks of 8 bytes each (BC1/Hap1).
    const info: VideoTrackInfo = .{ .fourcc = fcc_hap1, .width = 6, .height = 6 };
    try std.testing.expectEqual(@as(u32, 2 * 2 * 8), info.frameBytes());

    // Exact multiple of 4 with a 16-byte block format (Hap5/BC3).
    const info2: VideoTrackInfo = .{ .fourcc = fcc_hap5, .width = 8, .height = 4 };
    try std.testing.expectEqual(@as(u32, 2 * 1 * 16), info2.frameBytes());
}
