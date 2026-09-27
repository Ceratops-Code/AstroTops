class_name Traxy
extends SpaceTarget


const ATLAS_TEXTURE: Texture2D = preload("res://assets/traxy.png")
const CELL_SIZE := Vector2(256.0, 256.0)
const CHAIR_DRAW_SIZE := Vector2(118.0, 118.0)
const FLOAT_DRAW_SIZE := Vector2(126.0, 126.0)
const FLEE_FRAME_INDEX := 3
const FLEE_SPEED := 154.0
const FLEE_ACCELERATION := 560.0
const FLEE_ROTATION_RESPONSE := 7.2
const THRUSTER_RESPONSE := 11.0
const THRUSTER_PULSE_SPEED := 10.5
const FLOAT_SPEED := 48.0
const FLOAT_MIN_SPEED := 36.0
const FLOAT_ROTATION_SPEED := 0.22
const CAPTURE_POOF_DURATION := 0.52
const HOOK_TRAVEL_DURATION := 0.34
const HOOK_LATCH_DURATION := 0.38
const HOOK_HARNESS_OFFSET := Vector2(0.0, 18.0)
const HOOK_CABLE_SEGMENTS := 18
const EDGE_MARGIN := 92.0
const CORNER_MARGIN := 118.0
const PLANET_AVOIDANCE_MARGIN := 72.0
const STUCK_WINDOW := 0.5
const STUCK_DISTANCE := 10.0
const ESCAPE_LOCK_DURATION := 0.9
const TOW_DISTANCE := 132.0
const LABEL_FONT_SIZE := 18

enum MotionState { FLEEING, FLOATING, RESCUE_WAITING, HOOKING, TOWED }

var motion_state := MotionState.FLEEING
var movement_bounds := Rect2(35.0, 146.0, 1210.0, 536.0)
var velocity := Vector2.ZERO
var last_direction := Vector2.RIGHT
var escape_direction := Vector2.ZERO
var escape_lock_remaining := 0.0
var stuck_elapsed := 0.0
var stuck_origin := Vector2.ZERO
var flee_visual_rotation := 0.0
var flee_target_rotation := 0.0
var thruster_elapsed := 0.0
var left_thruster_power := 1.0
var right_thruster_power := 1.0
var blink_elapsed := 0.0
var capture_poof_elapsed := CAPTURE_POOF_DURATION
var capture_poof_world_position := Vector2.ZERO
var hook_elapsed := 0.0
var tow_elapsed := 0.0
var tow_exit_direction := Vector2.RIGHT
var tow_ship: PlayerShip
var thruster_layer: Node2D
var left_thruster: Node2D
var right_thruster: Node2D
var sprite: Sprite2D
var flee_material: ShaderMaterial
var random := RandomNumberGenerator.new()


func _ready() -> void:
	thruster_layer = Node2D.new()
	thruster_layer.show_behind_parent = true
	left_thruster = _make_thruster_flame(Vector2(-40.0, 0.0))
	right_thruster = _make_thruster_flame(Vector2(40.0, 0.0))
	thruster_layer.add_child(left_thruster)
	thruster_layer.add_child(right_thruster)
	add_child(thruster_layer)
	sprite = Sprite2D.new()
	sprite.texture = ATLAS_TEXTURE
	sprite.region_enabled = true
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# Effects and the name are drawn by the parent and must remain visible over
	# the character at the hook latch and at the center of the capture cloud.
	sprite.show_behind_parent = true
	add_child(sprite)
	_apply_flee_material()
	_sync_sprite()
	queue_redraw()


func configure(bounds: Rect2, ship_position: Vector2, obstacles: Array[ColorPlanet], seed: int) -> void:
	body_name = "Traxy"
	movement_bounds = bounds
	random.seed = seed
	position = _choose_spawn_position(ship_position, obstacles)
	velocity = _safe_direction(position - ship_position, Vector2.RIGHT) * FLEE_SPEED
	last_direction = velocity.normalized()
	flee_target_rotation = flee_rotation_for_direction(velocity)
	flee_visual_rotation = flee_target_rotation
	thruster_elapsed = 0.0
	left_thruster_power = 1.0
	right_thruster_power = 1.0
	stuck_origin = position
	motion_state = MotionState.FLEEING
	rotation = 0.0
	capture_poof_elapsed = CAPTURE_POOF_DURATION
	hook_elapsed = 0.0
	tow_ship = null
	_apply_flee_material()
	_sync_sprite()


