## Shared helpers for the manual smoke-test scripts (smoke_test.gd,
## smoke_test2.gd): building a HapPlayer/HapVideoStream pair and waiting for
## the player to finish opening. Kept intentionally minimal -- these are
## manual harnesses, not an automated suite.
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

## Polls process_frame until `player` emits "opened" or `max_frames` elapse.
## Returns whether the signal fired. Must be called (with `await`) after the
## caller has connected its own signal handlers and assigned player.stream.
static func wait_for_opened(tree: SceneTree, player: HapPlayer, max_frames: int = 120) -> bool:
	var opened := false
	var on_opened := func(): opened = true
	player.connect("opened", on_opened)
	for i in range(max_frames):
		await tree.process_frame
		if opened:
			break
	player.disconnect("opened", on_opened)
	return opened
