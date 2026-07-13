/*
 * libFuzzer harness for the demuxer open/parse path — the
 * untrusted-structure surface (arbitrary bytes claiming to be a Hap MOV).
 */

#include "core/demuxer.h"
#include "core/mmap_reader.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>
#include <vector>

// MmapReader only maps real files by design (see mmap_reader.h), so each
// input is round-tripped through a temp file to exercise the exact
// production open() path rather than a fuzz-only shortcut.
extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  std::string tmpl = std::string(std::getenv("TMPDIR") ?: "/tmp") +
                      "/hap_fuzz_XXXXXX";
  std::vector<char> path(tmpl.begin(), tmpl.end());
  path.push_back('\0');

  int fd = mkstemp(path.data());
  if (fd < 0)
    return 0;

  ssize_t written = write(fd, data, size);
  close(fd);
  if (written < 0 || static_cast<size_t>(written) != size) {
    unlink(path.data());
    return 0;
  }

  {
    hap::core::MmapReader reader;
    if (reader.open(path.data())) {
      hap::core::Demuxer demuxer;
      demuxer.open(reader);
    }
  }

  unlink(path.data());
  return 0;
}
