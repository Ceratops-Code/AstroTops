class_name Traxy
extends SpaceTarget


const ATLAS_TEXTURE: Texture2D = preload("res://assets/traxy.png")
const CELL_SIZE := Vector2(256.0, 256.0)
const CHAIR_DRAW_SIZE := Vector2(118.0, 118.0)
const FLOAT_DRAW_SIZE := Vector2(126.0, 126.0)
const FLEE_SPEED := 154.0
const FLEE_ACCELERATION := 560.0
const FLOAT_SPEED := 48.0
const FLOAT_MIN_SPEED := 36.0
const FLOAT_ROTATION_SPEED := 0.22
const EDGE_MARGIN := 92.0
const CORNER_MARGIN := 118.0
const PLANET_AVOIDANCE_MARGIN := 72.0
const STUCK_WINDOW := 0.5
const STUCK_DISTANCE := 10.0
const ESCAPE_LOCK_DURATION := 0.9
const TOW_DISTANCE := 132.0
const LABEL_FONT_SIZE := 18

enum MotionState { FLEEING, FLOATING, TOWED }

var motion_state := MotionState.FLEEING
var movement_bounds := Rect2(35.0, 146.0, 1210.0, 536.0)
var velocity := Vector2.ZERO
var last_direction := Vector2.RIGHT
var escape_direction := Vector2.ZERO
var escape_lock_remaining := 0.0
var stuck_elapsed := 0.0
var stuck_origin := Vector2.ZERO
var blink_elapsed := 0.0
var tow_elapsed := 0.0
var tow_exit_direction := Vector2.RIGHT
var tow_ship: PlayerShip
var sprite: Sprite2D
var random := RandomNumberGenerator.new()


func _ready() -> void:
	sprite = Sprite2D.new()
	sprite.texture = ATLAS_TEXTURE
	sprite.region_enabled = true
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	add_child(sprite)
	_sync_sprite()
	queue_redraw()


func configure(bounds: Rect2, ship_position: Vector2, obstacles: Array[ColorPlanet], seed: int) -> void:
	body_name = "Traxy"
	movement_bounds = bounds
	random.seed = seed
	position = _choose_spawn_position(ship_position, obstacles)
	velocity = _safe_direction(position - ship_position, Vector2.RIGHT) * FLEE_SPEED
	last_direction = velocity.normalized()
	stuck_origin = position
	motion_state = MotionState.FLEEING
	rotation = 0.0
	_sync_sprite()


func update_active(delta: float, ship_position: Vector2, obstacles: Array[ColorPlanet]) -> void:
	match motion_state:
		MotionState.FLEEING:
			_update_flee(delta, ship_position, obstacles)
		MotionState.FLOATING:
			_update_float(delta, obstacles)
		MotionState.TOWED:
			_update_tow(delta)
	_sync_sprite()
	queue_redraw()


func capture(color: Color) -> bool:
	if not super.capture(color):
		return false
	motion_state = MotionState.FLOATING
	var float_direction := _safe_direction(velocity, Vector2.from_angle(random.randf_range(0.0, TAU)))
	velocity = float_direction * FLOAT_SPEED
	blink_elapsed = 0.0
	_apply_captured_accent()
	_sync_sprite()
	return true


func capture_radius() -> float:
	return 40.0 if motion_state == MotionState.FLEEING else 36.0


func visual_extent() -> float:
	return 61.0 if motion_state == MotionState.FLEEING else 64.0


func apply_tractor_pull(destination: Vector2, pull_distance: float) -> void:
	if motion_state != MotionState.FLEEING:
		return
	global_position = global_position.move_toward(destination, pull_distance)
	velocity = velocity.lerp(_safe_direction(destination - global_position, last_direction) * FLEE_SPEED, 0.08)


func begin_tow(ship_node: PlayerShip, exit_direction: Vector2) -> void:
	tow_ship = ship_node
	tow_exit_direction = _safe_direction(exit_direction, Vector2.RIGHT)
	motion_state = MotionState.TOWED
	velocity = Vector2.ZERO
	tow_elapsed = 0.0
	_sync_sprite()


func current_frame_index() -> int:
	if motion_state != MotionState.FLEEING:
		return 5 if _eyes_closed() else 4
	var direction := velocity if velocity.length_squared() > 4.0 else last_direction
	if absf(direction.x) >= absf(direction.y):
		return 0 if direction.x >= 0.0 else 1
	return 3 if direction.y >= 0.0 else 2


func _choose_spawn_position(ship_position: Vector2, obstacles: Array[ColorPlanet]) -> Vector2:
	var inset := capture_radius() + 12.0
	var area := movement_bounds.grow(-inset)
	var best := area.get_center()
	var best_clearance := -INF
	for _attempt in range(80):
		var candidate := Vector2(
			random.randf_range(area.position.x, area.end.x),
			random.randf_range(area.position.y, area.end.y)
		)
		var clearance := candidate.distance_to(ship_position) - 190.0
		for planet in obstacles:
			if is_instance_valid(planet):
				clearance = minf(clearance, candidate.distance_to(planet.position) - planet.visual_extent() - 48.0)
		if clearance > best_clearance:
			best_clearance = clearance
			best = candidate
		if clearance >= 24.0:
			return candidate
	return best


