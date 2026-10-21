extends Node
## Run with a RenderingDevice and real audio driver (not --headless).
## Captures upstream of a muted output bus: tests never play audible sound.

const BUS := &"HapAudioSmokeCapture"
const SINK := &"HapAudioSmokeMuted"
const FIXTURE := "res://../tests/fixtures/hap1_audio.mov"
const STEREO_FIXTURES := [
	"res://../tests/fixtures/hap1_pcm16be_stereo.mov",
	"res://../tests/fixtures/hap1_pcm24be_stereo.mov",
]
const CAPTURE_WINDOW_SECONDS := 0.12
var _capture: AudioEffectCapture
var _opened := false
var _errors: Array[String] = []
var _completed := 0
var _looped := 0
var _failed := false
var _temporary_files: Array[String] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Independent hard deadline, including any accidentally stalled test await.
	get_tree().create_timer(75.0).timeout.connect(func(): _fail("hard timeout"))
	await get_tree().process_frame
	await _verify()


func _verify() -> void:
	var audio_driver := AudioServer.get_driver_name()
	print("AUDIO_SMOKE_DRIVER: %s" % audio_driver)
	if audio_driver == "Dummy":
		_fail("PCM capture requires a real audio driver")
		return
	if not ClassDB.class_exists("HapPlayer"):
		_fail("extension unavailable")
		return
	AudioServer.add_bus()
	var sink := AudioServer.bus_count - 1
	AudioServer.set_bus_name(sink, SINK)
	AudioServer.set_bus_mute(sink, true)
	AudioServer.add_bus()
	var capture_bus := AudioServer.bus_count - 1
	AudioServer.set_bus_name(capture_bus, BUS)
	AudioServer.set_bus_send(capture_bus, SINK)
	_capture = AudioEffectCapture.new()
	_capture.buffer_length = 1.0
	AudioServer.add_bus_effect(capture_bus, _capture)

	var stream: Object = ClassDB.instantiate("HapVideoStream")
	stream.file = ProjectSettings.globalize_path(FIXTURE)
	var hap: Object = ClassDB.instantiate("HapPlayer")
	hap.process_mode = Node.PROCESS_MODE_PAUSABLE
	hap.bus = BUS
	hap.volume_db = -3.0
	hap.opened.connect(func(): _opened = true)
	hap.error_occurred.connect(func(message: String): _errors.append(message))
	hap.playback_completed.connect(func(): _completed += 1)
	hap.playback_looped.connect(func(): _looped += 1)
	add_child(hap)
	hap.stream = stream
	var deadline := Time.get_ticks_msec() + 10000
	while not _opened and _errors.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not _opened or not _errors.is_empty():
		_fail("HapPlayer open failed: %s" % _errors)
		return
	if not hap.has_audio or hap.audio_sample_rate <= 0 or hap.audio_channels not in [1, 2]:
		_fail("PCM metadata missing after opened")
		return
	if hap.bus != BUS or absf(hap.volume_db + 3.0) > 0.001:
		_fail("bus/volume settings did not survive lazy sink creation")
		return
	if not await _silent("unplayed candidate"):
		return
	hap.play()
	if not await _audible("HapPlayer"):
		return
	if not await _mono("HapPlayer mono duplication"):
		return
	var generator_ref: WeakRef
	var generator_playback_ref: WeakRef
	var retained_playback: AudioStreamGeneratorPlayback
	for child in hap.get_children(true):
		if child is AudioStreamPlayer:
			if not child.stream is AudioStreamGenerator or child.stream.mix_rate != hap.audio_sample_rate or child.stream.mix_rate_mode != AudioStreamGenerator.MIX_RATE_CUSTOM:
				_fail("HapPlayer sink is not a custom-source-rate generator")
				return
			generator_ref = weakref(child.stream)
			retained_playback = child.get_stream_playback()
			generator_playback_ref = weakref(retained_playback)
	if generator_ref == null:
		_fail("HapPlayer did not create its private generator child")
		return
	hap.pause()
	if not await _silent("HapPlayer pause"):
		return
	# Godot's generator playback keeps a raw source pointer during its fade.
	# A retained old playback must therefore pin its source after sink teardown.
	if generator_ref.get_ref() == null:
		_fail("retained generator playback lost its source on pause")
		return
	hap.stream_position = 0.15
	hap.play()
	if not await _audible("HapPlayer seek/resume"):
		return
	for child in hap.get_children(true):
		if child is AudioStreamPlayer and child.stream == generator_ref.get_ref():
			_fail("pause/resume did not recreate the generator sink")
			return
	if generator_ref.get_ref() == null:
		_fail("old playback lost its generator during sink recreation")
		return
	hap.volume_db = -80.0
	if not await _silent("HapPlayer volume"):
		return
	hap.volume_db = -3.0
	hap.playback_speed = 0.5
	if not await _silent("HapPlayer non-1x"):
		return
	hap.playback_speed = -1.0
	if not await _silent("HapPlayer reverse"):
		return
	hap.playback_speed = 1.0
	hap.stream_position = 0.2
	hap.play()
	if not await _audible("HapPlayer normal speed restored"):
		return
	hap.step_frame(1)
	if not await _silent("HapPlayer step"):
		return
	hap.play()
	get_tree().paused = true
	if not await _silent("HapPlayer tree pause"):
		return
	# Explicit pause while tree-paused must survive unpause notifications.
	hap.pause()
	get_tree().paused = false
	if not await _silent("explicit pause after tree unpause"):
		return
	hap.stream_position = 0.1
	hap.play()
	if not await _audible("HapPlayer tree resume"):
		return
	# A rejected replacement and its pending controls must not stop active sound.
	var invalid: Object = ClassDB.instantiate("HapVideoStream")
	invalid.file = ProjectSettings.globalize_path("res://missing_audio_smoke.mov")
	hap.stream = invalid
	hap.pause()
	deadline = Time.get_ticks_msec() + 10000
	while _errors.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if _errors.is_empty() or hap.stream != stream:
		_fail("invalid replacement did not preserve active stream")
		return
	if not await _audible("active audio after failed replacement"):
		return
	hap.loop = true
	hap.stream_position = hap.duration - 0.1
	hap.play()
	await _wait_audio_seconds(0.25)
	if _looped == 0 or not await _audible("HapPlayer loop"):
		_fail("HapPlayer did not loop")
		return
	hap.loop = false
	hap.stream_position = hap.duration - 0.12
	hap.play()
	await _wait_audio_seconds(0.35)
	if _completed == 0:
		_fail("HapPlayer did not complete")
		return
	if not await _silent("HapPlayer completion"):
		return
	hap.stop()
	if absf(hap.stream_position) > 0.001:
		_fail("HapPlayer stop did not reset position")
		return
	hap.stream = null
	if hap.has_audio or hap.audio_sample_rate != 0 or hap.audio_channels != 0:
		_fail("clearing stream retained audio metadata")
		return
	# Free while a fresh generator is actively playing, not just after stop.
	# Children are destroyed before the extension's destructor callback.
	_opened = false
	hap.stream = stream
	deadline = Time.get_ticks_msec() + 10000
	while not _opened and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not _opened:
		_fail("HapPlayer reopen timed out")
		return
	hap.play()
	if not await _audible("HapPlayer active teardown setup"):
		return
	var active_generator_ref: WeakRef
	var active_playback_ref: WeakRef
	for child in hap.get_children(true):
		if child is AudioStreamPlayer:
			active_generator_ref = weakref(child.stream)
			active_playback_ref = weakref(child.get_stream_playback())
	hap.queue_free()
	await get_tree().process_frame
	await _wait_audio_seconds(0.15)
	if generator_ref.get_ref() == null or generator_playback_ref.get_ref() == null:
		_fail("retained old playback lost its generator when HapPlayer was freed")
		return
	if active_generator_ref == null or active_playback_ref == null or active_generator_ref.get_ref() != null or active_playback_ref.get_ref() != null:
		_fail("active generator or get_stream_playback reference leaked during free")
		return
	retained_playback = null
	await _wait_audio_seconds(0.15)
	if generator_ref.get_ref() != null or generator_playback_ref.get_ref() != null:
		_fail("released old playback or its pinned generator leaked")
		return

	var stock := VideoStreamPlayer.new()
	stock.process_mode = Node.PROCESS_MODE_PAUSABLE
	stock.bus = BUS
	stock.buffering_msec = 80
	stock.volume_db = -3.0
	add_child(stock)
	stock.stream = stream
	stock.paused = true
	_capture.clear_buffer()
	stock.play()
	if not stock.paused or not stock.is_playing() or not await _silent_immediate("VideoStreamPlayer paused before play"):
		_fail("VideoStreamPlayer play did not preserve explicit paused state")
		return
	_capture.clear_buffer()
	stock.stop()
	stock.play()
	if not stock.paused or not stock.is_playing() or not await _silent_immediate("VideoStreamPlayer paused stop/play"):
		_fail("VideoStreamPlayer stop/play did not preserve explicit paused state")
		return
	stock.paused = false
	if not await _audible("VideoStreamPlayer"):
		return
	if not await _mono("VideoStreamPlayer mono duplication"):
		return
	stock.paused = true
	if not await _silent("VideoStreamPlayer pause"):
		return
	stock.stream_position = 0.2
	stock.paused = false
	if not await _audible("VideoStreamPlayer seek/resume"):
		return
	stock.volume_db = -80.0
	if not await _silent("VideoStreamPlayer volume"):
		return
	stock.volume_db = -3.0
	# Stock speed_scale belongs to Godot's pitch-changing resampler; it is not
	# visible to playback virtuals and must NOT mute embedded PCM at non-1x.
	stock.speed_scale = 0.5
	if not await _audible("VideoStreamPlayer speed_scale"):
		return
	stock.speed_scale = 1.0
	stock.audio_track = 1
	if not await _silent("VideoStreamPlayer unsupported track"):
		return
	# This seek is a separate ordinary control test. The phase-changing stereo
	# tests below restore track 0 WITHOUT a seek, validating its live queue.
	stock.stream_position = 0.2
	stock.audio_track = 0
	if not await _audible("VideoStreamPlayer first track restored"):
		return
	stock.loop = true
	stock.stream_position = stock.get_stream_length() - 0.1
	await _wait_audio_seconds(0.25)
	if not await _audible("VideoStreamPlayer loop"):
		return
	stock.loop = false
	stock.stream_position = stock.get_stream_length() - 0.12
	await _wait_audio_seconds(0.35)
	if stock.is_playing():
		_fail("VideoStreamPlayer EOS drain did not finish")
		return
	if not await _silent("VideoStreamPlayer completion"):
		return
	stock.play()
	stock.stop()
	if not await _silent("VideoStreamPlayer stop"):
		return
	stock.queue_free()
	stream = null
	invalid = null
	await get_tree().process_frame
	if not await _silent("mono players freed"):
		return
	for path in STEREO_FIXTURES:
		if not await _verify_stereo(path):
			return
	if not await _verify_unsupported():
		return
	if not await _verify_terminal_decode_failure():
		return
	_cleanup_temp_files()
	AudioServer.remove_bus(capture_bus)
	AudioServer.remove_bus(sink)
	print("AUDIO_SMOKE_REGRESSIONS: retained generator lifetime, paused play/restart, no-seek track restore, and terminal-loop shutdown passed")
	print("AUDIO_SMOKE: mono16, stereo16BE, stereo24BE captured from both players; seek/loop content, controls, unsupported audio, and teardown passed")
	get_tree().quit(0)


