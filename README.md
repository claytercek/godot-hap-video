# Hap Video for Godot

Play Hap-encoded QuickTime (`.mov`) video in Godot 4. The extension decodes
Hap frames, uploads their GPU-compressed texture data, and exposes them through
Godot's `VideoStreamPlayer` or a `HapPlayer` node for direct control.
Embedded signed 16/24-bit PCM audio plays through Godot's audio buses.

## Install and play a video

1. Download `hap-video-<tag>.zip` from the [latest release](../../releases/latest).
2. Extract it at your Godot project's root so its contents land in
   `addons/hap_video/`.
3. Restart the editor. Godot loads the GDExtension automatically.

The release archive contains the manifest, debug and release libraries for the
supported platforms, this README, and the required license notices.

Put a Hap `.mov` file in the project and assign it to a normal
`VideoStreamPlayer`. The extension registers a loader for `.mov` files:

```gdscript
var player := VideoStreamPlayer.new()
add_child(player)
player.stream = load("res://videos/loop.mov")
player.play()
```

This route uses the controls provided by `VideoStreamPlayer`, including play,
pause, stop, seeking, and looping. Opening is synchronous here because the
stock node needs the display texture before its first draw.

## Use `HapPlayer` for direct control

`HapPlayer` is a `Control` that opens its stream asynchronously. Use it for
frame stepping, reverse playback, lifecycle signals, or the texture for your
own material. Wait for `opened` before reading metadata or starting playback.

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

`HapVideoStream.file` accepts a Godot path such as `res://` or `user://`,
or an absolute filesystem path. The extension resolves it before memory-mapping
the file. For large media, keep it outside the exported PCK and reference it
through `user://` or an absolute path.

### `HapPlayer` reference

| Property | Type | Default | Meaning |
| --- | --- | --- | --- |
| `stream` | `HapVideoStream` | `null` | Stream to open. Assigning one starts an asynchronous open. |
| `loop` | `bool` | `false` | Wrap when playback reaches an end. |
| `playback_speed` | `float` | `1.0` | Playback rate. A negative value plays backwards. |
| `bus` | `StringName` | `"Master"` | Godot audio bus for embedded PCM. |
| `volume_db` | `float` | `0.0` | Embedded PCM volume in decibels. |
| `autoplay` | `bool` | `false` | Start playing after the stream opens. |
| `stream_position` | `float` | `0.0` | Current position in seconds. Setting it seeks. |
| `paused` | `bool` | `false` | Pause without discarding the current texture. |
| `frame_rate`, `width`, `height`, `duration`, `frame_count` | read-only | `0` before open | Track metadata, valid after `opened`. |
| `has_audio` | read-only `bool` | `false` | Whether the first embedded audio track is supported PCM. |
| `audio_sample_rate`, `audio_channels` | read-only `int` | `0` | Source PCM rate and channel count; zero when audio is unavailable. |

Methods:

- `play()` starts or resumes from the current position.
- `pause()` freezes playback and retains the texture.
- `stop()` stops playback and resets the position to zero.
- `step_frame(n: int)` pauses if needed, then moves exactly `n` frames.
  `n` may be negative.
- `get_texture() -> Texture2D` returns the current display texture.

Signals:

- `opened()` fires when metadata and the display texture are ready.
- `playback_completed()` fires at an end when `loop` is false.
- `playback_looped()` fires each time looping wraps.
- `error_occurred(message: String)` fires once when opening or GPU setup
  fails.

## Requirements and releases

Godot **4.6 or later** is required by the shipped manifest. Use the Forward+
or Mobile renderer. The Compatibility/OpenGL renderer has no
`RenderingDevice`, so it cannot present Hap textures.

CPU minimums, since there is no runtime CPU dispatch:

- **x86_64**: Intel Haswell (2013) or newer, or the equivalent AMD part
  (Excavator/Zen+ or newer). The vendored Snappy decompressor is built with
  SSSE3 and BMI2 intrinsics for x86_64; BMI2 is the binding constraint. An
  older x86_64 CPU will hit `SIGILL` decoding a Hap frame.
