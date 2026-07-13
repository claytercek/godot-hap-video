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
# Vendored dependency include paths (shared by every build variant below)
# -----------------------------------------------------------------------
THIRDPARTY_CPPPATH = ["thirdparty/hap", "thirdparty/snappy", "thirdparty/minimp4"]
HAP_CPPPATH = ["thirdparty/hap", "thirdparty/snappy"]
SNAPPY_CPPPATH = ["thirdparty/snappy", "thirdparty/snappy/snappy_config"]
MINIMP4_CPPPATH = ["thirdparty/minimp4"]

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
    CPPPATH=HAP_CPPPATH,
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
    CPPPATH=SNAPPY_CPPPATH,
)

# minimp4 (single-header C library; built with 64-bit offset support)
minimp4_lib = env.StaticLibrary(
    "build/thirdparty/minimp4/minimp4",
    ["thirdparty/minimp4/minimp4.c"],
    CPPPATH=MINIMP4_CPPPATH,
)

# -----------------------------------------------------------------------
# Extension source files
# -----------------------------------------------------------------------
env.VariantDir("build/src", "src", duplicate=0)

env.Append(CPPPATH=["src/", "src/core", "src/godot"] + THIRDPARTY_CPPPATH)

sources = Glob("build/src/godot/*.cpp") + Glob("build/src/core/*.cpp")

