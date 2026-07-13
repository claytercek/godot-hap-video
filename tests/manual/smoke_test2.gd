extends SceneTree

var player: HapPlayer
var opened_fired := false
var completed_count := 0
var looped_count := 0

func _init():
	var stream = HapVideoStream.new()
	stream.set_file("res://tests/fixtures/hap1.mov")

	player = HapPlayer.new()
	root.add_child(player)
	player.connect("opened", _on_opened)
	player.connect("playback_completed", _on_completed)
	player.connect("playback_looped", _on_looped)

	player.loop = false
	player.playback_speed = 20.0  # fast-forward to hit the end quickly
	player.stream = stream

	for i in range(120):
		await process_frame
		if opened_fired:
			break

	player.play()
	for i in range(300):
		await process_frame
		if completed_count > 0:
			break

	print("completed_count: ", completed_count)
	print("looped_count: ", looped_count)
	print("final stream_position: ", player.stream_position)
	print("final duration: ", player.duration)

	quit()

func _on_opened():
	opened_fired = true

func _on_completed():
	completed_count += 1
	print("SIGNAL: playback_completed at position ", player.stream_position)

func _on_looped():
	looped_count += 1
