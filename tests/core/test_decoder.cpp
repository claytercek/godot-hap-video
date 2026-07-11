/*
 * Core decoder tests.
 *
 * Tests the Hap frame decoder with synthetic data: creates valid Hap1/5/7
 * frames in memory, decodes them, and verifies the output.
 * Also tests unsupported-formats rejection.
 */

#include "core/decoder.h"
#include "core/demuxer.h"
#include "core/hap_frame.h"
#include "core/mmap_reader.h"

#include "hap.h"
#include "test.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <unistd.h>

using namespace hap::core;

// -----------------------------------------------------------------------
// Helper: create a synthetic Hap frame with a given type byte
//
// A Hap frame structure:
//   4-byte header: length(3 bytes LE) + type(1 byte)
//   For single-chunk None compressor:
//     type byte = 0xAB (Hap1), 0xAE (Hap5), 0xAC (Hap7)
//   Frame data = raw BC block bytes (pass-through for None compressor)
// -----------------------------------------------------------------------
static std::vector<uint8_t> create_hap_frame(uint32_t /*width*/,
                                             uint32_t /*height*/,
                                             const uint8_t *bc_data,
                                             size_t bc_size,
                                             uint8_t type_byte) {
  std::vector<uint8_t> frame;

  // 4-byte header: length (3 bytes LE) + type (1 byte)
  uint32_t length = static_cast<uint32_t>(bc_size);
  frame.push_back(length & 0xFF);
  frame.push_back((length >> 8) & 0xFF);
  frame.push_back((length >> 16) & 0xFF);
  frame.push_back(type_byte);

  // Frame data (BC blocks)
  frame.insert(frame.end(), bc_data, bc_data + bc_size);

  return frame;
}

static std::vector<uint8_t> create_hap1_frame(uint32_t w, uint32_t h,
                                              const uint8_t *data, size_t sz) {
  return create_hap_frame(w, h, data, sz, 0xAB);
}

static std::vector<uint8_t> create_hap5_frame(uint32_t w, uint32_t h,
                                              const uint8_t *data, size_t sz) {
  return create_hap_frame(w, h, data, sz, 0xAE);
}

static std::vector<uint8_t> create_hap7_frame(uint32_t w, uint32_t h,
                                              const uint8_t *data, size_t sz) {
  return create_hap_frame(w, h, data, sz, 0xAC);
}

// -----------------------------------------------------------------------
// Hap1 (BC1/DXT1) tests
// -----------------------------------------------------------------------

HAP_TEST(test_decoder_hap1_single_block) {
  // A single 4x4 BC1 block (8 bytes): 2 endpoint colors + 4 bytes indices
  uint8_t bc1_block[8] = {
      0x00, 0x00, // color0: RGB565 = 0 (black)
      0xFF, 0xFF, // color1: RGB565 = 0xFFFF (white)
      0x00, 0x00, 0x00, 0x00, // all indices = 0 (black)
  };

  auto frame = create_hap1_frame(4, 4, bc1_block, sizeof(bc1_block));

  Decoder decoder;
  DecodedFrame output;

  bool ok = decoder.decode(frame.data(), frame.size(), output);
  HAP_ASSERT(ok);
  HAP_ASSERT_EQ(output.textures.size(), 1u);

  const auto &tex = output.textures[0];
  HAP_ASSERT(tex.format == hap::core::HapTextureFormat::RGB_DXT1);
  HAP_ASSERT(!tex.data.empty());
  HAP_ASSERT_EQ(tex.data.size(), 8u); // 8 bytes for BC1 block
  HAP_ASSERT(memcmp(tex.data.data(), bc1_block, 8) == 0);
}

HAP_TEST(test_decoder_hap1_multiple_blocks) {
  // 8x8 pixels = 4 BC1 blocks (2x2 grid)
  uint8_t bc1_blocks[32] = {0};
  // Block 0: black
  bc1_blocks[0] = 0x00;
  bc1_blocks[1] = 0x00;
  // Block 1: white
  bc1_blocks[8] = 0xFF;
  bc1_blocks[9] = 0xFF;
  // Block 2: red
  bc1_blocks[16] = 0x00;
  bc1_blocks[17] = 0xF8;
  // Block 3: blue
  bc1_blocks[24] = 0x1F;
  bc1_blocks[25] = 0x00;

  auto frame = create_hap1_frame(8, 8, bc1_blocks, sizeof(bc1_blocks));

  Decoder decoder;
  DecodedFrame output;

  bool ok = decoder.decode(frame.data(), frame.size(), output);
  HAP_ASSERT(ok);
  HAP_ASSERT_EQ(output.textures.size(), 1u);
  HAP_ASSERT_EQ(output.textures[0].data.size(), 32u); // 4 blocks x 8 bytes
}

