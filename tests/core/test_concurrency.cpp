/*
 * Concurrency unit tests: SPSC frame queue contract, outer-pool per-stream
 * serial invariant, retire ring sequencing, and thread-count bounds.
 *
 * Headless, no GPU.
 */

#include "core/frame_queue.h"
#include "core/outer_thread_pool.h"
#include "core/retire_ring.h"
#include "core/thread_pool.h"

#include "hap.h"
#include "test.h"
#include "test_hap_frames.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <thread>
#include <vector>

using namespace hap::core;

// -----------------------------------------------------------------------
// RetireRing
// -----------------------------------------------------------------------

HAP_TEST(retire_ring_default_depth_is_3) {
  RetireRing<> ring;
  HAP_ASSERT_EQ(ring.depth(), (size_t)3);
}

HAP_TEST(retire_ring_writable_never_equals_current) {
  RetireRing<3> ring;
  for (int i = 0; i < 10; i++) {
    HAP_ASSERT(ring.writable_slot() != ring.current_slot());
    ring.commit();
  }
}

HAP_TEST(retire_ring_cycles_through_all_slots_in_order) {
  RetireRing<3> ring;
  // current_slot starts at 0; each commit advances by one, wrapping.
  HAP_ASSERT_EQ(ring.current_slot(), (size_t)0);
  ring.commit();
  HAP_ASSERT_EQ(ring.current_slot(), (size_t)1);
  ring.commit();
  HAP_ASSERT_EQ(ring.current_slot(), (size_t)2);
  ring.commit();
  HAP_ASSERT_EQ(ring.current_slot(), (size_t)0);
}

HAP_TEST(retire_ring_writer_stays_two_slots_behind_reader) {
  // With depth 3, the slot a writer is about to fill was last "current"
  // two commits ago -- i.e. it was retired (no longer the display slot)
  // for a full extra generation beyond Godot's frame-queue depth of 2.
  RetireRing<3> ring;
  size_t slot_two_generations_ago = ring.current_slot();
  ring.commit();
  ring.commit();
  HAP_ASSERT_EQ(ring.writable_slot(), slot_two_generations_ago);
}

// -----------------------------------------------------------------------
// FrameQueue
// -----------------------------------------------------------------------

HAP_TEST(frame_queue_starts_empty_not_full) {
  FrameQueue q(4);
  HAP_ASSERT(q.empty());
  HAP_ASSERT(!q.full());
  HAP_ASSERT_EQ(q.capacity(), (size_t)4);
}

HAP_TEST(frame_queue_push_pop_preserves_order_and_index) {
  FrameQueue q(4);
  for (uint32_t i = 0; i < 4; i++) {
    DecodedFrame *slot = q.begin_write(i);
    HAP_ASSERT(slot != nullptr);
    slot->textures.resize(1);
    slot->textures[0].data = {static_cast<uint8_t>(i)};
    q.commit_write();
  }
  HAP_ASSERT(q.full());

  for (uint32_t i = 0; i < 4; i++) {
    uint32_t idx = 999;
    const DecodedFrame *f = q.peek(&idx);
    HAP_ASSERT(f != nullptr);
    HAP_ASSERT_EQ(idx, i);
    HAP_ASSERT_EQ(f->textures[0].data[0], static_cast<uint8_t>(i));
    q.pop();
  }
  HAP_ASSERT(q.empty());
}

HAP_TEST(frame_queue_begin_write_returns_null_when_full) {
  FrameQueue q(2);
  HAP_ASSERT(q.begin_write(0) != nullptr);
  q.commit_write();
  HAP_ASSERT(q.begin_write(1) != nullptr);
  q.commit_write();
  // Full: producer must back off (this is the seek/prefetch
  // queue-behind boundary, not an error).
  HAP_ASSERT(q.begin_write(2) == nullptr);
}

HAP_TEST(frame_queue_peek_pop_on_empty_is_safe) {
  FrameQueue q(4);
  HAP_ASSERT(q.peek() == nullptr);
  q.pop(); // must not crash or underflow count_
  HAP_ASSERT(q.empty());
}

HAP_TEST(frame_queue_slots_reuse_buffer_capacity) {
  // A slot's DecodedTexture buffer should retain its capacity across a
  // pop/refill cycle when the new frame is the same size (steady-state
  // playback), i.e. no reallocation on the happy path. With depth 2, the
  // ring returns to slot 0 on the 3rd write (0, 1, 0, 1, ...).
  FrameQueue q(2);

  DecodedFrame *w0 = q.begin_write(0);
  w0->textures.resize(1);
  w0->textures[0].data.resize(1024);
  const uint8_t *original_ptr = w0->textures[0].data.data();
  q.commit_write();
  q.pop();

  DecodedFrame *w1 = q.begin_write(1); // slot 1, unrelated buffer
  w1->textures.resize(1);
  w1->textures[0].data.resize(1024);
  q.commit_write();
  q.pop();

  DecodedFrame *w2 = q.begin_write(2); // wraps back to slot 0
  HAP_ASSERT(w2 == w0);
  w2->textures.resize(1);
  w2->textures[0].data.resize(1024); // same size: no reallocation expected
  HAP_ASSERT_EQ(w2->textures[0].data.data(), original_ptr);
  q.commit_write();
}

