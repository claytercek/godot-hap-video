#ifndef HAP_VIDEO_STREAM_PLAYBACK_H
#define HAP_VIDEO_STREAM_PLAYBACK_H

#include "gpu_presenter.h"
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/classes/video_stream_playback.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include "core/demuxer.h"
#include "core/decoder.h"
#include "core/hap_frame.h"
#include "core/mmap_reader.h"

#include <memory>
#include <vector>

namespace godot {

class HapVideoStreamPlayback : public VideoStreamPlayback {
  GDEXTENSION_CLASS(HapVideoStreamPlayback, VideoStreamPlayback)

public:
  bool open(const String &p_path);

  virtual void _stop() override;
  virtual void _play() override;
  virtual bool _is_playing() const override;
  virtual void _set_paused(bool p_paused) override;
  virtual bool _is_paused() const override;
  virtual double _get_length() const override;
  virtual double _get_playback_position() const override;
  virtual void _seek(double p_time) override;
  virtual void _set_audio_track(int32_t p_idx) override;
  virtual Ref<Texture2D> _get_texture() const override;
  virtual void _update(double p_delta) override;
  virtual int32_t _get_channels() const override;
  virtual int32_t _get_mix_rate() const override;

protected:
  template <typename T, typename B>
  static void register_virtuals() {
    VideoStreamPlayback::register_virtuals<T, B>();
  }

private:
  // Core demuxer/decoder
  hap::core::Demuxer demuxer_;
  hap::core::Decoder decoder_;
  hap::core::MmapReader mmap_;

  // Track info
  hap::core::VideoTrackInfo track_;
  std::vector<hap::core::SampleEntry> samples_;

  // Playback state
  bool is_playing_ = false;
  bool is_paused_ = false;
  double current_time_ = 0.0;
  uint32_t current_frame_ = 0;
  double frame_duration_ = 0.0;
  double length_ = 0.0;

  // GPU presenter for RD-based texture upload + compute
  GpuPresenter gpu_presenter_;
  bool gpu_initialized_ = false;

  /// Upload a decoded frame to the GPU.
  void upload_decoded_frame(const hap::core::DecodedFrame &frame);
};

} // namespace godot

#endif // HAP_VIDEO_STREAM_PLAYBACK_H