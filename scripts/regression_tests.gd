extends SceneTree


const MainScene := preload("res://main.tscn")
const MeteorScript := preload("res://scripts/meteor.gd")
const PlanetScript := preload("res://scripts/planet.gd")
const ShipScript := preload("res://scripts/player_ship.gd")
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
	_assert_equal("MENU-01/project-name", ProjectSettings.get_setting("application/config/name"), "AstroTops")
	var export_config := ConfigFile.new()
	_assert_equal("MENU-01/export-preset-load", export_config.load("res://export_presets.cfg"), OK)
	_assert_equal(
		"MENU-01/package-id",
		export_config.get_value("preset.1.options", "package/unique_name", ""),
		"com.ceratopscode.astrotops"
	)
	_assert_equal("MENU-01/brand", main.BRAND_NAME, "ASTROTOPS")
	_assert_equal("MENU-01/subtitle", main.MENU_SUBTITLE, "SPACE RUSH")
	_assert_equal("MENU-01/tagline", main.MENU_TAGLINE, "Paint every target. Beat your best time.")
	_assert_equal("MENU-02/label-sizes", [main.SHIP_LABEL.size, main.COLOR_LABEL.size, main.PILOT_LABEL.size], [Vector2(120, 54), Vector2(120, 54), Vector2(120, 54)])
	_assert_equal("MENU-02/label-left-alignment", [main.SHIP_LABEL.position.x, main.COLOR_LABEL.position.x, main.PILOT_LABEL.position.x], [326.0, 326.0, 326.0])
	_assert_equal("MENU-02/selector-row-alignment", [main.SHIP_LABEL.position.y, main.COLOR_LABEL.position.y, main.PILOT_LABEL.position.y], [main.SHIP_NAME_BUTTON.position.y, main.COLOR_NAME_BUTTON.position.y, main.PILOT_NAME_BUTTON.position.y])
	var ship_size: Vector2 = main.ship._ship_target_size() * main.MENU_SHIP_SCALE
	var menu_ship_bottom: float = main.MENU_SHIP_POSITION.y + ship_size.y * 0.5
	_assert_true("MENU-02/ship-does-not-overlap-selector", menu_ship_bottom < main.SHIP_LABEL.position.y, menu_ship_bottom, "< %s" % main.SHIP_LABEL.position.y)
	_assert_true("MENU-02/menu-ship-enlarged", main.MENU_SHIP_SCALE.x > 1.0, main.MENU_SHIP_SCALE)
	_assert_equal("MENU-03/reset-centered", main.RESET_BEST_BUTTON.get_center().x, main.VIEW_SIZE.x * 0.5)
	_assert_true("MENU-03/reset-below-best", main.RESET_BEST_BUTTON.position.y > 618.0, main.RESET_BEST_BUTTON.position.y, "> 618")
	_assert_true("MENU-04/color-choice-count", main.palette.size() >= 10, main.palette.size(), ">= 10")
	_assert_equal("MENU-04/ship-choice-count", main.ship_names.size(), 8)
	_assert_equal("MENU-04/pilot-choices", main.pilot_names, ["Trixie", "Astronaut", "Planet"])
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
	_assert_equal("MENU-04/common-selector-click", click_events, 3)
	_assert_equal("MENU-04/selector-updates", [main.selected_ship_index, main.selected_color_index, main.selected_pilot_index], [1, 1, 1])
	main._update_overlay()
	_assert_true("MENU-05/no-menu-overlay-hint", not main.message_label.visible, main.message_label.text, "hidden")
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
	_assert_near("AUDIO-01/boop-frequency-ratio", main.COUNTDOWN_BEEP_FREQUENCY / 4.0, 220.0, 0.001)
	_assert_near("AUDIO-01/boop-double-duration", main.countdown_boop_stream.get_length(), main.countdown_beep_stream.get_length() * 2.0, 0.002)
	var beep_peak := _pcm_peak(main.countdown_beep_stream)
	var boop_peak := _pcm_peak(main.countdown_boop_stream)
	_assert_true("AUDIO-01/boop-louder-pcm", boop_peak > beep_peak, {"beep": beep_peak, "boop": boop_peak}, "boop > beep")
	_assert_true("AUDIO-01/boop-louder-playback", main.COUNTDOWN_BOOP_VOLUME_DB > main.COUNTDOWN_BEEP_VOLUME_DB, {"beep_db": main.COUNTDOWN_BEEP_VOLUME_DB, "boop_db": main.COUNTDOWN_BOOP_VOLUME_DB}, "boop dB > beep dB")
	_assert_true("AUDIO-01/boop-bright-harmonics", main.COUNTDOWN_BOOP_BRIGHTNESS >= 0.75, main.COUNTDOWN_BOOP_BRIGHTNESS, ">= 0.75")
	_assert_true("AUDIO-02/click-is-short", main.ui_click_stream.get_length() < 0.09, main.ui_click_stream.get_length(), "< 0.09 seconds")
	_assert_near("AUDIO-03/finale-shout-duration", main.shout_stream.get_length(), main.SHOUT_DURATION, 0.002)
	main.tts_voice = ""
	main.target_speech_enqueued.connect(_on_target_speech_enqueued)
	main._speak_target_name("Earth")
	main._speak_target_name("Mars")
	main._speak_target_name("Haumea")
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
	_assert_true("TRACTOR-03/close-off-axis-selected", not candidate.is_empty() and candidate["planet"] == close_off_axis, candidate)
	var ship_before: Vector2 = main.ship.global_position
	var planet_before: Vector2 = close_off_axis.global_position
	main._update_tractor_beam(0.20, Vector2.UP)
	_assert_equal("TRACTOR-03/ship-course-unchanged", main.ship.global_position, ship_before)
	_assert_true("TRACTOR-03/planet-moves-closer", close_off_axis.global_position.distance_to(ship_before) < planet_before.distance_to(ship_before), {"before": planet_before, "after": close_off_axis.global_position})
	_assert_equal("TRACTOR-03/one-active-target", main.tractor_target, close_off_axis)
	main.state = main.GameState.READY
	main.tractor_beam_enabled = true
	_assert_equal("TRACTOR-04/on-label", main._tractor_button_label(), "TRACTOR BEAM: ON")
	main._toggle_tractor_beam()
	_assert_equal("TRACTOR-04/off-label", main._tractor_button_label(), "TRACTOR BEAM: OFF")
	var settings: ConfigFile = main._settings_config()
	_assert_equal("TRACTOR-04/persist-enabled", settings.get_value("tractor_beam", "enabled"), false)
	_assert_near("TRACTOR-04/persist-power", float(settings.get_value("tractor_beam", "strength")), main.TRACTOR_DEFAULT_STRENGTH, 0.001)
	_assert_equal("TRACTOR-04/power-label", main.TRACTOR_POWER_LABEL, "POWER")
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
	_observe("TARGET/roster-and-render-model", "size hierarchy, ring geometry, capture areas, black-hole blend, Earth silhouettes, and randomized layouts")


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
	_assert_equal("PILOT-02/planet-selection", ship.pilot_style, 2)
	_observe("SHIP/assets", "four raster ships retain high-resolution transparent sources; four procedural ships and three pilots remain selectable")


