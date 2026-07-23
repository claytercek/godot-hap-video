//! hap_resource_format_loader.zig — .mov ResourceFormatLoader.
//!
//! Registered with ResourceLoader (see extension.zig's LoaderLifecycle) for
//! the ".mov" extension. Does not decode anything here -- it just produces a
//! HapVideoStream resource pointing at the file; decoding happens lazily in
//! the playback.

const HapResourceFormatLoader = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const ResourceFormatLoader = godot.class.ResourceFormatLoader;
const FileAccess = godot.class.FileAccess;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const PackedStringArray = godot.builtin.PackedStringArray;
const Variant = godot.builtin.Variant;

const HapVideoStream = @import("hap_video_stream.zig");
const ref = @import("ref.zig");

const log = std.log.scoped(.hap_resource_format_loader);

pub fn register(r: *Registry) void {
    // Abstract (non-instantiable from GDScript): the loader is a singleton
    // created once, internally, by extension.zig's LoaderLifecycle (via
    // create() directly). Marking it abstract removes the ClassDB `.new()`
    // path -- which would otherwise double-claim the RefCounted base, since
    // create()'s `.init()` legitimately claims the single reference the
    // LoaderLifecycle owns and releases at teardown (see create()).
    r.addClass(HapResourceFormatLoader, r.allocator, .{ .is_abstract = true });
}

pub fn unregister(r: *Registry) void {
    r.removeClass(HapResourceFormatLoader);
}

allocator: Allocator,
base: *ResourceFormatLoader,

pub fn create(allocator: *Allocator) !*HapResourceFormatLoader {
    const self = try allocator.create(HapResourceFormatLoader);
    self.* = .{
        .allocator = allocator.*,
        // Claims RefCounted's initial reference: this is the sole,
        // internal creation path (the class is abstract, so there is no
        // GDScript `.new()` to also claim it -- see register()).
        .base = .init(),
    };
    self.base.setInstance(HapResourceFormatLoader, self);
    return self;
}

pub fn destroy(self: *HapResourceFormatLoader, allocator: *Allocator) void {
    self.base.destroy();
    allocator.destroy(self);
}

pub fn _getRecognizedExtensions(self: *HapResourceFormatLoader) PackedStringArray {
    _ = self;
    var exts = PackedStringArray.init();
    var ext = String.fromLatin1("mov");
    defer ext.deinit();
    _ = exts.append(ext);
    return exts;
}

pub fn _handlesType(self: *HapResourceFormatLoader, p_type: StringName) bool {
    _ = self;
    return p_type.eql(StringName.fromComptimeLatin1("VideoStream"));
}

pub fn _getResourceType(self: *HapResourceFormatLoader, p_path: String) String {
    _ = self;
    var ext = p_path.getExtension();
    defer ext.deinit();
    var mov = String.fromLatin1("mov");
    defer mov.deinit();
    if (ext.eql(mov)) return String.fromLatin1("VideoStream");
    return String.empty;
}

pub fn _load(
    self: *HapResourceFormatLoader,
    p_path: String,
    p_original_path: String,
    p_use_sub_threads: bool,
    p_cache_mode: i32,
) Variant {
    _ = p_original_path;
    _ = p_use_sub_threads;
    _ = p_cache_mode;

    if (!FileAccess.fileExists(p_path)) {
        var buf: [1024]u8 = undefined;
        log.err("File not found: {s}", .{p_path.toUtf8Buf(&buf)});
        return Variant.nil;
    }

    const stream = HapVideoStream.createOwned(&self.allocator) catch return Variant.nil;
    stream.setFile(p_path);

    // Variant.init() takes its own +1 reference on RefCounted objects; the
    // createOwned() call above already gave us a sole owning reference. Release
    // our copy once the Variant holds its own, so exactly one reference
    // survives. This should never be the last reference (see ref.zig), but
    // goes through the same typed-destroy path regardless in case
    // Variant.init() ever fails to take its own.
    const result = Variant.init(*HapVideoStream, stream);
    ref.releaseAndDestroy(HapVideoStream, stream, &self.allocator);
    return result;
}
