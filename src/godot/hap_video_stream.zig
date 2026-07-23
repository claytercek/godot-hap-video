//! hap_video_stream.zig — the HapVideoStream VideoStream resource.
//!
//! A VideoStream resource carrying a file path; a stock VideoStreamPlayer
//! holds one of these and calls _instantiatePlayback() to obtain a
//! HapVideoStreamPlayback bound to it.

const HapVideoStream = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const VideoStream = godot.class.VideoStream;
const VideoStreamPlayback = godot.class.VideoStreamPlayback;
const String = godot.builtin.String;

const HapVideoStreamPlayback = @import("hap_video_stream_playback.zig");
const ref = @import("ref.zig");

const log = std.log.scoped(.hap_video_stream);

pub fn register(r: *Registry) void {
    const class = r.createClass(HapVideoStream, r.allocator, .auto);
    class.addProperty("file", .{
        .hint = .property_hint_file,
        .hint_string = String.fromLatin1("*.mov"),
    });
}

pub fn unregister(r: *Registry) void {
    r.removeClass(HapVideoStream);
}

allocator: Allocator,
base: *VideoStream,
file_path: String = .empty,

/// Constructs a HapVideoStream with its base object left in RefCounted's
/// "pending" (unclaimed) state -- i.e. NOT wrapped through `VideoStream.init()`
/// (which also calls `initRef()`). This is the same create_instance_func
/// gdzig registers as `HapVideoStream`'s ClassDB constructor (see register()'s
/// `.auto` class registration), so it must behave like a create_instance_func
/// target: construct only, and leave the single legitimate
/// `init_ref()` claim to whichever code wraps the returned pointer first --
/// GDScript's own `.new()`, or a `Variant`/engine-Ref conversion.
///
/// Calling the bundled `VideoStream.init()` here instead double-claims: our own
/// claim plus GDScript's `.new()`-triggered wrap both succeed, leaving the
/// object's reference count one higher than its actual owners, so it's never
/// freed (confirmed empirically: `get_reference_count()` reads back 2, not 1,
/// immediately after `HapVideoStream.new()`, and the object survives to
/// Godot's ObjectDB leak report at shutdown). This looks like a gdzig
/// bindgen/idiom mismatch rather than intended behavior -- gdzig's own
/// generated `.init()` helpers (and its "plainly owned by the caller" doc
/// comment on `RefCounted.init()`) assume the caller is the *only* claimant,
/// which isn't true for a create_instance_func target. Every other call site
/// that wants plain ownership uses createOwned() instead.
pub fn create(allocator: *Allocator) !*HapVideoStream {
    const self = try allocator.create(HapVideoStream);
    self.* = .{
        .allocator = allocator.*,
        .base = constructPendingBase(),
    };
    self.base.setInstance(HapVideoStream, self);
    return self;
}

/// Construct and claim the pending initial reference for native code that
/// owns the result directly rather than returning it through ClassDB `.new()`.
pub fn createOwned(allocator: *Allocator) !*HapVideoStream {
    const self = try create(allocator);
    _ = self.base.initRef();
    return self;
}

fn constructPendingBase() *VideoStream {
    var name = godot.builtin.StringName.fromType(VideoStream);
    return @ptrCast(godot.raw.classdbConstructObject(@ptrCast(&name)).?);
}

pub fn destroy(self: *HapVideoStream, allocator: *Allocator) void {
    self.file_path.deinit();
    self.base.destroy();
    allocator.destroy(self);
}

pub fn setFile(self: *HapVideoStream, file: String) void {
    self.file_path.deinit();
    self.file_path = file.copy();
}

pub fn getFile(self: *HapVideoStream) String {
    return self.file_path.copy();
}

pub fn _instantiatePlayback(self: *HapVideoStream) ?*VideoStreamPlayback {
    const pb = HapVideoStreamPlayback.createOwned(&self.allocator) catch return null;

    var file = self.getFile();
    defer file.deinit();

    // The stock VideoStreamPlayer caches playback.getTexture() as soon as
    // the stream is set and expects a texture with its final size (as with
    // the engine's synchronous Theora open). Block here until the open
    // settles and materialize the GPU resources, so the drop-in layer gets
    // synchronous-open semantics; HapPlayer keeps the async path.
    if (!pb.open(file) or !pb.waitForOpen() or !pb.pollReady()) {
        var buf: [1024]u8 = undefined;
        log.err("Failed to open: {s}", .{file.toUtf8Buf(&buf)});
        // pb was never handed to the engine (we're bailing out before
        // returning it), so we're its sole owner (see ref.zig).
        ref.releaseAndDestroy(HapVideoStreamPlayback, pb, &self.allocator);
        return null;
    }

    return pb.base;
}
