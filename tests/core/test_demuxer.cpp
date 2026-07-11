/*
 * Core demuxer tests.
 *
 * Tests the demuxer's ability to parse MOV files, classify tracks, and
 * validate sample offsets. Some tests require fixture files; others use
 * synthetic data.
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
  HAP_ASSERT(result.track.fourcc == FCC_Hap1);
  HAP_ASSERT(result.track.width > 0);
  HAP_ASSERT(result.track.height > 0);
  HAP_ASSERT(result.track.frame_count > 0);
  HAP_ASSERT(result.track.frame_rate > 0.0);
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
  HAP_ASSERT(result.valid); // video track is found
  HAP_ASSERT(result.track.fourcc == FCC_Hap1); // video track is correctly identified
  HAP_ASSERT(result.track.width > 0);
  HAP_ASSERT(result.track.height > 0);
  HAP_ASSERT(result.track.frame_count > 0);
}

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------
int main() {
  return hap::test::run_all();
}