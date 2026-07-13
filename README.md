# Hap Video GDExtension

Hap video playback for Godot 4.4+. Plays Hap-encoded QuickTime/MOV files
with GPU-native decoding: frames are BC-compressed textures, so playback
is a Snappy decompress plus a texture upload — fast enough for multiple
simultaneous 4K@60 layers, instant seeking, and reverse playback. Built
for interactive installations and live visuals.

Two integration layers over one shared decode core:

1. **Drop-in** — `.mov` files load as a `VideoStream` and play in the
   stock `VideoStreamPlayer` node. Zero new concepts.
2. **Power-user** — a `HapPlayer` node with playback rate, reverse,
   frame-stepping, loop signals, and metadata.

## Requirements

- Godot **4.4+**
- **Forward+ or Mobile** renderer (the extension uses `RenderingDevice`;
  the Compatibility/OpenGL renderer is not supported)
- Windows (x86_64), macOS (universal), or Linux (x86_64)

## Installation

1. Download the addon zip from the [latest release](../../releases/latest)
   (or build from source, below).
2. Unzip it at your project root so the files land in
   `addons/hap_video/`.
3. Restart the editor. That's it — GDExtensions load automatically; there
   is nothing to enable in Project Settings.

The addon is self-contained: prebuilt debug and release binaries for all
three platforms, the `.gdextension` manifest, and all license files.

## Supported variants

| Variant | FourCC | Texture format | GPU work |
|---|---|---|---|
| Hap | `Hap1` | BC1 (DXT1) | pass-through |
| Hap Alpha | `Hap5` | BC3 (DXT5) | pass-through |
| Hap Q | `HapY` | YCoCg BC3 | YCoCg→RGB compute |
| Hap Q Alpha | `HapM` | YCoCg BC3 + BC4 alpha | YCoCg + alpha combine |
| Hap R | `Hap7` | BC7 (BPTC) | pass-through |

Chunked files (TouchDesigner, ffmpeg `-chunks`, AVF Batch Exporter)
decode multithreaded. Files with an audio track play their video; the
audio is skipped cleanly (see Limitations). Every variant — including
Hap Q Alpha's dual-texture layout — presents as a single `Texture2DRD`,
so alpha variants composite through the standard 2D alpha blend.

## Usage

### Layer 1: drop-in (`VideoStreamPlayer`)

Any `.mov` path resolves to a Hap video stream automatically — assign it
to a stock `VideoStreamPlayer` in the editor, or from code:

```gdscript
var player := VideoStreamPlayer.new()
add_child(player)
player.stream = load("res://videos/clip.mov")
player.play()
```

This layer covers what `VideoStreamPlayer` itself supports: play, stop,
pause, seek, loop, forward 1× playback. Errors are reported via the
engine log (the stock player has no error signals to consume).

### Layer 2: `HapPlayer`

`HapPlayer` is a `Control` node with the full control surface. It draws
its video like any other control, and exposes the texture for custom
materials.

```gdscript
var hap := HapPlayer.new()
add_child(hap)

var stream := HapVideoStream.new()
stream.file = "user://shows/loop_4k.mov"
hap.stream = stream

hap.opened.connect(func ():
    print("%dx%d @ %.2f fps, %d frames, %.2f s" % [
        hap.width, hap.height, hap.frame_rate,
        hap.frame_count, hap.duration,
    ])
    hap.play()
)
```

**Properties**

| Property | Type | Default | Notes |
|---|---|---|---|
| `stream` | `HapVideoStream` | — | The video to play; opening is asynchronous, wait for `opened` |
| `loop` | `bool` | `false` | Emits `playback_looped` at each wrap |
| `playback_speed` | `float` | `1.0` | Any float; **negative plays in reverse** |
| `autoplay` | `bool` | `false` | Play as soon as the stream opens |
| `stream_position` | `float` | `0.0` | Get/set; setting seeks (scrub-safe, latest seek wins) |
| `paused` | `bool` | `false` | Freezes the pump in place, texture retained |

Read-only metadata, valid after `opened` fires: `frame_rate`, `width`,
`height`, `duration`, `frame_count`.

**Methods**

- `play()` — starts/resumes from the current `stream_position`, in the
  direction implied by the sign of `playback_speed`. Does not reset
  position.
