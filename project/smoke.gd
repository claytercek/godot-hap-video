extends Node

const OPEN_TIMEOUT_MSEC := 10_000

var _opened := false
var _error_message := ""


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await _verify()


func _verify() -> void:
	for extension_class in ["HapVideoStream", "HapPlayer"]:
		if not ClassDB.class_exists(extension_class):
			_fail("missing extension class %s" % extension_class)
			return

	var stream: Object = ClassDB.instantiate("HapVideoStream")
	var player: Object = ClassDB.instantiate("HapPlayer")
	if stream == null or player == null or not player is Node:
		_fail("failed to instantiate Hap extension classes")
		return
	add_child(player)
	player.opened.connect(func(): _opened = true)
	player.error_occurred.connect(func(message: String): _error_message = message)

	stream.file = "res://hap1.mov"
	player.stream = stream
	# Controls issued while the candidate is still opening must travel with it
	# when the pending pair is promoted.
	player.loop = true
	player.playback_speed = 0.75
	player.stream_position = 0.01
	player.paused = true
	if not await _await_opened("opening fixture"):
		return
	if not player.loop or abs(player.playback_speed - 0.75) > 0.001:
		_fail("pre-open playback policy was lost during promotion")
		return
	if not player.paused or abs(player.stream_position - 0.01) > 0.001:
		_fail("pre-open playback state was lost during promotion")
		return
	if player.get_texture() == null:
		_fail("opened fixture did not expose a texture")
		return
	if player.frame_count <= 0 or player.frame_rate <= 0.0:
		_fail("opened fixture did not expose frame metadata")
		return
	if player.width <= 0 or player.height <= 0 or player.duration <= 0.0:
		_fail("opened fixture did not expose video dimensions and duration")
		return

	# Reassigning the same resource must preserve the active stream/playback.
	var assigned_stream: Object = player.stream
	player.stream = assigned_stream
	await get_tree().process_frame
	if player.stream != assigned_stream or player.get_texture() == null:
		_fail("self-assignment did not preserve active playback")
		return

	# An immediately rejected replacement must report error_occurred and leave
	# the active stream/playback pair intact.
	var empty_stream: Object = ClassDB.instantiate("HapVideoStream")
	_error_message = ""
	player.stream = empty_stream
	if not await _await_error("opening an empty stream"):
		return
	if player.stream != assigned_stream or player.get_texture() == null:
		_fail("failed replacement did not preserve active playback")
		return

	# A nonempty malformed file is accepted by the synchronous setter and
	# rejected later by the asynchronous mmap/demux job. The candidate must not
	# replace the active pair until that work and GPU initialization succeed.
	var malformed_path := "user://hap_video_smoke_malformed.mov"
	var malformed_file := FileAccess.open(malformed_path, FileAccess.WRITE)
	if malformed_file == null:
		_fail("could not create malformed replacement fixture")
		return
	malformed_file.store_string("not an mp4")
	malformed_file = null

	var malformed_stream: Object = ClassDB.instantiate("HapVideoStream")
	malformed_stream.file = malformed_path
	_error_message = ""
	player.stream = malformed_stream
	if not await _await_error("opening a malformed stream asynchronously"):
		return
	if player.stream != assigned_stream or player.get_texture() == null:
		_fail("asynchronously rejected replacement did not preserve active playback")
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(malformed_path))

	# Controls set while a valid replacement is still opening must belong to
	# that candidate and survive its eventual promotion to the active pair.
	var replacement_stream: Object = ClassDB.instantiate("HapVideoStream")
	replacement_stream.file = "res://hap1.mov"
	_opened = false
	_error_message = ""
	player.stream = replacement_stream
	player.loop = true
	player.playback_speed = 0.5
	player.stream_position = 0.2
	player.paused = true
	if not await _await_opened("opening a configured replacement"):
		return
	if player.stream != replacement_stream or not player.loop:
		_fail("successful replacement did not become active with loop state")
		return
	if abs(player.playback_speed - 0.5) > 0.001 or abs(player.stream_position - 0.2) > 0.001 or not player.paused:
		_fail("pre-open playback controls did not survive replacement")
		return
	assigned_stream = replacement_stream

	player.play()
	await get_tree().process_frame
	player.pause()
	var duration: float = player.duration
	var seek_target: float = minf(duration * 0.5, 0.25)
	player.stream_position = seek_target
	await get_tree().process_frame
	if abs(player.stream_position - seek_target) > 0.001:
		_fail("seek did not retain the requested position")
		return

	player.stream = null
	if player.stream != null or player.get_texture() != null:
		_fail("clearing stream did not clear playback state")
		return

	player.queue_free()
	print("SMOKE: Hap fixture opened, played, sought, cleared, and rejected synchronous/asynchronous invalid replacements")
	get_tree().quit(0)


func _await_opened(action: String) -> bool:
	var deadline := Time.get_ticks_msec() + OPEN_TIMEOUT_MSEC
	while not _opened and _error_message == "" and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if _error_message != "":
		_fail("%s failed: %s" % [action, _error_message])
		return false
	if not _opened:
		_fail("%s timed out after %d ms" % [action, OPEN_TIMEOUT_MSEC])
		return false
	return true


func _await_error(action: String) -> bool:
	var deadline := Time.get_ticks_msec() + OPEN_TIMEOUT_MSEC
	while _error_message == "" and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if _error_message == "":
		_fail("%s did not emit error_occurred within %d ms" % [action, OPEN_TIMEOUT_MSEC])
		return false
	return true


func _fail(message: String) -> void:
	push_error("SMOKE: %s" % message)
	get_tree().quit(1)
