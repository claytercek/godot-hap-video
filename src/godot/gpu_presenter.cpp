#include "gpu_presenter.h"

#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/rd_sampler_state.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <cstring>

namespace godot {

// -----------------------------------------------------------------------
// Embedded compute shader source (GLSL)
// -----------------------------------------------------------------------
const char *GpuPresenter::ycocg_shader_source_ = R"GLSL(
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D u_color_tex;
layout(set = 0, binding = 1) uniform sampler2D u_alpha_tex;
layout(set = 0, binding = 2, rgba8) uniform writeonly image2D u_output_img;

layout(push_constant) uniform PushConstants {
    int has_alpha;
} u_constants;

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(u_output_img);
    if (pos.x >= size.x || pos.y >= size.y) return;

    vec4 s = texelFetch(u_color_tex, pos, 0);

    float scale = 1.0 / (floor(s.b * 255.0 / 8.0 + 0.5) * (8.0 / 255.0) + 1.0);
    float Co = (s.r - 128.0 / 255.0) * scale;
    float Cg = (s.g - 128.0 / 255.0) * scale;
    float Y = s.a;

    float R = Y + Co - Cg;
    float G = Y + Cg;
    float B = Y - Co - Cg;

    float A = 1.0;
    if (u_constants.has_alpha != 0) {
        vec4 alpha_sample = texelFetch(u_alpha_tex, pos, 0);
        A = alpha_sample.r;
    }

    imageStore(u_output_img, pos, vec4(R, G, B, A));
}
)GLSL";

// -----------------------------------------------------------------------
// Format conversion helpers
// -----------------------------------------------------------------------
Image::Format GpuPresenter::hap_format_to_image(hap::core::HapTextureFormat fmt) {
  switch (fmt) {
  case hap::core::HapTextureFormat::RGB_DXT1:
    return Image::FORMAT_DXT1;
  case hap::core::HapTextureFormat::RGBA_DXT5:
  case hap::core::HapTextureFormat::YCoCg_DXT5:
    return Image::FORMAT_DXT5;
  case hap::core::HapTextureFormat::A_RGTC1:
    return Image::FORMAT_RGTC_R;
  case hap::core::HapTextureFormat::RGBA_BPTC_UNORM:
    return Image::FORMAT_BPTC_RGBA;
  default:
    return Image::FORMAT_DXT1;
  }
}

RenderingDevice::DataFormat GpuPresenter::hap_format_to_rd(
    hap::core::HapTextureFormat fmt) {
  switch (fmt) {
  case hap::core::HapTextureFormat::RGB_DXT1:
    return RenderingDevice::DATA_FORMAT_BC1_RGB_UNORM_BLOCK;
  case hap::core::HapTextureFormat::RGBA_DXT5:
  case hap::core::HapTextureFormat::YCoCg_DXT5:
    return RenderingDevice::DATA_FORMAT_BC3_UNORM_BLOCK;
  case hap::core::HapTextureFormat::A_RGTC1:
    return RenderingDevice::DATA_FORMAT_BC4_UNORM_BLOCK;
  case hap::core::HapTextureFormat::RGBA_BPTC_UNORM:
    return RenderingDevice::DATA_FORMAT_BC7_UNORM_BLOCK;
  default:
    return RenderingDevice::DATA_FORMAT_BC1_RGB_UNORM_BLOCK;
  }
}

// -----------------------------------------------------------------------
// Constructor / Destructor / Move
// -----------------------------------------------------------------------
GpuPresenter::~GpuPresenter() {
  cleanup();
}

GpuPresenter::GpuPresenter(GpuPresenter &&other) noexcept
    : rd_(other.rd_), initialized_(other.initialized_),
      is_ycocg_(other.is_ycocg_), has_alpha_(other.has_alpha_),
      width_(other.width_), height_(other.height_), ring_(other.ring_),
      bc_textures_created_(other.bc_textures_created_),
      sampler_(other.sampler_), shader_(other.shader_),
      pipeline_(other.pipeline_), uniform_set_(other.uniform_set_),
      shader_compiled_(other.shader_compiled_),
      display_texture_(other.display_texture_) {
  for (int i = 0; i < RING_SIZE; i++) {
    rs_color_texture_[i] = other.rs_color_texture_[i];
    rs_alpha_texture_[i] = other.rs_alpha_texture_[i];
    rd_color_texture_[i] = other.rd_color_texture_[i];
    rd_alpha_texture_[i] = other.rd_alpha_texture_[i];
    output_textures_[i] = other.output_textures_[i];
    color_image_[i] = other.color_image_[i];
    alpha_image_[i] = other.alpha_image_[i];

    other.rs_color_texture_[i] = RID();
    other.rs_alpha_texture_[i] = RID();
    other.rd_color_texture_[i] = RID();
    other.rd_alpha_texture_[i] = RID();
    other.output_textures_[i] = RID();
    other.color_image_[i] = Ref<Image>();
    other.alpha_image_[i] = Ref<Image>();
  }
  other.rd_ = nullptr;
  other.initialized_ = false;
  other.bc_textures_created_ = false;
  other.sampler_ = RID();
  other.shader_ = RID();
  other.pipeline_ = RID();
  other.uniform_set_ = RID();
}

