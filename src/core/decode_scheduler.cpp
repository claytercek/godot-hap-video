#include "decode_scheduler.h"

#include <atomic>

namespace hap {
namespace core {

namespace {
std::atomic<uint64_t> g_next_stream_id{1};
}

DecodeScheduler::DecodeScheduler()
    : stream_id_(g_next_stream_id.fetch_add(1, std::memory_order_relaxed)) {}

DecodeScheduler::~DecodeScheduler() {
  OuterThreadPool::instance().wait_for_stream_idle(stream_id_);
}

void DecodeScheduler::open_async(
    const std::string &path,
    std::function<void(bool, const std::string &)> on_opened) {
  // Stream-bound (not a plain one-shot submit()) so wait_for_stream_idle()
  // in the destructor also covers this job: if the scheduler is torn down
  // before open completes, the destructor must block on it too, or the
  // job's `this` capture goes dangling once the pool gets around to it.
  OuterThreadPool::instance().submit_for_stream(stream_id_, [this, path, on_opened]() {
    if (!mmap_.open(path)) {
      open_failed_.store(true, std::memory_order_release);
      if (on_opened)
        on_opened(false, "Failed to open file: " + path);
      return;
    }

    DemuxResult result = demuxer_.open(mmap_);
    if (!result.valid) {
      open_failed_.store(true, std::memory_order_release);
      if (on_opened)
        on_opened(false, result.error_message);
      return;
    }

    opened_.store(true, std::memory_order_release);
    if (on_opened)
      on_opened(true, "");
  });
}

void DecodeScheduler::request_frame(uint32_t frame_index, bool forward) {
  {
    // Target + direction + pending flag land in one critical section, so a
    // concurrent request_frame() can only ever leave a coherent pair
    // behind -- never this call's target with the other's direction.
    std::lock_guard<std::mutex> lock(mutex_);
    seek_target_ = frame_index;
    seek_forward_ = forward;
    seek_pending_ = true;
  }
  schedule_fill_if_needed();
}

void DecodeScheduler::notify_capacity_available() {
  schedule_fill_if_needed();
}

void DecodeScheduler::schedule_fill_if_needed() {
  if (!opened_.load(std::memory_order_acquire))
    return;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (fill_scheduled_)
      return; // already scheduled/in flight
    fill_scheduled_ = true;
  }
  OuterThreadPool::instance().submit_for_stream(stream_id_,
                                                [this]() { fill_step(); });
}

void DecodeScheduler::fill_step() {
  // Phase 1: under the lock, consume any pending seek and snapshot the
  // cursor state. Only fill_step mutates cursor_/forward_/reverse_exhausted_
  // and the outer pool serializes fill_steps per stream, so the snapshot
  // stays valid across the unlocked decode below. Honors "queue-behind":
  // any decode already in flight finished before this job ran, and the
  // latest seek wins because request_frame simply overwrote the target.
  bool do_drain = false;
  uint32_t frame_index;
  bool forward;
  bool reverse_exhausted;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (seek_pending_) {
      seek_pending_ = false;
      cursor_ = seek_target_;
      forward_ = seek_forward_;
      reverse_exhausted_ = false;
      do_drain = true;
    }
    frame_index = cursor_;
    forward = forward_;
    reverse_exhausted = reverse_exhausted_;
  }

  // Drain stale prefetched frames outside the lock (the queue is
  // self-synchronized).
  if (do_drain)
    queue_.drain();

  // Phase 2: attempt a single decode without holding mutex_ -- decode() and
  // the queue operations must never run under the seek lock.
  const auto &samples = demuxer_.samples();
  bool decoded_one = false;
  bool can_decode = frame_index < samples.size() && !queue_.full() &&
                    (forward || !reverse_exhausted);
  if (can_decode) {
    const uint8_t *sample = demuxer_.sample_data(mmap_, frame_index);
    if (sample) {
      DecodedFrame *slot = queue_.begin_write(frame_index);
      if (slot) {
        if (decoder_.decode(sample, samples[frame_index].size, *slot)) {
          queue_.commit_write();
          decoded_one = true;
        }
      }
    }
  }

  bool queue_full = queue_.full();

  // Phase 3: under the lock, advance the cursor from the snapshot and decide
  // whether to re-submit. A seek that arrived during the decode wins on the
  // next fill_step, which re-consumes seek_pending_ and overwrites cursor_.
  bool resubmit = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (decoded_one) {
      if (forward) {
        cursor_ = frame_index + 1;
      } else if (frame_index > 0) {
        cursor_ = frame_index - 1;
      } else {
        // Reached the start of the stream going backward: cursor_ is
        // unsigned, so it must not decrement past 0. Latch a flag instead
        // of storing a sentinel, so a later forward request still resumes
        // correctly from frame 0.
        reverse_exhausted_ = true;
      }
    }

    bool has_more_in_direction =
        forward ? cursor_ < samples.size() : !reverse_exhausted_;
    bool more_to_do = decoded_one && !queue_full && has_more_in_direction;
    more_to_do = more_to_do || seek_pending_;

    if (more_to_do) {
      resubmit = true; // fill_scheduled_ stays true
    } else {
      fill_scheduled_ = false;
    }
  }

  if (resubmit) {
    // Re-submit for another round; still serialized behind any other stream
    // jobs, but for this stream it's simply the next fill step.
    OuterThreadPool::instance().submit_for_stream(
        stream_id_, [this]() { fill_step(); });
  }
}

} // namespace core
} // namespace hap
