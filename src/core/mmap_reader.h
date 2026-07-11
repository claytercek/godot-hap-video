#ifndef HAP_CORE_MMAP_READER_H
#define HAP_CORE_MMAP_READER_H

#include <cstddef>
#include <cstdint>
#include <string>

namespace hap {
namespace core {

/// RAII memory-mapped file reader.
///
/// Opens a file, memory-maps it, and provides read-only access to the mapped
/// region. The mapping is released on destruction.
///
/// Non-copyable, movable.
class MmapReader {
public:
  MmapReader() noexcept = default;

  /// Open and memory-map the file at `path`.
  /// Returns true on success. On failure, error_message() provides details.
  bool open(const std::string &path);

  explicit operator bool() const noexcept { return data_ != nullptr; }

  const uint8_t *data() const noexcept { return data_; }
  size_t size() const noexcept { return size_; }
  const std::string &path() const noexcept { return path_; }
  const std::string &error_message() const noexcept { return error_message_; }

  void close() noexcept;

  MmapReader(const MmapReader &) = delete;
  MmapReader &operator=(const MmapReader &) = delete;

  MmapReader(MmapReader &&other) noexcept;
  MmapReader &operator=(MmapReader &&other) noexcept;

  ~MmapReader();

private:
  uint8_t *data_ = nullptr;
  size_t size_ = 0;
  std::string path_;
  std::string error_message_;
};

} // namespace core
} // namespace hap

#endif // HAP_CORE_MMAP_READER_H