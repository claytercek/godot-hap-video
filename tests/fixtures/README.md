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
core tests. Keep their original bytes, even when media tools reject them.
