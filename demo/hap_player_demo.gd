extends Control

const FIXTURE_PATH := "res://tests/fixtures/hap1.mov"

var player: HapPlayer
var display: ColorRect
var status_label: Label
var ping_pong_check: CheckButton
var play_pause_button: Button

var ping_pong := false

func _ready():
	custom_minimum_size = Vector2(640, 480)

	player = HapPlayer.new()
	add_child(player)

	display = ColorRect.new()
	display.size = Vector2(640, 360)
	display.material = ShaderMaterial.new()
	display.material.shader = load("res://demo/video_display.gdshader")
	add_child(display)

	var controls := HBoxContainer.new()
	controls.position = Vector2(0, 370)
	add_child(controls)

	play_pause_button = Button.new()
	play_pause_button.text = "Play"
	play_pause_button.pressed.connect(_on_play_pause_pressed)
	controls.add_child(play_pause_button)

	var step_back := Button.new()
	step_back.text = "< Step"
	step_back.pressed.connect(func(): player.step_frame(-1))
	controls.add_child(step_back)

	var step_forward := Button.new()
	step_forward.text = "Step >"
	step_forward.pressed.connect(func(): player.step_frame(1))
	controls.add_child(step_forward)

	ping_pong_check = CheckButton.new()
	ping_pong_check.text = "Ping-pong"
	ping_pong_check.toggled.connect(func(pressed): ping_pong = pressed)
	controls.add_child(ping_pong_check)

	status_label = Label.new()
	status_label.position = Vector2(0, 410)
	add_child(status_label)

	player.loop = false
	player.autoplay = false

	player.opened.connect(_on_opened)
	player.playback_completed.connect(_on_playback_completed)
	player.error_occurred.connect(_on_error_occurred)

	var stream := HapVideoStream.new()
	stream.file = FIXTURE_PATH
	player.stream = stream

func _process(_delta):
	if not player or player.frame_count <= 0:
		return
	var frame := int(player.stream_position * player.frame_rate)
	status_label.text = "frame %d/%d  speed %.2f  paused=%s" % [
		frame, player.frame_count, player.playback_speed, player.paused
	]
	play_pause_button.text = "Play" if player.paused else "Pause"

func _on_opened():
	display.material.set_shader_parameter("video_texture", player.get_texture())
	player.play()

func _on_playback_completed():
	# Ping-pong: instead of restarting, reverse direction and keep playing.
	if ping_pong:
		player.playback_speed = -player.playback_speed
		player.play()

func _on_play_pause_pressed():
	if player.paused:
		player.play()
	else:
		player.pause()

func _on_error_occurred(message: String):
	status_label.text = "error: " + message
