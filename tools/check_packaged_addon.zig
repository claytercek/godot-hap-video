const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Paths = std.StringHashMap(void);

const manifest = "hap_video.gdextension";
const notices = [_][]const u8{
    "README.md",
    "LICENSE.md",
    "licenses/LICENSE-snappy.txt",
    "licenses/AUTHORS-snappy.txt",
    "licenses/LICENSE-minimp4.txt",
    "licenses/LICENSE-gdzig.txt",
};

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        try Io.File.stderr().writeStreamingAll(init.io, "Usage: check_packaged_addon DIRECTORY\n");
        return 2;
    }
    var diagnostic: []const u8 = args[1];
    checkPath(init.io, init.arena.allocator(), args[1], &diagnostic) catch |err| {
        var stderr = Io.File.stderr().writerStreaming(init.io, &.{});
        try stderr.interface.print("PACKAGE_FAIL: {s}: {s}\n", .{ diagnostic, @errorName(err) });
        return 1;
    };
    try Io.File.stdout().writeStreamingAll(init.io, "PACKAGE_PASS\n");
    return 0;
}

fn checkPath(io: Io, allocator: Allocator, directory: []const u8, diagnostic: *[]const u8) !void {
    const dir = try Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    try check(io, allocator, dir, diagnostic);
}

fn check(io: Io, allocator: Allocator, dir: Io.Dir, diagnostic: *[]const u8) !void {
    diagnostic.* = manifest;
    const info = try dir.statFile(io, manifest, .{ .follow_symlinks = false });
    if (info.kind != .file or info.size == 0) return error.InvalidManifestFile;
    const source = try dir.readFileAlloc(io, manifest, allocator, .limited(1024 * 1024));
    var required: Paths = .init(allocator);
    try addLibraries(allocator, source, &required);
    try required.put(manifest, {});
    for (notices) |notice| try required.put(notice, {});

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        const path = if (Io.Dir.path.sep == '/') entry.path else blk: {
            const copy = try allocator.dupe(u8, entry.path);
            std.mem.replaceScalar(u8, copy, Io.Dir.path.sep, '/');
            break :blk copy;
        };
        verifyEntry(io, entry, path, &required) catch |err| {
            diagnostic.* = try allocator.dupe(u8, path);
            return err;
        };
    }
    var missing = required.keyIterator();
    if (missing.next()) |path| {
        diagnostic.* = path.*;
        return error.MissingPackageFile;
    }
}

fn verifyEntry(io: Io, entry: Io.Dir.Walker.Entry, path: []const u8, required: *Paths) !void {
    if (!required.remove(path)) return error.UnexpectedPackageFile;
    if (entry.kind != .file) return error.NotRegularFile;
    const info = try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false });
    if (info.kind != .file) return error.NotRegularFile;
    if (info.size == 0) return error.EmptyPackageFile;
}

fn addLibraries(allocator: Allocator, source: []const u8, required: *Paths) !void {
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidManifestEncoding;
    const whitespace = " \t\r";
    var sections: Paths = .init(allocator);
    var keys: Paths = .init(allocator);
    var section: []const u8 = "";
    var option_indent: ?usize = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, whitespace);
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        const indent = raw.len - std.mem.trimStart(u8, raw, whitespace).len;
        // A more deeply indented line can continue the previous value.
        if (option_indent != null and indent > option_indent.?) return error.AmbiguousContinuation;
        if (line[0] == '[') {
            if (line.len < 3 or line[line.len - 1] != ']') return error.InvalidSection;
            section = line[1 .. line.len - 1];
            if ((try sections.getOrPut(section)).found_existing) return error.DuplicateSection;
            keys.clearRetainingCapacity();
            option_indent = null;
            continue;
        }
        option_indent = indent;
        const separator = std.mem.indexOfAny(u8, line, "=:") orelse return error.InvalidOption;
        const key = std.mem.trimEnd(u8, line[0..separator], whitespace);
        if (section.len == 0 or key.len == 0) return error.InvalidOption;
        if ((try keys.getOrPut(key)).found_existing) return error.DuplicateOption;
        if (!std.mem.eql(u8, section, "libraries")) continue;

        const encoded = std.mem.trimStart(u8, line[separator + 1 ..], whitespace);
        const path = try std.json.parseFromSliceLeaky([]const u8, allocator, encoded, .{});
        if (path.len == 0 or std.mem.indexOfAny(u8, path, "\\:\x00") != null)
            return error.UnsafeLibraryPath;
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
                return error.UnsafeLibraryPath;
        }
        try required.put(path, {});
    }
    if (required.count() == 0) return error.NoLibraries;
}

