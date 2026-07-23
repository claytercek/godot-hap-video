//! ref.zig — shared teardown for RefCounted-derived objects this extension
//! plainly, solely owns (never a pointer merely borrowed for the duration
//! of one call).
//!
//! Every release below follows the same shape: drop our reference and,
//! only if it was the last one (`unreference()` returns true), actually
//! free the instance. Extension-owned instances must use their typed
//! `destroy()` callback so both the engine object and Zig-side fields are
//! released; plain engine objects use the engine object's `destroy()`.
//! Keeping that distinction here prevents call sites from drifting apart.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Release our reference to `obj`, an instance of one of this extension's
/// own classes (a struct with a `base: *Base` field and a typed
/// `destroy(allocator)` method, wired up via `setInstance`) -- freeing it
/// through `T`'s own typed `destroy()` iff this was the last reference.
///
/// Must go through the typed destroy, never `obj.base.destroy()`: the
/// engine-level shortcut frees the Godot Object but trips gdzig's destroy
/// double-free guard, which then skips the extension's free_instance_func
/// (the callback that frees the Zig-side struct) -- silently leaking the
/// struct and any fields it owns (Strings, etc.), even though the engine
/// Object itself is gone.
pub fn releaseAndDestroy(comptime T: type, obj: *T, allocator: *Allocator) void {
    if (obj.base.unreference()) obj.destroy(allocator);
}

/// Release our reference to a plain engine RefCounted object with no Zig
/// struct of our own behind it (for example, a Texture2drd created by the
/// presentation pipeline) -- freeing it iff this was the last reference.
/// There's no typed-vs-base split to get wrong here since the object isn't
/// backed by one of our own `create_instance_func` types to begin with: `destroy()`
/// on the object itself *is* the correct, un-guarded free.
pub fn releaseEngineRef(obj: anytype) void {
    if (obj.unreference()) obj.destroy();
}
