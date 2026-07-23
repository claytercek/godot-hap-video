//! extension.zig -- GDExtension entry point for the HAP video module.
//!
//! Registers HapVideoStreamPlayback,
//! HapVideoStream, HapResourceFormatLoader, and HapPlayer, and -- at the
//! SCENE initialization level -- adds a HapResourceFormatLoader singleton to
//! the ResourceLoader (removed at teardown) so a stock VideoStreamPlayer can
//! load + play a .mov Hap clip.
//!
//! Init-level handling: gdzig's entrypoint calls register() once at load,
//! then registry.enter(level)/exit(level) per initialization level, and
//! unregister() at final teardown. `.auto` classes commit at the SCENE
//! level. The loader singleton has no
//! class seam of its own for per-level setup, so the SCENE enter/exit is
//! hooked via the Registry's addCallbacks mechanism -- the enter callback
//! runs AFTER all classes for that level have committed (see
//! Registry.enter), so the loader class is already registered and
//! instantiable when the singleton is created.

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

// -----------------------------------------------------------------------
// LoaderLifecycle — the ResourceFormatLoader singleton's per-level hook.
//
// enter/exit fire for every initialization level; this acts only at SCENE.
// Stored by value in the Registry arena; the
// enter/exit callbacks receive a stable pointer to that copy.
// -----------------------------------------------------------------------
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
            // Drop our create-time ref; the engine dropped its own on
            // remove (see ref.zig for why this must go through the typed
            // destroy).
            ref.releaseAndDestroy(HapResourceFormatLoader, loader, &self.allocator);
            self.loader = null;
        }
    }
};
