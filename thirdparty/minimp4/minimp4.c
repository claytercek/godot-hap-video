// Compile unit for the minimp4 single-header library.
// MINIMP4_IMPLEMENTATION pulls in the implementation; MINIMP4_ALLOW_64BIT
// enables 64-bit file offsets so files >4 GB demux correctly.
#define MINIMP4_IMPLEMENTATION
#define MINIMP4_ALLOW_64BIT

#include "minimp4.h"
