#!/bin/bash
# Generate Hap video test fixtures.
#
# Requires ffmpeg built with --enable-libsnappy for Hap encoding support.
# The standard brew ffmpeg doesn't include this; you may need to build
# ffmpeg from source or use a custom build.
#
# Usage: ./scripts/generate_fixtures.sh [output_dir]
# Default output directory: tests/fixtures/

set -euo pipefail

OUTDIR="${1:-tests/fixtures}"
mkdir -p "$OUTDIR"

WIDTH=640
HEIGHT=360
FPS=30
DURATION=4

# Check if hap encoder is available
if ! ffmpeg -encoders 2>/dev/null | grep -q hap; then
  echo "ERROR: Hap encoder not available in ffmpeg."
  echo "Rebuild ffmpeg with --enable-libsnappy or use a custom build."
  echo "See: https://github.com/Vidvox/hap-ffmpeg"
  echo ""
  echo "To build ffmpeg with hap support:"
  echo "  brew install snappy"
  echo "  git clone https://github.com/FFmpeg/FFmpeg.git"
  echo "  cd FFmpeg && ./configure --enable-libsnappy && make"
  exit 1
fi

SOURCE_OPTS="-f lavfi -i testsrc2=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION}"

echo "Generating hap1 fixture..."
ffmpeg -y $SOURCE_OPTS -c:v hap -format hap -compressor snappy -chunks 1 "$OUTDIR/hap1.mov"

echo "Generating hap5 fixture..."
ffmpeg -y $SOURCE_OPTS -c:v hap -format hap_alpha -compressor snappy -chunks 1 "$OUTDIR/hap5.mov"

echo "Generating hapy fixture..."
ffmpeg -y $SOURCE_OPTS -c:v hap -format hap_q -compressor snappy -chunks 1 "$OUTDIR/hapy.mov"

echo "Generating hap1_chunked fixture (4 chunks)..."
ffmpeg -y $SOURCE_OPTS -c:v hap -format hap -compressor snappy -chunks 4 "$OUTDIR/hap1_chunked.mov"

echo "Generating hapy_chunked fixture (4 chunks)..."
ffmpeg -y $SOURCE_OPTS -c:v hap -format hap_q -compressor snappy -chunks 4 "$OUTDIR/hapy_chunked.mov"

echo "Generating hap5_chunked fixture (4 chunks)..."
ffmpeg -y $SOURCE_OPTS -c:v hap -format hap_alpha -compressor snappy -chunks 4 "$OUTDIR/hap5_chunked.mov"

echo "Generating hap1_audio fixture..."
ffmpeg -y -f lavfi -i testsrc2=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION} \
  -f lavfi -i sine=frequency=440:duration=${DURATION} \
  -c:v hap -format hap -compressor snappy -chunks 1 -c:a pcm_s16le \
  "$OUTDIR/hap1_audio.mov"

echo "Extracting golden reference frames..."
ffmpeg -y -i "$OUTDIR/hap1.mov" -vframes 1 "$OUTDIR/hap1_frame0.png"
ffmpeg -y -i "$OUTDIR/hap5.mov" -vframes 1 "$OUTDIR/hap5_frame0.png"
ffmpeg -y -i "$OUTDIR/hapy.mov" -vframes 1 "$OUTDIR/hapy_frame0.png"

echo "Generating hap7 fixture (Hap R / BC7)..."
# Hap7 cannot be encoded by ffmpeg; a Python script writes a valid MOV with
# a Hap7 stsd entry and a real Hap7 frame. See tests/fixtures/README.md.
if command -v python3 >/dev/null 2>&1; then
  python3 "$(dirname "$0")/generate_hap7_fixture.py" "$OUTDIR/hap7.mov" "$WIDTH" "$HEIGHT"
else
  # Unlike the missing-ffmpeg check above, this is a warning, not a hard
  # exit: Hap7 is best-effort (ffmpeg can't encode it at all, so this is
  # already the fallback path), and every other fixture format has already
  # been generated successfully by this point.
  echo "WARNING: python3 not found; skipping hap7.mov generation."
  echo "Run scripts/generate_hap7_fixture.py manually."
fi

echo "Done. Fixtures in: $OUTDIR"
