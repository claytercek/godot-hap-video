/*
 * HapPlayer's pump logic (rate/reverse/loop policy) is pure math with no
 * Godot or decode-scheduler dependency, factored out specifically so it
 * can be verified headless -- the Godot node itself can only be
 * exercised end-to-end with a live RenderingDevice, which this suite
 * doesn't have.
 */

#include "core/playback_pump.h"

#include "test.h"

#include <cmath>

using namespace hap::core;

namespace {
bool near(double a, double b, double eps = 1e-9) { return std::fabs(a - b) < eps; }
} // namespace

HAP_TEST(pump_step_forward_advances_position) {
  PumpStepResult r = pump_step(1.0, 0.1, 1.0, /*loop=*/false, /*duration=*/10.0,
                               /*needs_retarget=*/false,
                               /*last_direction_forward=*/true);
  HAP_ASSERT(near(r.position, 1.1));
  HAP_ASSERT(r.forward);
  HAP_ASSERT(!r.retarget);
  HAP_ASSERT(!r.looped);
  HAP_ASSERT(!r.completed);
}

HAP_TEST(pump_step_reverse_advances_position_backward) {
  PumpStepResult r = pump_step(5.0, 0.1, -1.0, /*loop=*/false, /*duration=*/10.0,
                               /*needs_retarget=*/false,
                               /*last_direction_forward=*/false);
  HAP_ASSERT(near(r.position, 4.9));
  HAP_ASSERT(!r.forward);
  HAP_ASSERT(!r.retarget);
  HAP_ASSERT(!r.looped);
  HAP_ASSERT(!r.completed);
}

HAP_TEST(pump_step_speed_magnitude_scales_delta_forward) {
  PumpStepResult r = pump_step(0.0, 1.0, 2.0, false, 100.0, false, true);
  HAP_ASSERT(near(r.position, 2.0));
}

HAP_TEST(pump_step_speed_magnitude_scales_delta_reverse) {
  PumpStepResult r = pump_step(5.0, 1.0, -0.5, false, 100.0, false, false);
  HAP_ASSERT(near(r.position, 4.5));
}

HAP_TEST(pump_step_forward_completes_at_duration_without_loop) {
  PumpStepResult r = pump_step(1.9, 0.5, 1.0, /*loop=*/false, /*duration=*/2.0,
                               false, true);
  HAP_ASSERT(near(r.position, 2.0));
  HAP_ASSERT(r.completed);
  HAP_ASSERT(!r.looped);
}

HAP_TEST(pump_step_reverse_completes_at_zero_without_loop) {
  PumpStepResult r = pump_step(0.1, 0.5, -1.0, /*loop=*/false, /*duration=*/2.0,
                               false, false);
  HAP_ASSERT(near(r.position, 0.0));
  HAP_ASSERT(r.completed);
  HAP_ASSERT(!r.looped);
}

HAP_TEST(pump_step_forward_loop_wraps_preserving_overshoot) {
  // 1.9 + 0.2 = 2.1, overshoots a 2.0s duration by 0.1s -- looping must
  // carry that overshoot into the new position, not just snap to 0.
  PumpStepResult r = pump_step(1.9, 0.2, 1.0, /*loop=*/true, /*duration=*/2.0,
                               false, true);
  HAP_ASSERT(near(r.position, 0.1));
  HAP_ASSERT(r.looped);
  HAP_ASSERT(!r.completed);
  HAP_ASSERT(r.retarget);
}

HAP_TEST(pump_step_reverse_loop_wraps_to_duration_preserving_overshoot) {
  // 0.05 - 0.2 = -0.15 undershoots 0 by 0.15s -- looping backward must
  // wrap to duration minus that overshoot.
  PumpStepResult r = pump_step(0.05, 0.2, -1.0, /*loop=*/true, /*duration=*/2.0,
                               false, false);
  HAP_ASSERT(near(r.position, 1.85));
  HAP_ASSERT(r.looped);
  HAP_ASSERT(!r.completed);
  HAP_ASSERT(r.retarget);
}

HAP_TEST(pump_step_direction_flip_forces_retarget_even_without_flag) {
  PumpStepResult r = pump_step(5.0, 0.1, -1.0, false, 10.0,
                               /*needs_retarget=*/false,
                               /*last_direction_forward=*/true);
  HAP_ASSERT(r.retarget);
}

HAP_TEST(pump_step_same_direction_does_not_force_retarget) {
  PumpStepResult r = pump_step(5.0, 0.1, 1.0, false, 10.0,
                               /*needs_retarget=*/false,
                               /*last_direction_forward=*/true);
  HAP_ASSERT(!r.retarget);
}

HAP_TEST(pump_step_needs_retarget_flag_propagates) {
  PumpStepResult r = pump_step(5.0, 0.1, 1.0, false, 10.0,
                               /*needs_retarget=*/true,
                               /*last_direction_forward=*/true);
  HAP_ASSERT(r.retarget);
}

HAP_TEST(pump_step_zero_duration_completes_immediately_even_with_loop) {
  // A zero-length stream can't meaningfully loop; must complete cleanly
  // rather than divide by zero (fmod by 0.0) or hang.
  PumpStepResult r = pump_step(0.0, 0.1, 1.0, /*loop=*/true, /*duration=*/0.0,
                               false, true);
  HAP_ASSERT(near(r.position, 0.0));
  HAP_ASSERT(r.completed);
  HAP_ASSERT(!r.looped);
}

int main() { return hap::test::run_all(); }