const testing = std.testing;
const test_libraries = [_][]const u8{ "bin/video.so", "video.dll", "video.dylib" };

fn writeFixture(dir: Io.Dir, path: []const u8, data: []const u8) !void {
    if (Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(testing.io, parent);
    try dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
}

fn fixture() !testing.TmpDir {
    var tmp = testing.tmpDir(.{ .iterate = true });
    errdefer tmp.cleanup();
    try writeFixture(tmp.dir, manifest,
        \\[configuration]
        \\entry_symbol = "hap_video_init"
        \\[libraries]
        \\linux.debug = "bin/video.so"
        \\linux.release = "bin/video.so"
        \\windows.release = "video.dll"
        \\macos.release = "video.dylib"
    );
    for (notices ++ test_libraries) |path| try writeFixture(tmp.dir, path, "fixture");
    return tmp;
}

fn checkFixture(tmp: testing.TmpDir) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diagnostic: []const u8 = "";
    return check(testing.io, arena.allocator(), tmp.dir, &diagnostic);
}

test "complete package" {
    var tmp = try fixture();
    defer tmp.cleanup();
    try checkFixture(tmp);
}

test "each library and notice must exist and be nonempty" {
    var tmp = try fixture();
    defer tmp.cleanup();
    for (notices ++ test_libraries) |path| {
        try writeFixture(tmp.dir, path, "");
        try testing.expectError(error.EmptyPackageFile, checkFixture(tmp));
        try tmp.dir.deleteFile(testing.io, path);
        try testing.expectError(error.MissingPackageFile, checkFixture(tmp));
        try writeFixture(tmp.dir, path, "fixture");
    }
}

test "unexpected stale file" {
    var tmp = try fixture();
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "old.dll", "stale");
    try testing.expectError(error.UnexpectedPackageFile, checkFixture(tmp));
}

test "invalid UTF-8 anywhere in the manifest is rejected" {
    var tmp = try fixture();
    defer tmp.cleanup();
    try writeFixture(tmp.dir, manifest, "# \xff\n[libraries]\nlinux.debug = \"bin/video.so\"\n");
    try testing.expectError(error.InvalidManifestEncoding, checkFixture(tmp));
}

test "an indented continuation cannot introduce a library" {
    var tmp = try fixture();
    defer tmp.cleanup();
    try writeFixture(tmp.dir, manifest,
        \\[libraries]
        \\linux.debug = "bin/video.so"
        \\  windows.debug = "video.dll"
    );
    try testing.expectError(error.AmbiguousContinuation, checkFixture(tmp));
}

test "unsafe manifest paths" {
    var tmp = try fixture();
    defer tmp.cleanup();
    for ([_][]const u8{
        "\"../outside.dll\"",
        "\"/tmp/outside.dll\"",
        "\"res://outside.dll\"",
        "\"C:\\\\outside.dll\"",
        "\"\"",
    }) |encoded| {
        const source = try std.fmt.allocPrint(testing.allocator, "[libraries]\nwindows.debug = {s}\n", .{encoded});
        defer testing.allocator.free(source);
        try writeFixture(tmp.dir, manifest, source);
        try testing.expectError(error.UnsafeLibraryPath, checkFixture(tmp));
    }
}
