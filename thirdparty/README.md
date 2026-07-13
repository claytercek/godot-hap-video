# Third-party code

This directory vendors three C/C++ libraries used by the extension. All were
added in a single initial commit and are built by SConstruct as static-lib
side-targets (see the root SConstruct).

## hap

- Upstream: https://github.com/Vidvox/hap
- Files: `thirdparty/hap/hap.c`, `thirdparty/hap/hap.h`
- License: `thirdparty/licenses/LICENSE-hap.txt`
- Upstream version: unrecorded. The vendored files carry no version define
  or commit reference, and the copyright header only dates the library to
  2011-2013. Vendored 2026-07-11 (date of the commit that introduced it,
  `90ece50`).

## minimp4

- Upstream: https://github.com/lieff/minimp4 (a fork of the original
  https://github.com/aspt/mp4, both credited in the vendored header)
- Files: `thirdparty/minimp4/minimp4.c`, `thirdparty/minimp4/minimp4.h`
- License: `thirdparty/licenses/LICENSE-minimp4.txt`
- Upstream version: unrecorded. minimp4 is a single-header library with no
  version macro; the vendored copy carries no commit reference. Vendored
  2026-07-11 (date of `90ece50`).
- `minimp4.c` itself is just the two defines (`MINIMP4_IMPLEMENTATION`,
  `MINIMP4_ALLOW_64BIT`) plus `#include "minimp4.h"` needed to emit the
  implementation in its own translation unit.

## snappy

- Upstream: https://github.com/google/snappy
- Files: `thirdparty/snappy/*.cc`, `thirdparty/snappy/*.h`
- License: `thirdparty/licenses/LICENSE-snappy.txt`,
  `thirdparty/licenses/AUTHORS-snappy.txt`
- Upstream version: **1.2.2**, per `SNAPPY_MAJOR`/`SNAPPY_MINOR`/
  `SNAPPY_PATCHLEVEL` in `thirdparty/snappy/snappy_config/snappy-stubs-public.h`.
  Vendored 2026-07-11 (date of `90ece50`).
- `thirdparty/snappy/snappy_config/` (`config.h`,
  `snappy-stubs-public.h`) is hand-written, not the CMake-generated output
  upstream normally produces. It disables the optional codec dependencies
  (`HAVE_LIBLZO2`, `HAVE_LIBZ`, `HAVE_LIBLZ4` all 0) since none are needed
  to decode Hap frames.

## Local patches

The commits below modified vendored files after the initial vendoring
commit (`90ece50`). All are hardening fixes driven by fuzzing the decoders
with malformed/adversarial input (see the fuzzing harness under
`tests/`); none are upstream cherry-picks. Any future refresh of a
vendored library from its upstream must re-apply the fixes below (or
confirm upstream has since fixed the same issue).

| Commit    | File                          | Description                                                        |
|-----------|-------------------------------|----------------------------------------------------------------------|
| `e87ae74` | `thirdparty/minimp4/minimp4.h` | Harden `MP4D_open` against malformed files: guard null-track derefs, fix a 32-bit-wrap bound check in `BOX_stts`, route all parse-time allocations through one bounded/overflow-checked helper, and fix a leak in `MALLOC()`. |
| `15ac7ad` | `thirdparty/minimp4/minimp4.h` | Close remaining null-track derefs (`stts`/`stsz`/`stz2`/`stsc`/`stco`/`co64`/`avcC`/`mdhd`) reachable via a lone top-level box, and fix O(n^2) rescans in `sample_to_chunk()`/`MP4D_frame_offset()` by resuming from a per-track cache instead of restarting each call. |
| `f36897e` | `thirdparty/minimp4/minimp4.h` | Grow `stts` timestamp/duration arrays geometrically (double capacity) instead of reallocating to the exact new size on every entry, fixing a fuzzer-found multi-second hang from many small `stts` entries. |
| `fc098ce` | `thirdparty/minimp4/minimp4.h` | Widen `count * elemsize` malloc-size expressions to 64-bit before multiplying, so overflow can't wrap the size below `minimp4_bounded_malloc`'s check and under-allocate a buffer the parser then writes past. |
| `74b9d08` | `thirdparty/minimp4/minimp4.h` | Guard `MP4D_frame_offset` against a chunk/sample count being set without its matching array being allocated (can happen when a malformed file's second, oversized `stco`/`stsz` box hits an out-of-memory path after the first allocation was freed). |
| `5965126` | `thirdparty/minimp4/minimp4.h` | Bail out of `BOX_ctts` once its declared entry count runs past the box's actual payload, instead of reading zero-padding forever — a file could otherwise claim ~4 billion entries in a few bytes on disk. |
| `2125503` | `thirdparty/hap/hap.c`        | Match `hap_decode_chunk`'s signature to the `HapDecodeWorkFunction` callback type it's invoked through, instead of casting a function pointer to a different parameter list (undefined behavior caught by UBSan's `-fsanitize=function`). |