- **aarch64/arm64**: the standard 64-bit Arm baseline (ARMv8-A). NEON is
  mandatory in that ISA and always used, so no CPU beyond the baseline is
  required.

Each release includes debug and release binaries selected automatically by
Godot's export mode:

| Platform | Architectures | Libraries |
| --- | --- | --- |
| macOS | universal arm64 + x86_64 | `libhap_video.macos.debug.dylib`, `libhap_video.macos.release.dylib` |
| Linux | x86_64, arm64 | `libhap_video.linux.{debug,release}.{x86_64,arm64}.so` |
| Windows | x86_64, arm64 | `hap_video.windows.{debug,release}.{x86_64,arm64}.dll` |

CI and releases share `.github/workflows/build.yml`. All build jobs use
Ubuntu 24.04 in one three-platform matrix (macOS, Linux, Windows). Zig 0.17.0
cross-compiles all six architecture targets in both safe/debug and fast/release
flavors: macOS arm64/x86_64, Linux x86_64/arm64 targeting glibc 2.31, and Windows
x86_64/arm64. On the Linux host, `llvm-lipo-18` combines and verifies each macOS
universal library. Builds do not install or run host Godot. The artifact names
remain `hap-video-macos`, `hap-video-linux`, and `hap-video-windows`.

Runtime CI runs only on Ubuntu 24.04, using Godot 4.7.2 and 4.6.3. Each run
consumes the Linux x86_64 release library from `hap-video-linux`, without
rebuilding the extension. Rendered Forward+ video and PCM smoke use Xvfb,
Mesa software Vulkan, and PulseAudio with a virtual 48,000 Hz stereo sink.
PCM validation requires the exact `AUDIO_SMOKE_DRIVER: PulseAudio` marker;
Dummy audio and audio-driver fallback fail validation. Native core and Python
helper tests run once, in the primary Godot 4.7.2 job. There are no native macOS
or Windows runtime jobs: cross-compilation and Linux smoke do not prove that
foreign-platform libraries load or run. Linux arm64 is compile-covered only.
Sanitizer and benchmark workflows remain separate.

The Release workflow supports `package-only` recovery: supply an existing
`release-tag` to rebuild that tag and replace its ZIP, or leave the tag empty to
upload a workflow artifact without creating a release. Build and packaging must
use the same source ref, not the current branch tip. Packaging consumes the
shared build artifacts and checks every library declared by the addon manifest,
all required notices (including Snappy AUTHORS), and rejects stale extra files.

## Supported content

The loader recognizes `.mov` files and selects a Hap video track from the
MOV container.

| Variant | FourCC | Presentation |
| --- | --- | --- |
| Hap | `Hap1` | BC1/DXT1 texture upload |
| Hap Alpha | `Hap5` | BC3/DXT5 texture upload with alpha |
| Hap Q | `HapY` | YCoCg BC3 converted to RGBA by a compute shader |
| Hap Q Alpha | `HapM` | YCoCg plus BC4 alpha, converted to RGBA by a compute shader |
| Hap R | `Hap7` | BC7/BPTC texture upload |

Chunked Hap frames are supported. The demuxer can validate sample offsets
beyond 4 GB, and files are read through a memory map.

### Embedded PCM audio

Both players support the **first audio track only** (index `0`), with:

- Signed, packed, interleaved **16-bit or 24-bit integer PCM**, mono or stereo.
  Mono is duplicated to left and right; stereo channels remain distinct.
- Integer sample rates from **8,000 to 192,000 Hz**.
- QuickTime `sowt`, `twos`, and `in24` version 0/1 sample entries, including
  `wave`/`enda` byte-order metadata, and version 2 `lpcm` entries with explicit
  signed/packed/interleaved layout flags. Little- and big-endian PCM are supported.
- Constant-size PCM packets with consistent timing and packet geometry. No edit
  list, an identity edit, or one forward trim with an optional leading empty
  edit is supported. Audio outside that presentation window is silent.

AAC, MP3, ALAC, floating-point PCM, unsigned PCM, planar/padded layouts,
multichannel audio, and more complex edit lists are not supported. An unsupported
audio track produces a warning and leaves Hap video usable; the loader does not
fall back to another audio track. There is **no AAC decoder**, FFmpeg, or GStreamer
runtime dependency.

