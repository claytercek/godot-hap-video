/*
 * Core demuxer tests.
 *
 * Tests the demuxer's ability to parse MOV files, classify tracks, and
 * validate sample offsets. Some tests require fixture files; others use
 * synthetic data.
 *
 * Covers Hap5, Hap7, and unsupported variant detection via the public
 * parse_stsd() method.
 */

#include "core/demuxer.h"
#include "core/hap_frame.h"
#include "core/mmap_reader.h"

#include "test.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>

using namespace hap::core;

// -----------------------------------------------------------------------
// Helper: create a temp file from a buffer
// -----------------------------------------------------------------------
static std::string create_temp_file(const std::vector<uint8_t> &data) {
  char tmpl[1024];
  snprintf(tmpl, sizeof(tmpl), "%s/hap_test_XXXXXX",
           std::getenv("TMPDIR") ?: "/tmp");
  int fd = mkstemp(tmpl);
  if (fd < 0) {
    perror("mkstemp");
    return "";
  }
  [[maybe_unused]] ssize_t written = write(fd, data.data(), data.size());
  close(fd);
  return std::string(tmpl);
}

// -----------------------------------------------------------------------
// Helper: build a synthetic stsd box buffer for a given FourCC and dimensions
//
// stsd is a FullBox: version(1) + flags(3) + entry_count(4)
// Each VisualSampleEntry:
//   size(4) + type(4=FourCC) + reserved(6) + data_reference_index(2) +
//   pre_defined(2) + reserved(2) + pre_defined(12) + width(2) + height(2) + ...
// We only need the first 32 bytes of the entry to reach width/height.
// -----------------------------------------------------------------------
static std::vector<uint8_t> build_stsd_entry(FourCC fourcc, uint16_t width,
                                              uint16_t height,
                                              uint32_t entry_size = 86) {
  std::vector<uint8_t> buf;
  auto write_u32_be = [&](uint32_t v) {
    buf.push_back((v >> 24) & 0xFF);
    buf.push_back((v >> 16) & 0xFF);
    buf.push_back((v >> 8) & 0xFF);
    buf.push_back(v & 0xFF);
  };
  auto write_u16_be = [&](uint16_t v) {
    buf.push_back((v >> 8) & 0xFF);
    buf.push_back(v & 0xFF);
  };
  auto write_bytes = [&](const uint8_t *d, size_t n) {
    buf.insert(buf.end(), d, d + n);
  };

  // Version(1) + flags(3) = 4 bytes, then entry_count(4)
  uint32_t stsd_payload_size = 4 + 4 + entry_size;

  // Full box header: size(4) + type(4) = 8 bytes
  write_u32_be(8 + stsd_payload_size); // total stsd box size
  write_bytes((const uint8_t *)"stsd", 4);
  write_u32_be(0); // version=0, flags=0
  write_u32_be(1); // entry_count = 1

  // SampleEntry: size(4) + type(4) + reserved(6) + data_reference_index(2)
  write_u32_be(entry_size);
  write_u32_be(fourcc.value);
  // 6 bytes reserved
  write_bytes((const uint8_t *)"\x00\x00\x00\x00\x00\x00", 6);
  write_u16_be(1); // data_reference_index

  // VisualSampleEntry fields up to width/height:
  // pre_defined(2) + reserved(2) + pre_defined(12) = 16 bytes
  write_u16_be(0); // pre_defined
  write_u16_be(0); // reserved
  write_u16_be(0); write_u16_be(0); // pre_defined (12 bytes)
  write_u16_be(0); write_u16_be(0);
  write_u16_be(0); write_u16_be(0);

  // Width + height at offset 32 from entry start
  write_u16_be(width);
  write_u16_be(height);

  // Pad to entry_size
  while (buf.size() < 8 + stsd_payload_size) {
    buf.push_back(0);
  }

  return buf;
}

// -----------------------------------------------------------------------
// FourCC tests
// -----------------------------------------------------------------------

HAP_TEST(test_fourcc_construction) {
  FourCC fcc1('H', 'a', 'p', '1');
  HAP_ASSERT(fcc1 == FCC_Hap1);
  HAP_ASSERT(fcc1 != FCC_Hap5);

  FourCC fcc2(0x48617031); // "Hap1" in big-endian
  HAP_ASSERT(fcc2 == FCC_Hap1);

  HAP_ASSERT_EQ(fcc1.to_string(), std::string("Hap1"));
}

