#ifndef HAP_CORE_FRAME_QUEUE_H
#define HAP_CORE_FRAME_QUEUE_H

#include "hap_frame.h"

#include <cstdint>
#include <mutex>
#include <vector>

namespace hap {
namespace core {

/// A bounded single-producer/single-consumer queue of decoded frames.
///
/// One decode worker (the outer-pool worker currently owning a stream)
/// pushes; the render thread pops. Depth defaults to 4, per spec.
///
/// Each slot owns a reusable DecodedFrame. There is no pin/lease
/// mechanism: texture_update()'s staging copy is synchronous, so a slot
/// is safe to recycle the instant the consumer has popped it. Buffers
/// inside DecodedTexture::data are only reallocated when the producer
/// writes a frame whose size differs from what a slot's buffer already
/// holds (dimension/variant change) — std::vector::resize() is a no-op
/// on capacity when shrinking or matching, so steady-state playback
/// never reallocates.
///
/// Internally guarded by a mutex rather than lock-free atomics: decode
/// times (microseconds-to-milliseconds) dwarf lock overhead, and the SPSC
/// *usage* contract (one producer thread, one consumer thread) is what
/// callers must honor — the mutex only makes violations safe rather than
/// undefined. The consumer polls (peek/empty) rather than blocking, so
/// there is no condition variable to wait on.
class FrameQueue {
public:
  explicit FrameQueue(size_t depth = 4) : slots_(depth) {}

  FrameQueue(const FrameQueue &) = delete;
  FrameQueue &operator=(const FrameQueue &) = delete;

  size_t capacity() const { return slots_.size(); }

  /// Producer: true if there is room to begin_write() without blocking.
  bool full() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return count_ == slots_.size();
  }

  /// Consumer: true if there is nothing to pop.
  bool empty() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return count_ == 0;
  }

  /// Producer: get a pointer to the DecodedFrame the caller should decode
  /// into. Returns nullptr if the queue is full (caller should back off;
  /// this is the seek/prefetch "queue-behind" boundary, not an error).
  /// The returned buffer's vectors retain their prior capacity — decode()
  /// implementations that resize() rather than reassign reuse it.
  DecodedFrame *begin_write(uint32_t frame_index) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (count_ == slots_.size())
      return nullptr;
    Slot &slot = slots_[write_pos_];
    slot.frame_index = frame_index;
    return &slot.frame;
  }

  /// Producer: publish the frame written via the last begin_write() call.
  void commit_write() {
    std::lock_guard<std::mutex> lock(mutex_);
    write_pos_ = (write_pos_ + 1) % slots_.size();
    count_++;
  }

  /// Consumer: peek the oldest committed frame without removing it.
  /// Returns nullptr if empty. `out_frame_index` receives the frame's
  /// index if non-null.
  const DecodedFrame *peek(uint32_t *out_frame_index = nullptr) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (count_ == 0)
      return nullptr;
    const Slot &slot = slots_[read_pos_];
    if (out_frame_index)
      *out_frame_index = slot.frame_index;
    return &slot.frame;
  }

  /// Consumer: remove the oldest committed frame, freeing its slot for
  /// reuse by the producer.
  void pop() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (count_ == 0)
      return;
    read_pos_ = (read_pos_ + 1) % slots_.size();
    count_--;
  }

  /// Consumer: drop all queued frames (used by seek/scrub to discard
  /// stale prefetched frames before refilling from the new position).
  /// Does not touch a frame the producer may currently be writing via
  /// begin_write() (that write has not been committed yet).
  void drain() {
    std::lock_guard<std::mutex> lock(mutex_);
    read_pos_ = write_pos_;
    count_ = 0;
  }

private:
  struct Slot {
    DecodedFrame frame;
    uint32_t frame_index = 0;
  };

  mutable std::mutex mutex_;
  std::vector<Slot> slots_;
  size_t write_pos_ = 0;
  size_t read_pos_ = 0;
  size_t count_ = 0;
};

} // namespace core
} // namespace hap

#endif // HAP_CORE_FRAME_QUEUE_H
