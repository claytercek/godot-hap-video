# Hap Video GDExtension

Hap video playback for Godot 4.4+. A GDExtension that plays Hap-encoded
QuickTime/MOV files through both the stock `VideoStreamPlayer` and a
custom `HapPlayer` node.

## Status

🚧 Skeleton — build system, vendored dependencies, and empty extension
loading in the editor. Implementations in progress.

## Supported variants

| Variant | FourCC | Texture |
|---|---|---|
| Hap | Hap1 | BC1 (DXT1) |
| Hap Alpha | Hap5 | BC3 (DXT5) |
| Hap Q | HapY | YCoCg DXT5 |
| Hap Q Alpha | HapM | YCoCg DXT5 + BC4 Alpha |
| Hap R | Hap7 | BC7 (BPTC) |

## Build

Requires Godot 4.4+ and a RenderingDevice renderer (Forward+ or Mobile).

```bash
# Clone with submodules
git clone --recursive <repo>
cd godot-hap-video

# Initialize submodules if you cloned without --recursive
git submodule update --init --recursive

# Debug build
scons target=template_debug

# Release build
scons target=template_release
```

## Install

Copy the `addons/hap_video/` directory into your project's `addons/`
folder, then enable the addon in Project Settings → Plugins.

## Dependencies

| Library | Purpose | License |
|---|---|---|
| [minimp4](https://github.com/lieff/minimp4) | MOV/MP4 demux | CC0 |
| [Vidvox hap](https://github.com/vidvox/hap) | HAP decode | BSD-2-Clause |
| [Google snappy](https://github.com/google/snappy) | Decompression | BSD-3-Clause |
| [godot-cpp](https://github.com/godotengine/godot-cpp) | GDExtension bindings | MIT |

## License

This extension is distributed under the MIT license. See LICENSE.md.
Vendored dependencies carry their own licenses; see `thirdparty/licenses/`.