/*
 * Shared synthetic Hap frame builders for tests.
 *
 * Chunked frames go through HapEncode (vendored hap.c) so tests exercise
 * the real encode path; unchunked frames are built by hand.
 */

#ifndef HAP_CORE_TEST_HAP_FRAMES_H
#define HAP_CORE_TEST_HAP_FRAMES_H

#include "hap.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace hap {
namespace test {

/// Create an unchunked (None-compressed) Hap1 frame from raw BC1 data.
inline std::vector<uint8_t> create_unchunked_hap1(const uint8_t *bc1_data,
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
inline std::vector<uint8_t> create_chunked_frame(const uint8_t *tex_data,
                                                 size_t tex_size,
                                                 unsigned int chunk_count,
                                                 unsigned int texture_format,
                                                 unsigned int compressor) {
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

} // namespace test
} // namespace hap

#endif // HAP_CORE_TEST_HAP_FRAMES_H
