class_name ColorPlanet
extends SpaceTarget


const LABEL_FONT_SIZE := 20
const ASTEROID_CAPTURE_SCALE := 1.3
const BLACK_HOLE_CAPTURE_BLEND := 0.50
const TOUR_GUIDE_DURATION := 2.5
const TOUR_MARKER_COLOR := Color("ffd777")
const TOUR_MARKER_BRIGHT_COLOR := Color("fff3b0")

var body_style := "mercury"
var radius := 40.0
var base_color := Color("5f83f2")
var accent_color := Color("c7d4ef")
var capture_progress := 0.0
var seed := 1
var craters: Array[Dictionary] = []
var asteroid_points := PackedVector2Array()
var pulse_time := 0.0
var explosion_progress := 0.0
var tour_highlighted := false
var tour_guide_time_remaining := 0.0
var ringed := false
var ring_angle := 0.0
var ring_rx := 0.0
var ring_ry := 0.0
var ring_width := 0.0
var font: Font


func configure(new_name: String, new_radius: float, new_style: String, new_seed: int) -> void:
	body_name = new_name
	radius = new_radius
	body_style = new_style
	seed = new_seed
	match body_style:
		"sun":
			base_color = Color("ffb21c")
			accent_color = Color("fff2a1")
		"black_hole":
			base_color = Color("030509")
			accent_color = Color("fffdf5")
		"mercury":
			base_color = Color("8e8b86")
			accent_color = Color("c8c1b8")
		"venus":
			base_color = Color("d9a441")
			accent_color = Color("ffe2a0")
		"earth":
			base_color = Color("2878d0")
			accent_color = Color("58b96a")
		"mars":
			base_color = Color("c55332")
			accent_color = Color("6f3328")
		"jupiter":
			base_color = Color("d5aa78")
			accent_color = Color("8f5f43")
		"saturn":
			base_color = Color("d9c27a")
			accent_color = Color("927748")
			ringed = true
			ring_angle = -0.23
			ring_rx = radius * 1.75
			ring_ry = radius * 0.46
			ring_width = maxf(7.0, radius * 0.16)
		"uranus":
			base_color = Color("80d8df")
			accent_color = Color("c7fbff")
			ringed = true
			ring_angle = 1.19
			ring_rx = radius * 1.38
			ring_ry = radius * 0.24
			ring_width = maxf(3.0, radius * 0.075)
		"neptune":
			base_color = Color("3159c8")
			accent_color = Color("8fb7ff")
		"moon":
			base_color = Color("b7b7ae")
			accent_color = Color("e3e1d8")
		"pluto":
			base_color = Color("a8896d")
			accent_color = Color("ead9c2")
		"haumea":
			base_color = Color("b86446")
			accent_color = Color("e4a47c")
		"asteroid_a", "asteroid_b":
			base_color = Color("756a67") if body_style == "asteroid_a" else Color("625b68")
			accent_color = Color("b1a29a")


func _ready() -> void:
	font = ThemeDB.fallback_font
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var crater_count := 0
	match body_style:
		"mercury": crater_count = 6
		"moon": crater_count = 5
		"mars": crater_count = 2
		"pluto": crater_count = 2
		"haumea": crater_count = 2
		"asteroid_a", "asteroid_b": crater_count = 3
	for index in range(crater_count):
		var angle := rng.randf_range(0.0, TAU)
		var distance := rng.randf_range(radius * 0.12, radius * 0.55)
		craters.append({
			"position": Vector2.from_angle(angle) * distance,
			"radius": rng.randf_range(maxf(1.2, radius * 0.08), maxf(2.0, radius * 0.18)),
		})
	if body_style.begins_with("asteroid"):
		for index in range(11):
			var angle := TAU * float(index) / 11.0
			asteroid_points.append(Vector2.from_angle(angle) * radius * rng.randf_range(0.72, 1.08))
	queue_redraw()


func _process(delta: float) -> void:
	pulse_time += delta
	if tour_highlighted and tour_guide_time_remaining > 0.0:
		tour_guide_time_remaining = maxf(0.0, tour_guide_time_remaining - delta)
	if captured or exploding or tour_highlighted or body_style == "black_hole":
		queue_redraw()


func set_tour_highlighted(value: bool, start_guide := true) -> void:
	if tour_highlighted == value:
		if value and start_guide and tour_guide_time_remaining <= 0.0:
			start_tour_guide()
		return
	tour_highlighted = value
	tour_guide_time_remaining = TOUR_GUIDE_DURATION if value and start_guide else 0.0
	queue_redraw()


