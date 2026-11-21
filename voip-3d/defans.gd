extends "res://match_role.gd"

func support_position(player: CharacterBody3D, _carrier: CharacterBody3D, attack_sign: float) -> Vector3:
	return formation_position(player, attack_sign, true)

func defensive_position(player: CharacterBody3D, attack_sign: float) -> Vector3:
	var slot := maxi(player.field_slot, 0)
	var ball_position: Vector3 = controller.ball.global_position
	var own_goal := Vector3(0.0, 0.0, -attack_sign * FIELD_HALF_LENGTH)
	var lane := ball_position.lerp(own_goal, 0.35 + float(slot % 2) * 0.12)
	lane += Vector3(float((slot % 3) - 1) * 4.0, 0.0, 0.0)
	return formation_position(player, attack_sign, false).lerp(lane, 0.45)
