extends Node2D


const PlanetScene := preload("res://scripts/planet.gd")
const ShipScene := preload("res://scripts/player_ship.gd")
const MeteorScene := preload("res://scripts/meteor.gd")

const SFX_STREAMS := {
	"meteor": preload("res://assets/sfx_meteor.ogg"),
	"explosion": preload("res://assets/sfx_explosion.ogg"),
}

const VIEW_SIZE := Vector2(1280.0, 720.0)
const HUD_HEIGHT := 136.0
const SHIP_BOUNDS := Rect2(35.0, 146.0, 1210.0, 536.0)
const SHIP_START := Vector2(640.0, 410.0)
const MENU_SHIP_POSITION := Vector2(640.0, 220.0)
const MENU_SHIP_SCALE := Vector2(1.28, 1.28)
const SHOUT_SAMPLE_RATE := 22050
const SHOUT_DURATION := 1.15
const COUNTDOWN_BEEP_FREQUENCY := 880.0
const COUNTDOWN_BEEP_DURATION := 0.11
const COUNTDOWN_BEEP_AMPLITUDE := 0.42
const COUNTDOWN_BEEP_VOLUME_DB := -5.0
const COUNTDOWN_BOOP_DURATION_MULTIPLIER := 2.0
const COUNTDOWN_BOOP_AMPLITUDE := 0.68
const COUNTDOWN_BOOP_BRIGHTNESS := 0.88
const COUNTDOWN_BOOP_VOLUME_DB := -1.5
const SAVE_PATH := "user://astrotops.cfg"
const TRACTOR_MIN_DISTANCE_FACTOR := 0.07
const TRACTOR_MAX_DISTANCE_FACTOR := 0.30
const TRACTOR_FIELD_BULB_RATIO := 0.46
const TRACTOR_MAX_PULL_RATIO := 0.30
const TRACTOR_PULL_BASE_SCALE := 0.85
const TRACTOR_PULL_TAPER := 0.15
const TRACTOR_DEFAULT_STRENGTH := 0.45
const TTS_RATE := 1.0

const BRAND_NAME := "ASTROTOPS"
const MENU_SUBTITLE := "SPACE RUSH"
const MENU_TAGLINE := "Paint every target. Beat your best time."
const READY_MESSAGE := "PRESS ANY KEY, GAMEPAD BUTTON, OR TAP\nTO START"
const PAUSE_MESSAGE := "FLIGHT PAUSED\nPRESS \"RESUME\" BUTTON WHEN YOU ARE READY"
const RESULT_TITLE := "MISSION COMPLETE!"
const RESULT_PILOT_FONT_SIZE := 28
const TRACTOR_POWER_LABEL := "POWER"

const BACK_BUTTON := Rect2(704.0, 16.0, 128.0, 50.0)
const RESET_BUTTON := Rect2(840.0, 16.0, 128.0, 50.0)
const PAUSE_BUTTON := Rect2(976.0, 16.0, 128.0, 50.0)
const CLOSE_BUTTON := Rect2(1112.0, 16.0, 128.0, 50.0)
const TRACTOR_BEAM_BUTTON := Rect2(18.0, 92.0, 260.0, 34.0)
const TRACTOR_SLIDER_TRACK := Rect2(390.0, 103.0, 360.0, 12.0)
const TRACTOR_SLIDER_HIT := Rect2(370.0, 84.0, 400.0, 48.0)

const SHIP_LABEL := Rect2(326.0, 302.0, 120.0, 54.0)
const SHIP_LEFT_BUTTON := Rect2(458.0, 302.0, 82.0, 54.0)
const SHIP_NAME_BUTTON := Rect2(552.0, 302.0, 310.0, 54.0)
const SHIP_RIGHT_BUTTON := Rect2(874.0, 302.0, 82.0, 54.0)
const COLOR_LABEL := Rect2(326.0, 370.0, 120.0, 54.0)
const COLOR_LEFT_BUTTON := Rect2(458.0, 370.0, 82.0, 54.0)
const COLOR_NAME_BUTTON := Rect2(552.0, 370.0, 310.0, 54.0)
const COLOR_RIGHT_BUTTON := Rect2(874.0, 370.0, 82.0, 54.0)
const PILOT_LABEL := Rect2(326.0, 438.0, 120.0, 54.0)
const PILOT_LEFT_BUTTON := Rect2(458.0, 438.0, 82.0, 54.0)
const PILOT_NAME_BUTTON := Rect2(552.0, 438.0, 310.0, 54.0)
const PILOT_RIGHT_BUTTON := Rect2(874.0, 438.0, 82.0, 54.0)
const START_BUTTON := Rect2(485.0, 516.0, 310.0, 62.0)
const RESET_BEST_BUTTON := Rect2(540.0, 636.0, 200.0, 32.0)
const AGAIN_BUTTON := Rect2(400.0, 545.0, 230.0, 72.0)
const MENU_BUTTON := Rect2(650.0, 545.0, 230.0, 72.0)

enum GameState { MENU, READY, COUNTDOWN, PLAYING, PAUSED, FINALE, RESULTS }

signal ui_click_requested
signal target_speech_enqueued(request: Dictionary)

var state := GameState.MENU
var state_before_pause := GameState.PLAYING
var palette := [
	Color("41f4c6"), Color("46a8ff"), Color("ff4e9c"),
	Color("ffc857"), Color("a879ff"), Color("76ed55"),
	Color("ff4a55"), Color("ff8a3d"), Color("edf7ff"), Color("20d9ff")
]
var color_names := [
	"Comet Mint", "Orbit Blue", "Nova Pink", "Solar Gold", "Nebula Violet",
	"Alien Lime", "Meteor Red", "Rocket Orange", "Starlight White", "Plasma Cyan",
]
var ship_names := [
	"Arrow Scout", "Dart Runner", "Nova Wing", "Orbit Saucer",
	"Comet Spear", "Twin Comet", "Star Skimmer", "Rocket Pod",
]
var pilot_names := ["Trixie", "Astronaut", "Planet"]
var selected_color_index := 0
var selected_ship_index := 0
var selected_pilot_index := 0

var ship: PlayerShip
var planets: Array[ColorPlanet] = []
var stars: Array[Dictionary] = []
var elapsed_time := 0.0
var final_time := 0.0
var best_time := 0.0
var captured_count := 0
var total_targets := 0
var countdown_value := 5
var countdown_phase := 0.0
var finale_impacts := 0
var input_hint_time := 0.0
var run_serial := 0
var tractor_beam_enabled := true
var tractor_beam_strength := TRACTOR_DEFAULT_STRENGTH
var tractor_target: ColorPlanet
var tractor_course_direction := Vector2.UP
var best_reset_confirmation_until := 0
var settings_path := SAVE_PATH
var audio_playback_enabled := true

var touch_id := -1
var touch_origin := Vector2.ZERO
var touch_position := Vector2.ZERO
var touch_vector := Vector2.ZERO
var mouse_steering := false
var tractor_slider_touch_id := -1
var tractor_slider_mouse_dragging := false

var font: Font
var overlay_layer: CanvasLayer
var overlay_shade: ColorRect
var message_label: Label
var countdown_label: Label
var shout_stream: AudioStreamWAV
var ui_click_stream: AudioStreamWAV
var countdown_beep_stream: AudioStreamWAV
var countdown_boop_stream: AudioStreamWAV
var tts_voice := ""
var target_speech_utterance_id := 0
var milky_way_texture: Texture2D


func _ready() -> void:
	font = ThemeDB.fallback_font
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
	_setup_tts()
	_make_stars()
	_load_settings()
	if ResourceLoader.exists("res://assets/milky_way_background.jpg"):
		milky_way_texture = load("res://assets/milky_way_background.jpg")
	_setup_overlay()
	ship = ShipScene.new()
	ship.z_index = 4
	add_child(ship)
	ship.configure(palette[selected_color_index], SHIP_BOUNDS, selected_ship_index, selected_pilot_index)
	ship.position = MENU_SHIP_POSITION
	ship.scale = MENU_SHIP_SCALE
	set_process_input(true)
	_update_overlay()
	queue_redraw()


