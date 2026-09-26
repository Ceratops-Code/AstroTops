class_name PlayerShip
extends Node2D


const TRIXIE_REGION := Rect2(529.0, 100.0, 654.0, 611.0)
const SHIP_TEXTURES := [
	preload("res://assets/ship_arrow.png"),
	preload("res://assets/ship_dart.png"),
	preload("res://assets/ship_nova.png"),
	preload("res://assets/ship_saucer.png"),
]
const SHIP_STYLE_COUNT := 8
const COCKPIT_COLOR := Color("010205")
const TRIXIE_PILOT_SCALE := 2.04
const ASTRONAUT_OUTER_SCALE := 0.90
const PLANET_PILOT_SCALE := 0.74
const PLANET_PILOT_RING_ROTATION := -0.28
const PLANET_PILOT_RING_X_SCALE := 1.42
const PLANET_PILOT_RING_Y_SCALE := 0.42
const COCKPIT_RADII := [13.0, 13.0, 13.0, 15.0, 13.0, 13.0, 13.0, 12.0]
const COCKPIT_OFFSETS := [
	Vector2(-1.0, 8.0), Vector2(1.0, 7.0), Vector2(0.0, 6.0), Vector2(-1.0, 1.0),
	Vector2(0.0, 10.0), Vector2(1.0, 9.0), Vector2(-1.0, 5.0), Vector2(1.0, 4.0),
]
const PROCEDURAL_SIZES := [
	Vector2(68.0, 78.0), Vector2(82.0, 76.0), Vector2(92.0, 72.0), Vector2(64.0, 82.0),
]

var ship_color := Color("41f4c6")
var ship_style := 0
var pilot_style := 0
var velocity := Vector2.ZERO
var max_speed := 330.0
var acceleration := 980.0
var braking := 760.0
var hit_radius := 29.0
var movement_bounds := Rect2(32.0, 92.0, 1216.0, 594.0)
var thrust_amount := 0.0
var trixie_texture: Texture2D = preload("res://assets/trixie.png")


func configure(color: Color, bounds: Rect2, style_index := 0, pilot_index := 0) -> void:
	ship_color = color
	movement_bounds = bounds
	ship_style = clampi(style_index, 0, SHIP_STYLE_COUNT - 1)
	pilot_style = clampi(pilot_index, 0, 2)
	queue_redraw()


func move_ship(input_vector: Vector2, delta: float) -> void:
	var desired_velocity := input_vector.limit_length(1.0) * max_speed
	var rate := acceleration if input_vector.length_squared() > 0.01 else braking
	velocity = velocity.move_toward(desired_velocity, rate * delta)
	position += velocity * delta
	position.x = clampf(position.x, movement_bounds.position.x, movement_bounds.end.x)
	position.y = clampf(position.y, movement_bounds.position.y, movement_bounds.end.y)
	if input_vector.length_squared() > 0.04:
		var desired_rotation := input_vector.angle() + PI * 0.5
		rotation = lerp_angle(rotation, desired_rotation, minf(1.0, delta * 11.0))
	thrust_amount = move_toward(thrust_amount, input_vector.length(), delta * 5.0)
	queue_redraw()


func stop() -> void:
	velocity = Vector2.ZERO
	thrust_amount = 0.0
	queue_redraw()


func _draw() -> void:
	var target_size := _ship_target_size()
	_draw_thruster_flames(target_size)

	if ship_style < SHIP_TEXTURES.size():
		var texture: Texture2D = SHIP_TEXTURES[ship_style]
		var target_rect := Rect2(-target_size * 0.5, target_size)
		# Paint remains readable without flattening the detail in Kenney's sprite art.
		draw_texture_rect(texture, Rect2(target_rect.position + Vector2(4.0, 6.0), target_rect.size), false, Color(0.0, 0.0, 0.05, 0.62))
		draw_texture_rect(texture, target_rect, false, Color.WHITE)
	else:
		_draw_procedural_ship()

	var cockpit: Vector2 = COCKPIT_OFFSETS[ship_style]
	var cockpit_radius: float = COCKPIT_RADII[ship_style]
	draw_circle(cockpit, cockpit_radius + 4.0, COCKPIT_COLOR)
	_draw_pilot(cockpit, cockpit_radius)


func _draw_pilot(cockpit: Vector2, cockpit_radius: float) -> void:
	match pilot_style:
		0:
			var pilot_size := Vector2.ONE * cockpit_radius * TRIXIE_PILOT_SCALE
			draw_texture_rect_region(
				trixie_texture,
				Rect2(cockpit - pilot_size * 0.5 + Vector2(0.0, 0.5), pilot_size),
				TRIXIE_REGION,
				Color.WHITE
			)
		1:
			_draw_astronaut_pilot(cockpit, cockpit_radius)
		2:
			_draw_planet_pilot(cockpit, cockpit_radius)