func start_tour_guide() -> void:
	if not tour_highlighted:
		return
	# Each new target gets one short guidance window; the stronger ring persists afterward.
	tour_guide_time_remaining = TOUR_GUIDE_DURATION
	queue_redraw()


func is_tour_guide_visible() -> bool:
	return tour_highlighted and tour_guide_time_remaining > 0.0


func _draw_tour_guide_arrows(marker_radius: float) -> void:
	# Four cardinal arrows animate inward so the target remains clear from any approach.
	var approach := sin(pulse_time * 7.0) * 4.0
	for arrow_index in range(4):
		var angle := float(arrow_index) * PI * 0.5
		var direction := Vector2.from_angle(angle)
		var tangent := direction.orthogonal()
		var tip := direction * (marker_radius + 7.0)
		var base_center := direction * (marker_radius + 28.0 + approach)
		var arrow_points := PackedVector2Array([
			tip,
			base_center + tangent * 9.0,
			base_center - tangent * 9.0,
		])
		draw_colored_polygon(arrow_points, TOUR_MARKER_BRIGHT_COLOR)
		draw_line(
			base_center,
			direction * (marker_radius + 42.0 + approach),
			TOUR_MARKER_COLOR,
			5.0,
			true
		)


func capture(color: Color) -> bool:
	if captured or exploding:
		return false
	captured = true
	captured_color = color
	var color_tween := create_tween()
	color_tween.tween_method(_set_capture_progress, 0.0, 1.0, 0.38).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var scale_tween := create_tween()
	scale_tween.tween_property(self, "scale", Vector2(1.18, 1.18), 0.12).set_trans(Tween.TRANS_QUAD)
	scale_tween.tween_property(self, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return true


func explode() -> void:
	if exploding:
		return
	exploding = true
	var tween := create_tween()
	tween.tween_method(_set_explosion_progress, 0.0, 1.0, 0.72).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_callback(queue_free)


func _set_capture_progress(value: float) -> void:
	capture_progress = value
	queue_redraw()


func _set_explosion_progress(value: float) -> void:
	explosion_progress = value
	queue_redraw()


func _ellipse_points(rx: float, ry: float, from_angle: float, to_angle: float, steps: int, rotation_angle := 0.0, offset := Vector2.ZERO) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in range(steps + 1):
		var amount := float(index) / float(steps)
		var angle := lerpf(from_angle, to_angle, amount)
		points.append(Vector2(cos(angle) * rx, sin(angle) * ry).rotated(rotation_angle) + offset)
	return points


func _surface_color(original: Color, darkness := 0.28) -> Color:
	return original.lerp(captured_color.darkened(darkness), capture_progress)


func _draw() -> void:
	if exploding:
		_draw_explosion()
		return

	var color := base_color.lerp(captured_color, capture_progress)
	if tour_highlighted:
		var marker_radius := visual_extent() + 14.0 + sin(pulse_time * 5.0) * 2.5
		draw_arc(Vector2.ZERO, marker_radius + 5.0, 0.0, TAU, 64, Color(1.0, 0.72, 0.18, 0.28), 9.0, true)
		draw_arc(Vector2.ZERO, marker_radius, 0.0, TAU, 64, TOUR_MARKER_COLOR, 5.0, true)
		for marker_index in range(8):
			var marker_angle := pulse_time * 0.7 + float(marker_index) * PI * 0.25
			draw_circle(Vector2.from_angle(marker_angle) * marker_radius, 4.0, TOUR_MARKER_BRIGHT_COLOR)
		if is_tour_guide_visible():
			_draw_tour_guide_arrows(marker_radius)
	if captured:
		var glow_alpha := 0.12 + sin(pulse_time * 4.0) * 0.035
		draw_circle(Vector2.ZERO, radius + 10.0, Color(captured_color, glow_alpha))

	if ringed:
		_draw_ring(color, false)

	if body_style == "black_hole":
		_draw_black_hole()
	elif body_style == "sun":
		_draw_sun(color)
	elif body_style.begins_with("asteroid"):
		_draw_asteroid(color)
	elif body_style == "haumea":
		_draw_haumea(color)
	else:
		_draw_round_world(color)

	if ringed:
		_draw_ring(color, true)
	_draw_label()


func _draw_round_world(color: Color) -> void:
	draw_circle(Vector2(4.0, 7.0), radius + 2.0, Color(0.0, 0.0, 0.12, 0.78))
	draw_circle(Vector2.ZERO, radius, color.darkened(0.12))
	draw_circle(Vector2(-radius * 0.07, -radius * 0.08), radius * 0.94, color)

	match body_style:
		"mercury", "moon":
			_draw_craters(color)
		"venus":
			_draw_band(-radius * 0.40, radius * 0.13, _surface_color(accent_color, 0.05))
			_draw_band(-radius * 0.08, radius * 0.16, _surface_color(Color("f0c46d"), 0.12))
			_draw_band(radius * 0.28, radius * 0.12, _surface_color(accent_color, 0.08))
		"earth":
			_draw_earth_features()
		"pluto":
			_draw_pluto_features()
		"mars":
			_draw_mars_features(color)
		"jupiter":
			_draw_jupiter_features()
		"saturn":
			_draw_band(-radius * 0.30, radius * 0.08, _surface_color(Color("f2dda0"), 0.07))
			_draw_band(radius * 0.02, radius * 0.10, _surface_color(accent_color, 0.16))
			_draw_band(radius * 0.32, radius * 0.07, _surface_color(Color("b69a61"), 0.20))
		"uranus":
			_draw_band(radius * 0.10, radius * 0.055, _surface_color(Color("d5ffff"), 0.04))
		"neptune":
			_draw_neptune_features()

	draw_circle(Vector2(-radius * 0.29, -radius * 0.34), radius * 0.28, Color(1.0, 1.0, 1.0, 0.12))


func _draw_sun(color: Color) -> void:
	var glow_color := color.lightened(0.24)
	draw_circle(Vector2.ZERO, radius + 19.0, Color(glow_color, 0.07))
	draw_circle(Vector2.ZERO, radius + 11.0, Color(glow_color, 0.15))
	for index in range(16):
		var angle := TAU * float(index) / 16.0 + pulse_time * 0.08
		var ray_start := Vector2.from_angle(angle) * (radius + 5.0)
		var ray_length := radius + 14.0 + sin(pulse_time * 2.4 + float(index)) * 3.0
		draw_line(ray_start, Vector2.from_angle(angle) * ray_length, Color(glow_color, 0.76), 3.0, true)
	draw_circle(Vector2(4.0, 7.0), radius + 2.0, Color(0.20, 0.05, 0.0, 0.72))
	draw_circle(Vector2.ZERO, radius, color.darkened(0.10))
	draw_circle(Vector2(-radius * 0.06, -radius * 0.07), radius * 0.94, color)
	for index in range(7):
		var spot_angle := TAU * float(index) / 7.0 + float(seed % 13) * 0.09
		var spot_position := Vector2.from_angle(spot_angle) * radius * (0.22 + float(index % 3) * 0.13)
		draw_circle(spot_position, radius * (0.055 + float(index % 2) * 0.025), _surface_color(accent_color, 0.18))
	draw_circle(Vector2(-radius * 0.28, -radius * 0.33), radius * 0.25, Color(1.0, 1.0, 1.0, 0.16))


func _draw_black_hole() -> void:
	var shimmer := 0.94 + sin(pulse_time * 1.7) * 0.06
	var halo_color := Color("f4f8ff").lerp(captured_color.lightened(0.32), capture_progress * 0.82)
	var disk_color := Color("e5a68d").lerp(captured_color.lightened(0.28), capture_progress)
	var disk_shadow := Color("7a4039").lerp(captured_color.darkened(0.30), capture_progress)
	var horizon_color := black_hole_horizon_color()

	# Broad, dim lensing rings establish the silhouette before the bright photon halo.
	var outer_halo := _ellipse_points(radius * 1.28, radius * 1.48, 0.0, TAU, 72)
	draw_polyline(outer_halo, Color(halo_color, 0.12 * shimmer), 8.0, true)
	var middle_halo := _ellipse_points(radius * 1.12, radius * 1.30, 0.0, TAU, 72)
	draw_polyline(middle_halo, Color(halo_color, 0.24 * shimmer), 5.0, true)

	# The far side of the accretion disk sits behind the event horizon.
	for band in [
		[radius * 2.12, radius * 0.34, 9.0, Color(disk_shadow, 0.58)],
		[radius * 1.96, radius * 0.25, 6.0, Color(disk_color, 0.82)],
		[radius * 1.78, radius * 0.18, 3.0, Color(halo_color, 0.90)],
	]:
		var disk := _ellipse_points(float(band[0]), float(band[1]), PI, TAU, 56, -0.025)
		draw_polyline(disk, band[3], float(band[2]), true)

	# Capture shifts the event horizon halfway from black toward the ship color.
	draw_circle(Vector2(2.0, 4.0), radius * 1.04, Color(horizon_color.darkened(0.48), 0.82))
	draw_circle(Vector2.ZERO, radius, horizon_color)
	var photon_ring := _ellipse_points(radius * 1.02, radius * 1.08, PI, TAU, 44)
	draw_polyline(photon_ring, Color(halo_color, 0.98 * shimmer), 4.5, true)
	var lower_lensing := _ellipse_points(radius * 0.92, radius * 1.04, 0.0, PI, 36)
	draw_polyline(lower_lensing, Color(halo_color, 0.48 * shimmer), 2.5, true)

	# The near side crosses in front, producing the bright horizontal streak in the reference.
	var front_glow := _ellipse_points(radius * 2.15, radius * 0.31, 0.0, PI, 56, -0.025)
	draw_polyline(front_glow, Color(disk_shadow, 0.74), 10.0, true)
	var front_disk := _ellipse_points(radius * 2.02, radius * 0.23, 0.0, PI, 56, -0.025)
	draw_polyline(front_disk, Color(disk_color, 0.94), 6.0, true)
	var white_edge := _ellipse_points(radius * 1.88, radius * 0.16, 0.0, PI, 48, -0.025)
	draw_polyline(white_edge, Color(halo_color, 0.96 * shimmer), 2.5, true)


func _draw_band(y: float, thickness: float, color: Color) -> void:
	var half_width := sqrt(maxf(0.0, radius * radius - y * y)) * 0.92
	draw_line(Vector2(-half_width, y), Vector2(half_width, y), color, maxf(1.0, thickness), true)


func _draw_craters(color: Color) -> void:
	for crater in craters:
		var crater_position: Vector2 = crater["position"]
		var crater_radius: float = crater["radius"]
		draw_circle(crater_position, crater_radius, Color(color.darkened(0.34), 0.78))
		draw_circle(crater_position + Vector2(-crater_radius * 0.22, -crater_radius * 0.22), crater_radius * 0.62, Color(color.lightened(0.20), 0.38))


func black_hole_horizon_color() -> Color:
	var captured_horizon := Color.BLACK.lerp(captured_color, BLACK_HOLE_CAPTURE_BLEND)
	return base_color.lerp(captured_horizon, capture_progress)


func earth_landmasses() -> Array[Dictionary]:
	return [
		{"id": "north_america", "shade": "land", "points": PackedVector2Array([
			Vector2(-radius * 0.74, -radius * 0.36), Vector2(-radius * 0.53, -radius * 0.60),
			Vector2(-radius * 0.24, -radius * 0.56), Vector2(-radius * 0.12, -radius * 0.40),
			Vector2(-radius * 0.28, -radius * 0.28), Vector2(-radius * 0.25, -radius * 0.12),
			Vector2(-radius * 0.43, -radius * 0.07), Vector2(-radius * 0.56, -radius * 0.19),
			Vector2(-radius * 0.70, -radius * 0.18),
		])},
		{"id": "south_america", "shade": "dark", "points": PackedVector2Array([
			Vector2(-radius * 0.43, -radius * 0.08), Vector2(-radius * 0.17, -radius * 0.01),
			Vector2(-radius * 0.07, radius * 0.17), Vector2(-radius * 0.18, radius * 0.38),
			Vector2(-radius * 0.24, radius * 0.66), Vector2(-radius * 0.36, radius * 0.74),
			Vector2(-radius * 0.42, radius * 0.45), Vector2(-radius * 0.53, radius * 0.22),
		])},
		{"id": "africa_europe", "shade": "land", "points": PackedVector2Array([
			Vector2(-radius * 0.12, -radius * 0.35), Vector2(radius * 0.10, -radius * 0.48),
			Vector2(radius * 0.27, -radius * 0.34), Vector2(radius * 0.20, -radius * 0.20),
			Vector2(radius * 0.28, -radius * 0.02), Vector2(radius * 0.17, radius * 0.22),
			Vector2(radius * 0.05, radius * 0.55), Vector2(-radius * 0.10, radius * 0.36),
			Vector2(-radius * 0.14, radius * 0.07), Vector2(-radius * 0.23, -radius * 0.13),
		])},
		{"id": "asia", "shade": "dark", "points": PackedVector2Array([
			Vector2(radius * 0.12, -radius * 0.47), Vector2(radius * 0.46, -radius * 0.56),
			Vector2(radius * 0.76, -radius * 0.34), Vector2(radius * 0.66, -radius * 0.14),
			Vector2(radius * 0.48, -radius * 0.12), Vector2(radius * 0.39, radius * 0.04),
			Vector2(radius * 0.23, -radius * 0.04), Vector2(radius * 0.10, -radius * 0.24),
		])},
		{"id": "australia", "shade": "land", "points": PackedVector2Array([
			Vector2(radius * 0.42, radius * 0.32), Vector2(radius * 0.69, radius * 0.27),
			Vector2(radius * 0.76, radius * 0.47), Vector2(radius * 0.57, radius * 0.61),
			Vector2(radius * 0.38, radius * 0.49),
		])},
		{"id": "greenland", "shade": "ice", "points": PackedVector2Array([
			Vector2(-radius * 0.29, -radius * 0.69), Vector2(-radius * 0.12, -radius * 0.78),
			Vector2(-radius * 0.03, -radius * 0.61), Vector2(-radius * 0.20, -radius * 0.55),
		])},
	]


func _draw_earth_features() -> void:
	var land := _surface_color(Color("58b96a"), 0.22)
	var dark_land := _surface_color(Color("3d9651"), 0.28)
	# Recognizable silhouettes rather than generic green patches: North and South
	# America on the left, Africa/Europe and Asia across the middle, Australia below.
	for landmass in earth_landmasses():
		var color := land
		if landmass["shade"] == "dark":
			color = dark_land
		elif landmass["shade"] == "ice":
			color = _surface_color(Color("d9f3ed"), 0.06)
		draw_colored_polygon(landmass["points"], color)
	var cloud := Color(1.0, 1.0, 1.0, 0.58)
	draw_polyline(PackedVector2Array([
		Vector2(-radius * 0.72, radius * 0.05), Vector2(-radius * 0.35, radius * 0.15),
		Vector2(radius * 0.02, radius * 0.10),
	]), cloud, maxf(1.0, radius * 0.045), true)
	draw_polyline(PackedVector2Array([
		Vector2(radius * 0.08, -radius * 0.60), Vector2(radius * 0.38, -radius * 0.50),
		Vector2(radius * 0.64, -radius * 0.34),
	]), Color(cloud, 0.45), maxf(1.0, radius * 0.04), true)


func _draw_pluto_features() -> void:
	var dark_plain := _surface_color(Color("765b4c"), 0.30)
	var tombaugh_regio := _surface_color(accent_color, 0.08)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-radius * 0.72, -radius * 0.18), Vector2(-radius * 0.34, -radius * 0.48),
		Vector2(radius * 0.02, -radius * 0.30), Vector2(-radius * 0.05, radius * 0.12),
		Vector2(-radius * 0.48, radius * 0.22),
	]), dark_plain)
	# Pluto's bright heart-shaped Tombaugh Regio keeps the dwarf planet
	# recognizable even at the game's deliberately compressed scale.
	draw_circle(Vector2(radius * 0.04, -radius * 0.14), radius * 0.30, tombaugh_regio)
	draw_circle(Vector2(radius * 0.34, -radius * 0.12), radius * 0.31, tombaugh_regio)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-radius * 0.21, -radius * 0.08), Vector2(radius * 0.61, -radius * 0.04),
		Vector2(radius * 0.19, radius * 0.55),
	]), tombaugh_regio)
	draw_circle(Vector2(-radius * 0.32, radius * 0.36), radius * 0.12, dark_plain.lightened(0.10))