func _process(delta: float) -> void:
	input_hint_time += delta
	match state:
		GameState.COUNTDOWN:
			countdown_phase += delta
			while countdown_phase >= 1.0 and state == GameState.COUNTDOWN:
				countdown_phase -= 1.0
				countdown_value -= 1
				if countdown_value <= 0:
					_launch_run()
				else:
					_play_countdown_tone(false)
		GameState.PLAYING:
			elapsed_time += delta
			var movement := _movement_input()
			ship.move_ship(movement, delta)
			_update_tractor_beam(delta, movement)
			_check_planet_contacts()
		GameState.MENU:
			ship.rotation = lerp_angle(ship.rotation, sin(input_hint_time * 0.6) * 0.08, delta * 2.0)
	_update_overlay()
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if state == GameState.MENU:
			get_tree().quit()
		else:
			_return_to_menu()


func _setup_overlay() -> void:
	# A CanvasLayer keeps countdown and pause messaging above the ship and planets.
	overlay_layer = CanvasLayer.new()
	overlay_layer.layer = 20
	add_child(overlay_layer)

	overlay_shade = ColorRect.new()
	overlay_shade.position = Vector2(0.0, HUD_HEIGHT)
	overlay_shade.size = Vector2(VIEW_SIZE.x, VIEW_SIZE.y - HUD_HEIGHT)
	overlay_shade.color = Color(0.01, 0.015, 0.06, 0.62)
	overlay_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay_layer.add_child(overlay_shade)

	message_label = Label.new()
	message_label.position = Vector2(140.0, 270.0)
	message_label.size = Vector2(1000.0, 190.0)
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message_label.add_theme_font_size_override("font_size", 38)
	message_label.add_theme_constant_override("outline_size", 12)
	message_label.add_theme_color_override("font_outline_color", Color(0.01, 0.015, 0.06, 0.96))
	message_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay_layer.add_child(message_label)

	countdown_label = Label.new()
	countdown_label.position = Vector2(440.0, 205.0)
	countdown_label.size = Vector2(400.0, 310.0)
	countdown_label.pivot_offset = countdown_label.size * 0.5
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	countdown_label.add_theme_font_size_override("font_size", 220)
	countdown_label.add_theme_constant_override("outline_size", 18)
	countdown_label.add_theme_color_override("font_outline_color", Color(0.01, 0.015, 0.06, 0.98))
	countdown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay_layer.add_child(countdown_label)


func _update_overlay() -> void:
	overlay_shade.visible = false
	message_label.visible = false
	countdown_label.visible = false
	if state == GameState.READY:
		overlay_shade.visible = true
		message_label.visible = true
		message_label.text = READY_MESSAGE
		message_label.modulate = palette[selected_color_index]
	elif state == GameState.COUNTDOWN:
		countdown_label.visible = true
		countdown_label.text = str(countdown_value)
		var zoom := lerpf(0.30, 3.45, pow(clampf(countdown_phase, 0.0, 1.0), 1.55))
		countdown_label.scale = Vector2.ONE * zoom
		countdown_label.rotation = lerpf(-0.045, 0.045, countdown_phase) * (-1.0 if countdown_value % 2 == 0 else 1.0)
		var fade := 1.0 - clampf((countdown_phase - 0.66) / 0.34, 0.0, 1.0)
		countdown_label.modulate = Color(palette[selected_color_index], fade)
	elif state == GameState.PAUSED:
		overlay_shade.visible = true
		message_label.visible = true
		message_label.text = PAUSE_MESSAGE
		message_label.modulate = palette[selected_color_index]


func _make_stars() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 22091986
	for index in range(150):
		stars.append({
			"position": Vector2(rng.randf_range(0.0, VIEW_SIZE.x), rng.randf_range(0.0, VIEW_SIZE.y)),
			"size": rng.randf_range(0.7, 2.1),
			"phase": rng.randf_range(0.0, TAU),
		})


func _load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(settings_path) == OK:
		best_time = float(config.get_value("times", "best", 0.0))
		tractor_beam_enabled = bool(config.get_value("tractor_beam", "enabled", true))
		tractor_beam_strength = clampf(float(config.get_value("tractor_beam", "strength", TRACTOR_DEFAULT_STRENGTH)), 0.0, 1.0)


func _save_settings() -> void:
	var config := _settings_config()
	config.save(settings_path)


func _settings_config() -> ConfigFile:
	var config := ConfigFile.new()
	config.set_value("times", "best", best_time)
	config.set_value("tractor_beam", "enabled", tractor_beam_enabled)
	config.set_value("tractor_beam", "strength", tractor_beam_strength)
	return config


func _save_best_time() -> void:
	if best_time <= 0.0 or final_time < best_time:
		best_time = final_time
		_save_settings()


func _body_specs() -> Array[Dictionary]:
	# Radii deliberately compress the real scale while preserving the recognizable hierarchy.
	return [
		{"name": "Sun", "radius": 60.0, "style": "sun"},
		{"name": "Black Hole", "radius": 30.0, "style": "black_hole"},
		{"name": "Jupiter", "radius": 54.0, "style": "jupiter"},
		{"name": "Saturn", "radius": 46.0, "style": "saturn"},
		{"name": "Uranus", "radius": 38.0, "style": "uranus"},
		{"name": "Neptune", "radius": 37.0, "style": "neptune"},
		{"name": "Earth", "radius": 30.0, "style": "earth"},
		{"name": "Venus", "radius": 29.0, "style": "venus"},
		{"name": "Mars", "radius": 22.0, "style": "mars"},
		{"name": "Mercury", "radius": 17.0, "style": "mercury"},
		{"name": "Moon", "radius": 15.0, "style": "moon"},
		{"name": "Pluto", "radius": 14.0, "style": "pluto"},
		{"name": "Haumea", "radius": 13.0, "style": "haumea"},
		{"name": "Asteroid", "radius": 13.0, "style": "asteroid_a"},
		{"name": "Asteroid", "radius": 11.0, "style": "asteroid_b"},
	]


func _spawn_planets() -> void:
	_clear_planets()
	run_serial += 1
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var specs := _body_specs()
	var positions := _random_target_positions(specs, rng)
	for index in range(specs.size()):
		var spec: Dictionary = specs[index]
		var planet: ColorPlanet = PlanetScene.new()
		planet.configure(String(spec["name"]), float(spec["radius"]), String(spec["style"]), 1000 + run_serial * 101 + index * 37)
		planet.position = positions[index]
		planet.z_index = 2
		add_child(planet)
		planets.append(planet)
	total_targets = planets.size()


func _random_target_positions(specs: Array[Dictionary], rng: RandomNumberGenerator) -> Array[Vector2]:
	# Continuous sampling removes visible rows while keeping bodies, rings, labels, and the ship separated.
	for layout_attempt in range(32):
		var positions: Array[Vector2] = []
		var extents: Array[float] = []
		for spec in specs:
			var extent := _layout_extent(spec)
			var candidate := Vector2.ZERO
			var placed := false
			for candidate_attempt in range(500):
				candidate = Vector2(
					rng.randf_range(maxf(82.0, extent + 20.0), minf(1198.0, VIEW_SIZE.x - extent - 20.0)),
					rng.randf_range(HUD_HEIGHT + extent + 18.0, VIEW_SIZE.y - extent - 36.0)
				)
				if candidate.distance_to(SHIP_START) < extent + 92.0:
					continue
				var has_clearance := true
				for other_index in range(positions.size()):
					var required_distance := maxf(128.0, extent + extents[other_index] + 30.0)
					if candidate.distance_to(positions[other_index]) < required_distance:
						has_clearance = false
						break
				if has_clearance:
					placed = true
					break
			if not placed:
				break
			positions.append(candidate)
			extents.append(extent)
		if positions.size() == specs.size():
			return positions
	# This irregular layout is reachable only if every randomized packing attempt fails.
	return [
		Vector2(150.0, 190.0), Vector2(1080.0, 180.0), Vector2(1020.0, 580.0),
		Vector2(220.0, 560.0), Vector2(780.0, 170.0), Vector2(430.0, 180.0),
		Vector2(1120.0, 390.0), Vector2(500.0, 580.0), Vector2(880.0, 560.0),
		Vector2(330.0, 400.0), Vector2(820.0, 390.0), Vector2(500.0, 360.0),
		Vector2(670.0, 590.0), Vector2(650.0, 140.0), Vector2(650.0, 280.0),
	]


