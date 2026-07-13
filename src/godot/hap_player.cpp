#include "hap_player.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>

namespace godot {

void HapPlayer::_bind_methods() {
  ClassDB::bind_method(D_METHOD("set_stream", "stream"), &HapPlayer::set_stream);
  ClassDB::bind_method(D_METHOD("get_stream"), &HapPlayer::get_stream);

  ClassDB::bind_method(D_METHOD("set_loop", "loop"), &HapPlayer::set_loop);
  ClassDB::bind_method(D_METHOD("is_loop"), &HapPlayer::is_loop);

  ClassDB::bind_method(D_METHOD("set_playback_speed", "speed"),
                       &HapPlayer::set_playback_speed);
  ClassDB::bind_method(D_METHOD("get_playback_speed"),
                       &HapPlayer::get_playback_speed);

  ClassDB::bind_method(D_METHOD("set_autoplay", "autoplay"),
                       &HapPlayer::set_autoplay);
  ClassDB::bind_method(D_METHOD("is_autoplay"), &HapPlayer::is_autoplay);

  ClassDB::bind_method(D_METHOD("set_stream_position", "position"),
                       &HapPlayer::set_stream_position);
  ClassDB::bind_method(D_METHOD("get_stream_position"),
                       &HapPlayer::get_stream_position);

  ClassDB::bind_method(D_METHOD("set_paused", "paused"), &HapPlayer::set_paused);
  ClassDB::bind_method(D_METHOD("is_paused"), &HapPlayer::is_paused);

  ClassDB::bind_method(D_METHOD("play"), &HapPlayer::play);
  ClassDB::bind_method(D_METHOD("pause"), &HapPlayer::pause);
  ClassDB::bind_method(D_METHOD("stop"), &HapPlayer::stop);
  ClassDB::bind_method(D_METHOD("step_frame", "n"), &HapPlayer::step_frame);

  ClassDB::bind_method(D_METHOD("get_texture"), &HapPlayer::get_texture);

  ClassDB::bind_method(D_METHOD("get_frame_rate"), &HapPlayer::get_frame_rate);
  ClassDB::bind_method(D_METHOD("get_width"), &HapPlayer::get_width);
  ClassDB::bind_method(D_METHOD("get_height"), &HapPlayer::get_height);
  ClassDB::bind_method(D_METHOD("get_duration"), &HapPlayer::get_duration);
  ClassDB::bind_method(D_METHOD("get_frame_count"), &HapPlayer::get_frame_count);

  ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "stream", PROPERTY_HINT_RESOURCE_TYPE,
                            "HapVideoStream"),
               "set_stream", "get_stream");
  ADD_PROPERTY(PropertyInfo(Variant::BOOL, "loop"), "set_loop", "is_loop");
  ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "playback_speed"),
               "set_playback_speed", "get_playback_speed");
  ADD_PROPERTY(PropertyInfo(Variant::BOOL, "autoplay"), "set_autoplay",
               "is_autoplay");
  ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "stream_position"),
               "set_stream_position", "get_stream_position");
  ADD_PROPERTY(PropertyInfo(Variant::BOOL, "paused"), "set_paused", "is_paused");

  // Read-only metadata, valid after `opened` -- no setter, so scripts
  // read them as plain properties (player.frame_rate, not
  // player.get_frame_rate()) via dot access, matching the spec's
  // property list.
  ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "frame_rate", PROPERTY_HINT_NONE, "",
                            PROPERTY_USAGE_READ_ONLY),
               "", "get_frame_rate");
  ADD_PROPERTY(PropertyInfo(Variant::INT, "width", PROPERTY_HINT_NONE, "",
                            PROPERTY_USAGE_READ_ONLY),
               "", "get_width");
  ADD_PROPERTY(PropertyInfo(Variant::INT, "height", PROPERTY_HINT_NONE, "",
                            PROPERTY_USAGE_READ_ONLY),
               "", "get_height");
  ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "duration", PROPERTY_HINT_NONE, "",
                            PROPERTY_USAGE_READ_ONLY),
               "", "get_duration");
  ADD_PROPERTY(PropertyInfo(Variant::INT, "frame_count", PROPERTY_HINT_NONE, "",
                            PROPERTY_USAGE_READ_ONLY),
               "", "get_frame_count");

  ADD_SIGNAL(MethodInfo("opened"));
  ADD_SIGNAL(MethodInfo("playback_completed"));
  ADD_SIGNAL(MethodInfo("playback_looped"));
  ADD_SIGNAL(MethodInfo("error_occurred", PropertyInfo(Variant::STRING, "message")));
}

void HapPlayer::set_stream(const Ref<HapVideoStream> &p_stream) {
  stream_ = p_stream;
  playback_.unref();

  error_fired_ = false;
  active_ = false;
  paused_ = false;
  position_ = 0.0;
  needs_retarget_ = true;
  last_direction_forward_ = true;

  if (stream_.is_null())
    return;

  Ref<HapVideoStreamPlayback> pb;
  pb.instantiate();
  if (!pb->open(stream_->get_file())) {
    ERR_PRINT("HapPlayer: failed to open stream: " + stream_->get_file());
    return;
  }
  playback_ = pb;
}

