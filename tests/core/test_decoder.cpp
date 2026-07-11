/*
 * Core decoder tests.
 *
 * Tests the Hap frame decoder with synthetic data: creates valid Hap1/HapY/HapM
 * frames in memory, decodes them, and verifies the output.
 */

#include "core/decoder.h"
#include "core/hap_frame.h"

#include "hap.h"
#include "test.h"

#include <cstdio>
#include <cstring>

using namespace hap::core;

// -----------------------------------------------------------------------
// Helper: write a 3-byte little-endian integer
// -----------------------------------------------------------------------
static void write_3_le(uint8_t *buf, uint32_t val) {
  buf[0] = val & 0xFF;
  buf[1] = (val >> 8) & 0xFF;
  buf[2] = (val >> 16) & 0xFF;
}

// -----------------------------------------------------------------------
// Helper: create a synthetic Hap1 frame (single-chunk, None compressor)
//
// A Hap1 frame structure:
//   4-byte header: length(3 bytes LE) + type(1 byte)
//   type = compressor<<4 | formatID
//   compressor None = 0xA, formatID RGB_DXT1 = 0xB -> 0xAB
//   Frame data = BC1 block bytes
// -----------------------------------------------------------------------
static std::vector<uint8_t> create_hap1_frame(const uint8_t *bc1_data,
                                              size_t bc1_size) {
  std::vector<uint8_t> frame;

  uint32_t length = static_cast<uint32_t>(bc1_size);
  frame.push_back(length & 0xFF);
  frame.push_back((length >> 8) & 0xFF);
  frame.push_back((length >> 16) & 0xFF);
  frame.push_back(0xAB); // Hap1: None(0xA)<<4 | RGB_DXT1(0xB) = 0xAB

  frame.insert(frame.end(), bc1_data, bc1_data + bc1_size);

  return frame;
}

// -----------------------------------------------------------------------
// Helper: create a synthetic HapY (YCoCg DXT5) frame
//
// Same section format as Hap5 but type byte uses YCoCg format identifier:
//   0xA0 (compressor None) | 0x0F (YCoCg DXT5 format ID) = 0xAF
// -----------------------------------------------------------------------
static std::vector<uint8_t> create_hapy_frame(const uint8_t *bc3_data,
                                              size_t bc3_size) {
  std::vector<uint8_t> frame;
  frame.resize(bc3_size + 4);
  write_3_le(frame.data(), static_cast<uint32_t>(bc3_size));
  frame[3] = 0xAF; // None compressor, YCoCg DXT5
  std::memcpy(frame.data() + 4, bc3_data, bc3_size);
  return frame;
}

// -----------------------------------------------------------------------
// Helper: create a synthetic HapM (dual-texture) frame
//
// Multi-image frame:
//   Outer header: total_length(3 bytes LE) + type(0x0D = kHapSectionMultipleImages)
//   Sub-section 1 header: length(3) + type(0xAF = color: YCoCg DXT5)
//   Sub-section 1 data: BC3 color data
//   Sub-section 2 header: length(3) + type(0xA1 = alpha: A_RGTC1)
//   Sub-section 2 data: BC4 alpha data
// -----------------------------------------------------------------------
static std::vector<uint8_t> create_hapm_frame(const uint8_t *color_data,
                                              size_t color_size,
                                              const uint8_t *alpha_data,
                                              size_t alpha_size) {
  std::vector<uint8_t> frame;

  uint32_t ss1_size = static_cast<uint32_t>(color_size);
  uint32_t ss2_size = static_cast<uint32_t>(alpha_size);
  uint32_t total_payload = 4 + ss1_size + 4 + ss2_size;

  // Outer header (4 bytes)
  frame.resize(4);
  write_3_le(frame.data(), total_payload);
  frame[3] = 0x0D; // kHapSectionMultipleImages

  // Sub-section 1 header (4 bytes)
  frame.resize(frame.size() + 4);
  write_3_le(frame.data() + frame.size() - 4, ss1_size);
  frame[frame.size() - 1] = 0xAF; // None compressor, YCoCg DXT5

  // Sub-section 1 data
  frame.insert(frame.end(), color_data, color_data + color_size);

  // Sub-section 2 header (4 bytes)
  frame.resize(frame.size() + 4);
  write_3_le(frame.data() + frame.size() - 4, ss2_size);
  frame[frame.size() - 1] = 0xA1; // None compressor, A_RGTC1

  // Sub-section 2 data
  frame.insert(frame.end(), alpha_data, alpha_data + alpha_size);

  return frame;
}