func _layout_extent(spec: Dictionary) -> float:
	var radius := float(spec["radius"])
	match String(spec["style"]):
		"sun": return radius * 1.22
		"black_hole": return radius * 2.25
		"saturn": return radius * 1.75
		"uranus": return radius * 1.38
		"haumea": return radius * 1.30
		_: return radius


func _clear_planets() -> void:
	tractor_target = null
	for planet in planets:
		if is_instance_valid(planet):
			planet.queue_free()
	planets.clear()
	for child in get_children():
		if child is TargetMeteor:
			child.queue_free()


func _prepare_run() -> void:
	_stop_target_speech()
	_spawn_planets()
	captured_count = 0
	elapsed_time = 0.0
	final_time = 0.0
	finale_impacts = 0
	countdown_value = 5
	countdown_phase = 0.0
	state = GameState.READY
	ship.visible = true
	ship.position = SHIP_START
	ship.rotation = 0.0
	ship.scale = Vector2.ONE
	ship.configure(palette[selected_color_index], SHIP_BOUNDS, selected_ship_index, selected_pilot_index)
	ship.stop()
	tractor_course_direction = Vector2.UP
	_clear_touch()


func _begin_countdown() -> void:
	if state != GameState.READY:
		return
	state = GameState.COUNTDOWN
	countdown_value = 5
	countdown_phase = 0.0
	_play_countdown_tone(false)


func _launch_run() -> void:
	state = GameState.PLAYING
	countdown_phase = 0.0
	_play_countdown_tone(true)


func _reset_run() -> void:
	_play_ui_click()
	_prepare_run()


func _toggle_pause() -> void:
	if state in [GameState.COUNTDOWN, GameState.PLAYING]:
		state_before_pause = state
		state = GameState.PAUSED
		ship.stop()
		_clear_touch()
		_play_ui_click()
	elif state == GameState.PAUSED:
		state = state_before_pause
		_play_ui_click()


func _check_planet_contacts() -> void:
	for planet in planets:
		if not is_instance_valid(planet) or planet.captured:
			continue
		if ship.position.distance_to(planet.position) <= planet.capture_radius() + ship.hit_radius * 0.72:
			if planet.capture(palette[selected_color_index]):
				captured_count += 1
				_speak_target_name(planet.body_name)
				if captured_count >= total_targets:
					_finish_run()


func _finish_run() -> void:
	state = GameState.FINALE
	tractor_target = null
	final_time = elapsed_time
	ship.stop()
	_save_best_time()
	_clear_touch()
	_play_sfx("meteor", 1.0, -5.0)
	for index in range(planets.size()):
		var planet := planets[index]
		if not is_instance_valid(planet):
			continue
		var angle := TAU * float(index) / float(planets.size()) + 0.27
		var start := VIEW_SIZE * 0.5 + Vector2.from_angle(angle) * 920.0
		var meteor: TargetMeteor = MeteorScene.new()
		meteor.z_index = 6
		add_child(meteor)
		meteor.setup(start, planet.position, 0.28 + index * 0.095, 1.05 + float(index % 4) * 0.10, planet, -80.0 + float(index % 5) * 38.0)
		meteor.impacted.connect(_on_meteor_impact)


func _on_meteor_impact(planet: Node) -> void:
	if finale_impacts == 0:
		_play_shout()
	if is_instance_valid(planet):
		planet.explode()
	finale_impacts += 1
	_play_sfx("explosion", 0.88 + float(finale_impacts % 5) * 0.055, -4.0)
	if finale_impacts >= total_targets:
		get_tree().create_timer(1.05).timeout.connect(_show_results)


func _show_results() -> void:
	if state == GameState.FINALE:
		state = GameState.RESULTS
		ship.visible = false


func _return_to_menu() -> void:
	_stop_target_speech()
	_play_ui_click()
	_clear_planets()
	state = GameState.MENU
	ship.visible = true
	ship.position = MENU_SHIP_POSITION
	ship.rotation = 0.0
	ship.scale = MENU_SHIP_SCALE
	ship.configure(palette[selected_color_index], SHIP_BOUNDS, selected_ship_index, selected_pilot_index)
	ship.stop()
	_clear_touch()


func _movement_input() -> Vector2:
	var movement := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		movement.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		movement.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		movement.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		movement.y += 1.0

	var joypads := Input.get_connected_joypads()
	if not joypads.is_empty():
		var joypad: int = joypads[0]
		var stick := Vector2(Input.get_joy_axis(joypad, JOY_AXIS_LEFT_X), Input.get_joy_axis(joypad, JOY_AXIS_LEFT_Y))
		if stick.length() > 0.18:
			movement = stick
		var dpad := Vector2(
			float(Input.is_joy_button_pressed(joypad, JOY_BUTTON_DPAD_RIGHT)) - float(Input.is_joy_button_pressed(joypad, JOY_BUTTON_DPAD_LEFT)),
			float(Input.is_joy_button_pressed(joypad, JOY_BUTTON_DPAD_DOWN)) - float(Input.is_joy_button_pressed(joypad, JOY_BUTTON_DPAD_UP))
		)
		if dpad.length_squared() > 0.0:
			movement = dpad

	if touch_vector.length_squared() > 0.01:
		movement = touch_vector
	return movement.limit_length(1.0)


func _update_tractor_beam(delta: float, movement: Vector2) -> void:
	tractor_target = null
	if not tractor_beam_enabled or tractor_beam_strength <= 0.0:
		return
	var course_direction := ship.velocity.normalized()
	if ship.velocity.length() < 36.0:
		course_direction = movement.normalized()
	if course_direction.length_squared() < 0.0001:
		return
	tractor_course_direction = course_direction
	var candidate := _best_tractor_candidate(course_direction)
	if candidate.is_empty():
		return
	tractor_target = candidate["planet"]
	# A target near the pear boundary still receives a gentle pull instead of dropping to zero.
	var alignment := lerpf(1.0, 0.25, float(candidate["field_normalized"]))
	var distance_factor := lerpf(1.0, 0.38, float(candidate["distance_normalized"]))
	var effective_power := _tractor_pull_power()
	var pull_speed := clampf(
		ship.max_speed * TRACTOR_MAX_PULL_RATIO * effective_power * alignment * distance_factor,
		0.0,
		ship.max_speed * TRACTOR_MAX_PULL_RATIO
	)
	tractor_target.global_position = tractor_target.global_position.move_toward(ship.global_position, pull_speed * delta)


func _tractor_pull_power() -> float:
	var power := tractor_beam_strength
	return power * (TRACTOR_PULL_BASE_SCALE - TRACTOR_PULL_TAPER * power)


func _tractor_max_distance(viewport_size: Vector2) -> float:
	var distance_factor := lerpf(TRACTOR_MIN_DISTANCE_FACTOR, TRACTOR_MAX_DISTANCE_FACTOR, tractor_beam_strength)
	return viewport_size.length() * distance_factor


