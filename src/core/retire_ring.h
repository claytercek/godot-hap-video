#ifndef HAP_CORE_RETIRE_RING_H
#define HAP_CORE_RETIRE_RING_H

#include <cstddef>

namespace hap {
namespace core {

/// A generation-counted ring index sequencer, depth N (default 3).
///
/// RetireRing does not own any GPU/CPU resources itself — it only sequences
/// which of N slots is safe to write next vs. which is the "current" (most
/// recently published, safe-to-read) slot. Callers own N parallel resource
/// arrays (textures, buffers, ...) indexed by the slot numbers this class
/// hands out.
///
/// Usage per frame:
///   size_t slot = ring.writable_slot();   // write new data into slot
///   ... write GPU/CPU resource at index `slot` ...
///   ring.commit();                        // publish: slot becomes current
///
/// Ring depth 3 is the minimum safe bound against Godot's default
/// render frame-queue depth of 2: by the time a slot is writable again,
/// at least two other slots have been published and consumed, so any
/// GPU work still reading an older slot never observes an in-progress
/// write. This closes tearing by construction, for every variant
/// (pass-through and YCoCg output alike).
template <size_t N = 3> class RetireRing {
public:
  static_assert(N >= 2, "RetireRing needs at least 2 slots to avoid a "
                        "writer stomping the slot a reader is using");

  RetireRing() = default;

  /// Number of slots in the ring.
  static constexpr size_t depth() { return N; }

  /// The slot most recently published via commit(). Safe to read.
  size_t current_slot() const { return current_; }

  /// The next slot a writer should fill. Never equal to current_slot()
  /// until commit() is called.
  size_t writable_slot() const { return (current_ + 1) % N; }

  /// Publish the slot last returned by writable_slot(): it becomes the
  /// new current_slot().
  void commit() { current_ = writable_slot(); }

private:
  size_t current_ = 0;
};

} // namespace core
} // namespace hap

#endif // HAP_CORE_RETIRE_RING_H