func _draw_mars_features(color: Color) -> void:
	draw_colored_polygon(PackedVector2Array([
		Vector2(-radius * 0.55, -radius * 0.10), Vector2(-radius * 0.12, -radius * 0.42),
		Vector2(radius * 0.34, -radius * 0.12), Vector2(radius * 0.22, radius * 0.26),
		Vector2(-radius * 0.30, radius * 0.20),
	]), _surface_color(accent_color, 0.38))
	draw_circle(Vector2(0.0, -radius * 0.77), radius * 0.17, _surface_color(Color("f4dccb"), 0.08))
	_draw_craters(color)


func _draw_jupiter_features() -> void:
	var bands := [
		[-0.58, 0.12, Color("8e6047")], [-0.35, 0.09, Color("f0d7b4")],
		[-0.10, 0.16, Color("ad7555")], [0.18, 0.10, Color("f2d7ac")],
		[0.43, 0.13, Color("9b664c")],
	]
	for band in bands:
		_draw_band(radius * float(band[0]), radius * float(band[1]), _surface_color(band[2], 0.22))
	var spot := _ellipse_points(radius * 0.22, radius * 0.11, 0.0, TAU, 24, 0.0, Vector2(radius * 0.31, radius * 0.20))
	draw_colored_polygon(spot, _surface_color(Color("b94837"), 0.30))