func _tractor_field_half_width(forward_normalized: float, max_distance: float) -> float:
	var progress := clampf(forward_normalized, 0.0, 1.0)
	# The ship sits at the broad end: the field swells immediately around nearby
	# off-course targets, then narrows steadily toward its distant tip.
	var rounded_profile := pow(maxf(0.0, sin(PI * progress)), 0.58)
	var near_weight := lerpf(1.40, 0.35, progress)
	var ship_socket := ship.hit_radius * 1.20 * (1.0 - progress)
	return ship_socket + max_distance * TRACTOR_FIELD_BULB_RATIO * rounded_profile * near_weight


func _best_tractor_candidate(course_direction: Vector2) -> Dictionary:
	var canvas_transform := get_viewport().get_canvas_transform()
	var viewport_rect := Rect2(Vector2.ZERO, get_viewport_rect().size)
	var ship_screen := canvas_transform * ship.global_position
	var course_screen := (canvas_transform * (ship.global_position + course_direction)) - ship_screen
	if course_screen.length_squared() < 0.0001:
		return {}
	course_screen = course_screen.normalized()
	var max_distance := _tractor_max_distance(viewport_rect.size)
	var best_score := INF
	var best_candidate := {}
	for planet in planets:
		if not is_instance_valid(planet) or planet.captured or not planet.is_visible_in_tree():
			continue
		var target_screen := canvas_transform * planet.global_position
		var visual_extent := planet.visual_extent()
		var extent_x_screen := canvas_transform * planet.to_global(Vector2(visual_extent, 0.0))
		var extent_y_screen := canvas_transform * planet.to_global(Vector2(0.0, visual_extent))
		var visibility_margin := maxf(target_screen.distance_to(extent_x_screen), target_screen.distance_to(extent_y_screen))
		if not viewport_rect.grow(visibility_margin).has_point(target_screen):
			continue
		var screen_delta := target_screen - ship_screen
		var screen_distance := screen_delta.length()
		if screen_distance <= 0.001:
			continue
		var forward_distance := screen_delta.dot(course_screen)
		if forward_distance <= 0.0 or forward_distance > max_distance:
			continue
		var forward_normalized := forward_distance / max_distance
		var half_width := _tractor_field_half_width(forward_normalized, max_distance)
		var lateral_distance := absf(course_screen.cross(screen_delta))
		if lateral_distance > half_width:
			continue
		var field_normalized := clampf(lateral_distance / maxf(half_width, 1.0), 0.0, 1.0)
		var distance_normalized := clampf(screen_distance / max_distance, 0.0, 1.0)
		# Course alignment remains dominant; distance breaks ties between similar bearings.
		var score := field_normalized * 0.80 + distance_normalized * 0.20
		if score < best_score:
			best_score = score
			best_candidate = {
				"planet": planet,
				"field_normalized": field_normalized,
				"distance_normalized": distance_normalized,
			}
	return best_candidate


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if state == GameState.READY:
			if event.keycode == KEY_ESCAPE:
				_return_to_menu()
			else:
				_begin_countdown()
			return
		if event.keycode == KEY_ESCAPE:
			if state == GameState.MENU:
				get_tree().quit()
			else:
				_return_to_menu()
		elif event.keycode == KEY_P and state in [GameState.COUNTDOWN, GameState.PLAYING, GameState.PAUSED]:
			_toggle_pause()
		elif event.keycode == KEY_M and _can_adjust_tractor_beam():
			_toggle_tractor_beam()
		elif event.keycode == KEY_R and state != GameState.MENU:
			_reset_run()
		elif state == GameState.MENU:
			if event.keycode in [KEY_LEFT, KEY_A]:
				_change_color(-1)
			elif event.keycode in [KEY_RIGHT, KEY_D]:
				_change_color(1)
			elif event.keycode in [KEY_UP, KEY_W]:
				_change_ship(-1)
			elif event.keycode in [KEY_DOWN, KEY_S]:
				_change_ship(1)
			elif event.keycode == KEY_Q:
				_change_pilot(-1)
			elif event.keycode == KEY_E:
				_change_pilot(1)
			elif event.keycode in [KEY_ENTER, KEY_SPACE]:
				_play_ui_click()
				_prepare_run()
		elif state == GameState.RESULTS and event.keycode in [KEY_ENTER, KEY_SPACE]:
			_play_ui_click()
			_prepare_run()

	elif event is InputEventJoypadButton and event.pressed:
		if state == GameState.READY:
			if event.button_index == JOY_BUTTON_B:
				_return_to_menu()
			else:
				_begin_countdown()
			return
		if event.button_index == JOY_BUTTON_B:
			if state != GameState.MENU:
				_return_to_menu()
		elif event.button_index == JOY_BUTTON_START and state in [GameState.COUNTDOWN, GameState.PLAYING, GameState.PAUSED]:
			_toggle_pause()
		elif event.button_index == JOY_BUTTON_X and _can_adjust_tractor_beam():
			_toggle_tractor_beam()
		elif state == GameState.MENU and event.button_index == JOY_BUTTON_DPAD_LEFT:
			_change_color(-1)
		elif state == GameState.MENU and event.button_index == JOY_BUTTON_DPAD_RIGHT:
			_change_color(1)
		elif state == GameState.MENU and event.button_index == JOY_BUTTON_DPAD_UP:
			_change_ship(-1)
		elif state == GameState.MENU and event.button_index == JOY_BUTTON_DPAD_DOWN:
			_change_ship(1)
		elif state == GameState.MENU and event.button_index == JOY_BUTTON_LEFT_SHOULDER:
			_change_pilot(-1)
		elif state == GameState.MENU and event.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			_change_pilot(1)
		elif event.button_index == JOY_BUTTON_A and state in [GameState.MENU, GameState.RESULTS]:
			_play_ui_click()
			_prepare_run()

	elif event is InputEventScreenTouch:
		_handle_pointer(event.position, event.pressed, event.index)
	elif event is InputEventScreenDrag:
		if event.index == tractor_slider_touch_id:
			_update_tractor_strength_from_x(event.position.x)
		elif event.index == touch_id:
			touch_position = event.position
			_update_touch_vector()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_handle_mouse_pointer(event.position, event.pressed)
	elif event is InputEventMouseMotion:
		if tractor_slider_mouse_dragging:
			_update_tractor_strength_from_x(event.position.x)
		elif mouse_steering:
			touch_position = event.position
			_update_touch_vector()


func _handle_pointer(position: Vector2, pressed: bool, pointer_id: int) -> void:
	if pressed:
		if _can_adjust_tractor_beam() and TRACTOR_SLIDER_HIT.has_point(position):
			_play_ui_click()
			tractor_slider_touch_id = pointer_id
			_update_tractor_strength_from_x(position.x)
			return
		if _handle_system_button(position):
			return
		if state == GameState.MENU:
			_handle_menu_click(position)
		elif state == GameState.RESULTS:
			_handle_results_click(position)
		elif state == GameState.READY:
			_begin_countdown()
		elif state == GameState.PLAYING and position.x < VIEW_SIZE.x * 0.62 and touch_id == -1:
			touch_id = pointer_id
			touch_origin = position
			touch_position = position
	else:
		if pointer_id == tractor_slider_touch_id:
			tractor_slider_touch_id = -1
			_save_settings()
			return
		if pointer_id == touch_id:
			_clear_touch()


func _handle_mouse_pointer(position: Vector2, pressed: bool) -> void:
	if pressed:
		if _can_adjust_tractor_beam() and TRACTOR_SLIDER_HIT.has_point(position):
			_play_ui_click()
			tractor_slider_mouse_dragging = true
			_update_tractor_strength_from_x(position.x)
			return
		if _handle_system_button(position):
			return
		if state == GameState.MENU:
			_handle_menu_click(position)
		elif state == GameState.RESULTS:
			_handle_results_click(position)
		elif state == GameState.READY:
			_begin_countdown()
		elif state == GameState.PLAYING and position.x < VIEW_SIZE.x * 0.62:
			mouse_steering = true
			touch_origin = position
			touch_position = position
	else:
		if tractor_slider_mouse_dragging:
			tractor_slider_mouse_dragging = false
			_save_settings()
			return
		mouse_steering = false
		if touch_id == -1:
			_clear_touch()


