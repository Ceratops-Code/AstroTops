extends SceneTree


const MainScene := preload("res://main.tscn")
const MeteorScript := preload("res://scripts/meteor.gd")
const PlanetScript := preload("res://scripts/planet.gd")
const ShipScript := preload("res://scripts/player_ship.gd")
const TraxyScript := preload("res://scripts/traxy.gd")
const RESULT_PREFIX := "ASTROTOPS_TEST_RESULT="
const GROUPS := [
	"menu-ui",
	"controls-countdown",
	"audio-speech",
	"tractor-beam",
	"targets",
	"ships-pilots",
	"gameplay-flow",
	"pause-results",
	"rendered-ui",
]

var group := ""
var temporary_root := ""
var evidence_root := ""
var assertions := 0
var failures: Array[Dictionary] = []
var observations: Array[Dictionary] = []
var evidence: Array[String] = []
var click_events := 0
var speech_events: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _parse_arguments():
		_finish()
		return
	DirAccess.make_dir_recursive_absolute(temporary_root)
	DirAccess.make_dir_recursive_absolute(evidence_root)
	match group:
		"menu-ui": await _test_menu_ui()
		"controls-countdown": await _test_controls_countdown()
		"audio-speech": await _test_audio_speech()
		"tractor-beam": await _test_tractor_beam()
		"targets": await _test_targets()
		"ships-pilots": await _test_ships_pilots()
		"gameplay-flow": await _test_gameplay_flow()
		"pause-results": await _test_pause_results()
		"rendered-ui": await _test_rendered_ui()
	await _cleanup_test_nodes()
	_finish()


func _parse_arguments() -> bool:
	var arguments := OS.get_cmdline_user_args()
	var index := 0
	while index < arguments.size():
		match arguments[index]:
			"--group":
				index += 1
				if index < arguments.size():
					group = arguments[index]
			"--temp-root":
				index += 1
				if index < arguments.size():
					temporary_root = arguments[index]
			"--evidence-root":
				index += 1
				if index < arguments.size():
					evidence_root = arguments[index]
		index += 1
	if not group in GROUPS:
		_fail("runner/group", GROUPS, group)
	if temporary_root.is_empty():
		_fail("runner/temp-root", "nonempty isolated directory", temporary_root)
	if evidence_root.is_empty():
		_fail("runner/evidence-root", "nonempty evidence directory", evidence_root)
	return failures.is_empty()


func _new_main(parent: Node, settings_name := "settings.cfg") -> Variant:
	var main: Variant = MainScene.instantiate()
	main.settings_path = temporary_root.path_join(settings_name)
	main.audio_playback_enabled = false
	parent.add_child(main)
	await process_frame
	main.set_process(false)
	return main


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame


func _cleanup_test_nodes() -> void:
	for child in root.get_children():
		_stop_audio(child)
		child.queue_free()
	await _wait_frames(2)


func _stop_audio(node: Node) -> void:
	if node is AudioStreamPlayer:
		node.stop()
		node.stream = null
	for child in node.get_children():
		_stop_audio(child)


func _observe(id: String, value: Variant) -> void:
	observations.append({"id": id, "value": str(value)})


func _fail(id: String, expected: Variant, actual: Variant) -> void:
	var failure := {"id": id, "expected": str(expected), "actual": str(actual)}
	failures.append(failure)
	print("FAIL %s expected=%s actual=%s" % [id, failure["expected"], failure["actual"]])


func _assert_true(id: String, condition: bool, actual: Variant, expected: Variant = "true") -> void:
	assertions += 1
	if not condition:
		_fail(id, expected, actual)


func _assert_equal(id: String, actual: Variant, expected: Variant) -> void:
	assertions += 1
	if actual != expected:
		_fail(id, expected, actual)


func _assert_near(id: String, actual: float, expected: float, tolerance: float) -> void:
	assertions += 1
	if absf(actual - expected) > tolerance:
		_fail(id, "%s +/- %s" % [expected, tolerance], actual)


func _assert_color_near(id: String, actual: Color, expected: Color, tolerance: float) -> void:
	var difference := maxf(
		maxf(absf(actual.r - expected.r), absf(actual.g - expected.g)),
		maxf(absf(actual.b - expected.b), absf(actual.a - expected.a))
	)
	_assert_true(id, difference <= tolerance, {"color": actual, "difference": difference}, expected)


func _on_ui_click_requested() -> void:
	click_events += 1


func _on_target_speech_enqueued(request: Dictionary) -> void:
	speech_events.append(request.duplicate(true))


func _test_menu_ui() -> void:
	var main: Variant = await _new_main(root)
	_assert_true("BACKGROUND-01/texture-loaded", main.milky_way_texture != null, main.milky_way_texture, "loaded generated background")
	if main.milky_way_texture != null:
		_assert_equal("BACKGROUND-01/portrait-size", main.milky_way_texture.get_size(), Vector2(1024.0, 1536.0))
	_assert_equal("MENU-01/project-name", ProjectSettings.get_setting("application/config/name"), "AstroTops")
	var export_config := ConfigFile.new()
	_assert_equal("MENU-01/export-preset-load", export_config.load("res://export_presets.cfg"), OK)
	_assert_equal(
		"MENU-01/package-id",
		export_config.get_value("preset.1.options", "package/unique_name", ""),
		"com.ceratopscode.astrotops"
	)
	var icon_layers := {
		"main": "res://assets/icon.svg",
		"adaptive-background": "res://assets/icon_background.svg",
		"adaptive-foreground": "res://assets/icon_foreground.svg",
		"adaptive-monochrome": "res://assets/icon_monochrome.svg",
	}
	_assert_equal("ICON-01/project-icon", ProjectSettings.get_setting("application/config/icon"), icon_layers["main"])
	_assert_equal("ICON-01/export-main-icon", export_config.get_value("preset.1.options", "launcher_icons/main_192x192", ""), icon_layers["main"])
	_assert_equal("ICON-01/export-adaptive-background", export_config.get_value("preset.1.options", "launcher_icons/adaptive_background_432x432", ""), icon_layers["adaptive-background"])
	_assert_equal("ICON-01/export-adaptive-foreground", export_config.get_value("preset.1.options", "launcher_icons/adaptive_foreground_432x432", ""), icon_layers["adaptive-foreground"])
	_assert_equal("ICON-01/export-adaptive-monochrome", export_config.get_value("preset.1.options", "launcher_icons/adaptive_monochrome_432x432", ""), icon_layers["adaptive-monochrome"])
	for layer_name in icon_layers:
		var icon_texture: Texture2D = load(icon_layers[layer_name])
		_assert_true("ICON-01/loadable-%s" % layer_name, icon_texture != null, icon_layers[layer_name], "loadable Texture2D")
		if icon_texture != null:
			_assert_equal("ICON-01/size-%s" % layer_name, icon_texture.get_size(), Vector2(512.0, 512.0))
	_assert_equal("MENU-01/brand", main.BRAND_NAME, "ASTROTOPS")
	_assert_equal("MENU-01/subtitle", main.MENU_SUBTITLE, "SPACE RUSH")
	_assert_equal("MENU-01/tagline", main.MENU_TAGLINE, "Paint every target. Beat your best time.")
	_assert_equal("MENU-02/label-sizes", [main.SHIP_LABEL.size, main.COLOR_LABEL.size, main.PILOT_LABEL.size, main.MODE_LABEL.size], [Vector2(120, 54), Vector2(120, 54), Vector2(120, 54), Vector2(120, 54)])
	_assert_equal("MENU-02/label-left-alignment", [main.SHIP_LABEL.position.x, main.COLOR_LABEL.position.x, main.PILOT_LABEL.position.x, main.MODE_LABEL.position.x], [326.0, 326.0, 326.0, 326.0])
	_assert_equal("MENU-02/selector-row-alignment", [main.SHIP_LABEL.position.y, main.COLOR_LABEL.position.y, main.PILOT_LABEL.position.y, main.MODE_LABEL.position.y], [main.SHIP_NAME_BUTTON.position.y, main.COLOR_NAME_BUTTON.position.y, main.PILOT_NAME_BUTTON.position.y, main.MODE_NAME_BUTTON.position.y])
	var ship_size: Vector2 = main.ship._ship_target_size() * main.MENU_SHIP_SCALE
	var menu_ship_bottom: float = main.MENU_SHIP_POSITION.y + ship_size.y * 0.5
	_assert_true("MENU-02/ship-does-not-overlap-selector", menu_ship_bottom < main.SHIP_LABEL.position.y, menu_ship_bottom, "< %s" % main.SHIP_LABEL.position.y)
	_assert_true("MENU-02/menu-ship-enlarged", main.MENU_SHIP_SCALE.x > 1.0, main.MENU_SHIP_SCALE)
	_assert_equal("MENU-03/reset-centered", main.RESET_BEST_BUTTON.get_center().x, main.VIEW_SIZE.x * 0.5)
	_assert_true("MENU-03/reset-below-best", main.RESET_BEST_BUTTON.position.y > 618.0, main.RESET_BEST_BUTTON.position.y, "> 618")
	_assert_true("MENU-04/color-choice-count", main.palette.size() >= 10, main.palette.size(), ">= 10")
	_assert_equal("MENU-04/ship-choice-count", main.ship_names.size(), 8)
	_assert_equal("MENU-04/pilot-choices", main.pilot_names, ["Trixie", "Astronaut", "Planet"])
	_assert_equal("TOUR-01/mode-choices", main.MODE_NAMES, ["SPACE RUSH", "SOLAR TOUR"])
	_assert_equal("TOUR-01/default-keeps-space-rush", main.selected_game_mode, main.GameMode.SPACE_RUSH)
	var left_arrow: PackedVector2Array = main._arrow_shape_points(main.SHIP_LEFT_BUTTON, -1.0)
	var right_arrow: PackedVector2Array = main._arrow_shape_points(main.SHIP_RIGHT_BUTTON, 1.0)
	_assert_equal("MENU-04/arrow-point-count", [left_arrow.size(), right_arrow.size()], [7, 7])
	for point_index in range(left_arrow.size()):
		var left_relative: Vector2 = left_arrow[point_index] - main.SHIP_LEFT_BUTTON.get_center()
		var right_relative: Vector2 = right_arrow[point_index] - main.SHIP_RIGHT_BUTTON.get_center()
		_assert_near("MENU-04/arrow-mirror-x-%d" % point_index, left_relative.x, -right_relative.x, 0.001)
		_assert_near("MENU-04/arrow-mirror-y-%d" % point_index, left_relative.y, right_relative.y, 0.001)
	main.ui_click_requested.connect(_on_ui_click_requested)
	main._change_ship(1)
	main._change_color(1)
	main._change_pilot(1)
	main._change_mode(1)
	_assert_equal("MENU-04/common-selector-click", click_events, 4)
	_assert_equal("MENU-04/selector-updates", [main.selected_ship_index, main.selected_color_index, main.selected_pilot_index], [1, 1, 1])
	_assert_equal("TOUR-01/additive-mode-selection", main.selected_game_mode, main.GameMode.SOLAR_TOUR)
	main._update_overlay()
	_assert_true("MENU-05/no-menu-overlay-hint", not main.message_label.visible, main.message_label.text, "hidden")
	_observe("ICON/icon-layer-references", icon_layers)
	_observe("MENU/render-model", "identity, selector geometry, arrows, common click signal, and no ship/selector overlap")


