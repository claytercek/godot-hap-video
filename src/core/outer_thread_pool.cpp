#include "outer_thread_pool.h"

#include <algorithm>

namespace hap {
namespace core {

// Default outer worker count. Kept in sync with thread_pool.cpp's
// kOuterWorkers so InnerThreadPool's max(1, hardware_concurrency -
// outer_workers) formula matches the pool actually running here.
static constexpr unsigned int kDefaultOuterWorkers = 3;

OuterThreadPool &OuterThreadPool::instance() {
  static OuterThreadPool pool;
  return pool;
}

OuterThreadPool::OuterThreadPool() {
  unsigned int hw = std::thread::hardware_concurrency();
  if (hw == 0)
    hw = kDefaultOuterWorkers;
  num_workers_ = std::min(kDefaultOuterWorkers, hw);
  if (num_workers_ < 1)
    num_workers_ = 1;

  workers_.reserve(num_workers_);
  for (unsigned int i = 0; i < num_workers_; i++) {
    workers_.emplace_back(&OuterThreadPool::worker_loop, this);
  }
}

OuterThreadPool::~OuterThreadPool() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    running_ = false;
  }
  cv_.notify_all();
  for (auto &w : workers_) {
    if (w.joinable())
      w.join();
  }
}

void OuterThreadPool::enqueue_ready_locked(Job job) {
  ready_.push_back(std::move(job));
  in_flight_++;
  cv_.notify_one();
}

void OuterThreadPool::submit(Job job) {
  std::lock_guard<std::mutex> lock(mutex_);
  enqueue_ready_locked(std::move(job));
}

void OuterThreadPool::submit_for_stream(uint64_t stream_id, Job job) {
  std::lock_guard<std::mutex> lock(mutex_);
  StreamState &st = streams_[stream_id];
  st.pending.push_back(std::move(job));
  if (!st.active) {
    st.active = true;
    Job next = std::move(st.pending.front());
    st.pending.pop_front();
    enqueue_ready_locked([this, stream_id, next = std::move(next)]() mutable {
      next();
      on_stream_job_done(stream_id);
    });
  }
}

void OuterThreadPool::on_stream_job_done(uint64_t stream_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = streams_.find(stream_id);
  if (it == streams_.end())
    return;
  StreamState &st = it->second;
  if (!st.pending.empty()) {
    Job next = std::move(st.pending.front());
    st.pending.pop_front();
    enqueue_ready_locked([this, stream_id, next = std::move(next)]() mutable {
      next();
      on_stream_job_done(stream_id);
    });
  } else {
    st.active = false;
    cv_.notify_all();
  }
}

void OuterThreadPool::worker_loop() {
  while (true) {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait(lock, [this]() { return !running_ || !ready_.empty(); });
    if (!running_ && ready_.empty())
      return;

    Job job = std::move(ready_.front());
    ready_.pop_front();
    lock.unlock();

    job();

    lock.lock();
    in_flight_--;
    if (in_flight_ == 0)
      cv_.notify_all();
  }
}

void OuterThreadPool::wait_idle() {
  std::unique_lock<std::mutex> lock(mutex_);
  cv_.wait(lock, [this]() { return in_flight_ == 0 && ready_.empty(); });
}

void OuterThreadPool::wait_for_stream_idle(uint64_t stream_id) {
  std::unique_lock<std::mutex> lock(mutex_);
  cv_.wait(lock, [this, stream_id]() {
    auto it = streams_.find(stream_id);
    return it == streams_.end() ||
          (!it->second.active && it->second.pending.empty());
  });
}

} // namespace core
} // namespace hap