HAP_TEST(test_decoder_hap1_multi_texture) {
  // Verify that HapGetFrameTextureCount returns 1 for a single-texture frame
  uint8_t bc1_block[8] = {0};
  auto frame = create_hap1_frame(4, 4, bc1_block, sizeof(bc1_block));

  unsigned int tex_count = 0;
  unsigned int result = HapGetFrameTextureCount(
      frame.data(), static_cast<unsigned long>(frame.size()), &tex_count);
  HAP_ASSERT_EQ(result, (unsigned int)HapResult_No_Error);
  HAP_ASSERT_EQ(tex_count, 1u);
}

// -----------------------------------------------------------------------
// Hap5 (BC3/DXT5) tests
// -----------------------------------------------------------------------

HAP_TEST(test_decoder_hap5_single_block) {
  // A single 4x4 BC3 block (16 bytes): 8 bytes alpha + 8 bytes color
  // Alpha part: endpoints 0x00 and 0xFF, indices all 0
  // Color part: black endpoint, white endpoint, indices all 0
  uint8_t bc3_block[16] = {
      0x00, 0xFF,                // alpha0=0, alpha1=255
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // alpha indices (all 0)
      0x00, 0x00,                // color0: RGB565 = 0 (black)
      0xFF, 0xFF,                // color1: RGB565 = 0xFFFF (white)
      0x00, 0x00, 0x00, 0x00,   // color indices (all 0)
  };

  auto frame = create_hap5_frame(4, 4, bc3_block, sizeof(bc3_block));

  Decoder decoder;
  DecodedFrame output;

  bool ok = decoder.decode(frame.data(), frame.size(), output);
  HAP_ASSERT(ok);
  HAP_ASSERT_EQ(output.textures.size(), 1u);

  const auto &tex = output.textures[0];
  HAP_ASSERT(tex.format == hap::core::HapTextureFormat::RGBA_DXT5);
  HAP_ASSERT(!tex.data.empty());
  HAP_ASSERT_EQ(tex.data.size(), 16u); // 16 bytes for BC3 block
  HAP_ASSERT(memcmp(tex.data.data(), bc3_block, 16) == 0);
}

HAP_TEST(test_decoder_hap5_multi_texture) {
  // Verify texture count is 1 for a Hap5 frame (single texture)
  uint8_t bc3_block[16] = {0};
  auto frame = create_hap5_frame(4, 4, bc3_block, sizeof(bc3_block));

  unsigned int tex_count = 0;
  unsigned int result = HapGetFrameTextureCount(
      frame.data(), static_cast<unsigned long>(frame.size()), &tex_count);
  HAP_ASSERT_EQ(result, (unsigned int)HapResult_No_Error);
  HAP_ASSERT_EQ(tex_count, 1u);
}

// -----------------------------------------------------------------------
// Hap7 (BC7/BPTC) tests
// -----------------------------------------------------------------------

HAP_TEST(test_decoder_hap7_single_block) {
  // A single 4x4 BC7 block (16 bytes).  BC7 is pass-through for None
  // compressor, so we use a simple known pattern.
  uint8_t bc7_block[16] = {
      0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  };

  auto frame = create_hap7_frame(4, 4, bc7_block, sizeof(bc7_block));

  Decoder decoder;
  DecodedFrame output;

  bool ok = decoder.decode(frame.data(), frame.size(), output);
  HAP_ASSERT(ok);
  HAP_ASSERT_EQ(output.textures.size(), 1u);

  const auto &tex = output.textures[0];
  HAP_ASSERT(tex.format == hap::core::HapTextureFormat::RGBA_BPTC_UNORM);
  HAP_ASSERT(!tex.data.empty());
  HAP_ASSERT_EQ(tex.data.size(), 16u); // 16 bytes for BC7 block
  HAP_ASSERT(memcmp(tex.data.data(), bc7_block, 16) == 0);
}

