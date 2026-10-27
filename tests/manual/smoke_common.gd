## Build HapPlayer/HapVideoStream pairs and await opening for the manual
## scripts smoke_test.gd and smoke_test2.gd.
class_name SmokeCommon
extends RefCounted

static func make_stream(path: String) -> HapVideoStream:
	var stream = HapVideoStream.new()
	stream.set_file(path)
	return stream

static func make_player(tree: SceneTree) -> HapPlayer:
	var player = HapPlayer.new()
	tree.root.add_child(player)
	return player

## Poll process_frame until "opened" or max_frames; return whether it fired.
## Await this after connecting the caller's handlers and assigning player.stream.
static func wait_for_opened(tree: SceneTree, player: HapPlayer, max_frames: int = 120) -> bool:
	# GDScript lambdas capture locals by value; share changes through an array.
	var opened := [false]
	var on_opened := func(): opened[0] = true
	player.connect("opened", on_opened)
	for i in range(max_frames):
		await tree.process_frame
		if opened[0]:
			break
	player.disconnect("opened", on_opened)
	return opened[0]
