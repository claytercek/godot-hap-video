#include "hap_video_stream.h"

#include "hap_video_stream_playback.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {

void HapVideoStream::_bind_methods() {
  ClassDB::bind_method(D_METHOD("set_file", "file"), &HapVideoStream::set_file);
  ClassDB::bind_method(D_METHOD("get_file"), &HapVideoStream::get_file);
  ADD_PROPERTY(PropertyInfo(Variant::STRING, "file", PROPERTY_HINT_FILE, "*.mov"),
               "set_file", "get_file");
}

void HapVideoStream::set_file(const String &p_file) {
  file_path = p_file;
}

String HapVideoStream::get_file() {
  return file_path;
}

Ref<VideoStreamPlayback> HapVideoStream::_instantiate_playback() {
  Ref<HapVideoStreamPlayback> playback;
  playback.instantiate();

  // The stock VideoStreamPlayer caches playback->get_texture() as soon as
  // the stream is set and expects a texture with its final size (as with
  // the engine's synchronous Theora open). Block here until the open
  // settles and materialize the GPU resources, so the drop-in layer gets
  // synchronous-open semantics; HapPlayer keeps the async path.
  if (!playback->open(file_path) || !playback->wait_for_open() ||
      !playback->poll_ready()) {
    ERR_PRINT("HapVideo: Failed to open: " + file_path);
    return Ref<VideoStreamPlayback>();
  }

  return playback;
}

} // namespace godot