#include "hap_video_stream_playback.h"

#include "core/hap_frame.h"

#include <chrono>
#include <thread>

#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>

namespace godot {

// -----------------------------------------------------------------------
// Open (async)
// -----------------------------------------------------------------------
bool HapVideoStreamPlayback::open(const String &p_path) {
  if (p_path.is_empty()) {
    ERR_PRINT("HapVideo: empty path");
    return false;
  }

  // The core demuxer mmaps the file directly, so it needs a real
  // filesystem path -- res:// and user:// are Godot virtual-filesystem
  // prefixes FileAccess resolves internally, but mmap() has no idea
  // about them. Absolute paths pass through globalize_path() unchanged.
  String real_path = ProjectSettings::get_singleton()->globalize_path(p_path);
  std::string path = real_path.utf8().get_data();

  // The async open callback runs on an outer-pool worker thread and may
  // fire after this object is gone; alive_ (kept alive by the shared_ptr
  // captured by value) lets it detect that and bail without touching
  // `this`.
  scheduler_.open_async(
      path, [this, alive = alive_](bool ok, const std::string &err) {
        if (!alive->load(std::memory_order_acquire))
          return;
        if (ok) {
          open_ready_.store(true, std::memory_order_release);
        } else {
          open_error_ = err;
          open_failed_.store(true, std::memory_order_release);
        }
      });

  // open_async() only hands the mmap+parse job to the outer pool and
  // returns immediately -- nothing above blocks the main thread.
  return true;
}

// -----------------------------------------------------------------------
// Post-open initialization: metadata + GPU resources
// -----------------------------------------------------------------------
void HapVideoStreamPlayback::initialize_after_open() {
  track_ = scheduler_.track_info();

  frame_duration_ =
      track_.frame_rate > 0.0 ? 1.0 / track_.frame_rate : 1.0 / 30.0;
  length_ = frame_duration_ * track_.frame_count;

  RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
  if (!gpu_presenter_.initialize(rd, static_cast<int>(track_.width),
                                 static_cast<int>(track_.height),
                                 track_.fourcc)) {
    ERR_PRINT("HapVideo: Failed to initialize GPU presenter");
    gpu_init_failed_ = true;
    return;
  }

  // Resolve any seek/position that arrived before open completed (e.g.
  // stream_position set immediately after assigning the stream) rather
  // than always starting from frame 0.
  if (current_time_ > length_)
    current_time_ = length_;
  current_frame_ = frame_from_time(current_time_);

  playback_initialized_ = true;
  scheduler_.request_frame(current_frame_);
}

bool HapVideoStreamPlayback::wait_for_open() {
  // The moov parse is milliseconds even for multi-gigabyte files; the
  // bound only guards against a pathological stall (e.g. a dead network
  // mount), turning it into a clean open failure instead of a hang.
  constexpr int kMaxWaitMs = 30000;
  for (int waited = 0; waited < kMaxWaitMs; waited++) {
    if (open_failed_.load(std::memory_order_acquire))
      return false;
    if (open_ready_.load(std::memory_order_acquire))
      return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return false;
}

bool HapVideoStreamPlayback::poll_ready() {
  if (open_failed_.load(std::memory_order_acquire))
    return false;
  if (!open_ready_.load(std::memory_order_acquire))
    return false;
  if (!playback_initialized_ && !gpu_init_failed_)
    initialize_after_open();
  return playback_initialized_;
}

bool HapVideoStreamPlayback::has_failed() const {
  return open_failed_.load(std::memory_order_acquire) || gpu_init_failed_;
}

String HapVideoStreamPlayback::get_error() const {
  if (open_failed_.load(std::memory_order_acquire))
    return String(open_error_.c_str());
  if (gpu_init_failed_)
    return "Failed to initialize GPU presenter";
  return String();
}

void HapVideoStreamPlayback::advance_to_frame(uint32_t frame_index,
                                              bool forward, bool retarget) {
  if (!playback_initialized_)
    return;

  if (track_.frame_count > 0 && frame_index >= track_.frame_count)
    frame_index = track_.frame_count - 1;

  current_frame_ = frame_index;
  current_time_ = frame_index * frame_duration_;

  if (retarget)
    scheduler_.request_frame(frame_index, forward);

  present_up_to_frame(frame_index, forward);
}

uint32_t HapVideoStreamPlayback::frame_from_time(double p_time) const {
  uint32_t frame = frame_duration_ > 0.0
                       ? static_cast<uint32_t>(p_time / frame_duration_)
                       : 0;
  if (track_.frame_count > 0 && frame >= track_.frame_count)
    frame = track_.frame_count - 1;
  return frame;
}

// -----------------------------------------------------------------------
// Drain the frame queue up to and including target_frame
// -----------------------------------------------------------------------
void HapVideoStreamPlayback::present_up_to_frame(uint32_t target_frame,
                                                 bool forward) {
  hap::core::FrameQueue &q = scheduler_.queue();

  uint32_t idx = 0;
  const hap::core::DecodedFrame *f = q.peek(&idx);
  while (f && (forward ? idx < target_frame : idx > target_frame)) {
    // Stale prefetch: behind the target when advancing forward, or
    // ahead of it (i.e. from before a reverse seek caught up) when
    // advancing backward.
    q.pop();
    scheduler_.notify_capacity_available();
    f = q.peek(&idx);
  }

  if (f && idx == target_frame) {
    gpu_presenter_.present(*f);
    q.pop();
    scheduler_.notify_capacity_available();
  }
  // else: decode hasn't caught up yet -- keep showing the previous
  // frame rather than blocking; the next _update() tick will retry.
}

// -----------------------------------------------------------------------
// VideoStreamPlayback virtuals
// -----------------------------------------------------------------------
void HapVideoStreamPlayback::_play() {
  is_playing_ = true;
  is_paused_ = false;
  current_time_ = 0.0;
  current_frame_ = 0;
  if (playback_initialized_) {
    scheduler_.request_frame(0);
  }
}

void HapVideoStreamPlayback::_stop() {
  is_playing_ = false;
  is_paused_ = false;
  current_time_ = 0.0;
  current_frame_ = 0;
}

bool HapVideoStreamPlayback::_is_playing() const { return is_playing_; }

void HapVideoStreamPlayback::_set_paused(bool p_paused) {
  is_paused_ = p_paused;
}

bool HapVideoStreamPlayback::_is_paused() const { return is_paused_; }

double HapVideoStreamPlayback::_get_length() const { return length_; }

double HapVideoStreamPlayback::_get_playback_position() const {
  return current_time_;
}

void HapVideoStreamPlayback::_seek(double p_time) {
  if (p_time < 0.0)
    p_time = 0.0;

  if (!playback_initialized_) {
    // Not open yet; remember the requested time. initialize_after_open()
    // resolves it to a frame once track length is known, rather than
    // discarding it and always starting from frame 0.
    current_time_ = p_time;
    return;
  }

  if (p_time > length_)
    p_time = length_;
  current_time_ = p_time;
  current_frame_ = frame_from_time(current_time_);

  scheduler_.request_frame(current_frame_);
}

void HapVideoStreamPlayback::_set_audio_track(int32_t p_idx) {}

Ref<Texture2D> HapVideoStreamPlayback::_get_texture() const {
  return gpu_presenter_.get_texture();
}

void HapVideoStreamPlayback::_update(double p_delta) {
  if (!poll_ready()) {
    // gpu_init_failed_ is already logged once, from inside
    // initialize_after_open(); only the async-open failure needs its
    // own once-only log here.
    if (open_failed_.load(std::memory_order_acquire) && !open_error_logged_) {
      ERR_PRINT("HapVideo: " + String(open_error_.c_str()));
      open_error_logged_ = true;
    }
    return;
  }

  if (is_playing_ && !is_paused_) {
    current_time_ += p_delta;

    if (current_time_ >= length_) {
      is_playing_ = false;
      current_time_ = length_;
      current_frame_ = track_.frame_count > 0 ? track_.frame_count - 1 : 0;
    } else {
      current_frame_ = frame_from_time(current_time_);
    }
  }

  present_up_to_frame(current_frame_);
}

int32_t HapVideoStreamPlayback::_get_channels() const { return 0; }

int32_t HapVideoStreamPlayback::_get_mix_rate() const { return 0; }

} // namespace godot