func _test_controls_countdown() -> void:
	var main: Variant = await _new_main(root)
	main.state = main.GameState.READY
	main._update_overlay()
	_assert_equal("COUNT-01/ready-message", main.message_label.text, main.READY_MESSAGE)
	_assert_true("COUNT-01/no-count-list-in-ready-message", not "5" in main.message_label.text, main.message_label.text, "message without countdown digits")
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_SPACE
	main._input(key)
	_assert_equal("COUNT-01/key-starts-countdown", main.state, main.GameState.COUNTDOWN)
	_assert_equal("COUNT-01/countdown-start", main.countdown_value, 5)
	var shown_values: Array[int] = [main.countdown_value]
	for _step in range(4):
		main._process(1.0)
		shown_values.append(main.countdown_value)
	_assert_equal("COUNT-01/visible-sequence", shown_values, [5, 4, 3, 2, 1])
	main._process(1.0)
	_assert_equal("COUNT-01/countdown-launches", main.state, main.GameState.PLAYING)
	_assert_equal("COUNT-01/countdown-font-size", main.countdown_label.get_theme_font_size("font_size"), 220)
	main.state = main.GameState.READY
	var joy := InputEventJoypadButton.new()
	joy.pressed = true
	joy.button_index = JOY_BUTTON_Y
	main._input(joy)
	_assert_equal("CTRL-01/gamepad-button-starts", main.state, main.GameState.COUNTDOWN)
	main.state = main.GameState.READY
	main._handle_pointer(Vector2(500.0, 500.0), true, 7)
	_assert_equal("CTRL-01/tap-starts", main.state, main.GameState.COUNTDOWN)
	main.touch_origin = Vector2(100.0, 100.0)
	main.touch_position = Vector2(500.0, 500.0)
	main._update_touch_vector()
	_assert_true("CTRL-01/touch-vector-bounded", main.touch_vector.length() <= 1.0001, main.touch_vector.length(), "<= 1")
	for pair in [[main.BACK_BUTTON, main.RESET_BUTTON], [main.RESET_BUTTON, main.PAUSE_BUTTON], [main.PAUSE_BUTTON, main.CLOSE_BUTTON]]:
		_assert_true("CTRL-02/system-buttons-separated-%s" % pair[0].position.x, not pair[0].intersects(pair[1]), pair, "non-overlapping")
	_observe("COUNT/countdown", shown_values)


func _pcm_peak(stream: AudioStreamWAV) -> int:
	var peak := 0
	for index in range(0, stream.data.size() - 1, 2):
		var sample := int(stream.data[index]) | (int(stream.data[index + 1]) << 8)
		if sample >= 32768:
			sample -= 65536
		peak = maxi(peak, absi(sample))
	return peak


func _test_audio_speech() -> void:
	var main: Variant = await _new_main(root)
	var audio: AstroAudioController = main.audio_controller
	main.target_speech_enqueued.connect(_on_target_speech_enqueued)
	_assert_near("AUDIO-01/boop-frequency-ratio", audio.COUNTDOWN_BEEP_FREQUENCY / 4.0, 220.0, 0.001)
	_assert_near("AUDIO-01/boop-2x-current-duration", audio.countdown_boop_stream.get_length(), audio.countdown_beep_stream.get_length() * 4.0, 0.002)
	var beep_peak := _pcm_peak(audio.countdown_beep_stream)
	var boop_peak := _pcm_peak(audio.countdown_boop_stream)
	_assert_true("AUDIO-01/boop-louder-pcm", boop_peak > beep_peak, {"beep": beep_peak, "boop": boop_peak}, "boop > beep")
	_assert_true("AUDIO-01/boop-louder-playback", audio.COUNTDOWN_BOOP_VOLUME_DB > audio.COUNTDOWN_BEEP_VOLUME_DB, {"beep_db": audio.COUNTDOWN_BEEP_VOLUME_DB, "boop_db": audio.COUNTDOWN_BOOP_VOLUME_DB}, "boop dB > beep dB")
	_assert_near("AUDIO-01/boop-1.5x-current-gain", db_to_linear(audio.COUNTDOWN_BOOP_VOLUME_DB - 2.0), 1.5, 0.02)
	_assert_true("AUDIO-01/boop-bright-harmonics", audio.COUNTDOWN_BOOP_BRIGHTNESS >= 0.75, audio.COUNTDOWN_BOOP_BRIGHTNESS, ">= 0.75")
	_assert_true("AUDIO-02/click-is-short", audio.ui_click_stream.get_length() < 0.09, audio.ui_click_stream.get_length(), "< 0.09 seconds")
	_assert_equal("AUDIO-04/explosion-resource", audio.SFX_STREAMS["explosion"].resource_path, "res://assets/sfx_explosion.ogg")
	_assert_near("AUDIO-04/bubble-pop-duration", audio.SFX_STREAMS["explosion"].get_length(), 1.79, 0.04)
	_assert_near("AUDIO-03/finale-shout-duration", audio.shout_stream.get_length(), audio.SHOUT_DURATION, 0.002)
	_assert_near("TRAXY-02/poof-sound-duration", audio.capture_poof_stream.get_length(), audio.CAPTURE_POOF_DURATION, 0.002)
	_assert_true("TRAXY-02/poof-sound-audible", _pcm_peak(audio.capture_poof_stream) > 5000, _pcm_peak(audio.capture_poof_stream), "> 5000 PCM peak")
	audio.tts_voice = ""
	audio.playback_enabled = true
	audio.play_capture_poof_then_speak("Traxy")
	_assert_equal("TRAXY-02/name-waits-for-poof", speech_events.size(), 0)
	await create_timer(audio.CAPTURE_POOF_DURATION + 0.10).timeout
	_assert_equal("TRAXY-02/poof-followed-by-name", speech_events.map(func(item: Dictionary) -> String: return String(item["text"])), ["Traxy"])
	audio.playback_enabled = false
	speech_events.clear()
	audio.target_speech_utterance_id = 0
	var refresh_attempts_before: int = int(audio.tts_voice_refresh_attempts)
	main._speak_target_name("Earth")
	main._speak_target_name("Mars")
	main._speak_target_name("Haumea")
	_assert_true("SPEECH-01/late-voice-refresh", audio.tts_voice_refresh_attempts > refresh_attempts_before, audio.tts_voice_refresh_attempts, "> %s" % refresh_attempts_before)
	_assert_equal("SPEECH-01/immediate-submission-count", speech_events.size(), 3)
	_assert_equal("SPEECH-01/submission-order", speech_events.map(func(item: Dictionary) -> String: return String(item["text"])), ["Earth", "Mars", "how MAY uh"])
	_assert_equal("SPEECH-01/utterance-ids", speech_events.map(func(item: Dictionary) -> int: return int(item["utterance_id"])), [1, 2, 3])
	for request in speech_events:
		_assert_near("SPEECH-01/normal-rate-%s" % request["utterance_id"], float(request["rate"]), 1.0, 0.001)
		_assert_equal("SPEECH-01/noninterrupting-%s" % request["utterance_id"], request["interrupt"], false)
	_observe("SPEECH/native-queue", "three requests submitted synchronously in capture order with interrupt=false")


func _append_planet(main: Variant, name: String, style: String, position: Vector2, seed: int) -> ColorPlanet:
	var planet: ColorPlanet = PlanetScript.new()
	planet.configure(name, 18.0, style, seed)
	planet.position = position
	main.add_child(planet)
	main.planets.append(planet)
	return planet