func _verify_stereo(path: String) -> bool:
	var stream: Object = ClassDB.instantiate("HapVideoStream")
	stream.file = ProjectSettings.globalize_path(path)
	var hap: Object = ClassDB.instantiate("HapPlayer")
	hap.bus = BUS
	hap.volume_db = -3.0
	_opened = false
	_errors.clear()
	hap.opened.connect(func(): _opened = true)
	hap.error_occurred.connect(func(message: String): _errors.append(message))
	hap.playback_looped.connect(func(): _looped += 1)
	add_child(hap)
	_capture.clear_buffer()
	hap.stream = stream
	# Controls on the unpublished candidate must not create an audible sink.
	hap.play()
	hap.pause()
	if not await _wait_open(hap, path):
		return false
	await _wait_audio_seconds(0.12)
	var candidate_stats := _analyze(_capture.get_buffer(_capture.get_frames_available()))
	if candidate_stats.peak > 0.0001:
		_fail("unpublished candidate produced audio: %s" % candidate_stats)
		return false
	if not hap.has_audio or hap.audio_sample_rate != 48000 or hap.audio_channels != 2:
		_fail("%s: wrong stereo PCM metadata" % path)
		return false
	if not await _silent("paused candidate %s" % path):
		return false
	hap.stream_position = 0.15
	hap.play()
	if not await _pattern("HapPlayer %s start" % path, false):
		return false
	hap.stream_position = 1.2
	if not await _pattern("HapPlayer %s forward seek" % path, true):
		return false
	hap.stream_position = 0.15
	# The audio thread keeps capturing while the main thread is delayed. Force
	# an oversized queue AFTER the full measurement window, not a source stall
	# inside it. The same strict backward-seek content assertions must still
	# judge exactly 120 ms, rather than diluting them with the later dropout.
	var read_delay_msec := 900 if path == STEREO_FIXTURES[0] else 0
	var stalled_playback_id := 0
	if read_delay_msec > 0:
		stalled_playback_id = _generator_playback_id(hap)
	if not await _pattern("HapPlayer %s backward seek" % path, false, read_delay_msec):
		return false
	if read_delay_msec > 0:
		# process_frame precedes child processing; allow reconciliation to run.
		await get_tree().process_frame
		await get_tree().process_frame
		if stalled_playback_id == 0 or _generator_playback_id(hap) != stalled_playback_id:
			_fail("ordinary starvation recovery replaced the generator playback")
			return false
	hap.bus = SINK
	if not await _silent("HapPlayer live bus routing"):
		return false
	hap.bus = BUS
	hap.loop = true
	hap.stream_position = 1.4
	if not await _pattern("HapPlayer pre-loop generation", true):
		return false
	var previous_loops := _looped
	var deadline := Time.get_ticks_msec() + 3000
	while _looped == previous_loops and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if _looped == previous_loops:
		_fail("HapPlayer stereo loop timed out")
		return false
	if not await _pattern("HapPlayer fresh loop generation", false):
		return false
	hap.queue_free()
	await get_tree().process_frame
	if not await _silent("stereo HapPlayer freed"):
		return false

	# Run independently: simultaneous sources could hide channel/flush bugs.
	var stock := VideoStreamPlayer.new()
	stock.bus = BUS
	stock.volume_db = -3.0
	stock.buffering_msec = 80
	add_child(stock)
	stock.stream = stream
	stock.play()
	stock.stream_position = 0.15
	if not await _pattern("VideoStreamPlayer %s start" % path, false):
		return false
	stock.stream_position = 1.2
	if not await _pattern("VideoStreamPlayer %s forward seek" % path, true):
		return false
	stock.stream_position = 0.15
	if not await _pattern("VideoStreamPlayer %s backward seek" % path, false):
		return false
	stock.audio_track = 1
	if not await _silent("VideoStreamPlayer track disabled before phase change"):
		return false
	deadline = Time.get_ticks_msec() + 3000
	while stock.stream_position < 1.2 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if stock.stream_position < 1.2 or stock.stream_position > 1.6:
		_fail("disabled audio track did not advance across the fixture phase change")
		return false
	if not await _restore_current_pattern(stock, "VideoStreamPlayer %s no-seek track restore" % path):
		return false
	stock.loop = true
	stock.stream_position = 1.4
	if not await _pattern("VideoStreamPlayer pre-loop generation", true):
		return false
	deadline = Time.get_ticks_msec() + 3000
	while stock.stream_position > 0.5 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if stock.stream_position > 0.5:
		_fail("VideoStreamPlayer stereo loop timed out")
		return false
	if not await _pattern("VideoStreamPlayer fresh loop generation", false):
		return false
	stock.queue_free()
	stream = null
	await get_tree().process_frame
	return await _silent("stereo VideoStreamPlayer freed")


