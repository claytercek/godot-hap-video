#ifndef HAP_CORE_DEMUXER_H
#define HAP_CORE_DEMUXER_H

#include "hap_frame.h"
#include "mmap_reader.h"

#include <string>
#include <vector>

// minimp4 forward declaration (C struct, typedef'd as MP4D_demux_t)
struct MP4D_demux_tag;
typedef struct MP4D_demux_tag MP4D_demux_t;

namespace hap {
namespace core {

/// Demuxer for Hap-encoded MOV files.
///
/// Uses minimp4 for basic MOV parsing and hand-parses the stsd box to
/// extract Hap FourCCs and dimensions (minimp4's FourCC allowlist doesn't
/// recognize Hap codecs). Classifies tracks by stsd FourCC, not handler_type,
/// to sidestep minimp4's dual-hdlr bug.
///
/// All frame offsets/sizes are validated and cached at open time for O(1)
/// random access and SIGBUS mitigation.
class Demuxer {
public:
  Demuxer() = default;
  ~Demuxer();

  Demuxer(const Demuxer &) = delete;
  Demuxer &operator=(const Demuxer &) = delete;

  Demuxer(Demuxer &&other) noexcept;
  Demuxer &operator=(Demuxer &&other) noexcept;

  /// Open and demux a Hap MOV file from a memory-mapped reader.
  /// Returns the demux result. The reader must outlive the Demuxer.
  DemuxResult open(const MmapReader &reader);

  /// Returns true if a valid Hap video track was found.
  bool is_valid() const { return valid_; }

  /// Returns the video track info.
  const VideoTrackInfo &track_info() const { return track_; }

  /// Returns the cached sample entries.
  const std::vector<SampleEntry> &samples() const { return samples_; }

  /// Returns a pointer to the sample data for the given frame index.
  /// Returns nullptr if index is out of range.
  const uint8_t *sample_data(const MmapReader &reader, uint32_t index) const;

  /// Parse the stsd box to extract FourCC and dimensions.
  /// Static so it can be tested without opening a file.
  static StsdResult parse_stsd(const uint8_t *data, uint32_t size, VideoFormat &out_format);

  /// Validate all sample offsets/sizes against the file size. Static and
  /// public so it can be tested with synthetic offsets (including
  /// >4 GB ones) without needing a real multi-gigabyte fixture.
  static bool validate_samples(const std::vector<SampleEntry> &samples,
                               uint64_t file_size, std::string &error);

private:
  MP4D_demux_t *mp4_ = nullptr; // Owned heap-allocated minimp4 context
  bool valid_ = false;
  VideoTrackInfo track_;
  std::vector<SampleEntry> samples_;
  uint64_t file_size_ = 0;

  /// Clean up the minimp4 context.
  void cleanup_mp4();
};

} // namespace core
} // namespace hap

#endif // HAP_CORE_DEMUXER_H