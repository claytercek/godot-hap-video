#!/usr/bin/env python
import os
import sys

from SCons.Action import Action

libname = "hap_video"
projectdir = "addons/hap_video"

localEnv = Environment(tools=["default"], PLATFORM="")

# Build profile - enables only the engine classes we need.
localEnv["build_profile"] = "build_profile.json"

customs = ["custom.py"]
customs = [os.path.abspath(path) for path in customs]

opts = Variables(customs, ARGUMENTS)
opts.Update(localEnv)

Help(opts.GenerateHelpText(localEnv))

env = localEnv.Clone()

# Ensure godot-cpp submodule is present
if not (os.path.isdir("godot-cpp") and os.listdir("godot-cpp")):
    print("godot-cpp is not available. Run: git submodule update --init --recursive")
    sys.exit(1)

# Import godot-cpp build configuration
env = SConscript("godot-cpp/SConstruct", {"env": env, "customs": customs})

# Flat suffix
suffix = env["suffix"].replace(".dev", "").replace(".universal", "")

# -----------------------------------------------------------------------
# Vendored dependency targets
# -----------------------------------------------------------------------
if sys.platform == "win32":
    env.Append(CXXFLAGS=["/std:c++17", "/EHsc", "/W3"])
    env.Append(CCFLAGS=["/W3"])
else:
    env.Append(CXXFLAGS=["-std=c++17", "-Wall", "-Wextra", "-Wno-unused-parameter"])
    env.Append(CCFLAGS=["-Wall", "-Wextra", "-Wno-unused-parameter"])

# hap (C source)
hap_sources = ["thirdparty/hap/hap.c"]
hap_lib = env.StaticLibrary(
    "build/thirdparty/hap/hap",
    hap_sources,
    CPPPATH=["thirdparty/hap", "thirdparty/snappy"],
)

# snappy (C++ sources)
snappy_sources = [
    "thirdparty/snappy/snappy.cc",
    "thirdparty/snappy/snappy-c.cc",
    "thirdparty/snappy/snappy-sinksource.cc",
    "thirdparty/snappy/snappy-stubs-internal.cc",
]
snappy_lib = env.StaticLibrary(
    "build/thirdparty/snappy/snappy",
    snappy_sources,
    CPPPATH=["thirdparty/snappy", "thirdparty/snappy/snappy_config"],
)

# minimp4 (single-header C library; built with 64-bit offset support)
minimp4_lib = env.StaticLibrary(
    "build/thirdparty/minimp4/minimp4",
    ["thirdparty/minimp4/minimp4.c"],
    CPPPATH=["thirdparty/minimp4"],
)

# -----------------------------------------------------------------------
# Extension source files
# -----------------------------------------------------------------------
env.VariantDir("build/src", "src", duplicate=0)

env.Append(CPPPATH=[
    "src/", "src/core", "src/godot",
    "thirdparty/hap", "thirdparty/snappy", "thirdparty/minimp4",
])

sources = [
    "build/src/godot/register_types.cpp",
    "build/src/godot/hap_video_stream.cpp",
    "build/src/godot/hap_video_stream_playback.cpp",
    "build/src/godot/hap_resource_format_loader.cpp",
    "build/src/godot/hap_texture_2d.cpp",
]

# Core sources (currently empty, but directory structure is ready)
core_sources = Glob("build/src/core/*.cpp")
sources.extend(core_sources)

# -----------------------------------------------------------------------
# Shared library
# -----------------------------------------------------------------------
lib_filename = "{}{}{}{}".format(
    env.subst("$SHLIBPREFIX"), libname, suffix, env.subst("$SHLIBSUFFIX"),
)

library = env.SharedLibrary(
    "bin/{}/{}".format(env["platform"], lib_filename),
    source=sources,
    LIBS=[hap_lib, snappy_lib, minimp4_lib] + env.get("LIBS", []),
)

# Install into addon directory
install_dir = "{}/{}/".format(projectdir, env["platform"])
copy = env.Install(install_dir, library)

# -----------------------------------------------------------------------
# Generate .gdextension manifest
# -----------------------------------------------------------------------
def _gen_gdextension(target, source, env):
    plat = env["platform"]
    name = "hap_video"

    if plat in ("macos", "ios"):
        prefix = "lib"
        ext = "dylib"
    elif plat == "windows":
        prefix = ""
        ext = "dll"
    else:
        prefix = "lib"
        ext = "so"

    content = (
        "[configuration]\n"
        "entry_symbol = \"hap_video_init\"\n"
        "compatibility_minimum = 4.4\n"
        "\n"
        "[libraries]\n"
        "{plat}.debug = \"./{plat}/{prefix}{name}.{plat}.template_debug.{ext}\"\n"
        "{plat}.release = \"./{plat}/{prefix}{name}.{plat}.template_release.{ext}\"\n"
    ).format(plat=plat, prefix=prefix, name=name, ext=ext)

    with open(target[0].path, "w") as f:
        f.write(content)

gdextension_config = env.Command(
    target="addons/hap_video/hap_video.gdextension",
    source=[],
    action=Action(_gen_gdextension, "Generating $TARGET"),
)

env.Depends(gdextension_config, library)

Default(library, copy, gdextension_config)

# -----------------------------------------------------------------------
# Core tests (headless, no Godot dependency)
# -----------------------------------------------------------------------
if ARGUMENTS.get("build_tests", "0") == "1":
    test_env = env.Clone()
    test_env.Append(CPPPATH=["tests/core", "src/", "src/core",
                              "thirdparty/hap", "thirdparty/snappy",
                              "thirdparty/minimp4"])
    test_env.Append(CXXFLAGS=["-g", "-O0"])

    test_sources = [
        "tests/core/test_demuxer.cpp",
        "tests/core/test_decoder.cpp",
    ]

    for src in test_sources:
        if not os.path.exists(src):
            continue
        basename = os.path.splitext(os.path.basename(src))[0]
        core_objects = [
            "build/src/core/demuxer.os",
            "build/src/core/decoder.os",
            "build/src/core/mmap_reader.os",
        ]
        test_bin = test_env.Program(
            "build/tests/{}".format(basename),
            [src] + core_objects,
            LIBS=[hap_lib, snappy_lib, minimp4_lib],
        )
        Default(test_bin)

    Alias("core_tests", "build/tests/test_demuxer")