#ifndef HAP_GPU_PRESENTER_H
#define HAP_GPU_PRESENTER_H

#include "core/hap_frame.h"
#include "core/retire_ring.h"

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/classes/ref.hpp>

#include <cstdint>
#include <vector>

namespace godot {

/// Manages GPU resources for presenting decoded Hap frames.
///
/// Handles two paths:
///   1. Pass-through (Hap1, Hap5, Hap7): upload BC data to an RS texture,
///      wrap it in Texture2DRD.
///   2. YCoCg decode (HapY, HapM): upload BC data to RD textures, dispatch
///      a compute shader that performs YCoCg→RGB, writes to an RGBA8 ring,
///      and re-points Texture2DRD to the newest ring slot.
///
/// Every variant rings its GPU-written textures 3 deep
/// (hap::core::RetireRing<3>), including the pass-through path and the
/// YCoCg path's BC source textures — not just its RGBA8 output. Ring
/// depth 3 is the minimum safe bound against Godot's default render
/// frame-queue depth of 2: a texture is only reused for a new write
/// after two other slots have been published in between, so in-flight
/// GPU reads of an older slot never race a new write. This closes
/// tearing by construction for every variant.
///
/// RD resources are created once at init (RING_SIZE copies per texture)
/// and reused across frames.
class GpuPresenter {
public:
  GpuPresenter();
  ~GpuPresenter();

  // Non-copyable, non-movable.
  GpuPresenter(const GpuPresenter &) = delete;
  GpuPresenter &operator=(const GpuPresenter &) = delete;

  GpuPresenter(GpuPresenter &&) = delete;
  GpuPresenter &operator=(GpuPresenter &&) = delete;

  /// Initialize GPU resources for the given format and dimensions.
  /// Returns true on success.
  bool initialize(RenderingDevice *rd, int width, int height,
                  hap::core::FourCC fourcc);

  /// Free all GPU resources.
  void cleanup();

  /// Present a decoded frame.
  /// Uploads BC data, optionally dispatches compute, updates the texture ring.
  /// Returns true on success.
  bool present(const hap::core::DecodedFrame &frame);

  /// Returns the stable Texture2DRD that points to the current output.
  /// Valid (same object) from construction on — consumers like the stock
  /// VideoStreamPlayer cache it once, before the async open completes.
  Ref<Texture2DRD> get_texture() const { return display_texture_; }

  /// Returns true if the presenter has alpha support (HapM, Hap5).
  bool has_alpha() const { return has_alpha_; }

private:
  static const int RING_SIZE = 3;

  RenderingDevice *rd_ = nullptr;
  bool initialized_ = false;
  bool is_ycocg_ = false;
  bool has_alpha_ = false;
  int width_ = 0;
  int height_ = 0;

  // Single sequencer shared by every per-frame-written resource ring
  // below: BC source textures (both paths) and the YCoCg output ring
  // all advance together, once per present() call.
  hap::core::RetireRing<RING_SIZE> ring_;
  bool bc_textures_created_ = false;

  // RS-level BC textures, ring of 3 (pass-through path reuses these
  // directly via Texture2DRD; YCoCg path samples them in the compute
  // shader).
  RID rs_color_texture_[RING_SIZE];
  RID rs_alpha_texture_[RING_SIZE];

  // RD texture RIDs extracted from the RS textures above (for compute
  // shader sampling), same ring indices.
  RID rd_color_texture_[RING_SIZE];
  RID rd_alpha_texture_[RING_SIZE];

  // Sampler (nearest for texelFetch)
  RID sampler_;

  // Compute shader resources (YCoCg only)
  RID shader_;
  RID pipeline_;
  // Pre-created once (per ring slot) when the BC ring is created; the
  // inputs a slot's uniform set binds (rd_color_texture_[slot],
  // rd_alpha_texture_[slot], output_textures_[slot], sampler_) never
  // change afterward, so there's no need to free/recreate per dispatch.
  RID uniform_sets_[RING_SIZE];
  bool shader_compiled_ = false;

  // Output ring (RGBA8 storage textures, YCoCg only), indexed by ring_.
  RID output_textures_[RING_SIZE];

  // Stable Texture2DRD presented to the user
  Ref<Texture2DRD> display_texture_;

  // Reusable Image objects, one per ring slot (to avoid creating new
  // ones each frame and to avoid two slots fighting over one Image).
  Ref<Image> color_image_[RING_SIZE];
  Ref<Image> alpha_image_[RING_SIZE];

  /// Embedded compute shader source (GLSL).
  static const char *ycocg_shader_source_;

  /// Create every ring slot's RS-level BC texture and its RD counterpart.
  bool create_bc_texture_ring(hap::core::HapTextureFormat fmt,
                              RID (&out_rs_tex)[RING_SIZE],
                              RID (&out_rd_tex)[RING_SIZE]);

  /// Update one ring slot's RS texture with decoded BC data.
  bool update_bc_texture(const RID &rs_tex, Ref<Image> &image,
                          hap::core::HapTextureFormat fmt,
                          const std::vector<uint8_t> &data);

  /// Compile the compute shader and create the pipeline.
  bool create_compute_pipeline();

  /// Create the output storage textures (ring).
  bool create_output_textures();

  /// Create the uniform set with the RD textures for `slot`. Called once
  /// per slot when the BC ring is created.
  bool create_uniform_set(int slot);

  /// Dispatch the compute shader, reading ring slot `slot`, writing
  /// output ring slot `slot`.
  bool dispatch_compute(int slot);

  /// Create the sampler (nearest filtering for texelFetch).
  bool create_sampler();

  /// Convert Hap texture format to Image format.
  static Image::Format hap_format_to_image(hap::core::HapTextureFormat fmt);

  /// Convert Hap texture format to RD data format.
  static RenderingDevice::DataFormat hap_format_to_rd(
      hap::core::HapTextureFormat fmt);
};

} // namespace godot

#endif // HAP_GPU_PRESENTER_H
