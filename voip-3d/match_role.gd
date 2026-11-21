extends RefCounted

const FIELD_HALF_LENGTH := 52.5
const GOAL_HALF_WIDTH := 3.66

var controller

func _init(match_controller) -> void:
	controller = match_controller

func support_position(player: CharacterBody3D, _carrier: CharacterBody3D, _attack_sign: float) -> Vector3:
	return player.spawn_position

func defensive_position(player: CharacterBody3D, _attack_sign: float) -> Vector3:
	return player.spawn_position

func keeper_target(player: CharacterBody3D, _attack_sign: float) -> Vector3:
	return player.global_position

func formation_position(player: CharacterBody3D, attack_sign: float, attacking: bool) -> Vector3:
	var base: Vector3 = player.spawn_position
	var ball_position: Vector3 = controller.ball.global_position + controller.ball.linear_velocity * 0.2
	ball_position.x = clampf(ball_position.x, -controller.FIELD_HALF_WIDTH, controller.FIELD_HALF_WIDTH)
	ball_position.z = clampf(ball_position.z, -FIELD_HALF_LENGTH, FIELD_HALF_LENGTH)
	base.x = lerpf(base.x, ball_position.x, 0.2)
	base.z += clampf(ball_position.z * 0.3, -15.0, 15.0)
	base.z += attack_sign * (4.0 if attacking else -3.0)
	return base
