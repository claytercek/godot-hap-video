#ifndef HAP_VIDEO_STREAM_PLAYBACK_H
#define HAP_VIDEO_STREAM_PLAYBACK_H

#include "gpu_presenter.h"
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/classes/video_stream_playback.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include "core/decode_scheduler.h"
#include "core/hap_frame.h"

#include <atomic>
#include <memory>
#include <string>

namespace godot {

/// Position-engine playback: owns the async decode pipeline
/// (DecodeScheduler: mmap, demux, decode, SPSC frame queue) and the GPU
/// present pipeline (GpuPresenter: RD textures + compute + ring +
/// Texture2DRD). No loop, rate, or reverse logic lives here — that's
/// the power-user layer's job; this decodes the frame at position X.
///
/// open() kicks off an asynchronous open on the shared outer pool and
/// returns immediately; nothing here blocks the main thread. Until the
/// async open completes, playback virtuals report harmless defaults.
class HapVideoStreamPlayback : public VideoStreamPlayback {
  GDEXTENSION_CLASS(HapVideoStreamPlayback, VideoStreamPlayback)

public:
  ~HapVideoStreamPlayback() override {
    alive_->store(false, std::memory_order_release);
  }

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
  // Async decode pipeline (Godot-free core).
  hap::core::DecodeScheduler scheduler_;

  // Track info, valid once open_ready_ becomes true.
  hap::core::VideoTrackInfo track_;
  std::atomic<bool> open_ready_{false};
  std::atomic<bool> open_failed_{false};
  std::string open_error_;
  bool open_error_logged_ = false;

  // Guards the open_async() completion callback against firing after
  // this object has been destroyed (the callback runs on an outer-pool
  // worker thread and outlives no particular object lifetime).
  std::shared_ptr<std::atomic<bool>> alive_ =
      std::make_shared<std::atomic<bool>>(true);

  // Playback state
  bool is_playing_ = false;
  bool is_paused_ = false;
  double current_time_ = 0.0;
  uint32_t current_frame_ = 0;
  double frame_duration_ = 0.0;
  double length_ = 0.0;

  // Becomes true once track_ has been captured and GPU resources
  // created for it (happens on the first _update() after open_ready_).
  bool playback_initialized_ = false;
  bool gpu_init_failed_ = false;

  // GPU presenter for RD-based texture upload + compute
  GpuPresenter gpu_presenter_;

  /// One-time setup once the async open has completed: captures
  /// metadata, computes duration, and initializes GPU resources.
  void initialize_after_open();

  /// Drain the frame queue up to (and including) `target_frame`,
  /// presenting the first frame found at or after it. Frames behind
  /// the target are stale prefetch and are discarded.
  void present_up_to_frame(uint32_t target_frame);
};

} // namespace godot

#endif // HAP_VIDEO_STREAM_PLAYBACK_H
