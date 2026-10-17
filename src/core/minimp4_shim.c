#include "minimp4_shim.h"

#include "minimp4.h"

#include <stdlib.h>
#include <string.h>

// Read-callback context: a plain (pointer, size) view over the caller's
// mmap'd buffer. Lives alongside the MP4D_demux_t it feeds so both are
// freed together.
typedef struct {
  const uint8_t *data;
  int64_t size;
} hap_read_ctx;

struct hap_mp4d_ctx {
  MP4D_demux_t mp4;
  hap_read_ctx read_ctx;
};

static int hap_minimp4_read(int64_t offset, void *buffer, size_t size,
                            void *token) {
  hap_read_ctx *ctx = (hap_read_ctx *)token;
  if (!ctx || offset < 0 || offset > ctx->size ||
      (uint64_t)size > (uint64_t)(ctx->size - offset))
    return 1;
  if (size)
    memcpy(buffer, ctx->data + offset, size);
  return 0;
}

hap_mp4d_ctx *hap_mp4d_open(const uint8_t *data, int64_t size) {
  if (!data || size <= 0 || (uint64_t)size > SIZE_MAX)
    return NULL;
  hap_mp4d_ctx *ctx = (hap_mp4d_ctx *)calloc(1, sizeof(hap_mp4d_ctx));
  if (!ctx)
    return NULL;

  ctx->read_ctx.data = data;
  ctx->read_ctx.size = size;

  if (!MP4D_open(&ctx->mp4, hap_minimp4_read, &ctx->read_ctx, size)) {
    // MP4D_open() already calls MP4D_close() internally on failure; this
    // is a defensive, idempotent no-op belt-and-suspenders call.
    MP4D_close(&ctx->mp4);
    free(ctx);
    return NULL;
  }
  return ctx;
}

void hap_mp4d_close(hap_mp4d_ctx *ctx) {
  if (!ctx)
    return;
  MP4D_close(&ctx->mp4);
  free(ctx);
}

unsigned hap_mp4d_track_count(const hap_mp4d_ctx *ctx) {
  return ctx ? ctx->mp4.track_count : 0;
}

static const MP4D_track_t *hap_mp4d_track(const hap_mp4d_ctx *ctx,
                                       unsigned ntrack) {
  if (!ctx || !ctx->mp4.track || ntrack >= ctx->mp4.track_count)
    return NULL;
  return &ctx->mp4.track[ntrack];
}

unsigned hap_mp4d_track_sample_count(const hap_mp4d_ctx *ctx,
                                    unsigned ntrack) {
  const MP4D_track_t *tr = hap_mp4d_track(ctx, ntrack);
  return tr ? tr->sample_count : 0;
}

unsigned hap_mp4d_track_timescale(const hap_mp4d_ctx *ctx, unsigned ntrack) {
  const MP4D_track_t *tr = hap_mp4d_track(ctx, ntrack);
  return tr ? tr->timescale : 0;
}

unsigned hap_mp4d_track_constant_sample_size(const hap_mp4d_ctx *ctx,
                                           unsigned ntrack) {
  const MP4D_track_t *tr = hap_mp4d_track(ctx, ntrack);
  return tr ? tr->constant_sample_size : 0;
}

unsigned hap_mp4d_track_sample_size(const hap_mp4d_ctx *ctx, unsigned ntrack,
                                   unsigned nsample) {
  const MP4D_track_t *tr = hap_mp4d_track(ctx, ntrack);
  if (!tr || nsample >= tr->sample_count)
    return 0;
  return tr->constant_sample_size
             ? tr->constant_sample_size
             : (tr->entry_size ? tr->entry_size[nsample] : 0);
}

unsigned hap_mp4d_track_chunk_count(const hap_mp4d_ctx *ctx, unsigned ntrack) {
  const MP4D_track_t *tr = hap_mp4d_track(ctx, ntrack);
  return tr ? tr->chunk_count : 0;
}

int hap_mp4d_track_chunk_offset(const hap_mp4d_ctx *ctx, unsigned ntrack,
                               unsigned nchunk, uint64_t *offset) {
  const MP4D_track_t *tr = hap_mp4d_track(ctx, ntrack);
  if (!tr || !offset || !tr->chunk_offset || nchunk >= tr->chunk_count)
    return 0;
  *offset = (uint64_t)tr->chunk_offset[nchunk];
  return 1;
}

unsigned hap_mp4d_track_stsc_count(const hap_mp4d_ctx *ctx, unsigned ntrack) {
  const MP4D_track_t *tr = hap_mp4d_track(ctx, ntrack);
  return tr ? tr->sample_to_chunk_count : 0;
}

int hap_mp4d_track_stsc_entry(const hap_mp4d_ctx *ctx, unsigned ntrack,
                            unsigned entry, unsigned *first_chunk,
                            unsigned *samples_per_chunk,
                            unsigned *sample_description_index) {
  const MP4D_track_t *tr = hap_mp4d_track(ctx, ntrack);
  if (!tr || !first_chunk || !samples_per_chunk || !sample_description_index ||
      !tr->sample_to_chunk || entry >= tr->sample_to_chunk_count)
    return 0;
  *first_chunk = tr->sample_to_chunk[entry].first_chunk;
  *samples_per_chunk = tr->sample_to_chunk[entry].samples_per_chunk;
  *sample_description_index = tr->sample_to_chunk[entry].sample_description_index;
  return 1;
}

unsigned hap_mp4d_track_timing_run_count(const hap_mp4d_ctx *ctx,
                                      unsigned ntrack) {
  const MP4D_track_t *tr = hap_mp4d_track(ctx, ntrack);
  return tr ? tr->timing_run_count : 0;
}

int hap_mp4d_track_timing_run(const hap_mp4d_ctx *ctx, unsigned ntrack,
                            unsigned entry, unsigned *sample_count,
                            unsigned *duration) {
  const MP4D_track_t *tr = hap_mp4d_track(ctx, ntrack);
  if (!tr || !sample_count || !duration || !tr->timing_run ||
      entry >= tr->timing_run_count)
    return 0;
  *sample_count = tr->timing_run[entry].sample_count;
  *duration = tr->timing_run[entry].duration;
  return 1;
}

uint64_t hap_mp4d_frame_offset(const hap_mp4d_ctx *ctx, unsigned ntrack,
                              unsigned nsample, unsigned *frame_bytes,
                              unsigned *timestamp, unsigned *duration) {
  return (uint64_t)MP4D_frame_offset(ctx ? &ctx->mp4 : NULL, ntrack, nsample,
                                   frame_bytes, timestamp, duration);
}