func _test_tractor_beam() -> void:
	var main: Variant = await _new_main(root)
	var pull_steps: Array[float] = []
	var previous := 0.0
	for power in [0.25, 0.50, 0.75, 1.0]:
		main.tractor_beam_strength = power
		var current: float = main._tractor_pull_power()
		pull_steps.append(current - previous)
		previous = current
	_assert_true("TRACTOR-01/diminishing-step-1", pull_steps[0] > pull_steps[1], pull_steps)
	_assert_true("TRACTOR-01/diminishing-step-2", pull_steps[1] > pull_steps[2], pull_steps)
	_assert_true("TRACTOR-01/diminishing-step-3", pull_steps[2] > pull_steps[3], pull_steps)
	main.tractor_beam_strength = main.TRACTOR_DEFAULT_STRENGTH
	var max_distance: float = main._tractor_max_distance(main.VIEW_SIZE)
	_assert_true("TRACTOR-02/range-limited", max_distance < main.VIEW_SIZE.length() * 0.18, max_distance, "< 18% viewport diagonal")
	var near_width: float = main._tractor_field_half_width(0.12, max_distance)
	var bulb_width: float = main._tractor_field_half_width(0.34, max_distance)
	var tail_width: float = main._tractor_field_half_width(0.82, max_distance)
	_assert_true("TRACTOR-02/pear-swells", bulb_width > near_width, {"near": near_width, "bulb": bulb_width})
	_assert_true("TRACTOR-02/pear-tapers", tail_width < bulb_width, {"bulb": bulb_width, "tail": tail_width})
	main.ship.position = Vector2(640.0, 410.0)
	main.ship.velocity = Vector2(0.0, -120.0)
	main.planets.clear()
	var close_off_axis := _append_planet(main, "Mercury", "mercury", Vector2(700.0, 350.0), 1)
	var hidden_aligned := _append_planet(main, "Mars", "mars", Vector2(640.0, 265.0), 2)
	hidden_aligned.visible = false
	var captured_aligned := _append_planet(main, "Earth", "earth", Vector2(640.0, 300.0), 3)
	captured_aligned.captured = true
	await process_frame
	var candidate: Dictionary = main._best_tractor_candidate(Vector2.UP)
	_assert_true("TRACTOR-03/close-off-axis-selected", not candidate.is_empty() and candidate["target"] == close_off_axis, candidate)
	var ship_before: Vector2 = main.ship.global_position
	var planet_before: Vector2 = close_off_axis.global_position
	main._update_tractor_beam(0.20, Vector2.UP)
	_assert_equal("TRACTOR-03/ship-course-unchanged", main.ship.global_position, ship_before)
	_assert_true("TRACTOR-03/planet-moves-closer", close_off_axis.global_position.distance_to(ship_before) < planet_before.distance_to(ship_before), {"before": planet_before, "after": close_off_axis.global_position})
	_assert_equal("TRACTOR-03/one-active-target", main.tractor_target, close_off_axis)
	for planet in main.planets:
		planet.visible = false
	var traxy: Traxy = TraxyScript.new()
	main.add_child(traxy)
	traxy.configure(main.SHIP_BOUNDS, main.ship.position, main.planets, 44)
	traxy.position = Vector2(640.0, 300.0)
	main.traxy = traxy
	var traxy_candidate: Dictionary = main._best_tractor_candidate(Vector2.UP)
	_assert_equal("TRAXY-01/tractor-selects-traxy", traxy_candidate.get("target"), traxy)
	main.state = main.GameState.READY
	main.tractor_beam_enabled = true
	_assert_equal("TRACTOR-04/on-label", main._tractor_button_label(), "TRACTOR BEAM: ON")
	main._toggle_tractor_beam()
	_assert_equal("TRACTOR-04/off-label", main._tractor_button_label(), "TRACTOR BEAM: OFF")
	var settings: ConfigFile = main._settings_config()
	_assert_equal("TRACTOR-04/persist-enabled", settings.get_value("tractor_beam", "enabled"), false)
	_assert_near("TRACTOR-04/persist-power", float(settings.get_value("tractor_beam", "strength")), main.TRACTOR_DEFAULT_STRENGTH, 0.001)
	_assert_equal("TRACTOR-04/power-label", main.TRACTOR_POWER_LABEL, "POWER")
	main.state = main.GameState.PLAYING
	main.tractor_beam_enabled = true
	_assert_equal("TRACTOR-05/debug-hidden-default", main.tractor_debug_field_visible, false)
	main._handle_system_button(main.BACK_BUTTON.get_center())
	_assert_equal("TRACTOR-05/back-waits-for-sequence", main.state, main.GameState.PLAYING)
	var pending_back_serial: int = main.tractor_debug_sequence_serial
	main._on_tractor_debug_back_timeout(pending_back_serial)
	_assert_equal("TRACTOR-05/lone-back-still-works", main.state, main.GameState.MENU)
	main.state = main.GameState.PLAYING
	main._handle_system_button(main.BACK_BUTTON.get_center())
	main._handle_system_button(main.PAUSE_BUTTON.get_center())
	_assert_equal("TRACTOR-05/wrong-order-hidden", main.tractor_debug_field_visible, false)
	_assert_equal("TRACTOR-05/wrong-order-resets", main.tractor_debug_sequence_index, 0)
	_assert_equal("TRACTOR-05/wrong-order-resolves-back", main.state, main.GameState.MENU)
	main.state = main.GameState.PLAYING
	main._handle_system_button(main.BACK_BUTTON.get_center())
	var first_prefix_serial: int = main.tractor_debug_sequence_serial
	main._handle_system_button(main.RESET_BUTTON.get_center())
	var partial_prefix_serial: int = main.tractor_debug_sequence_serial
	main._on_tractor_debug_back_timeout(first_prefix_serial)
	_assert_equal("TRACTOR-05/stale-prefix-timer-ignored", main.state, main.GameState.PLAYING)
	_assert_equal("TRACTOR-05/partial-prefix-retained", main.tractor_debug_sequence_index, 2)
	main._on_tractor_debug_back_timeout(partial_prefix_serial)
	_assert_equal("TRACTOR-05/partial-prefix-timeout-resolves-back", main.state, main.GameState.MENU)
	_assert_equal("TRACTOR-05/partial-prefix-timeout-resets", main.tractor_debug_sequence_index, 0)
	main.state = main.GameState.PLAYING
	main._handle_system_button(main.BACK_BUTTON.get_center())
	main._handle_system_button(main.RESET_BUTTON.get_center())
	main._handle_system_button(main.TRACTOR_BEAM_BUTTON.get_center())
	_assert_equal("TRACTOR-05/partial-prefix-interrupt-resolves-back", main.state, main.GameState.MENU)
	_assert_equal("TRACTOR-05/partial-prefix-interrupt-resets", main.tractor_debug_sequence_index, 0)
	main.state = main.GameState.PLAYING
	for button_rect in [main.BACK_BUTTON, main.RESET_BUTTON, main.PAUSE_BUTTON, main.CLOSE_BUTTON]:
		main._handle_system_button(button_rect.get_center())
	_assert_equal("TRACTOR-05/secret-sequence-shows", main.tractor_debug_field_visible, true)
	_assert_equal("TRACTOR-05/secret-sequence-consumed", main.state, main.GameState.PLAYING)
	for button_rect in [main.BACK_BUTTON, main.RESET_BUTTON, main.PAUSE_BUTTON, main.CLOSE_BUTTON]:
		main._handle_system_button(button_rect.get_center())
	_assert_equal("TRACTOR-05/secret-sequence-hides", main.tractor_debug_field_visible, false)
	_observe("TRACTOR/profile", {"pull_steps": pull_steps, "widths": [near_width, bulb_width, tail_width], "range": max_distance})


func _spec_by_style(specs: Array[Dictionary], style: String) -> Dictionary:
	for spec in specs:
		if spec["style"] == style:
			return spec
	return {}


