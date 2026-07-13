#include "mmap_reader.h"

#include <cerrno>
#include <cstring>
#include <string>

#if defined(_WIN32) || defined(_WIN64)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#include <sys/stat.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace hap {
namespace core {

MmapReader::MmapReader(MmapReader &&other) noexcept
    : data_(other.data_), size_(other.size_), path_(std::move(other.path_)),
      error_message_(std::move(other.error_message_)) {
  other.data_ = nullptr;
  other.size_ = 0;
}

MmapReader &MmapReader::operator=(MmapReader &&other) noexcept {
  if (this != &other) {
    close();
    data_ = other.data_;
    size_ = other.size_;
    path_ = std::move(other.path_);
    error_message_ = std::move(other.error_message_);
    other.data_ = nullptr;
    other.size_ = 0;
  }
  return *this;
}

MmapReader::~MmapReader() { close(); }

void MmapReader::close() noexcept {
  if (data_ == nullptr)
    return;

#if defined(_WIN32) || defined(_WIN64)
  UnmapViewOfFile(data_);
#else
  munmap(data_, size_);
#endif

  data_ = nullptr;
  size_ = 0;
  path_.clear();
  error_message_.clear();
}

bool MmapReader::open(const std::string &path) {
  if (data_ != nullptr)
    close();

#if defined(_WIN32) || defined(_WIN64)
  HANDLE hFile = CreateFileA(path.c_str(), GENERIC_READ, FILE_SHARE_READ, NULL,
                             OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (hFile == INVALID_HANDLE_VALUE) {
    error_message_ = "Failed to open file: " + path;
    return false;
  }

  LARGE_INTEGER file_size;
  if (!GetFileSizeEx(hFile, &file_size)) {
    error_message_ = "Failed to get file size: " + path;
    CloseHandle(hFile);
    return false;
  }
  size_ = static_cast<size_t>(file_size.QuadPart);

  HANDLE hMapping = CreateFileMappingA(hFile, NULL, PAGE_READONLY, 0, 0, NULL);
  if (hMapping == NULL) {
    error_message_ = "Failed to create file mapping: " + path;
    CloseHandle(hFile);
    return false;
  }

  data_ = static_cast<uint8_t *>(MapViewOfFile(hMapping, FILE_MAP_READ, 0, 0, 0));
  CloseHandle(hMapping);
  CloseHandle(hFile);

  if (data_ == nullptr) {
    error_message_ = "Failed to map view of file: " + path;
    return false;
  }
#else
  int fd = ::open(path.c_str(), O_RDONLY);
  if (fd < 0) {
    error_message_ = "Failed to open file: " + path + " - " +
                     std::strerror(errno);
    return false;
  }

  struct stat st;
  if (::fstat(fd, &st) < 0) {
    error_message_ = "Failed to stat file: " + path + " - " +
                     std::strerror(errno);
    ::close(fd);
    return false;
  }
  size_ = static_cast<size_t>(st.st_size);

  if (size_ == 0) {
    ::close(fd);
    data_ = nullptr;
    path_ = path;
    return true; // Empty file, valid but data() returns nullptr
  }

  void *mapped = ::mmap(nullptr, size_, PROT_READ, MAP_SHARED, fd, 0);
  int mmap_err = errno;
  ::close(fd);

  if (mapped == MAP_FAILED) {
    error_message_ = "Failed to mmap file: " + path + " - " +
                     std::strerror(mmap_err);
    size_ = 0;
    return false;
  }

  data_ = static_cast<uint8_t *>(mapped);
#endif

  path_ = path;
  return true;
}

} // namespace core
} // namespace hap