- `pause()` / `stop()` — `stop()` also resets `stream_position` to 0.
- `step_frame(n: int)` — steps exactly `n` frames (negative allowed);
  auto-pauses if playing.
- `get_texture() -> Texture2D` — the stable per-stream `Texture2DRD`;
  feed it to your own materials for custom rendering.

**Signals**

- `opened()` — metadata is valid, playback may start.
- `playback_completed()` — reached the end (non-looping).
- `playback_looped()` — wrapped around (looping).
- `error_occurred(message: String)` — open failed or the file is
  unsupported.

Multiple videos need no special API: each `HapPlayer` owns its own
playback and all players share one bounded decode worker pool.

## Large files: keep them out of the PCK

Reference large videos by **absolute path or `user://` path**, not
`res://`, and don't pack gigabyte videos into the PCK. The loader
accepts all three path forms and the demuxer memory-maps the file
either way, but PCK-packed videos bloat exports and defeat the
memory-mapped zero-copy read path. Files over 4 GB are supported.

```gdscript
stream.file = "user://content/act2_background.mov"   # good
stream.file = "/media/show-drive/act2_background.mov" # good
```

## Performance tuning

Playback is designed for multiple simultaneous 4K@60 streams. Three
knobs matter if you push it hard:

1. **Staging buffer size** — set
   `rendering/rendering_device/staging_buffer/max_size_mb` to **256**
   in Project Settings for multi-stream 4K. The default 128 MB is
   shared by every texture upload each frame; four 4K Hap Q Alpha
   streams upload ≈ 50 MB/frame, and overflowing the staging buffer
   triggers a full-device flush-and-stall.
2. **Upload region size** —
   `rendering/rendering_device/staging_buffer/texture_upload_region_size_px`
   (default 64) is a profiling lever. Texture uploads are tiled into
   regions and the CPU cost scales with region count (~2,000 memcpys
   per 4K frame at the default). If you see render-thread CPU saturation
   under multi-stream 4K, profile with larger values; there is no
   universal recommended setting.
3. **Decode worker split** — a shared pool of **3 outer workers**
   decodes streams (one stream per worker at a time); the remaining
   hardware threads parallelize chunk decode within a frame. If many
   simultaneous streams starve the outer pool, raise
   `OuterThreadPool::kDefaultWorkers` (`src/core/outer_thread_pool.h`)
   and rebuild — the trade-off is less chunk-level parallelism per
   stream. This is a compile-time constant, not a runtime setting.

## Limitations

- **Video-only.** Audio tracks in the container are skipped cleanly and
  never played; the extension reports a silent stream.
- **HapA (alpha-only) and Hap HDR (BC6) are not supported.** Files in
  these variants fail to open with a clear error rather than
  misrendering.
- **Forward+ and Mobile renderers only.** The Compatibility (OpenGL)
  renderer has no `RenderingDevice` and is not supported.
- **Single-precision Godot builds only.** Double-precision
  (`precision=double`) builds are not provided or tested.
- **No performance guarantees.** The multi-4K@60 target shaped the
  architecture, but there is no minimum hardware spec or benchmark
  gate; below high-end hardware, throughput is best-effort.

## Building from source

```bash
git clone --recursive <repo>
cd godot-hap-video

scons target=template_debug    # editor/debug binary
scons target=template_release  # release binary
```

Binaries, the `.gdextension` manifest, and bundled licenses are
assembled into `addons/hap_video/` for the host platform. Headless core
tests build with `scons build_tests=1 target=template_debug` and run via
`scripts/run_core_tests.sh`.

## Dependencies

| Library | Purpose | License |
|---|---|---|
| [Vidvox hap](https://github.com/vidvox/hap) | Hap frame decode | BSD-2-Clause |
| [Google snappy](https://github.com/google/snappy) | Snappy decompression | BSD-3-Clause |
| [minimp4](https://github.com/lieff/minimp4) | MOV/MP4 demux | CC0 |
| [godot-cpp](https://github.com/godotengine/godot-cpp) | GDExtension bindings | MIT |

hap, snappy, and minimp4 are vendored under `thirdparty/` (see
`thirdparty/README.md` for versions and local patches); godot-cpp is a
submodule pinned to `godot-4.4.1-stable`.

## License

MIT — see [LICENSE.md](LICENSE.md). Vendored dependencies carry their
own licenses, shipped both in `thirdparty/licenses/` and inside the
addon at `addons/hap_video/licenses/`.
