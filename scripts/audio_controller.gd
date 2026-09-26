extends Node
class_name AstroAudioController


signal ui_click_requested
signal target_speech_enqueued(request: Dictionary)

const SFX_STREAMS := {
	"meteor": preload("res://assets/sfx_meteor.ogg"),
	"explosion": preload("res://assets/sfx_explosion.ogg"),
}
const SAMPLE_RATE := 22050
const SHOUT_DURATION := 1.15
const COUNTDOWN_BEEP_FREQUENCY := 880.0
const COUNTDOWN_BEEP_DURATION := 0.11
const COUNTDOWN_BEEP_AMPLITUDE := 0.42
const COUNTDOWN_BEEP_VOLUME_DB := -5.0
const COUNTDOWN_BOOP_DURATION_MULTIPLIER := 4.0
const COUNTDOWN_BOOP_AMPLITUDE := 0.68
const COUNTDOWN_BOOP_BRIGHTNESS := 0.88
const COUNTDOWN_BOOP_VOLUME_DB := 5.521825
const TTS_RATE := 1.0

var playback_enabled := true
var shout_stream: AudioStreamWAV
var ui_click_stream: AudioStreamWAV
var countdown_beep_stream: AudioStreamWAV
var countdown_boop_stream: AudioStreamWAV
var tts_voice := ""
var tts_voice_refresh_attempts := 0
var target_speech_utterance_id := 0


func _ready() -> void:
	# Runtime-generated cues stay centralized here so gameplay only requests sounds.
	shout_stream = _make_shout_stream()
	ui_click_stream = _make_mouse_click_stream()
	countdown_beep_stream = _make_tone_stream(
		COUNTDOWN_BEEP_FREQUENCY,
		COUNTDOWN_BEEP_FREQUENCY,
		COUNTDOWN_BEEP_DURATION,
		COUNTDOWN_BEEP_AMPLITUDE
	)
	countdown_boop_stream = _make_tone_stream(
		COUNTDOWN_BEEP_FREQUENCY / 4.0,
		COUNTDOWN_BEEP_FREQUENCY / 4.0,
		COUNTDOWN_BEEP_DURATION * COUNTDOWN_BOOP_DURATION_MULTIPLIER,
		COUNTDOWN_BOOP_AMPLITUDE,
		COUNTDOWN_BOOP_BRIGHTNESS
	)
	setup_tts()


func play_ui_click() -> void:
	ui_click_requested.emit()
	_play_generated_stream(ui_click_stream, -8.0)


func play_countdown_tone(final_boop: bool) -> void:
	_play_generated_stream(
		countdown_boop_stream if final_boop else countdown_beep_stream,
		COUNTDOWN_BOOP_VOLUME_DB if final_boop else COUNTDOWN_BEEP_VOLUME_DB
	)


func play_sfx(effect: String, pitch := 1.0, volume_db := 0.0) -> void:
	if not playback_enabled or not SFX_STREAMS.has(effect):
		return
	# One-shot players self-remove, allowing closely spaced meteor impacts to overlap cleanly.
	var player := AudioStreamPlayer.new()
	player.stream = SFX_STREAMS[effect]
	player.pitch_scale = pitch
	player.volume_db = volume_db
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


func setup_tts() -> void:
	if not tts_voice.is_empty():
		return
	tts_voice_refresh_attempts += 1
	if not DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH):
		return
	var voices := DisplayServer.tts_get_voices_for_language("en")
	if voices.is_empty():
		voices = DisplayServer.tts_get_voices_for_language("en_US")
	if voices.is_empty():
		voices = DisplayServer.tts_get_voices_for_language("en-US")
	if not voices.is_empty():
		tts_voice = String(voices[0])


func speak_target_name(target_name: String) -> void:
	target_speech_utterance_id += 1
	var request := target_speech_request(target_name, target_speech_utterance_id)
	target_speech_enqueued.emit(request)
	if tts_voice.is_empty():
		setup_tts()
		if tts_voice.is_empty():
			return
	# The native queue preserves capture order without adding an application delay.
	DisplayServer.tts_speak(
		String(request["text"]),
		tts_voice,
		int(request["volume"]),
		float(request["pitch"]),
		float(request["rate"]),
		int(request["utterance_id"]),
		bool(request["interrupt"])
	)


func target_speech_request(target_name: String, utterance_id: int) -> Dictionary:
	return {
		"text": "how MAY uh" if target_name == "Haumea" else target_name,
		"volume": 58,
		"pitch": 1.0,
		"rate": TTS_RATE,
		"utterance_id": utterance_id,
		"interrupt": false,
	}