# -----------------------------------------------------------------------
# Shared library
# -----------------------------------------------------------------------
lib_filename = "lib{}{}{}".format(
    libname, suffix, env.subst("$SHLIBSUFFIX"),
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
# The manifest always lists every shipped platform (not just the one being
# built) so the addon directory is drop-in complete once the per-platform
# binaries are assembled. Filenames must match the flat suffix above:
# ".universal" is stripped on macOS, but linux/windows keep their arch.
def _gen_gdextension(target, source, env):
    name = "hap_video"
    lines = [
        "[configuration]",
        'entry_symbol = "hap_video_init"',
        "compatibility_minimum = 4.4",
        "",
        "[libraries]",
    ]
    for key, path in (
        ("macos.debug", "./macos/lib{n}.macos.template_debug.dylib"),
        ("macos.release", "./macos/lib{n}.macos.template_release.dylib"),
        ("windows.debug.x86_64", "./windows/lib{n}.windows.template_debug.x86_64.dll"),
        ("windows.release.x86_64", "./windows/lib{n}.windows.template_release.x86_64.dll"),
        ("windows.debug.arm64", "./windows/lib{n}.windows.template_debug.arm64.dll"),
        ("windows.release.arm64", "./windows/lib{n}.windows.template_release.arm64.dll"),
        ("linux.debug.x86_64", "./linux/lib{n}.linux.template_debug.x86_64.so"),
        ("linux.release.x86_64", "./linux/lib{n}.linux.template_release.x86_64.so"),
        ("linux.debug.arm64", "./linux/lib{n}.linux.template_debug.arm64.so"),
        ("linux.release.arm64", "./linux/lib{n}.linux.template_release.arm64.so"),
    ):
        lines.append('{} = "{}"'.format(key, path.format(n=name)))

    with open(target[0].path, "w") as f:
        f.write("\n".join(lines) + "\n")

gdextension_config = env.Command(
    target="addons/hap_video/hap_video.gdextension",
    source=[],
    action=Action(_gen_gdextension, "Generating $TARGET"),
)

env.Depends(gdextension_config, library)

# -----------------------------------------------------------------------
# Bundle licenses into the addon (extension + statically linked deps)
# -----------------------------------------------------------------------
license_files = [
    env.InstallAs("{}/LICENSE.md".format(projectdir), "LICENSE.md"),
    env.InstallAs(
        "{}/licenses/LICENSE-godot-cpp.txt".format(projectdir),
        "godot-cpp/LICENSE.md",
    ),
]
for lic in Glob("thirdparty/licenses/*"):
    license_files.append(env.Install("{}/licenses/".format(projectdir), lic))

Default(library, copy, gdextension_config, license_files)

# -----------------------------------------------------------------------
# Core tests (headless, no Godot dependency)
# -----------------------------------------------------------------------
test_sources = [
    "tests/core/test_demuxer.cpp",
    "tests/core/test_decoder.cpp",
    "tests/core/test_concurrency.cpp",
    "tests/core/test_scheduler.cpp",
    "tests/core/test_playback_pump.cpp",
    "tests/core/test_fuzz_regressions.cpp",
]

# Extra compiler/linker flags for the sanitizer build_tests variants and the
# fuzz=1 harness below. Every variant recompiles the core sources and the
# vendored static libs from scratch (rather than reusing the plain build's
# build/src/core/*.os) so the instrumentation actually covers demuxer,
# minimp4, hap.c, and snappy -- not just the newly-compiled test/harness file.
SANITIZE_FLAGS = {
    # Bundled per spec: ASan + UBSan, abort (don't just warn) on first UB.
    "asan_ubsan": ["-fsanitize=address,undefined",
                   "-fno-sanitize-recover=all",
                   "-fno-omit-frame-pointer"],
    # Separate build: scheduler/queue/ring focus.
    "tsan": ["-fsanitize=thread"],
}


def _variant_env(label, extra_flags, use_clang=False):
    v_env = env.Clone()
    if use_clang:
        v_env["CC"] = ARGUMENTS.get("CC", "clang")
        v_env["CXX"] = ARGUMENTS.get("CXX", "clang++")
    # godot-cpp strips symbols by default (debug_symbols defaults to
    # dev_build, not to target=template_debug) via a bare "-s" LINKFLAGS.
    # Crash/leak/race reports are useless without symbols, so drop it.
    v_env["LINKFLAGS"] = [f for f in v_env["LINKFLAGS"] if f != "-s"]
    v_env.Append(CCFLAGS=["-g", "-O1"] + extra_flags)
    v_env.Append(CXXFLAGS=["-g", "-O1"] + extra_flags)
    v_env.Append(LINKFLAGS=["-g"] + extra_flags)
    v_env.Append(CPPPATH=["src/", "src/core"] + THIRDPARTY_CPPPATH)
    if sys.platform != "win32":
        v_env.Append(LIBS=["pthread"])
    return v_env


def _variant_libs(v_env, label):
    # Recompile the vendored libs from a variant-private VariantDir too --
    # otherwise their object files collide with the plain (non-instrumented)
    # build's objects, which live next to the source since thirdparty/ isn't
    # under the top-level "build/src" VariantDir.
    variant_thirdparty = "build/{}/thirdparty_src".format(label)
    v_env.VariantDir(variant_thirdparty, "thirdparty", duplicate=0)

    def _vp(path):
        return path.replace("thirdparty/", variant_thirdparty + "/", 1)

    hap = v_env.StaticLibrary(
        "build/{}/thirdparty/hap/hap".format(label),
        [_vp(p) for p in hap_sources],
        CPPPATH=HAP_CPPPATH,
    )
    snappy = v_env.StaticLibrary(
        "build/{}/thirdparty/snappy/snappy".format(label),
        [_vp(p) for p in snappy_sources],
        CPPPATH=SNAPPY_CPPPATH,
    )
    minimp4 = v_env.StaticLibrary(
        "build/{}/thirdparty/minimp4/minimp4".format(label),
        [_vp("thirdparty/minimp4/minimp4.c")], CPPPATH=MINIMP4_CPPPATH,
    )
    return [hap, snappy, minimp4]


def _variant_core_sources(v_env, label):
    v_env.VariantDir("build/{}/core".format(label), "src/core", duplicate=0)
    return Glob("build/{}/core/*.cpp".format(label))


if ARGUMENTS.get("build_tests", "0") == "1":
    sanitize = ARGUMENTS.get("sanitize", "")

    if sanitize:
        if sanitize not in SANITIZE_FLAGS:
            print("Unknown sanitize= value '{}' (expected: {})".format(
                sanitize, ", ".join(sorted(SANITIZE_FLAGS))))
            Exit(1)
        if sys.platform == "win32":
            print("sanitize= is only supported on Linux/macOS")
            Exit(1)

        label = "sanitize_{}".format(sanitize)
        test_env = _variant_env(label, SANITIZE_FLAGS[sanitize])
        test_env.Append(CPPPATH=["tests/core"])
        test_libs = _variant_libs(test_env, label)
        core_objects = _variant_core_sources(test_env, label)
    else:
        test_env = env.Clone()
        test_env.Append(CPPPATH=["tests/core", "src/", "src/core"] + THIRDPARTY_CPPPATH)
        test_env.Append(CXXFLAGS=["-g", "-O0"])
        if sys.platform != "win32":
            test_env.Append(LIBS=["pthread"])

        test_libs = [hap_lib, snappy_lib, minimp4_lib]
        # Reuse the already-built (non-instrumented) core objects from the
        # main SharedLibrary build above instead of recompiling -- same
        # Glob source as line ~95, but matching the compiled objects rather
        # than the .cpp sources, since $SHOBJSUFFIX is what SharedLibrary
        # actually produced them as (".os" on POSIX, ".obj" on MSVC).
        # Must use test_env.Glob (not the bare global Glob), since on MSVC
        # SHOBJSUFFIX is the literal unresolved string "$OBJSUFFIX" -- the
        # global Glob() deliberately skips variable substitution, so it'd
        # glob for a file literally named "*$OBJSUFFIX" and silently match
        # nothing.
        core_objects = test_env.Glob("build/src/core/*" + env["SHOBJSUFFIX"])

    test_targets = []
    for src in test_sources:
        if not os.path.exists(src):
            print("Missing test source: {}".format(src))
            Exit(1)
        basename = os.path.splitext(os.path.basename(src))[0]
        test_bin = test_env.Program(
            "build/tests/{}".format(basename),
            [src] + core_objects,
            LIBS=test_libs,
        )
        Default(test_bin)
        test_targets.append(test_bin)

    Alias("core_tests", test_targets)

# -----------------------------------------------------------------------
# Fuzz harness (libFuzzer + ASan, demuxer open/parse path only)
# -----------------------------------------------------------------------
if ARGUMENTS.get("fuzz", "0") == "1":
    if sys.platform == "win32":
        print("fuzz=1 is only supported on Linux/macOS with clang")
        Exit(1)
    if sys.platform == "linux" and ARGUMENTS.get("use_llvm", "no") != "yes":
        # godot-cpp's linux.py only skips its GCC-only -fno-gnu-unique flag
        # (unknown to clang) when use_llvm=yes is passed at the top level;
        # overriding CC/CXX after the fact doesn't undo that already-appended
        # flag, so libFuzzer (clang-only) needs the real thing.
        print("fuzz=1 requires use_llvm=yes on Linux (libFuzzer needs clang)")
        Exit(1)

    fuzz_label = "fuzz"
    fuzz_env = _variant_env(fuzz_label, ["-fsanitize=fuzzer,address"], use_clang=True)
    fuzz_libs = _variant_libs(fuzz_env, fuzz_label)
    fuzz_core_sources = _variant_core_sources(fuzz_env, fuzz_label)

    fuzz_bin = fuzz_env.Program(
        "build/fuzz/fuzz_demuxer",
        ["tests/fuzz/fuzz_demuxer.cpp"] + fuzz_core_sources,
        LIBS=fuzz_libs,
    )
    Default(fuzz_bin)
    Alias("fuzz", fuzz_bin)