func _generator_playback_id(hap: Object) -> int:
	for child in hap.get_children(true):
		if child is AudioStreamPlayer and child.stream is AudioStreamGenerator and child.has_stream_playback():
			return child.get_stream_playback().get_instance_id()
	return 0


func _verify_unsupported() -> bool:
	# Classification-only synthetic fixture: PCM payload with an unsupported
	# mp4a FourCC. This is intentionally NOT an AAC bitstream or decoder test.
	var bytes := FileAccess.get_file_as_bytes(STEREO_FIXTURES[0])
	var marker := -1
	for i in range(bytes.size() - 4, -1, -1):
		if bytes.slice(i, i + 4) == "twos".to_ascii_buffer():
			marker = i
			break
	if marker < 0:
		_fail("cannot locate synthetic unsupported audio sample entry")
		return false
	for i in range(4):
		bytes[marker + i] = "mp4a".to_ascii_buffer()[i]
	var path := "user://audio_smoke_unsupported_classification.mov"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("cannot write synthetic unsupported audio fixture")
		return false
	file.store_buffer(bytes)
	file.close()
	_temporary_files.append(path)
	var stream: Object = ClassDB.instantiate("HapVideoStream")
	stream.file = path
	var hap: Object = ClassDB.instantiate("HapPlayer")
	hap.bus = BUS
	_opened = false
	_errors.clear()
	hap.opened.connect(func(): _opened = true)
	hap.error_occurred.connect(func(message: String): _errors.append(message))
	add_child(hap)
	hap.stream = stream
	if not await _wait_open(hap, "unsupported audio classification"):
		return false
	if hap.has_audio or hap.audio_sample_rate != 0 or hap.audio_channels != 0:
		_fail("unsupported audio retained PCM metadata")
		return false
	hap.play()
	if not await _silent("unsupported audio HapPlayer"):
		return false
	if hap.stream_position < 0.1 or hap.get_texture() == null or not _errors.is_empty():
		_fail("unsupported audio prevented HapPlayer video playback")
		return false
	hap.queue_free()
	await get_tree().process_frame
	var stock := VideoStreamPlayer.new()
	stock.bus = BUS
	add_child(stock)
	stock.stream = stream
	stock.play()
	if not await _silent("unsupported audio VideoStreamPlayer"):
		return false
	if stock.stream_position < 0.1 or stock.get_video_texture() == null:
		_fail("unsupported audio prevented VideoStreamPlayer video playback")
		return false
	stock.queue_free()
	stream = null
	await get_tree().process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return true


