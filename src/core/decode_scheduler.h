#ifndef HAP_CORE_DECODE_SCHEDULER_H
#define HAP_CORE_DECODE_SCHEDULER_H

#include "decoder.h"
#include "demuxer.h"
#include "frame_queue.h"
#include "hap_frame.h"
#include "mmap_reader.h"
#include "outer_thread_pool.h"

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>

namespace hap {
namespace core {

/// Per-stream decode pipeline: async open + continuous serial decode into
/// a FrameQueue, run entirely on the shared OuterThreadPool.
///
/// One DecodeScheduler owns one stream's mmap, demuxer, decoder, and
/// frame queue. Its decode work always runs via
/// OuterThreadPool::submit_for_stream(stream_id), which guarantees at
/// most one fill step for this stream is ever in flight — the "each
/// stream decodes strictly serially" invariant the SPSC queue depends
/// on — while other streams' schedulers run concurrently on the same
/// shared pool.
///
/// Usage:
///   scheduler.open_async(path, [](bool ok, const std::string &err){...});
///   // once opened (poll is_open() or wait for the callback):
///   scheduler.request_frame(0);       // start prefetching from frame 0
///   ... consumer thread ...
///   const DecodedFrame *f = scheduler.queue().peek(&idx);
///   ...use f...
///   scheduler.queue().pop();
///   scheduler.notify_capacity_available(); // resume prefetch
///
/// Seeking: request_frame() again with a different index. The in-flight
/// decode (if any) finishes first — Snappy/hap.c are not
/// cancellation-safe — then the queue is drained and refilled from the
/// new position. Calling request_frame() again before the previous seek
/// has been applied simply overwrites the target: latest seek wins.
class DecodeScheduler {
public:
  DecodeScheduler();
  /// Blocks until no fill_step is queued or running for this stream on
  /// the shared OuterThreadPool -- a queued/in-flight fill_step captures
  /// `this` by raw pointer, so it must never observe this object mid- or
  /// post-destruction.
  ~DecodeScheduler();

  DecodeScheduler(const DecodeScheduler &) = delete;
  DecodeScheduler &operator=(const DecodeScheduler &) = delete;

  /// Begin an asynchronous open: mmap + demux + validate, run as a
  /// one-shot job on the outer pool. `on_opened` is invoked from an
  /// outer-pool worker thread (never the caller's thread) exactly once,
  /// with success/failure and, on failure, an error message.
  void open_async(const std::string &path,
                  std::function<void(bool, const std::string &)> on_opened);

  /// True once open_async's job has completed successfully. Safe to poll
  /// from any thread.
  bool is_open() const { return opened_.load(std::memory_order_acquire); }

  /// Valid only once is_open() is true.
  const VideoTrackInfo &track_info() const { return demuxer_.track_info(); }

  /// The consumer-side (render thread) frame queue.
  FrameQueue &queue() { return queue_; }

  /// Request that decode proceed from `frame_index`, in either temporal
  /// direction. On first call after open, this starts prefetch from
  /// `frame_index`. On subsequent calls (a different index and/or a
  /// direction flip), this is a seek: the queue is drained and refilled
  /// from the new position/direction once the in-flight decode (if any)
  /// completes. `forward=false` decodes backward (frame_index,
  /// frame_index-1, ...), stopping cleanly at frame 0 -- Hap is
  /// all-keyframe, so reverse is this queue-management behavior, not a
  /// different decode path.
  void request_frame(uint32_t frame_index, bool forward = true);

  /// Call after popping a frame from queue() to allow prefetch to
  /// continue filling the now-open slot. A no-op if a fill is already
  /// scheduled or in flight.
  void notify_capacity_available();

  /// Unique id used for outer-pool per-stream serialization. Exposed for
  /// tests.
  uint64_t stream_id() const { return stream_id_; }

private:
  void fill_step();
  /// Submit a fill_step to the outer pool unless one is already queued or
  /// running for this stream. Takes mutex_ internally to test/set
  /// fill_scheduled_.
  void schedule_fill_if_needed();

  MmapReader mmap_;
  Demuxer demuxer_;
  Decoder decoder_;
  FrameQueue queue_{4};

  uint64_t stream_id_;

  // Lock-free polling flags for other threads (open status). These are the
  // only cross-thread reads that must not block, so they stay atomic.
  std::atomic<bool> opened_{false};
  std::atomic<bool> open_failed_{false};

  // All seek/cursor state below is guarded by mutex_. Grouping it under one
  // lock closes the tearing hazard where two concurrent request_frame()
  // calls could interleave a target from one with a direction from the
  // other: request_frame() writes target+forward+pending in one critical
  // section, and fill_step() consumes them in one critical section.
  std::mutex mutex_;

  // Pending seek, applied by the next fill_step invocation.
  bool seek_pending_ = false;
  uint32_t seek_target_ = 0;
  bool seek_forward_ = true;

  // Decode cursor: next frame index the fill step will decode.
  uint32_t cursor_ = 0;

  // Active decode direction, latched from seek_forward_ when a pending
  // seek is applied in fill_step().
  bool forward_ = true;

  // True once a reverse fill has decoded frame 0 -- stops fill_step from
  // underflowing cursor_ (unsigned) by re-decoding frame 0 forever.
  bool reverse_exhausted_ = false;

  // True while a fill_step is queued or running for this stream, so
  // notify_capacity_available()/request_frame() don't over-submit.
  bool fill_scheduled_ = false;
};

} // namespace core
} // namespace hap

#endif // HAP_CORE_DECODE_SCHEDULER_H
