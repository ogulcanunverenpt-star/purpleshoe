extends RigidBody3D

signal fast_pitch_bounce

const RADIUS := 0.11
const FIELD_HALF_WIDTH := 34.0
const FIELD_HALF_LENGTH := 52.5

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var position := state.transform.origin
	var velocity := state.linear_velocity
	if velocity.y >= -6.0 or absf(position.x) > FIELD_HALF_WIDTH or absf(position.z) > FIELD_HALF_LENGTH:
		return
	var impact_speed := velocity.y + state.total_gravity.y * state.step
	if position.y < RADIUS - 0.05 or position.y + impact_speed * state.step > RADIUS:
		return
	# The CCD solver otherwise scales down the whole velocity on a fast pitch impact.
	var transform := state.transform
	transform.origin.y = RADIUS + 0.01
	state.transform = transform
	var high_impact := clampf((-impact_speed - 9.0) / 4.0, 0.0, 1.0)
	var bounce := lerpf(physics_material_override.bounce, 0.45, high_impact)
	velocity.y = -impact_speed * bounce
	state.linear_velocity = velocity
	fast_pitch_bounce.emit()
