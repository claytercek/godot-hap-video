#ifndef HAP_MINIMP4_SHIM_H
#define HAP_MINIMP4_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle wrapping a minimp4 MP4D_demux_t plus its read-callback
// context. minimp4's structs are large and MINIMP4_ALLOW_64BIT-dependent;
// hiding them behind this handle means the Zig demuxer never has to mirror
// their layout -- it only ever sees this pointer and the scalar accessors
// below.
typedef struct hap_mp4d_ctx hap_mp4d_ctx;

// Parse `data[0..size)` as an MP4/MOV container. Returns a heap-allocated
// context on success, or NULL on out-of-memory or a parse failure (mirrors
// MP4D_open()'s combined success/failure return -- the two cases are not
// distinguished).
hap_mp4d_ctx *hap_mp4d_open(const uint8_t *data, int64_t size);

// Releases a context returned by hap_mp4d_open(). Safe to call with NULL.
void hap_mp4d_close(hap_mp4d_ctx *ctx);

// Number of tracks in the movie.
unsigned hap_mp4d_track_count(const hap_mp4d_ctx *ctx);

// Number of samples ("frames") in track `ntrack`. Caller must ensure
// ntrack < hap_mp4d_track_count(ctx).
unsigned hap_mp4d_track_sample_count(const hap_mp4d_ctx *ctx, unsigned ntrack);

// Media timescale (tick rate) for track `ntrack`.
unsigned hap_mp4d_track_timescale(const hap_mp4d_ctx *ctx, unsigned ntrack);

// Byte offset (into the original `data` buffer passed to hap_mp4d_open) of
// sample `nsample` in track `ntrack`. Fills *frame_bytes / *timestamp /
// *duration. Thin wrapper over MP4D_frame_offset() -- see minimp4.h for the
// full contract.
uint64_t hap_mp4d_frame_offset(const hap_mp4d_ctx *ctx, unsigned ntrack,
                                unsigned nsample, unsigned *frame_bytes,
                                unsigned *timestamp, unsigned *duration);

#ifdef __cplusplus
}
#endif

#endif // HAP_MINIMP4_SHIM_H
