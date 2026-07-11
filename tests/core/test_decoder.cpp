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
#include "core/thread_pool.h"

#include "hap.h"
#include "test.h"

#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
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
// Chunked frame helpers
//
// We use HapEncode (from the vendored hap.c) to create valid chunked frames
// and a manual builder for unchunked frames. This way we test the actual
// hap.c encode path as well as our decode path.
// -----------------------------------------------------------------------

/// Create an unchunked (None-compressed) Hap1 frame from raw BC1 data.
static std::vector<uint8_t> create_unchunked_hap1(const uint8_t *bc1_data,
                                                   size_t bc1_size) {
  std::vector<uint8_t> frame;
  uint32_t length = static_cast<uint32_t>(bc1_size);
  frame.push_back(length & 0xFF);
  frame.push_back((length >> 8) & 0xFF);
  frame.push_back((length >> 16) & 0xFF);
  frame.push_back(0xAB); // None|DXT1
  frame.insert(frame.end(), bc1_data, bc1_data + bc1_size);
  return frame;
}

/// Create a chunked (Complex/Snappy) frame from raw texture data.
/// Uses HapEncode with the given number of chunks and texture format.
static std::vector<uint8_t> create_chunked_frame(const uint8_t *tex_data,
                                                  size_t tex_size,
                                                  unsigned int chunk_count,
                                                  unsigned int texture_format,
                                                  unsigned int compressor) {
  // Use HapMaxEncodedLength for accurate buffer sizing
  unsigned long lengths[] = {static_cast<unsigned long>(tex_size)};
  unsigned int tex_fmts[] = {texture_format};
  unsigned int chunk_counts[] = {chunk_count};
  unsigned long max_size = HapMaxEncodedLength(1, lengths, tex_fmts,
                                                 chunk_counts);
  if (max_size == 0) {
    return {};
  }

  std::vector<uint8_t> output(max_size, 0);
  unsigned long bytes_used = 0;
  const void *input_bufs[] = {tex_data};
  unsigned long input_sizes[] = {static_cast<unsigned long>(tex_size)};
  unsigned int compressors[] = {compressor};

  unsigned int result = HapEncode(1, input_bufs, input_sizes, tex_fmts,
                                   compressors, chunk_counts,
                                   output.data(), max_size, &bytes_used);
  if (result != HapResult_No_Error) {
    return {};
  }
  output.resize(bytes_used);
  return output;
}

// -----------------------------------------------------------------------
// Chunked decode tests
//
// Core assertion: chunking is transport — the decoded output of a chunked
// frame must be byte-for-byte identical to the output of an unchunked frame
// when both encode the same raw texture data.
// -----------------------------------------------------------------------

HAP_TEST(test_decoder_chunked_bc1_byte_identical) {
  // Create raw BC1 data: 64x32 pixels = 128 BC1 blocks (1024 bytes)
  // Large enough for HapEncode to produce a Complex frame.
  uint8_t bc1_blocks[1024];
  for (size_t i = 0; i < sizeof(bc1_blocks); i += 8) {
    // Each block: alternating pattern that compresses well
    bc1_blocks[i + 0] = 0xFF; bc1_blocks[i + 1] = 0xFF; // color0: white
    bc1_blocks[i + 2] = 0x00; bc1_blocks[i + 3] = 0x00; // color1: black
    bc1_blocks[i + 4] = 0x00; bc1_blocks[i + 5] = 0x00; // indices: all 0
    bc1_blocks[i + 6] = 0x00; bc1_blocks[i + 7] = 0x00;
  }

  // Create unchunked frame (None compressor)
  auto unchunked = create_unchunked_hap1(bc1_blocks, sizeof(bc1_blocks));
  HAP_ASSERT(!unchunked.empty());

  // Create chunked frame (Snappy, 4 chunks)
  auto chunked = create_chunked_frame(bc1_blocks, sizeof(bc1_blocks), 4,
                                       HapTextureFormat_RGB_DXT1,
                                       HapCompressorSnappy);
  HAP_ASSERT(!chunked.empty());

  // Verify the chunked frame is actually Complex (0xCB header type)
  HAP_ASSERT_EQ(chunked.size() >= 4u, true);
  unsigned int chunked_type = static_cast<unsigned char>(chunked[3]);
  HAP_ASSERT_EQ(chunked_type, 0xCBu); // Complex|DXT1

  // Verify chunk count is 4
  int chunk_count = 0;
  unsigned int result = HapGetFrameTextureChunkCount(
      chunked.data(), static_cast<unsigned long>(chunked.size()), 0,
      &chunk_count);
  HAP_ASSERT_EQ(result, (unsigned int)HapResult_No_Error);
  HAP_ASSERT_EQ(chunk_count, 4);

  // Decode both frames
  Decoder decoder;
  DecodedFrame output_unchunked;
  DecodedFrame output_chunked;

  bool ok = decoder.decode(unchunked.data(), unchunked.size(), output_unchunked);
  HAP_ASSERT(ok);

  ok = decoder.decode(chunked.data(), chunked.size(), output_chunked);
  HAP_ASSERT(ok);

  // Both should decode to 1 texture
  HAP_ASSERT_EQ(output_unchunked.textures.size(), 1u);
  HAP_ASSERT_EQ(output_chunked.textures.size(), 1u);

  // Format should match
  HAP_ASSERT(output_unchunked.textures[0].format ==
             hap::core::HapTextureFormat::RGB_DXT1);
  HAP_ASSERT(output_chunked.textures[0].format ==
             hap::core::HapTextureFormat::RGB_DXT1);

  // Byte-level identity: chunking is transport
  HAP_ASSERT_EQ(output_unchunked.textures[0].data.size(),
                output_chunked.textures[0].data.size());
  HAP_ASSERT(memcmp(output_unchunked.textures[0].data.data(),
                    output_chunked.textures[0].data.data(),
                    output_unchunked.textures[0].data.size()) == 0);
}

