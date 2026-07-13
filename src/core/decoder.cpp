#include "decoder.h"

#include "thread_pool.h"

#include "hap.h"

#include <cstring>

namespace hap {
namespace core {

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

    // Allocate a generous output buffer. We grow it as needed.
    // The maximum size for BC-compressed data is the full input size
    // (uncompressed worst case). For safety, use input_size * 1.5.
    size_t max_size = static_cast<size_t>(static_cast<double>(input_size) * 1.5);
    if (max_size < 1024 * 1024)
      max_size = 1024 * 1024; // Minimum 1 MB
    if (temp_buffer_.size() < max_size)
      temp_buffer_.resize(max_size);

    // Decode into temp_buffer_. If it's too small, hap.c reports the exact
    // bytes needed via bytes_used; grow to 1.5x that and retry once.
    unsigned long bytes_used = 0;
    bool decoded = false;
    for (int attempt = 0; attempt < 2; attempt++) {
      result = HapDecode(input, static_cast<unsigned long>(input_size), i,
                         hap_inner_decode_callback, nullptr,
                         temp_buffer_.data(),
                         static_cast<unsigned long>(temp_buffer_.size()),
                         &bytes_used, &texture_format);
      if (result == HapResult_No_Error) {
        decoded = true;
        break;
      }
      if (result != HapResult_Buffer_Too_Small)
        return false;
      temp_buffer_.resize(static_cast<size_t>(bytes_used * 1.5));
    }
    if (!decoded)
      return false;

    // Copy decoded data into the output
    auto &tex = output.textures[i];
    tex.data.assign(temp_buffer_.data(), temp_buffer_.data() + bytes_used);
    tex.format = static_cast<HapTextureFormat>(texture_format);
  }

  return true;
}

} // namespace core
} // namespace hap