func _draw_astronaut_pilot(cockpit: Vector2, cockpit_radius: float) -> void:
	draw_circle(cockpit + Vector2(0.0, 1.0), cockpit_radius * ASTRONAUT_OUTER_SCALE, Color("f1f4fa"))
	draw_circle(cockpit + Vector2(0.0, 1.0), cockpit_radius * 0.70, Color("263b67"))
	draw_circle(cockpit + Vector2(0.0, 2.0), cockpit_radius * 0.52, Color("d99a70"))
	draw_circle(cockpit + Vector2(-3.0, 1.0), 1.2, Color("17192b"))
	draw_circle(cockpit + Vector2(3.0, 1.0), 1.2, Color("17192b"))
	draw_arc(cockpit + Vector2(0.0, 1.0), cockpit_radius * 0.77, PI + 0.22, TAU - 0.22, 18, Color(1.0, 1.0, 1.0, 0.82), 1.5, true)


func _draw_planet_pilot(cockpit: Vector2, cockpit_radius: float) -> void:
	var planet_radius := cockpit_radius * PLANET_PILOT_SCALE
	# The far arc is painted first and becomes occluded by the planet body.
	draw_polyline(_planet_pilot_ring_arc(cockpit, planet_radius, PI, TAU), Color("b99a50"), 2.2, true)
	draw_circle(cockpit, planet_radius, Color("7258d8"))
	draw_colored_polygon(PackedVector2Array([
		cockpit + Vector2(-planet_radius * 0.70, -planet_radius * 0.18),
		cockpit + Vector2(-planet_radius * 0.18, -planet_radius * 0.58),
		cockpit + Vector2(planet_radius * 0.12, -planet_radius * 0.10),
		cockpit + Vector2(-planet_radius * 0.20, planet_radius * 0.20),
	]), Color("75e0a0"))
	draw_circle(cockpit + Vector2(-2.6, 0.8), 1.15, Color("11152b"))
	draw_circle(cockpit + Vector2(2.6, 0.8), 1.15, Color("11152b"))
	# The near arc is painted last, crossing the lower face as a foreground ring.
	draw_polyline(_planet_pilot_ring_arc(cockpit, planet_radius, 0.0, PI), Color("ffe18a"), 2.4, true)


func _planet_pilot_ring_arc(cockpit: Vector2, planet_radius: float, from_angle: float, to_angle: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in range(17):
		var angle := lerpf(from_angle, to_angle, float(index) / 16.0)
		points.append(_planet_pilot_ring_point(cockpit, planet_radius, angle))
	return points


func _planet_pilot_ring_point(cockpit: Vector2, planet_radius: float, angle: float) -> Vector2:
	return cockpit + Vector2(
		cos(angle) * planet_radius * PLANET_PILOT_RING_X_SCALE,
		sin(angle) * planet_radius * PLANET_PILOT_RING_Y_SCALE
	).rotated(PLANET_PILOT_RING_ROTATION)


func _ship_target_size() -> Vector2:
	if ship_style >= SHIP_TEXTURES.size():
		return PROCEDURAL_SIZES[ship_style - SHIP_TEXTURES.size()]
	var texture: Texture2D = SHIP_TEXTURES[ship_style]
	var source_size := texture.get_size()
	var target_height := 78.0 if ship_style == 3 else 76.0
	return source_size * (target_height / source_size.y)


func _draw_thruster_flames(target_size: Vector2) -> void:
	if thrust_amount <= 0.08:
		return
	var flame_wave := 4.0 + sin(Time.get_ticks_msec() * 0.022) * 3.0
	var flame_length := 18.0 + flame_wave * thrust_amount
	var flame_y := target_size.y * 0.40
	if ship_style == 5:
		_draw_flame(Vector2(-22.0, flame_y), 6.0, flame_length * 0.88)
		_draw_flame(Vector2(22.0, flame_y), 6.0, flame_length * 0.88)
	elif ship_style == 6:
		_draw_flame(Vector2(-15.0, flame_y), 7.0, flame_length * 0.82)
		_draw_flame(Vector2(15.0, flame_y), 7.0, flame_length * 0.82)
	else:
		_draw_flame(Vector2(0.0, flame_y), 8.0 if ship_style in [3, 7] else 11.0, flame_length)


func _draw_flame(origin: Vector2, width: float, length: float) -> void:
	draw_colored_polygon(PackedVector2Array([
		origin + Vector2(-width, 0.0), origin + Vector2(0.0, length), origin + Vector2(width, 0.0),
	]), Color("ff873b"))
	draw_colored_polygon(PackedVector2Array([
		origin + Vector2(-width * 0.45, -1.0),
		origin + Vector2(0.0, length * 0.62),
		origin + Vector2(width * 0.45, -1.0),
	]), Color("fff4a4"))


func _draw_procedural_ship() -> void:
	match ship_style:
		4: _draw_comet_spear()
		5: _draw_twin_comet()
		6: _draw_star_skimmer()
		7: _draw_rocket_pod()


func _draw_comet_spear() -> void:
	var hull := PackedVector2Array([
		Vector2(0.0, -40.0), Vector2(-13.0, -13.0), Vector2(-25.0, 28.0),
		Vector2(-7.0, 21.0), Vector2(0.0, 38.0), Vector2(7.0, 21.0),
		Vector2(25.0, 28.0), Vector2(13.0, -13.0),
	])
	_draw_ship_polygon(hull, ship_color)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-10.0, -9.0), Vector2(-30.0, 23.0), Vector2(-9.0, 14.0),
	]), ship_color.darkened(0.28))
	draw_colored_polygon(PackedVector2Array([
		Vector2(10.0, -9.0), Vector2(30.0, 23.0), Vector2(9.0, 14.0),
	]), ship_color.darkened(0.18))
	draw_line(Vector2(0.0, -34.0), Vector2(0.0, 31.0), ship_color.lightened(0.42), 3.0, true)