func _handle_system_button(position: Vector2) -> bool:
	if CLOSE_BUTTON.has_point(position):
		_play_ui_click()
		get_tree().quit()
		return true
	if state == GameState.MENU:
		return false
	if BACK_BUTTON.has_point(position):
		_return_to_menu()
		return true
	if RESET_BUTTON.has_point(position):
		_reset_run()
		return true
	if TRACTOR_BEAM_BUTTON.has_point(position) and _can_adjust_tractor_beam():
		_toggle_tractor_beam()
		return true
	if PAUSE_BUTTON.has_point(position) and state in [GameState.COUNTDOWN, GameState.PLAYING, GameState.PAUSED]:
		_toggle_pause()
		return true
	return false


func _update_touch_vector() -> void:
	var offset := touch_position - touch_origin
	touch_vector = (offset / 72.0).limit_length(1.0)
	touch_position = touch_origin + offset.limit_length(72.0)


func _clear_touch() -> void:
	touch_id = -1
	touch_vector = Vector2.ZERO
	mouse_steering = false
	tractor_slider_touch_id = -1
	tractor_slider_mouse_dragging = false


func _handle_menu_click(position: Vector2) -> void:
	if SHIP_LEFT_BUTTON.has_point(position):
		_change_ship(-1)
	elif SHIP_RIGHT_BUTTON.has_point(position):
		_change_ship(1)
	elif COLOR_LEFT_BUTTON.has_point(position):
		_change_color(-1)
	elif COLOR_RIGHT_BUTTON.has_point(position):
		_change_color(1)
	elif PILOT_LEFT_BUTTON.has_point(position):
		_change_pilot(-1)
	elif PILOT_RIGHT_BUTTON.has_point(position):
		_change_pilot(1)
	elif START_BUTTON.has_point(position):
		_play_ui_click()
		_prepare_run()
	elif RESET_BEST_BUTTON.has_point(position):
		_request_best_score_reset()


func _handle_results_click(position: Vector2) -> void:
	if AGAIN_BUTTON.has_point(position):
		_play_ui_click()
		_prepare_run()
	elif MENU_BUTTON.has_point(position):
		_return_to_menu()


func _change_color(step: int) -> void:
	selected_color_index = wrapi(selected_color_index + step, 0, palette.size())
	ship.configure(palette[selected_color_index], SHIP_BOUNDS, selected_ship_index, selected_pilot_index)
	_play_ui_click()


func _change_ship(step: int) -> void:
	selected_ship_index = wrapi(selected_ship_index + step, 0, ship_names.size())
	ship.configure(palette[selected_color_index], SHIP_BOUNDS, selected_ship_index, selected_pilot_index)
	_play_ui_click()


func _change_pilot(step: int) -> void:
	selected_pilot_index = wrapi(selected_pilot_index + step, 0, pilot_names.size())
	ship.configure(palette[selected_color_index], SHIP_BOUNDS, selected_ship_index, selected_pilot_index)
	_play_ui_click()


func _can_adjust_tractor_beam() -> bool:
	return state in [GameState.READY, GameState.COUNTDOWN, GameState.PLAYING, GameState.PAUSED]


func _toggle_tractor_beam() -> void:
	tractor_beam_enabled = not tractor_beam_enabled
	if not tractor_beam_enabled:
		tractor_target = null
	_save_settings()
	_play_ui_click()


func _update_tractor_strength_from_x(pointer_x: float) -> void:
	tractor_beam_strength = clampf(
		(pointer_x - TRACTOR_SLIDER_TRACK.position.x) / TRACTOR_SLIDER_TRACK.size.x,
		0.0,
		1.0
	)
	if tractor_beam_strength <= 0.0:
		tractor_target = null


func _request_best_score_reset() -> void:
	var now := Time.get_ticks_msec()
	if now <= best_reset_confirmation_until:
		best_time = 0.0
		best_reset_confirmation_until = 0
		_save_settings()
		_play_ui_click()
	else:
		best_reset_confirmation_until = now + 2500
		_play_ui_click()


func _make_mouse_click_stream() -> AudioStreamWAV:
	# Two short, damped transients mimic a mechanical mouse press and release.
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SHOUT_SAMPLE_RATE
	stream.stereo = false
	var duration := 0.070
	var sample_count := int(duration * float(SHOUT_SAMPLE_RATE))
	var samples := PackedByteArray()
	samples.resize(sample_count * 2)
	for index in range(sample_count):
		var time := float(index) / float(SHOUT_SAMPLE_RATE)
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
	# Smooth envelopes avoid clicks; optional odd harmonics give the low final
	# tone enough edge to remain sharp instead of becoming a dull sine thump.
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SHOUT_SAMPLE_RATE
	stream.stereo = false
	var sample_count := int(duration * float(SHOUT_SAMPLE_RATE))
	var samples := PackedByteArray()
	samples.resize(sample_count * 2)
	var phase := 0.0
	for index in range(sample_count):
		var time := float(index) / float(SHOUT_SAMPLE_RATE)
		var progress := time / duration
		var frequency := lerpf(start_frequency, end_frequency, progress)
		phase += TAU * frequency / float(SHOUT_SAMPLE_RATE)
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
	if stream == null or not audio_playback_enabled:
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


func _play_ui_click() -> void:
	ui_click_requested.emit()
	_play_generated_stream(ui_click_stream, -8.0)


func _play_countdown_tone(final_boop: bool) -> void:
	_play_generated_stream(
		countdown_boop_stream if final_boop else countdown_beep_stream,
		COUNTDOWN_BOOP_VOLUME_DB if final_boop else COUNTDOWN_BEEP_VOLUME_DB
	)


func _play_sfx(effect: String, pitch := 1.0, volume_db := 0.0) -> void:
	if not audio_playback_enabled or not SFX_STREAMS.has(effect):
		return
	# One-shot players self-remove, allowing closely spaced meteor impacts to overlap cleanly.
	var player := AudioStreamPlayer.new()
	player.stream = SFX_STREAMS[effect]
	player.pitch_scale = pitch
	player.volume_db = volume_db
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


func _setup_tts() -> void:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH):
		return
	var voices := DisplayServer.tts_get_voices_for_language("en")
	if voices.is_empty():
		voices = DisplayServer.tts_get_voices_for_language("en-US")
	if not voices.is_empty():
		tts_voice = String(voices[0])


func _speak_target_name(target_name: String) -> void:
	target_speech_utterance_id += 1
	var request := _target_speech_request(target_name, target_speech_utterance_id)
	target_speech_enqueued.emit(request)
	if tts_voice.is_empty():
		return
	# Godot's native synthesizer owns the utterance queue. Submitting immediately
	# removes the application-side pause while interrupt=false keeps names ordered
	# and non-overlapping.
	DisplayServer.tts_speak(
		String(request["text"]),
		tts_voice,
		int(request["volume"]),
		float(request["pitch"]),
		float(request["rate"]),
		int(request["utterance_id"]),
		bool(request["interrupt"])
	)


func _target_speech_request(target_name: String, utterance_id: int) -> Dictionary:
	return {
		"text": "how MAY uh" if target_name == "Haumea" else target_name,
		"volume": 58,
		"pitch": 1.0,
		"rate": TTS_RATE,
		"utterance_id": utterance_id,
		"interrupt": false,
	}


func _stop_target_speech() -> void:
	if not tts_voice.is_empty():
		DisplayServer.tts_stop()


