#ifndef HAP_PLAYER_H
#define HAP_PLAYER_H

#include "core/playback_pump.h"
#include "hap_video_stream.h"
#include "hap_video_stream_playback.h"

#include <godot_cpp/classes/control.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>

namespace godot {

/// Power-user layer: a Control node that owns its own playback pump
/// (rate, reverse, loop, frame-stepping) and drives a
/// HapVideoStreamPlayback directly -- not through a VideoStreamPlayer,
/// so the engine never advances the playback on its own. All rate/
/// loop/reverse/step *policy* lives here; the playback stays the dumb
/// position-engine described in its own header, only ever told "decode
/// and present frame X, in this direction."
class HapPlayer : public Control {
  GDCLASS(HapPlayer, Control)

public:
  void set_stream(const Ref<HapVideoStream> &p_stream);
  Ref<HapVideoStream> get_stream() const { return stream_; }

  void set_loop(bool p_loop) { loop_ = p_loop; }
  bool is_loop() const { return loop_; }

  void set_playback_speed(double p_speed) { playback_speed_ = p_speed; }
  double get_playback_speed() const { return playback_speed_; }

  void set_autoplay(bool p_autoplay) { autoplay_ = p_autoplay; }
  bool is_autoplay() const { return autoplay_; }

  void set_stream_position(double p_position);
  double get_stream_position() const { return position_; }

  void set_paused(bool p_paused) { paused_ = p_paused; }
  bool is_paused() const { return paused_; }

  /// Start (or resume) playback from the current stream_position, in
  /// the direction implied by playback_speed's sign. Does not reset
  /// position -- resuming after pause/completion continues from where
  /// playback left off.
  void play();
  /// Freeze the pump in place; texture and stream_position are
  /// retained. Equivalent to set_paused(true).
  void pause();
  /// Halt playback and reset stream_position to 0.
  void stop();
  /// Pause-gated: auto-pauses if playing, then moves exactly n frames
  /// (n may be negative) via a priority seek.
  void step_frame(int32_t n);

  Ref<Texture2D> get_texture() const;

  // Read-only metadata, valid after the `opened` signal.
  double get_frame_rate() const;
  int32_t get_width() const;
  int32_t get_height() const;
  double get_duration() const;
  int32_t get_frame_count() const;

  virtual void _ready() override;
  virtual void _process(double p_delta) override;

protected:
  static void _bind_methods();

private:
  Ref<HapVideoStream> stream_;
  Ref<HapVideoStreamPlayback> playback_;

  bool loop_ = false;
  bool autoplay_ = false;
  double playback_speed_ = 1.0;

  // True between play() and stop(); paused_ additionally gates whether
  // the pump is actively advancing (mirrors VideoStreamPlayer's
  // play/pause-without-stop contract). Not exposed -- only `paused` is
  // public API, per spec.
  bool active_ = false;
  bool paused_ = false;

  // The pump's own authoritative position, in seconds. Decoupled from
  // HapVideoStreamPlayback's internal current_time_, which only the
  // drop-in (Layer 1) path uses.
  double position_ = 0.0;

  bool error_fired_ = false;

  // True when the next advance_to_frame() call must retarget the
  // scheduler's prefetch: set on any discontinuity (stream (re)opened,
  // play(), stop(), scrub, step, loop wrap, direction reversal).
  bool needs_retarget_ = true;
  bool last_direction_forward_ = true;

  /// Present `frame`, always retargeting the scheduler's prefetch, and
  /// update the direction/retarget bookkeeping to match -- the shared
  /// tail of every discontinuity (scrub, stop, step, initial present).
  /// Steady-state playback in _process() calls advance_to_frame()
  /// directly since its retarget flag varies.
  void present_at(uint32_t frame, bool forward);
};

} // namespace godot

#endif // HAP_PLAYER_H