func _draw_twin_comet() -> void:
	var left_pod := PackedVector2Array([
		Vector2(-22.0, -34.0), Vector2(-33.0, -12.0), Vector2(-30.0, 31.0),
		Vector2(-17.0, 38.0), Vector2(-12.0, -7.0),
	])
	var right_pod := PackedVector2Array([
		Vector2(22.0, -34.0), Vector2(33.0, -12.0), Vector2(30.0, 31.0),
		Vector2(17.0, 38.0), Vector2(12.0, -7.0),
	])
	_draw_ship_polygon(left_pod, ship_color.darkened(0.12))
	_draw_ship_polygon(right_pod, ship_color)
	_draw_ship_polygon(PackedVector2Array([
		Vector2(0.0, -30.0), Vector2(-17.0, 4.0), Vector2(0.0, 29.0), Vector2(17.0, 4.0),
	]), ship_color.lightened(0.16))
	draw_line(Vector2(-19.0, 11.0), Vector2(19.0, 11.0), Color(1.0, 1.0, 1.0, 0.55), 3.0, true)


func _draw_star_skimmer() -> void:
	var wing := PackedVector2Array([
		Vector2(0.0, -36.0), Vector2(-16.0, -12.0), Vector2(-44.0, 7.0),
		Vector2(-25.0, 17.0), Vector2(-32.0, 31.0), Vector2(0.0, 20.0),
		Vector2(32.0, 31.0), Vector2(25.0, 17.0), Vector2(44.0, 7.0), Vector2(16.0, -12.0),
	])
	_draw_ship_polygon(wing, ship_color)
	draw_colored_polygon(PackedVector2Array([
		Vector2(0.0, -28.0), Vector2(-26.0, 10.0), Vector2(0.0, 14.0), Vector2(26.0, 10.0),
	]), ship_color.darkened(0.30))
	draw_line(Vector2(-36.0, 9.0), Vector2(-10.0, 3.0), ship_color.lightened(0.45), 3.0, true)
	draw_line(Vector2(36.0, 9.0), Vector2(10.0, 3.0), ship_color.lightened(0.45), 3.0, true)


func _draw_rocket_pod() -> void:
	var hull := PackedVector2Array([
		Vector2(0.0, -42.0), Vector2(-16.0, -18.0), Vector2(-17.0, 25.0),
		Vector2(-10.0, 37.0), Vector2(10.0, 37.0), Vector2(17.0, 25.0), Vector2(16.0, -18.0),
	])
	_draw_ship_polygon(hull, ship_color)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-15.0, 10.0), Vector2(-31.0, 31.0), Vector2(-13.0, 27.0),
	]), ship_color.darkened(0.24))
	draw_colored_polygon(PackedVector2Array([
		Vector2(15.0, 10.0), Vector2(31.0, 31.0), Vector2(13.0, 27.0),
	]), ship_color.darkened(0.16))
	draw_line(Vector2(-11.0, -15.0), Vector2(-11.0, 23.0), ship_color.lightened(0.38), 3.0, true)
	draw_line(Vector2(11.0, -15.0), Vector2(11.0, 23.0), ship_color.darkened(0.22), 3.0, true)


func _draw_ship_polygon(points: PackedVector2Array, color: Color) -> void:
	var shadow := PackedVector2Array()
	for point in points:
		shadow.append(point + Vector2(4.0, 6.0))
	draw_colored_polygon(shadow, Color(0.0, 0.0, 0.05, 0.70))
	draw_colored_polygon(points, color)
