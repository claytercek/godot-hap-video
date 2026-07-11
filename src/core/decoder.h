#ifndef HAP_CORE_DECODER_H
#define HAP_CORE_DECODER_H

#include "hap_frame.h"

#include <cstdint>
#include <vector>

namespace hap {
namespace core {

/// Decodes a single Hap frame from its compressed bytes into raw texture data.
///
/// Wraps the Vidvox hap.c decoder (HapDecode, HapGetFrameTextureCount, etc.)
/// with correct multi-texture handling (fixing the reference Unity plugin's
/// hardcoded index=0 bug).
///
/// For the tracer bullet, decode is synchronous with no thread pool.
/// The callback always dispatches work inline (single-threaded).
class Decoder {
public:
  Decoder() = default;
  ~Decoder() = default;

  Decoder(const Decoder &) = delete;
  Decoder &operator=(const Decoder &) = delete;

  /// Decode a single Hap frame.
  ///
  /// @param input      Pointer to the compressed frame data (from the mmap).
  /// @param input_size Size of the compressed frame data in bytes.
  /// @param output     Output vector for decoded textures.
  /// @return true on success, false on error.
  bool decode(const uint8_t *input, size_t input_size,
              DecodedFrame &output);

  /// Get the maximum output buffer size needed for a given frame.
  /// This is approximate; actual sizes are determined after decode.
  static size_t max_output_size(const uint8_t *input, size_t input_size);

private:
  /// Temporary output buffer for the decoded texture data.
  /// Reused across decode calls to avoid reallocation.
  std::vector<uint8_t> temp_buffer_;
};

} // namespace core
} // namespace hap

#endif // HAP_CORE_DECODER_H