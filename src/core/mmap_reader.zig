//! mmap_reader.zig
//!
//! Read-only memory-mapped file view. `init` opens and maps the file;
//! `deinit` unmaps it. An empty file is a valid, successful open whose
//! `data` is an empty slice; a missing/unreadable file, a failed `fstat`,
//! or a failed `mmap` are all reported as errors.
//!
//! Design notes:
//!   * Failures are reported via a Zig error union.
//!   * `path` is stored as a borrowed slice: the caller must keep the string
//!     backing it alive for the reader's lifetime.
//!   * `MmapReader` is a plain struct; call `deinit` yourself when replacing
//!     or dropping one, since Zig has no destructors.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const MmapReader = struct {
    /// Read-only view of the mapped file contents. Empty for a zero-byte
    /// file, which is still a successful open.
    data: []const u8 = &.{},

    /// The path this reader was opened with (borrowed, see module docs).
    path: []const u8 = "",

    pub const InitError = error{
        OpenFailed,
        StatFailed,
        MmapFailed,
    };

    /// Open and memory-map the file at `path`.
    pub fn init(path: []const u8) InitError!MmapReader {
        return if (builtin.os.tag == .windows)
            initWindows(path)
        else
            initPosix(path);
    }

    /// Unmap the file, if mapped. Safe to call on a zero-value/empty reader.
    pub fn deinit(self: *MmapReader) void {
        if (self.data.len == 0) {
            self.* = .{};
            return;
        }

        if (builtin.os.tag == .windows) {
            _ = UnmapViewOfFile(@ptrCast(self.data.ptr));
        } else {
            const aligned: []align(std.heap.page_size_min) const u8 = @alignCast(self.data);
            posix.munmap(aligned);
        }

        self.* = .{};
    }

    fn initPosix(path: []const u8) InitError!MmapReader {
        const fd = posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch {
            return InitError.OpenFailed;
        };
        defer _ = std.c.close(fd);

        const size: usize = @intCast(fstatSize(fd) catch {
            return InitError.StatFailed;
        });

        if (size == 0) {
            return .{ .data = &.{}, .path = path };
        }

        const mapped = posix.mmap(
            null,
            size,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch {
            return InitError.MmapFailed;
        };

        return .{ .data = mapped, .path = path };
    }

    /// Size in bytes of an already-open file descriptor, cross-platform.
    ///
    /// zig 0.16's `std.c` deliberately stubs `fstat`/`fstatat` out to `void`
    /// on Linux (see std/c.zig: `.linux => {}`) rather than exposing glibc's
    /// versioned fstat symbols, so the `std.c.fstat` call this used on macOS
    /// doesn't exist as a callable decl there. The blessed 0.16 replacement
    /// is `std.Io.File.stat`, but that requires an `Io` instance, and the
    /// only zero-setup one std ships (`std.Io.Threaded.global_single_threaded`)
    /// is documented as not supporting concurrency -- this codebase already
    /// hit a real bug from using it on a path that runs on real concurrent
    /// OS threads (see sync.zig's module doc), and `MmapReader.init` is
    /// called from decode_scheduler.zig, which is exactly such a path. So
    /// Linux goes through a direct, dependency-free `statx(2)` syscall via
    /// `std.os.linux.statx` instead (fd-only, `AT.EMPTY_PATH`, `STATX.SIZE`),
    /// which needs neither libc nor the Io framework.
    fn fstatSize(fd: posix.fd_t) !u64 {
        if (builtin.os.tag == .linux) {
            const linux = std.os.linux;
            var stx: linux.Statx = undefined;
            const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx);
            if (linux.errno(rc) != .SUCCESS) return error.StatFailed;
            return stx.size;
        }

        var st: std.c.Stat = undefined;
        if (posix.errno(std.c.fstat(fd, &st)) != .SUCCESS) return error.StatFailed;
        return @intCast(st.size);
    }

    fn initWindows(path: []const u8) InitError!MmapReader {
        const windows = std.os.windows;

        // ANSI CreateFileA because `path` is a narrow UTF-8 byte slice;
        // non-ASCII Windows paths are a known limitation. MAX_PATH (not
        // PATH_MAX_WIDE, which sizes the `\\?\`-prefixed wide-char API) is
        // the correct narrow-path limit for this ANSI call.
        var path_buf: [windows.MAX_PATH]u8 = undefined;
        if (path.len >= path_buf.len) return InitError.OpenFailed;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf);

        const handle = CreateFileA(
            path_z,
            GENERIC_READ,
            FILE_SHARE_READ,
            null,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) return InitError.OpenFailed;
        defer _ = CloseHandle(handle);

        var file_size: i64 = undefined;
        if (GetFileSizeEx(handle, &file_size) == 0) return InitError.StatFailed;
        const size: usize = @intCast(file_size);

        if (size == 0) {
            return .{ .data = &.{}, .path = path };
        }

        const mapping = CreateFileMappingA(handle, null, PAGE_READONLY, 0, 0, null);
        if (mapping == null) return InitError.MmapFailed;
        defer _ = CloseHandle(mapping);

        const view = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0);
        if (view == null) return InitError.MmapFailed;

        const data_ptr: [*]const u8 = @ptrCast(view.?);
        return .{ .data = data_ptr[0..size], .path = path };
    }
};