`HapPlayer` outputs audio only while playing forwards at `playback_speed == 1.0`.
Pause, stop, frame stepping, reverse, and other speeds silence it; seeks and loops
discard stale queued sound. Use `bus` and `volume_db` to route and control volume.
The stock `VideoStreamPlayer` uses its own `bus`, `volume_db`, pause, seek, and
loop controls. Its `speed_scale` is handled by Godot's pitch-changing resampler
and does not have `HapPlayer`'s non-1x mute policy. Selecting `audio_track` other
than `0` disables audio rather than selecting another embedded track.

Audio synchronization is pragmatic, roughly **100 ms** on normal devices, not
sample-exact or gapless. Long main-thread stalls drop stale sound instead of
playing it late; unusually large device latency can worsen synchronization.

## Architecture

The Godot-facing layer registers `HapVideoStream`, a `.mov` resource loader,
and `HapPlayer`. Both playback surfaces use the same Godot-independent core.
That core memory-maps the MOV file, parses its track and sample table with
minimp4, and decodes Hap sections with the vendored Hap and Snappy libraries.

Decode work runs on one bounded process-wide outer worker pool, not one worker
per video. A stream's jobs stay serial, while different streams can run on
different pool workers. Chunk decoding uses the remaining hardware threads.
The presenter keeps a three-texture retirement ring so a new upload does not
overwrite a texture still in the render queue.

Hap1, Hap5, and Hap7 use GPU-compressed uploads. HapY and HapM upload their
compressed inputs, then run a YCoCg-to-RGBA compute pass. `get_texture()`
returns the stable `Texture2DRD` wrapper used for presentation.

PCM is converted from mapped media in bounded batches on the main thread and
copied into Godot's audio buffers. The extension does not decode/read mapped media
on the audio thread or load an entire PCM track into memory. Constant-size audio
sample tables stay compact rather than allocating one index record per PCM frame.

## Limitations and diagnostics

- Audio support is limited to the PCM layouts and playback policies above;
  unsupported audio warns without failing video playback.
- HapA and Hap HDR are rejected. Supported FourCCs are `Hap1`, `Hap5`,
  `HapY`, `HapM`, and `Hap7`.
- The Compatibility/OpenGL renderer and headless presentation are not
  supported because both lack a `RenderingDevice`.
- No shipped double-precision Godot library variant is declared in the addon
  manifest.
- `VideoStreamPlayer` exposes failures through Godot's log. With
  `HapPlayer`, handle `error_occurred(message)` to report an open or
  presenter failure in your game.

For high-throughput scenes, profile on the target hardware. The default outer
decode pool has three workers; changing `kDefaultWorkers` in
`src/core/outer_thread_pool.zig` requires rebuilding and trades stream-level
parallelism against chunk-level parallelism.

## Build from source

Clone the repository (no submodules required):

```bash
git clone <repository-url>
cd godot-hap-video
```

