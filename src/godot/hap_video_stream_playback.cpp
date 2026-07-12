#include "hap_video_stream_playback.h"

#include "core/hap_frame.h"

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {

// -----------------------------------------------------------------------
// Open (async)
// -----------------------------------------------------------------------
bool HapVideoStreamPlayback::open(const String &p_path) {
  if (p_path.is_empty()) {
    ERR_PRINT("HapVideo: empty path");
    return false;
  }

  std::string path = p_path.utf8().get_data();

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

  playback_initialized_ = true;
  scheduler_.request_frame(0);
}

// -----------------------------------------------------------------------
// Drain the frame queue up to and including target_frame
// -----------------------------------------------------------------------
void HapVideoStreamPlayback::present_up_to_frame(uint32_t target_frame) {
  hap::core::FrameQueue &q = scheduler_.queue();

  uint32_t idx = 0;
  const hap::core::DecodedFrame *f = q.peek(&idx);
  while (f && idx < target_frame) {
    // Stale prefetch (shouldn't normally happen in forward playback,
    // but seeks and frame-stepping can leave the queue briefly ahead).
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
    // Not open yet; remember the request for once init runs the first
    // present, but there's no track length to clamp against yet.
    current_time_ = p_time;
    current_frame_ = 0;
    return;
  }

  if (p_time > length_)
    p_time = length_;
  current_time_ = p_time;

  current_frame_ = frame_duration_ > 0.0
                       ? static_cast<uint32_t>(p_time / frame_duration_)
                       : 0;
  if (track_.frame_count > 0 && current_frame_ >= track_.frame_count)
    current_frame_ = track_.frame_count - 1;

  scheduler_.request_frame(current_frame_);
}

void HapVideoStreamPlayback::_set_audio_track(int32_t p_idx) {}

Ref<Texture2D> HapVideoStreamPlayback::_get_texture() const {
  return gpu_presenter_.get_texture();
}

void HapVideoStreamPlayback::_update(double p_delta) {
  if (open_failed_.load(std::memory_order_acquire)) {
    if (!open_error_logged_) {
      ERR_PRINT("HapVideo: " + String(open_error_.c_str()));
      open_error_logged_ = true;
    }
    return;
  }

  if (!open_ready_.load(std::memory_order_acquire))
    return; // still opening asynchronously

  if (!playback_initialized_) {
    if (gpu_init_failed_)
      return;
    initialize_after_open();
    if (!playback_initialized_)
      return;
  }

  if (is_playing_ && !is_paused_) {
    current_time_ += p_delta;

    if (current_time_ >= length_) {
      is_playing_ = false;
      current_time_ = length_;
      current_frame_ = track_.frame_count > 0 ? track_.frame_count - 1 : 0;
    } else {
      uint32_t new_frame =
          frame_duration_ > 0.0
              ? static_cast<uint32_t>(current_time_ / frame_duration_)
              : 0;
      if (track_.frame_count > 0 && new_frame >= track_.frame_count)
        new_frame = track_.frame_count - 1;
      current_frame_ = new_frame;
    }
  }

  present_up_to_frame(current_frame_);
}

int32_t HapVideoStreamPlayback::_get_channels() const { return 0; }

int32_t HapVideoStreamPlayback::_get_mix_rate() const { return 0; }

} // namespace godot