HAP_TEST(test_decoder_hap7_multi_texture) {
  // Verify texture count is 1 for a Hap7 frame
  uint8_t bc7_block[16] = {0};
  auto frame = create_hap7_frame(4, 4, bc7_block, sizeof(bc7_block));

  unsigned int tex_count = 0;
  unsigned int result = HapGetFrameTextureCount(
      frame.data(), static_cast<unsigned long>(frame.size()), &tex_count);
  HAP_ASSERT_EQ(result, (unsigned int)HapResult_No_Error);
  HAP_ASSERT_EQ(tex_count, 1u);
}

// -----------------------------------------------------------------------
// Golden-frame tests: byte-exact BC block comparison
// -----------------------------------------------------------------------

HAP_TEST(test_decoder_hap1_golden_frame) {
  // 16x8 pixels = 4 BC1 blocks (2x2 grid)
  uint8_t bc1_blocks[32];

  // Block 0 (top-left): white (0xFFFF, 0x0000, indices all 0)
  bc1_blocks[0] = 0xFF; bc1_blocks[1] = 0xFF;
  bc1_blocks[2] = 0x00; bc1_blocks[3] = 0x00;
  bc1_blocks[4] = 0x00; bc1_blocks[5] = 0x00;
  bc1_blocks[6] = 0x00; bc1_blocks[7] = 0x00;

  // Block 1 (top-right): black
  bc1_blocks[8] = 0x00; bc1_blocks[9] = 0x00;
  bc1_blocks[10] = 0xFF; bc1_blocks[11] = 0xFF;
  bc1_blocks[12] = 0x00; bc1_blocks[13] = 0x00;
  bc1_blocks[14] = 0x00; bc1_blocks[15] = 0x00;

  // Block 2 (bottom-left): red
  bc1_blocks[16] = 0x00; bc1_blocks[17] = 0xF8;
  bc1_blocks[18] = 0x00; bc1_blocks[19] = 0x00;
  bc1_blocks[20] = 0x00; bc1_blocks[21] = 0x00;
  bc1_blocks[22] = 0x00; bc1_blocks[23] = 0x00;

  // Block 3 (bottom-right): blue
  bc1_blocks[24] = 0x1F; bc1_blocks[25] = 0x00;
  bc1_blocks[26] = 0x00; bc1_blocks[27] = 0x00;
  bc1_blocks[28] = 0x00; bc1_blocks[29] = 0x00;
  bc1_blocks[30] = 0x00; bc1_blocks[31] = 0x00;

  auto frame = create_hap1_frame(16, 8, bc1_blocks, sizeof(bc1_blocks));

  Decoder decoder;
  DecodedFrame output;

  bool ok = decoder.decode(frame.data(), frame.size(), output);
  HAP_ASSERT(ok);
  HAP_ASSERT_EQ(output.textures.size(), 1u);
  const auto &tex = output.textures[0];
  HAP_ASSERT(tex.format == hap::core::HapTextureFormat::RGB_DXT1);
  HAP_ASSERT_EQ(tex.data.size(), 32u);
  HAP_ASSERT(memcmp(tex.data.data(), bc1_blocks, sizeof(bc1_blocks)) == 0);
}