func update_active(delta: float, ship_position: Vector2, obstacles: Array[ColorPlanet]) -> void:
	capture_poof_elapsed = minf(CAPTURE_POOF_DURATION, capture_poof_elapsed + delta)
	match motion_state:
		MotionState.FLEEING:
			_update_flee(delta, ship_position, obstacles)
		MotionState.FLOATING:
			_update_float(delta, obstacles)
		MotionState.RESCUE_WAITING:
			_update_rescue_waiting(delta)
		MotionState.HOOKING:
			_update_hook(delta)
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
	capture_poof_world_position = global_position
	capture_poof_elapsed = 0.0
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


func prepare_for_rescue() -> void:
	if motion_state == MotionState.FLOATING:
		motion_state = MotionState.RESCUE_WAITING
		velocity = Vector2.ZERO
		_sync_sprite()
		queue_redraw()


func begin_hook(ship_node: PlayerShip) -> void:
	tow_ship = ship_node
	motion_state = MotionState.HOOKING
	velocity = Vector2.ZERO
	hook_elapsed = 0.0
	_sync_sprite()


func hook_progress() -> float:
	return clampf(hook_elapsed / HOOK_TRAVEL_DURATION, 0.0, 1.0)


func hook_latch_progress() -> float:
	return clampf((hook_elapsed - HOOK_TRAVEL_DURATION) / HOOK_LATCH_DURATION, 0.0, 1.0)


func is_hook_animation_complete() -> bool:
	return motion_state == MotionState.HOOKING and hook_elapsed >= HOOK_TRAVEL_DURATION + HOOK_LATCH_DURATION


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
	return FLEE_FRAME_INDEX


func flee_rotation_for_direction(direction: Vector2) -> float:
	# The approved overhead chair frame points down at zero rotation.
	return wrapf(_safe_direction(direction, Vector2.DOWN).angle() - Vector2.DOWN.angle(), -PI, PI)


func flee_visual_direction() -> Vector2:
	return Vector2.DOWN.rotated(flee_visual_rotation)


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
	_update_flee_visual(delta, velocity if velocity.length_squared() > 4.0 else desired_direction)

	stuck_elapsed += delta
	if stuck_elapsed >= STUCK_WINDOW:
		if position.distance_to(stuck_origin) < STUCK_DISTANCE:
			escape_direction = _select_escape_direction(ship_position, obstacles)
			escape_lock_remaining = ESCAPE_LOCK_DURATION
		stuck_origin = position
		stuck_elapsed = 0.0


func _update_flee_visual(delta: float, direction: Vector2) -> void:
	# Shortest-arc interpolation prevents both atlas thresholds and a full spin
	# when the escape vector crosses the -PI/PI boundary.
	flee_target_rotation = flee_rotation_for_direction(direction)
	var turn_error := wrapf(flee_target_rotation - flee_visual_rotation, -PI, PI)
	var rotation_weight := 1.0 - exp(-FLEE_ROTATION_RESPONSE * maxf(delta, 0.0))
	flee_visual_rotation = wrapf(lerp_angle(flee_visual_rotation, flee_target_rotation, rotation_weight), -PI, PI)
	thruster_elapsed += maxf(delta, 0.0)
	var pulse := 0.94 + sin(thruster_elapsed * THRUSTER_PULSE_SPEED) * 0.08
	var turn_bias := clampf(turn_error / PI, -0.34, 0.34)
	var thruster_weight := 1.0 - exp(-THRUSTER_RESPONSE * maxf(delta, 0.0))
	left_thruster_power = lerpf(left_thruster_power, pulse - turn_bias, thruster_weight)
	right_thruster_power = lerpf(right_thruster_power, pulse + turn_bias, thruster_weight)


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


func _update_hook(delta: float) -> void:
	blink_elapsed += delta
	rotation = fposmod(rotation + FLOAT_ROTATION_SPEED * delta, TAU)
	hook_elapsed += delta


