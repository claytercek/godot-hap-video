/*
 * Core decoder tests.
 *
 * Tests the Hap frame decoder with synthetic data: creates valid Hap1 frames
 * (BC1/DXT1) in memory, decodes them, and verifies the output.
 */

#include "core/decoder.h"
#include "core/hap_frame.h"

#include "hap.h"
#include "test.h"

#include <cstdio>
#include <cstring>

using namespace hap::core;

// -----------------------------------------------------------------------
// Helper: create a synthetic Hap1 frame (single-chunk, snappy compressed)
//
// A Hap1 frame structure:
//   4-byte header: length(3 bytes LE) + type(1 byte)
//   For uncompressed (0xAB): length = frame data, type = 0xAB
//   Frame data = BC1 block bytes
// -----------------------------------------------------------------------
static std::vector<uint8_t> create_hap1_frame(uint32_t width, uint32_t height,
                                              const uint8_t *bc1_data,
                                              size_t bc1_size) {
  std::vector<uint8_t> frame;

  // 4-byte header: length (3 bytes LE) + type (1 byte)
  uint32_t length = static_cast<uint32_t>(bc1_size);
  frame.push_back(length & 0xFF);
  frame.push_back((length >> 8) & 0xFF);
  frame.push_back((length >> 16) & 0xFF);
  frame.push_back(0xAB); // Hap1, None compressor (single chunk)

  // Frame data (BC1 blocks)
  frame.insert(frame.end(), bc1_data, bc1_data + bc1_size);

  return frame;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

HAP_TEST(test_decoder_hap1_single_block) {
  // A single 4x4 BC1 block (8 bytes): 2 endpoint colors + 4 bytes indices
  // Endpoints: black (0x0000) and white (0xFFFF)
  // Indices: all 0 (select first color)
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

  // Verify the decoded data matches the original BC1 block
  HAP_ASSERT(memcmp(tex.data.data(), bc1_block, 8) == 0);
}

HAP_TEST(test_decoder_hap1_multiple_blocks) {
  // 8x8 pixels = 4 BC1 blocks (2x2 grid)
  // Each block: 8 bytes
  uint8_t bc1_blocks[32] = {0};
  // Fill with a simple pattern: alternate black/white
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

  // Check texture count via HapGetFrameTextureCount
  unsigned int tex_count = 0;
  unsigned int result = HapGetFrameTextureCount(
      frame.data(), static_cast<unsigned long>(frame.size()), &tex_count);
  HAP_ASSERT_EQ(result, (unsigned int)HapResult_No_Error);
  HAP_ASSERT_EQ(tex_count, 1u);
}

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------
int main() {
  return hap::test::run_all();
}