HAP_TEST(test_decoder_hap5_golden_frame) {
  // 16x8 pixels = 4 BC3 blocks (2x2 grid), each 16 bytes
  uint8_t bc3_blocks[64];

  // Block 0 (top-left): alpha opaque, white
  bc3_blocks[0] = 0xFF; bc3_blocks[1] = 0x00; // alpha endpoints: 255, 0
  memset(bc3_blocks + 2, 0x00, 6); // alpha indices all 0 (opaque)
  bc3_blocks[8] = 0xFF; bc3_blocks[9] = 0xFF; // color0: white
  bc3_blocks[10] = 0x00; bc3_blocks[11] = 0x00; // color1: black
  bc3_blocks[12] = 0x00; bc3_blocks[13] = 0x00;
  bc3_blocks[14] = 0x00; bc3_blocks[15] = 0x00; // color indices all 0

  // Block 1 (top-right): alpha transparent, black
  bc3_blocks[16] = 0x00; bc3_blocks[17] = 0xFF; // alpha endpoints: 0, 255
  memset(bc3_blocks + 18, 0x00, 6); // alpha indices all 0 (transparent)
  bc3_blocks[24] = 0x00; bc3_blocks[25] = 0x00; // color0: black
  bc3_blocks[26] = 0xFF; bc3_blocks[27] = 0xFF; // color1: white
  bc3_blocks[28] = 0x00; bc3_blocks[29] = 0x00;
  bc3_blocks[30] = 0x00; bc3_blocks[31] = 0x00;

  // Block 2 (bottom-left): alpha opaque, red
  bc3_blocks[32] = 0xFF; bc3_blocks[33] = 0x00;
  memset(bc3_blocks + 34, 0x00, 6);
  bc3_blocks[40] = 0x00; bc3_blocks[41] = 0xF8; // color0: red
  bc3_blocks[42] = 0x00; bc3_blocks[43] = 0x00;
  memset(bc3_blocks + 44, 0x00, 4);

  // Block 3 (bottom-right): alpha opaque, blue
  bc3_blocks[48] = 0xFF; bc3_blocks[49] = 0x00;
  memset(bc3_blocks + 50, 0x00, 6);
  bc3_blocks[56] = 0x1F; bc3_blocks[57] = 0x00; // color0: blue
  bc3_blocks[58] = 0x00; bc3_blocks[59] = 0x00;
  memset(bc3_blocks + 60, 0x00, 4);

  auto frame = create_hap5_frame(16, 8, bc3_blocks, sizeof(bc3_blocks));

  Decoder decoder;
  DecodedFrame output;

  bool ok = decoder.decode(frame.data(), frame.size(), output);
  HAP_ASSERT(ok);
  HAP_ASSERT_EQ(output.textures.size(), 1u);

  const auto &tex = output.textures[0];
  HAP_ASSERT(tex.format == hap::core::HapTextureFormat::RGBA_DXT5);
  HAP_ASSERT_EQ(tex.data.size(), 64u); // 4 blocks x 16 bytes

  // Assert: decoded BC3 data matches input byte-for-byte
  HAP_ASSERT(memcmp(tex.data.data(), bc3_blocks, sizeof(bc3_blocks)) == 0);
}

HAP_TEST(test_decoder_hap7_golden_frame) {
  // 16x8 pixels = 4 BC7 blocks (2x2 grid), each 16 bytes
  // BC7 mode 1 blocks: simple test pattern
  uint8_t bc7_blocks[64];

  // Block 0: mode 1, all zeros
  bc7_blocks[0] = 0x01;
  memset(bc7_blocks + 1, 0x00, 15);

  // Block 1: mode 1
  bc7_blocks[16] = 0x01;
  memset(bc7_blocks + 17, 0x00, 15);

  // Block 2: mode 1
  bc7_blocks[32] = 0x01;
  memset(bc7_blocks + 33, 0x00, 15);

  // Block 3: mode 1
  bc7_blocks[48] = 0x01;
  memset(bc7_blocks + 49, 0x00, 15);

  auto frame = create_hap7_frame(16, 8, bc7_blocks, sizeof(bc7_blocks));

  Decoder decoder;
  DecodedFrame output;

  bool ok = decoder.decode(frame.data(), frame.size(), output);
  HAP_ASSERT(ok);
  HAP_ASSERT_EQ(output.textures.size(), 1u);

  const auto &tex = output.textures[0];
  HAP_ASSERT(tex.format == hap::core::HapTextureFormat::RGBA_BPTC_UNORM);
  HAP_ASSERT_EQ(tex.data.size(), 64u); // 4 blocks x 16 bytes

  // Assert: decoded BC7 data matches input byte-for-byte
  HAP_ASSERT(memcmp(tex.data.data(), bc7_blocks, sizeof(bc7_blocks)) == 0);
}

// -----------------------------------------------------------------------
// Unsupported format tests
// -----------------------------------------------------------------------

HAP_TEST(test_decoder_unsupported_format_rejected) {
  // Create a frame with an unrecognized format type byte (0x00 is
  // neither None/Snappy/Complex compressor nor any known format).
  // The hap.c decoder should reject it with HapResult_Bad_Frame.
  uint8_t dummy_data[16] = {0};

  // Type byte 0x00: compressor = 0x0 (invalid), format = 0x0 (invalid)
  std::vector<uint8_t> frame;
  uint32_t length = 16;
  frame.push_back(length & 0xFF);
  frame.push_back((length >> 8) & 0xFF);
  frame.push_back((length >> 16) & 0xFF);
  frame.push_back(0x00); // invalid type byte
  frame.insert(frame.end(), dummy_data, dummy_data + 16);

  Decoder decoder;
  DecodedFrame output;

  bool ok = decoder.decode(frame.data(), frame.size(), output);
  HAP_ASSERT(!ok); // Must fail: unsupported format
}

