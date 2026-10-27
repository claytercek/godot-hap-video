# Hap Video for Godot

Play Hap-encoded QuickTime (`.mov`) video through Godot 4's `VideoStreamPlayer`
or the extension's `HapPlayer` node. The extension uploads GPU-compressed Hap
textures and plays embedded signed 16/24-bit PCM through Godot's audio buses.

## Requirements

Use **Godot 4.6 or later** with the **Forward+ or Mobile renderer**.
Compatibility/OpenGL and headless mode lack the `RenderingDevice` needed to
present Hap textures. The addon manifest declares no double-precision library.

CPU requirements:

- x86_64: Intel Haswell (2013) or newer, or equivalent AMD hardware
  (Excavator/Zen+ or newer). Snappy uses SSSE3 and BMI2 with no runtime CPU
  dispatch; BMI2 sets the minimum. Older CPUs will hit `SIGILL` during decode.
- aarch64/arm64: the ARMv8-A baseline, which includes NEON.

Releases include debug and release libraries; Godot selects the flavor for its
export mode:

| Platform | Architectures | Libraries |
| --- | --- | --- |
| macOS | universal arm64 + x86_64 | `libhap_video.macos.debug.dylib`, `libhap_video.macos.release.dylib` |
| Linux | x86_64, arm64 | `libhap_video.linux.{debug,release}.{x86_64,arm64}.so` |
| Windows | x86_64, arm64 | `hap_video.windows.{debug,release}.{x86_64,arm64}.dll` |

Linux builds target glibc 2.31. Runtime CI covers Linux x86_64 only;
cross-compilation does not verify that macOS, Windows, or Linux arm64 libraries
load or run.

## Install and play a video

1. Download `hap-video-<tag>.zip` from the [latest release](../../releases/latest).
2. Extract it at your Godot project's root so its contents land in
   `addons/hap_video/`.
3. Restart the editor to load the GDExtension.

The archive includes the manifest, libraries for all supported platforms, this
README, and license notices.

Put a Hap `.mov` file in the project and assign it to a `VideoStreamPlayer`:

```gdscript
var player := VideoStreamPlayer.new()
add_child(player)
player.stream = load("res://videos/loop.mov")
player.play()
```

The extension registers a `.mov` resource loader. Use `VideoStreamPlayer`'s
play, pause, stop, seek, and loop controls. Opening blocks until the display
texture is ready for the node's first draw.

## Use `HapPlayer` for direct control

`HapPlayer` is a `Control` with asynchronous opening, frame stepping, reverse
playback, and lifecycle signals. Wait for `opened` before reading metadata or
starting playback. Use `get_texture()` to access the texture for a material.

```gdscript
var hap := HapPlayer.new()
add_child(hap)

var stream := HapVideoStream.new()
stream.file = "res://videos/loop.mov"
hap.stream = stream

hap.opened.connect(func():
	print("%d frames at %.2f fps" % [hap.frame_count, hap.frame_rate])
	hap.play()
)
hap.error_occurred.connect(func(message):
	push_error(message)
)
```

`HapVideoStream.file` accepts `res://`, `user://`, or an absolute filesystem
path. Files must be accessible on disk for memory mapping. Keep large media
outside the exported PCK and use `user://` or an absolute path.

### Properties

| Property | Type | Default | Meaning |
| --- | --- | --- | --- |
| `stream` | `HapVideoStream` | `null` | Assign a stream to open it asynchronously. |
| `loop` | `bool` | `false` | Wrap at either end. |
| `playback_speed` | `float` | `1.0` | Playback rate; negative values play backwards. |
| `bus` | `StringName` | `"Master"` | Audio bus for embedded PCM. |
| `volume_db` | `float` | `0.0` | PCM volume in decibels. |
| `autoplay` | `bool` | `false` | Play after opening. |
| `stream_position` | `float` | `0.0` | Position in seconds; setting it seeks. |
| `paused` | `bool` | `false` | Pause and retain the current texture. |
| `frame_rate`, `width`, `height`, `duration`, `frame_count` | read-only | `0` before open | Track metadata, valid after `opened`. |
| `has_audio` | read-only `bool` | `false` | Whether the first audio track is supported PCM. |
| `audio_sample_rate`, `audio_channels` | read-only `int` | `0` | Source PCM rate and channel count; zero without supported audio. |

### Methods and signals

- `play()` starts or resumes at the current position.
- `pause()` freezes playback and retains the texture.
- `stop()` stops playback and resets the position to zero.
- `step_frame(n: int)` pauses if needed and moves exactly `n` frames;
  negative values step backwards.
- `get_texture() -> Texture2D` returns the current display texture, a stable
  `Texture2DRD` wrapper.