func _test_gameplay_flow() -> void:
	var main: Variant = await _new_main(root, "gameplay-flow-settings.cfg")
	main.tts_voice = ""
	main.target_speech_enqueued.connect(_on_target_speech_enqueued)
	main._prepare_run()
	_assert_equal("FLOW-01/ready-state", main.state, main.GameState.READY)
	_assert_equal("FLOW-01/target-count", main.total_targets, 15)
	_assert_equal("FLOW-01/spawned-count", main.planets.size(), main.total_targets)
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
	_assert_equal("FLOW-01/captured-count", main.captured_count, main.total_targets)
	_assert_true("FLOW-01/all-targets-captured", main.planets.all(func(planet: ColorPlanet) -> bool: return planet.captured), main.captured_count)
	_assert_equal("FLOW-01/speech-per-capture", speech_events.size(), main.total_targets)
	_assert_equal("FLOW-01/finale-state", main.state, main.GameState.FINALE)
	_assert_near("FLOW-01/final-time", main.final_time, 12.345, 0.001)
	_assert_near("FLOW-01/best-time", main.best_time, 12.345, 0.001)
	var meteors: Array[Node] = []
	for child in main.get_children():
		if child.get_script() == MeteorScript:
			meteors.append(child)
	_assert_equal("FLOW-01/meteor-per-target", meteors.size(), main.total_targets)
	for planet in main.planets:
		main._on_meteor_impact(planet)
	_assert_equal("FLOW-01/impact-count", main.finale_impacts, main.total_targets)
	_assert_true("FLOW-01/all-targets-exploding", main.planets.all(func(planet: ColorPlanet) -> bool: return planet.exploding), main.finale_impacts)
	main._show_results()
	_assert_equal("FLOW-01/results-state", main.state, main.GameState.RESULTS)
	_assert_equal("FLOW-01/ship-hidden", main.ship.visible, false)
	_observe("FLOW/complete-run", "ready, countdown, play, all captures, one meteor per target, explosions, score, and results")


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
	main.best_time = 34.039
	main._request_best_score_reset()
	_assert_near("PERSIST-01/reset-first-tap-arms", main.best_time, 34.039, 0.0001)
	main._request_best_score_reset()
	_assert_equal("PERSIST-01/reset-second-tap-clears", main.best_time, 0.0)
	main.best_time = 22.5
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
	main.state = main.GameState.PLAYING
	main.elapsed_time = 8.72
	main.captured_count = 0
	main.total_targets = 15
	main.ship.visible = true
	main._update_overlay()
	main.queue_redraw()
	var playing_image: Image = await _capture(viewport, "playing.png")
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
	main.state = main.GameState.RESULTS
	main.final_time = 34.039
	main.best_time = 34.039
	main.ship.visible = false
	main._update_overlay()
	main.queue_redraw()
	var results_image: Image = await _capture(viewport, "results.png")
	_assert_true("RENDER-04/results-panel-visible", _different_pixels(playing_image, results_image, Rect2i(300, 148, 680, 490), 0.03, 4) > 1500, "rendered result panel")

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