Install **Zig 0.17.0** directly from [Zig](https://ziglang.org/download/).
The core test suite does not need Godot:

```bash
zig version             # 0.17.0
zig build test
```

`build.zig.zon` fetches canonical upstream gdzig directly, pinned by URL to
`c05f4910e2bf72cb947423acee6554dd0d29b041` and verified by its Zig
package hash. The first build needs network access to fetch the dependency;
subsequent builds use Zig's cache. This revision includes the nullable-object
and nullable-Ref ptrcall fixes previously carried by our fork. Its bundled
Godot API and interface header let you build the extension and cross-compile
without installing Godot.

`run`, `smoke`, and `audio-smoke` need Godot 4.6 or newer. Install Godot separately
(for example, with `gdvm`). These commands use
`-Dgodot-path`, then `GODOT_PATH`, then `godot` on `PATH`. Godot is no longer
downloaded by the build, and `-Dgodot-version` is no longer supported:

```bash
zig build smoke -Dgodot-path=/path/to/godot
# or
GODOT_PATH=/path/to/godot zig build run
```

If you use `gdvm`, point `GODOT_PATH` at the Godot executable it manages,
for example `export GODOT_PATH="$(gdvm show 4.7.1)"`. The build does not
pick a Godot version for you. CI tests both 4.6.3 and 4.7.2.

To regenerate the media fixtures from the project root, run
`bash scripts/generate_fixtures.sh`. This requires Python 3 and FFmpeg built
with `--enable-libsnappy` for Hap encoding. The fixture files under
`tests/fixtures/` are committed for tests. The additional stereo PCM fixtures
need **only Python 3**, reusing committed Hap video without an encoder:

```bash
python3 scripts/generate_pcm_fixtures.py
python3 scripts/generate_pcm_fixtures.py --check
```

The development build installs the library into `project/lib/` and uses
`project/hap_video.gdextension`, which is separate from the release addon
manifest. Useful commands:

```bash
zig build                         # build the development extension
zig build run                     # build, then run the development demo
zig build smoke                   # build, then run video and audio smokes serially
zig build audio-smoke             # same prerequisites, ending with PCM capture checks
zig build test -Dtest-optimize=debug # core tests with Zig runtime safety checks
zig build test -Dsanitize-c=full  # core tests with C/C++ UBSan
```

`zig build run -- <args>` forwards `<args>` to Godot. `zig build smoke`
checks that the extension can open the bundled Hap fixture, present a frame,
expose metadata, seek, preserve playback after a rejected replacement, and
release stream references. It requires a RenderingDevice and checks for the
script's completion marker rather than relying on Godot's exit code alone.
It then runs `project/audio_smoke.tscn` with a real audio driver, capturing PCM
upstream of a muted sink bus, so it does not play audible sound. This checks mono
duplication, stereo16/24 big-endian conversion and normalization, changing
seek/loop content, pause/speed/volume/bus controls, completion and teardown, and
video-only fallback for synthetic unsupported audio metadata. Regressions also
cover generator lifetime while an old playback is retained, paused stock-player
starts/restarts, the first PCM after a no-seek audio-track restore, and terminal
video-decode failure with looping enabled. The latter corrupts a late video frame
in a temporary MOV without changing PCM or sample tables; its decoder error log
is expected. The two scenes
run serially and must both print their completion markers; `--headless` or a
dummy audio driver cannot validate these presentation/capture checks.

On Godot 4.6, this upstream revision logs missing 4.7 interface probes (`variant_get_type_by_name`, `classdb_construct_object3`,
`classdb_register_extension_class6`) at startup; the 4.6 fallback still runs
and the smoke test passes.

To test an already-built or downloaded extension without overwriting it:

```bash
python3 tests/run_smoke.py --godot gdvm --gdvm-version 4.7.2 \
  --driver default --audio --log-dir ci-logs
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

The runner executes the two existing scenes serially, enforces deadlines and
exact completion markers, and requires a Forward+ device banner. Its log checker
allows only the scenes' exact intentional negative-test errors and the three
known interface-probe errors on Godot 4.6; other errors and leaks fail even if
Godot exits successfully. CI uploads build and runtime diagnostic logs. For
video-only smoke omit `--audio`; PCM uses the normal engine cadence and a real
audio driver, never a headless or Dummy-audio fallback.
The optional `--audio-driver` selects a PCM driver and requires its exact marker
in the log. Omit it for Godot's native default, including CoreAudio on macOS.
CI passes `--audio-driver PulseAudio` and rejects fallback to another driver.

## Project layout

| Path | Contents |
| --- | --- |
| `addon/` | Release GDExtension manifest. |
| `project/` | Development demo, video/audio smoke scenes, fixture MOV, and development manifest. |
| `src/core/` | Godot-independent MOV demuxing, Hap decode, scheduling, and tests. |
| `src/godot/` | GDExtension classes, resource loader, playback adapter, and GPU presenter. |
| `thirdparty/` | Vendored Hap, minimp4, and Snappy sources, plus third-party license notices (including gdzig). |
| `build.zig.zon` | Pinned upstream gdzig GDExtension binding dependency. |
| `tests/fixtures/` | Media fixtures and notes about their provenance. |

## License

This project is licensed under the [MIT License](LICENSE.md). The release
archive also includes the license notices for Hap, minimp4, Snappy, and gdzig.