GpuPresenter &GpuPresenter::operator=(GpuPresenter &&other) noexcept {
  if (this != &other) {
    cleanup();
    rd_ = other.rd_;
    initialized_ = other.initialized_;
    is_ycocg_ = other.is_ycocg_;
    has_alpha_ = other.has_alpha_;
    width_ = other.width_;
    height_ = other.height_;
    ring_ = other.ring_;
    bc_textures_created_ = other.bc_textures_created_;
    sampler_ = other.sampler_;
    shader_ = other.shader_;
    pipeline_ = other.pipeline_;
    uniform_set_ = other.uniform_set_;
    shader_compiled_ = other.shader_compiled_;
    display_texture_ = other.display_texture_;
    for (int i = 0; i < RING_SIZE; i++) {
      rs_color_texture_[i] = other.rs_color_texture_[i];
      rs_alpha_texture_[i] = other.rs_alpha_texture_[i];
      rd_color_texture_[i] = other.rd_color_texture_[i];
      rd_alpha_texture_[i] = other.rd_alpha_texture_[i];
      output_textures_[i] = other.output_textures_[i];
      color_image_[i] = other.color_image_[i];
      alpha_image_[i] = other.alpha_image_[i];

      other.rs_color_texture_[i] = RID();
      other.rs_alpha_texture_[i] = RID();
      other.rd_color_texture_[i] = RID();
      other.rd_alpha_texture_[i] = RID();
      other.output_textures_[i] = RID();
      other.color_image_[i] = Ref<Image>();
      other.alpha_image_[i] = Ref<Image>();
    }
    other.rd_ = nullptr;
    other.initialized_ = false;
    other.bc_textures_created_ = false;
    other.sampler_ = RID();
    other.shader_ = RID();
    other.pipeline_ = RID();
    other.uniform_set_ = RID();
  }
  return *this;
}

// -----------------------------------------------------------------------
// Initialize
// -----------------------------------------------------------------------
bool GpuPresenter::initialize(RenderingDevice *rd, int width, int height,
                              hap::core::FourCC fourcc) {
  cleanup();

  rd_ = rd;
  width_ = width;
  height_ = height;

  // Determine variant
  is_ycocg_ = (fourcc == hap::core::FCC_HapY || fourcc == hap::core::FCC_HapM);
  has_alpha_ = (fourcc == hap::core::FCC_HapM || fourcc == hap::core::FCC_Hap5);

  if (!rd_) {
    ERR_PRINT("HapGpuPresenter: RenderingDevice is null");
    return false;
  }

  // Create the sampler (nearest filtering for texelFetch)
  if (!create_sampler()) {
    return false;
  }

  if (is_ycocg_) {
    // YCoCg path: create BC textures, compile compute shader, create output ring
    if (!create_compute_pipeline()) {
      return false;
    }
    if (!create_output_textures()) {
      return false;
    }

    // Create the stable Texture2DRD and point it to the first output slot
    display_texture_.instantiate();
    display_texture_->set_texture_rd_rid(output_textures_[ring_.current_slot()]);

  } else {
    // Pass-through path: RS textures are created lazily on first
    // present() when the format is known.
    display_texture_.instantiate();
  }

  initialized_ = true;
  return true;
}