func _update_flee(delta: float, ship_position: Vector2, obstacles: Array[ColorPlanet]) -> void:
	escape_lock_remaining = maxf(0.0, escape_lock_remaining - delta)
	var desired_direction := _safe_direction(position - ship_position, last_direction)
	var inward := _edge_inward_vector(EDGE_MARGIN)
	var corner_inward := _edge_inward_vector(CORNER_MARGIN)
	var near_horizontal_edge := not is_zero_approx(inward.x)
	var near_vertical_edge := not is_zero_approx(inward.y)
	if not is_zero_approx(corner_inward.x) and not is_zero_approx(corner_inward.y) and escape_lock_remaining <= 0.0:
		escape_direction = _select_escape_direction(ship_position, obstacles)
		escape_lock_remaining = ESCAPE_LOCK_DURATION
	if escape_lock_remaining > 0.0:
		desired_direction = escape_direction
	elif near_horizontal_edge or near_vertical_edge:
		var tangent := Vector2.ZERO
		if near_horizontal_edge:
			tangent.y = 1.0 if position.y >= ship_position.y else -1.0
		if near_vertical_edge:
			tangent.x = 1.0 if position.x >= ship_position.x else -1.0
		desired_direction = _safe_direction(desired_direction * 0.35 + tangent * 0.85 + inward * 0.72, inward)

	var avoidance := _planet_avoidance(obstacles)
	if avoidance.length_squared() > 0.001:
		desired_direction = _safe_direction(desired_direction + avoidance * 1.35, desired_direction)
	velocity = velocity.move_toward(desired_direction * FLEE_SPEED, FLEE_ACCELERATION * delta)
	position += velocity * delta
	_clamp_to_bounds()
	if velocity.length_squared() > 4.0:
		last_direction = velocity.normalized()

	stuck_elapsed += delta
	if stuck_elapsed >= STUCK_WINDOW:
		if position.distance_to(stuck_origin) < STUCK_DISTANCE:
			escape_direction = _select_escape_direction(ship_position, obstacles)
			escape_lock_remaining = ESCAPE_LOCK_DURATION
		stuck_origin = position
		stuck_elapsed = 0.0


func _update_float(delta: float, obstacles: Array[ColorPlanet]) -> void:
	blink_elapsed += delta
	rotation = fposmod(rotation + FLOAT_ROTATION_SPEED * delta, TAU)
	position += velocity * delta
	var radius := capture_radius()
	var minimum := movement_bounds.position + Vector2.ONE * radius
	var maximum := movement_bounds.end - Vector2.ONE * radius
	if position.x <= minimum.x:
		position.x = minimum.x
		velocity.x = absf(velocity.x)
	elif position.x >= maximum.x:
		position.x = maximum.x
		velocity.x = -absf(velocity.x)
	if position.y <= minimum.y:
		position.y = minimum.y
		velocity.y = absf(velocity.y)
	elif position.y >= maximum.y:
		position.y = maximum.y
		velocity.y = -absf(velocity.y)
	for planet in obstacles:
		if not is_instance_valid(planet) or planet.exploding:
			continue
		var separation := position - planet.position
		var required := radius + planet.capture_radius() + 4.0
		if separation.length_squared() >= required * required:
			continue
		var normal := _safe_direction(separation, Vector2.UP)
		position = planet.position + normal * required
		if velocity.dot(normal) < 0.0:
			velocity = velocity.bounce(normal)
	if velocity.length() < FLOAT_MIN_SPEED:
		velocity = _safe_direction(velocity, Vector2.from_angle(random.randf_range(0.0, TAU))) * FLOAT_MIN_SPEED


func _update_tow(delta: float) -> void:
	blink_elapsed += delta
	tow_elapsed += delta
	if not is_instance_valid(tow_ship):
		return
	var perpendicular := tow_exit_direction.orthogonal()
	var anchor := tow_ship.global_position - tow_exit_direction * TOW_DISTANCE
	anchor += perpendicular * sin(tow_elapsed * 5.2) * 12.0
	global_position = global_position.lerp(anchor, minf(1.0, delta * 5.4))


func _edge_inward_vector(margin: float = EDGE_MARGIN) -> Vector2:
	var inward := Vector2.ZERO
	if position.x < movement_bounds.position.x + margin:
		inward.x = 1.0
	elif position.x > movement_bounds.end.x - margin:
		inward.x = -1.0
	if position.y < movement_bounds.position.y + margin:
		inward.y = 1.0
	elif position.y > movement_bounds.end.y - margin:
		inward.y = -1.0
	return inward


