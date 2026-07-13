#!/usr/bin/env bash
# Bounded-time local libFuzzer run against the demuxer open/parse path.
#
# Usage: scripts/fuzz_demuxer.sh [seconds]
#
# Not run in CI (per-push live fuzzing is out of scope by design); this is
# local discipline. Crash artifacts land in tests/fuzz/crashes/ — triage
# real findings by copying the input into tests/fixtures/fuzz_crashes/ and
# adding a case to tests/core/test_fuzz_regressions.cpp.
set -euo pipefail
cd "$(dirname "$0")/.."

DURATION="${1:-120}"
CORPUS_DIR="tests/fuzz/corpus"
CRASH_DIR="tests/fuzz/crashes"

mkdir -p "$CORPUS_DIR" "$CRASH_DIR"
cp -n tests/fixtures/*.mov "$CORPUS_DIR/" 2>/dev/null || true

SCONS_ARGS=(fuzz=1 target=template_debug)

case "$(uname)" in
  Linux)
    SCONS_ARGS+=(use_llvm=yes)
    ;;
  Darwin)
    # Apple's Xcode clang doesn't ship the libFuzzer runtime; point at a
    # Homebrew LLVM clang if one is installed.
    LLVM_PREFIX=""
    for candidate in /opt/homebrew/opt/llvm@* /opt/homebrew/opt/llvm /usr/local/opt/llvm@* /usr/local/opt/llvm; do
      if [[ -x "$candidate/bin/clang++" ]]; then
        LLVM_PREFIX="$candidate"
        break
      fi
    done
    if [[ -n "$LLVM_PREFIX" ]]; then
      SCONS_ARGS+=(CC="$LLVM_PREFIX/bin/clang" CXX="$LLVM_PREFIX/bin/clang++")
    else
      echo "warning: no Homebrew LLVM found (brew install llvm) — libFuzzer needs its runtime, which Xcode's clang doesn't ship" >&2
    fi
    ;;
esac

scons "${SCONS_ARGS[@]}"

echo "Fuzzing tests/fuzz/fuzz_demuxer for ${DURATION}s against $CORPUS_DIR ..."
./build/fuzz/fuzz_demuxer \
  -max_total_time="$DURATION" \
  -artifact_prefix="$CRASH_DIR/" \
  "$CORPUS_DIR"

echo "Done. Inspect any crash-/leak-/timeout-* files under $CRASH_DIR."
