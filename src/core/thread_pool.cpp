#include "thread_pool.h"

#include "outer_thread_pool.h"

#include <algorithm>
#include <thread>

namespace hap {
namespace core {

// Inner pool = max(1, hardware_concurrency - outer_workers), where the
// outer worker count is OuterThreadPool::kDefaultWorkers.
static constexpr unsigned int kOuterWorkers = OuterThreadPool::kDefaultWorkers;

// -----------------------------------------------------------------------
// Singleton
// -----------------------------------------------------------------------
InnerThreadPool &InnerThreadPool::instance() {
  static InnerThreadPool pool;
  return pool;
}

// -----------------------------------------------------------------------
// Construction: derive thread count from hardware concurrency
// -----------------------------------------------------------------------
InnerThreadPool::InnerThreadPool() {
  unsigned int hw = std::thread::hardware_concurrency();
  if (hw <= kOuterWorkers) {
    num_workers_ = 1;
  } else {
    num_workers_ = hw - kOuterWorkers;
  }
  // Clamp to minimum of 1 always
  if (num_workers_ < 1) {
    num_workers_ = 1;
  }

  partitions_.resize(num_workers_ + 1); // +1 for the calling thread
  workers_.reserve(num_workers_);

  for (unsigned int i = 0; i < num_workers_; i++) {
    workers_.emplace_back(&InnerThreadPool::worker_loop, this, i);
  }
}

// -----------------------------------------------------------------------
// Destruction: signal shutdown and join all workers
// -----------------------------------------------------------------------
InnerThreadPool::~InnerThreadPool() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    running_ = false;
  }
  cv_start_.notify_all();
  for (auto &w : workers_) {
    if (w.joinable()) {
      w.join();
    }
  }
}

// -----------------------------------------------------------------------
// execute: dispatch work across the pool and wait for completion
// -----------------------------------------------------------------------
void InnerThreadPool::execute(HapDecodeWorkFunction func, void *p,
                               unsigned int count) {
  // Single item: no parallelism needed. The hap.c library guarantees that
  // the callback is only invoked for multi-chunk textures (count >= 2), but
  // we handle the edge case defensively.
  if (count <= 1) {
    func(p, 0);
    return;
  }

  // The outer pool may have several streams decoding concurrently; only
  // one of them may be dispatching into the shared inner pool at a time
  // (func_/p_/partitions_ are single-batch shared state).
  std::lock_guard<std::mutex> dispatch_lock(dispatch_mutex_);

  unsigned int total_workers = num_workers_ + 1; // calling thread + pool

  // Partition work evenly across all workers (including the calling thread).
  unsigned int base = count / total_workers;
  unsigned int remainder = count % total_workers;
  unsigned int pos = 0;
  for (unsigned int i = 0; i < total_workers; i++) {
    unsigned int extra = (i < remainder) ? 1 : 0;
    unsigned int size = base + extra;
    partitions_[i].start = pos;
    partitions_[i].end = pos + size;
    pos += size;
  }

  // Increment the work batch before waking workers. Workers compare their
  // local batch against this to decide whether to work or wait. This
  // prevents re-entry within the same batch.
  {
    std::lock_guard<std::mutex> lock(mutex_);
    func_ = func;
    p_ = p;
    remaining_ = num_workers_;
    work_batch_.fetch_add(1, std::memory_order_release);
  }
  cv_start_.notify_all();

  // Calling thread processes its own partition (worker index = num_workers_).
  const Partition &my_part = partitions_[num_workers_];
  for (unsigned int i = my_part.start; i < my_part.end; i++) {
    func(p, i);
  }

  // Wait for all pool workers to finish.
  {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_done_.wait(lock, [this]() { return remaining_ == 0; });
    // Reset shared state for next invocation.
    func_ = nullptr;
    p_ = nullptr;
  }
}

// -----------------------------------------------------------------------
// worker_loop: each worker thread waits for work, processes its partition,
//              then signals completion. Uses a batch counter to prevent
//              re-entering the work loop within the same batch.
// -----------------------------------------------------------------------
void InnerThreadPool::worker_loop(unsigned int worker_id) {
  unsigned int my_batch = 0; // last batch this worker processed

  while (true) {
    std::unique_lock<std::mutex> lock(mutex_);
    // Wait until either shutdown or a new work batch is available.
    cv_start_.wait(lock, [this, &my_batch]() {
      return !running_ ||
             work_batch_.load(std::memory_order_acquire) != my_batch;
    });
    if (!running_) {
      return;
    }

    // Record the current batch so we don't re-enter on the next loop check.
    my_batch = work_batch_.load(std::memory_order_acquire);

    // Grab our partition. The partition vector is stable during execute().
    const Partition part = partitions_[worker_id];
    auto func = func_;
    auto p = p_;

    lock.unlock();

    // Process all work items in this partition.
    for (unsigned int i = part.start; i < part.end; i++) {
      func(p, i);
    }

    // Signal completion.
    lock.lock();
    remaining_--;
    cv_done_.notify_one();
  }
}

// -----------------------------------------------------------------------
// HapDecodeCallback-compatible function
// -----------------------------------------------------------------------
void hap_inner_decode_callback(HapDecodeWorkFunction function, void *p,
                                unsigned int count, void * /*info*/) {
  InnerThreadPool::instance().execute(function, p, count);
}

} // namespace core
} // namespace hap