| Signal | Emitted when |
| --- | --- |
| `opened()` | Metadata and the display texture are ready. |
| `playback_completed()` | Playback reaches an end with `loop` disabled. |
| `playback_looped()` | Playback wraps around an end. |
| `error_occurred(message: String)` | Opening or GPU setup fails; emitted once per failure. |

Handle `error_occurred(message)` to report failures in your game.
`VideoStreamPlayer` reports failures through Godot's log.

## Supported content

The `.mov` loader selects a Hap video track from the MOV container:

| Variant | FourCC | Presentation |
| --- | --- | --- |
| Hap | `Hap1` | BC1/DXT1 texture upload |
| Hap Alpha | `Hap5` | BC3/DXT5 texture upload with alpha |
| Hap Q | `HapY` | YCoCg BC3 converted to RGBA by a compute shader |
| Hap Q Alpha | `HapM` | YCoCg plus BC4 alpha, converted to RGBA by a compute shader |
| Hap R | `Hap7` | BC7/BPTC texture upload |

Chunked frames and sample offsets beyond 4 GB are supported. HapA and Hap HDR
are rejected.

### Embedded PCM audio

Both players use **only the first audio track** (index `0`). Supported audio:

- Signed, packed, interleaved 16-bit or 24-bit integer PCM, mono or stereo,
  in either byte order. Mono duplicates to left and right; stereo channels
  remain distinct.
- Integer sample rates of 8,000 to 192,000 Hz.
- QuickTime `sowt`, `twos`, and `in24` version 0/1 sample entries, including
  `wave`/`enda` byte-order metadata; version 2 `lpcm` entries with explicit
  signed/packed/interleaved layout flags.
- Constant-size PCM packets with consistent timing and packet geometry.
- No edit list, an identity edit, or one forward trim with an optional leading
  empty edit. Audio outside the presentation window is silent.

AAC, MP3, ALAC, floating-point or unsigned PCM, planar/padded layouts,
multichannel audio, and more complex edit lists are unsupported. Unsupported
audio warns and leaves video usable; the loader never tries another audio
track. There is no AAC decoder or FFmpeg/GStreamer runtime dependency.

`HapPlayer` plays audio only during forward playback at `playback_speed == 1.0`.
Pause, stop, frame stepping, reverse, and other speeds silence it. Seeks and
loops discard queued sound. Set `bus` and `volume_db` to route and adjust PCM.

`VideoStreamPlayer` uses its own audio and transport controls. Godot's
pitch-changing resampler handles `speed_scale`, without `HapPlayer`'s non-1x
mute policy. Setting `audio_track` to anything other than `0` disables audio.

Audio synchronization is roughly **100 ms** on normal devices; playback is
neither sample-exact nor gapless. Main-thread stalls drop stale sound rather
than play it late. High device latency can worsen synchronization.

## Performance

The core memory-maps MOV files, parses them with minimp4, and decodes frames
with vendored Hap and Snappy code. Streams share a bounded decode pool: jobs
for each stream run serially, and different streams can use different workers. Chunk decoding uses
the remaining hardware threads. A three-texture retirement ring protects
textures still in the render queue.

PCM conversion runs in bounded main-thread batches and copies into Godot's
audio buffers. It never reads mapped media on the audio thread or loads an
entire PCM track into memory. Constant-size PCM sample tables avoid one index
record per audio frame.

Profile high-throughput scenes on the target hardware. The outer decode pool
defaults to three workers. Change `kDefaultWorkers` in
`src/core/outer_thread_pool.zig` and rebuild to trade stream-level parallelism
against chunk-level parallelism.

## Build from source

Clone the repository; no submodules are required:

```bash
git clone <repository-url>
cd godot-hap-video
```

