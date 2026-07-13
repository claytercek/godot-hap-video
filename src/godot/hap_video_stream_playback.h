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
  GDCLASS(HapVideoStreamPlayback, VideoStreamPlayback)

public:
  ~HapVideoStreamPlayback() override {
    alive_->store(false, std::memory_order_release);
  }

  bool open(const String &p_path);

  // -----------------------------------------------------------------
  // Power-user layer (HapPlayer) integration surface. HapPlayer owns
  // this object directly rather than through a VideoStreamPlayer, so
  // the engine never calls the virtuals below automatically; HapPlayer
  // drives them from its own _process() pump instead. No loop, rate,
  // or reverse policy lives here -- HapPlayer decides *when* to call
  // these; this object only decodes/presents the frame it's told to.
  // -----------------------------------------------------------------

  /// Poll for async-open + GPU-init completion, running
  /// initialize_after_open() the first time it's ready. Safe to call
  /// every tick before open completes; a no-op afterward. Returns
  /// is_ready().
  bool poll_ready();

  /// True once metadata and the presented texture are valid (post
  /// async-open + GPU init).
  bool is_ready() const { return playback_initialized_; }

  /// True once the async open or GPU init has failed permanently.
  bool has_failed() const;

  /// Human-readable error, valid once has_failed() is true.
  String get_error() const;

  // Metadata, valid once is_ready() is true.
  double get_frame_rate() const { return track_.frame_rate; }
  int32_t get_width() const { return static_cast<int32_t>(track_.width); }
  int32_t get_height() const { return static_cast<int32_t>(track_.height); }
  int32_t get_frame_count() const {
    return static_cast<int32_t>(track_.frame_count);
  }

  /// Decode and present the frame at `frame_index`, in `forward`
  /// direction. `retarget` must be true on any discontinuity (play
  /// start, scrub, step, loop wrap, direction change) so the
  /// scheduler's prefetch is redirected; false for ordinary
  /// continuous-direction playback, which relies on prefetch already
  /// in flight. A no-op until is_ready().
  void advance_to_frame(uint32_t frame_index, bool forward, bool retarget);

  /// Convert a playback-position time to a frame index, clamped to the
  /// track's valid frame range. Degrades to 0 gracefully before
  /// is_ready() (frame_duration_/track_.frame_count are still their
  /// zero defaults). Shared by both layers: Layer 1's own time-based
  /// _seek()/_update() and HapPlayer's frame-based pump.
  uint32_t frame_from_time(double p_time) const;

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
  static void _bind_methods() {}

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
  /// presenting the first frame found at or after it (or, when
  /// `forward` is false, at or before it). Frames on the wrong side of
  /// the target are stale prefetch and are discarded.
  void present_up_to_frame(uint32_t target_frame, bool forward = true);
};

} // namespace godot

#endif // HAP_VIDEO_STREAM_PLAYBACK_H
