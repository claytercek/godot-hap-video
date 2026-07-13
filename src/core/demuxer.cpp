#include "demuxer.h"

#include "minimp4.h"

#include <cstring>
#include <string>
#include <vector>

namespace hap {
namespace core {

// -----------------------------------------------------------------------
// minimp4 read callback
// -----------------------------------------------------------------------
struct ReadContext {
  const uint8_t *data;
  int64_t size;
};

static int minimp4_read(int64_t offset, void *buffer, size_t size,
                        void *token) {
  auto *ctx = static_cast<ReadContext *>(token);
  if (offset + static_cast<int64_t>(size) > ctx->size) {
    if (offset >= ctx->size)
      return 1;
    size = static_cast<size_t>(ctx->size - offset);
  }
  std::memcpy(buffer, ctx->data + offset, size);
  return 0;
}

// -----------------------------------------------------------------------
// ISOBMFF box parsing utilities (big-endian)
// -----------------------------------------------------------------------
static uint32_t read_u32_be(const uint8_t *p) {
  return (static_cast<uint32_t>(p[0]) << 24) |
         (static_cast<uint32_t>(p[1]) << 16) |
         (static_cast<uint32_t>(p[2]) << 8) |
         (static_cast<uint32_t>(p[3]));
}

static uint16_t read_u16_be(const uint8_t *p) {
  return (static_cast<uint16_t>(p[0]) << 8) | static_cast<uint16_t>(p[1]);
}

static uint64_t read_u64_be(const uint8_t *p) {
  return (static_cast<uint64_t>(p[0]) << 56) |
         (static_cast<uint64_t>(p[1]) << 48) |
         (static_cast<uint64_t>(p[2]) << 40) |
         (static_cast<uint64_t>(p[3]) << 32) |
         (static_cast<uint64_t>(p[4]) << 24) |
         (static_cast<uint64_t>(p[5]) << 16) |
         (static_cast<uint64_t>(p[6]) << 8) |
         (static_cast<uint64_t>(p[7]));
}

struct BoxHeader {
  uint64_t offset;
  uint64_t size;
  uint32_t type;
  uint64_t data_pos;
  uint32_t data_size;
};

static bool read_box_header(const uint8_t *file_data, uint64_t file_size,
                            uint64_t offset, BoxHeader &hdr) {
  if (offset + 8 > file_size)
    return false;

  uint32_t size_raw = read_u32_be(file_data + offset);
  uint32_t type = read_u32_be(file_data + offset + 4);

  uint64_t box_size;
  uint64_t header_size;

  if (size_raw == 1) {
    if (offset + 16 > file_size)
      return false;
    box_size = read_u64_be(file_data + offset + 8);
    header_size = 16;
  } else if (size_raw == 0) {
    box_size = file_size - offset;
    header_size = 8;
  } else {
    box_size = size_raw;
    header_size = 8;
  }

  if (box_size < header_size || offset + box_size > file_size)
    return false;

  hdr.offset = offset;
  hdr.size = box_size;
  hdr.type = type;
  hdr.data_pos = offset + header_size;
  hdr.data_size = static_cast<uint32_t>(box_size - header_size);
  return true;
}

template <typename Visitor>
static bool walk_children(const uint8_t *file_data, uint64_t file_size,
                          const BoxHeader &parent, Visitor visitor) {
  uint64_t end = parent.offset + parent.size;
  uint64_t pos = parent.data_pos;

  while (pos + 8 <= end) {
    BoxHeader child;
    if (!read_box_header(file_data, file_size, pos, child))
      break;
    if (visitor(child))
      return true;
    pos += child.size;
    if (pos >= end)
      break;
  }
  return false;
}

static bool find_trak_at(const uint8_t *file_data, uint64_t file_size,
                         const BoxHeader &moov, unsigned int track_index,
                         BoxHeader &out_trak) {
  unsigned int count = 0;
  return walk_children(
      file_data, file_size, moov, [&](const BoxHeader &child) -> bool {
        if (child.type == FourCC('t','r','a','k').value) {
          if (count == track_index) {
            out_trak = child;
            return true;
          }
          count++;
        }
        return false;
      });
}

static bool find_stsd_in_trak(const uint8_t *file_data, uint64_t file_size,
                              const BoxHeader &trak, BoxHeader &out_stsd) {
  BoxHeader mdia;
  if (!walk_children(file_data, file_size, trak,
                     [&](const BoxHeader &child) -> bool {
                       if (child.type == FourCC('m','d','i','a').value) {
                         mdia = child;
                         return true;
                       }
                       return false;
                     }))
    return false;

  BoxHeader minf;
  if (!walk_children(file_data, file_size, mdia,
                     [&](const BoxHeader &child) -> bool {
                       if (child.type == FourCC('m','i','n','f').value) {
                         minf = child;
                         return true;
                       }
                       return false;
                     }))
    return false;

  BoxHeader stbl;
  if (!walk_children(file_data, file_size, minf,
                     [&](const BoxHeader &child) -> bool {
                       if (child.type == FourCC('s','t','b','l').value) {
                         stbl = child;
                         return true;
                       }
                       return false;
                     }))
    return false;

  return walk_children(file_data, file_size, stbl,
                       [&](const BoxHeader &child) -> bool {
                         if (child.type == FourCC('s','t','s','d').value) {
                           out_stsd = child;
                           return true;
                         }
                         return false;
                       });
}

// -----------------------------------------------------------------------
// stsd box parsing
//
// stsd is a FullBox: version(1) + flags(3) + entry_count(4)
// For each entry (SampleEntry):
//   size(4) + type(4 {FourCC}) + reserved(6) + data_reference_index(2)
// VisualSampleEntry (video) continues:
//   pre_defined(2) + reserved(2) + pre_defined(12) + width(2) + height(2)
// -----------------------------------------------------------------------
StsdResult Demuxer::parse_stsd(const uint8_t *data, uint32_t size,
                         VideoFormat &out_format) {
  if (size < 8)
    return StsdResult::NoMatch;

  uint32_t entry_count = read_u32_be(data + 4);
  uint32_t offset = 8; // past full-box header (version+flags+entry_count)

  for (uint32_t i = 0; i < entry_count; i++) {
    if (offset + 8 > size)
      return StsdResult::NoMatch;

    uint32_t entry_size = read_u32_be(data + offset);
    FourCC fourcc(read_u32_be(data + offset + 4));

    bool is_hap = is_known_hap_fourcc(fourcc);
    bool is_unsupported_hap = (fourcc == FCC_HapA ||
                               fourcc == FCC_HapHDR);

    if (is_hap) {
      // Dimensions at offset+32: after SampleEntry(16 bytes) +
      // pre_defined(2) + reserved(2) + pre_defined(12) = 32 bytes
      uint32_t dim_offset = offset + 32;
      if (dim_offset + 4 <= size) {
        out_format.width = read_u16_be(data + dim_offset);
        out_format.height = read_u16_be(data + dim_offset + 2);
        out_format.fourcc = fourcc;
        return StsdResult::Found;
      }
    }

    if (is_unsupported_hap) {
      out_format.fourcc = fourcc;
      return StsdResult::Unsupported;
    }

    if (entry_size == 0)
      break;
    offset += entry_size;
    if (offset >= size)
      break;
  }

  return StsdResult::NoMatch;
}

// -----------------------------------------------------------------------
// Validate all sample offsets/sizes against the file size
// -----------------------------------------------------------------------
bool Demuxer::validate_samples(const std::vector<SampleEntry> &samples,
                               uint64_t file_size, std::string &error) {
  for (size_t i = 0; i < samples.size(); i++) {
    uint64_t end = static_cast<uint64_t>(samples[i].offset) +
                   static_cast<uint64_t>(samples[i].size);
    if (end > file_size) {
      error = "Sample " + std::to_string(i) + " at offset " +
              std::to_string(samples[i].offset) + " size " +
              std::to_string(samples[i].size) + " exceeds file size (" +
              std::to_string(file_size) + ")";
      return false;
    }
  }
  return true;
}

// -----------------------------------------------------------------------
// Destructor / Move
// -----------------------------------------------------------------------
void MP4DemuxDeleter::operator()(MP4D_demux_t *ptr) const {
  if (ptr) {
    MP4D_close(ptr);
    delete ptr;
  }
}

void Demuxer::cleanup_mp4() {
  mp4_.reset();
}

Demuxer::~Demuxer() {
  cleanup_mp4();
}

Demuxer::Demuxer(Demuxer &&other) noexcept
    : mp4_(std::move(other.mp4_)), valid_(other.valid_), track_(other.track_),
      samples_(std::move(other.samples_)), file_size_(other.file_size_) {
  other.valid_ = false;
}

Demuxer &Demuxer::operator=(Demuxer &&other) noexcept {
  if (this != &other) {
    mp4_ = std::move(other.mp4_);
    valid_ = other.valid_;
    track_ = other.track_;
    samples_ = std::move(other.samples_);
    file_size_ = other.file_size_;
    other.valid_ = false;
  }
  return *this;
}

// -----------------------------------------------------------------------
// Open: parse the MOV file, find Hap video track, cache all samples
// -----------------------------------------------------------------------
DemuxResult Demuxer::open(const MmapReader &reader) {
  DemuxResult result;
  valid_ = false;
  samples_.clear();
  track_ = VideoTrackInfo{};
  file_size_ = reader.size();

  // Allocate and initialize minimp4 context
  mp4_.reset(new (std::nothrow) MP4D_demux_t());
  if (!mp4_) {
    result.error_message = "Out of memory allocating demux context";
    return result;
  }
  std::memset(mp4_.get(), 0, sizeof(*mp4_));

  ReadContext read_ctx;
  read_ctx.data = reader.data();
  read_ctx.size = static_cast<int64_t>(reader.size());

  if (!MP4D_open(mp4_.get(), minimp4_read, &read_ctx, read_ctx.size)) {
    result.error_message = "Failed to open/parse MOV file";
    cleanup_mp4();
    return result;
  }

  // Find the moov box in the raw file by scanning top-level boxes
  const uint8_t *file_data = reader.data();
  uint64_t file_size = reader.size();

  BoxHeader moov;
  uint64_t pos = 0;
  bool found_moov = false;
  while (pos + 8 <= file_size) {
    BoxHeader hdr;
    if (!read_box_header(file_data, file_size, pos, hdr))
      break;
    if (hdr.type == FourCC('m','o','o','v').value) {
      moov = hdr;
      found_moov = true;
      break;
    }
    pos += hdr.size;
    if (pos >= file_size)
      break;
  }

  if (!found_moov) {
    result.error_message = "No moov box found in MOV file";
    cleanup_mp4();
    return result;
  }

  // Walk tracks to find the Hap video track.
  // For each track index t (matching minimp4 track order), manually
  // find and parse its stsd box to check for Hap FourCCs.
  unsigned int hap_track_index = 0;
  bool found_hap = false;
  bool found_unsupported_hap = false;
  FourCC unsupported_hap_fourcc;
  VideoFormat hap_format;

  for (unsigned int t = 0; t < mp4_->track_count; t++) {
    BoxHeader trak;
    if (!find_trak_at(file_data, file_size, moov, t, trak))
      continue;

    BoxHeader stsd;
    if (!find_stsd_in_trak(file_data, file_size, trak, stsd))
      continue;

    StsdResult stsd_result =
        parse_stsd(file_data + stsd.data_pos, stsd.data_size, hap_format);

    if (stsd_result == StsdResult::Found) {
      hap_track_index = t;
      found_hap = true;
      break;
    }

    if (stsd_result == StsdResult::Unsupported) {
      found_unsupported_hap = true;
      unsupported_hap_fourcc = hap_format.fourcc;
    }
  }

  if (!found_hap) {
    if (found_unsupported_hap) {
      result.error_message =
          "Unsupported Hap variant (" + unsupported_hap_fourcc.to_string() +
          ") found in file \u2014 only Hap1, Hap5, HapY, HapM, Hap7 are supported";
    } else {
      result.error_message = "No Hap video track found in file";
    }
    cleanup_mp4();
    return result;
  }

  // Extract sample info from minimp4 for the found Hap track
  auto &mp4_track = mp4_->track[hap_track_index];
  uint32_t num_samples = mp4_track.sample_count;

  if (num_samples == 0) {
    result.error_message = "Hap video track has zero samples";
    cleanup_mp4();
    return result;
  }

  // A file can't legitimately contain more samples than it has bytes, so
  // this also catches minimp4's stsz sample_count (bounded only to a
  // generous 256MB/4-byte-entries ceiling) before it drives a reserve()
  // far bigger than the file it came from -- fuzzer found a ~1GB
  // allocation from a small crafted file.
  if (static_cast<uint64_t>(num_samples) > file_size_) {
    result.error_message = "Sample count exceeds file size (broken file?)";
    cleanup_mp4();
    return result;
  }

  // Cache all sample offsets/sizes
  samples_.reserve(num_samples);
  for (uint32_t i = 0; i < num_samples; i++) {
    unsigned int frame_bytes = 0;
    unsigned int timestamp = 0;
    unsigned int duration = 0;
    MP4D_file_offset_t offset = MP4D_frame_offset(
        mp4_.get(), hap_track_index, i, &frame_bytes, &timestamp, &duration);

    SampleEntry entry;
    entry.offset = static_cast<uint64_t>(offset);
    entry.size = frame_bytes;
    samples_.push_back(entry);
  }

  // Validate all samples against file size
  std::string validation_error;
  if (!validate_samples(samples_, file_size_, validation_error)) {
    result.error_message = validation_error;
    cleanup_mp4();
    return result;
  }

  // Populate track info
  track_.fourcc = hap_format.fourcc;
  track_.width = hap_format.width;
  track_.height = hap_format.height;
  track_.frame_count = num_samples;
  track_.timescale = mp4_track.timescale;

  // Compute frame rate from first sample's duration
  if (num_samples > 0) {
    unsigned int frame_bytes = 0;
    unsigned int timestamp = 0;
    unsigned int duration = 0;
    MP4D_frame_offset(mp4_.get(), hap_track_index, 0, &frame_bytes, &timestamp,
                      &duration);
    if (duration > 0 && mp4_track.timescale > 0) {
      track_.frame_rate =
          static_cast<double>(mp4_track.timescale) /
          static_cast<double>(duration);
    }
  }

  valid_ = true;
  result.valid = true;
  result.track = track_;
  result.samples = samples_;
  return result;
}

const uint8_t *Demuxer::sample_data(const MmapReader &reader,
                                    uint32_t index) const {
  if (!valid_ || index >= samples_.size())
    return nullptr;
  return reader.data() + samples_[index].offset;
}

} // namespace core
} // namespace hap