func _verify_terminal_decode_failure() -> bool:
	# Fault injection only: invalidate one late Hap frame header, leaving all
	# video sample tables and PCM metadata/payload untouched. Do not commit it.
	var bytes := FileAccess.get_file_as_bytes(STEREO_FIXTURES[0])
	const CORRUPT_FRAME := 45
	var sample := _video_sample_range(bytes, CORRUPT_FRAME)
	if sample.x < 0 or sample.y - sample.x < 16:
		_fail("cannot locate late Hap sample for terminal decode fault injection")
		return false
	for i in range(sample.x, sample.x + 16):
		bytes[i] = 0
	var path := "user://audio_smoke_terminal_video_fault.mov"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("cannot write terminal video fault fixture")
		return false
	file.store_buffer(bytes)
	file.close()
	_temporary_files.append(path)
	var stream: Object = ClassDB.instantiate("HapVideoStream")
	stream.file = path
	var stock := VideoStreamPlayer.new()
	stock.bus = BUS
	stock.volume_db = -3.0
	stock.buffering_msec = 80
	stock.loop = true
	add_child(stock)
	stock.stream = stream
	stock.play()
	if not await _audible("terminal video fault: valid initial PCM"):
		return false
	stock.stream_position = float(CORRUPT_FRAME) / 30.0
	var deadline := Time.get_ticks_msec() + 3000
	while stock.is_playing() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if stock.is_playing() or not stock.loop:
		_fail("terminal video decode failure did not stop a looping stock player")
		return false
	if not await _silent("terminal video failure silences PCM"):
		return false
	var stopped_position := stock.stream_position
	await _wait_audio_seconds(0.35)
	if stock.is_playing() or absf(stock.stream_position - stopped_position) > 0.001:
		_fail("terminal video decode failure automatically restarted the loop")
		return false
	if not await _silent_immediate("terminal video failure remains silent"):
		return false
	stock.queue_free()
	stream = null
	await get_tree().process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return true


