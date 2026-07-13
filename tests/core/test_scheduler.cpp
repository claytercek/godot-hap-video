/*
 * DecodeScheduler tests: async open, continuous serial prefetch fill,
 * and seek/queue-behind semantics, against real fixture files.
 *
 * Headless, no GPU.
 */

#include "core/decode_scheduler.h"

#include "test.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <future>
#include <string>
#include <thread>
#include <vector>

using namespace hap::core;

namespace {

std::string find_fixture(const std::string &name) {
  std::vector<std::string> candidates = {
      "tests/fixtures/" + name,
      "../tests/fixtures/" + name,
  };
  for (const auto &p : candidates) {
    FILE *f = fopen(p.c_str(), "rb");
    if (f) {
      fclose(f);
      return p;
    }
  }
  return "";
}

bool wait_for(std::function<bool()> pred, int timeout_ms = 5000) {
  auto start = std::chrono::steady_clock::now();
  while (!pred()) {
    if (std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start)
            .count() > timeout_ms) {
      return false;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return true;
}

} // namespace

HAP_TEST(scheduler_open_async_does_not_block_caller) {
  std::string path = find_fixture("hap1.mov");
  if (path.empty()) {
    fprintf(stderr, "SKIP (no fixture) ");
    return;
  }

  DecodeScheduler scheduler;
  std::atomic<bool> callback_fired{false};
  std::atomic<bool> callback_success{false};

  // open_async must return immediately -- it hands the mmap+parse work
  // to the outer pool rather than doing it on the calling thread.
  scheduler.open_async(path, [&](bool ok, const std::string &err) {
    callback_success.store(ok);
    callback_fired.store(true);
  });

  // The callback runs on a pool worker; give it a bounded window.
  HAP_ASSERT(wait_for([&]() { return callback_fired.load(); }));
  HAP_ASSERT(callback_success.load());
  HAP_ASSERT(scheduler.is_open());
  HAP_ASSERT(scheduler.track_info().frame_count > 0);
}

HAP_TEST(scheduler_open_async_reports_failure_for_missing_file) {
  DecodeScheduler scheduler;
  std::atomic<bool> callback_fired{false};
  std::atomic<bool> callback_success{true};

  scheduler.open_async("tests/fixtures/does_not_exist.mov",
                       [&](bool ok, const std::string &err) {
                         callback_success.store(ok);
                         callback_fired.store(true);
                       });

  HAP_ASSERT(wait_for([&]() { return callback_fired.load(); }));
  HAP_ASSERT(!callback_success.load());
  HAP_ASSERT(!scheduler.is_open());
}

HAP_TEST(scheduler_prefetches_frames_in_order) {
  std::string path = find_fixture("hap1.mov");
  if (path.empty()) {
    fprintf(stderr, "SKIP (no fixture) ");
    return;
  }

  DecodeScheduler scheduler;
  std::atomic<bool> opened{false};
  scheduler.open_async(
      path, [&](bool ok, const std::string &) { opened.store(ok); });
  HAP_ASSERT(wait_for([&]() { return opened.load(); }));

  scheduler.request_frame(0);

  // Consume frames as a render thread would, popping and re-arming
  // prefetch, and check strictly increasing indices with no gaps.
  uint32_t expected = 0;
  uint32_t frame_count = scheduler.track_info().frame_count;
  uint32_t to_read = std::min<uint32_t>(frame_count, 10);

  while (expected < to_read) {
    uint32_t idx = 0;
    bool got = wait_for([&]() { return scheduler.queue().peek(&idx) != nullptr; });
    HAP_ASSERT(got);
    scheduler.queue().peek(&idx);
    HAP_ASSERT_EQ(idx, expected);
    scheduler.queue().pop();
    scheduler.notify_capacity_available();
    expected++;
  }
}

HAP_TEST(scheduler_seek_drains_and_retargets) {
  std::string path = find_fixture("hap1.mov");
  if (path.empty()) {
    fprintf(stderr, "SKIP (no fixture) ");
    return;
  }

  DecodeScheduler scheduler;
  std::atomic<bool> opened{false};
  scheduler.open_async(
      path, [&](bool ok, const std::string &) { opened.store(ok); });
  HAP_ASSERT(wait_for([&]() { return opened.load(); }));

  uint32_t frame_count = scheduler.track_info().frame_count;
  if (frame_count < 3) {
    fprintf(stderr, "SKIP (fixture too short) ");
    return;
  }

  scheduler.request_frame(0);
  // Let a couple of frames prefetch, then seek forward. The queue-behind
  // contract only guarantees the *next* frame observed is >= the seek
  // target (an in-flight decode may still land first).
  std::this_thread::sleep_for(std::chrono::milliseconds(5));

  uint32_t seek_target = frame_count - 1;
  scheduler.request_frame(seek_target);

  uint32_t idx = 0;
  bool got = wait_for([&]() {
    if (scheduler.queue().peek(&idx) == nullptr)
      return false;
    return idx >= seek_target || idx == seek_target;
  });
  HAP_ASSERT(got);
  HAP_ASSERT(idx >= seek_target);
}

HAP_TEST(scheduler_backward_seek_drains_and_retargets) {
  std::string path = find_fixture("hap1.mov");
  if (path.empty()) {
    fprintf(stderr, "SKIP (no fixture) ");
    return;
  }

  DecodeScheduler scheduler;
  std::atomic<bool> opened{false};
  scheduler.open_async(
      path, [&](bool ok, const std::string &) { opened.store(ok); });
  HAP_ASSERT(wait_for([&]() { return opened.load(); }));

  uint32_t frame_count = scheduler.track_info().frame_count;
  if (frame_count < 15) {
    fprintf(stderr, "SKIP (fixture too short) ");
    return;
  }

  scheduler.request_frame(0);

  // Consume forward far enough that the queue is prefetching well past
  // the backward target, so the drain has stale (higher-index) frames
  // to discard.
  uint32_t expected = 0;
  while (expected < 10) {
    uint32_t idx = 0;
    HAP_ASSERT(wait_for([&]() { return scheduler.queue().peek(&idx) != nullptr; }));
    scheduler.queue().peek(&idx);
    HAP_ASSERT_EQ(idx, expected);
    scheduler.queue().pop();
    scheduler.notify_capacity_available();
    expected++;
  }

  // Let a little more forward prefetch land in the (now-refilling) queue
  // before seeking backward, so there is real stale, higher-index
  // material to drain.
  std::this_thread::sleep_for(std::chrono::milliseconds(5));

  const uint32_t seek_target = 2;
  scheduler.request_frame(seek_target);

  // Every frame observed from here on must never regress below the
  // target (no stale pre-seek frame slips through) and must eventually
  // reach the target itself.
  bool saw_target = false;
  auto start = std::chrono::steady_clock::now();
  while (std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now() - start)
             .count() < 5000) {
    uint32_t idx = 0;
    const DecodedFrame *f = scheduler.queue().peek(&idx);
    if (!f) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
      continue;
    }
    HAP_ASSERT(idx >= seek_target);
    if (idx == seek_target)
      saw_target = true;
    scheduler.queue().pop();
    scheduler.notify_capacity_available();
    if (saw_target)
      break;
  }
  HAP_ASSERT(saw_target);
}