HAP_TEST(frame_queue_drain_discards_committed_frames) {
  FrameQueue q(4);
  for (uint32_t i = 0; i < 3; i++) {
    q.begin_write(i);
    q.commit_write();
  }
  HAP_ASSERT(!q.empty());
  q.drain();
  HAP_ASSERT(q.empty());
  HAP_ASSERT(!q.full());
}

HAP_TEST(frame_queue_concurrent_producer_consumer) {
  // Real SPSC usage: one producer thread, one consumer thread, depth 4,
  // 2000 frames. Consumer must observe strictly increasing frame indices
  // with no gaps or duplicates.
  FrameQueue q(4);
  constexpr uint32_t kFrames = 2000;
  std::atomic<bool> producer_done{false};

  std::thread producer([&]() {
    uint32_t i = 0;
    while (i < kFrames) {
      DecodedFrame *slot = q.begin_write(i);
      if (!slot) {
        std::this_thread::yield();
        continue;
      }
      slot->textures.resize(1);
      slot->textures[0].data = {static_cast<uint8_t>(i & 0xFF)};
      q.commit_write();
      i++;
    }
    producer_done.store(true, std::memory_order_release);
  });

  std::thread consumer([&]() {
    uint32_t expected = 0;
    while (expected < kFrames) {
      uint32_t idx = 0;
      const DecodedFrame *f = q.peek(&idx);
      if (!f) {
        std::this_thread::yield();
        continue;
      }
      HAP_ASSERT_EQ(idx, expected);
      HAP_ASSERT_EQ(f->textures[0].data[0],
                    static_cast<uint8_t>(expected & 0xFF));
      q.pop();
      expected++;
    }
  });

  producer.join();
  consumer.join();
  HAP_ASSERT(producer_done.load());
}

// -----------------------------------------------------------------------
// OuterThreadPool: per-stream serial invariant
// -----------------------------------------------------------------------

HAP_TEST(outer_pool_default_worker_count_matches_spec) {
  // Spec default: kDefaultWorkers shared outer workers.
  HAP_ASSERT_EQ(OuterThreadPool::instance().worker_count(),
                std::min(OuterThreadPool::kDefaultWorkers,
                         std::max(1u, std::thread::hardware_concurrency())));
}

HAP_TEST(outer_pool_serializes_jobs_within_a_stream) {
  OuterThreadPool &pool = OuterThreadPool::instance();

  constexpr uint64_t kStreamA = 0xA;
  constexpr uint64_t kStreamB = 0xB;
  constexpr int kJobsPerStream = 200;

  std::atomic<int> a_in_flight{0};
  std::atomic<int> b_in_flight{0};
  std::atomic<int> a_max_concurrency{0};
  std::atomic<int> b_max_concurrency{0};
  std::atomic<int> a_completed{0};
  std::atomic<int> b_completed{0};
  std::vector<int> a_order;
  std::vector<int> b_order;
  std::mutex order_mutex;

  for (int i = 0; i < kJobsPerStream; i++) {
    pool.submit_for_stream(kStreamA, [&, i]() {
      int cur = a_in_flight.fetch_add(1) + 1;
      int prev_max = a_max_concurrency.load();
      while (cur > prev_max &&
             !a_max_concurrency.compare_exchange_weak(prev_max, cur)) {
      }
      {
        std::lock_guard<std::mutex> lock(order_mutex);
        a_order.push_back(i);
      }
      std::this_thread::sleep_for(std::chrono::microseconds(50));
      a_in_flight.fetch_sub(1);
      a_completed.fetch_add(1);
    });
    pool.submit_for_stream(kStreamB, [&, i]() {
      int cur = b_in_flight.fetch_add(1) + 1;
      int prev_max = b_max_concurrency.load();
      while (cur > prev_max &&
             !b_max_concurrency.compare_exchange_weak(prev_max, cur)) {
      }
      {
        std::lock_guard<std::mutex> lock(order_mutex);
        b_order.push_back(i);
      }
      std::this_thread::sleep_for(std::chrono::microseconds(50));
      b_in_flight.fetch_sub(1);
      b_completed.fetch_add(1);
    });
  }

  pool.wait_idle();

  HAP_ASSERT_EQ(a_completed.load(), kJobsPerStream);
  HAP_ASSERT_EQ(b_completed.load(), kJobsPerStream);
  // Never more than one job in flight per stream, regardless of pool size.
  HAP_ASSERT_EQ(a_max_concurrency.load(), 1);
  HAP_ASSERT_EQ(b_max_concurrency.load(), 1);
  // FIFO order within each stream.
  HAP_ASSERT_EQ((int)a_order.size(), kJobsPerStream);
  HAP_ASSERT_EQ((int)b_order.size(), kJobsPerStream);
  for (int i = 0; i < kJobsPerStream; i++) {
    HAP_ASSERT_EQ(a_order[i], i);
    HAP_ASSERT_EQ(b_order[i], i);
  }
}

