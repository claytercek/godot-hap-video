shader_type canvas_item;

// HapPlayer.get_texture() supplies a stable Texture2DRD for this sampler2D.
// Custom materials need no HapPlayer-specific shader code.
uniform sampler2D video_texture: filter_linear;

void fragment() {
	COLOR = texture(video_texture, UV);
}