HAP_TEST(test_fourcc_known_codes) {
  HAP_ASSERT(FCC_Hap1 == FourCC('H', 'a', 'p', '1'));
  HAP_ASSERT(FCC_Hap5 == FourCC('H', 'a', 'p', '5'));
  HAP_ASSERT(FCC_HapY == FourCC('H', 'a', 'p', 'Y'));
  HAP_ASSERT(FCC_HapM == FourCC('H', 'a', 'p', 'M'));
  HAP_ASSERT(FCC_Hap7 == FourCC('H', 'a', 'p', '7'));
  HAP_ASSERT(FCC_HapA == FourCC('H', 'a', 'p', 'A'));
  HAP_ASSERT(FCC_HapHDR == FourCC('H', 'a', 'p', 'H'));
}

// -----------------------------------------------------------------------
// MmapReader tests
// -----------------------------------------------------------------------

HAP_TEST(test_mmap_reader_open_close) {
  std::vector<uint8_t> data = {0x48, 0x65, 0x6C, 0x6C, 0x6F}; // "Hello"
  std::string path = create_temp_file(data);
  HAP_ASSERT(!path.empty());

  MmapReader reader;
  HAP_ASSERT(reader.open(path));
  HAP_ASSERT(reader.data() != nullptr);
  HAP_ASSERT_EQ(reader.size(), data.size());
  HAP_ASSERT_EQ(reader.path(), path);

  // Verify data
  HAP_ASSERT(memcmp(reader.data(), data.data(), data.size()) == 0);

  reader.close();
  HAP_ASSERT(reader.data() == nullptr);
  HAP_ASSERT_EQ(reader.size(), 0u);

  unlink(path.c_str());
}

HAP_TEST(test_mmap_reader_nonexistent) {
  MmapReader reader;
  HAP_ASSERT(!reader.open("/nonexistent/file.mov"));
  HAP_ASSERT(reader.data() == nullptr);
}

// -----------------------------------------------------------------------
// stsd parsing tests (via public parse_stsd)
// -----------------------------------------------------------------------

HAP_TEST(test_parse_stsd_hap1) {
  auto buf = build_stsd_entry(FCC_Hap1, 640, 360);
  // The stsd data starts after the box header (8 bytes) and full-box fields
  // (version+flags = 4 bytes). Our build_stsd_entry returns the full box
  // including the 8-byte box header, so data_pos = buf.data() + 8.
  VideoFormat fmt;
  StsdResult result = Demuxer::parse_stsd(buf.data() + 8,
                                           static_cast<uint32_t>(buf.size() - 8),
                                           fmt);
  HAP_ASSERT(result == StsdResult::Found);
  HAP_ASSERT(fmt.fourcc == FCC_Hap1);
  HAP_ASSERT_EQ(fmt.width, 640u);
  HAP_ASSERT_EQ(fmt.height, 360u);
}

HAP_TEST(test_parse_stsd_hap5) {
  auto buf = build_stsd_entry(FCC_Hap5, 640, 360);
  VideoFormat fmt;
  StsdResult result = Demuxer::parse_stsd(buf.data() + 8,
                                           static_cast<uint32_t>(buf.size() - 8),
                                           fmt);
  HAP_ASSERT(result == StsdResult::Found);
  HAP_ASSERT(fmt.fourcc == FCC_Hap5);
  HAP_ASSERT_EQ(fmt.width, 640u);
  HAP_ASSERT_EQ(fmt.height, 360u);
}

HAP_TEST(test_parse_stsd_hap7) {
  auto buf = build_stsd_entry(FCC_Hap7, 1920, 1080);
  VideoFormat fmt;
  StsdResult result = Demuxer::parse_stsd(buf.data() + 8,
                                           static_cast<uint32_t>(buf.size() - 8),
                                           fmt);
  HAP_ASSERT(result == StsdResult::Found);
  HAP_ASSERT(fmt.fourcc == FCC_Hap7);
  HAP_ASSERT_EQ(fmt.width, 1920u);
  HAP_ASSERT_EQ(fmt.height, 1080u);
}

HAP_TEST(test_parse_stsd_unsupported_hapa) {
  auto buf = build_stsd_entry(FCC_HapA, 640, 360);
  VideoFormat fmt;
  StsdResult result = Demuxer::parse_stsd(buf.data() + 8,
                                           static_cast<uint32_t>(buf.size() - 8),
                                           fmt);
  HAP_ASSERT(result == StsdResult::Unsupported);
  HAP_ASSERT(fmt.fourcc == FCC_HapA);
}