HAP_TEST(outer_pool_different_streams_run_concurrently) {
  // With >=2 workers, two different streams' jobs should be able to
  // overlap in time (this isn't guaranteed on a single-core CI box, so
  // only assert it when the pool actually has room for it).
  OuterThreadPool &pool = OuterThreadPool::instance();
  if (pool.worker_count() < 2) {
    return;
  }

  std::atomic<int> concurrent{0};
  std::atomic<int> observed_overlap{0};
  constexpr uint64_t kStreamA = 0x1111;
  constexpr uint64_t kStreamB = 0x2222;

  auto job = [&]() {
    int cur = concurrent.fetch_add(1) + 1;
    if (cur >= 2)
      observed_overlap.store(1);
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    concurrent.fetch_sub(1);
  };

  for (int i = 0; i < 5; i++) {
    pool.submit_for_stream(kStreamA, job);
    pool.submit_for_stream(kStreamB, job);
  }
  pool.wait_idle();

  HAP_ASSERT_EQ(observed_overlap.load(), 1);
}

// -----------------------------------------------------------------------
// InnerThreadPool: concurrent execute() safety, thread-count bound
// -----------------------------------------------------------------------

HAP_TEST(inner_pool_survives_concurrent_execute_calls) {
  // Two "outer workers" both decoding chunked frames at once must not
  // corrupt the shared work-batch state.
  InnerThreadPool &pool = InnerThreadPool::instance();

  auto run_batch = [&](std::atomic<int> &sum) {
    constexpr unsigned int kChunks = 37;
    std::atomic<int> local_sum{0};
    pool.execute(
        [](void *p, unsigned int i) {
          auto *acc = static_cast<std::atomic<int> *>(p);
          acc->fetch_add(static_cast<int>(i));
        },
        &local_sum, kChunks);
    // 0 + 1 + ... + 36 = 666
    sum.store(local_sum.load());
  };

  std::atomic<int> sum_a{0};
  std::atomic<int> sum_b{0};
  std::thread ta([&]() {
    for (int i = 0; i < 20; i++)
      run_batch(sum_a);
  });
  std::thread tb([&]() {
    for (int i = 0; i < 20; i++)
      run_batch(sum_b);
  });
  ta.join();
  tb.join();

  HAP_ASSERT_EQ(sum_a.load(), 666);
  HAP_ASSERT_EQ(sum_b.load(), 666);
}

HAP_TEST(outer_times_inner_stays_within_hardware_concurrency) {
  unsigned int hw = std::thread::hardware_concurrency();
  if (hw == 0)
    return; // undetectable on this platform; nothing to assert
  unsigned int outer = OuterThreadPool::instance().worker_count();
  unsigned int inner = InnerThreadPool::instance().worker_count();
  // Spec formula: inner = max(1, hw - outer), so outer + inner <= hw
  // (the two pools' worker threads never together exceed hardware
  // concurrency).
  HAP_ASSERT(outer + inner <= hw || inner == 1);
}

// -----------------------------------------------------------------------
// InnerThreadPool: HapDecode work-batch dispatch (moved from
// test_decoder.cpp -- these exercise the same InnerThreadPool as the
// tests above, not decoder-specific behavior)
// -----------------------------------------------------------------------

struct WorkItem {
  std::atomic<unsigned int> call_count{0};
};

static void test_work_function(void *p, unsigned int /*index*/) {
  auto *item = static_cast<WorkItem *>(p);
  item->call_count.fetch_add(1, std::memory_order_relaxed);
}

HAP_TEST(test_thread_pool_basic) {
  auto &pool = InnerThreadPool::instance();

  // The pool should have at least 1 worker
  HAP_ASSERT(pool.worker_count() >= 1);

  // Verify the thread count matches the formula
  // max(1, hardware_concurrency - kDefaultWorkers)
  unsigned int hw = std::thread::hardware_concurrency();
  unsigned int outer = OuterThreadPool::kDefaultWorkers;
  unsigned int expected = (hw > outer) ? (hw - outer) : 1;
  HAP_ASSERT_EQ(pool.worker_count(), expected);
}

