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

HAP_TEST(test_decoder_golden_frame) {
  // Create a BC1 checkerboard pattern: 16x8 pixels = 4 BC1 blocks (2x2 grid)
  // Each block is 8 bytes: 2 endpoints (RGB565) + 4 bytes indices
  
  uint8_t bc1_blocks[32];
  
  // Block 0 (top-left 4x4): white
  // Endpoints: 0xFFFF (white), 0x0000 (black)
  // Indices: all 0 (select first color = white)
  bc1_blocks[0] = 0xFF; bc1_blocks[1] = 0xFF; // color0: white (RGB565)
  bc1_blocks[2] = 0x00; bc1_blocks[3] = 0x00; // color1: black (RGB565)
  bc1_blocks[4] = 0x00; bc1_blocks[5] = 0x00; // indices all 0
  bc1_blocks[6] = 0x00; bc1_blocks[7] = 0x00;
  
  // Block 1 (top-right 4x4): black 
  // Endpoints: 0x0000 (black), 0xFFFF (white)
  // Indices: all 0 (select first color = black)
  bc1_blocks[8] = 0x00; bc1_blocks[9] = 0x00; // color0: black
  bc1_blocks[10] = 0xFF; bc1_blocks[11] = 0xFF; // color1: white
  bc1_blocks[12] = 0x00; bc1_blocks[13] = 0x00; // indices all 0
  bc1_blocks[14] = 0x00; bc1_blocks[15] = 0x00;
  
  // Block 2 (bottom-left 4x4): red
  // RGB565 red = 0xF800, stored little-endian
  bc1_blocks[16] = 0x00; bc1_blocks[17] = 0xF8; // color0: red
  bc1_blocks[18] = 0x00; bc1_blocks[19] = 0x00; // color1: black
  bc1_blocks[20] = 0x00; bc1_blocks[21] = 0x00; // indices all 0
  bc1_blocks[22] = 0x00; bc1_blocks[23] = 0x00;
  
  // Block 3 (bottom-right 4x4): blue
  // RGB565 blue = 0x001F, stored little-endian
  bc1_blocks[24] = 0x1F; bc1_blocks[25] = 0x00; // color0: blue
  bc1_blocks[26] = 0x00; bc1_blocks[27] = 0x00; // color1: black
  bc1_blocks[28] = 0x00; bc1_blocks[29] = 0x00; // indices all 0
  bc1_blocks[30] = 0x00; bc1_blocks[31] = 0x00;
  
  // Wrap in a Hap1 frame
  auto frame = create_hap1_frame(16, 8, bc1_blocks, sizeof(bc1_blocks));
  
  // Decode it
  Decoder decoder;
  DecodedFrame output;
  
  bool ok = decoder.decode(frame.data(), frame.size(), output);
  HAP_ASSERT(ok);
  HAP_ASSERT_EQ(output.textures.size(), 1u);
  
  const auto &tex = output.textures[0];
  HAP_ASSERT(tex.format == hap::core::HapTextureFormat::RGB_DXT1);
  HAP_ASSERT_EQ(tex.data.size(), 32u); // 4 blocks × 8 bytes
  
  // Assert: decoded data is byte-for-byte identical to the original BC1 input
  HAP_ASSERT(memcmp(tex.data.data(), bc1_blocks, sizeof(bc1_blocks)) == 0);
}

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------
int main() {
  return hap::test::run_all();
}