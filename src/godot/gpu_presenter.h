#ifndef HAP_GPU_PRESENTER_H
#define HAP_GPU_PRESENTER_H

#include "core/hap_frame.h"

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
/// RD resources are created once at init and reused across frames.
class GpuPresenter {
public:
  GpuPresenter() = default;
  ~GpuPresenter();

  // Non-copyable, movable.
  GpuPresenter(const GpuPresenter &) = delete;
  GpuPresenter &operator=(const GpuPresenter &) = delete;

  GpuPresenter(GpuPresenter &&other) noexcept;
  GpuPresenter &operator=(GpuPresenter &&other) noexcept;

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

  // RS-level texture (pass-through path reuses this directly via Texture2DRD)
  RID rs_color_texture_;
  RID rs_alpha_texture_;

  // RD texture RIDs extracted from RS textures (for compute shader sampling)
  RID rd_color_texture_;
  RID rd_alpha_texture_;

  // Sampler (nearest for texelFetch)
  RID sampler_;

  // Compute shader resources (YCoCg only)
  RID shader_;
  RID pipeline_;
  RID uniform_set_;
  bool shader_compiled_ = false;

  // Output ring (RGBA8 storage textures, YCoCg only)
  RID output_textures_[RING_SIZE];
  int current_slot_ = 0;

  // Stable Texture2DRD presented to the user
  Ref<Texture2DRD> display_texture_;

  // Reusable Image objects (to avoid creating new ones each frame)
  Ref<Image> color_image_;
  Ref<Image> alpha_image_;

  /// Embedded compute shader source (GLSL).
  static const char *ycocg_shader_source_;

  /// Create the RS-level BC texture and its RD counterpart.
  bool create_bc_texture(hap::core::HapTextureFormat fmt, RID &out_rs_tex,
                          RID &out_rd_tex);

  /// Update an RS texture with decoded BC data.
  bool update_bc_texture(const RID &rs_tex, Ref<Image> &image,
                          hap::core::HapTextureFormat fmt,
                          const std::vector<uint8_t> &data);

  /// Compile the compute shader and create the pipeline.
  bool create_compute_pipeline();

  /// Create the output storage textures (ring).
  bool create_output_textures();

  /// Update the uniform set with current RD textures.
  bool update_uniform_set();

  /// Dispatch the compute shader.
  bool dispatch_compute();

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