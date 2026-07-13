/*
 * Shared fixture-path discovery for the core test suite.
 *
 * All fixtures live under tests/fixtures/. Tests may run from the repo
 * root or from a build directory (e.g. build/tests/), so every lookup
 * probes both locations.
 */

#ifndef HAP_CORE_TEST_FIXTURES_H
#define HAP_CORE_TEST_FIXTURES_H

#include <string>
#include <vector>

#include <unistd.h>

namespace hap {
namespace test {

// Directories probed for fixtures, in order. Covers running the test
// binary from the repo root (tests/fixtures/) and from build/tests/
// (../tests/fixtures/).
inline const std::vector<std::string> &fixture_search_dirs() {
  static const std::vector<std::string> dirs = {
      "tests/fixtures/",
      "../tests/fixtures/",
  };
  return dirs;
}

inline bool fixture_path_exists(const std::string &path) {
  return access(path.c_str(), F_OK) == 0;
}

// Resolve a single fixture file by name (e.g. "hap1.mov"). Returns the
// resolved path, or an empty string if not found in any search dir.
inline std::string find_fixture(const std::string &name) {
  for (const auto &dir : fixture_search_dirs()) {
    std::string full = dir + name;
    if (fixture_path_exists(full))
      return full;
  }
  return "";
}

// Resolve the fixture directory that contains every file in `names` (all
// must live in the same directory). Returns the directory, with trailing
// slash, or an empty string if no search dir has all of them.
inline std::string find_fixture_dir(const std::vector<std::string> &names) {
  for (const auto &dir : fixture_search_dirs()) {
    bool all_present = true;
    for (const auto &name : names) {
      if (!fixture_path_exists(dir + name)) {
        all_present = false;
        break;
      }
    }
    if (all_present)
      return dir;
  }
  return "";
}

// Resolve a fixture subdirectory by name (e.g. "fuzz_regressions").
// Returns the resolved path, or an empty string if not found.
inline std::string find_fixture_subdir(const std::string &name) {
  for (const auto &dir : fixture_search_dirs()) {
    std::string full = dir + name;
    if (fixture_path_exists(full))
      return full;
  }
  return "";
}

} // namespace test
} // namespace hap

#endif // HAP_CORE_TEST_FIXTURES_H
