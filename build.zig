const std = @import("std");
const Build = std.Build;
const gdzig = @import("gdzig");

const common_warn_flags = [_][]const u8{ "-Wall", "-Wextra", "-Wno-unused-parameter" };

// Wires up the vendored C/C++ (minimp4, snappy) that core.zig wraps with
// hand-written `extern fn` declarations, shared between the shipped core
// module and the test-only one (see build()'s `core_test_mod`).
fn addCoreCSources(b: *Build, mod: *Build.Module, target: Build.ResolvedTarget) void {
    mod.addIncludePath(b.path("thirdparty/minimp4"));
    mod.addIncludePath(b.path("thirdparty/snappy"));
    mod.addIncludePath(b.path("thirdparty/snappy/snappy_config"));

    mod.addCSourceFiles(.{
        .files = &.{
            "thirdparty/minimp4/minimp4.c",
            "src/core/minimp4_shim.c",
        },
        .flags = &common_warn_flags,
    });

    // Snappy has no runtime CPU dispatch: SSSE3/BMI2 decode is purely
    // compile-time gated, so it must be paired with the matching codegen
    // flag. Scoped to x86_64 only; aarch64 already gets NEON for free via
    // __ARM_NEON.
    const snappy_arch_flags: []const []const u8 = switch (target.result.cpu.arch) {
        .x86_64 => &.{ "-mssse3", "-mbmi2" },
        else => &.{},
    };
    var snappy_flags = std.ArrayList([]const u8).initCapacity(
        b.allocator,
        common_warn_flags.len + 2 + snappy_arch_flags.len,
    ) catch @panic("OOM");
    snappy_flags.appendSliceAssumeCapacity(&common_warn_flags);
    snappy_flags.appendSliceAssumeCapacity(&.{ "-std=c++17", "-DHAVE_CONFIG_H=1" });
    snappy_flags.appendSliceAssumeCapacity(snappy_arch_flags);

    mod.addCSourceFiles(.{
        .files = &.{
            "thirdparty/snappy/snappy.cc",
            "thirdparty/snappy/snappy-c.cc",
            "thirdparty/snappy/snappy-sinksource.cc",
            "thirdparty/snappy/snappy-stubs-internal.cc",
        },
        .flags = snappy_flags.items,
    });
}

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .fast;
    const test_optimize = b.option(std.builtin.OptimizeMode, "test-optimize", "Optimization mode for the core test suite") orelse .debug;
    const env_godot = b.graph.environ_map.get("GODOT_PATH");
    // Upstream ships its binding API/header: only run/smoke need an executable.
    // Pass a fallback name to keep upstream's configure-time lookup from
    // requiring Godot for core tests and cross-compilation.
    const godot_path = b.option([]const u8, "godot-path", "Path to a Godot executable (run/smoke only)") orelse
        env_godot orelse b.findProgram(.{ .names = &.{"godot"} }) orelse "godot";

    // Sanitizer knobs for the core test suite only (see
    // .github/workflows/sanitizers.yml for what's actually wired into CI,
    // and that file's header comment for what Zig 0.17 does and doesn't
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

    addCoreCSources(b, core_mod, target);

    // The test suite has its own optimization mode so extension builds can
    // stay fast while ordinary tests default to runtime-safe debug.
    // Local fuzzing can opt into fast without silently changing the
    // extension build through -Dtest-optimize=fast.
    const core_test_mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libcpp = true,
        .sanitize_thread = tsan,
        .sanitize_c = sanitize_c,
    });
    addCoreCSources(b, core_test_mod, target);

    const core_tests = b.addTest(.{ .root_module = core_test_mod });
    const test_step = b.step("test", "Run core unit tests (no Godot needed)");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // --- Bench: standalone open/close/decode benchmark, no Godot needed.
    // Reuses core_mod (not core_test_mod) so numbers reflect the same
    // fast build that ships in the extension. ---
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
        },
    });

    const bench_exe = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addPassthruArgs();
    b.step("bench", "Run decode/open/close benchmarks").dependOn(&run_bench.step);

    // --- Godot extension: gdzig glue. ---
    const gdzig_dep = b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .@"godot-path" = godot_path,
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

    if (optimize != .debug) {
        extension.compile.root_module.strip = true;
        extension.compile.link_gc_sections = true;
    }

    // Keep development output isolated from the distributable addon template.
    const install = b.addInstallFileWithDir(extension.output, .{ .custom = "../project/lib" }, extension.filename);
    b.default_step.dependOn(&install.step);

    const run = Build.Step.Run.create(b, "run Godot demo");
    run.addArg(godot_path);
    run.addArg("--path");
    run.addDirectoryArg(b.path("project"));
    run.addArg("--");
    run.addPassthruArgs();
    run.step.dependOn(&install.step);
    b.step("run", "Run the development demo project in Godot (forwards -- <args>)").dependOn(&run.step);

    const smoke = Build.Step.Run.create(b, "open and present the bundled Hap fixture in Godot");
    smoke.addArg(godot_path);
    // The smoke opens and presents a real Hap frame, so it needs a rendering
    // driver; Godot's headless mode has no RenderingDevice.
    smoke.addArg("--path");
    smoke.addDirectoryArg(b.path("project"));
    smoke.addArg("res://smoke.tscn");
    // Godot can exit successfully after a script fails to load. Require the
    // end-of-test marker, and rerun even when the extension is unchanged.
    smoke.expectStdOutMatch("SMOKE: Hap fixture opened, played, sought, cleared, and rejected synchronous/asynchronous invalid replacements");
    smoke.has_side_effects = true;
    smoke.step.dependOn(&install.step);
    b.step("smoke", "Load the extension and instantiate its public Godot classes").dependOn(&smoke.step);
}
