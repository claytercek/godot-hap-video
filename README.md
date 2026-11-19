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

Install [Zig 0.17.0](https://ziglang.org/download/) and
[Git LFS](https://git-lfs.com/), then clone the repository:

```bash
git lfs install
git clone https://github.com/claytercek/godot-hap-video.git
cd godot-hap-video
zig build test
```

For an existing checkout, run `git lfs pull` before testing, benchmarking, or
running the demo. The [fixture inventory](tests/fixtures/README.md) describes
the media and golden frames. `zig build test` uses these files without Godot,
FFmpeg, or Python. The first build also downloads the pinned gdzig dependency,
which bundles the Godot API and interface header.

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
zig build test -Dsanitize-c=full  # core tests with C/C++ UBSan
zig build bench                   # benchmark open, close, and decode against the fixtures
```

`zig build run -- <args>` forwards `<args>` to Godot.

### Smoke tests

`zig build smoke` runs the rendered video scene followed by the PCM capture
scene. Both must print their completion markers and exit without unexpected
errors or leaks. Video needs a Forward+ rendering device; PCM capture needs
a real audio driver. Headless mode and Dummy audio lack those devices. The audio
scene captures upstream of a muted bus, so no sound plays through the speakers.

To test a library already installed in `project/lib/` without rebuilding it,
run the same checker from the repository root:

```bash
zig run tools/smoke.zig -- --audio
```

The runner prints its log directory under `.zig-cache/smoke/`. Use
`--log-dir ci-logs` for a fixed artifact path; reserve it for one run at a time.
Omit `--audio` for video only. Use `--audio-driver PulseAudio` with `--audio`
to require that specific driver, or omit `--audio-driver` for the native
default. With `gdvm`, pass `--godot "$(gdvm show 4.7.2)"`.

### CI and packaging

See [Contributing](CONTRIBUTING.md) for CI coverage, package validation, and
release recovery.

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
