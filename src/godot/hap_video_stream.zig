//! HapVideoStream resource storing a file path. VideoStreamPlayer calls
//! _instantiatePlayback() to create a HapVideoStreamPlayback for that file.

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

/// ClassDB constructor: Godot 4.7's create_instance3 requires a claimed
/// reference. Older callbacks leave the initial claim to the engine's first
/// Ref/Variant wrapper to avoid an extra reference. Native code always uses
/// createOwned().
pub fn create(allocator: *Allocator) !*HapVideoStream {
    const self = try allocator.create(HapVideoStream);
    self.* = .{
        .allocator = allocator.*,
        .base = if (godot.api_version.gte(.@"4.7")) VideoStream.init() else constructPendingBase(),
    };
    self.base.setInstance(HapVideoStream, self);
    return self;
}

/// Construct and claim the pending initial reference for native code that
/// owns the result directly rather than returning it through ClassDB `.new()`.
pub fn createOwned(allocator: *Allocator) !*HapVideoStream {
    const self = try create(allocator);
    if (!godot.api_version.gte(.@"4.7")) _ = self.base.initRef();
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

    // VideoStreamPlayer caches the texture when setting the stream and
    // needs its final size, as with synchronous Theora open. Wait for open
    // and GPU setup here; HapPlayer uses the async path.
    if (!pb.open(file) or !pb.waitForOpen() or !pb.pollReady()) {
        var buf: [1024]u8 = undefined;
        log.err("Failed to open: {s}", .{file.toUtf8Buf(&buf)});
        // The engine never received pb; release its sole ref (see ref.zig).
        ref.releaseAndDestroy(HapVideoStreamPlayback, pb, &self.allocator);
        return null;
    }

    return pb.base;
}
