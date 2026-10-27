//! .mov ResourceFormatLoader installed by extension.zig's LoaderLifecycle.
//! Creates a HapVideoStream with the file path; playback decodes it lazily.

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
    // Keep the singleton abstract so ClassDB .new() cannot double-claim
    // its initial RefCounted reference. LoaderLifecycle calls create(),
    // owns that reference, and releases it at teardown.
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
        // Claim the initial reference on the sole creation path; the
        // abstract class prevents a second claim through GDScript .new().
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

    // Variant.init() takes a +1 reference. Release the createOwned() ref
    // so only the Variant's remains. Use typed destroy (see ref.zig) even
    // if Variant.init() unexpectedly leaves this as the last reference.
    const result = Variant.init(*HapVideoStream, stream);
    ref.releaseAndDestroy(HapVideoStream, stream, &self.allocator);
    return result;
}
