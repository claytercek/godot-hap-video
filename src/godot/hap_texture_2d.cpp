#include "hap_texture_2d.h"

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {

void HapTexture2D::update_from_image(const Ref<Image> &p_image) {
  if (!p_image.is_valid())
    return;

  width_ = p_image->get_width();
  height_ = p_image->get_height();

  if (rs_texture_.is_valid()) {
    RenderingServer::get_singleton()->texture_2d_update(rs_texture_, p_image, 0);
  } else {
    rs_texture_ = RenderingServer::get_singleton()->texture_2d_create(p_image);
  }
}

int32_t HapTexture2D::_get_width() const { return width_; }

int32_t HapTexture2D::_get_height() const { return height_; }

bool HapTexture2D::_has_alpha() const { return has_alpha_; }

bool HapTexture2D::_is_pixel_opaque(int32_t p_x, int32_t p_y) const {
  return true; // Hap1 is opaque
}

RID HapTexture2D::_get_rid() const {
  return rs_texture_;
}

} // namespace godot