// -----------------------------------------------------------------------
// Cleanup
// -----------------------------------------------------------------------
void GpuPresenter::cleanup() {
  if (!rd_)
    return;

  // Free RD resources
  for (int i = 0; i < RING_SIZE; i++) {
    if (output_textures_[i].is_valid()) {
      rd_->free_rid(output_textures_[i]);
      output_textures_[i] = RID();
    }
  }

  if (uniform_set_.is_valid()) {
    rd_->free_rid(uniform_set_);
    uniform_set_ = RID();
  }
  if (pipeline_.is_valid()) {
    rd_->free_rid(pipeline_);
    pipeline_ = RID();
  }
  if (shader_.is_valid()) {
    rd_->free_rid(shader_);
    shader_ = RID();
  }
  if (sampler_.is_valid()) {
    rd_->free_rid(sampler_);
    sampler_ = RID();
  }

  // Free RS textures (which also frees the underlying RD textures)
  for (int i = 0; i < RING_SIZE; i++) {
    if (rs_color_texture_[i].is_valid()) {
      RenderingServer::get_singleton()->free_rid(rs_color_texture_[i]);
      rs_color_texture_[i] = RID();
    }
    if (rs_alpha_texture_[i].is_valid()) {
      RenderingServer::get_singleton()->free_rid(rs_alpha_texture_[i]);
      rs_alpha_texture_[i] = RID();
    }
    rd_color_texture_[i] = RID();
    rd_alpha_texture_[i] = RID();
    color_image_[i] = Ref<Image>();
    alpha_image_[i] = Ref<Image>();
  }

  display_texture_ = Ref<Texture2DRD>();

  shader_compiled_ = false;
  bc_textures_created_ = false;
  ring_ = hap::core::RetireRing<RING_SIZE>();
  initialized_ = false;
}

