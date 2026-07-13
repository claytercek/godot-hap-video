#include "playback_pump.h"

#include <cmath>

namespace hap {
namespace core {

PumpStepResult pump_step(double position, double delta, double playback_speed,
                         bool loop, double duration, bool needs_retarget,
                         bool last_direction_forward) {
  bool forward = playback_speed >= 0.0;
  double speed = forward ? playback_speed : -playback_speed;

  double new_position = position + (forward ? speed : -speed) * delta;

  PumpStepResult result;
  result.forward = forward;
  result.retarget = needs_retarget || forward != last_direction_forward;

  if (forward && new_position >= duration) {
    if (loop && duration > 0.0) {
      new_position = std::fmod(new_position, duration);
      result.looped = true;
      result.retarget = true;
    } else {
      new_position = duration;
      result.completed = true;
    }
  } else if (!forward && new_position <= 0.0) {
    if (loop && duration > 0.0) {
      new_position = duration - std::fmod(-new_position, duration);
      result.looped = true;
      result.retarget = true;
    } else {
      new_position = 0.0;
      result.completed = true;
    }
  }

  result.position = new_position;
  return result;
}

} // namespace core
} // namespace hap