func _update_rescue_waiting(delta: float) -> void:
	blink_elapsed += delta
	rotation = fposmod(rotation + FLOAT_ROTATION_SPEED * delta, TAU)


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
	sprite.rotation = flee_visual_rotation if motion_state == MotionState.FLEEING else 0.0
	sprite.position = Vector2.ZERO
	if is_instance_valid(thruster_layer):
		thruster_layer.visible = motion_state == MotionState.FLEEING
		thruster_layer.rotation = flee_visual_rotation
	if is_instance_valid(left_thruster):
		left_thruster.scale = Vector2(1.0, clampf(left_thruster_power, 0.58, 1.34))
	if is_instance_valid(right_thruster):
		right_thruster.scale = Vector2(1.0, clampf(right_thruster_power, 0.58, 1.34))
	if motion_state == MotionState.HOOKING and is_instance_valid(tow_ship):
		var latch := hook_latch_progress()
		if latch > 0.0 and latch < 1.0:
			var ship_local := to_local(tow_ship.global_position)
			sprite.position = _safe_direction(ship_local, Vector2.RIGHT) * sin(latch * PI) * 7.0


func _make_thruster_flame(flame_position: Vector2) -> Node2D:
	# Exhaust is separate from the chair art so each side can react to steering
	# while the complete visual rotates continuously as one unit.
	var flame := Node2D.new()
	flame.position = flame_position
	var outer := Polygon2D.new()
	outer.polygon = PackedVector2Array([Vector2(-6.0, 0.0), Vector2(6.0, 0.0), Vector2(4.5, -11.0), Vector2(0.0, -25.0), Vector2(-4.5, -11.0)])
	outer.color = Color("ff5a1f")
	flame.add_child(outer)
	var middle := Polygon2D.new()
	middle.polygon = PackedVector2Array([Vector2(-4.0, -1.0), Vector2(4.0, -1.0), Vector2(3.0, -10.0), Vector2(0.0, -20.0), Vector2(-3.0, -10.0)])
	middle.color = Color("ffd23f")
	flame.add_child(middle)
	var core := Polygon2D.new()
	core.polygon = PackedVector2Array([Vector2(-2.2, -2.0), Vector2(2.2, -2.0), Vector2(1.6, -8.0), Vector2(0.0, -15.0), Vector2(-1.6, -8.0)])
	core.color = Color("dffbff")
	flame.add_child(core)
	return flame


func _apply_flee_material() -> void:
	if not is_instance_valid(sprite):
		return
	if flee_material == null:
		# Frame 3 is the approved overhead chair. Mask only its two baked flame
		# ellipses in atlas coordinates; the code-rendered exhaust replaces them.
		var shader := Shader.new()
		shader.code = """shader_type canvas_item;
void fragment() {
	vec4 pixel = texture(TEXTURE, UV);
	vec2 atlas_pixel = UV * vec2(768.0, 512.0);
	vec2 local_pixel = atlas_pixel - vec2(0.0, 256.0);
	vec2 left_flame = (local_pixel - vec2(64.0, 69.0)) / vec2(22.0, 59.0);
	vec2 right_flame = (local_pixel - vec2(181.0, 69.0)) / vec2(22.0, 59.0);
	float baked_flame = max(1.0 - smoothstep(0.82, 1.0, length(left_flame)), 1.0 - smoothstep(0.82, 1.0, length(right_flame)));
	pixel.a *= 1.0 - baked_flame;
	COLOR = pixel;
}"""
		flee_material = ShaderMaterial.new()
		flee_material.shader = shader
	sprite.material = flee_material


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
	_draw_capture_poof()
	if motion_state == MotionState.HOOKING and is_instance_valid(tow_ship):
		_draw_hook_animation()
	if motion_state == MotionState.TOWED and is_instance_valid(tow_ship):
		var ship_local := to_local(tow_ship.global_position)
		var harness := _harness_local_position()
		var ship_anchor := _ship_cable_anchor(ship_local, harness)
		var cable_sag := sin(tow_elapsed * 5.2) * 7.0
		_draw_cable(ship_anchor, harness, cable_sag)
		draw_circle(harness, 5.0, Color("ffc857"))
	if motion_state != MotionState.TOWED:
		var font := ThemeDB.fallback_font
		var label_color := name_label_color()
		draw_string(font, Vector2(-50.0, 72.0), body_name, HORIZONTAL_ALIGNMENT_CENTER, 100.0, LABEL_FONT_SIZE, Color(0.0, 0.0, 0.04, 0.92))
		draw_string(font, Vector2(-50.0, 70.5), body_name, HORIZONTAL_ALIGNMENT_CENTER, 100.0, LABEL_FONT_SIZE, label_color)


func name_label_color() -> Color:
	return captured_color if captured else Color("dffbff")