HAP_TEST(test_thread_pool_no_workers_if_single_item) {
  // A single work item should complete immediately via the calling thread
  auto &pool = InnerThreadPool::instance();

  WorkItem item;
  pool.execute(test_work_function, &item, 1);

  HAP_ASSERT_EQ(item.call_count.load(), 1u);
}

HAP_TEST(test_thread_pool_multi_work_items) {
  auto &pool = InnerThreadPool::instance();

  WorkItem item;
  const unsigned int kCount = 100;

  pool.execute(test_work_function, &item, kCount);

  // All work items must have been executed
  HAP_ASSERT_EQ(item.call_count.load(), kCount);
}

HAP_TEST(test_thread_pool_no_remaining_state) {
  // Execute multiple batches to ensure no state leaks between calls
  auto &pool = InnerThreadPool::instance();

  WorkItem item1;
  WorkItem item2;

  pool.execute(test_work_function, &item1, 5);
  HAP_ASSERT_EQ(item1.call_count.load(), 5u);

  pool.execute(test_work_function, &item2, 7);
  HAP_ASSERT_EQ(item2.call_count.load(), 7u);

  // item1 should not have been called again
  HAP_ASSERT_EQ(item1.call_count.load(), 5u);
}

HAP_TEST(test_thread_pool_large_count) {
  auto &pool = InnerThreadPool::instance();

  // Use a count that exceeds the number of workers to test partitioning
  const unsigned int kCount = 1000;
  WorkItem item;

  pool.execute(test_work_function, &item, kCount);
  HAP_ASSERT_EQ(item.call_count.load(), kCount);
}

// -----------------------------------------------------------------------
// Callback contract: verify HapDecode respects the single-chunk contract
// (moved from test_decoder.cpp -- this is thread-pool dispatch behavior,
// not decode-correctness behavior)
// -----------------------------------------------------------------------

using hap::test::create_chunked_frame;
using hap::test::create_unchunked_hap1;

static int callback_invocation_count = 0;

static void tracking_callback(HapDecodeWorkFunction function, void *p,
                               unsigned int count, void *info) {
  callback_invocation_count++;
  // Forward to the inner pool for proper multi-threaded decode
  hap_inner_decode_callback(function, p, count, info);
}

static void reset_callback_count() { callback_invocation_count = 0; }

HAP_TEST(test_decoder_callback_not_invoked_for_single_chunk) {
  // Create an unchunked frame and decode it with our tracking callback
  uint8_t bc1_block[8] = {0xFF, 0xFF, 0x00, 0x00,
                           0x00, 0x00, 0x00, 0x00};
  auto frame = create_unchunked_hap1(bc1_block, sizeof(bc1_block));

  // Decode with the tracking callback via HapDecode directly
  unsigned int tex_format = 0;
  unsigned long bytes_used = 0;
  uint8_t output[1024];

  reset_callback_count();

  unsigned int result = HapDecode(
      frame.data(), static_cast<unsigned long>(frame.size()), 0,
      tracking_callback, nullptr, output, sizeof(output),
      &bytes_used, &tex_format);

  HAP_ASSERT_EQ(result, (unsigned int)HapResult_No_Error);

  // The callback must NOT have been invoked for a single-chunk frame
  HAP_ASSERT_EQ(callback_invocation_count, 0);
}

HAP_TEST(test_decoder_callback_invoked_for_multi_chunk) {
  // Create raw BC1 data (1024 bytes = 128 BC1 blocks), large enough
  // for HapEncode to produce a Complex (chunked) frame.
  uint8_t bc1_data[1024];
  std::memset(bc1_data, 0, sizeof(bc1_data));

  // Encode with 4 chunks
  auto chunked = create_chunked_frame(bc1_data, sizeof(bc1_data), 4,
                                       HapTextureFormat_RGB_DXT1,
                                       HapCompressorSnappy);
  HAP_ASSERT(!chunked.empty());

  // Decode with the tracking callback via HapDecode directly
  unsigned int tex_format = 0;
  unsigned long bytes_used = 0;
  uint8_t output[4096];

  reset_callback_count();

  unsigned int result = HapDecode(
      chunked.data(), static_cast<unsigned long>(chunked.size()), 0,
      tracking_callback, nullptr, output, sizeof(output),
      &bytes_used, &tex_format);

  HAP_ASSERT_EQ(result, (unsigned int)HapResult_No_Error);

  // The callback MUST have been invoked exactly once for a multi-chunk frame
  HAP_ASSERT_EQ(callback_invocation_count, 1);
}

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------
int main() { return hap::test::run_all(); }
