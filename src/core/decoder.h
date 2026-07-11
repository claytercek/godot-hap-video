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
/// Chunked frames (Complex compressor) are decoded in parallel using the
/// shared InnerThreadPool, which auto-derives its thread count from
/// hardware_concurrency per the spec's formula. The HapDecode callback
/// is invoked once per multi-chunk texture and returns only when all
/// chunks are complete. Single-chunk textures bypass the callback entirely.
///
/// The decoder does not copy sample data — it slices directly from the
/// caller's input buffer (which is typically the mmap region).
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