HAP_TEST(test_parse_stsd_unsupported_haphdr) {
  auto buf = build_stsd_entry(FCC_HapHDR, 640, 360);
  VideoFormat fmt;
  StsdResult result = Demuxer::parse_stsd(buf.data() + 8,
                                           static_cast<uint32_t>(buf.size() - 8),
                                           fmt);
  HAP_ASSERT(result == StsdResult::Unsupported);
  HAP_ASSERT(fmt.fourcc == FCC_HapHDR);
}

HAP_TEST(test_parse_stsd_unknown_codec) {
  // 'raw ' is a common video format that should not be detected as Hap
  auto buf = build_stsd_entry(FourCC('r', 'a', 'w', ' '), 640, 360);
  VideoFormat fmt;
  StsdResult result = Demuxer::parse_stsd(buf.data() + 8,
                                           static_cast<uint32_t>(buf.size() - 8),
                                           fmt);
  HAP_ASSERT(result == StsdResult::NoMatch);
}

// -----------------------------------------------------------------------
// Demuxer tests with fixture files (if available)
// -----------------------------------------------------------------------

HAP_TEST(test_demuxer_with_fixture) {
  // Look for test fixture files
  std::vector<std::string> fixture_paths = {
      "tests/fixtures/hap1.mov",
      "../tests/fixtures/hap1.mov",
  };

  std::string fixture_path;
  for (const auto &p : fixture_paths) {
    if (access(p.c_str(), F_OK) == 0) {
      fixture_path = p;
      break;
    }
  }

  if (fixture_path.empty()) {
    fprintf(stderr, "SKIP (no fixture file found) ");
    return;
  }

  MmapReader reader;
  HAP_ASSERT(reader.open(fixture_path));

  Demuxer demuxer;
  auto result = demuxer.open(reader);
  HAP_ASSERT(result.valid);
  HAP_ASSERT(demuxer.track_info().fourcc == FCC_Hap1);
  HAP_ASSERT(demuxer.track_info().width > 0);
  HAP_ASSERT(demuxer.track_info().height > 0);
  HAP_ASSERT(demuxer.track_info().frame_count > 0);
  HAP_ASSERT(demuxer.track_info().frame_rate > 0.0);
}

HAP_TEST(test_demuxer_with_hap5_fixture) {
  std::vector<std::string> fixture_paths = {
      "tests/fixtures/hap5.mov",
      "../tests/fixtures/hap5.mov",
  };

  std::string fixture_path;
  for (const auto &p : fixture_paths) {
    if (access(p.c_str(), F_OK) == 0) {
      fixture_path = p;
      break;
    }
  }

  if (fixture_path.empty()) {
    fprintf(stderr, "SKIP (no hap5 fixture) ");
    return;
  }

  MmapReader reader;
  HAP_ASSERT(reader.open(fixture_path));

  Demuxer demuxer;
  auto result = demuxer.open(reader);
  HAP_ASSERT(result.valid);
  HAP_ASSERT(demuxer.track_info().fourcc == FCC_Hap5);
  HAP_ASSERT(demuxer.track_info().width > 0);
  HAP_ASSERT(demuxer.track_info().height > 0);
  HAP_ASSERT(demuxer.track_info().frame_count > 0);
}

HAP_TEST(test_demuxer_with_hap7_fixture) {
  std::vector<std::string> fixture_paths = {
      "tests/fixtures/hap7.mov",
      "../tests/fixtures/hap7.mov",
  };

  std::string fixture_path;
  for (const auto &p : fixture_paths) {
    if (access(p.c_str(), F_OK) == 0) {
      fixture_path = p;
      break;
    }
  }

  if (fixture_path.empty()) {
    fprintf(stderr, "SKIP (no hap7 fixture) ");
    return;
  }

  MmapReader reader;
  HAP_ASSERT(reader.open(fixture_path));

  Demuxer demuxer;
  auto result = demuxer.open(reader);
  HAP_ASSERT(result.valid);
  HAP_ASSERT(demuxer.track_info().fourcc == FCC_Hap7);
  HAP_ASSERT(demuxer.track_info().width > 0);
  HAP_ASSERT(demuxer.track_info().height > 0);
  HAP_ASSERT(demuxer.track_info().frame_count > 0);
  fprintf(stderr, "OK (demuxed Hap7: %ux%u, %u frames) ",
          demuxer.track_info().width, demuxer.track_info().height, demuxer.track_info().frame_count);
}