func _test_targets() -> void:
	var main: Variant = await _new_main(root)
	var specs: Array[Dictionary] = main._body_specs()
	var required_names := ["Sun", "Black Hole", "Mercury", "Venus", "Earth", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune", "Moon", "Haumea", "Asteroid"]
	var names: Array[String] = []
	for spec in specs:
		names.append(String(spec["name"]))
	for required_name in required_names:
		_assert_true("TARGET-01/roster-%s" % required_name, required_name in names, names, required_name)
	var sun := _spec_by_style(specs, "sun")
	var jupiter := _spec_by_style(specs, "jupiter")
	var mercury := _spec_by_style(specs, "mercury")
	_assert_true("TARGET-01/sun-slightly-larger-than-jupiter", float(sun["radius"]) > float(jupiter["radius"]) and float(sun["radius"]) < float(jupiter["radius"]) * 1.2, {"sun": sun["radius"], "jupiter": jupiter["radius"]})
	for spec in specs:
		if spec["style"] not in ["asteroid_a", "asteroid_b", "haumea", "moon", "pluto"]:
			_assert_true("TARGET-01/mercury-smallest-major-%s" % spec["style"], float(mercury["radius"]) <= float(spec["radius"]), {"mercury": mercury["radius"], "other": spec})
	var saturn: ColorPlanet = PlanetScript.new()
	saturn.configure("Saturn", 46.0, "saturn", 11)
	root.add_child(saturn)
	var uranus: ColorPlanet = PlanetScript.new()
	uranus.configure("Uranus", 38.0, "uranus", 12)
	root.add_child(uranus)
	_assert_true("TARGET-02/both-ringed", saturn.ringed and uranus.ringed, {"saturn": saturn.ringed, "uranus": uranus.ringed})
	_assert_true("TARGET-02/uranus-rings-more-vertical", absf(uranus.ring_angle) > absf(saturn.ring_angle) * 3.0, {"saturn": saturn.ring_angle, "uranus": uranus.ring_angle})
	_assert_true("TARGET-02/uranus-rings-smaller", uranus.ring_width < saturn.ring_width and uranus.ring_rx < saturn.ring_rx, {"saturn": [saturn.ring_rx, saturn.ring_width], "uranus": [uranus.ring_rx, uranus.ring_width]})
	var asteroid_specs := specs.filter(func(spec: Dictionary) -> bool: return String(spec["style"]).begins_with("asteroid"))
	_assert_equal("TARGET-03/asteroid-labels", asteroid_specs.map(func(spec: Dictionary) -> String: return String(spec["name"])), ["Asteroid", "Asteroid"])
	var asteroid: ColorPlanet = PlanetScript.new()
	asteroid.configure("Asteroid", 13.0, "asteroid_a", 13)
	root.add_child(asteroid)
	_assert_near("TARGET-03/asteroid-capture-area", asteroid.capture_radius(), asteroid.radius * 1.3, 0.001)
	_assert_true("TARGET-03/large-body-label", asteroid.LABEL_FONT_SIZE >= 20, asteroid.LABEL_FONT_SIZE, ">= 20")
	var black_hole: ColorPlanet = PlanetScript.new()
	black_hole.configure("Black Hole", 30.0, "black_hole", 14)
	black_hole.captured_color = Color("46a8ff")
	black_hole.capture_progress = 1.0
	root.add_child(black_hole)
	_assert_color_near("TARGET-04/black-hole-half-color", black_hole.black_hole_horizon_color(), Color.BLACK.lerp(black_hole.captured_color, 0.5), 0.001)
	var earth: ColorPlanet = PlanetScript.new()
	earth.configure("Earth", 30.0, "earth", 15)
	root.add_child(earth)
	var landmasses := earth.earth_landmasses()
	_assert_equal("TARGET-05/earth-landmass-count", landmasses.size(), 6)
	_assert_equal("TARGET-05/earth-landmass-identities", landmasses.map(func(item: Dictionary) -> String: return String(item["id"])), ["north_america", "south_america", "africa_europe", "asia", "australia", "greenland"])
	var haumea := _spec_by_style(specs, "haumea")
	_assert_equal("TARGET-05/haumea-identity", [haumea["name"], haumea["style"]], ["Haumea", "haumea"])
	for seed in range(5):
		var rng := RandomNumberGenerator.new()
		rng.seed = 900 + seed
		var positions: Array[Vector2] = main._random_target_positions(specs, rng)
		_assert_equal("TARGET-06/random-layout-size-%d" % seed, positions.size(), specs.size())
		var distinct_x := {}
		var distinct_y := {}
		for position in positions:
			distinct_x[int(round(position.x))] = true
			distinct_y[int(round(position.y))] = true
		_assert_true("TARGET-06/not-a-grid-x-%d" % seed, distinct_x.size() >= specs.size() - 2, distinct_x.size(), ">= %d" % (specs.size() - 2))
		_assert_true("TARGET-06/not-a-grid-y-%d" % seed, distinct_y.size() >= specs.size() - 3, distinct_y.size(), ">= %d" % (specs.size() - 3))

	var atlas: Image = load("res://assets/traxy.png").get_image()
	_assert_equal("TRAXY-01/atlas-size", atlas.get_size(), Vector2i(768, 512))
	for frame in range(6):
		var frame_origin := Vector2i((frame % 3) * 256, floori(float(frame) / 3.0) * 256)
		var corner_alpha := [
			atlas.get_pixelv(frame_origin).a,
			atlas.get_pixelv(frame_origin + Vector2i(255, 0)).a,
			atlas.get_pixelv(frame_origin + Vector2i(0, 255)).a,
			atlas.get_pixelv(frame_origin + Vector2i(255, 255)).a,
		]
		_assert_true("TRAXY-01/transparent-frame-corners-%d" % frame, corner_alpha.max() <= 0.05, corner_alpha, "all <= 0.05")
	var no_planets: Array[ColorPlanet] = []
	var traxy: Traxy = TraxyScript.new()
	root.add_child(traxy)
	traxy.configure(main.SHIP_BOUNDS, Vector2(420.0, 410.0), no_planets, 70)
	_assert_true("TRAXY-01/shared-target-contract", traxy is SpaceTarget and asteroid is SpaceTarget, [traxy, asteroid], "both are SpaceTarget")
	_assert_equal("TRAXY-01/name", traxy.body_name, "Traxy")
	var direction_frames: Array[int] = []
	for direction in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		traxy.velocity = direction * traxy.FLEE_SPEED
		direction_frames.append(traxy.current_frame_index())
	_assert_equal("TRAXY-01/directional-chair-frames", direction_frames, [0, 1, 2, 3])
	traxy.position = Vector2(640.0, 410.0)
	traxy.velocity = Vector2.ZERO
	traxy.stuck_origin = traxy.position
	var flee_distance_before := traxy.position.distance_to(Vector2(420.0, 410.0))
	for _step in range(10):
		traxy.update_active(0.1, Vector2(420.0, 410.0), no_planets)
	_assert_true("TRAXY-01/flees-ship", traxy.position.distance_to(Vector2(420.0, 410.0)) > flee_distance_before + 40.0, traxy.position)
	traxy.position = main.SHIP_BOUNDS.position + Vector2.ONE * traxy.capture_radius()
	traxy.velocity = Vector2.ZERO
	traxy.stuck_origin = traxy.position
	var corner_origin := traxy.position
	for _step in range(10):
		traxy.update_active(0.1, main.SHIP_BOUNDS.get_center(), no_planets)
	_assert_true("TRAXY-01/corner-escape", traxy.position.distance_to(corner_origin) > traxy.STUCK_DISTANCE, {"before": corner_origin, "after": traxy.position})
	_assert_true("TRAXY-01/remains-in-playfield", main.SHIP_BOUNDS.grow(-traxy.capture_radius()).has_point(traxy.position), traxy.position)
	_assert_true("TRAXY-02/capture", traxy.capture(Color("ff4e9c")), traxy.motion_state)
	_assert_equal("TRAXY-02/floating-state", traxy.motion_state, traxy.MotionState.FLOATING)
	_assert_color_near("TRAXY-02/captured-name-uses-ship-color", traxy.name_label_color(), Color("ff4e9c"), 0.001)
	_assert_near("TRAXY-02/capture-starts-white-poof", traxy.capture_poof_elapsed, 0.0, 0.001)
	traxy.blink_elapsed = 0.0
	_assert_equal("TRAXY-02/shocked-open-frame", traxy.current_frame_index(), 4)
	traxy.blink_elapsed = 1.70
	_assert_equal("TRAXY-02/shocked-closed-frame", traxy.current_frame_index(), 5)
	traxy.blink_elapsed = 0.0
	traxy.rotation = 0.0
	traxy.position = main.SHIP_BOUNDS.get_center()
	traxy.velocity = Vector2.RIGHT * traxy.FLOAT_SPEED
	traxy.update_active(1.0, Vector2.ZERO, no_planets)
	_assert_near("TRAXY-02/slow-clockwise-float", traxy.rotation, traxy.FLOAT_ROTATION_SPEED, 0.001)
	traxy.position = Vector2(main.SHIP_BOUNDS.position.x + traxy.capture_radius(), main.SHIP_BOUNDS.get_center().y)
	traxy.velocity = Vector2.LEFT * traxy.FLOAT_SPEED
	traxy.update_active(0.1, Vector2.ZERO, no_planets)
	_assert_true("TRAXY-02/edge-bounce", traxy.velocity.x > 0.0, traxy.velocity)
	earth.position = Vector2(640.0, 410.0)
	traxy.position = earth.position + Vector2(earth.capture_radius() + traxy.capture_radius() - 1.0, 0.0)
	traxy.velocity = Vector2.LEFT * traxy.FLOAT_SPEED
	var earth_obstacle: Array[ColorPlanet] = [earth]
	traxy.update_active(0.02, Vector2.ZERO, earth_obstacle)
	_assert_true("TRAXY-02/planet-bounce", traxy.velocity.x > 0.0, traxy.velocity)
	_observe("TARGET/roster-and-render-model", "celestial roster plus Traxy's directional chair, corner escape, shocked blink, and bounded bounce behavior")


func _test_ships_pilots() -> void:
	var ship: PlayerShip = ShipScript.new()
	root.add_child(ship)
	await process_frame
	_assert_equal("SHIP-01/style-count", ship.SHIP_STYLE_COUNT, 8)
	_assert_equal("SHIP-01/cockpit-count", ship.COCKPIT_OFFSETS.size(), ship.SHIP_STYLE_COUNT)
	var unique_offsets := {}
	for offset in ship.COCKPIT_OFFSETS:
		unique_offsets[str(offset)] = true
	_assert_equal("SHIP-01/unique-cockpit-offsets", unique_offsets.size(), ship.SHIP_STYLE_COUNT)
	for style_index in range(ship.COCKPIT_OFFSETS.size()):
		if style_index != 3:
			_assert_true("SHIP-01/rear-cockpit-%d" % style_index, ship.COCKPIT_OFFSETS[style_index].y >= 4.0, ship.COCKPIT_OFFSETS[style_index])
	_assert_color_near("PILOT-01/black-cockpit", ship.COCKPIT_COLOR, Color("010205"), 0.001)
	_assert_true("PILOT-01/trixie-enlarged", ship.TRIXIE_PILOT_SCALE >= 2.0, ship.TRIXIE_PILOT_SCALE, ">= 2")
	_assert_true("PILOT-01/astronaut-enlarged", ship.ASTRONAUT_OUTER_SCALE >= 0.9, ship.ASTRONAUT_OUTER_SCALE, ">= 0.9")
	_assert_true("PILOT-01/planet-enlarged", ship.PLANET_PILOT_SCALE >= 0.74, ship.PLANET_PILOT_SCALE, ">= 0.74")
	ship.configure(Color("41f4c6"), Rect2(35.0, 146.0, 1210.0, 536.0), 0, 0)
	_assert_equal("PILOT-01/default-trixie", ship.pilot_style, 0)
	for style_index in range(ship.SHIP_TEXTURES.size()):
		ship.ship_style = style_index
		var texture: Texture2D = ship.SHIP_TEXTURES[style_index]
		var source_size := texture.get_size()
		var target_size: Vector2 = ship._ship_target_size()
		_assert_true("SHIP-02/high-resolution-%d" % style_index, source_size.x >= target_size.x * 1.75 and source_size.y >= target_size.y * 1.75, {"source": source_size, "target": target_size}, "source >= 1.75x target")
		var image := texture.get_image()
		var corner_alpha := [image.get_pixel(0, 0).a, image.get_pixel(image.get_width() - 1, 0).a, image.get_pixel(0, image.get_height() - 1).a, image.get_pixel(image.get_width() - 1, image.get_height() - 1).a]
		_assert_true("SHIP-02/transparent-corners-%d" % style_index, corner_alpha.max() <= 0.05, corner_alpha, "all <= 0.05")
	ship.position = Vector2(100.0, 200.0)
	ship.configure(Color.WHITE, Rect2(0.0, 100.0, 200.0, 200.0), 4, 2)
	ship.move_ship(Vector2.RIGHT, 2.0)
	_assert_equal("SHIP-03/movement-bounded", ship.position.x, 200.0)
	ship.position = Vector2(100.0, 200.0)
	ship.stop()
	ship.move_scripted(Vector2.LEFT * 300.0, 1.0)
	_assert_true("TRAXY-03/scripted-rescue-bypasses-bounds", ship.position.x < 0.0, ship.position.x, "< 0")
	_assert_equal("PILOT-02/planet-selection", ship.pilot_style, 2)
	_observe("SHIP/assets", "four raster ships retain high-resolution transparent sources; four procedural ships and three pilots remain selectable")


func _test_gameplay_flow() -> void:
	var main: Variant = await _new_main(root, "gameplay-flow-settings.cfg")
	main.audio_controller.tts_voice = ""
	main.target_speech_enqueued.connect(_on_target_speech_enqueued)
	main._prepare_run()
	_assert_equal("FLOW-01/ready-state", main.state, main.GameState.READY)
	_assert_equal("FLOW-01/target-count", main.total_targets, 16)
	_assert_equal("FLOW-01/planet-count", main.planets.size(), 15)
	_assert_true("TRAXY-01/space-rush-target", is_instance_valid(main.traxy), main.traxy, "spawned Traxy")
	main._begin_countdown()
	_assert_equal("FLOW-01/countdown-state", main.state, main.GameState.COUNTDOWN)
	_assert_equal("FLOW-01/countdown-start", main.countdown_value, 5)
	main._launch_run()
	_assert_equal("FLOW-01/playing-state", main.state, main.GameState.PLAYING)
	main.elapsed_time = 12.345
	for planet in main.planets:
		if not planet.captured:
			main.ship.position = planet.position
			main._check_planet_contacts()
	_assert_equal("TRAXY-03/last-planet-count-excludes-traxy", main.captured_count, main.planets.size())
	_assert_true("FLOW-01/all-planets-captured", main.planets.all(func(planet: ColorPlanet) -> bool: return planet.captured), main.captured_count)
	_assert_true("TRAXY-03/last-planet-keeps-traxy-uncaught", not main.traxy.captured, main.traxy.motion_state)
	_assert_equal("TRAXY-03/last-planet-keeps-playing", main.state, main.GameState.PLAYING)
	_assert_equal("TRAXY-03/last-planet-speech-excludes-traxy", speech_events.size(), main.planets.size())
	main.ship.position = main.traxy.position
	main._check_traxy_contact()
	_assert_equal("FLOW-01/captured-count", main.captured_count, main.total_targets)
	_assert_true("TRAXY-03/explicitly-captured", main.traxy.captured, main.traxy.motion_state)
	_assert_equal("FLOW-01/speech-per-capture", speech_events.size(), main.total_targets)
	_assert_equal("TRAXY-03/rescue-before-finale", main.state, main.GameState.RESCUE)
	_assert_near("FLOW-01/final-time", main.final_time, 12.345, 0.001)
	_assert_near("FLOW-01/best-time", main.best_time, 12.345, 0.001)
	var rescue_wait_position: Vector2 = main.traxy.position
	main._process(0.25)
	_assert_near("TRAXY-03/timer-frozen-during-rescue", main.elapsed_time, 12.345, 0.001)
	_assert_true("TRAXY-03/rescue-freezes-float-for-hook", main.traxy.position.distance_to(rescue_wait_position) < 0.001, main.traxy.position, rescue_wait_position)
	var meteors: Array[Node] = []
	for child in main.get_children():
		if child.get_script() == MeteorScript:
			meteors.append(child)
	_assert_equal("TRAXY-03/no-meteors-before-tow", meteors.size(), 0)
	var corner_probe := Vector2(120.0, 190.0)
	var view_size: Vector2 = main.VIEW_SIZE
	var expected_probe_direction := (view_size - corner_probe).normalized()
	_assert_true("TRAXY-03/farthest-corner-selection", main._farthest_corner_exit_direction(corner_probe).distance_to(expected_probe_direction) < 0.001, main._farthest_corner_exit_direction(corner_probe), expected_probe_direction)
	var probe_staging: Vector2 = main._rescue_hook_staging_position(corner_probe, expected_probe_direction)
	_assert_true("TRAXY-03/stages-ahead-in-tow-direction", (probe_staging - corner_probe).dot(expected_probe_direction) > 0.0, probe_staging, "between Traxy and the tow corner")
	_assert_near("TRAXY-03/tow-speed-factor", main.RESCUE_TOW_SPEED_FACTOR, 0.70, 0.001)
	_assert_near("TRAXY-03/tow-speed", main._rescue_tow_speed(), main.ship.max_speed * 0.70, 0.001)
	main.ship.position = main.rescue_staging_position
	main._update_traxy_rescue(0.02)
	_assert_true("TRAXY-03/hook-launch-started", main.rescue_hook_started and not main.rescue_hooked and main.traxy.motion_state == main.traxy.MotionState.HOOKING, main.traxy.motion_state)
	main._update_traxy_rescue(main.traxy.HOOK_TRAVEL_DURATION * 0.5)
	_assert_true("TRAXY-03/hook-travels-progressively", main.traxy.hook_progress() > 0.0 and main.traxy.hook_progress() < 1.0 and not main.rescue_hooked, main.traxy.hook_progress())
	var expected_exit_direction: Vector2 = main._farthest_corner_exit_direction(main.traxy.position)
	main._update_traxy_rescue(main.traxy.HOOK_TRAVEL_DURATION + main.traxy.HOOK_LATCH_DURATION)
	_assert_true("TRAXY-03/harness-hooked", main.rescue_hooked and main.traxy.motion_state == main.traxy.MotionState.TOWED, main.rescue_hooked)
	_assert_true("TRAXY-03/tow-uses-farthest-corner", main.rescue_exit_direction.distance_to(expected_exit_direction) < 0.001, main.rescue_exit_direction, expected_exit_direction)
	main.ship.position = Vector2(-1000.0, -1000.0)
	main.traxy.position = Vector2(-1100.0, -1100.0)
	main._update_traxy_rescue(0.0)
	_assert_equal("TRAXY-03/finale-after-offscreen", main.state, main.GameState.FINALE)
	meteors.clear()
	for child in main.get_children():
		if child.get_script() == MeteorScript:
			meteors.append(child)
	_assert_equal("FLOW-01/meteor-per-planet", meteors.size(), main.planets.size())
	for planet in main.planets:
		main._on_meteor_impact(planet)
	_assert_equal("FLOW-01/impact-count", main.finale_impacts, main.planets.size())
	_assert_true("FLOW-01/all-targets-exploding", main.planets.all(func(planet: ColorPlanet) -> bool: return planet.exploding), main.finale_impacts)
	main._show_results()
	_assert_equal("FLOW-01/results-state", main.state, main.GameState.RESULTS)
	_assert_equal("FLOW-01/ship-hidden", main.ship.visible, false)

	var early_main: Variant = await _new_main(root, "early-traxy-settings.cfg")
	early_main._prepare_run()
	early_main.state = early_main.GameState.PLAYING
	early_main.ship.position = early_main.traxy.position
	early_main._check_traxy_contact()
	_assert_equal("TRAXY-02/early-capture-count", early_main.captured_count, 1)
	_assert_equal("TRAXY-02/early-capture-keeps-playing", early_main.state, early_main.GameState.PLAYING)
	_assert_equal("TRAXY-02/early-capture-floats", early_main.traxy.motion_state, early_main.traxy.MotionState.FLOATING)

	var tour_main: Variant = await _new_main(root, "tour-flow-settings.cfg")
	tour_main.selected_game_mode = tour_main.GameMode.SOLAR_TOUR
	tour_main._prepare_run()
	tour_main.state = tour_main.GameState.PLAYING
	_assert_true("TRAXY-01/absent-from-solar-tour", not is_instance_valid(tour_main.traxy), tour_main.traxy, "no Traxy")
	_assert_equal("TOUR-01/order-covers-roster", tour_main.TOUR_ORDER.size(), tour_main.total_targets)
	_assert_equal("TOUR-01/first-target", tour_main._tour_target_style(), "sun")
	_assert_equal("TOUR-01/one-highlight", tour_main.planets.filter(func(planet: ColorPlanet) -> bool: return planet.tour_highlighted).size(), 1)
	var out_of_order: ColorPlanet = _planet_by_style(tour_main, "mercury")
	var first_target: ColorPlanet = _planet_by_style(tour_main, "sun")
	_assert_true("TOUR-01/initial-arrow-cue", first_target.is_tour_guide_visible(), first_target.tour_guide_time_remaining, "> 0 seconds")
	first_target._process(first_target.TOUR_GUIDE_DURATION)
	_assert_true("TOUR-01/arrow-cue-times-out", not first_target.is_tour_guide_visible() and first_target.tour_highlighted, {"guide": first_target.tour_guide_time_remaining, "highlighted": first_target.tour_highlighted}, "arrows hidden; marker remains")
	for planet in tour_main.planets:
		planet.visible = planet in [first_target, out_of_order]
	tour_main.ship.position = Vector2(640.0, 600.0)
	first_target.position = Vector2(640.0, 450.0)
	out_of_order.position = Vector2(640.0, 510.0)
	var tour_tractor_candidate: Dictionary = tour_main._best_tractor_candidate(Vector2.UP)
	_assert_equal("TOUR-01/tractor-follows-order", tour_tractor_candidate.get("target"), first_target)
	for planet in tour_main.planets:
		planet.visible = true
	first_target.position = Vector2(300.0, 300.0)
	out_of_order.position = Vector2(900.0, 300.0)
	tour_main.ship.position = out_of_order.position
	tour_main._check_planet_contacts()
	_assert_equal("TOUR-01/out-of-order-blocked", tour_main.captured_count, 0)
	tour_main.ship.position = first_target.position
	tour_main._check_planet_contacts()
	_assert_equal("TOUR-01/order-advances", [tour_main.captured_count, tour_main._tour_target_style()], [1, "mercury"])
	_assert_true("TOUR-01/next-target-highlighted", out_of_order.tour_highlighted, out_of_order.body_style)
	_assert_true("TOUR-01/next-target-arrow-cue-reset", out_of_order.is_tour_guide_visible(), out_of_order.tour_guide_time_remaining, "> 0 seconds")
	tour_main.elapsed_time = 19.5
	for tour_index in range(1, tour_main.TOUR_ORDER.size()):
		var tour_target: ColorPlanet = _planet_by_style(tour_main, String(tour_main.TOUR_ORDER[tour_index]))
		tour_main.ship.position = tour_target.position
		tour_main._check_planet_contacts()
	_assert_equal("TOUR-01/complete-state", tour_main.state, tour_main.GameState.FINALE)
	_assert_equal("TOUR-01/all-targets-captured", tour_main.captured_count, tour_main.total_targets)
	_assert_near("TOUR-01/separate-tour-best", tour_main.tour_best_time, 19.5, 0.001)
	_assert_equal("TOUR-01/rush-best-unchanged", tour_main.best_time, 0.0)
	_assert_equal("TOUR-01/medal-copy", tour_main._result_pilot_message(), "Trixie completed the solar tour")
	_observe("FLOW/complete-run", "ready, countdown, play, explicit Traxy capture, hook-and-drag rescue, one meteor per planet, explosions, score, and results")
	_observe("TOUR/ordered-run", "Space Rush remains the default; Solar Tour blocks out-of-order captures, advances its highlight, and keeps a separate best time")


func _planet_by_style(main: Variant, style: String) -> ColorPlanet:
	for planet in main.planets:
		if planet.body_style == style:
			return planet
	return null


func _assert_result_layout(main: Variant, variant: String) -> void:
	var layout: Dictionary = main._result_layout_bounds()
	var ordered_keys := ["title", "pilot"]
	if layout.has("medal"):
		ordered_keys.append("medal")
	ordered_keys.append_array(["time", "best", "actions"])
	var collisions: Array[String] = []
	for index in range(1, ordered_keys.size()):
		var previous: Rect2 = layout[ordered_keys[index - 1]]
		var current: Rect2 = layout[ordered_keys[index]]
		if previous.end.y > current.position.y:
			collisions.append("%s/%s" % [ordered_keys[index - 1], ordered_keys[index]])
	_assert_true("RESULT-03/%s-nonoverlap" % variant, collisions.is_empty(), collisions, "vertically separated result elements")
	var safe_panel: Rect2 = layout["panel"].grow(-8.0)
	var outside: Array[String] = []
	for key in ordered_keys:
		if not safe_panel.encloses(layout[key]):
			outside.append(key)
	_assert_true("RESULT-03/%s-inside-panel" % variant, outside.is_empty(), outside, "all result elements inside panel")
	if layout.has("medal"):
		var medal_gap: float = layout["time"].position.y - layout["medal"].end.y
		_assert_true("RESULT-03/solar-tour-medal-time-gap", medal_gap >= 6.0, medal_gap, ">= 6 pixels")


func _test_pause_results() -> void:
	var main: Variant = await _new_main(root, "persistent-settings.cfg")
	main.state = main.GameState.PLAYING
	main.ship.velocity = Vector2(80.0, 10.0)
	main._toggle_pause()
	main._update_overlay()
	_assert_equal("PAUSE-01/state", main.state, main.GameState.PAUSED)
	_assert_equal("PAUSE-01/ship-stopped", main.ship.velocity, Vector2.ZERO)
	_assert_equal("PAUSE-01/message", main.message_label.text, main.PAUSE_MESSAGE)
	_assert_equal("PAUSE-01/header-not-shaded", main.overlay_shade.position.y, main.HUD_HEIGHT)
	main._toggle_pause()
	_assert_equal("PAUSE-01/resume", main.state, main.GameState.PLAYING)
	main.state = main.GameState.FINALE
	main._update_overlay()
	_assert_true("RESULT-01/no-finale-banner", not main.message_label.visible, main.message_label.text, "hidden")
	_assert_equal("RESULT-01/title", main.RESULT_TITLE, "MISSION COMPLETE!")
	_assert_true("RESULT-01/no-retired-completion-copy", not "celestial" in main.RESULT_TITLE.to_lower() and not "space rush" in main.RESULT_TITLE.to_lower(), main.RESULT_TITLE)
	_assert_true("RESULT-01/pilot-line-size", main.RESULT_PILOT_FONT_SIZE >= 28, main.RESULT_PILOT_FONT_SIZE, ">= 28")
	main.selected_pilot_index = 0
	_assert_equal("RESULT-01/pilot-line", main._result_pilot_message(), "Trixie painted every target")
	main.state = main.GameState.RESULTS
	main.final_time = 62.44
	main.best_time = 62.44
	main.selected_game_mode = main.GameMode.SPACE_RUSH
	_assert_equal("RESULT-03/minute-time-format", main._format_time(main.final_time), "01:02.44")
	_assert_result_layout(main, "space-rush")
	for pilot_index in range(1, main.pilot_names.size()):
		main.selected_pilot_index = pilot_index
		_assert_result_layout(main, "space-rush-pilot-%d" % pilot_index)
	main.selected_game_mode = main.GameMode.SOLAR_TOUR
	main.tour_best_time = 62.44
	main.selected_pilot_index = 0
	_assert_result_layout(main, "solar-tour")
	for pilot_index in range(1, main.pilot_names.size()):
		main.selected_pilot_index = pilot_index
		_assert_result_layout(main, "solar-tour-pilot-%d" % pilot_index)
	main.selected_pilot_index = 0
	main.selected_game_mode = main.GameMode.SPACE_RUSH
	main.best_time = 34.039
	main._request_best_score_reset()
	_assert_near("PERSIST-01/reset-first-tap-arms", main.best_time, 34.039, 0.0001)
	main._request_best_score_reset()
	_assert_equal("PERSIST-01/reset-second-tap-clears", main.best_time, 0.0)
	main.best_time = 22.5
	main.tour_best_time = 31.25
	main.tractor_beam_enabled = false
	main.tractor_beam_strength = 0.37
	main._save_settings()
	var restored: Variant = MainScene.instantiate()
	restored.settings_path = main.settings_path
	restored.audio_playback_enabled = false
	root.add_child(restored)
	await process_frame
	restored.set_process(false)
	_assert_near("PERSIST-01/best-time-roundtrip", restored.best_time, 22.5, 0.001)
	_assert_near("TOUR-01/best-time-roundtrip", restored.tour_best_time, 31.25, 0.001)
	_assert_equal("PERSIST-01/tractor-enabled-roundtrip", restored.tractor_beam_enabled, false)
	_assert_near("PERSIST-01/tractor-power-roundtrip", restored.tractor_beam_strength, 0.37, 0.001)
	main.state = main.GameState.FINALE
	main.ship.visible = true
	main._show_results()
	_assert_equal("RESULT-02/results-state", main.state, main.GameState.RESULTS)
	_assert_equal("RESULT-02/ship-hidden", main.ship.visible, false)
	_observe("PAUSE/results", "pause/resume state, undimmed header boundary, completion copy, score reset, and settings roundtrip")


func _capture(viewport: SubViewport, filename: String) -> Image:
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	RenderingServer.force_draw()
	await _wait_frames(3)
	var texture := viewport.get_texture()
	if texture == null:
		_fail("RENDER/capture-%s" % filename, "render texture", null)
		return Image.new()
	var image := texture.get_image()
	if image == null or image.is_empty():
		_fail("RENDER/capture-%s" % filename, "nonempty rendered image", image)
		return Image.new()
	var path := evidence_root.path_join(filename)
	var save_error := image.save_png(path)
	_assert_equal("RENDER/save-%s" % filename, save_error, OK)
	if save_error == OK:
		evidence.append(filename)
	return image


func _different_pixels(first: Image, second: Image, rect: Rect2i, threshold := 0.03, stride := 2) -> int:
	var differences := 0
	for y in range(rect.position.y, rect.end.y, stride):
		for x in range(rect.position.x, rect.end.x, stride):
			var one := first.get_pixel(x, y)
			var two := second.get_pixel(x, y)
			if maxf(maxf(absf(one.r - two.r), absf(one.g - two.g)), absf(one.b - two.b)) > threshold:
				differences += 1
	return differences


func _circularly_masked(image: Image, center: Vector2, radius: float) -> Image:
	# Android launchers may apply a circular adaptive-icon mask. Preserve the
	# actual rendered layers while emulating that user-visible clipping shape.
	var masked := image.duplicate()
	var radius_squared := radius * radius
	for y in range(masked.get_height()):
		for x in range(masked.get_width()):
			var delta := Vector2(float(x) + 0.5, float(y) + 0.5) - center
			if delta.length_squared() > radius_squared:
				masked.set_pixel(x, y, Color.TRANSPARENT)
	return masked


func _test_rendered_ui() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var main: Variant = await _new_main(viewport, "render-settings.cfg")
	main.input_hint_time = 0.0
	main.ship.rotation = 0.0
	main.queue_redraw()
	var menu_image: Image = await _capture(viewport, "menu.png")
	_assert_equal("RENDER-01/menu-size", menu_image.get_size(), Vector2i(1280, 720))
	var background_texture: Texture2D = main.milky_way_texture
	main.milky_way_texture = null
	main.queue_redraw()
	RenderingServer.force_draw()
	await _wait_frames(3)
	var no_background_image: Image = viewport.get_texture().get_image()
	var background_difference := _different_pixels(menu_image, no_background_image, Rect2i(0, 0, 1280, 720), 0.02, 4)
	_assert_true("BACKGROUND-01/rendered-background-difference", background_difference > 30000, background_difference, "> 30000 sampled pixels")
	main.milky_way_texture = background_texture
	main.state = main.GameState.PLAYING
	main.elapsed_time = 8.72
	main.captured_count = 0
	main.total_targets = 16
	main.ship.visible = true
	main._update_overlay()
	main.queue_redraw()
	var playing_image: Image = await _capture(viewport, "playing.png")
	for button_rect in [main.BACK_BUTTON, main.RESET_BUTTON, main.PAUSE_BUTTON, main.CLOSE_BUTTON]:
		main._handle_system_button(button_rect.get_center())
	main.queue_redraw()
	var debug_field_image: Image = await _capture(viewport, "tractor-debug.png")
	var debug_field_difference := _different_pixels(playing_image, debug_field_image, Rect2i(300, 136, 680, 500), 0.02, 2)
	_assert_true("RENDER-08/tractor-debug-visible-after-sequence", debug_field_difference > 180, debug_field_difference, "> 180 sampled pixels")
	for button_rect in [main.BACK_BUTTON, main.RESET_BUTTON, main.PAUSE_BUTTON, main.CLOSE_BUTTON]:
		main._handle_system_button(button_rect.get_center())
	main._handle_mouse_pointer(main.PAUSE_BUTTON.get_center(), true)
	main._handle_mouse_pointer(main.PAUSE_BUTTON.get_center(), false)
	main._update_overlay()
	main.queue_redraw()
	var paused_image: Image = await _capture(viewport, "paused.png")
	_assert_equal("RENDER-02/pause-control-state", main.state, main.GameState.PAUSED)
	var header_difference := _different_pixels(playing_image, paused_image, Rect2i(0, 0, 690, 82), 0.01, 2)
	var field_difference := _different_pixels(playing_image, paused_image, Rect2i(0, 136, 1280, 584), 0.03, 4)
	_assert_true("RENDER-02/header-undimmed", header_difference <= 150, header_difference, "<= 150 sampled pixels")
	_assert_true("RENDER-02/playfield-dimmed", field_difference > 2000, field_difference, "> 2000 sampled pixels")
	_observe("RENDER/pause-differences", {"header": header_difference, "playfield": field_difference})
	main.state = main.GameState.COUNTDOWN
	main.countdown_value = 5
	main.countdown_phase = 0.42
	main._update_overlay()
	main.queue_redraw()
	var countdown_image: Image = await _capture(viewport, "countdown.png")
	var countdown_difference := _different_pixels(playing_image, countdown_image, Rect2i(390, 180, 500, 370), 0.04, 2)
	_assert_true("RENDER-03/countdown-visible-over-ship", countdown_difference > 1200, countdown_difference, "> 1200 sampled pixels")
	main.selected_game_mode = main.GameMode.SPACE_RUSH
	main.state = main.GameState.RESULTS
	main.final_time = 62.44
	main.best_time = 62.44
	main.ship.visible = false
	main._update_overlay()
	main.queue_redraw()
	var results_image: Image = await _capture(viewport, "results.png")
	_assert_true("RENDER-04/results-panel-visible", _different_pixels(playing_image, results_image, Rect2i(300, 148, 680, 490), 0.03, 4) > 1500, "rendered result panel")

	main.selected_game_mode = main.GameMode.SOLAR_TOUR
	main._prepare_run()
	main.state = main.GameState.PLAYING
	for planet in main.planets:
		planet.set_process(false)
	main._update_overlay()
	main.queue_redraw()
	var tour_image: Image = await _capture(viewport, "tour.png")
	var highlighted_target: ColorPlanet = _planet_by_style(main, "sun")
	highlighted_target.set_tour_highlighted(false)
	RenderingServer.force_draw()
	await _wait_frames(3)
	var tour_without_marker: Image = viewport.get_texture().get_image()
	var marker_difference := _different_pixels(tour_image, tour_without_marker, Rect2i(0, 136, 1280, 584), 0.03, 2)
	_assert_true("TOUR-01/rendered-next-target-marker", marker_difference > 50, marker_difference, "> 50 sampled pixels")
	main._clear_targets()
	main.tour_progress_index = main.TOUR_ORDER.size()
	main.captured_count = main.total_targets
	main.state = main.GameState.RESULTS
	main.final_time = 62.44
	main.tour_best_time = 62.44
	main.ship.visible = false
	main._update_overlay()
	main.queue_redraw()
	var tour_results_image: Image = await _capture(viewport, "tour-results.png")
	var tour_results_difference := _different_pixels(results_image, tour_results_image, Rect2i(300, 148, 680, 490), 0.03, 3)
	_assert_true("TOUR-01/rendered-medal", tour_results_difference > 300, tour_results_difference, "> 300 sampled pixels")

	var ship_viewport := SubViewport.new()
	ship_viewport.size = Vector2i(220, 220)
	ship_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(ship_viewport)
	var ship_background := ColorRect.new()
	ship_background.color = Color("d6d9e2")
	ship_background.size = Vector2(220.0, 220.0)
	ship_viewport.add_child(ship_background)
	var isolated_ship: PlayerShip = ShipScript.new()
	isolated_ship.position = Vector2(110.0, 110.0)
	isolated_ship.configure(Color("41f4c6"), Rect2(0.0, 0.0, 220.0, 220.0), 4, 0)
	ship_viewport.add_child(isolated_ship)
	var ship_image: Image = await _capture(ship_viewport, "cockpit.png")
	var cockpit: Vector2 = isolated_ship.position + isolated_ship.COCKPIT_OFFSETS[4]
	var sample_radius: float = isolated_ship.COCKPIT_RADII[4] + 2.0
	for sample_index in range(4):
		var sample_point := Vector2i(cockpit + Vector2.from_angle(float(sample_index) * PI * 0.5) * sample_radius)
		var sample := ship_image.get_pixelv(sample_point)
		_assert_true("RENDER-05/black-cockpit-ring-%d" % sample_index, maxf(sample.r, maxf(sample.g, sample.b)) < 0.12, sample, "dark filled ring")
	isolated_ship.configure(Color("41f4c6"), Rect2(0.0, 0.0, 220.0, 220.0), 4, 2)
	isolated_ship.scale = Vector2.ONE * 2.5
	var planet_pilot_image: Image = await _capture(ship_viewport, "planet-pilot.png")
	var planet_cockpit: Vector2 = isolated_ship.COCKPIT_OFFSETS[4]
	var planet_radius: float = isolated_ship.COCKPIT_RADII[4] * isolated_ship.PLANET_PILOT_SCALE
	var front_ring_point := Vector2i((isolated_ship.position + isolated_ship._planet_pilot_ring_point(planet_cockpit, planet_radius, PI * 0.5) * isolated_ship.scale).round())
	var back_ring_point := Vector2i((isolated_ship.position + isolated_ship._planet_pilot_ring_point(planet_cockpit, planet_radius, PI * 1.5) * isolated_ship.scale).round())
	var front_ring_sample := planet_pilot_image.get_pixelv(front_ring_point)
	var back_ring_sample := planet_pilot_image.get_pixelv(back_ring_point)
	_assert_true("PILOT-02/ring-front-visible", front_ring_sample.r > 0.72 and front_ring_sample.g > 0.55 and front_ring_sample.b < 0.72, front_ring_sample, "gold foreground arc")
	_assert_true("PILOT-02/ring-back-occluded", not (back_ring_sample.r > 0.72 and back_ring_sample.g > 0.55 and back_ring_sample.b < 0.72), back_ring_sample, "planet body covers rear arc")

	var target_viewport := SubViewport.new()
	target_viewport.size = Vector2i(500, 260)
	target_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(target_viewport)
	var target_background := ColorRect.new()
	target_background.color = Color("071029")
	target_background.size = Vector2(500.0, 260.0)
	target_viewport.add_child(target_background)
	var earth: ColorPlanet = PlanetScript.new()
	earth.configure("Earth", 70.0, "earth", 21)
	earth.position = Vector2(120.0, 125.0)
	target_viewport.add_child(earth)
	var black_hole: ColorPlanet = PlanetScript.new()
	black_hole.configure("Black Hole", 48.0, "black_hole", 22)
	black_hole.position = Vector2(365.0, 125.0)
	black_hole.captured_color = Color("46a8ff")
	black_hole.captured = true
	black_hole.capture_progress = 1.0
	target_viewport.add_child(black_hole)
	var target_image: Image = await _capture(target_viewport, "targets.png")
	var horizon_sample := target_image.get_pixelv(Vector2i(365, 125))
	_assert_color_near("RENDER-06/black-hole-visible-color", horizon_sample, Color.BLACK.lerp(black_hole.captured_color, 0.5), 0.08)
	var green_land_pixels := 0
	for y in range(65, 186, 2):
		for x in range(60, 181, 2):
			var pixel := target_image.get_pixel(x, y)
			if pixel.g > pixel.b * 1.08 and pixel.g > pixel.r * 1.25:
				green_land_pixels += 1
	_assert_true("RENDER-07/earth-land-visible", green_land_pixels > 120, green_land_pixels, "> 120 sampled green land pixels")

	var traxy_viewport := SubViewport.new()
	traxy_viewport.size = Vector2i(520, 260)
	traxy_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(traxy_viewport)
	var traxy_background := ColorRect.new()
	traxy_background.color = Color("071029")
	traxy_background.size = Vector2(520.0, 260.0)
	traxy_viewport.add_child(traxy_background)
	var no_planets: Array[ColorPlanet] = []
	var running_traxy: Traxy = TraxyScript.new()
	traxy_viewport.add_child(running_traxy)
	running_traxy.configure(Rect2(0.0, 0.0, 520.0, 260.0), Vector2.ZERO, no_planets, 90)
	running_traxy.position = Vector2(135.0, 120.0)
	running_traxy.velocity = Vector2.RIGHT * running_traxy.FLEE_SPEED
	var shocked_traxy: Traxy = TraxyScript.new()
	traxy_viewport.add_child(shocked_traxy)
	shocked_traxy.configure(Rect2(0.0, 0.0, 520.0, 260.0), Vector2.ZERO, no_planets, 91)
	shocked_traxy.position = Vector2(385.0, 120.0)
	shocked_traxy.capture(Color("ff4e9c"))
	var poof_image: Image = await _capture(traxy_viewport, "traxy-poof.png")
	shocked_traxy.capture_poof_elapsed = shocked_traxy.CAPTURE_POOF_DURATION
	shocked_traxy.queue_redraw()
	var traxy_image: Image = await _capture(traxy_viewport, "traxy-states.png")
	var poof_difference := _different_pixels(poof_image, traxy_image, Rect2i(295, 25, 180, 190), 0.025, 1)
	_assert_true("TRAXY-02/rendered-white-poof", poof_difference > 220, poof_difference, "> 220 changed cloud pixels")
	var traxy_green_pixels := [0, 0]
	for y in range(45, 205, 2):
		for x in range(50, 470, 2):
			var pixel := traxy_image.get_pixel(x, y)
			if pixel.g > pixel.r * 1.18 and pixel.g > pixel.b * 0.82:
				traxy_green_pixels[0 if x < 260 else 1] += 1
	_assert_true("TRAXY-01/rendered-chair", traxy_green_pixels[0] > 120, traxy_green_pixels[0], "> 120 sampled green pixels")
	_assert_true("TRAXY-02/rendered-shocked-pose", traxy_green_pixels[1] > 120, traxy_green_pixels[1], "> 120 sampled green pixels")

	var color_viewport := SubViewport.new()
	color_viewport.size = Vector2i(520, 260)
	color_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(color_viewport)
	var color_background := ColorRect.new()
	color_background.color = Color("071029")
	color_background.size = Vector2(520.0, 260.0)
	color_viewport.add_child(color_background)
	var cyan_traxy: Traxy = TraxyScript.new()
	color_viewport.add_child(cyan_traxy)
	cyan_traxy.configure(Rect2(0.0, 0.0, 520.0, 260.0), Vector2.ZERO, no_planets, 93)
	cyan_traxy.position = Vector2(135.0, 120.0)
	cyan_traxy.capture(Color("20d9ff"))
	var pink_traxy: Traxy = TraxyScript.new()
	color_viewport.add_child(pink_traxy)
	pink_traxy.configure(Rect2(0.0, 0.0, 520.0, 260.0), Vector2.ZERO, no_planets, 94)
	pink_traxy.position = Vector2(385.0, 120.0)
	pink_traxy.capture(Color("ff4e9c"))
	var color_image: Image = await _capture(color_viewport, "traxy-suit-color.png")
	var changed_suit_pixels := 0
	var changed_head_pixels := 0
	for local_y in range(-60, 61):
		for local_x in range(-60, 61):
			var cyan_pixel := color_image.get_pixel(135 + local_x, 120 + local_y)
			var pink_pixel := color_image.get_pixel(385 + local_x, 120 + local_y)
			var difference := absf(cyan_pixel.r - pink_pixel.r) + absf(cyan_pixel.g - pink_pixel.g) + absf(cyan_pixel.b - pink_pixel.b)
			if difference <= 0.12:
				continue
			if local_y >= -6 or (abs(local_x) >= 34 and local_y >= -24):
				changed_suit_pixels += 1
			elif abs(local_x) <= 30 and local_y <= -12:
				changed_head_pixels += 1
	_assert_true("TRAXY-02/spacesuit-adopts-ship-color", changed_suit_pixels > 180, changed_suit_pixels, "> 180 changed suit pixels")
	_assert_true("TRAXY-02/head-colors-preserved", changed_head_pixels <= 12, changed_head_pixels, "<= 12 changed head pixels")

	var tow_viewport := SubViewport.new()
	tow_viewport.size = Vector2i(560, 260)
	tow_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(tow_viewport)
	var tow_background := ColorRect.new()
	tow_background.color = Color("071029")
	tow_background.size = Vector2(560.0, 260.0)
	tow_viewport.add_child(tow_background)
	var rescue_ship: PlayerShip = ShipScript.new()
	rescue_ship.position = Vector2(400.0, 130.0)
	rescue_ship.configure(Color("41f4c6"), Rect2(0.0, 0.0, 560.0, 260.0), 0, 0)
	tow_viewport.add_child(rescue_ship)
	var towed_traxy: Traxy = TraxyScript.new()
	tow_viewport.add_child(towed_traxy)
	towed_traxy.configure(Rect2(0.0, 0.0, 560.0, 260.0), Vector2.ZERO, no_planets, 92)
	towed_traxy.position = Vector2(250.0, 130.0)
	towed_traxy.capture(Color("ff4e9c"))
	towed_traxy.capture_poof_elapsed = towed_traxy.CAPTURE_POOF_DURATION
	towed_traxy.begin_hook(rescue_ship)
	towed_traxy.update_active(towed_traxy.HOOK_TRAVEL_DURATION * 0.55, rescue_ship.position, no_planets)
	var hook_image: Image = await _capture(tow_viewport, "traxy-hook.png")
	var hook_cable_pixels := 0
	var gold_hook_pixels := 0
	for y in range(108, 154):
		for x in range(300, 411):
			var hook_pixel := hook_image.get_pixel(x, y)
			if hook_pixel.r > 0.70 and hook_pixel.b > 0.35 and hook_pixel.g < 0.68:
				hook_cable_pixels += 1
			if hook_pixel.r > 0.78 and hook_pixel.g > 0.48 and hook_pixel.b < 0.42:
				gold_hook_pixels += 1
	_assert_true("TRAXY-03/rendered-progressive-hook-cable", hook_cable_pixels > 18, hook_cable_pixels, "> 18 pink cable pixels")
	_assert_true("TRAXY-03/rendered-rotating-hook", gold_hook_pixels > 5, gold_hook_pixels, "> 5 gold hook pixels")
	towed_traxy.update_active(towed_traxy.HOOK_TRAVEL_DURATION * 0.45 + towed_traxy.HOOK_LATCH_DURATION * 0.45, rescue_ship.position, no_planets)
	var latch_image: Image = await _capture(tow_viewport, "traxy-hook-latch.png")
	var latch_difference := _different_pixels(hook_image, latch_image, Rect2i(215, 112, 82, 78), 0.06, 1)
	_assert_true("TRAXY-03/rendered-latch-burst", latch_difference > 100, latch_difference, "> 100 changed latch pixels")
	towed_traxy.update_active(towed_traxy.HOOK_LATCH_DURATION, rescue_ship.position, no_planets)
	_assert_true("TRAXY-03/hook-animation-completes", towed_traxy.is_hook_animation_complete(), towed_traxy.hook_elapsed)
	towed_traxy.begin_tow(rescue_ship, Vector2.RIGHT)
	towed_traxy.update_active(0.2, rescue_ship.position, no_planets)
	var tow_image: Image = await _capture(tow_viewport, "traxy-tow.png")
	var cable_pixels := 0
	for y in range(115, 151):
		for x in range(325, 371):
			var pixel := tow_image.get_pixel(x, y)
			if pixel.r > 0.70 and pixel.b > 0.35 and pixel.g < 0.68:
				cable_pixels += 1
	_assert_true("TRAXY-03/rendered-tow-cable", cable_pixels > 12, cable_pixels, "> 12 pink cable pixels")

	var icon_viewport := SubViewport.new()
	icon_viewport.size = Vector2i(512, 512)
	icon_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(icon_viewport)
	var icon_rect := TextureRect.new()
	icon_rect.size = Vector2(512.0, 512.0)
	icon_rect.texture = load("res://assets/icon.svg")
	icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_viewport.add_child(icon_rect)
	var icon_image: Image = await _capture(icon_viewport, "app-icon.png")
	_assert_equal("ICON-01/render-size", icon_image.get_size(), Vector2i(512, 512))
	var dark_space := icon_image.get_pixel(256, 40)
	var bright_rocket := icon_image.get_pixel(373, 112)
	var gold_planet := icon_image.get_pixel(145, 330)
	var dark_space_luminance := (dark_space.r + dark_space.g + dark_space.b) / 3.0
	_assert_true("ICON-01/dark-space-background", dark_space_luminance < 0.14, {"color": dark_space, "luminance": dark_space_luminance}, "luminance < 0.14")
	_assert_true("ICON-01/bright-diagonal-rocket", bright_rocket.r + bright_rocket.g + bright_rocket.b > 1.65, bright_rocket, "bright rocket")
	_assert_true("ICON-01/gold-ringed-planet", gold_planet.r > gold_planet.b * 1.45, gold_planet, "gold planet")

	var adaptive_viewport := SubViewport.new()
	adaptive_viewport.size = Vector2i(512, 512)
	adaptive_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(adaptive_viewport)
	var adaptive_background := TextureRect.new()
	adaptive_background.size = Vector2(512.0, 512.0)
	adaptive_background.texture = load("res://assets/icon_background.svg")
	adaptive_background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	adaptive_background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	adaptive_viewport.add_child(adaptive_background)
	var adaptive_foreground := TextureRect.new()
	adaptive_foreground.size = Vector2(512.0, 512.0)
	adaptive_foreground.texture = load("res://assets/icon_foreground.svg")
	adaptive_foreground.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	adaptive_foreground.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	adaptive_viewport.add_child(adaptive_foreground)
	var adaptive_composite: Image = await _capture(adaptive_viewport, "app-icon-adaptive.png")
	var adaptive_image := _circularly_masked(adaptive_composite, Vector2(256.0, 256.0), 236.0)
	var adaptive_save_error := adaptive_image.save_png(evidence_root.path_join("app-icon-adaptive.png"))
	_assert_equal("ICON-01/adaptive-mask-save", adaptive_save_error, OK)
	_assert_equal("ICON-01/adaptive-render-size", adaptive_image.get_size(), Vector2i(512, 512))
	var adaptive_corner := adaptive_image.get_pixel(0, 0)
	var adaptive_space := adaptive_image.get_pixel(256, 40)
	var adaptive_rocket := adaptive_image.get_pixel(373, 112)
	var adaptive_planet := adaptive_image.get_pixel(145, 330)
	var adaptive_space_luminance := (adaptive_space.r + adaptive_space.g + adaptive_space.b) / 3.0
	_assert_true("ICON-01/adaptive-circular-mask", adaptive_corner.a < 0.01, adaptive_corner, "transparent clipped corner")
	_assert_true("ICON-01/adaptive-dark-space-background", adaptive_space.a > 0.99 and adaptive_space_luminance < 0.14, adaptive_space, "opaque dark space")
	_assert_true("ICON-01/adaptive-bright-diagonal-rocket", adaptive_rocket.a > 0.99 and adaptive_rocket.r + adaptive_rocket.g + adaptive_rocket.b > 1.65, adaptive_rocket, "visible bright rocket")
	_assert_true("ICON-01/adaptive-gold-ringed-planet", adaptive_planet.a > 0.99 and adaptive_planet.r > adaptive_planet.b * 1.45, adaptive_planet, "visible gold planet")
	_observe("RENDER/evidence", evidence)


func _finish() -> void:
	var status := "passed" if failures.is_empty() else "failed"
	var result := {
		"schema": "astrotops-godot-test-group.v1",
		"group": group,
		"status": status,
		"assertions": assertions,
		"failures": failures,
		"observations": observations,
		"evidence": evidence,
	}
	print(RESULT_PREFIX + JSON.stringify(result))
	quit(0 if failures.is_empty() else 1)