HAP_TEST(test_decoder_chunked_hapy_byte_identical) {
  // Create raw YCoCg-DXT5 data (BC3 format): 64x32 pixels = 128 BC3 blocks
  // 128 blocks × 16 bytes = 2048 bytes. Large enough for Complex compression.
  uint8_t bc3_blocks[2048];
  std::memset(bc3_blocks, 0, sizeof(bc3_blocks));

  // Fill with a simple pattern: set alpha to opaque and colors to white
  for (size_t i = 0; i < sizeof(bc3_blocks); i += 16) {
    // Alpha endpoints: opaque
    bc3_blocks[i + 0] = 0xFF; bc3_blocks[i + 1] = 0xFF;
    // Color endpoints: white (RGB565 = 0xFFFF)
    bc3_blocks[i + 8] = 0xFF; bc3_blocks[i + 9] = 0xFF;
  }

  // Encode unchunked via HapEncode (1 chunk, Snappy)
  auto unchunked = create_chunked_frame(bc3_blocks, sizeof(bc3_blocks), 1,
                                         HapTextureFormat_YCoCg_DXT5,
                                         HapCompressorSnappy);
  HAP_ASSERT(!unchunked.empty());

  // Encode chunked via HapEncode (4 chunks, Snappy)
  auto chunked = create_chunked_frame(bc3_blocks, sizeof(bc3_blocks), 4,
                                       HapTextureFormat_YCoCg_DXT5,
                                       HapCompressorSnappy);
  HAP_ASSERT(!chunked.empty());

  // Verify it's Complex (0xCF = Complex|YCoCg-DXT5)
  HAP_ASSERT_EQ(chunked.size() >= 4u, true);
  HAP_ASSERT_EQ(static_cast<unsigned char>(chunked[3]), 0xCFu);

  // Verify chunk count
  int chunk_count = 0;
  unsigned int result = HapGetFrameTextureChunkCount(
      chunked.data(), static_cast<unsigned long>(chunked.size()),
      0, &chunk_count);
  HAP_ASSERT_EQ(result, (unsigned int)HapResult_No_Error);
  HAP_ASSERT(chunk_count >= 2);

  // Decode both
  Decoder decoder;
  DecodedFrame out_unc, out_chk;

  HAP_ASSERT(decoder.decode(unchunked.data(), unchunked.size(), out_unc));
  HAP_ASSERT(decoder.decode(chunked.data(), chunked.size(), out_chk));

  // Both should decode to 1 texture
  HAP_ASSERT_EQ(out_unc.textures.size(), 1u);
  HAP_ASSERT_EQ(out_chk.textures.size(), 1u);

  // Byte-level identity
  HAP_ASSERT_EQ(out_unc.textures[0].data.size(),
                out_chk.textures[0].data.size());
  HAP_ASSERT(memcmp(out_unc.textures[0].data.data(),
                    out_chk.textures[0].data.data(),
                    out_unc.textures[0].data.size()) == 0);
}

// -----------------------------------------------------------------------
// Thread pool unit tests
// -----------------------------------------------------------------------

struct WorkItem {
  std::atomic<unsigned int> call_count{0};
};

static void test_work_function(void *p, unsigned int /*index*/) {
  auto *item = static_cast<WorkItem *>(p);
  item->call_count.fetch_add(1, std::memory_order_relaxed);
}

