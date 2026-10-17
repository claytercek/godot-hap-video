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

// Number of samples ("frames") in track `ntrack`. Invalid tracks return 0.
unsigned hap_mp4d_track_sample_count(const hap_mp4d_ctx *ctx, unsigned ntrack);

// Media timescale (tick rate) for track `ntrack`.
unsigned hap_mp4d_track_timescale(const hap_mp4d_ctx *ctx, unsigned ntrack);

// Immutable sample-table access. All indices are zero-based (the stored
// stsc first_chunk and sample_description_index values remain one-based).
// Scalar accessors return 0 for invalid input; entry accessors return 1 on
// success and 0 on invalid input, leaving outputs untouched on failure.
// Output pointers for entry accessors must be non-NULL.
unsigned hap_mp4d_track_constant_sample_size(const hap_mp4d_ctx *ctx, unsigned ntrack);
unsigned hap_mp4d_track_sample_size(const hap_mp4d_ctx *ctx, unsigned ntrack, unsigned nsample);
unsigned hap_mp4d_track_chunk_count(const hap_mp4d_ctx *ctx, unsigned ntrack);
int hap_mp4d_track_chunk_offset(const hap_mp4d_ctx *ctx, unsigned ntrack, unsigned nchunk, uint64_t *offset);
unsigned hap_mp4d_track_stsc_count(const hap_mp4d_ctx *ctx, unsigned ntrack);
int hap_mp4d_track_stsc_entry(const hap_mp4d_ctx *ctx, unsigned ntrack, unsigned entry,
                            unsigned *first_chunk, unsigned *samples_per_chunk,
                            unsigned *sample_description_index);
unsigned hap_mp4d_track_timing_run_count(const hap_mp4d_ctx *ctx, unsigned ntrack);
int hap_mp4d_track_timing_run(const hap_mp4d_ctx *ctx, unsigned ntrack, unsigned entry,
                            unsigned *sample_count, unsigned *duration);

// Byte offset (into the original `data` buffer passed to hap_mp4d_open) of
// sample `nsample` in track `ntrack`. Fills *frame_bytes / *timestamp /
// *duration. Thin wrapper over MP4D_frame_offset() -- see minimp4.h for the
// full contract. Timestamp preserves the legacy low-32-bit wraparound;
// missing timing yields zero timestamp/duration. Invalid lookups (including
// byte-offset overflow) return 0 and zero any non-NULL outputs. This lookup
// updates per-track caches; use the immutable table accessors for audio.
uint64_t hap_mp4d_frame_offset(const hap_mp4d_ctx *ctx, unsigned ntrack,
                                unsigned nsample, unsigned *frame_bytes,
                                unsigned *timestamp, unsigned *duration);

#ifdef __cplusplus
}
#endif

#endif // HAP_MINIMP4_SHIM_H
