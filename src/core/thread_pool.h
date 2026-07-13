#ifndef HAP_CORE_THREAD_POOL_H
#define HAP_CORE_THREAD_POOL_H

#include "hap.h"

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>

namespace hap {
namespace core {

/// A thread pool for parallel chunk decode within a single frame.
///
/// Implements the HapDecodeCallback contract: dispatch N work items across
/// available threads and return only when all are complete.
///
/// Thread count: max(1, hardware_concurrency - outer_workers)
/// where outer_workers defaults to 3 (matching the outer pool size).
/// Clamped to a minimum of 1.
///
/// Singleton: shared by all streams. The outer pool runs up to
/// outer_workers streams concurrently, so multiple streams' chunked
/// frames can call execute() at the same time; execute() itself
/// serializes those calls (dispatch_mutex_) so the shared work-batch
/// state is never touched by two callers at once. This trades
/// chunk-level parallelism across simultaneously-chunk-decoding streams
/// for correctness — the thread count stays bounded either way. The
/// thread count is auto-derived from the hardware at construction time.
class InnerThreadPool {
public:
  /// Access the shared instance. Created on first access.
  static InnerThreadPool &instance();

  /// Execute `count` work items across the thread pool.
  /// Blocks until all items complete. Safe to call concurrently from
  /// multiple outer-pool workers — calls are internally serialized.
  /// @param func  The work function to call per chunk index
  /// @param p     Opaque context pointer passed to the work function
  /// @param count Number of work items (chunks) to process
  void execute(HapDecodeWorkFunction func, void *p, unsigned int count);

  /// Number of worker threads in the pool (excluding the calling thread).
  unsigned int worker_count() const { return num_workers_; }

private:
  InnerThreadPool();
  ~InnerThreadPool();

  InnerThreadPool(const InnerThreadPool &) = delete;
  InnerThreadPool &operator=(const InnerThreadPool &) = delete;

  /// Worker thread entry point.
  void worker_loop(unsigned int worker_id);

  /// Worker threads.
  std::vector<std::thread> workers_;

  /// Number of worker threads (pool size, excluding calling thread).
  unsigned int num_workers_ = 0;

  /// Serializes execute() calls across concurrent outer-pool workers.
  /// Held for the full duration of one batch's dispatch-and-wait.
  std::mutex dispatch_mutex_;

  /// Synchronization.
  std::mutex mutex_;
  std::condition_variable cv_start_;
  std::condition_variable cv_done_;

  /// Shared work state, set by execute() before waking workers.
  HapDecodeWorkFunction func_ = nullptr;
  void *p_ = nullptr;
  unsigned int remaining_ = 0;

  /// Monotonically increasing batch counter. Workers track their last seen
  /// batch and only proceed when the counter changes, preventing re-entry
  /// within the same batch.
  std::atomic<unsigned int> work_batch_{0};

  /// Per-worker partition: start index (inclusive) and end index (exclusive).
  struct Partition {
    unsigned int start;
    unsigned int end;
  };
  std::vector<Partition> partitions_;

  /// Pool lifecycle flag.
  bool running_ = true;
};

/// HapDecodeCallback-compatible function that uses the shared InnerThreadPool.
///
/// Pass this function as the callback argument to HapDecode. The info
/// argument is unused. The callback is invoked only for multi-chunk textures
/// (Complex compressor) and returns only when all chunks are decoded.
void hap_inner_decode_callback(HapDecodeWorkFunction function, void *p,
                                unsigned int count, void *info);

} // namespace core
} // namespace hap

#endif // HAP_CORE_THREAD_POOL_H