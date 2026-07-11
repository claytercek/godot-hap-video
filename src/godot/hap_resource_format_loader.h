#ifndef HAP_RESOURCE_FORMAT_LOADER_H
#define HAP_RESOURCE_FORMAT_LOADER_H

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/resource_format_loader.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace godot {

class HapResourceFormatLoader : public ResourceFormatLoader {
  GDEXTENSION_CLASS(HapResourceFormatLoader, ResourceFormatLoader)

public:
  virtual Variant _load(const String &p_path, const String &p_original_path,
                        bool p_use_sub_threads,
                        int32_t p_cache_mode) const override;
  virtual PackedStringArray _get_recognized_extensions() const override;
  virtual bool _handles_type(const StringName &p_type) const override;
  virtual String _get_resource_type(const String &p_path) const override;

protected:
  template <typename T, typename B>
  static void register_virtuals() {
    ResourceFormatLoader::register_virtuals<T, B>();
  }
};

} // namespace godot

#endif // HAP_RESOURCE_FORMAT_LOADER_H