// -- Windows-only extern bindings ------------------------------------------
//
// std.os.windows no longer wraps these Win32 file-API calls or exposes
// their flat constants (zig 0.16 keeps only typed wrappers like
// ACCESS_MASK), so both are declared directly here. Pruned at comptime on
// non-Windows targets; exercised by the cross-compiled Windows builds.

const GENERIC_READ: u32 = 0x8000_0000;
const FILE_SHARE_READ: u32 = 0x01;
const OPEN_EXISTING: u32 = 3;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const PAGE_READONLY: u32 = 0x02;
const FILE_MAP_READ: u32 = 0x0004;

extern "kernel32" fn CreateFileA(
    lpFileName: [*:0]const u8,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;

extern "kernel32" fn GetFileSizeEx(
    hFile: ?*anyopaque,
    lpFileSize: *i64,
) callconv(.winapi) c_int;

extern "kernel32" fn CreateFileMappingA(
    hFile: ?*anyopaque,
    lpFileMappingAttributes: ?*anyopaque,
    flProtect: u32,
    dwMaximumSizeHigh: u32,
    dwMaximumSizeLow: u32,
    lpName: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;

extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: ?*anyopaque,
    dwDesiredAccess: u32,
    dwFileOffsetHigh: u32,
    dwFileOffsetLow: u32,
    dwNumberOfBytesToMap: usize,
) callconv(.winapi) ?*anyopaque;

extern "kernel32" fn UnmapViewOfFile(
    lpBaseAddress: ?*const anyopaque,
) callconv(.winapi) c_int;

extern "kernel32" fn CloseHandle(
    hObject: ?*anyopaque,
) callconv(.winapi) c_int;

const repo_root_hap1_mov = "tests/fixtures/hap1.mov";

test "init maps a real fixture file and reads its MP4 box header" {
    var reader = try MmapReader.init(repo_root_hap1_mov);
    defer reader.deinit();

    try std.testing.expect(reader.data.len > 0);
    // ISO base media file format: a 4-byte big-endian box size followed by a
    // 4-byte box type. The first box in a .mov is typically "ftyp".
    try std.testing.expectEqualSlices(u8, "ftyp", reader.data[4..8]);
}

test "init fails for a nonexistent file" {
    const result = MmapReader.init("tests/fixtures/does_not_exist.mov");
    try std.testing.expectError(MmapReader.InitError.OpenFailed, result);
}

test "deinit on a zero-value reader is a no-op" {
    var reader: MmapReader = .{};
    reader.deinit();
    try std.testing.expectEqual(@as(usize, 0), reader.data.len);
}
