//! sync.zig — shared Mutex/Condition wrapper for real OS-thread
//! synchronization, used by thread_pool.zig, outer_thread_pool.zig,
//! frame_queue.zig, and decode_scheduler.zig. Previously duplicated
//! near-identically inside thread_pool.zig and outer_thread_pool.zig;
//! extracted here once both pools' need for the same primitive made that
//! duplication a maintenance hazard.
//!
//! Zig 0.16 note: `std.Thread.Mutex`/`std.Thread.Condition` were removed
//! upstream with no direct OS-thread-safe replacement in std
//! (`std.Io.Mutex`/`Io.Condition` require threading an `Io` instance
//! through every call, and the only zero-setup instance std ships,
//! `std.Io.Threaded.global_single_threaded`, is documented as not
//! supporting concurrency at all -- an earlier version of this codebase
//! backed `Mutex`/`Condition` with it anyway, which produced an
//! intermittent shutdown race under real cross-thread contention).
//! `Mutex`/`Condition` below wrap the native OS primitives behind the old
//! infallible, io-free call shape instead -- POSIX
//! `pthread_mutex_t`/`pthread_cond_t` (via `std.c`) on macOS/Linux,
//! SRWLOCK/CONDITION_VARIABLE (via kernel32) on Windows -- which are
//! genuinely safe for real OS threads.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const windows = std.os.windows;

const is_windows = builtin.target.os.tag == .windows;

/// Drop-in replacement for the removed std.Thread.Mutex (see module docs).
pub const Mutex = if (is_windows) WindowsMutex else PosixMutex;

/// Drop-in replacement for the removed std.Thread.Condition (see module
/// docs).
pub const Condition = if (is_windows) WindowsCondition else PosixCondition;

/// Backed directly by a POSIX pthread_mutex_t.
const PosixMutex = struct {
    inner: c.pthread_mutex_t = .{},

    pub fn lock(m: *Mutex) void {
        const rc = c.pthread_mutex_lock(&m.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn unlock(m: *Mutex) void {
        const rc = c.pthread_mutex_unlock(&m.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    /// Releases OS resources held by the mutex. Only needed for
    /// heap-allocated pools that are actually torn down (tests); the
    /// process-lifetime singletons are intentionally never torn down.
    pub fn deinit(m: *Mutex) void {
        _ = c.pthread_mutex_destroy(&m.inner);
    }
};

/// Backed directly by a POSIX pthread_cond_t.
const PosixCondition = struct {
    inner: c.pthread_cond_t = .{},

    pub fn wait(cv: *Condition, mu: *Mutex) void {
        const rc = c.pthread_cond_wait(&cv.inner, &mu.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn notifyOne(cv: *Condition) void {
        const rc = c.pthread_cond_signal(&cv.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn notifyAll(cv: *Condition) void {
        const rc = c.pthread_cond_broadcast(&cv.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    /// See Mutex.deinit.
    pub fn deinit(cv: *Condition) void {
        _ = c.pthread_cond_destroy(&cv.inner);
    }
};

/// Backed directly by a Win32 SRWLOCK (exclusive mode only, matching the
/// POSIX backend's plain-mutex semantics).
const WindowsMutex = struct {
    inner: windows.SRWLOCK = .{},

    pub fn lock(m: *Mutex) void {
        AcquireSRWLockExclusive(&m.inner);
    }

    pub fn unlock(m: *Mutex) void {
        ReleaseSRWLockExclusive(&m.inner);
    }

    /// SRWLOCKs hold no OS resources; present for API parity with the
    /// POSIX backend (see PosixMutex.deinit).
    pub fn deinit(m: *Mutex) void {
        _ = m;
    }
};

/// Backed directly by a Win32 CONDITION_VARIABLE.
const WindowsCondition = struct {
    inner: windows.CONDITION_VARIABLE = .{},

    pub fn wait(cv: *Condition, mu: *Mutex) void {
        // INFINITE timeout; flags 0 = the SRWLOCK is held in exclusive
        // mode. With INFINITE the call can only fail on API misuse.
        const INFINITE: u32 = 0xFFFF_FFFF;
        std.debug.assert(SleepConditionVariableSRW(&cv.inner, &mu.inner, INFINITE, 0) != 0);
    }

    pub fn notifyOne(cv: *Condition) void {
        WakeConditionVariable(&cv.inner);
    }

    pub fn notifyAll(cv: *Condition) void {
        WakeAllConditionVariable(&cv.inner);
    }

    /// CONDITION_VARIABLEs hold no OS resources; see WindowsMutex.deinit.
    pub fn deinit(cv: *Condition) void {
        _ = cv;
    }
};

// -- Windows-only extern bindings ------------------------------------------
//
// std.os.windows declares the SRWLOCK/CONDITION_VARIABLE types but no
// longer wraps these kernel32 entry points, so they are declared directly
// here (same pattern as mmap_reader.zig's file-mapping bindings). Pruned
// at comptime on non-Windows targets.

extern "kernel32" fn AcquireSRWLockExclusive(srw_lock: *windows.SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(srw_lock: *windows.SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn SleepConditionVariableSRW(
    condition_variable: *windows.CONDITION_VARIABLE,
    srw_lock: *windows.SRWLOCK,
    milliseconds: u32,
    flags: u32,
) callconv(.winapi) c_int;
extern "kernel32" fn WakeConditionVariable(condition_variable: *windows.CONDITION_VARIABLE) callconv(.winapi) void;
extern "kernel32" fn WakeAllConditionVariable(condition_variable: *windows.CONDITION_VARIABLE) callconv(.winapi) void;