// -----------------------------------------------------------------------
// Helper: create a BC3 block (16 bytes) with given RGBA values
// The BC3 block stores 32-bit alpha at 8bpp, and BC1 color in 565 format.
// For test purposes, we create a minimal valid block.
// -----------------------------------------------------------------------
static void make_bc3_block(uint8_t *block, uint8_t r, uint8_t g, uint8_t b,
                           uint8_t a) {
  // Alpha part (8 bytes): 2 endpoint alphas + 3-bit indices per texel
  block[0] = a;      // alpha endpoint 0
  block[1] = a;      // alpha endpoint 1 (same = all texels get same alpha)
  // Alpha indices: all 0 (select endpoint 0 = a)
  block[2] = 0x00;
  block[3] = 0x00;
  block[4] = 0x00;
  block[5] = 0x00;
  block[6] = 0x00;
  block[7] = 0x00;

  // Color part (8 bytes): RGB565 endpoints + 2-bit color indices
  uint16_t c0 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
  uint16_t c1 = 0; // second endpoint = black
  block[8] = c0 & 0xFF;
  block[9] = (c0 >> 8) & 0xFF;
  block[10] = c1 & 0xFF;
  block[11] = (c1 >> 8) & 0xFF;
  // Color indices: all 0 (select endpoint 0)
  block[12] = 0x00;
  block[13] = 0x00;
  block[14] = 0x00;
  block[15] = 0x00;
}

// -----------------------------------------------------------------------
// Helper: create a BC4 block (8 bytes) with given alpha value
// BC4 stores single-channel data: 8-bit endpoint + 3-bit indices
// -----------------------------------------------------------------------
static void make_bc4_block(uint8_t *block, uint8_t a) {
  block[0] = a;      // endpoint 0
  block[1] = a;      // endpoint 1 (same = all texels get same value)
  // Indices: all 0
  block[2] = 0x00;
  block[3] = 0x00;
  block[4] = 0x00;
  block[5] = 0x00;
  block[6] = 0x00;
  block[7] = 0x00;
}

