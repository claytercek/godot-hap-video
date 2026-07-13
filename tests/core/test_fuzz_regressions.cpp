/*
 * Fuzz-found regression tests.
 *
 * Each fixture under tests/fixtures/fuzz_regressions/ is a raw input that
 * previously crashed, hung, leaked, or OOM'd libFuzzer's fuzz_demuxer
 * harness (see tests/fuzz/fuzz_demuxer.cpp). The bugs are fixed; these
 * replay the exact inputs through the same open() path so a regression
 * shows up as an ordinary sanitizer abort/hang in this deterministic
 * suite instead of only in an occasional local fuzz run.
 */

#include "core/demuxer.h"
#include "core/mmap_reader.h"

#include "test.h"
#include "test_fixtures.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <string>
#include <unistd.h>
#include <vector>

using namespace hap::core;

namespace {

// Fuzz-found inputs are raw bytes, not valid Hap MOVs in most cases -- the
// only thing under test is that open() returns normally (no crash/leak/
// hang), not that it succeeds.
void replay(const std::string &path) {
  MmapReader reader;
  HAP_ASSERT(reader.open(path));
  Demuxer demuxer;
  demuxer.open(reader);
}

} // namespace

HAP_TEST(test_fuzz_regressions) {
  std::string dir_path = hap::test::find_fixture_subdir("fuzz_regressions");

  if (dir_path.empty()) {
    fprintf(stderr, "SKIP (no fuzz_regressions fixtures found) ");
    return;
  }

  DIR *dir = opendir(dir_path.c_str());
  HAP_ASSERT(dir != nullptr);
  if (!dir)
    return;

  int replayed = 0;
  struct dirent *entry;
  while ((entry = readdir(dir)) != nullptr) {
    std::string name = entry->d_name;
    if (name == "." || name == "..")
      continue;
    replay(dir_path + "/" + name);
    replayed++;
  }
  closedir(dir);

  // Guard against a typo'd path silently turning this into a no-op test.
  HAP_ASSERT(replayed > 0);
}

int main() { return hap::test::run_all(); }
