shader_type canvas_item;

// Fed from HapPlayer.get_texture() in the demo script -- the whole point
// is that the stable Texture2DRD works as an ordinary sampler2D uniform
// in a hand-written material, with no HapPlayer-specific shader code.
uniform sampler2D video_texture: filter_linear;

void fragment() {
	COLOR = texture(video_texture, UV);
}