func _draw_neptune_features() -> void:
	_draw_band(-radius * 0.24, radius * 0.08, _surface_color(accent_color, 0.10))
	_draw_band(radius * 0.33, radius * 0.06, _surface_color(Color("6e8de0"), 0.16))
	var spot := _ellipse_points(radius * 0.19, radius * 0.11, 0.0, TAU, 20, -0.18, Vector2(radius * 0.28, radius * 0.02))
	draw_colored_polygon(spot, _surface_color(Color("172b76"), 0.38))


func _draw_ring(color: Color, front: bool) -> void:
	var ring_color := accent_color.lerp(captured_color.lightened(0.34), capture_progress)
	var from_angle := 0.0
	var to_angle := PI if front else TAU
	var ring_points := _ellipse_points(ring_rx, ring_ry, from_angle, to_angle, 64 if not front else 32, ring_angle)
	draw_polyline(ring_points, Color(ring_color, 0.90), ring_width, true)
	draw_polyline(ring_points, Color(color.darkened(0.42), 0.82), maxf(1.2, ring_width * 0.20), true)


func _draw_haumea(color: Color) -> void:
	var shadow := _ellipse_points(radius * 1.30, radius * 0.86, 0.0, TAU, 36, -0.13, Vector2(3.0, 5.0))
	draw_colored_polygon(shadow, Color(0.0, 0.0, 0.12, 0.78))
	var body := _ellipse_points(radius * 1.28, radius * 0.84, 0.0, TAU, 36, -0.13)
	draw_colored_polygon(body, color)
	var patch := _ellipse_points(radius * 0.50, radius * 0.24, 0.0, TAU, 24, -0.20, Vector2(-radius * 0.28, -radius * 0.12))
	draw_colored_polygon(patch, _surface_color(accent_color, 0.18))
	_draw_craters(color)


