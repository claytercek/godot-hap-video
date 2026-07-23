#!/usr/bin/env bash
# Bounded-time local fuzz run against the Demuxer.open() path
# (src/core/demuxer_fuzz.zig).
#
# Usage: scripts/fuzz_demuxer.sh [seconds]
#
# Not run in CI (per-push live fuzzing is out of scope by design); this is
# local discipline.
#
# Two fuzzing paths, tried in order:
#
#   1. zig's own coverage-guided engine (`zig build test --fuzz=<limit>`).
#      As of zig 0.16.0 this does NOT link for this project: `-ffuzz`
#      instruments the vendored C sources (hap.c, minimp4.c, snappy.cc)
#      with clang's classic `-fsanitize-coverage=trace-cmp` calls
#      (__sanitizer_cov_trace_cmp*/_switch/_const_cmp*), and zig's
#      from-scratch fuzzer runtime doesn't implement that ABI -- only the
#      pure-Zig coverage path does (verified locally with a minimal
#      C-source-free repro, which links and fuzzes fine). This step is
#      kept first anyway so the script starts using it automatically the
#      day either zig or this project's C dependency drops out of the
#      picture; see src/core/demuxer_fuzz.zig's module doc comment for the
#      full writeup.
#
#   2. A bounded random-input loop inside the test binary itself, gated by
#      HAP_FUZZ_SECONDS (src/core/demuxer_fuzz.zig's
#      "bounded randomized fuzz" test). This is what actually runs today.
#      It's "dumb" (uncoverage-guided) fuzzing -- no feedback loop steering
#      generation toward new coverage -- but still throws a large volume
#      of random malformed input at Demuxer.open() per run.
#
# No corpus directory: zig 0.16's `std.testing.fuzz` has no on-disk corpus
# concept (`FuzzInputOptions.corpus` is a fixed in-binary list -- see
# demuxer_fuzz.zig -- and a coverage-guided `--fuzz` run keeps its corpus
# in memory for the life of that single invocation, with no artifact
# directory à la libFuzzer's corpus/ or crash-*). There is therefore
# nothing to persist across runs and no directory to gitignore here.
#
# No crash artifacts either: on a failure, the child process prints the
# panic/stack trace to stderr and exits -- there is no libFuzzer-style
# `crash-<hash>` file written to disk. This script tees output to a log
# under .zig-cache/ (already gitignored) purely so a long run's output
# survives scrollback; it is not a corpus or artifact store. Triage a real
# finding by copying the offending bytes into
# tests/fixtures/fuzz_regressions/ and letting fuzz_regressions_test.zig
# replay it forever after.
set -euo pipefail
cd "$(dirname "$0")/.."

DURATION="${1:-120}"
LOG_DIR=".zig-cache/fuzz-logs"
LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"

# Rough iteration-count stand-in for a time limit: --fuzz's -Dfuzz=<N> is a
# run-count limit, not a wall-clock one. This is only reached if step 1
# above ever starts working; it does not affect step 2's HAP_FUZZ_SECONDS
# bound.
FUZZ_LIMIT=$((DURATION * 20000))

echo "Attempting zig's coverage-guided fuzzer (zig build test --fuzz=${FUZZ_LIMIT}) ..." | tee "$LOG_FILE"
if zig build test -Dtest-optimize=ReleaseFast "--fuzz=${FUZZ_LIMIT}" 2>&1 | tee -a "$LOG_FILE"; then
  echo "Coverage-guided run completed cleanly." | tee -a "$LOG_FILE"
  exit 0
fi

cat <<'EOF' | tee -a "$LOG_FILE"

Coverage-guided --fuzz failed to build/run (expected on zig 0.16.0 for this
project -- see this script's header comment). Falling back to the bounded
random-input loop.
EOF

echo "Running HAP_FUZZ_SECONDS=${DURATION} zig build test ..." | tee -a "$LOG_FILE"
HAP_FUZZ_SECONDS="$DURATION" zig build test -Dtest-optimize=ReleaseFast --summary all 2>&1 | tee -a "$LOG_FILE"

echo "Done. Log: $LOG_FILE"
echo "Any crash/leak/hang above: copy the offending bytes into tests/fixtures/fuzz_regressions/ and add coverage in fuzz_regressions_test.zig."