// -----------------------------------------------------------------------
// BC1 block helpers (8 bytes)
// -----------------------------------------------------------------------
static void make_bc1_block(uint8_t *block, uint16_t c0, uint16_t c1) {
  block[0] = c0 & 0xFF;
  block[1] = (c0 >> 8) & 0xFF;
  block[2] = c1 & 0xFF;
  block[3] = (c1 >> 8) & 0xFF;
  // Indices: all 0
  block[4] = 0x00;
  block[5] = 0x00;
  block[6] = 0x00;
  block[7] = 0x00;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

HAP_TEST(test_decoder_hap1_single_block) {
  uint8_t bc1_block[8];
  make_bc1_block(bc1_block, 0x0000, 0xFFFF); // black endpoint 0, white endpoint 1

  auto frame = create_hap1_frame(bc1_block, sizeof(bc1_block));

  Decoder decoder;
  DecodedFrame output;

  bool ok = decoder.decode(frame.data(), frame.size(), output);
  HAP_ASSERT(ok);
  HAP_ASSERT_EQ(output.textures.size(), 1u);

  const auto &tex = output.textures[0];
  HAP_ASSERT(tex.format == hap::core::HapTextureFormat::RGB_DXT1);
  HAP_ASSERT(!tex.data.empty());
  HAP_ASSERT_EQ(tex.data.size(), 8u);
  HAP_ASSERT(memcmp(tex.data.data(), bc1_block, 8) == 0);
}

HAP_TEST(test_decoder_hap1_multiple_blocks) {
  uint8_t bc1_blocks[32];
  make_bc1_block(bc1_blocks, 0x0000, 0xFFFF);       // block 0: black
  make_bc1_block(bc1_blocks + 8, 0xFFFF, 0x0000);   // block 1: white
  make_bc1_block(bc1_blocks + 16, 0xF800, 0x0000);  // block 2: red
  make_bc1_block(bc1_blocks + 24, 0x001F, 0x0000);  // block 3: blue

  auto frame = create_hap1_frame(bc1_blocks, sizeof(bc1_blocks));

  Decoder decoder;
  DecodedFrame output;

  bool ok = decoder.decode(frame.data(), frame.size(), output);
  HAP_ASSERT(ok);
  HAP_ASSERT_EQ(output.textures.size(), 1u);
  HAP_ASSERT_EQ(output.textures[0].data.size(), 32u);
}

HAP_TEST(test_decoder_hap1_multi_texture) {
  uint8_t bc1_block[8];
  make_bc1_block(bc1_block, 0x0000, 0xFFFF);
  auto frame = create_hap1_frame(bc1_block, sizeof(bc1_block));

  unsigned int tex_count = 0;
  unsigned int result = HapGetFrameTextureCount(
      frame.data(), static_cast<unsigned long>(frame.size()), &tex_count);
  HAP_ASSERT_EQ(result, (unsigned int)HapResult_No_Error);
  HAP_ASSERT_EQ(tex_count, 1u);
}

HAP_TEST(test_decoder_golden_frame) {
  uint8_t bc1_blocks[32];
  make_bc1_block(bc1_blocks, 0xFFFF, 0x0000);    // block 0: white
  make_bc1_block(bc1_blocks + 8, 0x0000, 0xFFFF); // block 1: black
  make_bc1_block(bc1_blocks + 16, 0xF800, 0x0000); // block 2: red
  make_bc1_block(bc1_blocks + 24, 0x001F, 0x0000); // block 3: blue

  auto frame = create_hap1_frame(bc1_blocks, sizeof(bc1_blocks));

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

// -----------------------------------------------------------------------
// HapY (YCoCg DXT5) tests
// -----------------------------------------------------------------------

HAP_TEST(test_decoder_hapy_single_block) {
  // A single 4x4 BC3 block (16 bytes): alpha + color parts
  uint8_t bc3_block[16];
  make_bc3_block(bc3_block, 128, 128, 128, 128); // mid-gray, medium alpha

  auto frame = create_hapy_frame(bc3_block, sizeof(bc3_block));

  Decoder decoder;
  DecodedFrame output;

  bool ok = decoder.decode(frame.data(), frame.size(), output);
  HAP_ASSERT(ok);
  HAP_ASSERT_EQ(output.textures.size(), 1u);

  const auto &tex = output.textures[0];
  // HapY decodes to BC3 format (same as DXT5)
  HAP_ASSERT(tex.format == hap::core::HapTextureFormat::YCoCg_DXT5);
  HAP_ASSERT(!tex.data.empty());
  HAP_ASSERT_EQ(tex.data.size(), 16u);
  HAP_ASSERT(memcmp(tex.data.data(), bc3_block, 16) == 0);
}

HAP_TEST(test_decoder_hapy_format_detection) {
  // Verify HapGetFrameTextureFormat reports YCoCg_DXT5 for HapY
  uint8_t bc3_block[16];
  make_bc3_block(bc3_block, 128, 128, 128, 128);

  auto frame = create_hapy_frame(bc3_block, sizeof(bc3_block));

  unsigned int tex_format = 0;
  unsigned int result = HapGetFrameTextureFormat(
      frame.data(), static_cast<unsigned long>(frame.size()), 0, &tex_format);
  HAP_ASSERT_EQ(result, (unsigned int)HapResult_No_Error);
  HAP_ASSERT_EQ(tex_format, (unsigned int)HapTextureFormat_YCoCg_DXT5);
}

HAP_TEST(test_decoder_hapy_texture_count) {
  uint8_t bc3_block[16];
  make_bc3_block(bc3_block, 128, 128, 128, 128);

  auto frame = create_hapy_frame(bc3_block, sizeof(bc3_block));

  unsigned int tex_count = 0;
  unsigned int result = HapGetFrameTextureCount(
      frame.data(), static_cast<unsigned long>(frame.size()), &tex_count);
  HAP_ASSERT_EQ(result, (unsigned int)HapResult_No_Error);
  HAP_ASSERT_EQ(tex_count, 1u); // HapY is single-texture
}

// -----------------------------------------------------------------------
// HapM (dual-texture: color + alpha) tests
// -----------------------------------------------------------------------

HAP_TEST(test_decoder_hapm_dual_texture) {
  // Two 4x4 blocks: one BC3 color, one BC4 alpha
  uint8_t color_block[16];
  make_bc3_block(color_block, 128, 128, 128, 128);

  uint8_t alpha_block[8];
  make_bc4_block(alpha_block, 96); // alpha = 96

  auto frame = create_hapm_frame(color_block, sizeof(color_block),
                                 alpha_block, sizeof(alpha_block));

  Decoder decoder;
  DecodedFrame output;

  bool ok = decoder.decode(frame.data(), frame.size(), output);
  HAP_ASSERT(ok);
  HAP_ASSERT_EQ(output.textures.size(), 2u); // Dual textures

  // Texture 0: color (YCoCg DXT5)
  const auto &tex0 = output.textures[0];
  HAP_ASSERT(tex0.format == hap::core::HapTextureFormat::YCoCg_DXT5);
  HAP_ASSERT(!tex0.data.empty());
  HAP_ASSERT_EQ(tex0.data.size(), 16u);
  HAP_ASSERT(memcmp(tex0.data.data(), color_block, 16) == 0);

  // Texture 1: alpha (A_RGTC1)
  const auto &tex1 = output.textures[1];
  HAP_ASSERT(tex1.format == hap::core::HapTextureFormat::A_RGTC1);
  HAP_ASSERT(!tex1.data.empty());
  HAP_ASSERT_EQ(tex1.data.size(), 8u);
  HAP_ASSERT(memcmp(tex1.data.data(), alpha_block, 8) == 0);
}

HAP_TEST(test_decoder_hapm_alpha_non_trivial) {
  // Verify that HapM produces a non-trivial alpha texture
  // This tests the exact regression from the Unity plugin (which hardcoded
  // texture index 0 and dropped alpha).

  uint8_t color_block[16];
  make_bc3_block(color_block, 64, 128, 192, 255); // arbitrary YCoCg values

  uint8_t alpha_block[8];
  make_bc4_block(alpha_block, 160); // non-trivial alpha = 160

  auto frame = create_hapm_frame(color_block, sizeof(color_block),
                                 alpha_block, sizeof(alpha_block));

  Decoder decoder;
  DecodedFrame output;

  bool ok = decoder.decode(frame.data(), frame.size(), output);
  HAP_ASSERT(ok);
  HAP_ASSERT_EQ(output.textures.size(), 2u);

  // Verify alpha texture has non-trivial content
  const auto &alpha_tex = output.textures[1];
  HAP_ASSERT(!alpha_tex.data.empty());
  HAP_ASSERT_EQ(alpha_tex.data.size(), 8u); // 8 bytes for BC4 block

  // Check that not all bytes are zero (non-trivial alpha)
  bool all_zero = true;
  for (uint8_t byte : alpha_tex.data) {
    if (byte != 0) {
      all_zero = false;
      break;
    }
  }
  HAP_ASSERT(!all_zero); // Alpha data must be non-trivial

  // Verify the alpha endpoint is 160 (our test value)
  HAP_ASSERT_EQ(alpha_tex.data[0], 160);
}

HAP_TEST(test_decoder_hapm_texture_count) {
  uint8_t color_block[16];
  make_bc3_block(color_block, 128, 128, 128, 128);
  uint8_t alpha_block[8];
  make_bc4_block(alpha_block, 96);

  auto frame = create_hapm_frame(color_block, sizeof(color_block),
                                 alpha_block, sizeof(alpha_block));

  unsigned int tex_count = 0;
  unsigned int result = HapGetFrameTextureCount(
      frame.data(), static_cast<unsigned long>(frame.size()), &tex_count);
  HAP_ASSERT_EQ(result, (unsigned int)HapResult_No_Error);
  HAP_ASSERT_EQ(tex_count, 2u); // HapM is dual-texture
}

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------
int main() {
  return hap::test::run_all();
}