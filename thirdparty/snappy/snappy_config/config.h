#ifndef GODOT_HAP_SNAPPY_CONFIG_H
#define GODOT_HAP_SNAPPY_CONFIG_H

/* Snappy normally expects generated feature checks. The Zig build cross-compiles
 * all supported targets, so this header keeps the checks to stable compiler and
 * platform macros instead of host-time probing. */

#define HAVE_ATTRIBUTE_ALWAYS_INLINE 1
#define HAVE_BUILTIN_CTZ 1
#define HAVE_BUILTIN_EXPECT 1
#define HAVE_BUILTIN_PREFETCH 1

#define HAVE_LIBLZO2 0
#define HAVE_LIBZ 0
#define HAVE_LIBLZ4 0

#if defined(_WIN32)
#  define HAVE_FUNC_MMAP 0
#  define HAVE_FUNC_SYSCONF 0
#  define HAVE_SYS_MMAN_H 0
#  define HAVE_SYS_RESOURCE_H 0
#  define HAVE_SYS_TIME_H 0
#  define HAVE_SYS_UIO_H 0
#  define HAVE_UNISTD_H 0
#  define HAVE_WINDOWS_H 1
#else
#  define HAVE_FUNC_MMAP 1
#  define HAVE_FUNC_SYSCONF 1
#  define HAVE_SYS_MMAN_H 1
#  define HAVE_SYS_RESOURCE_H 1
#  define HAVE_SYS_TIME_H 1
#  define HAVE_SYS_UIO_H 1
#  define HAVE_UNISTD_H 1
#  define HAVE_WINDOWS_H 0
#endif

#ifndef SNAPPY_HAVE_SSSE3
#  if defined(__SSSE3__)
#    define SNAPPY_HAVE_SSSE3 1
#  else
#    define SNAPPY_HAVE_SSSE3 0
#  endif
#endif

#ifndef SNAPPY_HAVE_X86_CRC32
#  define SNAPPY_HAVE_X86_CRC32 0
#endif

#ifndef SNAPPY_HAVE_BMI2
#  if defined(__BMI2__)
#    define SNAPPY_HAVE_BMI2 1
#  else
#    define SNAPPY_HAVE_BMI2 0
#  endif
#endif

#ifndef SNAPPY_HAVE_NEON
#  if defined(__ARM_NEON) || defined(__ARM_NEON__)
#    define SNAPPY_HAVE_NEON 1
#  else
#    define SNAPPY_HAVE_NEON 0
#  endif
#endif

#define SNAPPY_RVV_1 0
#define SNAPPY_RVV_0_7 0
#define SNAPPY_HAVE_NEON_CRC32 0

#if defined(__BYTE_ORDER__) && defined(__ORDER_BIG_ENDIAN__) && \
    __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#  define SNAPPY_IS_BIG_ENDIAN 1
#else
#  define SNAPPY_IS_BIG_ENDIAN 0
#endif

#endif /* GODOT_HAP_SNAPPY_CONFIG_H */