Install **Zig 0.17.0** from [Zig](https://ziglang.org/download/). Core tests need
no Godot installation:

```bash
zig version             # 0.17.0
zig build test
```

`build.zig.zon` pins upstream gdzig to
`c05f4910e2bf72cb947423acee6554dd0d29b041`, verified by its Zig package hash.
The first build needs network access; later builds use Zig's cache. gdzig
bundles the Godot API and interface header, so building and cross-compiling
need no Godot executable.

`run`, `smoke`, and `audio-smoke` require a separate Godot 4.6+ installation.
The executable lookup order is `-Dgodot-path`, `GODOT_PATH`, then `godot` on
`PATH`. The build neither downloads Godot nor accepts `-Dgodot-version`:

```bash
zig build smoke -Dgodot-path=/path/to/godot
# or
GODOT_PATH=/path/to/godot zig build run
```

With `gdvm`, point `GODOT_PATH` at its managed executable, for example
`export GODOT_PATH="$(gdvm show 4.7.1)"`. The build does not select a version.
CI tests Godot 4.6.3 and 4.7.2.

Development builds install into `project/lib/` and use
`project/hap_video.gdextension`, separate from the release addon manifest:

```bash
zig build                         # build the development extension
zig build run                     # build, then run the development demo
zig build smoke                   # build, then run video and audio smokes serially
zig build audio-smoke             # same prerequisites, ending with PCM capture checks
zig build test -Dtest-optimize=debug # core tests with Zig runtime safety checks
zig build test -Dsanitize-c=full  # core tests with C/C++ UBSan
```

`zig build run -- <args>` forwards `<args>` to Godot.

### Fixtures

Tests use committed media under `tests/fixtures/`. Regenerate it from the
project root with `bash scripts/generate_fixtures.sh`, using Python 3 and
FFmpeg built with `--enable-libsnappy`. Stereo PCM fixtures reuse committed
Hap video and need only Python 3:

```bash
python3 scripts/generate_pcm_fixtures.py
python3 scripts/generate_pcm_fixtures.py --check
```

### Smoke tests

`zig build smoke` and `zig build audio-smoke` run the video scene followed by
`project/audio_smoke.tscn`. Both must print their completion markers; Godot's
exit code alone does not prove success. Video needs a `RenderingDevice`, and
PCM capture needs a real audio driver. Neither headless mode nor Dummy audio
can validate these checks. PCM capture runs upstream of a muted sink bus and
produces no audible sound.

The scenes check presentation, metadata, seeking, rejected stream replacements,
and reference cleanup. PCM checks cover mono duplication, stereo16/24
big-endian conversion and normalization, seek/loop content, pause/speed/volume/bus
controls, completion, and teardown. Regressions cover retained old
playbacks, paused stock-player starts/restarts, audio-track restoration without
a seek, and terminal decode failure while looping. The last test corrupts a
late video frame in a temporary MOV, preserving PCM and sample tables; its
decoder error log is expected. Synthetic unsupported audio metadata tests
video-only fallback.

On Godot 4.6, gdzig logs missing 4.7 interface probes at startup:
`variant_get_type_by_name`, `classdb_construct_object3`, and
`classdb_register_extension_class6`. The 4.6 fallback still runs and passes smoke.

To test an existing library without rebuilding or overwriting it:

```bash
python3 tests/run_smoke.py --godot gdvm --gdvm-version 4.7.2 \
  --driver default --audio --log-dir ci-logs
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

The runner executes the scenes serially with deadlines, exact completion
markers, and a required Forward+ device banner. Its log checker permits only
the scenes' exact intentional errors and the known Godot 4.6 interface probes;
other errors and leaks fail even after a successful exit.

Omit `--audio` for video-only smoke. PCM uses normal engine cadence and a real
audio driver. `--audio-driver` selects a driver and requires its exact log
marker. Omit it for Godot's native default, including CoreAudio on macOS.
CI requires `--audio-driver PulseAudio` and the exact
`AUDIO_SMOKE_DRIVER: PulseAudio` marker; driver fallback fails validation.

### CI and packaging

CI and releases use `.github/workflows/build.yml` to cross-compile all platform
and architecture targets on Ubuntu 24.04 with Zig 0.17.0. The `safe` and `fast`
builds become debug and release libraries. `llvm-lipo-18` combines and verifies
the macOS universal libraries. Builds never install or run host Godot. Artifacts
are named `hap-video-macos`, `hap-video-linux`, and `hap-video-windows`.

Runtime CI tests the Linux x86_64 release artifact without rebuilding. It runs
Godot 4.7.2 and 4.6.3 on Ubuntu 24.04 with Xvfb, Mesa software Vulkan, and
PulseAudio's virtual 48,000 Hz stereo sink. Core and Python helper tests run
once in the 4.7.2 job. CI uploads build and runtime logs; sanitizer and benchmark
workflows run separately.

For release recovery, run the Release workflow with `package-only` and an
existing `release-tag` to rebuild that tag and replace its ZIP. Leave the tag
empty to upload a workflow artifact without creating a release. Build and
packaging must use the same source ref, not the current branch tip. Packaging
checks every manifest library and required notice, including Snappy AUTHORS,
and rejects stale extra files.

## Project layout

| Path | Contents |
| --- | --- |
| `addon/` | Release GDExtension manifest. |
| `project/` | Development demo, video/audio smoke scenes, fixture MOV, and development manifest. |
| `src/core/` | Godot-independent MOV demuxing, Hap decode, scheduling, and tests. |
| `src/godot/` | GDExtension classes, resource loader, playback adapter, and GPU presenter. |
| `thirdparty/` | Vendored Hap, minimp4, and Snappy sources, plus third-party license notices (including gdzig). |
| `build.zig.zon` | Pinned upstream gdzig GDExtension binding dependency. |
| `tests/fixtures/` | Media fixtures and provenance notes. |

## License

Licensed under the [MIT License](LICENSE.md). Release archives also include
Hap, minimp4, Snappy, and gdzig license notices.