HAP_TEST(scheduler_rapid_seeks_resolve_to_latest_target_only) {
  std::string path = find_fixture("hap1.mov");
  if (path.empty()) {
    fprintf(stderr, "SKIP (no fixture) ");
    return;
  }

  DecodeScheduler scheduler;
  std::atomic<bool> opened{false};
  scheduler.open_async(
      path, [&](bool ok, const std::string &) { opened.store(ok); });
  HAP_ASSERT(wait_for([&]() { return opened.load(); }));

  uint32_t frame_count = scheduler.track_info().frame_count;
  if (frame_count < 45) {
    fprintf(stderr, "SKIP (fixture too short) ");
    return;
  }

  scheduler.request_frame(0);

  // Let one frame land and consume it so a decode is plausibly in
  // flight, then fire a burst of seeks back-to-back with no waiting in
  // between -- only the last one should ever be honored (latest seek
  // wins). The discarded targets are chosen far from both the initial
  // in-flight window and the final target so any of them showing up in
  // the queue is unambiguously a scheduling bug, not a coincidence of
  // sequential decode.
  uint32_t idx = 0;
  HAP_ASSERT(wait_for([&]() { return scheduler.queue().peek(&idx) != nullptr; }));
  scheduler.queue().pop();
  scheduler.notify_capacity_available();

  const uint32_t final_target = 3;
  const uint32_t discarded[] = {frame_count - 5, frame_count - 15,
                                frame_count - 25};
  for (uint32_t t : discarded)
    scheduler.request_frame(t);
  scheduler.request_frame(final_target);

  // Drain everything the scheduler produces for a bounded window,
  // asserting none of the discarded targets is ever served and that the
  // final target eventually is.
  bool saw_final_target = false;
  auto start = std::chrono::steady_clock::now();
  while (std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now() - start)
             .count() < 5000) {
    uint32_t observed = 0;
    const DecodedFrame *f = scheduler.queue().peek(&observed);
    if (!f) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
      continue;
    }
    for (uint32_t t : discarded)
      HAP_ASSERT(observed != t);
    if (observed == final_target)
      saw_final_target = true;
    scheduler.queue().pop();
    scheduler.notify_capacity_available();
    if (saw_final_target)
      break;
  }
  HAP_ASSERT(saw_final_target);
}

