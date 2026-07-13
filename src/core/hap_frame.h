#ifndef HAP_CORE_HAP_FRAME_H
#define HAP_CORE_HAP_FRAME_H

#include <cstdint>
#include <string>
#include <vector>

namespace hap {
namespace core {

/// Hap texture format identifiers (subset of HapTextureFormat from hap.h).
enum class HapTextureFormat : uint32_t {
  RGB_DXT1 = 0x83F0,
  RGBA_DXT5 = 0x83F3,
  YCoCg_DXT5 = 0x01,
  A_RGTC1 = 0x8DBB,
  RGBA_BPTC_UNORM = 0x8E8C,
};

/// Decoded texture data for one texture in a frame.
struct DecodedTexture {
  std::vector<uint8_t> data;
  HapTextureFormat format = HapTextureFormat::RGB_DXT1;
};

/// A single decoded Hap frame, carrying one or two textures.
struct DecodedFrame {
  std::vector<DecodedTexture> textures;
};

/// FourCC code as a 32-bit integer (big-endian in file, stored host-endian).
struct FourCC {
  uint32_t value = 0;

  FourCC() = default;
  constexpr explicit FourCC(uint32_t v) : value(v) {}
  constexpr FourCC(char a, char b, char c, char d)
      : value((static_cast<uint32_t>(a) << 24) |
              (static_cast<uint32_t>(b) << 16) |
              (static_cast<uint32_t>(c) << 8) |
              (static_cast<uint32_t>(d))) {}

  bool operator==(FourCC other) const { return value == other.value; }
  bool operator!=(FourCC other) const { return value != other.value; }

  std::string to_string() const {
    char buf[5] = {static_cast<char>((value >> 24) & 0xFF),
                   static_cast<char>((value >> 16) & 0xFF),
                   static_cast<char>((value >> 8) & 0xFF),
                   static_cast<char>((value)&0xFF), '\0'};
    return std::string(buf);
  }
};

// Known Hap FourCCs
constexpr FourCC FCC_Hap1{'H', 'a', 'p', '1'}; // Hap (BC1/DXT1)
constexpr FourCC FCC_Hap5{'H', 'a', 'p', '5'}; // Hap Alpha (BC3/DXT5)
constexpr FourCC FCC_HapY{'H', 'a', 'p', 'Y'}; // Hap Q (YCoCg-DXT5)
constexpr FourCC FCC_HapM{'H', 'a', 'p', 'M'}; // Hap Q Alpha (dual texture)
constexpr FourCC FCC_Hap7{'H', 'a', 'p', '7'}; // Hap R (BC7/BPTC)

// Unsupported Hap FourCCs (used for testing the error path)
constexpr FourCC FCC_HapA{'H', 'a', 'p', 'A'}; // HapA (alpha-only, unsupported)
constexpr FourCC FCC_HapHDR{'H', 'a', 'p', 'H'}; // Hap HDR (BC6, unsupported)

/// Check if a FourCC is a known (supported) Hap variant.
inline bool is_known_hap_fourcc(FourCC fourcc) {
  return fourcc == FCC_Hap1 || fourcc == FCC_Hap5 ||
         fourcc == FCC_HapY || fourcc == FCC_HapM ||
         fourcc == FCC_Hap7;
}

/// Result of parsing an stsd box.
enum class StsdResult {
  NoMatch,       ///< No Hap variant found in this stsd.
  Found,         ///< A supported Hap variant was found.
  Unsupported,   ///< An unsupported Hap variant was found (HapA, Hap HDR, etc.).
};

/// Parsed track dimensions and FourCC from stsd.
struct VideoFormat {
  FourCC fourcc;
  uint32_t width = 0;
  uint32_t height = 0;
};

/// Video track metadata extracted from the MOV container.
struct VideoTrackInfo {
  FourCC fourcc;             // The stsd sample entry FourCC
  uint32_t width = 0;        // Frame width in pixels
  uint32_t height = 0;       // Frame height in pixels
  uint32_t frame_count = 0;  // Number of frames/samples
  double frame_rate = 0.0;   // Computed from timescale/duration
  uint32_t timescale = 0;    // Media timescale (tick rate)

  /// Block size for this format's compressed texture data.
  uint32_t block_size() const {
    switch (fourcc.value) {
    case FCC_Hap1.value: return 8;  // BC1: 8 bytes per 4x4 block
    case FCC_Hap5.value: return 16; // BC3: 16 bytes per 4x4 block
    case FCC_HapY.value: return 16; // YCoCg-DXT5: same as BC3
    case FCC_HapM.value: return 16; // Dual-texture, color is BC3
    case FCC_Hap7.value: return 16; // BC7: 16 bytes per 4x4 block
    default: return 8;
    }
  }

  /// Bytes per frame for single-texture variants.
  uint32_t frame_bytes() const {
    uint32_t blocks_x = (width + 3) / 4;
    uint32_t blocks_y = (height + 3) / 4;
    return blocks_x * blocks_y * block_size();
  }
};

/// A cached sample entry: offset into the file and byte size.
struct SampleEntry {
  uint64_t offset = 0;
  uint32_t size = 0;
};

/// Result of opening/demuxing a Hap video file. On success, read the parsed
/// track and sample cache via Demuxer::track_info() / Demuxer::samples().
struct DemuxResult {
  bool valid = false;
  std::string error_message;
};

} // namespace core
} // namespace hap

#endif // HAP_CORE_HAP_FRAME_H