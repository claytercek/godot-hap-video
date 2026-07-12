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

int main() { return hap::test::run_all(); }
