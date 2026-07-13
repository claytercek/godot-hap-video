#!/usr/bin/env bash
# Run one or more built core test binaries from build/tests/.
#
# Used by CI (.github/workflows/build.yml, .github/workflows/sanitizers.yml)
# so the plain, ASan+UBSan, and TSan jobs share one place that runs the
# binaries instead of three near-identical lists of steps. Sanitizer options
# (ASAN_OPTIONS, TSAN_OPTIONS, ...) are set by the caller's step `env:` and
# pass straight through to each binary. TSan only exercises a subset of
# tests (concurrency/scheduler focus) -- that's expressed by which test
# names the caller passes, not by anything in this script.
#
# Usage: scripts/run_core_tests.sh <test-name> [test-name...]
#   test-name is a binary under build/tests/, e.g. test_demuxer

set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <test-name> [test-name...]" >&2
  exit 1
fi

for name in "$@"; do
  echo "::group::Running $name"
  "build/tests/${name}"
  echo "::endgroup::"
done