// -----------------------------------------------------------------------
// Create sampler
// -----------------------------------------------------------------------
bool GpuPresenter::create_sampler() {
  Ref<RDSamplerState> sampler_state;
  sampler_state.instantiate();
  sampler_state->set_mag_filter(RenderingDevice::SAMPLER_FILTER_NEAREST);
  sampler_state->set_min_filter(RenderingDevice::SAMPLER_FILTER_NEAREST);
  sampler_state->set_mip_filter(RenderingDevice::SAMPLER_FILTER_NEAREST);
  sampler_state->set_repeat_u(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
  sampler_state->set_repeat_v(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
  sampler_state->set_repeat_w(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);

  sampler_ = rd_->sampler_create(sampler_state);
  if (!sampler_.is_valid()) {
    ERR_PRINT("HapGpuPresenter: Failed to create sampler");
    return false;
  }
  return true;
}

// -----------------------------------------------------------------------
// Create a ring of BC textures (RS + RD), RING_SIZE copies
// -----------------------------------------------------------------------
bool GpuPresenter::create_bc_texture_ring(hap::core::HapTextureFormat fmt,
                                          RID (&out_rs_tex)[RING_SIZE],
                                          RID (&out_rd_tex)[RING_SIZE]) {
  Image::Format img_fmt = hap_format_to_image(fmt);

  for (int i = 0; i < RING_SIZE; i++) {
    Ref<Image> dummy = Image::create_empty(width_, height_, false, img_fmt);
    if (!dummy.is_valid()) {
      ERR_PRINT("HapGpuPresenter: Failed to create dummy image for BC texture");
      return false;
    }

    RID rs_tex = RenderingServer::get_singleton()->texture_2d_create(dummy);
    if (!rs_tex.is_valid()) {
      ERR_PRINT("HapGpuPresenter: Failed to create RS texture");
      return false;
    }

    RID rd_tex = RenderingServer::get_singleton()->texture_get_rd_texture(rs_tex);
    if (!rd_tex.is_valid()) {
      ERR_PRINT("HapGpuPresenter: Failed to get RD texture from RS texture");
      RenderingServer::get_singleton()->free_rid(rs_tex);
      return false;
    }

    out_rs_tex[i] = rs_tex;
    out_rd_tex[i] = rd_tex;
  }
  return true;
}

// -----------------------------------------------------------------------
// Update BC texture with decoded data
// -----------------------------------------------------------------------
bool GpuPresenter::update_bc_texture(const RID &rs_tex, Ref<Image> &image,
                                      hap::core::HapTextureFormat fmt,
                                      const std::vector<uint8_t> &data) {
  Image::Format img_fmt = hap_format_to_image(fmt);

  PackedByteArray img_data;
  img_data.resize(static_cast<int>(data.size()));
  if (data.size() > 0) {
    memcpy(img_data.ptrw(), data.data(), data.size());
  }

  if (!image.is_valid()) {
    image.instantiate();
  }
  image->set_data(width_, height_, false, img_fmt, img_data);

  RenderingServer::get_singleton()->texture_2d_update(rs_tex, image, 0);
  return true;
}

// -----------------------------------------------------------------------
// Compile compute shader
// -----------------------------------------------------------------------
bool GpuPresenter::create_compute_pipeline() {
  // Create RDShaderSource with the GLSL source
  Ref<RDShaderSource> shader_source;
  shader_source.instantiate();
  shader_source->set_language(RenderingDevice::SHADER_LANGUAGE_GLSL);
  shader_source->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE,
                                  String(ycocg_shader_source_));

  // Compile GLSL to SPIR-V
  Ref<RDShaderSPIRV> spirv = rd_->shader_compile_spirv_from_source(shader_source, true);
  if (!spirv.is_valid()) {
    ERR_PRINT("HapGpuPresenter: Failed to compile compute shader (null returned)");
    return false;
  }

  // Check for compile errors in the SPIR-V object
  String compile_error = spirv->get_stage_compile_error(
      RenderingDevice::SHADER_STAGE_COMPUTE);
  if (!compile_error.is_empty()) {
    ERR_PRINT("HapGpuPresenter: Shader compile error: " + compile_error);
    return false;
  }

  // Create the shader from SPIR-V
  shader_ = rd_->shader_create_from_spirv(spirv, "HapYCoCgDecode");
  if (!shader_.is_valid()) {
    ERR_PRINT("HapGpuPresenter: Failed to create shader from SPIR-V");
    return false;
  }

  // Create the compute pipeline
  // Note: push constant size must be at least 4 bytes (one int)
  // The pipeline expects a push constant of size 4 (one int32)
  pipeline_ = rd_->compute_pipeline_create(shader_);
  if (!pipeline_.is_valid()) {
    ERR_PRINT("HapGpuPresenter: Failed to create compute pipeline");
    return false;
  }

  shader_compiled_ = true;
  return true;
}

// -----------------------------------------------------------------------
// Create output storage textures (ring of 3)
// -----------------------------------------------------------------------
bool GpuPresenter::create_output_textures() {
  Ref<RDTextureFormat> fmt;
  fmt.instantiate();
  fmt->set_format(RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM);
  fmt->set_width(static_cast<uint32_t>(width_));
  fmt->set_height(static_cast<uint32_t>(height_));
  fmt->set_depth(1);
  fmt->set_array_layers(1);
  fmt->set_mipmaps(1);
  fmt->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
  fmt->set_samples(RenderingDevice::TEXTURE_SAMPLES_1);
  fmt->set_usage_bits(
      static_cast<uint64_t>(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT) |
      static_cast<uint64_t>(RenderingDevice::TEXTURE_USAGE_STORAGE_BIT) |
      static_cast<uint64_t>(RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT));

  Ref<RDTextureView> view;
  view.instantiate();
  view->set_format_override(RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM);
  view->set_swizzle_r(RenderingDevice::TEXTURE_SWIZZLE_IDENTITY);
  view->set_swizzle_g(RenderingDevice::TEXTURE_SWIZZLE_IDENTITY);
  view->set_swizzle_b(RenderingDevice::TEXTURE_SWIZZLE_IDENTITY);
  view->set_swizzle_a(RenderingDevice::TEXTURE_SWIZZLE_IDENTITY);

  // No initial data
  TypedArray<PackedByteArray> empty_data;

  for (int i = 0; i < RING_SIZE; i++) {
    output_textures_[i] = rd_->texture_create(fmt, view, empty_data);
    if (!output_textures_[i].is_valid()) {
      ERR_PRINT("HapGpuPresenter: Failed to create output texture " + String::num_int64(i));
      return false;
    }
  }

  return true;
}

// -----------------------------------------------------------------------
// Update uniform set for a given ring slot
// -----------------------------------------------------------------------
bool GpuPresenter::update_uniform_set(int slot) {
  // Free old uniform set
  if (uniform_set_.is_valid()) {
    rd_->free_rid(uniform_set_);
    uniform_set_ = RID();
  }

  TypedArray<RDUniform> uniforms;

  // Uniform 0: color texture (sampler with texture)
  {
    Ref<RDUniform> uniform;
    uniform.instantiate();
    uniform->set_uniform_type(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE);
    uniform->set_binding(0);
    uniform->add_id(rd_color_texture_[slot]);
    uniforms.push_back(uniform);
  }

  // Uniform 1: alpha texture (sampler with texture) — always bind, shader
  //            checks has_alpha push constant
  {
    Ref<RDUniform> uniform;
    uniform.instantiate();
    uniform->set_uniform_type(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE);
    uniform->set_binding(1);
    uniform->add_id(rd_alpha_texture_[slot]);
    uniforms.push_back(uniform);
  }

  // Uniform 2: output image (storage image)
  {
    Ref<RDUniform> uniform;
    uniform.instantiate();
    uniform->set_uniform_type(RenderingDevice::UNIFORM_TYPE_IMAGE);
    uniform->set_binding(2);
    uniform->add_id(output_textures_[slot]);
    uniforms.push_back(uniform);
  }

  uniform_set_ = rd_->uniform_set_create(uniforms, shader_, 0);
  if (!uniform_set_.is_valid()) {
    ERR_PRINT("HapGpuPresenter: Failed to create uniform set");
    return false;
  }

  return true;
}

// -----------------------------------------------------------------------
// Dispatch compute shader for ring slot `slot`
// -----------------------------------------------------------------------
bool GpuPresenter::dispatch_compute(int slot) {
  if (!shader_compiled_ || !pipeline_.is_valid()) {
    ERR_PRINT("HapGpuPresenter: Compute shader not compiled");
    return false;
  }

  if (!update_uniform_set(slot)) {
    return false;
  }

  // Begin compute list
  int64_t compute_list = rd_->compute_list_begin();
  if (compute_list < 0) {
    ERR_PRINT("HapGpuPresenter: Failed to begin compute list");
    return false;
  }

  rd_->compute_list_bind_compute_pipeline(compute_list, pipeline_);
  rd_->compute_list_bind_uniform_set(compute_list, uniform_set_, 0);

  // Push constant: has_alpha
  PackedByteArray push_constant;
  push_constant.resize(4); // one int32
  int32_t has_alpha_val = has_alpha_ ? 1 : 0;
  memcpy(push_constant.ptrw(), &has_alpha_val, 4);
  rd_->compute_list_set_push_constant(compute_list, push_constant, 4);

  // Dispatch: ceil(width/8) x ceil(height/8) x 1
  uint32_t groups_x = (static_cast<uint32_t>(width_) + 7) / 8;
  uint32_t groups_y = (static_cast<uint32_t>(height_) + 7) / 8;
  rd_->compute_list_dispatch(compute_list, groups_x, groups_y, 1);

  rd_->compute_list_end();

  return true;
}

// -----------------------------------------------------------------------
// Present a decoded frame
// -----------------------------------------------------------------------
bool GpuPresenter::present(const hap::core::DecodedFrame &frame) {
  if (!initialized_ || !rd_) {
    ERR_PRINT("HapGpuPresenter: Not initialized");
    return false;
  }

  if (frame.textures.empty()) {
    return false;
  }

  const auto &tex0 = frame.textures[0];
  if (tex0.data.empty()) {
    return false;
  }

  // Every write this frame targets the ring's writable slot; commit()
  // publishes it (as the new current_slot()) only once every resource
  // has been written, so a partially-updated slot is never presented.
  int slot = static_cast<int>(ring_.writable_slot());

  if (is_ycocg_) {
    // --- YCoCg path ---

    if (!bc_textures_created_) {
      if (!create_bc_texture_ring(tex0.format, rs_color_texture_,
                                  rd_color_texture_)) {
        return false;
      }
      hap::core::HapTextureFormat alpha_fmt =
          (has_alpha_ && frame.textures.size() > 1)
              ? frame.textures[1].format
              : hap::core::HapTextureFormat::A_RGTC1;
      if (!create_bc_texture_ring(alpha_fmt, rs_alpha_texture_,
                                  rd_alpha_texture_)) {
        return false;
      }
      bc_textures_created_ = true;
    }

    if (!update_bc_texture(rs_color_texture_[slot], color_image_[slot],
                            tex0.format, tex0.data)) {
      return false;
    }

    if (has_alpha_ && frame.textures.size() > 1) {
      const auto &tex1 = frame.textures[1];
      if (!update_bc_texture(rs_alpha_texture_[slot], alpha_image_[slot],
                              tex1.format, tex1.data)) {
        return false;
      }
    }

    if (!dispatch_compute(slot)) {
      return false;
    }

    display_texture_->set_texture_rd_rid(output_textures_[slot]);

  } else {
    // --- Pass-through path ---

    if (!bc_textures_created_) {
      hap::core::HapTextureFormat dummy_fmt = hap::core::HapTextureFormat::A_RGTC1;
      if (!create_bc_texture_ring(tex0.format, rs_color_texture_,
                                  rd_color_texture_)) {
        return false;
      }
      // Alpha ring unused in the pass-through path; leave empty.
      (void)dummy_fmt;
      bc_textures_created_ = true;
    }

    if (!update_bc_texture(rs_color_texture_[slot], color_image_[slot],
                            tex0.format, tex0.data)) {
      return false;
    }

    RID rd_tex = RenderingServer::get_singleton()->texture_get_rd_texture(
        rs_color_texture_[slot]);
    if (rd_tex.is_valid()) {
      display_texture_->set_texture_rd_rid(rd_tex);
    }
  }

  ring_.commit();

  return true;
}

} // namespace godot
