# Hap test fixtures

Run `git lfs pull` from the repository root to fetch the MOVs, reference
frames, and binary regression inputs. Tests and benchmarks read these files
directly. The demo's `project/hap1.mov` uses the same LFS object as `hap1.mov`.

## Video

All clips are 640×360 at 30 fps. `hap1.mov` (BC1), `hap5.mov` (BC3 with
alpha), and `hapy.mov` (YCoCg BC3) contain two seconds of FFmpeg test video
with Snappy compression. Each has a four-chunk `*_chunked.mov` counterpart.
Frame zero must decode to identical bytes in both files. The `*_frame0.png`
stills are for visual inspection; `hap1_golden.bin` is the byte-exact BC1
reference used by the decoder tests.

`hap7.mov` and `hapm.mov` each contain one synthetic frame with uncompressed
Hap sections. Hap7 exercises BC7 block pass-through and dimension lookup from
the MOV sample description. HapM carries two independent textures in a
Multi-Image section. `hapm_golden_tex0.bin` is its YCoCg BC3 color plane;
`hapm_golden_tex1.bin` is its BC4 alpha plane. Update a clip and its reference
bytes together.

## Audio

| File | PCM track |
| --- | --- |
| `hap1_audio.mov` | Mono 16-bit little-endian, 44.1 kHz |
| `hap1_pcm16be_stereo.mov` | Stereo 16-bit big-endian (`twos`), 48 kHz |
| `hap1_pcm24be_stereo.mov` | Stereo packed 24-bit big-endian (`in24`), 48 kHz |

The stereo clips share the mono clip's compressed video samples. Their tones
switch from left-dominant 480/960 Hz to right-dominant 720/1,440 Hz after
one second, so the audio smoke scene can distinguish seek and loop playback
from stale audio. The `in24` version 1 entry reports a nominal 16-bit sample
size but stores three bytes per channel and six per frame.

The smoke scene creates disposable negative inputs under `user://`. Its
unsupported-audio case relabels PCM as `mp4a` to check that video keeps
playing; the payload is not AAC.

## Regression inputs

`fuzz_regressions/` holds malformed binary inputs for exact replay by the
core tests. Save new inputs as `.bin` and add them to `regression_paths` in
[`test_support.zig`](../../src/core/test_support.zig). Keep their original
bytes, even when media tools reject them.

## Replacing media

The [original fixture recipes](https://github.com/claytercek/godot-hap-video/tree/50c026ed39076a075f93de9f722c0127dcb93c2f/scripts)
are available for maintainers. Run them in a scratch checkout, then copy
only the intended replacements into this one. The historical FFmpeg script
specifies four seconds; use two seconds to match the committed clips.

- For Hap1, Hap5, or HapY, update the chunked counterpart and the frame-zero
  still. For Hap1, also update `project/hap1.mov` and the raw BC1 golden.
- `generate_hap7_fixture.py` writes the BC7 clip. `generate_hapm_fixture.py`
  writes the dual-texture clip and both goldens together.
- If `hap1_audio.mov` changes, run `generate_pcm_fixtures.py` in the scratch
  checkout with the replacement source. Its `--check` option compares both
  stereo fixtures with the expected bytes without writing.

Run `zig build test` for the decode and golden checks, then `zig build smoke`
for presentation and audio playback. Use `git lfs fsck` after committing to
verify the pointers and stored objects.