func _be32(bytes: PackedByteArray, offset: int) -> int:
	return (int(bytes[offset]) << 24) | (int(bytes[offset + 1]) << 16) | (int(bytes[offset + 2]) << 8) | int(bytes[offset + 3])


func _mov_child(bytes: PackedByteArray, begin: int, end: int, kind: String) -> Vector2i:
	if begin < 0 or end > bytes.size():
		return Vector2i(-1, -1)
	var offset := begin
	while offset + 8 <= end:
		var size := _be32(bytes, offset)
		# The generated fixtures use ordinary-size boxes; reject extensions
		# rather than guessing their layout or reading outside a parent box.
		if size < 8 or size > end - offset:
			return Vector2i(-1, -1)
		if bytes.slice(offset + 4, offset + 8).get_string_from_ascii() == kind:
			return Vector2i(offset + 8, offset + size)
		offset += size
	return Vector2i(-1, -1)


func _video_sample_range(bytes: PackedByteArray, frame: int) -> Vector2i:
	var moov := _mov_child(bytes, 0, bytes.size(), "moov")
	var track := _mov_child(bytes, moov.x, moov.y, "trak")
	var stbl := Vector2i(-1, -1)
	while track.x >= 0:
		var mdia := _mov_child(bytes, track.x, track.y, "mdia")
		var handler := _mov_child(bytes, mdia.x, mdia.y, "hdlr")
		if handler.x >= 0 and handler.y - handler.x >= 12 and bytes.slice(handler.x + 8, handler.x + 12).get_string_from_ascii() == "vide":
			var minf := _mov_child(bytes, mdia.x, mdia.y, "minf")
			stbl = _mov_child(bytes, minf.x, minf.y, "stbl")
			break
		track = _mov_child(bytes, track.y, moov.y, "trak")
	var stsz := _mov_child(bytes, stbl.x, stbl.y, "stsz")
	var stco := _mov_child(bytes, stbl.x, stbl.y, "stco")
	var stsc := _mov_child(bytes, stbl.x, stbl.y, "stsc")
	if (
		stsz.x < 0 or stsz.y - stsz.x < 12
		or stco.x < 0 or stco.y - stco.x < 12
		or stsc.x < 0 or stsc.y - stsc.x < 20
	):
		return Vector2i(-1, -1)
	var constant_size := _be32(bytes, stsz.x + 4)
	var count := _be32(bytes, stsz.x + 8)
	# This deliberately small reader accepts the generator's single video
	# chunk only, checking stsc rather than assuming the first mdat is video.
	if (
		frame < 0 or frame >= count
		or _be32(bytes, stco.x + 4) != 1 or _be32(bytes, stsc.x + 4) != 1
		or _be32(bytes, stsc.x + 8) != 1
		or _be32(bytes, stsc.x + 12) != count
		or _be32(bytes, stsc.x + 16) != 1
	):
		return Vector2i(-1, -1)
	if constant_size == 0 and stsz.y - stsz.x < 12 + count * 4:
		return Vector2i(-1, -1)
	var offset := _be32(bytes, stco.x + 8)
	for i in range(frame):
		offset += constant_size if constant_size > 0 else _be32(bytes, stsz.x + 12 + i * 4)
	var size := constant_size if constant_size > 0 else _be32(bytes, stsz.x + 12 + frame * 4)
	if offset < 0 or size <= 0 or offset + size > bytes.size():
		return Vector2i(-1, -1)
	return Vector2i(offset, offset + size)


