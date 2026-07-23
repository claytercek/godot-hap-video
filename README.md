# Hap Video for Godot

Play Hap-encoded QuickTime (`.mov`) video in Godot 4. The extension decodes
Hap frames, uploads their GPU-compressed texture data, and exposes them through
Godot's `VideoStreamPlayer` or a `HapPlayer` node for direct control.

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
| `autoplay` | `bool` | `false` | Start playing after the stream opens. |
| `stream_position` | `float` | `0.0` | Current position in seconds. Setting it seeks. |
| `paused` | `bool` | `false` | Pause without discarding the current texture. |
| `frame_rate`, `width`, `height`, `duration`, `frame_count` | read-only | `0` before open | Track metadata, valid after `opened`. |

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

The release workflow builds those targets. The regular CI smoke test runs on
macOS; the other release targets are cross-compiled in CI.

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

## Limitations and diagnostics

- This is video-only. An audio track in a MOV file is skipped while the Hap
  video track is used.
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

Clone the repository with its submodules, because `vendor/gdzig` is a required
local dependency:

```bash
git clone --recurse-submodules <repository-url>
cd godot-hap-video
```

Use **Zig 0.16.0**. The core test suite does not need Godot:

```bash
zig build test
```

Building the extension needs a Godot executable for GDExtension binding
generation. By default, the build asks gdzig for Godot 4.6. Supply a local
executable when needed:

```bash
zig build -Dgodot-path=/path/to/godot
# or
GODOT_PATH=/path/to/godot zig build
```

The development build installs the library into `project/lib/` and uses
`project/hap_video.gdextension`, which is separate from the release addon
manifest. Useful commands:

```bash
zig build                         # build the development extension
zig build run                     # build, then run the development demo
zig build smoke                   # build, then open and present the bundled fixture
zig build test -Dtest-optimize=Debug # core tests with Zig runtime safety checks
zig build test -Dsanitize-c=full  # core tests with C/C++ UBSan
```

`zig build run -- <args>` forwards `<args>` to Godot. `zig build smoke`
checks that the extension can open the bundled Hap fixture, present a frame,
expose metadata, seek, and preserve playback after a rejected replacement. It
requires a RenderingDevice.

## Project layout

| Path | Contents |
| --- | --- |
| `addon/` | Release GDExtension manifest. |
| `project/` | Development demo, smoke scene, fixture MOV, and development manifest. |
| `src/core/` | Godot-independent MOV demuxing, Hap decode, scheduling, and tests. |
| `src/godot/` | GDExtension classes, resource loader, playback adapter, and GPU presenter. |
| `thirdparty/` | Vendored Hap, minimp4, and Snappy sources and their license notices. |
| `vendor/gdzig/` | Pinned GDExtension binding dependency. |
| `tests/fixtures/` | Media fixtures and notes about their provenance. |

## License

This project is licensed under the [MIT License](LICENSE.md). The release
archive also includes the license notices for Hap, minimp4, Snappy, and gdzig.
