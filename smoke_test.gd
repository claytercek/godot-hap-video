extends SceneTree

var player: HapPlayer
var opened_fired := false
var looped_count := 0
var completed_fired := false
var error_message := ""

func _init():
	var stream = HapVideoStream.new()
	stream.set_file("res://tests/fixtures/hap1.mov")

	player = HapPlayer.new()
	root.add_child(player)
	player.connect("opened", _on_opened)
	player.connect("playback_looped", _on_looped)
	player.connect("playback_completed", _on_completed)
	player.connect("error_occurred", _on_error)

	player.loop = true
	player.playback_speed = 1.0
	player.stream = stream

	for i in range(120):
		await process_frame
		if opened_fired:
			break

	print("opened_fired: ", opened_fired)
	print("error_message: ", error_message)
	print("frame_rate: ", player.frame_rate)
	print("width: ", player.width)
	print("height: ", player.height)
	print("duration: ", player.duration)
	print("frame_count: ", player.frame_count)

	var tex = player.get_texture()
	print("texture: ", tex)

	player.play()
	for i in range(10):
		await process_frame
	print("stream_position after play (forward): ", player.stream_position)

	# Reverse
	player.playback_speed = -1.0
	for i in range(10):
		await process_frame
	print("stream_position after reverse: ", player.stream_position)

	# Step frame (should auto-pause)
	player.playback_speed = 1.0
	player.play()
	for i in range(5):
		await process_frame
	player.step_frame(3)
	await process_frame
	print("paused after step_frame: ", player.paused)
	print("stream_position after step: ", player.stream_position)

	print("looped_count so far: ", looped_count)

	quit()

func _on_opened():
	opened_fired = true
	print("SIGNAL: opened")

func _on_looped():
	looped_count += 1
	print("SIGNAL: playback_looped")

func _on_completed():
	completed_fired = true
	print("SIGNAL: playback_completed")

func _on_error(msg):
	error_message = msg
	print("SIGNAL: error_occurred: ", msg)