func _restore_current_pattern(stock: VideoStreamPlayer, label: String) -> bool:
	_capture.clear_buffer()
	stock.audio_track = 0
	var data := PackedVector2Array()
	var started := false
	var deadline := Time.get_ticks_msec() + 1000
	# Judge the FIRST audible frames, not a later window that can hide stale
	# PCM draining from the disabled track. Ignore initial silence only.
	while data.size() < 1024 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var chunk := _capture.get_buffer(_capture.get_frames_available())
		for frame in chunk:
			if not started and frame.length_squared() < 0.000001:
				continue
			started = true
			data.append(frame)
			if data.size() == 1024:
				break
	return _check_pattern(label, true, _analyze(data))


func _cleanup_temp_files() -> void:
	for path in _temporary_files:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_temporary_files.clear()


func _wait_open(hap: Object, label: String) -> bool:
	var deadline := Time.get_ticks_msec() + 10000
	while not _opened and _errors.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not _opened or not _errors.is_empty() or hap.get_texture() == null:
		_fail("%s: open failed: %s" % [label, _errors])
		return false
	return true


func _wait_audio_seconds(seconds: float) -> void:
	# SceneTreeTimer subtracts the full frame delta, including time before its
	# creation. Audio settling must instead elapse AFTER this wait starts.
	var deadline := Time.get_ticks_usec() + ceili(seconds * 1000000.0)
	while Time.get_ticks_usec() < deadline:
		await get_tree().process_frame