HAP_TEST(test_thread_pool_basic) {
  auto &pool = InnerThreadPool::instance();

  // The pool should have at least 1 worker
  HAP_ASSERT(pool.worker_count() >= 1);

  // Verify the thread count matches the formula
  // max(1, hardware_concurrency - 3)
  unsigned int hw = std::thread::hardware_concurrency();
  unsigned int expected = (hw > 3) ? (hw - 3) : 1;
  HAP_ASSERT_EQ(pool.worker_count(), expected);
}

HAP_TEST(test_thread_pool_no_workers_if_single_item) {
  // A single work item should complete immediately via the calling thread
  auto &pool = InnerThreadPool::instance();

  WorkItem item;
  pool.execute(test_work_function, &item, 1);

  HAP_ASSERT_EQ(item.call_count.load(), 1u);
}

HAP_TEST(test_thread_pool_multi_work_items) {
  auto &pool = InnerThreadPool::instance();

  WorkItem item;
  const unsigned int kCount = 100;

  pool.execute(test_work_function, &item, kCount);

  // All work items must have been executed
  HAP_ASSERT_EQ(item.call_count.load(), kCount);
}

HAP_TEST(test_thread_pool_no_remaining_state) {
  // Execute multiple batches to ensure no state leaks between calls
  auto &pool = InnerThreadPool::instance();

  WorkItem item1;
  WorkItem item2;

  pool.execute(test_work_function, &item1, 5);
  HAP_ASSERT_EQ(item1.call_count.load(), 5u);

  pool.execute(test_work_function, &item2, 7);
  HAP_ASSERT_EQ(item2.call_count.load(), 7u);

  // item1 should not have been called again
  HAP_ASSERT_EQ(item1.call_count.load(), 5u);
}

HAP_TEST(test_thread_pool_large_count) {
  auto &pool = InnerThreadPool::instance();

  // Use a count that exceeds the number of workers to test partitioning
  const unsigned int kCount = 1000;
  WorkItem item;

  pool.execute(test_work_function, &item, kCount);
  HAP_ASSERT_EQ(item.call_count.load(), kCount);
}

// -----------------------------------------------------------------------
// Callback contract: verify HapDecode respects the single-chunk contract
// -----------------------------------------------------------------------

static int callback_invocation_count = 0;

static void tracking_callback(HapDecodeWorkFunction function, void *p,
                               unsigned int count, void *info) {
  callback_invocation_count++;
  // Forward to the inner pool for proper multi-threaded decode
  hap_inner_decode_callback(function, p, count, info);
}

static void reset_callback_count() { callback_invocation_count = 0; }

HAP_TEST(test_decoder_callback_not_invoked_for_single_chunk) {
  // Create an unchunked frame and decode it with our tracking callback
  uint8_t bc1_block[8] = {0xFF, 0xFF, 0x00, 0x00,
                           0x00, 0x00, 0x00, 0x00};
  auto frame = create_unchunked_hap1(bc1_block, sizeof(bc1_block));

  // Decode with the tracking callback via HapDecode directly
  unsigned int tex_format = 0;
  unsigned long bytes_used = 0;
  uint8_t output[1024];

  reset_callback_count();

  unsigned int result = HapDecode(
      frame.data(), static_cast<unsigned long>(frame.size()), 0,
      tracking_callback, nullptr, output, sizeof(output),
      &bytes_used, &tex_format);

  HAP_ASSERT_EQ(result, (unsigned int)HapResult_No_Error);

  // The callback must NOT have been invoked for a single-chunk frame
  HAP_ASSERT_EQ(callback_invocation_count, 0);
}

HAP_TEST(test_decoder_callback_invoked_for_multi_chunk) {
  // Create raw BC1 data (1024 bytes = 128 BC1 blocks), large enough
  // for HapEncode to produce a Complex (chunked) frame.
  uint8_t bc1_data[1024];
  std::memset(bc1_data, 0, sizeof(bc1_data));

  // Encode with 4 chunks
  auto chunked = create_chunked_frame(bc1_data, sizeof(bc1_data), 4,
                                       HapTextureFormat_RGB_DXT1,
                                       HapCompressorSnappy);
  HAP_ASSERT(!chunked.empty());

  // Decode with the tracking callback via HapDecode directly
  unsigned int tex_format = 0;
  unsigned long bytes_used = 0;
  uint8_t output[4096];

  reset_callback_count();

  unsigned int result = HapDecode(
      chunked.data(), static_cast<unsigned long>(chunked.size()), 0,
      tracking_callback, nullptr, output, sizeof(output),
      &bytes_used, &tex_format);

  HAP_ASSERT_EQ(result, (unsigned int)HapResult_No_Error);

  // The callback MUST have been invoked exactly once for a multi-chunk frame
  HAP_ASSERT_EQ(callback_invocation_count, 1);
}

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------
int main() {
  return hap::test::run_all();
}