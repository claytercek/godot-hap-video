#include "hap_resource_format_loader.h"

#include "hap_video_stream.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {

PackedStringArray HapResourceFormatLoader::_get_recognized_extensions() const {
  PackedStringArray exts;
  exts.append("mov");
  return exts;
}

bool HapResourceFormatLoader::_handles_type(const StringName &p_type) const {
  return p_type == StringName("VideoStream");
}

String HapResourceFormatLoader::_get_resource_type(const String &p_path) const {
  String ext = p_path.get_extension();
  if (ext == "mov") {
    return "VideoStream";
  }
  return "";
}

Variant HapResourceFormatLoader::_load(const String &p_path,
                                       const String &p_original_path,
                                       bool p_use_sub_threads,
                                       int32_t p_cache_mode) const {
  if (!FileAccess::file_exists(p_path)) {
    ERR_PRINT("HapVideo: File not found: " + p_path);
    return Ref<Resource>();
  }

  Ref<HapVideoStream> stream;
  stream.instantiate();
  stream->set_file(p_path);
  return stream;
}

} // namespace godot