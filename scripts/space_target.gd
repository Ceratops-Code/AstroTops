class_name SpaceTarget
extends Node2D


## Shared gameplay contract for anything the ship can mark or pull.
## Target implementations own their rendering and post-capture behavior.
var body_name := "Target"
var captured_color := Color("41f4c6")
var captured := false
var exploding := false


func capture(color: Color) -> bool:
	if captured or exploding:
		return false
	captured = true
	captured_color = color
	queue_redraw()
	return true


func capture_radius() -> float:
	return 32.0


func visual_extent() -> float:
	return capture_radius()


func apply_tractor_pull(destination: Vector2, pull_distance: float) -> void:
	global_position = global_position.move_toward(destination, pull_distance)