func _stats(read_delay_msec: int = 0) -> Dictionary:
	_capture.clear_buffer()
	var begin := Time.get_ticks_usec()
	var frames := ceili(AudioServer.get_mix_rate() * CAPTURE_WINDOW_SECONDS)
	var deadline := Time.get_ticks_msec() + 1500
	# A SceneTree timer only bounds when the main thread may resume. Reading
	# ALL queued frames after it can turn 120 ms into a second of PCM followed
	# by starvation silence, corrupting RMS and zero-crossing normalization.
	# Wait for, then read, the exact oldest source-independent mix-frame window.
	while _capture.get_frames_available() < frames and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if _capture.get_frames_available() < frames:
		_fail("capture window timed out: need=%d available=%d elapsed_ms=%f" % [frames, _capture.get_frames_available(), (Time.get_ticks_usec() - begin) / 1000.0])
		return _analyze(PackedVector2Array())
	if read_delay_msec > 0:
		OS.delay_msec(read_delay_msec)
	var queued_frames := _capture.get_frames_available()
	if read_delay_msec > 0 and queued_frames < frames * 4:
		_fail("delayed-read regression did not create an oversized capture queue: window=%d queued=%d" % [frames, queued_frames])
		return _analyze(PackedVector2Array())
	var data := _capture.get_buffer(frames)
	# Later frames are outside this measurement, not part of its denominator.
	_capture.clear_buffer()
	var stats := _analyze(data)
	stats["queued_frames"] = queued_frames
	return stats


