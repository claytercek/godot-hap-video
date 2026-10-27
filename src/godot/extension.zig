//! GDExtension entry point. Registers HapVideoStreamPlayback, HapVideoStream,
//! HapResourceFormatLoader, and HapPlayer. At SCENE initialization, installs
//! the .mov loader singleton so VideoStreamPlayer can load Hap clips; removes
//! it at SCENE teardown.
//!
//! gdzig calls register() at load, Registry.enter/exit per initialization
//! level, then unregister() at final teardown. Registry.addCallbacks runs
//! the loader's SCENE enter hook after .auto classes commit, so its class
//! exists before the singleton is created.

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const InitializationLevel = godot.extension.InitializationLevel;
const ResourceLoader = godot.class.ResourceLoader;

const HapVideoStreamPlayback = @import("hap_video_stream_playback.zig");
const HapVideoStream = @import("hap_video_stream.zig");
const HapResourceFormatLoader = @import("hap_resource_format_loader.zig");
const HapPlayer = @import("hap_player.zig");
const ref = @import("ref.zig");

pub fn register(r: *Registry) void {
    // Register playback before stream so the stream's `_instantiatePlayback`
    // return type resolves.
    r.addModule(HapVideoStreamPlayback);
    r.addModule(HapVideoStream);
    r.addModule(HapResourceFormatLoader);
    r.addModule(HapPlayer);

    // Loader singleton lifecycle, gated to the SCENE level.
    r.addCallbacks(LoaderLifecycle, .{ .allocator = r.allocator }, .{});
}

pub fn unregister(r: *Registry) void {
    r.removeModule(HapPlayer);
    r.removeModule(HapResourceFormatLoader);
    r.removeModule(HapVideoStream);
    r.removeModule(HapVideoStreamPlayback);
}

// SCENE-only loader lifecycle. Registry stores this value in its arena and
// passes callbacks a stable pointer to that copy.
const LoaderLifecycle = struct {
    allocator: Allocator,
    loader: ?*HapResourceFormatLoader = null,

    pub fn enter(self: *LoaderLifecycle, level: InitializationLevel) void {
        if (level != .scene) return;
        const loader = HapResourceFormatLoader.create(&self.allocator) catch return;
        self.loader = loader;
        ResourceLoader.addResourceFormatLoader(loader.base, .{});
    }

    pub fn exit(self: *LoaderLifecycle, level: InitializationLevel) void {
        if (level != .scene) return;
        if (self.loader) |loader| {
            ResourceLoader.removeResourceFormatLoader(loader.base);
            // Removal dropped the engine's ref. Release the create-time
            // ref through typed destroy (see ref.zig).
            ref.releaseAndDestroy(HapResourceFormatLoader, loader, &self.allocator);
            self.loader = null;
        }
    }
};
