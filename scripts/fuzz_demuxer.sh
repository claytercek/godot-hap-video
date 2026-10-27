#!/usr/bin/env bash
# Fuzz Demuxer.open() (src/core/demuxer_fuzz.zig) locally, outside CI.
# The core test binary also runs decoder.decode()'s bounded loop
# (src/core/hap_decode_fuzz.zig), each for HAP_FUZZ_SECONDS.
#
# Usage: scripts/fuzz_demuxer.sh [seconds]
#
# Try coverage-guided fuzzing (`zig build test --fuzz=<limit>`) first.
# On Zig 0.17.0 it fails to link: -ffuzz instruments minimp4.c and snappy.cc
# with Clang's -fsanitize-coverage=trace-cmp calls
# (__sanitizer_cov_trace_cmp*/_switch/_const_cmp*), but Zig's fuzzer runtime
# lacks that ABI. Pure-Zig fuzzing links and runs. Keep this attempt so the
# script uses it when the incompatibility is resolved. See
# src/core/demuxer_fuzz.zig for details.
#
# On failure, run the test binary's "bounded randomized fuzz" test with
# HAP_FUZZ_SECONDS. This fallback sends random malformed input to Demuxer.open()
# without coverage feedback.
#
# Zig 0.16's std.testing.fuzz has no on-disk corpus: FuzzInputOptions.corpus
# is an in-binary list, and --fuzz keeps its corpus in memory for one run.
# Failures print a panic/stack trace to stderr; they write no crash-<hash>
# files. Nothing persists across runs except this script's log under the
# gitignored .zig-cache/fuzz-logs/. The log is not a corpus or crash artifact.
# Copy failing bytes into tests/fixtures/fuzz_regressions/ and add a replay
# in fuzz_regressions_test.zig.
set -euo pipefail
cd "$(dirname "$0")/.."

DURATION="${1:-120}"
LOG_DIR=".zig-cache/fuzz-logs"
LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"

# Approximate the duration with --fuzz's run-count limit (-Dfuzz=<N>).
# This does not change the fallback's HAP_FUZZ_SECONDS time bound.
FUZZ_LIMIT=$((DURATION * 20000))

echo "Attempting zig's coverage-guided fuzzer (zig build test --fuzz=${FUZZ_LIMIT}) ..." | tee "$LOG_FILE"
if zig build test -Dtest-optimize=fast "--fuzz=${FUZZ_LIMIT}" 2>&1 | tee -a "$LOG_FILE"; then
  echo "Coverage-guided run completed cleanly." | tee -a "$LOG_FILE"
  exit 0
fi

cat <<'EOF' | tee -a "$LOG_FILE"

Coverage-guided --fuzz failed to build/run (expected on zig 0.17.0 for this
project -- see this script's header comment). Falling back to the bounded
random-input loop.
EOF

echo "Running HAP_FUZZ_SECONDS=${DURATION} zig build test ..." | tee -a "$LOG_FILE"
HAP_FUZZ_SECONDS="$DURATION" zig build test -Dtest-optimize=fast --summary all 2>&1 | tee -a "$LOG_FILE"

echo "Done. Log: $LOG_FILE"
echo "Any crash/leak/hang above: copy the offending bytes into tests/fixtures/fuzz_regressions/ and add coverage in fuzz_regressions_test.zig (Demuxer.open) or hap_decode_fuzz.zig's decoder replay test (decoder.decode), whichever path found it."
