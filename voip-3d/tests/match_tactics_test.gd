extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
		quit(1)
	return condition

func _run() -> void:
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var manager := root.get_node("MatchManager")
	manager.start_server(manager.TEAM_RED, manager.ROLE_PLAYER, "Test", false, 5, manager.MODE_MATCH, false)
	if change_scene_to_file("res://match.tscn") != OK:
		push_error("Could not load match scene.")
		quit(1)
		return
	for _frame in range(5):
		await process_frame
	var world := current_scene
	var game := world.get_node("FootballMatchController")
	var players := world.get_node("players")
	game.set_physics_process(false)
	for player in players.get_children():
		player.set_physics_process(false)
		if player is CharacterBody3D:
			player.global_position = Vector3(30, 0, 40 if player.team == manager.TEAM_BLUE else -40)
	var passer := players.get_node("10105") as CharacterBody3D
	var blocked := players.get_node("10106") as CharacterBody3D
	var safe := players.get_node("10104") as CharacterBody3D
	var defender := players.get_node("10000") as CharacterBody3D
	passer.global_position = Vector3.ZERO
	blocked.global_position = Vector3(0, 0, 15)
	safe.global_position = Vector3(12, 0, 10)
	defender.global_position = Vector3(0, 0, 7)
	game.ball.freeze = true
	game.ball.global_position = Vector3(0, game.BALL_RADIUS, 0)
	game.ball.linear_velocity = Vector3.ZERO
	game.ball_owner_name = passer.name
	if not _check(game._best_forward_teammate(passer) == safe, "AI chose a pass through a defender instead of a clear option."):
		return
	var pressing_opponent := players.get_node("10001") as CharacterBody3D
	pressing_opponent.global_position = Vector3(3, 0, 0)
	game.game_started = true
	game.kickoff_team = -1
	game.kickoff_delay = 0.0
	game.ball.freeze = false
	game.selected_entity_by_peer[1] = "10108"
	game.try_ai_ball_action(passer)
	if not _check(game.ball_owner_name.is_empty() and game.cross_run_assignments.has(safe.name), "Pressured AI did not play a through ball for its unselected receiver."):
		return
	game.cross_run_assignments.clear()
	game.ball.freeze = true
	game.ball.global_position = Vector3(0, game.BALL_RADIUS, 0)
	game.ball.linear_velocity = Vector3.ZERO
	game.ball_owner_name = passer.name
	safe.global_position = Vector3(0, 0, 12)
	if not _check(game._best_forward_teammate(passer) == null, "AI selected a blocked passing lane."):
		return
	game.ball_owner_name = ""
	game.ball.linear_velocity = Vector3(8, 0, 0)
	defender.global_position = Vector3(-8, 0, 0)
	var press_target: Vector3 = game._ai_press_target(defender, game._attack_sign(defender.team))
	if not _check(press_target.x > game.ball.global_position.x, "Pressing player did not lead a moving loose ball."):
		return
	var interceptor := players.get_node("10002") as CharacterBody3D
	defender.global_position = Vector3(1, 0, 0)
	interceptor.global_position = Vector3(8, 0, 0)
	game.ball.linear_velocity = Vector3(30, 0, 0)
	if not _check(game._ai_tactical_state(interceptor) == game.AIState.PRESS and game._ai_tactical_state(defender) == game.AIState.COVER, "AI did not assign a fast loose ball to the best interceptor."):
		return
	game.ball.linear_velocity = Vector3.ZERO
	game.ball_owner_name = passer.name
	var presser := players.get_node("10001") as CharacterBody3D
	presser.global_position = Vector3(1, 0, 0)
	defender.global_position = Vector3(10, 0, 6)
	blocked.global_position = Vector3(10, 0, 8)
	var marker_target: Vector3 = game._ai_marking_target(defender, defender.global_position, game._attack_sign(defender.team))
	if not _check(marker_target.distance_to(blocked.global_position) < 2.1 and marker_target.z > blocked.global_position.z, "Defender did not mark goal-side of the attacker."):
		return
	game.ball_owner_name = ""
	var role = game._role_ai_for(passer)
	passer.spawn_position = Vector3(0, 0, -25)
	game.second_half = false
	var first_half: Vector3 = role.formation_position(passer, game._attack_sign(passer.team), false)
	game.second_half = true
	game.reset_players_for_kickoff(manager.TEAM_BLUE)
	var second_half: Vector3 = role.formation_position(passer, game._attack_sign(passer.team), false)
	if not _check(first_half.z < 0 and second_half.z > 0, "Formation did not reverse after halftime."):
		return
	var keeper := players.get_node("10110") as CharacterBody3D
	game.second_half = false
	game.ball.global_position = Vector3(2, game.BALL_RADIUS, -45)
	var keeper_target: Vector3 = game._role_ai_for(keeper).keeper_target(keeper, game._attack_sign(keeper.team))
	if not _check(keeper_target.distance_to(Vector3(2, 0, -45)) < 0.01, "Keeper did not collect a slow loose ball inside the penalty area."):
		return
	game.ball.linear_velocity = Vector3(2, 0, -12)
	keeper_target = game._role_ai_for(keeper).keeper_target(keeper, game._attack_sign(keeper.team))
	if not _check(absf(keeper_target.z + game.FIELD_HALF_LENGTH - 3.0) < 0.01, "Keeper abandoned the goal during an incoming shot."):
		return
	var opposing_keeper := players.get_node("10010") as CharacterBody3D
	opposing_keeper.global_position = Vector3(2, 0, game.FIELD_HALF_LENGTH - 3.0)
	game.ball.global_position = Vector3(20, game.BALL_RADIUS, 30)
	var shot_direction: Vector3 = game._ai_shot_direction(passer, game._attack_sign(passer.team))
	var goal_time: float = (game.FIELD_HALF_LENGTH - game.ball.global_position.z) / shot_direction.z
	var shot_goal_x: float = game.ball.global_position.x + shot_direction.x * goal_time
	if not _check(shot_goal_x < 0.0 and absf(shot_goal_x) < game.GOAL_HALF_WIDTH, "AI shot from a wide angle did not aim inside the goal, away from the keeper."):
		return
	game.second_half = true
	opposing_keeper.global_position = Vector3(-2, 0, -game.FIELD_HALF_LENGTH + 3.0)
	game.ball.global_position = Vector3(-20, game.BALL_RADIUS, -30)
	shot_direction = game._ai_shot_direction(passer, game._attack_sign(passer.team))
	goal_time = (-game.FIELD_HALF_LENGTH - game.ball.global_position.z) / shot_direction.z
	shot_goal_x = game.ball.global_position.x + shot_direction.x * goal_time
	if not _check(shot_goal_x > 0.0 and absf(shot_goal_x) < game.GOAL_HALF_WIDTH, "AI did not reverse its shot direction after halftime."):
		return
	game.second_half = false
	manager.roster = {1: {"team": manager.TEAM_RED, "role": manager.ROLE_PLAYER, "username": "Test"}}
	for player in players.get_children():
		if player is CharacterBody3D:
			player.controller_peer_id = 1
			player.global_position = Vector3(30, 0, 40)
	game._set_local_selection(passer)
	defender.global_position = Vector3(0, 0, 20)
	interceptor.global_position = Vector3(10, 0, 10)
	game.kickoff_team = -1
	game._start_free_kick(Vector3(0, game.BALL_RADIUS, 20), manager.TEAM_BLUE, "FREE KICK")
	game.kickoff_delay = 0.0
	game._physics_process(5.1)
	if not _check(not game.set_piece_active and game.pass_origin_name == defender.name and game.pass_receiver_name == interceptor.name, "AI did not pass a distant free kick to an available teammate."):
		return
	defender.global_position = Vector3(0, 0, -40)
	game._start_free_kick(Vector3(0, game.BALL_RADIUS, -40), manager.TEAM_BLUE, "PENALTY", "penalty")
	game.kickoff_delay = 0.0
	game._physics_process(5.1)
	if not _check(not game.set_piece_active and game.last_ball_actor_name == defender.name and game.pass_origin_name.is_empty() and game.ball.linear_velocity.z < 0.0, "AI did not shoot its penalty toward goal."):
		return
	defender.global_position = Vector3(game.FIELD_HALF_WIDTH - 1.0, 0, -game.FIELD_HALF_LENGTH + 1.0)
	game._start_corner_kick(Vector3(game.FIELD_HALF_WIDTH, 0, -game.FIELD_HALF_LENGTH), manager.TEAM_RED)
	game.kickoff_delay = 0.0
	game._physics_process(5.1)
	if not _check(not game.set_piece_active and game.pass_origin_name == defender.name and game.ball.linear_velocity.x < 0.0 and game.ball.linear_velocity.y > 0.0, "AI did not cross the corner toward the penalty area."):
		return
	game.last_ball_actor_name = passer.name
	game._restart_at_six_yard(Vector3(0, 0, game.FIELD_HALF_LENGTH + 1.0))
	game.kickoff_delay = 0.0
	game._physics_process(5.1)
	if not _check(not game.set_piece_active and game.last_ball_actor_name == "10010" and game.ball.linear_velocity.z < 0.0, "AI goalkeeper did not take the goal kick upfield."):
		return
	defender.global_position = Vector3(game.FIELD_HALF_WIDTH - 1.0, 0, 0)
	interceptor.global_position = Vector3(game.FIELD_HALF_WIDTH - 10.0, 0, -10)
	game.last_ball_actor_name = passer.name
	game._start_throw_in(Vector3(game.FIELD_HALF_WIDTH + 1.0, 0, 0))
	game.kickoff_delay = 0.0
	game._physics_process(5.1)
	if not _check(not game.set_piece_active and game.pass_origin_name == defender.name and game.ball.linear_velocity.x < 0.0, "AI did not restart a throw-in toward the field."):
		return
	passer.global_position = Vector3(0, 0, 0)
	game._start_free_kick(Vector3(0, game.BALL_RADIUS, 0), manager.TEAM_RED, "FREE KICK")
	game.kickoff_delay = 0.0
	game._physics_process(5.1)
	if not _check(game.set_piece_active and game.get_local_selected_player() == passer, "AI took a human-controlled free kick before its timeout."):
		return
	game._set_local_selection(safe)
	game._physics_process(0.1)
	if not _check(game.set_piece_active, "AI took a human team's free kick after the player changed selection."):
		return

	game._clear_set_piece()
	game.kickoff_team = -1
	game.kickoff_delay = 0.0
	for player in players.get_children():
		if player is CharacterBody3D:
			player.global_position = Vector3(30, 0, 40 if player.team == manager.TEAM_BLUE else -40)
			player.velocity = Vector3.ZERO
	passer.global_position = Vector3.ZERO
	safe.global_position = Vector3(10, 0, 0)
	game.selected_entity_by_peer[1] = "10108"
	game.ball.freeze = false
	game.ball.global_position = Vector3(0, game.BALL_RADIUS, 0)
	game.ball.linear_velocity = Vector3.ZERO
	game.ball_owner_name = passer.name
	game._handle_ball_action(0, passer.name, Vector3.RIGHT, 0.5, 0.0, "pass", true, false, safe.name)
	if not _check(game.pass_receiver_name == safe.name and game.cross_run_assignments.has(safe.name), "A short-pass receiver was not assigned to meet the ball."):
		return
	var receive_input: Dictionary = game.ai_input_for(safe, 0.016)
	if not _check(receive_input.get("world_move", Vector3.ZERO).x < -0.1, "The short-pass receiver did not move toward the incoming ball."):
		return
	game.clear_pass_selection()
	game.ai_input_for(safe, 0.016)
	if not _check(not game.cross_run_assignments.has(safe.name), "The receiver continued an intercepted pass run."):
		return

	game.ball_owner_name = passer.name
	defender.global_position = Vector3(0, 0, 3)
	interceptor.global_position = Vector3(0, 0, -2)
	if not _check(game._ai_tactical_state(defender) == game.AIState.PRESS and game._ai_tactical_state(interceptor) == game.AIState.COVER, "The defender between the carrier and goal did not take the press."):
		return
	game.selected_entity_by_peer[1] = defender.name
	if not _check(game._ai_tactical_state(interceptor) == game.AIState.PRESS, "AI failed to assist when the goal-side defender is human-controlled."):
		return
	game.selected_entity_by_peer[1] = "10108"

	defender.global_position = Vector3(0, 0, 6)
	interceptor.global_position = Vector3(20, 0, 30)
	var support_target: Vector3 = game._ai_support_target(safe, passer, Vector3(0, 0, 12), game._attack_sign(passer.team))
	if not _check(absf(support_target.x) > 1.0, "Supporting player did not move away from a blocked passing lane."):
		return
	support_target = game._ai_support_target(safe, passer, Vector3(0, 0, 45), game._attack_sign(passer.team))
	if not _check(support_target.z <= game._offside_line_progress(passer.team), "Supporting run crossed the offside line."):
		return

	keeper.global_position = Vector3(0, 0, -49.5)
	game.ball_owner_name = ""
	game.ball.global_position = Vector3(2, game.BALL_RADIUS, -48.5)
	game.ball.linear_velocity = Vector3(-45, 0, -12)
	game.ai_keeper_dive_cooldowns.clear()
	game.diving_peers.clear()
	keeper.set_diving_local(false, 0)
	game._try_ai_keeper_dive(keeper, game._attack_sign(keeper.team))
	if not _check(keeper.is_diving and keeper.get_node("CollisionShape3D").position.x < 0.0, "Keeper dived toward the ball's current position instead of its projected path."):
		return
	keeper.set_diving_local(false, 0)
	game.ai_keeper_dive_cooldowns.clear()
	game.diving_peers.clear()
	game.ball.linear_velocity = Vector3(45, 0, -12)
	game._try_ai_keeper_dive(keeper, game._attack_sign(keeper.team))
	if not _check(not keeper.is_diving, "Keeper dived for a shot projected to miss the goal."):
		return

	for player in players.get_children():
		if player is CharacterBody3D:
			player.global_position = Vector3(30, 0, 40 if player.team == manager.TEAM_BLUE else -40)
	passer.global_position = Vector3(23, 0, 31)
	safe.global_position = Vector3(0, 0, 38)
	game.ball.global_position = Vector3(23, game.BALL_RADIUS, 31)
	game.ball.linear_velocity = Vector3.ZERO
	game.ball_owner_name = passer.name
	game.ai_ball_action_cooldown_until = 0
	game.ai_action_cooldowns.clear()
	game.try_ai_ball_action(passer)
	if not _check(game.pass_receiver_name == safe.name and game.cross_run_assignments.has(safe.name) and game.ball.linear_velocity.y > 4.0, "Wide attacker did not cross to the available player in the box."):
		return
	game.ball_owner_name = passer.name
	safe.global_position.z = 45.0
	if not _check(game._best_cross_teammate(passer) == null, "AI chose an offside cross receiver."):
		return

	for player in players.get_children():
		if player is CharacterBody3D:
			player.global_position = Vector3(30, 0, 40 if player.team == manager.TEAM_BLUE else -40)
			player.velocity = Vector3.ZERO
	passer.global_position = Vector3.ZERO
	safe.global_position = Vector3(10, 0, 0)
	game._set_local_selection(players.get_node("10108"))
	game.cross_run_assignments.clear()
	game.clear_pass_selection()
	game.ball.freeze = true
	game.ball.global_position = Vector3(0, game.BALL_RADIUS, 0)
	game.ball.linear_velocity = Vector3.ZERO
	await physics_frame
	game.ball.freeze = false
	game.ball_owner_name = passer.name
	game._handle_ball_action(0, passer.name, Vector3.RIGHT, 0.3, 0.0, "pass", true, false, safe.name)
	safe.set_physics_process(true)
	var received := false
	for _frame in range(150):
		await physics_frame
		if game.ball_owner_name == safe.name or game.last_ball_actor_name == safe.name:
			received = true
			break
	safe.set_physics_process(false)
	if not _check(received, "The AI receiver did not reach a short pass in the physics simulation."):
		return
	if not _check(game.get_local_selected_player() == safe and safe.selection_ring.visible, "The human team did not take control of the physical pass receiver."):
		return

	manager.roster = {1: {"team": manager.TEAM_BLUE, "role": manager.ROLE_PLAYER, "username": "Test"}}
	game._set_local_selection(players.get_node("10008"))
	game.ball.freeze = true
	safe.global_position = Vector3(0, 0, 38)
	game.ball.global_position = Vector3(0, 1.95, 37)
	game.ball.linear_velocity = Vector3.ZERO
	await physics_frame
	game.ball.freeze = false
	game.ball_owner_name = ""
	game.last_ball_actor_name = passer.name
	game.last_kick_control_until = 0
	game.ball.linear_velocity = Vector3(0, 0, 7)
	var headed := false
	for _frame in range(60):
		await physics_frame
		if game.last_ball_actor_name == safe.name and game.ball.linear_velocity.z > 10.0:
			headed = true
			break
	if not _check(headed, "AI did not head an incoming ball toward goal on contact."):
		return
	var controlled := players.get_node("10008") as CharacterBody3D
	game.ball.global_position = controlled.global_position + Vector3(0, 1.6, 0)
	game.ball.linear_velocity = Vector3(0, 0, 7)
	if not _check(not game._try_ai_header(controlled, passer.name), "AI automatically headed for the selected human player."):
		return
	game.ball.global_position = safe.global_position + Vector3(0, 2.8, 0)
	game.ball.linear_velocity = Vector3(0, -1, 0)
	if not _check(game._ai_should_jump_for_ball(safe) and not game._ai_should_jump_for_ball(controlled), "AI did not reserve the aerial jump for an unselected player near the ball."):
		return
	print("Match tactics tests passed.")
	world.queue_free()
	await process_frame
	quit(0)