HAP_TEST(test_demuxer_audio_skip) {
  // Look for audio fixture file (MOV with both video and audio tracks)
  std::vector<std::string> fixture_paths = {
      "tests/fixtures/hap1_audio.mov",
      "../tests/fixtures/hap1_audio.mov",
  };

  std::string fixture_path;
  for (const auto &p : fixture_paths) {
    if (access(p.c_str(), F_OK) == 0) {
      fixture_path = p;
      break;
    }
  }

  if (fixture_path.empty()) {
    fprintf(stderr, "SKIP (no audio fixture file found) ");
    return;
  }

  MmapReader reader;
  HAP_ASSERT(reader.open(fixture_path));

  Demuxer demuxer;
  auto result = demuxer.open(reader);
  
  // Assert: demuxer finds and returns the video track despite audio track presence
  HAP_ASSERT(result.valid);
  HAP_ASSERT(demuxer.track_info().fourcc == FCC_Hap1);
  HAP_ASSERT(demuxer.track_info().width > 0);
  HAP_ASSERT(demuxer.track_info().height > 0);
  HAP_ASSERT(demuxer.track_info().frame_count > 0);
}

// -----------------------------------------------------------------------
// validate_samples: 64-bit offset tests (synthetic, no multi-GB fixture
// needed -- file_size is just a parameter).
// -----------------------------------------------------------------------

HAP_TEST(test_validate_samples_accepts_offset_beyond_4gb) {
  // A sample living entirely past the 32-bit boundary in a >4 GB file.
  constexpr uint64_t kFourGb = 1ull << 32;
  std::vector<SampleEntry> samples = {
      {kFourGb + 1024, 4096}, // offset ~4 GB + 1 KiB, 4 KiB sample
  };
  uint64_t file_size = kFourGb + 1024 + 4096;
  std::string error;
  HAP_ASSERT(Demuxer::validate_samples(samples, file_size, error));
  HAP_ASSERT(error.empty());
}

HAP_TEST(test_validate_samples_rejects_offset_beyond_4gb_out_of_range) {
  // Same >4 GB offset, but the file is one byte too short to hold it --
  // must be caught by 64-bit arithmetic, not wrap/truncate to a
  // spuriously "in range" 32-bit value.
  constexpr uint64_t kFourGb = 1ull << 32;
  std::vector<SampleEntry> samples = {
      {kFourGb + 1024, 4096},
  };
  uint64_t file_size = kFourGb + 1024 + 4096 - 1; // one byte short
  std::string error;
  HAP_ASSERT(!Demuxer::validate_samples(samples, file_size, error));
  HAP_ASSERT(!error.empty());
}

HAP_TEST(test_validate_samples_handles_offset_and_size_summing_past_4gb) {
  // offset itself fits in 32 bits, but offset + size overflows a 32-bit
  // sum; must be computed in 64-bit to avoid a false negative.
  constexpr uint64_t kFourGb = 1ull << 32;
  std::vector<SampleEntry> samples = {
      {kFourGb - 100, 200}, // end = kFourGb + 100, past the 32-bit line
  };
  std::string error;
  HAP_ASSERT(!Demuxer::validate_samples(samples, kFourGb, error));
  HAP_ASSERT(Demuxer::validate_samples(samples, kFourGb + 100, error));
}

// -----------------------------------------------------------------------
// block_size() regression: switch cases use FCC_*.value (well-defined),
// not multi-char char literals (implementation-defined). Verify each
// supported FourCC maps to its documented block size.
// -----------------------------------------------------------------------
HAP_TEST(test_block_size_per_fourcc) {
  auto block_size_for = [](FourCC fourcc) {
    VideoTrackInfo info;
    info.fourcc = fourcc;
    return info.block_size();
  };
  HAP_ASSERT_EQ(block_size_for(FCC_Hap1), 8u);
  HAP_ASSERT_EQ(block_size_for(FCC_Hap5), 16u);
  HAP_ASSERT_EQ(block_size_for(FCC_HapY), 16u);
  HAP_ASSERT_EQ(block_size_for(FCC_HapM), 16u);
  HAP_ASSERT_EQ(block_size_for(FCC_Hap7), 16u);
}

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------
int main() {
  return hap::test::run_all();
}