func _harness_local_position() -> Vector2:
	return HOOK_HARNESS_OFFSET + (sprite.position if is_instance_valid(sprite) else Vector2.ZERO)


func _ship_cable_anchor(ship_local: Vector2, harness: Vector2) -> Vector2:
	var hull_offset := tow_ship.hit_radius if is_instance_valid(tow_ship) else 29.0
	return ship_local + _safe_direction(harness - ship_local, Vector2.LEFT) * hull_offset


func _draw_hook_animation() -> void:
	var ship_local := to_local(tow_ship.global_position)
	var harness := _harness_local_position()
	var ship_anchor := _ship_cable_anchor(ship_local, harness)
	var travel := hook_progress()
	var eased_travel := smoothstep(0.0, 1.0, travel)
	var hook_position := ship_anchor.lerp(harness, eased_travel)
	var latch := hook_latch_progress()
	var cable_sag := lerpf(18.0, 4.0, eased_travel)
	if latch > 0.0:
		cable_sag = sin(latch * TAU) * (1.0 - latch) * 18.0
	_draw_cable(ship_anchor, hook_position, cable_sag)
	_draw_hook_head(hook_position, ship_anchor, harness, travel)
	if latch > 0.0:
		var flash_alpha := 1.0 - latch * 0.78
		var burst_radius := 10.0 + latch * 24.0
		draw_arc(harness, burst_radius, 0.0, TAU, 28, Color(1.0, 1.0, 1.0, flash_alpha), 4.0, true)
		draw_circle(harness, 8.0 + latch * 7.0, Color(0.88, 0.96, 1.0, flash_alpha * 0.34))
		for index in range(8):
			var ray := Vector2.from_angle(TAU * float(index) / 8.0 + latch * 0.7)
			draw_line(harness + ray * (burst_radius + 3.0), harness + ray * (burst_radius + 12.0), Color(1.0, 0.95, 0.72, flash_alpha), 3.0, true)


func _draw_cable(from: Vector2, to: Vector2, sag: float) -> void:
	var points := PackedVector2Array()
	var perpendicular := _safe_direction((to - from).orthogonal(), Vector2.UP)
	for index in range(HOOK_CABLE_SEGMENTS + 1):
		var amount := float(index) / float(HOOK_CABLE_SEGMENTS)
		points.append(from.lerp(to, amount) + perpendicular * sin(amount * PI) * sag)
	draw_polyline(points, Color(0.02, 0.04, 0.10, 0.90), 6.0, true)
	draw_polyline(points, Color(captured_color, 0.94), 3.0, true)


func _draw_hook_head(hook_position: Vector2, ship_local: Vector2, harness: Vector2, travel: float) -> void:
	var launch_direction := _safe_direction(harness - ship_local, Vector2.RIGHT)
	var hook_rotation := launch_direction.angle() + PI * 0.5 + travel * TAU * 1.5
	draw_set_transform(hook_position, hook_rotation, Vector2.ONE)
	draw_line(Vector2(0.0, -11.0), Vector2(0.0, 5.0), Color("fff4c2"), 4.0, true)
	draw_arc(Vector2(4.0, 5.0), 8.0, 0.15, PI * 1.55, 16, Color("ffc857"), 4.0, true)
	draw_circle(Vector2(0.0, -11.0), 3.2, Color.WHITE)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_capture_poof() -> void:
	if capture_poof_elapsed >= CAPTURE_POOF_DURATION:
		return
	var progress := clampf(capture_poof_elapsed / CAPTURE_POOF_DURATION, 0.0, 1.0)
	var fade := pow(1.0 - progress, 1.45)
	var origin := to_local(capture_poof_world_position)
	draw_arc(origin, 18.0 + progress * 50.0, 0.0, TAU, 40, Color(1.0, 1.0, 1.0, fade * 0.78), 4.0, true)
	for index in range(12):
		var angle := TAU * float(index) / 12.0 + float(index % 3) * 0.12
		var distance := (22.0 + progress * 48.0) * (0.88 + float(index % 4) * 0.06)
		var world_center := capture_poof_world_position + Vector2.from_angle(angle) * distance
		var center := to_local(world_center)
		var radius := (10.0 + progress * 8.0) * (0.86 + float(index % 3) * 0.09)
		var cloud_color := Color(0.96, 0.98, 1.0, fade * (0.58 + float(index % 2) * 0.12))
		draw_circle(center, radius, cloud_color)
