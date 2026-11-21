extends "res://match_role.gd"

func support_position(player: CharacterBody3D, carrier: CharacterBody3D, attack_sign: float) -> Vector3:
	var slot := maxi(player.field_slot, 0)
	var lateral := float((slot % 3) - 1) * 9.0
	var run: Vector3 = carrier.global_position + Vector3(lateral * 0.75, 0.0, attack_sign * 13.0)
	var target := formation_position(player, attack_sign, true).lerp(run, 0.7)
	target.z = minf(attack_sign * target.z, maxf(0.0, controller._offside_line_progress(player.team) - 1.5)) * attack_sign
	return target

func defensive_position(player: CharacterBody3D, _attack_sign: float) -> Vector3:
	var target := formation_position(player, _attack_sign, false)
	var ball_position: Vector3 = controller.ball.global_position
	target.z = lerpf(target.z, ball_position.z - _attack_sign * 16.0, 0.25)
	return target
