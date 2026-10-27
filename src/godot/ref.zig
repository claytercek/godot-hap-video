//! Release owned RefCounted references; never pass call-scoped borrows.
//! Destroy an instance only when unreference() returns true (the last ref).
//! Extension classes require typed destroy() to free Godot and Zig state;
//! plain engine objects use the engine's destroy().

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Release an extension-class reference; call T.destroy(allocator) on the
/// last ref. T must have base: *Base and a typed destroy wired by setInstance.
///
/// Never call obj.base.destroy() here. It frees the Godot Object but trips
/// gdzig's double-free guard, which skips free_instance_func and leaks the
/// Zig struct and owned fields such as Strings.
pub fn releaseAndDestroy(comptime T: type, obj: *T, allocator: *Allocator) void {
    if (obj.base.unreference()) obj.destroy(allocator);
}

/// Release a plain engine RefCounted reference (for example, Texture2drd).
/// Destroy it on the last ref. These objects have no extension Zig struct
/// or create_instance_func, so the engine's destroy() frees them directly.
pub fn releaseEngineRef(obj: anytype) void {
    if (obj.unreference()) obj.destroy();
}
