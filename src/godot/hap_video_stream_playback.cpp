#include "hap_video_stream_playback.h"

#include "core/decoder.h"
#include "core/hap_frame.h"

#include "gpu_presenter.h"

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstring>

namespace godot {

// -----------------------------------------------------------------------
// Open
// -----------------------------------------------------------------------
bool HapVideoStreamPlayback::open(const String &p_path) {
  if (!mmap_.open(p_path.utf8().get_data())) {
    ERR_PRINT("HapVideo: Failed to open file: " + p_path);
    return false;
  }

  auto result = demuxer_.open(mmap_);
  if (!result.valid) {
    ERR_PRINT("HapVideo: " + String(result.error_message.c_str()));
    mmap_.close();
    return false;
  }

  track_ = result.track;
  samples_ = std::move(result.samples);

  if (track_.frame_rate > 0.0) {
    frame_duration_ = 1.0 / track_.frame_rate;
  } else {
    frame_duration_ = 1.0 / 30.0;
  }
  length_ = frame_duration_ * track_.frame_count;

  // Initialize the GPU presenter
  RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
  if (rd) {
    gpu_initialized_ = gpu_presenter_.initialize(
        rd, track_.width, track_.height, track_.fourcc);
    if (!gpu_initialized_) {
      ERR_PRINT("HapVideo: Failed to initialize GPU presenter");
    }
  } else {
    ERR_PRINT("HapVideo: No RenderingDevice available");
  }

  // Decode the first frame
  const uint8_t *sample = demuxer_.sample_data(mmap_, 0);
  if (sample) {
    hap::core::DecodedFrame frame;
    if (decoder_.decode(sample, samples_[0].size, frame)) {
      upload_decoded_frame(frame);
    }
  }

  return true;
}

// -----------------------------------------------------------------------
// Upload a decoded frame to the GPU
// -----------------------------------------------------------------------
void HapVideoStreamPlayback::upload_decoded_frame(
    const hap::core::DecodedFrame &frame) {
  if (frame.textures.empty())
    return;

  if (gpu_initialized_) {
    gpu_presenter_.present(frame);
  }
}

// -----------------------------------------------------------------------
// VideoStreamPlayback virtuals
// -----------------------------------------------------------------------
void HapVideoStreamPlayback::_play() {
  is_playing_ = true;
  is_paused_ = false;
  current_time_ = 0.0;
  current_frame_ = 0;
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
  if (p_time > length_)
    p_time = length_;

  current_time_ = p_time;
  if (frame_duration_ > 0.0) {
    current_frame_ = static_cast<uint32_t>(p_time / frame_duration_);
    if (current_frame_ >= track_.frame_count)
      current_frame_ = track_.frame_count - 1;
  }
}

void HapVideoStreamPlayback::_set_audio_track(int32_t p_idx) {}

Ref<Texture2D> HapVideoStreamPlayback::_get_texture() const {
  if (gpu_initialized_) {
    return gpu_presenter_.get_texture();
  }
  return Ref<Texture2D>();
}

void HapVideoStreamPlayback::_update(double p_delta) {
  if (!is_playing_ || is_paused_)
    return;

  if (!mmap_ || !demuxer_.is_valid())
    return;

  current_time_ += p_delta;

  if (current_time_ >= length_) {
    is_playing_ = false;
    current_time_ = length_;
    current_frame_ = track_.frame_count - 1;

    const uint8_t *sample = demuxer_.sample_data(mmap_, current_frame_);
    if (sample) {
      hap::core::DecodedFrame frame;
      if (decoder_.decode(sample, samples_[current_frame_].size, frame)) {
        upload_decoded_frame(frame);
      }
    }
    return;
  }

  uint32_t new_frame =
      static_cast<uint32_t>(current_time_ / frame_duration_);
  if (new_frame >= track_.frame_count)
    new_frame = track_.frame_count - 1;

  if (new_frame != current_frame_) {
    current_frame_ = new_frame;

    const uint8_t *sample = demuxer_.sample_data(mmap_, current_frame_);
    if (sample) {
      hap::core::DecodedFrame frame;
      if (decoder_.decode(sample, samples_[current_frame_].size, frame)) {
        upload_decoded_frame(frame);
      }
    }
  }
}

int32_t HapVideoStreamPlayback::_get_channels() const { return 0; }

int32_t HapVideoStreamPlayback::_get_mix_rate() const { return 0; }

} // namespace godot