func _select_escape_direction(ship_position: Vector2, obstacles: Array[ColorPlanet]) -> Vector2:
	var inward := _edge_inward_vector(CORNER_MARGIN)
	var away := _safe_direction(position - ship_position, Vector2.RIGHT)
	var candidates := [
		Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN,
		Vector2(1.0, 1.0).normalized(), Vector2(1.0, -1.0).normalized(),
		Vector2(-1.0, 1.0).normalized(), Vector2(-1.0, -1.0).normalized(),
	]
	var best: Vector2 = _safe_direction(inward, away)
	var best_score := -INF
	for candidate: Vector2 in candidates:
		var probe := position + candidate * 92.0
		if not movement_bounds.grow(-capture_radius()).has_point(probe):
			continue
		var score := candidate.dot(away) * 1.4 + candidate.dot(inward) * 1.8
		for planet in obstacles:
			if is_instance_valid(planet):
				score += clampf(probe.distance_to(planet.position) / 180.0, 0.0, 1.0) * 0.22
		if score > best_score:
			best_score = score
			best = candidate
	return best


func _planet_avoidance(obstacles: Array[ColorPlanet]) -> Vector2:
	var avoidance := Vector2.ZERO
	for planet in obstacles:
		if not is_instance_valid(planet) or planet.exploding:
			continue
		var separation := position - planet.position
		var influence := capture_radius() + planet.visual_extent() + PLANET_AVOIDANCE_MARGIN
		var distance := separation.length()
		if distance > 0.001 and distance < influence:
			avoidance += separation / distance * (1.0 - distance / influence)
	return avoidance


func _clamp_to_bounds() -> void:
	var radius := capture_radius()
	position.x = clampf(position.x, movement_bounds.position.x + radius, movement_bounds.end.x - radius)
	position.y = clampf(position.y, movement_bounds.position.y + radius, movement_bounds.end.y - radius)


func _safe_direction(value: Vector2, fallback: Vector2) -> Vector2:
	return value.normalized() if value.length_squared() > 0.0001 else fallback.normalized()


func _eyes_closed() -> bool:
	return fmod(blink_elapsed, 1.8) >= 1.64


func _sync_sprite() -> void:
	if not is_instance_valid(sprite):
		return
	var frame := current_frame_index()
	sprite.region_rect = Rect2(Vector2(frame % 3, frame / 3) * CELL_SIZE, CELL_SIZE)
	var draw_size := CHAIR_DRAW_SIZE if motion_state == MotionState.FLEEING else FLOAT_DRAW_SIZE
	sprite.scale = draw_size / CELL_SIZE


func _apply_captured_accent() -> void:
	if not is_instance_valid(sprite):
		return
	var shader := Shader.new()
	shader.code = """shader_type canvas_item;
uniform vec4 accent_color : source_color;
void fragment() {
	vec4 pixel = texture(TEXTURE, UV);
	vec2 local_uv = vec2(fract(UV.x * 3.0), fract(UV.y * 2.0));
	float cool = smoothstep(0.06, 0.34, pixel.b - pixel.r) * smoothstep(-0.04, 0.30, pixel.g - pixel.r);
	float channel_min = min(pixel.r, min(pixel.g, pixel.b));
	float channel_max = max(pixel.r, max(pixel.g, pixel.b));
	float white_fabric = smoothstep(0.58, 0.88, channel_min) * (1.0 - smoothstep(0.12, 0.30, channel_max - channel_min));
	float side_sleeves = smoothstep(0.40, 0.49, local_uv.y) * smoothstep(0.18, 0.30, abs(local_uv.x - 0.5));
	float lower_suit = smoothstep(0.52, 0.62, local_uv.y);
	float central_head = (1.0 - smoothstep(0.22, 0.31, abs(local_uv.x - 0.5))) * (1.0 - smoothstep(0.54, 0.63, local_uv.y));
	float suit_geometry = max(side_sleeves, lower_suit) * (1.0 - central_head);
	float suit_mask = max(cool, white_fabric) * suit_geometry;
	float lightness = max(max(pixel.r, pixel.g), pixel.b);
	vec3 replacement = accent_color.rgb * (0.58 + lightness * 0.42);
	COLOR = vec4(mix(pixel.rgb, replacement, suit_mask * 0.82), pixel.a);
}"""
	var shader_material := ShaderMaterial.new()
	shader_material.shader = shader
	shader_material.set_shader_parameter("accent_color", captured_color)
	sprite.material = shader_material


func _draw() -> void:
	if motion_state == MotionState.TOWED and is_instance_valid(tow_ship):
		var ship_local := to_local(tow_ship.global_position)
		draw_line(Vector2.ZERO, ship_local, Color(captured_color, 0.90), 3.0, true)
		draw_circle(Vector2.ZERO, 5.0, Color("ffc857"))
	if motion_state != MotionState.TOWED:
		var font := ThemeDB.fallback_font
		var label_color := Color("fff2a8") if captured else Color("dffbff")
		draw_string(font, Vector2(-50.0, 72.0), body_name, HORIZONTAL_ALIGNMENT_CENTER, 100.0, LABEL_FONT_SIZE, Color(0.0, 0.0, 0.04, 0.92))
		draw_string(font, Vector2(-50.0, 70.5), body_name, HORIZONTAL_ALIGNMENT_CENTER, 100.0, LABEL_FONT_SIZE, label_color)
