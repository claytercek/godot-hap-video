#ifndef BLUECADET_HAP_SNAPPY_STUBS_PUBLIC_H
#define BLUECADET_HAP_SNAPPY_STUBS_PUBLIC_H

#include <cstddef>

#if !defined(_WIN32)
#include <sys/uio.h>
#endif

#define SNAPPY_MAJOR 1
#define SNAPPY_MINOR 2
#define SNAPPY_PATCHLEVEL 2
#define SNAPPY_VERSION \
    ((SNAPPY_MAJOR << 16) | (SNAPPY_MINOR << 8) | SNAPPY_PATCHLEVEL)

namespace snappy {

#if defined(_WIN32)
struct iovec {
    void *iov_base;
    size_t iov_len;
};
#endif

}  // namespace snappy

#endif /* BLUECADET_HAP_SNAPPY_STUBS_PUBLIC_H */
