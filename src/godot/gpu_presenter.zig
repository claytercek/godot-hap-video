//! gpu_presenter.zig — GPU resources for presenting decoded Hap frames.
//!
//! HapVideoStreamPlayback is the only consumer, through this surface:
//! init()/deinit, initialize(rd, w, h, variant), cleanup(),
//! present(&frame), getTexture() -> *Texture2drd, hasAlpha().
//!
//! Handles two paths:
//!   1. Pass-through (Hap1, Hap5, Hap7): upload BC data to an RS texture,
//!      wrap it in Texture2DRD.
//!   2. YCoCg decode (HapY, HapM): upload BC data to RD textures, dispatch
//!      a compute shader that performs YCoCg->RGB, writes to an RGBA8 ring,
//!      and re-points Texture2DRD to the newest ring slot.
//!
//! Every variant rings its GPU-written textures 3 deep (RetireRing(3)),
//! including the pass-through path and the YCoCg path's BC source textures
//! -- not just its RGBA8 output. Ring depth 3 is the minimum safe bound
//! against Godot's default render frame-queue depth of 2: a texture is only
//! reused for a new write after two other slots have been published in
//! between, so in-flight GPU reads of an older slot never race a new write.
//! This closes tearing by construction for every variant.
//!
//! RD resources are created once at init (ring_size copies per texture) and
//! reused across frames.
//!
//! RefCounted release pattern: every transient Rd* object obtained via
//! `.init()` is released with `defer ref.releaseEngineRef(x);` right after
//! construction, since these are one-shot config objects consumed
//! synchronously by the `RenderingDevice.*Create` call that follows.

const std = @import("std");

const godot = @import("godot");
const RenderingServer = godot.class.RenderingServer;
const RenderingDevice = godot.class.RenderingDevice;
const RdShaderSource = godot.class.RdShaderSource;
const RdTextureFormat = godot.class.RdTextureFormat;
const RdTextureView = godot.class.RdTextureView;
const RdUniform = godot.class.RdUniform;
const RdSamplerState = godot.class.RdSamplerState;
const Texture2drd = godot.class.Texture2drd;
const Image = godot.class.Image;
const Rid = godot.builtin.Rid;
const Array = godot.builtin.Array;
const Variant = godot.builtin.Variant;
const String = godot.builtin.String;
const PackedByteArray = godot.builtin.PackedByteArray;

// Core types come through the "core" named module (build.zig-wired) so they
// match the module instance the rest of the extension hands around. A
// module's root restricts @import to its own subtree, so a path import into
// ../core is not an option.
const core = @import("core");
const hap_frame = core.hap_frame;
const retire_ring = core.retire_ring;

const ref = @import("ref.zig");

const log = std.log.scoped(.hap_gpu_presenter);

/// Number of ring slots. See the module doc comment for the depth-3
/// rationale (Godot's ~2-deep render frame queue).
pub const ring_size: usize = 3;

const Ring = retire_ring.RetireRing(ring_size);

/// An empty/invalid RID, comptime-constructible (unlike `Rid.init()`, which
/// goes through a runtime FFI constructor call and so cannot be a struct
/// field default).
const rid_invalid: Rid = std.mem.zeroes(Rid);

// YCoCg-DXT5 -> RGBA unpack compute shader (Hap Q / Hap Q Alpha): samples
// the hardware-decompressed BC3 color texture (plus an optional BC4 alpha
// texture) and writes the YCoCg->RGB inverse transform to an RGBA8 storage
// image.
const ycocg_shader_source = @embedFile("ycocg_unpack.glsl");

// -----------------------------------------------------------------------
// Format conversion helpers
// -----------------------------------------------------------------------

/// Godot-side `Image.Format` for a `HapTextureFormat`: the one switch site
/// that maps core Hap format knowledge onto the Image enum (core itself must
/// stay free of godot/gdzig imports, so this can't move into hap_frame.zig
/// alongside the fourcc/variant knowledge it's derived from).
/// `HapTextureFormat` is exhaustive, so `imageFormat()` needs no fallback
/// branch.
///
/// Resolved once per BC ring (see `createBcTextureRing`) and cached on
/// `GpuPresenter`, rather than re-switched on every frame's `updateBcTexture`
/// call.
fn imageFormat(fmt: hap_frame.HapTextureFormat) Image.Format {
    return switch (fmt) {
        .rgb_dxt1 => .format_dxt1,
        .rgba_dxt5, .ycocg_dxt5 => .format_dxt5,
        .a_rgtc1 => .format_rgtc_r,
        .rgba_bptc_unorm => .format_bptc_rgba,
    };
}