func _make_shout_stream() -> AudioStreamWAV:
	# Build a short vowel-like shout in memory so every platform hears the same finale cue.
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SHOUT_SAMPLE_RATE
	stream.stereo = false
	var sample_count := int(SHOUT_DURATION * float(SHOUT_SAMPLE_RATE))
	var samples := PackedByteArray()
	samples.resize(sample_count * 2)
	var phase := 0.0
	for index in range(sample_count):
		var time := float(index) / float(SHOUT_SAMPLE_RATE)
		var progress := time / SHOUT_DURATION
		var attack := clampf(time / 0.055, 0.0, 1.0)
		var release := clampf((SHOUT_DURATION - time) / 0.24, 0.0, 1.0)
		var pitch := lerpf(174.0, 132.0, progress) + sin(time * TAU * 2.2) * 3.5
		phase += TAU * pitch / float(SHOUT_SAMPLE_RATE)
		var voice := sin(phase) * 0.58 + sin(phase * 2.0) * 0.20 + sin(phase * 3.0) * 0.10
		var formants := sin(time * TAU * 720.0) * 0.075 + sin(time * TAU * 1120.0) * 0.045
		var tremolo := 0.91 + sin(time * TAU * 5.2) * 0.09
		var value := clampf((voice + formants) * attack * release * tremolo * 0.52, -1.0, 1.0)
		var pcm := int(round(value * 32767.0))
		samples[index * 2] = pcm & 0xff
		samples[index * 2 + 1] = (pcm >> 8) & 0xff
	stream.data = samples
	return stream


func _play_shout() -> void:
	if shout_stream == null or not audio_playback_enabled:
		return
	var player := AudioStreamPlayer.new()
	player.stream = shout_stream
	player.volume_db = -11.0
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


func _format_time(value: float) -> String:
	var minutes := int(floor(value / 60.0))
	var seconds := fmod(value, 60.0)
	return "%02d:%05.2f" % [minutes, seconds]


func _center_text(text: String, y: float, size: int, color := Color.WHITE) -> void:
	draw_string(font, Vector2(0.0, y), text, HORIZONTAL_ALIGNMENT_CENTER, VIEW_SIZE.x, size, color)


func _chamfered_points(rect: Rect2, cut := 8.0) -> PackedVector2Array:
	return PackedVector2Array([
		rect.position + Vector2(cut, 0.0),
		Vector2(rect.end.x - cut, rect.position.y),
		Vector2(rect.end.x, rect.position.y + cut),
		rect.end - Vector2(0.0, cut),
		rect.end - Vector2(cut, 0.0),
		Vector2(rect.position.x + cut, rect.end.y),
		Vector2(rect.position.x, rect.end.y - cut),
		rect.position + Vector2(0.0, cut),
	])


func _closed_outline(points: PackedVector2Array) -> PackedVector2Array:
	var outline := points.duplicate()
	outline.append(points[0])
	return outline


func _outlined_rect_text(rect: Rect2, label: String, size: int, color: Color) -> void:
	var baseline := rect.position.y + (rect.size.y + float(size)) * 0.5 - 3.0
	var shadow_position := Vector2(rect.position.x + 2.0, baseline + 2.0)
	draw_string(font, shadow_position, label, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, size, Color(0.0, 0.0, 0.04, 0.96))
	draw_string(font, Vector2(rect.position.x, baseline), label, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, size, color)


func _button(rect: Rect2, label: String, color: Color, enabled := true) -> void:
	var fill := Color(0.025, 0.035, 0.12, 0.96) if enabled else Color(0.025, 0.03, 0.07, 0.78)
	var stroke := color if enabled else Color(color, 0.32)
	var text_color := Color.WHITE if enabled else Color(0.70, 0.74, 0.84, 0.45)
	var points := _chamfered_points(rect, minf(9.0, rect.size.y * 0.24))
	draw_colored_polygon(points, fill)
	draw_polyline(_closed_outline(points), stroke, 3.0, true)
	draw_line(rect.position + Vector2(13.0, 6.0), Vector2(rect.end.x - 13.0, rect.position.y + 6.0), Color(stroke.lightened(0.35), 0.42), 1.0, true)
	var font_size := 15 if rect.size.y <= 38.0 else (20 if rect.size.y <= 54.0 else 22)
	_outlined_rect_text(rect, label, font_size, text_color)


func _arrow_button(rect: Rect2, direction: float, color: Color) -> void:
	var points := _chamfered_points(rect, minf(9.0, rect.size.y * 0.24))
	draw_colored_polygon(points, Color(0.025, 0.035, 0.12, 0.96))
	draw_polyline(_closed_outline(points), color, 3.0, true)
	var arrow := _arrow_shape_points(rect, direction)
	draw_colored_polygon(arrow, color.lightened(0.20))
	draw_polyline(_closed_outline(arrow), Color.WHITE, 1.2, true)
	var center := rect.get_center()
	draw_line(
		center - Vector2(23.0 * direction, 7.0),
		center - Vector2(23.0 * direction, -7.0),
		Color(color, 0.72),
		2.0,
		true
	)


func _arrow_shape_points(rect: Rect2, direction: float) -> PackedVector2Array:
	var center := rect.get_center()
	return PackedVector2Array([
		center + Vector2(15.0 * direction, 0.0),
		center + Vector2(-3.0 * direction, -15.0),
		center + Vector2(-3.0 * direction, -7.0),
		center + Vector2(-14.0 * direction, -7.0),
		center + Vector2(-14.0 * direction, 7.0),
		center + Vector2(-3.0 * direction, 7.0),
		center + Vector2(-3.0 * direction, 15.0),
	])


func _selector(rect: Rect2, label: String) -> void:
	var accent: Color = palette[selected_color_index]
	var points := _chamfered_points(rect, 9.0)
	draw_colored_polygon(points, Color(accent, 0.17))
	draw_polyline(_closed_outline(points), accent, 3.0, true)
	draw_line(rect.position + Vector2(18.0, 7.0), Vector2(rect.end.x - 18.0, rect.position.y + 7.0), Color(accent.lightened(0.38), 0.42), 1.0, true)
	_outlined_rect_text(rect, label, 21, Color.WHITE)


func _section_label(rect: Rect2, label: String) -> void:
	var accent: Color = palette[selected_color_index]
	var points := _chamfered_points(rect, 8.0)
	draw_colored_polygon(points, Color(0.02, 0.03, 0.10, 0.90))
	draw_polyline(_closed_outline(points), Color(accent, 0.72), 2.0, true)
	draw_rect(Rect2(rect.position + Vector2(8.0, 9.0), Vector2(4.0, rect.size.y - 18.0)), accent, true)
	_outlined_rect_text(rect, label, 20, accent.lightened(0.45))


