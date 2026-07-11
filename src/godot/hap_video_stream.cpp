#include "hap_video_stream.h"

#include "hap_video_stream_playback.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {

void HapVideoStream::set_file(const String &p_file) {
  file_path = p_file;
}

String HapVideoStream::get_file() {
  return file_path;
}

Ref<VideoStreamPlayback> HapVideoStream::_instantiate_playback() {
  Ref<HapVideoStreamPlayback> playback;
  playback.instantiate();

  if (!playback->open(file_path)) {
    ERR_PRINT("HapVideo: Failed to open: " + file_path);
    return Ref<VideoStreamPlayback>();
  }

  return playback;
}

} // namespace godot