func stop_target_speech() -> void:
	if not tts_voice.is_empty():
		DisplayServer.tts_stop()


func play_shout() -> void:
	if shout_stream == null or not playback_enabled:
		return
	var player := AudioStreamPlayer.new()
	player.stream = shout_stream
	player.volume_db = -11.0
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


func _make_mouse_click_stream() -> AudioStreamWAV:
	# Two short, damped transients mimic a mechanical mouse press and release.
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	var duration := 0.070
	var sample_count := int(duration * float(SAMPLE_RATE))
	var samples := PackedByteArray()
	samples.resize(sample_count * 2)
	for index in range(sample_count):
		var time := float(index) / float(SAMPLE_RATE)
		var press := exp(-time * 105.0) * (
			sin(time * TAU * 2920.0) * 0.52 + sin(time * TAU * 1680.0) * 0.26
		)
		var release_time := time - 0.032
		var release := 0.0
		if release_time >= 0.0:
			release = exp(-release_time * 145.0) * (
				sin(release_time * TAU * 2380.0) * 0.30 + sin(release_time * TAU * 1120.0) * 0.16
			)
		var value := clampf(press + release, -0.72, 0.72)
		var pcm := int(round(value * 32767.0))
		samples[index * 2] = pcm & 0xff
		samples[index * 2 + 1] = (pcm >> 8) & 0xff
	stream.data = samples
	return stream


func _make_tone_stream(
	start_frequency: float,
	end_frequency: float,
	duration: float,
	amplitude: float,
	brightness := 0.0
) -> AudioStreamWAV:
	# Smooth envelopes avoid clicks; odd harmonics keep the low final tone crisp.
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	var sample_count := int(duration * float(SAMPLE_RATE))
	var samples := PackedByteArray()
	samples.resize(sample_count * 2)
	var phase := 0.0
	for index in range(sample_count):
		var time := float(index) / float(SAMPLE_RATE)
		var progress := time / duration
		var frequency := lerpf(start_frequency, end_frequency, progress)
		phase += TAU * frequency / float(SAMPLE_RATE)
		var attack := clampf(time / 0.008, 0.0, 1.0)
		var release := clampf((duration - time) / minf(0.045, duration * 0.35), 0.0, 1.0)
		var rounded_tone := sin(phase) * 0.82 + sin(phase * 2.0) * 0.12
		var bright_edge := sin(phase * 3.0) * 0.15 + sin(phase * 5.0) * 0.08
		var tone := (rounded_tone + bright_edge * brightness) / (0.94 + brightness * 0.23)
		var value := clampf(tone * attack * release * amplitude, -1.0, 1.0)
		var pcm := int(round(value * 32767.0))
		samples[index * 2] = pcm & 0xff
		samples[index * 2 + 1] = (pcm >> 8) & 0xff
	stream.data = samples
	return stream


func _play_generated_stream(stream: AudioStreamWAV, volume_db: float) -> void:
	if stream == null or not playback_enabled:
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


func _make_shout_stream() -> AudioStreamWAV:
	# Build a short vowel-like shout in memory for consistent cross-platform playback.
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	var sample_count := int(SHOUT_DURATION * float(SAMPLE_RATE))
	var samples := PackedByteArray()
	samples.resize(sample_count * 2)
	var phase := 0.0
	for index in range(sample_count):
		var time := float(index) / float(SAMPLE_RATE)
		var progress := time / SHOUT_DURATION
		var attack := clampf(time / 0.055, 0.0, 1.0)
		var release := clampf((SHOUT_DURATION - time) / 0.24, 0.0, 1.0)
		var pitch := lerpf(174.0, 132.0, progress) + sin(time * TAU * 2.2) * 3.5
		phase += TAU * pitch / float(SAMPLE_RATE)
		var voice := sin(phase) * 0.58 + sin(phase * 2.0) * 0.20 + sin(phase * 3.0) * 0.10
		var formants := sin(time * TAU * 720.0) * 0.075 + sin(time * TAU * 1120.0) * 0.045
		var tremolo := 0.91 + sin(time * TAU * 5.2) * 0.09
		var value := clampf((voice + formants) * attack * release * tremolo * 0.52, -1.0, 1.0)
		var pcm := int(round(value * 32767.0))
		samples[index * 2] = pcm & 0xff
		samples[index * 2 + 1] = (pcm >> 8) & 0xff
	stream.data = samples
	return stream
