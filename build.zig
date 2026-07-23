const std = @import("std");
const Build = std.Build;
const gdzig = @import("gdzig");

// Downloaded by gdzig for bindgen when no local Godot binary is available.
// A local executable still wins via -Dgodot-path or GODOT_PATH.
const default_godot_version = "4.6";

const common_warn_flags = [_][]const u8{ "-Wall", "-Wextra", "-Wno-unused-parameter" };

// Wires up the vendored C/C++ (hap, minimp4, snappy) that core.zig wraps
// with hand-written `extern fn` declarations, shared between the shipped
// core module and the test-only one (see build()'s `core_test_mod`).
fn addCoreCSources(b: *Build, mod: *Build.Module) void {
    mod.addIncludePath(b.path("thirdparty/hap"));
    mod.addIncludePath(b.path("thirdparty/minimp4"));
    mod.addIncludePath(b.path("thirdparty/snappy"));
    mod.addIncludePath(b.path("thirdparty/snappy/snappy_config"));

    mod.addCSourceFiles(.{
        .files = &.{
            "thirdparty/hap/hap.c",
            "thirdparty/minimp4/minimp4.c",
            "src/core/minimp4_shim.c",
        },
        .flags = &common_warn_flags,
    });

    mod.addCSourceFiles(.{
        .files = &.{
            "thirdparty/snappy/snappy.cc",
            "thirdparty/snappy/snappy-c.cc",
            "thirdparty/snappy/snappy-sinksource.cc",
            "thirdparty/snappy/snappy-stubs-internal.cc",
        },
        .flags = &(common_warn_flags ++ [_][]const u8{ "-std=c++17", "-DHAVE_CONFIG_H=1" }),
    });
}

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast;
    const test_optimize = b.option(std.builtin.OptimizeMode, "test-optimize", "Optimization mode for the core test suite") orelse .Debug;
    const env_godot = b.graph.environ_map.get("GODOT_PATH");
    const opt_godot_path = b.option([]const u8, "godot-path", "Path to a Godot executable") orelse env_godot;
    const opt_godot_version = b.option([]const u8, "godot-version", "Godot version to download for bindgen (e.g. `4.6`)");

    // Sanitizer knobs for the core test suite only (see
    // .github/workflows/sanitizers.yml for what's actually wired into CI,
    // and that file's header comment for what zig 0.16 does and doesn't
    // support here). Not applied to the Godot extension build.
    const tsan = b.option(bool, "tsan", "Enable ThreadSanitizer on the core test build") orelse false;
    const sanitize_c = b.option(std.zig.SanitizeC, "sanitize-c", "UBSan mode for the core test build's C sources (off/trap/full)") orelse .off;

    // --- Core: pure Zig plus the vendored C libraries (hap, snappy,
    // minimp4) it wraps with hand-written `extern fn` declarations. ---
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });

    addCoreCSources(b, core_mod);

    // The test suite has its own optimization mode so extension builds can
    // stay ReleaseFast while ordinary tests default to runtime-safe Debug.
    // Local fuzzing can opt into ReleaseFast without silently changing the
    // extension build through -Dtest-optimize=ReleaseFast.
    const core_test_mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libcpp = true,
        .sanitize_thread = tsan,
        .sanitize_c = sanitize_c,
    });
    addCoreCSources(b, core_test_mod);

    const core_tests = b.addTest(.{ .root_module = core_test_mod });
    const test_step = b.step("test", "Run core unit tests (no Godot needed)");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // --- Godot extension: gdzig glue. ---
    // Explicit path > explicit version > downloaded default version.
    const gdzig_dep = if (opt_godot_path) |path| b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .@"godot-path" = path,
    }) else b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .@"godot-version" = opt_godot_version orelse default_godot_version,
    });

    const ext_mod = b.createModule(.{
        .root_source_file = b.path("src/godot/extension.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "godot", .module = gdzig_dep.module("gdzig") },
            .{ .name = "core", .module = core_mod },
        },
    });

    const extension = gdzig.addExtension(b, .{
        .name = "hap_video",
        .root_module = ext_mod,
        .entry_symbol = "hap_video_init",
        .minimum_initialization_level = .scene,
        .target = target,
        .optimize = optimize,
    }) orelse return;

    if (optimize != .Debug) {
        extension.compile.root_module.strip = true;
        extension.compile.link_gc_sections = true;
    }

    // Keep development output isolated from the distributable addon template.
    const install = b.addInstallFileWithDir(extension.output, .{ .custom = "../project/lib" }, extension.filename);
    b.default_step.dependOn(&install.step);

    const run = Build.Step.Run.create(b, "run Godot demo");
    run.addFileArg(gdzig_dep.namedLazyPath("godot"));
    run.addArg("--path");
    run.addDirectoryArg(b.path("project"));
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    run.step.dependOn(&install.step);
    b.step("run", "Run the development demo project in Godot (forwards -- <args>)").dependOn(&run.step);

    const smoke = Build.Step.Run.create(b, "open and present the bundled Hap fixture in Godot");
    smoke.addFileArg(gdzig_dep.namedLazyPath("godot"));
    // The smoke opens and presents a real Hap frame, so it needs a rendering
    // driver; Godot's headless mode has no RenderingDevice.
    smoke.addArg("--path");
    smoke.addDirectoryArg(b.path("project"));
    smoke.addArg("res://smoke.tscn");
    smoke.step.dependOn(&install.step);
    b.step("smoke", "Load the extension and instantiate its public Godot classes").dependOn(&smoke.step);
}