HAP_TEST(test_decoder_hap_format_rejected) {
  // Unsupported Hap compressor type should also be rejected.
  // Type byte 0xD0: compressor = 0xD (invalid), format = 0x0 (invalid)
  uint8_t dummy_data[16] = {0};
  std::vector<uint8_t> frame;
  uint32_t length = 16;
  frame.push_back(length & 0xFF);
  frame.push_back((length >> 8) & 0xFF);
  frame.push_back((length >> 16) & 0xFF);
  frame.push_back(0xD0);
  frame.insert(frame.end(), dummy_data, dummy_data + 16);

  Decoder decoder;
  DecodedFrame output;

  bool ok = decoder.decode(frame.data(), frame.size(), output);
  HAP_ASSERT(!ok);
}

// -----------------------------------------------------------------------
// Fixture-based decode tests: demux + decode frame 0 from real .mov files.
// These exercise the Snappy decompress path (the synthetic tests above use
// the None compressor) and assert format + expected BC block byte count.
// -----------------------------------------------------------------------

static std::string find_fixture(const std::vector<std::string> &names) {
  std::vector<std::string> paths = {
      "tests/fixtures/",
      "../tests/fixtures/",
  };
  for (const auto &name : names) {
    for (const auto &p : paths) {
      std::string full = p + name;
      if (access(full.c_str(), F_OK) == 0)
        return full;
    }
  }
  return "";
}

HAP_TEST(test_decoder_hap5_fixture_frame0) {
  std::string path = find_fixture({"hap5.mov"});
  if (path.empty()) {
    fprintf(stderr, "SKIP (no hap5 fixture) ");
    return;
  }

  MmapReader reader;
  HAP_ASSERT(reader.open(path));

  Demuxer demuxer;
  auto result = demuxer.open(reader);
  HAP_ASSERT(result.valid);
  HAP_ASSERT(result.track.fourcc == FCC_Hap5);
  HAP_ASSERT(result.track.frame_count > 0);

  const uint8_t *sample = demuxer.sample_data(reader, 0);
  HAP_ASSERT(sample != nullptr);

  Decoder decoder;
  DecodedFrame output;
  HAP_ASSERT(decoder.decode(sample, result.samples[0].size, output));
  HAP_ASSERT_EQ(output.textures.size(), 1u);

  const auto &tex = output.textures[0];
  HAP_ASSERT(tex.format == hap::core::HapTextureFormat::RGBA_DXT5);
  // Decoded size must match the BC3 block byte count for the track dimensions.
  HAP_ASSERT_EQ(tex.data.size(),
               static_cast<size_t>(result.track.frame_bytes()));
}

HAP_TEST(test_decoder_hap7_fixture_frame0) {
  std::string path = find_fixture({"hap7.mov"});
  if (path.empty()) {
    fprintf(stderr, "SKIP (no hap7 fixture) ");
    return;
  }

  MmapReader reader;
  HAP_ASSERT(reader.open(path));

  Demuxer demuxer;
  auto result = demuxer.open(reader);
  HAP_ASSERT(result.valid);
  HAP_ASSERT(result.track.fourcc == FCC_Hap7);
  HAP_ASSERT(result.track.frame_count > 0);

  const uint8_t *sample = demuxer.sample_data(reader, 0);
  HAP_ASSERT(sample != nullptr);

  Decoder decoder;
  DecodedFrame output;
  HAP_ASSERT(decoder.decode(sample, result.samples[0].size, output));
  HAP_ASSERT_EQ(output.textures.size(), 1u);

  const auto &tex = output.textures[0];
  HAP_ASSERT(tex.format == hap::core::HapTextureFormat::RGBA_BPTC_UNORM);
  HAP_ASSERT_EQ(tex.data.size(),
               static_cast<size_t>(result.track.frame_bytes()));
}

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------
int main() {
  return hap::test::run_all();
}