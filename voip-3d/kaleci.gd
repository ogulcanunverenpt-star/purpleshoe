extends "res://match_role.gd"

func keeper_target(player: CharacterBody3D, attack_sign: float) -> Vector3:
	var ball_position: Vector3 = controller.ball.global_position
	var ball_velocity: Vector3 = controller.ball.linear_velocity
	var goal_line_z := -attack_sign * FIELD_HALF_LENGTH
	var goal_z := -attack_sign * (FIELD_HALF_LENGTH - 3.0)
	var target_x := ball_position.x * 0.25
	if absf(ball_velocity.z) > 0.5 and ball_velocity.z * attack_sign < 0.0:
		var time_to_goal := (goal_line_z - ball_position.z) / ball_velocity.z
		if time_to_goal >= 0.0 and time_to_goal < 3.0:
			target_x = ball_position.x + ball_velocity.x * time_to_goal
	elif controller.ball_owner_name.is_empty() and ball_position.y < 1.0 \
			and absf(ball_position.x) < controller.PENALTY_AREA_HALF_WIDTH \
			and attack_sign * ball_position.z < -FIELD_HALF_LENGTH + controller.PENALTY_AREA_DEPTH \
			and ball_velocity.length() < 5.0:
		return Vector3(ball_position.x, 0.0, ball_position.z)
	controller._try_ai_keeper_dive(player, attack_sign)
	return Vector3(clampf(target_x, -GOAL_HALF_WIDTH + 0.55, GOAL_HALF_WIDTH - 0.55), 0.0, goal_z)