HAP_TEST(scheduler_reverse_prefetches_frames_in_decreasing_order) {
  std::string path = find_fixture("hap1.mov");
  if (path.empty()) {
    fprintf(stderr, "SKIP (no fixture) ");
    return;
  }

  DecodeScheduler scheduler;
  std::atomic<bool> opened{false};
  scheduler.open_async(
      path, [&](bool ok, const std::string &) { opened.store(ok); });
  HAP_ASSERT(wait_for([&]() { return opened.load(); }));

  uint32_t frame_count = scheduler.track_info().frame_count;
  if (frame_count < 20) {
    fprintf(stderr, "SKIP (fixture too short) ");
    return;
  }

  // Reverse playback: request_frame's `forward=false` overload must decode
  // *backward* from the target, i.e. the frame queue fills with strictly
  // decreasing indices, not the scheduler's default forward cursor.
  const uint32_t start = 19;
  scheduler.request_frame(start, /*forward=*/false);

  uint32_t expected = start;
  for (int i = 0; i < 10; i++) {
    uint32_t idx = 0;
    HAP_ASSERT(wait_for([&]() { return scheduler.queue().peek(&idx) != nullptr; }));
    scheduler.queue().peek(&idx);
    HAP_ASSERT_EQ(idx, expected);
    scheduler.queue().pop();
    scheduler.notify_capacity_available();
    expected--;
  }
}

HAP_TEST(scheduler_reverse_playback_stops_cleanly_at_frame_zero) {
  std::string path = find_fixture("hap1.mov");
  if (path.empty()) {
    fprintf(stderr, "SKIP (no fixture) ");
    return;
  }

  DecodeScheduler scheduler;
  std::atomic<bool> opened{false};
  scheduler.open_async(
      path, [&](bool ok, const std::string &) { opened.store(ok); });
  HAP_ASSERT(wait_for([&]() { return opened.load(); }));

  uint32_t frame_count = scheduler.track_info().frame_count;
  if (frame_count < 5) {
    fprintf(stderr, "SKIP (fixture too short) ");
    return;
  }

  // Reverse playback that reaches the start of the stream must present
  // frame 0 exactly once and then settle -- no underflow (frame_index is
  // unsigned), no crash, no runaway re-decode of frame 0 forever.
  scheduler.request_frame(4, /*forward=*/false);

  uint32_t idx = 5; // sentinel higher than any expected index
  bool saw_zero = false;
  for (int i = 0; i < 5; i++) {
    HAP_ASSERT(wait_for([&]() { return scheduler.queue().peek(&idx) != nullptr; }));
    scheduler.queue().peek(&idx);
    HAP_ASSERT_EQ(idx, 4u - static_cast<uint32_t>(i));
    if (idx == 0)
      saw_zero = true;
    scheduler.queue().pop();
    scheduler.notify_capacity_available();
    if (saw_zero)
      break;
  }
  HAP_ASSERT(saw_zero);

  // Give the scheduler a bounded window to (mis)behave: it must not
  // produce another frame after 0 (no wraparound, no duplicate spam).
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  HAP_ASSERT(scheduler.queue().peek(&idx) == nullptr);
}

HAP_TEST(scheduler_destroyed_immediately_after_open_does_not_hang_or_crash) {
  std::string path = find_fixture("hap1.mov");
  if (path.empty()) {
    fprintf(stderr, "SKIP (no fixture) ");
    return;
  }

  // Destroying a DecodeScheduler while its open_async job is still queued
  // or in flight must be safe: the destructor has to block until that job
  // (which captures `this`) finishes, rather than let it run against
  // freed memory. Run off-thread with a bounded wait so a regression
  // (destructor returns without joining the job) hangs this test instead
  // of the whole suite.
  std::promise<void> done;
  std::future<void> done_future = done.get_future();
  std::thread runner([&]() {
    for (int i = 0; i < 20; i++) {
      DecodeScheduler scheduler;
      scheduler.open_async(path, [](bool, const std::string &) {});
      // No wait for the callback -- destructor races the open job.
    }
    done.set_value();
  });
  runner.detach();

  HAP_ASSERT(done_future.wait_for(std::chrono::seconds(10)) ==
             std::future_status::ready);
}

int main() { return hap::test::run_all(); }
