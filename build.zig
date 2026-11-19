const std = @import("std");
const Build = std.Build;
const gdzig = @import("gdzig");

const common_warn_flags = [_][]const u8{ "-Wall", "-Wextra", "-Wno-unused-parameter" };

// Add minimp4 and snappy to the shipped and test core modules.
// core.zig calls them through hand-written `extern fn` declarations.
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

    // Snappy selects SSSE3/BMI2 at compile time, with no runtime CPU dispatch.
    // Use matching codegen flags on x86_64; aarch64 enables NEON via __ARM_NEON.
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

fn testSmokeCli(b: *Build, runner: *Build.Step.Compile, test_step: *Build.Step) void {
    const child = b.addExecutable(.{ .name = "fake-godot", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/fake_godot.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "smoke", .module = runner.root_module }},
    }) });
    const integration = b.addExecutable(.{ .name = "smoke-cli-test", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/smoke_cli.zig"),
        .target = b.graph.host,
    }) });
    const Mode = enum { pass, exit, timeout };
    for (std.enums.values(Mode)) |mode| {
        const run = b.addRunArtifact(integration);
        run.setCwd(b.path("."));
        run.addArtifactArg(runner);
        run.addArtifactArg(child);
        run.addArg(@tagName(mode));
        _ = run.addOutputDirectoryArg(@tagName(mode));
        run.expectExitCode(0);
        test_step.dependOn(&run.step);
    }
}

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .fast;
    const test_optimize = b.option(std.builtin.OptimizeMode, "test-optimize", "Optimization mode for the core test suite") orelse .debug;
    const env_godot = b.graph.environ_map.get("GODOT_PATH");
    // Upstream ships the binding API/header; only run/smoke need Godot.
    // A fallback name bypasses configure-time lookup for tests and cross-builds.
    const godot_path = b.option([]const u8, "godot-path", "Path to a Godot executable (run/smoke only)") orelse
        env_godot orelse b.findProgram(.{ .names = &.{"godot"} }) orelse "godot";

    // Apply sanitizers only to core tests, never the extension.
    // See .github/workflows/sanitizers.yml for CI lanes and their limits.
    const tsan = b.option(bool, "tsan", "Enable ThreadSanitizer on the core test build") orelse false;
    const sanitize_c = b.option(std.zig.SanitizeC, "sanitize-c", "UBSan mode for the core test build's C sources (off/trap/full)") orelse .off;

    // Core: Zig with vendored hap, snappy, and minimp4 via `extern fn`.
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });

    addCoreCSources(b, core_mod, target);

    // Tests default to runtime-safe debug independently of extension builds.
    // Local fuzzing can use -Dtest-optimize=fast without changing the extension.
    const core_test_mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libcpp = true,
        .sanitize_thread = tsan,
        .sanitize_c = sanitize_c,
    });
    addCoreCSources(b, core_test_mod, target);

    const test_step = b.step("test", "Run core, fixture, and validation tool tests (no Godot needed)");
    const core_tests = b.addRunArtifact(b.addTest(.{ .root_module = core_test_mod }));
    core_tests.setCwd(b.path("."));
    // Tests read LFS fixtures at runtime, outside the compiler's cache key.
    core_tests.has_side_effects = true;
    test_step.dependOn(&core_tests.step);
    b.step("test-core", "Run core and fixture tests only").dependOn(&core_tests.step);

    const smoke_mod = b.createModule(.{
        .root_source_file = b.path("tools/smoke.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    const package_check_mod = b.createModule(.{
        .root_source_file = b.path("tools/check_packaged_addon.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    for ([_]*Build.Module{ smoke_mod, package_check_mod }) |module| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    }
    const smoke_exe = b.addExecutable(.{ .name = "smoke", .root_module = smoke_mod });
    testSmokeCli(b, smoke_exe, test_step);

    // Benchmark open/close/decode without Godot, using the shipped core_mod
    // optimization mode rather than core_test_mod.
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

    const smoke = b.addRunArtifact(smoke_exe);
    smoke.setCwd(b.path("."));
    smoke.addArgs(&.{ "--godot", godot_path, "--audio" });
    smoke.addPassthruArgs();
    smoke.has_side_effects = true;
    smoke.step.dependOn(&install.step);
    b.step("smoke", "Run rendered Godot video and PCM smoke tests").dependOn(&smoke.step);
    b.step("audio-smoke", "Alias for smoke").dependOn(&smoke.step);
}