/// One ring slot's worth of per-frame-written GPU state. Every field here
/// is always indexed by the same ring slot as every other field, across
/// every call site (present(), cleanup(), createUniformSet(), ...) -- they
/// were previously 8 separate `[ring_size]` arrays indexed in lockstep.
const RingSlot = struct {
    // RS-level BC textures (pass-through path reuses these directly via
    // Texture2DRD; YCoCg path samples them in the compute shader).
    rs_color_texture: Rid = rid_invalid,
    rs_alpha_texture: Rid = rid_invalid,

    // RD texture RIDs extracted from the RS textures above (for compute
    // shader sampling).
    rd_color_texture: Rid = rid_invalid,
    rd_alpha_texture: Rid = rid_invalid,

    // Compute shader resources (YCoCg only). Pre-created once when the BC
    // ring is created; the inputs a slot's uniform set binds
    // (rd_color_texture, rd_alpha_texture, output_texture, sampler) never
    // change afterward, so there's no need to free/recreate per dispatch.
    uniform_set: Rid = rid_invalid,

    // Output texture (RGBA8 storage, YCoCg only).
    output_texture: Rid = rid_invalid,

    // Reusable Image objects (to avoid creating new ones each frame and to
    // avoid two slots fighting over one Image).
    color_image: ?*Image = null,
    alpha_image: ?*Image = null,
};

