#ifndef HAP_VIDEO_STREAM_H
#define HAP_VIDEO_STREAM_H

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/video_stream.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class HapVideoStreamPlayback;

class HapVideoStream : public VideoStream {
  GDEXTENSION_CLASS(HapVideoStream, VideoStream)

public:
  void set_file(const String &p_file);
  String get_file();

  virtual Ref<VideoStreamPlayback> _instantiate_playback() override;

protected:
  template <typename T, typename B>
  static void register_virtuals() {
    VideoStream::register_virtuals<T, B>();
  }

private:
  String file_path;
};

} // namespace godot

#endif // HAP_VIDEO_STREAM_H