#ifndef HAP_CORE_PLAYBACK_PUMP_H
#define HAP_CORE_PLAYBACK_PUMP_H

namespace hap {
namespace core {

/// Result of advancing the power-user pump by one tick.
struct PumpStepResult {
  double position = 0.0;
  bool forward = true;

  /// True if the caller must redirect the decode scheduler's prefetch
  /// this tick (any discontinuity: direction flip or a loop wrap).
  bool retarget = false;

  bool looped = false;
  bool completed = false;
};

/// Pure position-advance logic for HapPlayer's playback pump: rate,
/// reverse, and loop policy, decoupled from Godot/decode-scheduler
/// specifics so it's headless-testable. HapPlayer wraps this with the
/// actual frame conversion, scheduler retargeting, and signal
/// emission -- this function has no side effects and no I/O.
///
/// `playback_speed`'s sign selects direction (negative = reverse);
/// its magnitude scales `delta`. `needs_retarget` is true when the
/// caller already knows this tick is a discontinuity (e.g. right
/// after play()); the result ORs that in with a direction flip or a
/// loop wrap detected here.
PumpStepResult pump_step(double position, double delta, double playback_speed,
                         bool loop, double duration, bool needs_retarget,
                         bool last_direction_forward);

} // namespace core
} // namespace hap

#endif // HAP_CORE_PLAYBACK_PUMP_H
