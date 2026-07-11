#include "decoder.h"

#include "hap.h"

#include <cstring>

namespace hap {
namespace core {

// -----------------------------------------------------------------------
// Synchronous decode callback: dispatches work inline (single-threaded).
// For the tracer bullet, we don't use a thread pool — just call the work
// function sequentially. The callback is invoked only for multi-chunk
// frames (complex compressor).
// -----------------------------------------------------------------------
static void sync_decode_callback(HapDecodeWorkFunction function, void *p,
                                  unsigned int count, void * /*info*/) {
  for (unsigned int i = 0; i < count; i++) {
    function(p, i);
  }
}

bool Decoder::decode(const uint8_t *input, size_t input_size,
                     DecodedFrame &output) {
  output.textures.clear();

  // Determine number of textures in this frame
  unsigned int texture_count = 0;
  unsigned int result =
      HapGetFrameTextureCount(input, static_cast<unsigned long>(input_size),
                              &texture_count);
  if (result != HapResult_No_Error || texture_count == 0 ||
      texture_count > 2) {
    return false;
  }

  output.textures.resize(texture_count);

  for (unsigned int i = 0; i < texture_count; i++) {
    // Peek at the texture format to determine output buffer size
    unsigned int texture_format = 0;
    result = HapGetFrameTextureFormat(
        input, static_cast<unsigned long>(input_size), i, &texture_format);
    if (result != HapResult_No_Error) {
      return false;
    }

    // Get chunk count to estimate output size
    int chunk_count = 0;
    HapGetFrameTextureChunkCount(
        input, static_cast<unsigned long>(input_size), i, &chunk_count);

    // Allocate a generous output buffer. We grow it as needed.
    // The maximum size for BC-compressed data is the full input size
    // (uncompressed worst case). For safety, use input_size * 2.
    size_t max_size = static_cast<size_t>(static_cast<double>(input_size) * 1.5);
    if (max_size < 1024 * 1024)
      max_size = 1024 * 1024; // Minimum 1 MB
    if (temp_buffer_.size() < max_size)
      temp_buffer_.resize(max_size);

    unsigned long bytes_used = 0;
    result = HapDecode(input, static_cast<unsigned long>(input_size), i,
                       sync_decode_callback, nullptr, temp_buffer_.data(),
                       static_cast<unsigned long>(temp_buffer_.size()),
                       &bytes_used, &texture_format);
    if (result != HapResult_No_Error) {
      // Buffer too small? Grow and try again
      if (result == HapResult_Buffer_Too_Small) {
        max_size = static_cast<size_t>(bytes_used * 1.5);
        temp_buffer_.resize(max_size);
        result = HapDecode(
            input, static_cast<unsigned long>(input_size), i,
            sync_decode_callback, nullptr, temp_buffer_.data(),
            static_cast<unsigned long>(temp_buffer_.size()), &bytes_used,
            &texture_format);
        if (result != HapResult_No_Error) {
          return false;
        }
      } else {
        return false;
      }
    }

    // Copy decoded data into the output
    auto &tex = output.textures[i];
    tex.data.assign(temp_buffer_.data(), temp_buffer_.data() + bytes_used);
    tex.format = static_cast<HapTextureFormat>(texture_format);
  }

  return true;
}

size_t Decoder::max_output_size(const uint8_t *input, size_t input_size) {
  // For an uncompressed frame (worst case), the decoded size equals the
  // compressed size (since unpacked = raw block data). For snappy-compressed,
  // it can be slightly larger. Use a heuristic: 2x input size.
  return input_size * 2;
}

} // namespace core
} // namespace hap