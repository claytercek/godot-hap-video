#ifndef HAP_VIDEO_STREAM_H
#define HAP_VIDEO_STREAM_H

#include "hap_video_stream_playback.h"

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/video_stream.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class HapVideoStream : public VideoStream {
  GDCLASS(HapVideoStream, VideoStream)

public:
  void set_file(const String &p_file);
  String get_file();

  virtual Ref<VideoStreamPlayback> _instantiate_playback() override;

protected:
  static void _bind_methods();

private:
  String file_path;
};

} // namespace godot

#endif // HAP_VIDEO_STREAM_H