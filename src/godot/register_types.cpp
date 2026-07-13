#include "register_types.h"

#include "hap_player.h"
#include "hap_resource_format_loader.h"
#include "hap_video_stream.h"
#include "hap_video_stream_playback.h"

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static Ref<HapResourceFormatLoader> hap_loader;

void initialize_hap_video_module(ModuleInitializationLevel p_level) {
  if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
    return;
  }

  ClassDB::register_class<HapResourceFormatLoader>();
  ClassDB::register_class<HapVideoStream>();
  ClassDB::register_class<HapVideoStreamPlayback>();
  ClassDB::register_class<HapPlayer>();

  // The ResourceLoader singleton doesn't exist yet at SERVERS level, so
  // the loader hook happens here -- still before any project code runs.
  hap_loader.instantiate();
  ResourceLoader::get_singleton()->add_resource_format_loader(hap_loader);
}

void uninitialize_hap_video_module(ModuleInitializationLevel p_level) {
  if (p_level == MODULE_INITIALIZATION_LEVEL_SCENE) {
    ResourceLoader::get_singleton()->remove_resource_format_loader(hap_loader);
    hap_loader.unref();
  }
}

extern "C" {

// GDExtension entry point.
GDExtensionBool GDE_EXPORT hap_video_init(
    GDExtensionInterfaceGetProcAddress p_get_proc_address,
    GDExtensionClassLibraryPtr p_library,
    GDExtensionInitialization *r_initialization) {
  godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library,
                                                  r_initialization);

  init_obj.register_initializer(initialize_hap_video_module);
  init_obj.register_terminator(uninitialize_hap_video_module);
  init_obj.set_minimum_library_initialization_level(
      MODULE_INITIALIZATION_LEVEL_SERVERS);

  return init_obj.init();
}
}