func _draw_asteroid(color: Color) -> void:
	var shadow := PackedVector2Array()
	for point in asteroid_points:
		shadow.append(point + Vector2(3.0, 5.0))
	draw_colored_polygon(shadow, Color(0.0, 0.0, 0.12, 0.78))
	draw_colored_polygon(asteroid_points, color)
	_draw_craters(color)


func _draw_label() -> void:
	var half_height := radius
	if body_style == "sun":
		half_height = radius + 20.0
	elif body_style == "black_hole":
		half_height = radius * 1.50
	if ringed:
		half_height = maxf(half_height, absf(ring_rx * sin(ring_angle)) + absf(ring_ry * cos(ring_angle)))
	var label_y := half_height + 23.0
	var label_color := Color("eef3ff") if not captured else captured_color.lightened(0.38)
	draw_string(font, Vector2(-95.0, label_y), body_name, HORIZONTAL_ALIGNMENT_CENTER, 190.0, LABEL_FONT_SIZE, Color(0.0, 0.0, 0.0, 0.92))
	draw_string(font, Vector2(-95.0, label_y - 1.5), body_name, HORIZONTAL_ALIGNMENT_CENTER, 190.0, LABEL_FONT_SIZE, label_color)


func capture_radius() -> float:
	return radius * ASTEROID_CAPTURE_SCALE if body_style.begins_with("asteroid") else radius


func visual_extent() -> float:
	if body_style == "black_hole":
		return radius * 2.15
	if ringed:
		return ring_rx
	if body_style == "haumea":
		return radius * 1.3
	return radius


func _draw_explosion() -> void:
	var amount := explosion_progress
	var fire_color := captured_color if captured else base_color
	var fade := 1.0 - amount
	draw_circle(Vector2.ZERO, radius * (0.35 + amount * 1.65), Color("fff2a8") * Color(1.0, 1.0, 1.0, fade))
	draw_circle(Vector2.ZERO, radius * (0.22 + amount * 1.18), Color(fire_color, fade))
	for index in range(14):
		var angle := TAU * float(index) / 14.0 + float(seed % 9) * 0.11
		var direction := Vector2.from_angle(angle)
		var fragment_position := direction * radius * amount * (1.6 + float(index % 3) * 0.22)
		var fragment_size := maxf(1.0, radius * 0.12 * fade)
		draw_circle(fragment_position, fragment_size, Color(fire_color.lightened(0.25), fade))