func _draw_planet_letter(center: Vector2, radius: float, planet_color: Color, ring_color: Color) -> void:
	draw_set_transform(center, -0.30, Vector2(1.0, 0.38))
	draw_arc(Vector2.ZERO, radius * 1.62, 0.0, TAU, 42, Color(ring_color, 0.92), 4.5, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	draw_circle(center + Vector2(2.5, 3.0), radius + 1.5, Color(0.0, 0.0, 0.04, 0.86))
	draw_circle(center, radius, planet_color)
	draw_circle(center - Vector2(radius * 0.24, radius * 0.26), radius * 0.50, planet_color.lightened(0.34))
	draw_circle(center + Vector2(radius * 0.25, radius * 0.14), radius * 0.13, Color(planet_color.darkened(0.30), 0.76))
	draw_arc(center, radius, 0.0, TAU, 30, Color.WHITE, 1.6, true)


func _draw_brand_title(baseline_y: float, size: int, color: Color) -> void:
	var astr_width := font.get_string_size("ASTR", HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x
	var t_width := font.get_string_size("T", HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x
	var ps_width := font.get_string_size("PS", HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x
	var planet_width := float(size) * 0.94
	var total_width := astr_width + t_width + ps_width + planet_width * 2.0 + 12.0
	var x := (VIEW_SIZE.x - total_width) * 0.5
	var planet_center_y := baseline_y - float(size) * 0.36
	var radius := float(size) * 0.35

	draw_string(font, Vector2(x + 3.0, baseline_y + 3.0), "ASTR", HORIZONTAL_ALIGNMENT_LEFT, astr_width, size, Color(0.0, 0.0, 0.04, 0.90))
	draw_string(font, Vector2(x, baseline_y), "ASTR", HORIZONTAL_ALIGNMENT_LEFT, astr_width, size, color)
	x += astr_width + 3.0
	_draw_planet_letter(Vector2(x + planet_width * 0.5, planet_center_y), radius, Color("73caff"), Color("ffc857"))
	x += planet_width + 3.0
	draw_string(font, Vector2(x + 3.0, baseline_y + 3.0), "T", HORIZONTAL_ALIGNMENT_LEFT, t_width, size, Color(0.0, 0.0, 0.04, 0.90))
	draw_string(font, Vector2(x, baseline_y), "T", HORIZONTAL_ALIGNMENT_LEFT, t_width, size, color)
	x += t_width + 3.0
	_draw_planet_letter(Vector2(x + planet_width * 0.5, planet_center_y), radius, Color("a879ff"), Color("41f4c6"))
	x += planet_width + 3.0
	draw_string(font, Vector2(x + 3.0, baseline_y + 3.0), "PS", HORIZONTAL_ALIGNMENT_LEFT, ps_width, size, Color(0.0, 0.0, 0.04, 0.90))
	draw_string(font, Vector2(x, baseline_y), "PS", HORIZONTAL_ALIGNMENT_LEFT, ps_width, size, color)


func _draw_space_subtitle(text: String, baseline_y: float, size: int, color: Color) -> void:
	var text_width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x
	var x := (VIEW_SIZE.x - text_width) * 0.5
	var line_y := baseline_y - float(size) * 0.32
	draw_line(Vector2(x - 92.0, line_y), Vector2(x - 16.0, line_y), Color(color, 0.72), 2.0, true)
	draw_line(Vector2(x + text_width + 16.0, line_y), Vector2(x + text_width + 92.0, line_y), Color(color, 0.72), 2.0, true)
	draw_circle(Vector2(x - 102.0, line_y), 3.0, color)
	draw_circle(Vector2(x + text_width + 102.0, line_y), 3.0, color)
	draw_string(font, Vector2(x + 2.0, baseline_y + 2.0), text, HORIZONTAL_ALIGNMENT_LEFT, text_width, size, Color(0.0, 0.0, 0.04, 0.90))
	draw_string(font, Vector2(x, baseline_y), text, HORIZONTAL_ALIGNMENT_LEFT, text_width, size, color)


func _draw_milky_way_background() -> void:
	if milky_way_texture == null:
		return
	var source_size := milky_way_texture.get_size()
	var rotated_size := Vector2(source_size.y, source_size.x)
	var cover_scale := maxf(VIEW_SIZE.x / rotated_size.x, VIEW_SIZE.y / rotated_size.y)
	draw_set_transform(VIEW_SIZE * 0.5, PI * 0.5, Vector2.ONE * cover_scale)
	draw_texture(milky_way_texture, -source_size * 0.5, Color(0.66, 0.68, 0.78, 0.48))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_tractor_debug_field() -> void:
	if not OS.is_debug_build() or not tractor_beam_enabled or tractor_beam_strength <= 0.0:
		return
	if tractor_course_direction.length_squared() < 0.0001:
		return
	var canvas_transform := get_viewport().get_canvas_transform()
	var inverse_canvas := canvas_transform.affine_inverse()
	var ship_screen := canvas_transform * ship.global_position
	var course_screen := (canvas_transform * (ship.global_position + tractor_course_direction)) - ship_screen
	if course_screen.length_squared() < 0.0001:
		return
	course_screen = course_screen.normalized()
	var perpendicular := course_screen.orthogonal()
	var max_distance := _tractor_max_distance(get_viewport_rect().size)
	var left_edge := PackedVector2Array()
	var right_edge := PackedVector2Array()
	var steps := 30
	for index in range(steps + 1):
		var progress := float(index) / float(steps)
		var forward := max_distance * progress
		var half_width := _tractor_field_half_width(progress, max_distance)
		var center_screen := ship_screen + course_screen * forward
		left_edge.append(to_local(inverse_canvas * (center_screen - perpendicular * half_width)))
		right_edge.append(to_local(inverse_canvas * (center_screen + perpendicular * half_width)))
	var field_points := PackedVector2Array()
	field_points.append_array(left_edge)
	for index in range(right_edge.size() - 1, -1, -1):
		field_points.append(right_edge[index])
	var outline := field_points.duplicate()
	outline.append(field_points[0])
	var field_color: Color = palette[selected_color_index]
	draw_colored_polygon(field_points, Color(field_color, 0.055))
	draw_polyline(outline, Color(field_color.lightened(0.36), 0.50), 2.0, true)
	var tip_local := to_local(inverse_canvas * (ship_screen + course_screen * max_distance))
	draw_line(to_local(ship.global_position), tip_local, Color(field_color, 0.18), 1.0, true)


func _draw_tractor_beam() -> void:
	if not tractor_beam_enabled or tractor_beam_strength <= 0.0:
		return
	if not is_instance_valid(tractor_target) or tractor_target.captured or tractor_target.exploding:
		return
	var beam_start := to_local(ship.global_position)
	var beam_end := to_local(tractor_target.global_position)
	var beam_delta := beam_end - beam_start
	if beam_delta.length_squared() < 1.0:
		return
	var perpendicular := beam_delta.normalized().orthogonal()
	var beam_color: Color = palette[selected_color_index]
	var wave_size := lerpf(2.0, 6.5, tractor_beam_strength)
	var beam_points := PackedVector2Array()
	for index in range(25):
		var amount := float(index) / 24.0
		var wave := sin(input_hint_time * 9.0 - amount * 17.0) * wave_size * sin(PI * amount)
		beam_points.append(beam_start.lerp(beam_end, amount) + perpendicular * wave)
	draw_polyline(beam_points, Color(beam_color, 0.13 + tractor_beam_strength * 0.10), 10.0, true)
	draw_polyline(beam_points, Color(beam_color.lightened(0.38), 0.52 + tractor_beam_strength * 0.28), 2.2, true)
	for index in range(4):
		var amount := fposmod(input_hint_time * 0.92 + float(index) * 0.25, 1.0)
		var pulse_wave := sin(input_hint_time * 9.0 - amount * 17.0) * wave_size * sin(PI * amount)
		var pulse_position := beam_end.lerp(beam_start, amount) + perpendicular * pulse_wave
		draw_circle(pulse_position, 2.5 + tractor_beam_strength * 2.0, Color(beam_color.lightened(0.55), 0.88))
	var reticle_radius := tractor_target.capture_radius() + 6.0 + sin(input_hint_time * 7.0) * 2.0
	draw_arc(beam_end, reticle_radius, 0.0, TAU, 40, Color(beam_color.lightened(0.30), 0.72), 2.0, true)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, VIEW_SIZE), Color("050618"), true)
	_draw_milky_way_background()
	draw_circle(Vector2(225.0, 220.0), 230.0, Color(0.16, 0.08, 0.35, 0.13))
	draw_circle(Vector2(1050.0, 555.0), 280.0, Color(0.02, 0.36, 0.43, 0.09))
	for star in stars:
		var twinkle := 0.58 + sin(input_hint_time * 1.8 + star["phase"]) * 0.25
		draw_circle(star["position"], star["size"], Color(0.82, 0.90, 1.0, twinkle))
	if state == GameState.PLAYING:
		_draw_tractor_debug_field()
		_draw_tractor_beam()

	match state:
		GameState.MENU:
			_draw_menu()
		GameState.READY, GameState.COUNTDOWN, GameState.PLAYING, GameState.PAUSED:
			_draw_game_hud()
			if state == GameState.PLAYING:
				_draw_touch_stick()
		GameState.FINALE:
			_draw_game_hud()
		GameState.RESULTS:
			_draw_game_hud()
			_draw_results()


func _draw_menu() -> void:
	var accent: Color = palette[selected_color_index]
	var title_panel := Rect2(320.0, 12.0, 640.0, 142.0)
	var title_points := _chamfered_points(title_panel, 18.0)
	draw_colored_polygon(title_points, Color(0.015, 0.025, 0.09, 0.68))
	draw_polyline(_closed_outline(title_points), Color(accent, 0.34), 2.0, true)
	_draw_brand_title(78.0, 60, Color("f4f8ff"))
	_draw_space_subtitle(MENU_SUBTITLE, 115.0, 24, accent.lightened(0.18))
	_center_text(MENU_TAGLINE, 145.0, 18, Color("c1cbea"))
	_button(CLOSE_BUTTON, "CLOSE", Color("ff657a"))
	_section_label(SHIP_LABEL, "SHIP")
	_arrow_button(SHIP_LEFT_BUTTON, -1.0, palette[selected_color_index])
	_arrow_button(SHIP_RIGHT_BUTTON, 1.0, palette[selected_color_index])
	_selector(SHIP_NAME_BUTTON, ship_names[selected_ship_index])
	_section_label(COLOR_LABEL, "COLOR")
	_arrow_button(COLOR_LEFT_BUTTON, -1.0, palette[selected_color_index])
	_arrow_button(COLOR_RIGHT_BUTTON, 1.0, palette[selected_color_index])
	_selector(COLOR_NAME_BUTTON, color_names[selected_color_index])
	_section_label(PILOT_LABEL, "PILOT")
	_arrow_button(PILOT_LEFT_BUTTON, -1.0, palette[selected_color_index])
	_arrow_button(PILOT_RIGHT_BUTTON, 1.0, palette[selected_color_index])
	_selector(PILOT_NAME_BUTTON, pilot_names[selected_pilot_index])
	_button(START_BUTTON, "LAUNCH MISSION", palette[selected_color_index])
	var reset_label := "TAP AGAIN TO RESET" if Time.get_ticks_msec() <= best_reset_confirmation_until else "RESET BEST TIME"
	_button(RESET_BEST_BUTTON, reset_label, Color("ffc857"))
	var best_label := "BEST TIME  --:--.--" if best_time <= 0.0 else "BEST TIME  %s" % _format_time(best_time)
	_center_text(best_label, 618.0, 22, Color("e7edff"))
	_center_text("WASD / arrows • Gamepad stick / D-pad • Touch drag • Q/E pilot", 704.0, 15, Color("7f8bae"))


func _draw_game_hud() -> void:
	draw_rect(Rect2(0.0, 0.0, VIEW_SIZE.x, HUD_HEIGHT), Color(0.015, 0.02, 0.08, 0.94), true)
	draw_rect(Rect2(0.0, 0.0, VIEW_SIZE.x, 4.0), Color(palette[selected_color_index], 0.86), true)
	draw_line(Vector2(0.0, 82.0), Vector2(VIEW_SIZE.x, 82.0), Color(0.42, 0.49, 0.72, 0.32), 2.0)
	draw_string(font, Vector2(20.0, 51.0), BRAND_NAME, HORIZONTAL_ALIGNMENT_LEFT, 190.0, 23, Color(0.0, 0.0, 0.04, 0.90))
	draw_string(font, Vector2(18.0, 49.0), BRAND_NAME, HORIZONTAL_ALIGNMENT_LEFT, 190.0, 23, palette[selected_color_index].lightened(0.18))
	draw_arc(Vector2(123.0, 39.0), 15.0, -0.30, PI + 0.35, 22, Color(palette[selected_color_index], 0.55), 2.0, true)
	var shown_time := final_time if state in [GameState.FINALE, GameState.RESULTS] else elapsed_time
	draw_string(font, Vector2(210.0, 49.0), _format_time(shown_time), HORIZONTAL_ALIGNMENT_CENTER, 180.0, 27, Color.WHITE)
	draw_string(font, Vector2(410.0, 48.0), "%d / %d TARGETS" % [captured_count, total_targets], HORIZONTAL_ALIGNMENT_CENTER, 275.0, 19, Color("dbe5ff"))
	_button(BACK_BUTTON, "BACK", Color("8291b9"))
	_button(RESET_BUTTON, "RESET", Color("ffc857"))
	var can_pause := state in [GameState.COUNTDOWN, GameState.PLAYING, GameState.PAUSED]
	_button(PAUSE_BUTTON, "RESUME" if state == GameState.PAUSED else "PAUSE", palette[selected_color_index], can_pause)
	_button(CLOSE_BUTTON, "CLOSE", Color("ff657a"))
	var can_adjust := _can_adjust_tractor_beam()
	var beam_color: Color = palette[selected_color_index] if tractor_beam_enabled else Color("ff657a")
	_button(TRACTOR_BEAM_BUTTON, _tractor_button_label(), beam_color, can_adjust)
	draw_string(font, Vector2(302.0, 116.0), TRACTOR_POWER_LABEL, HORIZONTAL_ALIGNMENT_LEFT, 78.0, 18, Color(0.0, 0.0, 0.04, 0.92))
	draw_string(font, Vector2(300.0, 114.0), TRACTOR_POWER_LABEL, HORIZONTAL_ALIGNMENT_LEFT, 78.0, 18, palette[selected_color_index].lightened(0.38))
	var slider_alpha := 1.0 if can_adjust else 0.34
	draw_rect(TRACTOR_SLIDER_TRACK, Color(0.12, 0.15, 0.28, slider_alpha), true)
	draw_rect(Rect2(TRACTOR_SLIDER_TRACK.position, Vector2(TRACTOR_SLIDER_TRACK.size.x * tractor_beam_strength, TRACTOR_SLIDER_TRACK.size.y)), Color(palette[selected_color_index], slider_alpha), true)
	var knob_x := TRACTOR_SLIDER_TRACK.position.x + TRACTOR_SLIDER_TRACK.size.x * tractor_beam_strength
	draw_circle(Vector2(knob_x, TRACTOR_SLIDER_TRACK.get_center().y), 10.0, Color(Color.WHITE, slider_alpha))


func _draw_touch_stick() -> void:
	if touch_id == -1 and not mouse_steering:
		return
	var origin := touch_origin
	var knob := touch_position
	draw_circle(origin, 53.0, Color(0.75, 0.82, 1.0, 0.10))
	draw_arc(origin, 53.0, 0.0, TAU, 40, Color(0.75, 0.82, 1.0, 0.30), 2.0, true)
	draw_circle(knob, 23.0, Color(palette[selected_color_index], 0.34))


func _draw_results() -> void:
	draw_rect(Rect2(300.0, 148.0, 680.0, 490.0), Color(0.025, 0.03, 0.12, 0.96), true)
	draw_rect(Rect2(300.0, 148.0, 680.0, 490.0), palette[selected_color_index], false, 4.0)
	_center_text(RESULT_TITLE, 220.0, 43, palette[selected_color_index])
	_center_text(_result_pilot_message(), 270.0, RESULT_PILOT_FONT_SIZE, Color("d7e1ff"))
	_center_text(_format_time(final_time), 375.0, 68, Color.WHITE)
	_center_text("BEST TIME  " + _format_time(best_time), 435.0, 23, Color("ffd777"))
	_button(AGAIN_BUTTON, "RUN AGAIN", palette[selected_color_index])
	_button(MENU_BUTTON, "MENU", Color("8291b9"))


func _tractor_button_label() -> String:
	return "TRACTOR BEAM: ON" if tractor_beam_enabled else "TRACTOR BEAM: OFF"


func _result_pilot_message() -> String:
	return "%s painted every target" % pilot_names[selected_pilot_index]
