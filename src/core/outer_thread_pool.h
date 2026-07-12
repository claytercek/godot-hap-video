#ifndef HAP_CORE_OUTER_THREAD_POOL_H
#define HAP_CORE_OUTER_THREAD_POOL_H

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>

namespace hap {
namespace core {

/// A shared, bounded worker pool used for two kinds of jobs:
///
///  - One-shot jobs (submit()): async open (mmap + parse + validate +
///    offset cache), not bound to any stream.
///  - Per-stream jobs (submit_for_stream()): decode work. Jobs sharing a
///    stream key never run concurrently and always run in the order they
///    were submitted, which is what preserves the "each stream decodes
///    strictly serially" invariant the SPSC FrameQueue depends on — even
///    though the pool itself has multiple workers servicing many streams
///    at once.
///
/// Default worker count is 3, shared across all streams — never one
/// pool per stream. This is a singleton for the same reason
/// InnerThreadPool is: the whole point of the two-level design is one
/// shared outer pool process-wide.
class OuterThreadPool {
public:
  using Job = std::function<void()>;

  /// Access the shared instance. Created on first access.
  static OuterThreadPool &instance();

  /// Submit a job with no stream affinity. May run concurrently with
  /// anything else, subject to worker availability.
  void submit(Job job);

  /// Submit a job bound to `stream_id`. Jobs sharing a stream_id run
  /// strictly one at a time, in submission order. Different stream_ids
  /// may run concurrently across the pool's workers.
  void submit_for_stream(uint64_t stream_id, Job job);

  /// Number of worker threads in the pool.
  unsigned int worker_count() const { return num_workers_; }

  /// Block until the pool has no ready or pending work left. Test-only
  /// convenience; production code should not need to wait on the pool.
  void wait_idle();

private:
  OuterThreadPool();
  ~OuterThreadPool();

  OuterThreadPool(const OuterThreadPool &) = delete;
  OuterThreadPool &operator=(const OuterThreadPool &) = delete;

  struct StreamState {
    std::deque<Job> pending;
    bool active = false;
  };

  void worker_loop();
  /// Called (without holding mutex_) after a stream-bound job finishes;
  /// activates the next queued job for that stream, if any.
  void on_stream_job_done(uint64_t stream_id);
  /// Pushes `job` onto ready_ and wakes a worker. mutex_ must be held.
  void enqueue_ready_locked(Job job);

  std::mutex mutex_;
  std::condition_variable cv_;
  std::deque<Job> ready_;
  std::unordered_map<uint64_t, StreamState> streams_;

  std::vector<std::thread> workers_;
  unsigned int num_workers_ = 0;
  bool running_ = true;

  // Bookkeeping so wait_idle() can tell when nothing is in flight.
  int in_flight_ = 0;
};

} // namespace core
} // namespace hap

#endif // HAP_CORE_OUTER_THREAD_POOL_H
