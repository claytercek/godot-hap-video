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

void DecodeScheduler::request_frame(uint32_t frame_index) {
  seek_target_.store(frame_index, std::memory_order_relaxed);
  seek_pending_.store(true, std::memory_order_release);
  schedule_fill_locked_if_needed();
}

void DecodeScheduler::notify_capacity_available() {
  schedule_fill_locked_if_needed();
}

void DecodeScheduler::schedule_fill_locked_if_needed() {
  if (!opened_.load(std::memory_order_acquire))
    return;
  bool expected = false;
  if (!fill_scheduled_.compare_exchange_strong(expected, true))
    return; // already scheduled/in flight
  OuterThreadPool::instance().submit_for_stream(stream_id_,
                                                [this]() { fill_step(); });
}

void DecodeScheduler::fill_step() {
  // Apply a pending seek: drain stale prefetched frames and retarget the
  // cursor. Runs before this fill step decodes anything, honoring
  // "queue-behind" — any decode that was already in flight completed
  // before this job ran (outer pool serializes per-stream jobs), and the
  // latest seek always wins because seek_target_ was simply overwritten.
  if (seek_pending_.exchange(false, std::memory_order_acq_rel)) {
    queue_.drain();
    cursor_.store(seek_target_.load(std::memory_order_relaxed),
                  std::memory_order_relaxed);
  }

  const auto &samples = demuxer_.samples();
  uint32_t frame_index = cursor_.load(std::memory_order_relaxed);

  bool decoded_one = false;
  if (frame_index < samples.size() && !queue_.full()) {
    const uint8_t *sample = demuxer_.sample_data(mmap_, frame_index);
    if (sample) {
      DecodedFrame *slot = queue_.begin_write(frame_index);
      if (slot) {
        if (decoder_.decode(sample, samples[frame_index].size, *slot)) {
          queue_.commit_write();
          decoded_one = true;
          cursor_.store(frame_index + 1, std::memory_order_relaxed);
        }
      }
    }
  }

  bool more_to_do = decoded_one && !queue_.full() &&
                    cursor_.load(std::memory_order_relaxed) < samples.size();
  more_to_do = more_to_do || seek_pending_.load(std::memory_order_acquire);

  if (more_to_do) {
    // Re-submit for another round; still serialized behind any other
    // stream jobs, but for this stream it's simply the next fill step.
    OuterThreadPool::instance().submit_for_stream(
        stream_id_, [this]() { fill_step(); });
  } else {
    fill_scheduled_.store(false, std::memory_order_release);
  }
}

} // namespace core
} // namespace hap
