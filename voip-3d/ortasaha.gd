extends "res://match_role.gd"

func support_position(player: CharacterBody3D, carrier: CharacterBody3D, attack_sign: float) -> Vector3:
	var slot := maxi(player.field_slot, 0)
	var lateral := float((slot % 3) - 1) * 9.0
	var support := carrier.global_position + Vector3(lateral, 0.0, attack_sign * 7.0)
	return formation_position(player, attack_sign, true).lerp(support, 0.6)

func defensive_position(player: CharacterBody3D, attack_sign: float) -> Vector3:
	var slot := maxi(player.field_slot, 0)
	var ball_position: Vector3 = controller.ball.global_position
	var lateral := float(slot - 5) * 10.0
	var cover := Vector3(ball_position.x * 0.35 + lateral, 0.0, ball_position.z - attack_sign * 9.0)
	return formation_position(player, attack_sign, false).lerp(cover, 0.55)
