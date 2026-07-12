#ifndef HAP_CORE_DECODE_SCHEDULER_H
#define HAP_CORE_DECODE_SCHEDULER_H

#include "decoder.h"
#include "demuxer.h"
#include "frame_queue.h"
#include "hap_frame.h"
#include "mmap_reader.h"
#include "outer_thread_pool.h"

#include <atomic>
#include <functional>
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

  /// Request that decode proceed from `frame_index`. On first call after
  /// open, this starts forward prefetch. On subsequent calls with a
  /// different index, this is a seek: the queue is drained and refilled
  /// from the new position once the in-flight decode (if any) completes.
  void request_frame(uint32_t frame_index);

  /// Call after popping a frame from queue() to allow prefetch to
  /// continue filling the now-open slot. A no-op if a fill is already
  /// scheduled or in flight.
  void notify_capacity_available();

  /// Unique id used for outer-pool per-stream serialization. Exposed for
  /// tests.
  uint64_t stream_id() const { return stream_id_; }

private:
  void fill_step();
  void schedule_fill_locked_if_needed();

  MmapReader mmap_;
  Demuxer demuxer_;
  Decoder decoder_;
  FrameQueue queue_{4};

  uint64_t stream_id_;
  std::atomic<bool> opened_{false};
  std::atomic<bool> open_failed_{false};

  // Decode cursor: next frame index the fill step will decode.
  std::atomic<uint32_t> cursor_{0};

  // Pending seek target, applied by the next fill_step invocation.
  std::atomic<bool> seek_pending_{false};
  std::atomic<uint32_t> seek_target_{0};

  // True while a fill_step is queued or running for this stream, so
  // notify_capacity_available()/request_frame() don't over-submit.
  std::atomic<bool> fill_scheduled_{false};
};

} // namespace core
} // namespace hap

#endif // HAP_CORE_DECODE_SCHEDULER_H
