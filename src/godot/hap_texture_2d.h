#ifndef HAP_TEXTURE_2D_H
#define HAP_TEXTURE_2D_H

#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/rid.hpp>

namespace godot {

/// A simple Texture2D implementation that wraps a RenderingServer 2D texture RID.
/// The underlying RS texture is created from an Image and updated each frame.
class HapTexture2D : public Texture2D {
  GDEXTENSION_CLASS(HapTexture2D, Texture2D)

public:
  void set_rs_texture_rid(const RID &p_rid) { rs_texture_ = p_rid; }
  RID get_rs_texture_rid() const { return rs_texture_; }

  /// Update the underlying texture from a new Image.
  void update_from_image(const Ref<Image> &p_image);

  virtual int32_t _get_width() const override;
  virtual int32_t _get_height() const override;
  virtual bool _has_alpha() const override;
  virtual bool _is_pixel_opaque(int32_t p_x, int32_t p_y) const override;

protected:
  template <typename T, typename B>
  static void register_virtuals() {
    Texture2D::register_virtuals<T, B>();
  }

private:
  RID rs_texture_;
  int32_t width_ = 0;
  int32_t height_ = 0;
};

} // namespace godot

#endif // HAP_TEXTURE_2D_H