func _analyze(data: PackedVector2Array) -> Dictionary:
	var energy := Vector2.ZERO
	var difference_energy := 0.0
	var peak := 0.0
	var crossings := Vector2.ZERO
	var previous := Vector2.ZERO
	for frame in data:
		energy += frame * frame
		difference_energy += (frame.x - frame.y) ** 2
		peak = maxf(peak, maxf(absf(frame.x), absf(frame.y)))
		if frame.x > 0.0 and previous.x <= 0.0:
			crossings.x += 1.0
		if frame.y > 0.0 and previous.y <= 0.0:
			crossings.y += 1.0
		previous = frame
	var count := maxf(1.0, data.size())
	return {
		"frames": data.size(),
		"rms": Vector2(sqrt(energy.x / count), sqrt(energy.y / count)),
		"difference": sqrt(difference_energy / count),
		"peak": peak,
		"frequency": crossings * AudioServer.get_mix_rate() / count,
	}


func _sample() -> Vector2:
	var stats := await _stats()
	var rms: Vector2 = stats.rms
	return Vector2(stats.frames, sqrt(rms.length_squared() / 2.0))


func _mono(label: String) -> bool:
	var stats := await _stats()
	if stats.frames < 256 or stats.rms.x < 0.001 or stats.difference > 0.000001:
		_fail("%s: mono channels differ or are silent: %s" % [label, stats])
		return false
	return true


func _pattern(label: String, late: bool, read_delay_msec: int = 0) -> bool:
	# Drain old server/device data before judging seek/loop content. Both
	# channels retain tones, with dominance AND frequency changing at 1 second.
	await _wait_audio_seconds(0.15)
	var stats := await _stats(read_delay_msec)
	return _check_pattern(label, late, stats)


func _check_pattern(label: String, late: bool, stats: Dictionary) -> bool:
	var rms: Vector2 = stats.rms
	var dominant := rms.y if late else rms.x
	var quiet := rms.x if late else rms.y
	var expected := Vector2(720.0, 1440.0) if late else Vector2(480.0, 960.0)
	var frequency: Vector2 = stats.frequency
	if stats.frames < 256 or dominant < 0.19 or dominant > 0.29 or quiet < 0.04 or quiet > 0.08 or stats.peak > 0.4 or dominant < quiet * 3.0:
		_fail("%s: wrong channel separation/PCM normalization: %s" % [label, stats])
		return false
	if absf(frequency.x - expected.x) > expected.x * 0.2 or absf(frequency.y - expected.y) > expected.y * 0.2:
		_fail("%s: stale/wrong temporal tone: %s expected=%s" % [label, stats, expected])
		return false
	return true


func _audible(label: String) -> bool:
	var sample := await _sample()
	if sample.x < 256 or sample.y < 0.001:
		_fail("%s: insufficient captured PCM frames=%d RMS=%f" % [label, int(sample.x), sample.y])
		return false
	return true


func _silent(label: String) -> bool:
	# Discard bounded server/device tail before measuring a control transition.
	await _wait_audio_seconds(0.15)
	var sample := await _sample()
	if sample.y > 0.0001:
		_fail("%s: stale audio RMS=%f" % [label, sample.y])
		return false
	return true


func _silent_immediate(label: String) -> bool:
	# Caller clears before the transition. Do not discard its first audio:
	# paused-before-play and stop/play regressions can leak only a short burst.
	await _wait_audio_seconds(0.12)
	var stats := _analyze(_capture.get_buffer(_capture.get_frames_available()))
	if stats.peak > 0.0001:
		_fail("%s: unexpected immediate PCM: %s" % [label, stats])
		return false
	return true


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	get_tree().paused = false
	_cleanup_temp_files()
	push_error("AUDIO_SMOKE: %s" % message)
	get_tree().quit(1)
