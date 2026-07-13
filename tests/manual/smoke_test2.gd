extends SceneTree

const SmokeCommon = preload("res://tests/manual/smoke_common.gd")

var player: HapPlayer
var completed_count := 0
var looped_count := 0

func _init():
	var stream = SmokeCommon.make_stream("res://tests/fixtures/hap1.mov")

	player = SmokeCommon.make_player(self)
	player.connect("playback_completed", _on_completed)
	player.connect("playback_looped", _on_looped)

	player.loop = false
	player.playback_speed = 20.0  # fast-forward to hit the end quickly
	player.stream = stream

	await SmokeCommon.wait_for_opened(self, player)

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

func _on_completed():
	completed_count += 1
	print("SIGNAL: playback_completed at position ", player.stream_position)

func _on_looped():
	looped_count += 1