/// Manages GPU resources for presenting decoded Hap frames. See the module
/// doc comment for the two variants (pass-through vs. YCoCg) and the
/// retire-ring rationale.
pub const GpuPresenter = struct {
    rd: ?*RenderingDevice = null,
    initialized: bool = false,
    is_ycocg: bool = false,
    has_alpha: bool = false,
    width: i32 = 0,
    height: i32 = 0,

    // Single sequencer shared by every per-frame-written resource ring
    // below: BC source textures (both paths) and the YCoCg output ring
    // all advance together, once per present() call.
    ring: Ring = .{},

    // YCoCg-only: the pass-through path creates its BC ring eagerly at
    // initialize(), but the YCoCg path defers BC ring creation to the first
    // present() (it needs the first frame's exact alpha-texture format), so
    // this guards that one-time lazy setup.
    bc_textures_created: bool = false,

    ring_slots: [ring_size]RingSlot = @splat(.{}),

    // Resolved once, when the BC ring is (re)created -- see imageFormat().
    color_format: Image.Format = imageFormat(.rgb_dxt1),
    alpha_format: Image.Format = imageFormat(.rgb_dxt1),

    // Sampler (nearest for texelFetch)
    sampler: Rid = rid_invalid,

    // Compute shader resources (YCoCg only)
    shader: Rid = rid_invalid,
    pipeline: Rid = rid_invalid,

    // Stable Texture2DRD presented to the user. Valid (same object) from
    // construction on -- consumers like the stock VideoStreamPlayer cache
    // it once, before the async open completes.
    display_texture: *Texture2drd,

    pub fn init() GpuPresenter {
        return .{
            .display_texture = Texture2drd.init(),
        };
    }

    pub fn deinit(self: *GpuPresenter) void {
        self.cleanup();
        ref.releaseEngineRef(self.display_texture);
    }

    /// Initialize GPU resources for the given format and dimensions.
    /// Returns true on success.
    pub fn initialize(self: *GpuPresenter, rd: ?*RenderingDevice, width: i32, height: i32, variant: hap_frame.HapVariant) bool {
        self.cleanup();

        self.rd = rd;
        self.width = width;
        self.height = height;

        self.is_ycocg = variant.isYcocg();
        self.has_alpha = variant.hasAlpha();

        if (self.rd == null) {
            log.err("RenderingDevice is null", .{});
            return false;
        }

        // Create the sampler (nearest filtering for texelFetch)
        if (!self.createSampler()) return false;

        if (self.is_ycocg) {
            // YCoCg path: compile compute shader, create output ring. BC
            // textures are created lazily in present() once the first
            // frame's exact alpha-texture format is known.
            if (!self.createComputePipeline()) return false;
            if (!self.createOutputTextures()) return false;

            // Point the stable Texture2DRD at the first output slot
            self.display_texture.setTextureRdRid(self.ring_slots[self.ring.currentSlot()].output_texture);
        } else {
            // Pass-through path: the frame format is fixed per variant, so
            // the BC ring can be created now and the display texture
            // pointed at it. The texture must report its real size from
            // initialization on: the stock VideoStreamPlayer's first draw
            // happens before the first decoded frame arrives, and a 0x0
            // texture at that draw leaves the canvas item without the RS
            // dependency that triggers later redraws.
            const fmt = variant.textureFormat() orelse {
                log.err("pass-through Hap variant has no fixed texture format: {s}", .{@tagName(variant)});
                return false;
            };

            if (!self.createBcTextureRing(.color, fmt)) return false;

            // createBcTextureRing already extracted, validated, and cached
            // each slot's RD texture; point the display texture at the
            // current slot's directly.
            self.display_texture.setTextureRdRid(self.ring_slots[self.ring.currentSlot()].rd_color_texture);
        }

        self.initialized = true;
        return true;
    }

    /// Free all GPU resources.
    pub fn cleanup(self: *GpuPresenter) void {
        const rd = self.rd orelse return;

        // Free RD resources. Uniform sets must go before the textures they
        // reference: RD's dependency tracking frees a set automatically
        // when a contained texture is freed, so the reverse order
        // double-frees.
        for (&self.ring_slots) |*slot| {
            if (slot.uniform_set.isValid()) {
                rd.freeRid(slot.uniform_set);
                slot.uniform_set = rid_invalid;
            }
        }

        for (&self.ring_slots) |*slot| {
            if (slot.output_texture.isValid()) {
                rd.freeRid(slot.output_texture);
                slot.output_texture = rid_invalid;
            }
        }
        if (self.pipeline.isValid()) {
            rd.freeRid(self.pipeline);
            self.pipeline = rid_invalid;
        }
        if (self.shader.isValid()) {
            rd.freeRid(self.shader);
            self.shader = rid_invalid;
        }
        if (self.sampler.isValid()) {
            rd.freeRid(self.sampler);
            self.sampler = rid_invalid;
        }

        // Free RS textures (which also frees the underlying RD textures)
        for (&self.ring_slots) |*slot| {
            if (slot.rs_color_texture.isValid()) {
                RenderingServer.freeRid(slot.rs_color_texture);
                slot.rs_color_texture = rid_invalid;
            }
            if (slot.rs_alpha_texture.isValid()) {
                RenderingServer.freeRid(slot.rs_alpha_texture);
                slot.rs_alpha_texture = rid_invalid;
            }
            slot.rd_color_texture = rid_invalid;
            slot.rd_alpha_texture = rid_invalid;
            if (slot.color_image) |img| {
                ref.releaseEngineRef(img);
                slot.color_image = null;
            }
            if (slot.alpha_image) |img| {
                ref.releaseEngineRef(img);
                slot.alpha_image = null;
            }
        }

        // Keep the display texture object itself (consumers hold a cached
        // reference to it); just detach it from the freed GPU resources.
        self.display_texture.setTextureRdRid(rid_invalid);

        self.bc_textures_created = false;
        self.ring = .{};
        self.initialized = false;
    }

    /// Present a decoded frame. Uploads BC data, optionally dispatches
    /// compute, updates the texture ring. Returns true on success.
    pub fn present(self: *GpuPresenter, frame: *const hap_frame.DecodedFrame) bool {
        if (!self.initialized or self.rd == null) {
            log.err("not initialized", .{});
            return false;
        }

        if (frame.textures.items.len == 0) return false;

        const tex0 = &frame.textures.items[0];
        if (tex0.data.items.len == 0) return false;

        // Every write this frame targets the ring's writable slot; commit()
        // publishes it (as the new currentSlot()) only once every resource
        // has been written, so a partially-updated slot is never presented.
        const slot = self.ring.writableSlot();

        const s = &self.ring_slots[slot];

        if (self.is_ycocg) {
            // --- YCoCg path ---

            if (!self.bc_textures_created) {
                if (!self.createBcTextureRing(.color, tex0.format)) return self.rollbackLazyInitialization();

                const alpha_fmt: hap_frame.HapTextureFormat = if (self.has_alpha and frame.textures.items.len > 1)
                    frame.textures.items[1].format
                else
                    .a_rgtc1;
                if (!self.createBcTextureRing(.alpha, alpha_fmt)) return self.rollbackLazyInitialization();
                self.bc_textures_created = true;

                // The alpha ring is always created above in the YCoCg
                // path, so every input a uniform set binds
                // (rd_color_texture, rd_alpha_texture, output_texture,
                // sampler) already exists for every slot; create all
                // ring_size uniform sets once instead of per-dispatch.
                for (0..ring_size) |i| {
                    if (!self.createUniformSet(i)) return self.rollbackLazyInitialization();
                }
            }

            self.updateBcTexture(s.rs_color_texture, &s.color_image, self.color_format, tex0.data.items);

            if (self.has_alpha and frame.textures.items.len > 1) {
                const tex1 = &frame.textures.items[1];
                self.updateBcTexture(s.rs_alpha_texture, &s.alpha_image, self.alpha_format, tex1.data.items);
            }

            if (!self.dispatchCompute(slot)) return false;

            self.display_texture.setTextureRdRid(s.output_texture);
        } else {
            // --- Pass-through path ---

            self.updateBcTexture(s.rs_color_texture, &s.color_image, self.color_format, tex0.data.items);

            // createBcTextureRing (run eagerly at initialize()) already cached
            // this slot's validated RD texture; wrap it directly rather than
            // re-deriving it from the RS texture every frame.
            self.display_texture.setTextureRdRid(s.rd_color_texture);
        }

        self.ring.commit();
        return true;
    }

    /// Returns the stable Texture2DRD that points to the current output.
    pub fn getTexture(self: *const GpuPresenter) *Texture2drd {
        return self.display_texture;
    }

    /// Returns true if the presenter has alpha support (HapM, Hap5).
    pub fn hasAlpha(self: *const GpuPresenter) bool {
        return self.has_alpha;
    }

    // -----------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------

    /// Lazy YCoCg setup writes several interdependent rings. Roll the whole
    /// presenter back on any partial failure so a caller can never retry over
    /// live RIDs that were only partly published.
    fn rollbackLazyInitialization(self: *GpuPresenter) bool {
        self.cleanup();
        return false;
    }

    /// Create the sampler (nearest filtering for texelFetch).
    fn createSampler(self: *GpuPresenter) bool {
        const rd = self.rd.?;

        const sampler_state = RdSamplerState.init();
        defer ref.releaseEngineRef(sampler_state);
        sampler_state.setMagFilter(.sampler_filter_nearest);
        sampler_state.setMinFilter(.sampler_filter_nearest);
        sampler_state.setMipFilter(.sampler_filter_nearest);
        sampler_state.setRepeatU(.sampler_repeat_mode_clamp_to_edge);
        sampler_state.setRepeatV(.sampler_repeat_mode_clamp_to_edge);
        sampler_state.setRepeatW(.sampler_repeat_mode_clamp_to_edge);

        self.sampler = rd.samplerCreate(sampler_state);
        if (!self.sampler.isValid()) {
            log.err("failed to create sampler", .{});
            return false;
        }
        return true;
    }

    /// Which pair of a RingSlot's BC texture fields `createBcTextureRing`
    /// writes into.
    const Channel = enum { color, alpha };

    /// Create every ring slot's RS-level BC texture and its RD
    /// counterpart, and cache the resolved Image.Format for later
    /// `updateBcTexture` calls on this channel.
    fn createBcTextureRing(self: *GpuPresenter, channel: Channel, fmt: hap_frame.HapTextureFormat) bool {
        const img_fmt = imageFormat(fmt);
        switch (channel) {
            .color => self.color_format = img_fmt,
            .alpha => self.alpha_format = img_fmt,
        }

        for (&self.ring_slots) |*slot| {
            const dummy = Image.createEmpty(self.width, self.height, false, img_fmt) orelse {
                log.err("failed to create dummy image for BC texture", .{});
                return false;
            };
            defer ref.releaseEngineRef(dummy);

            const rs_tex = RenderingServer.texture2dCreate(dummy);
            if (!rs_tex.isValid()) {
                log.err("failed to create RS texture", .{});
                return false;
            }

            const rd_tex = RenderingServer.textureGetRdTexture(rs_tex, .{});
            if (!rd_tex.isValid()) {
                log.err("failed to get RD texture from RS texture", .{});
                RenderingServer.freeRid(rs_tex);
                return false;
            }

            switch (channel) {
                .color => {
                    slot.rs_color_texture = rs_tex;
                    slot.rd_color_texture = rd_tex;
                },
                .alpha => {
                    slot.rs_alpha_texture = rs_tex;
                    slot.rd_alpha_texture = rd_tex;
                },
            }
        }
        return true;
    }

    /// Update one ring slot's RS texture with decoded BC data.
    fn updateBcTexture(self: *GpuPresenter, rs_tex: Rid, image_slot: *?*Image, img_fmt: Image.Format, data: []const u8) void {
        var img_data = PackedByteArray.init();
        defer img_data.deinit();
        _ = img_data.resize(@intCast(data.len));
        if (data.len > 0) {
            const dst: [*]u8 = @ptrCast(img_data.index(0));
            @memcpy(dst[0..data.len], data);
        }

        if (image_slot.* == null) {
            image_slot.* = Image.init();
        }
        const image = image_slot.*.?;
        image.setData(self.width, self.height, false, img_fmt, img_data);

        RenderingServer.texture2dUpdate(rs_tex, image, 0);
    }

    /// Compile the compute shader and create the pipeline.
    fn createComputePipeline(self: *GpuPresenter) bool {
        const rd = self.rd.?;

        // Create RDShaderSource with the GLSL source
        const shader_source = RdShaderSource.init();
        defer ref.releaseEngineRef(shader_source);
        shader_source.setLanguage(.shader_language_glsl);
        var source_str = String.fromLatin1(ycocg_shader_source);
        defer source_str.deinit();
        shader_source.setStageSource(.shader_stage_compute, source_str);

        // Compile GLSL to SPIR-V
        const spirv = rd.shaderCompileSpirvFromSource(shader_source, .{}) orelse {
            log.err("failed to compile compute shader (null returned)", .{});
            return false;
        };
        defer ref.releaseEngineRef(spirv);

        // Check for compile errors in the SPIR-V object
        var compile_error = spirv.getStageCompileError(.shader_stage_compute);
        defer compile_error.deinit();
        if (compile_error.length() != 0) {
            log.err("shader compile error", .{});
            return false;
        }

        // Create the shader from SPIR-V
        var name_str = String.fromLatin1("HapYCoCgDecode");
        defer name_str.deinit();
        self.shader = rd.shaderCreateFromSpirv(spirv, .{ .name = name_str });
        if (!self.shader.isValid()) {
            log.err("failed to create shader from SPIR-V", .{});
            return false;
        }

        // Create the compute pipeline
        // Note: push constant size must be at least 4 bytes (one int)
        // The pipeline expects a push constant of size 16 (padded).
        self.pipeline = rd.computePipelineCreate(self.shader, .{});
        if (!self.pipeline.isValid()) {
            log.err("failed to create compute pipeline", .{});
            return false;
        }

        return true;
    }

    /// Create the output storage textures (ring).
    fn createOutputTextures(self: *GpuPresenter) bool {
        const rd = self.rd.?;

        const fmt = RdTextureFormat.init();
        defer ref.releaseEngineRef(fmt);
        fmt.setFormat(.data_format_r8g8b8a8_unorm);
        fmt.setWidth(@intCast(self.width));
        fmt.setHeight(@intCast(self.height));
        fmt.setDepth(1);
        fmt.setArrayLayers(1);
        fmt.setMipmaps(1);
        fmt.setTextureType(.texture_type_2d);
        fmt.setSamples(.texture_samples_1);
        fmt.setUsageBits(.{
            .texture_usage_sampling_bit = true,
            .texture_usage_storage_bit = true,
            .texture_usage_can_update_bit = true,
        });

        const view = RdTextureView.init();
        defer ref.releaseEngineRef(view);
        view.setFormatOverride(.data_format_r8g8b8a8_unorm);
        view.setSwizzleR(.texture_swizzle_identity);
        view.setSwizzleG(.texture_swizzle_identity);
        view.setSwizzleB(.texture_swizzle_identity);
        view.setSwizzleA(.texture_swizzle_identity);

        for (&self.ring_slots, 0..) |*slot, i| {
            slot.output_texture = rd.textureCreate(fmt, view, .{});
            if (!slot.output_texture.isValid()) {
                log.err("failed to create output texture {d}", .{i});
                return false;
            }
        }

        return true;
    }

    /// Append one `sampler2D` uniform (sampler id first, then texture id)
    /// to `uniforms` at `binding`.
    fn appendSamplerUniform(uniforms: *Array, binding: i32, sampler: Rid, texture: Rid) void {
        const uniform = RdUniform.init();
        defer ref.releaseEngineRef(uniform);
        uniform.setUniformType(.uniform_type_sampler_with_texture);
        uniform.setBinding(binding);
        uniform.addId(sampler);
        uniform.addId(texture);
        var v = Variant.init(*RdUniform, uniform);
        uniforms.append(v);
        v.deinit();
    }

    /// Append one storage-image uniform to `uniforms` at `binding`.
    fn appendImageUniform(uniforms: *Array, binding: i32, texture: Rid) void {
        const uniform = RdUniform.init();
        defer ref.releaseEngineRef(uniform);
        uniform.setUniformType(.uniform_type_image);
        uniform.setBinding(binding);
        uniform.addId(texture);
        var v = Variant.init(*RdUniform, uniform);
        uniforms.append(v);
        v.deinit();
    }

    /// Create the uniform set with the RD textures for `slot`. Called once
    /// per slot when the BC ring is created.
    fn createUniformSet(self: *GpuPresenter, slot: usize) bool {
        const rd = self.rd.?;
        const s = &self.ring_slots[slot];

        var uniforms = Array.init();
        defer uniforms.deinit();

        // Binding 0: color texture.
        appendSamplerUniform(&uniforms, 0, self.sampler, s.rd_color_texture);
        // Binding 1: alpha texture — always bound, shader checks has_alpha
        // push constant.
        appendSamplerUniform(&uniforms, 1, self.sampler, s.rd_alpha_texture);
        // Binding 2: output image (storage image).
        appendImageUniform(&uniforms, 2, s.output_texture);

        s.uniform_set = rd.uniformSetCreate(uniforms, self.shader, 0);
        if (!s.uniform_set.isValid()) {
            log.err("failed to create uniform set", .{});
            return false;
        }

        return true;
    }

    /// Dispatch the compute shader, reading ring slot `slot`, writing
    /// output ring slot `slot`.
    fn dispatchCompute(self: *GpuPresenter, slot: usize) bool {
        if (!self.pipeline.isValid()) {
            log.err("compute shader not compiled", .{});
            return false;
        }
        const rd = self.rd.?;

        // Begin compute list
        const compute_list = rd.computeListBegin();
        if (compute_list < 0) {
            log.err("failed to begin compute list", .{});
            return false;
        }

        rd.computeListBindComputePipeline(compute_list, self.pipeline);
        rd.computeListBindUniformSet(compute_list, self.ring_slots[slot].uniform_set, 0);

        // Push constant: has_alpha (one int32, padded to the 16-byte push
        // constant size Vulkan rounds the block up to)
        var push_constant = PackedByteArray.init();
        defer push_constant.deinit();
        _ = push_constant.resize(16);
        push_constant.fill(0);
        const has_alpha_val: i32 = if (self.has_alpha) 1 else 0;
        {
            const dst: [*]u8 = @ptrCast(push_constant.index(0));
            @memcpy(dst[0..4], std.mem.asBytes(&has_alpha_val));
        }
        rd.computeListSetPushConstant(compute_list, push_constant, 16);

        // Dispatch: ceil(width/8) x ceil(height/8) x 1
        const w: u32 = @intCast(self.width);
        const h: u32 = @intCast(self.height);
        const groups_x: u32 = (w + 7) / 8;
        const groups_y: u32 = (h + 7) / 8;
        rd.computeListDispatch(compute_list, groups_x, groups_y, 1);

        rd.computeListEnd();

        return true;
    }
};