void HapPlayer::set_stream_position(double p_position) {
  if (p_position < 0.0)
    p_position = 0.0;

  if (playback_.is_valid() && playback_->is_ready()) {
    double duration = playback_->_get_length();
    if (p_position > duration)
      p_position = duration;
  }

  position_ = p_position;
  needs_retarget_ = true;

  if (playback_.is_valid() && playback_->is_ready()) {
    bool forward = playback_speed_ >= 0.0;
    playback_->advance_to_frame(frame_from_position(position_), forward, true);
    last_direction_forward_ = forward;
    needs_retarget_ = false;
  }
}

void HapPlayer::play() {
  active_ = true;
  paused_ = false;
  needs_retarget_ = true;
}

void HapPlayer::pause() { paused_ = true; }

void HapPlayer::stop() {
  active_ = false;
  paused_ = false;
  position_ = 0.0;
  needs_retarget_ = true;
  last_direction_forward_ = true;

  if (playback_.is_valid() && playback_->is_ready()) {
    playback_->advance_to_frame(0, /*forward=*/true, /*retarget=*/true);
    needs_retarget_ = false;
  }
}

void HapPlayer::step_frame(int32_t n) {
  if (playback_.is_null() || !playback_->is_ready())
    return;

  // Pause-gated: auto-pause if currently advancing, then step exactly
  // n frames via a priority seek.
  if (active_ && !paused_)
    paused_ = true;

  int32_t frame_count = playback_->get_frame_count();
  int32_t current_frame = static_cast<int32_t>(frame_from_position(position_));
  int32_t target = current_frame + n;
  if (target < 0)
    target = 0;
  if (frame_count > 0 && target >= frame_count)
    target = frame_count - 1;

  bool forward = n >= 0;
  double frame_rate = playback_->get_frame_rate();
  position_ = frame_rate > 0.0 ? target / frame_rate : 0.0;

  playback_->advance_to_frame(static_cast<uint32_t>(target), forward, true);
  last_direction_forward_ = forward;
  needs_retarget_ = false;
}

Ref<Texture2D> HapPlayer::get_texture() const {
  if (playback_.is_null())
    return Ref<Texture2D>();
  return playback_->_get_texture();
}

double HapPlayer::get_frame_rate() const {
  return playback_.is_valid() ? playback_->get_frame_rate() : 0.0;
}

int32_t HapPlayer::get_width() const {
  return playback_.is_valid() ? playback_->get_width() : 0;
}

int32_t HapPlayer::get_height() const {
  return playback_.is_valid() ? playback_->get_height() : 0;
}

double HapPlayer::get_duration() const {
  return playback_.is_valid() ? playback_->_get_length() : 0.0;
}

int32_t HapPlayer::get_frame_count() const {
  return playback_.is_valid() ? playback_->get_frame_count() : 0;
}

uint32_t HapPlayer::frame_from_position(double p_position) const {
  if (playback_.is_null() || !playback_->is_ready())
    return 0;

  double frame_rate = playback_->get_frame_rate();
  int32_t frame_count = playback_->get_frame_count();
  uint32_t frame =
      frame_rate > 0.0 ? static_cast<uint32_t>(p_position * frame_rate) : 0;
  if (frame_count > 0 && frame >= static_cast<uint32_t>(frame_count))
    frame = static_cast<uint32_t>(frame_count) - 1;
  return frame;
}

void HapPlayer::_ready() { set_process(true); }

void HapPlayer::_process(double p_delta) {
  if (playback_.is_null())
    return;

  bool was_ready = playback_->is_ready();
  bool now_ready = playback_->poll_ready();

  if (now_ready && !was_ready) {
    // Materialize the current (possibly pre-set) position's frame
    // immediately, so get_texture() is valid the instant `opened`
    // fires -- before any handler calls play().
    bool forward = playback_speed_ >= 0.0;
    playback_->advance_to_frame(frame_from_position(position_), forward, true);
    last_direction_forward_ = forward;
    needs_retarget_ = false;

    emit_signal("opened");
    if (autoplay_)
      play();
  }

  if (playback_->has_failed()) {
    if (!error_fired_) {
      error_fired_ = true;
      emit_signal("error_occurred", playback_->get_error());
    }
    return;
  }

  if (!now_ready || !active_ || paused_)
    return;

  hap::core::PumpStepResult step = hap::core::pump_step(
      position_, p_delta, playback_speed_, loop_, playback_->_get_length(),
      needs_retarget_, last_direction_forward_);

  position_ = step.position;
  needs_retarget_ = false;
  last_direction_forward_ = step.forward;
  if (step.completed)
    active_ = false;

  playback_->advance_to_frame(frame_from_position(position_), step.forward,
                              step.retarget);

  if (step.looped)
    emit_signal("playback_looped");
  if (step.completed)
    emit_signal("playback_completed");
}

} // namespace godot
