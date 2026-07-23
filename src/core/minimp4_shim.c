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
  if (offset + (int64_t)size > ctx->size) {
    if (offset >= ctx->size)
      return 1;
    size = (size_t)(ctx->size - offset);
  }
  memcpy(buffer, ctx->data + offset, size);
  return 0;
}

hap_mp4d_ctx *hap_mp4d_open(const uint8_t *data, int64_t size) {
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
  return ctx->mp4.track_count;
}

unsigned hap_mp4d_track_sample_count(const hap_mp4d_ctx *ctx,
                                      unsigned ntrack) {
  return ctx->mp4.track[ntrack].sample_count;
}

unsigned hap_mp4d_track_timescale(const hap_mp4d_ctx *ctx, unsigned ntrack) {
  return ctx->mp4.track[ntrack].timescale;
}

uint64_t hap_mp4d_frame_offset(const hap_mp4d_ctx *ctx, unsigned ntrack,
                                unsigned nsample, unsigned *frame_bytes,
                                unsigned *timestamp, unsigned *duration) {
  return (uint64_t)MP4D_frame_offset(&ctx->mp4, ntrack, nsample, frame_bytes,
                                      timestamp, duration);
}
