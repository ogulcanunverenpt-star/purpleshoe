extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
		quit(1)
	return condition

func _run() -> void:
	if change_scene_to_file("res://match.tscn") != OK:
		push_error("Could not load match scene.")
		quit(1)
		return
	for _frame in range(5):
		await process_frame
	var world := current_scene
	var game := world.get_node("FootballMatchController")
	var players := world.get_node("players")
	var manager := root.get_node("MatchManager")
	var kickoff_player := players.get_node_or_null("10108") as CharacterBody3D
	if not _check(kickoff_player != null and kickoff_player.global_position.distance_to(Vector3(0, 0, -0.85)) < 0.1, "Initial kickoff player is not at the ball: %s" % (kickoff_player.global_position if kickoff_player else "missing")):
		return
	if not _check(game.ball.freeze and game.kickoff_team == manager.TEAM_RED, "Initial kickoff is not ready."):
		return
	for child in players.get_children():
		if child is CharacterBody3D:
			child.set_physics_process(false)
			child.set_process(false)
			var slot: int = child.field_slot
			child.global_position = Vector3(-30.0 + float((slot + 1) % 10) * 5.0, 0.0, 35.0 if child.team == manager.TEAM_BLUE else -35.0)
	game.set_physics_process(false)
	game.kickoff_team = -1
	game.kickoff_delay = 0.0
	game.ball.freeze = false
	game.ball.global_position = Vector3(0.0, 0.11, 0.0)
	var actor := players.get_node("10008") as CharacterBody3D
	var receiver := players.get_node("10007") as CharacterBody3D
	var other := players.get_node("10009") as CharacterBody3D
	actor.global_position = Vector3.ZERO
	receiver.global_position = Vector3(8.0, 0.0, 0.0)
	other.global_position = Vector3(0.0, 0.0, 8.0)
	game._set_local_selection(actor)
	game.controller_input_by_peer.clear()
	game.cross_run_assignments[actor.name] = {"position": Vector3(20, 0, 0), "expires": Time.get_ticks_msec() + 10000}
	var selected_input: Dictionary = game.server_input_for(actor)
	if not _check(not selected_input.is_empty() and selected_input.get("move") == Vector2.ZERO, "Selected player was handed to the AI before input arrived."):
		return
	game.cross_run_assignments.clear()
	if not _check(game.can_local_shoot(), "Nearby selected player cannot pass or shoot."):
		return
	if not _check(game._pass_receiver(actor, Vector3.RIGHT, 30.0) == receiver, "Pass assist chose the wrong teammate."):
		return
	game._handle_ball_action(1, actor.name, Vector3.RIGHT, 0.5, 0.0, "pass")
	if not _check(game.ball.linear_velocity.x > 5.0 and absf(game.ball.linear_velocity.z) < 0.1, "Pass was not kicked toward the selected teammate."):
		return
	var pass_velocity: Vector3 = game.ball.linear_velocity
	game.update_player_dribble(actor, Vector3.RIGHT, 0.016)
	if not _check(game.ball.linear_velocity.is_equal_approx(pass_velocity), "The passer immediately intercepted their own pass."):
		return
	game.ball.linear_velocity = Vector3.ZERO
	game.ball.global_position = Vector3(0, 0.11, 0)
	var down := InputEventKey.new()
	down.keycode = KEY_DOWN
	down.pressed = true
	Input.parse_input_event(down)
	var pass_key := InputEventKey.new()
	pass_key.keycode = KEY_S
	pass_key.pressed = true
	Input.parse_input_event(pass_key)
	await process_frame
	actor._update_match_action_charge(0.5)
	pass_key.pressed = false
	Input.parse_input_event(pass_key)
	await process_frame
	actor._update_match_action_charge(0.0)
	down.pressed = false
	Input.parse_input_event(down)
	if not _check(game.ball.linear_velocity.x > 5.0, "S and the direction keys did not produce a pass."):
		return
	receiver.contact_impulse = Vector3.ZERO
	game._on_ball_body_entered(receiver)
	if not _check(receiver.contact_impulse.is_zero_approx(), "Receiving a pass knocked over the teammate."):
		return
	actor.global_position = Vector3.ZERO
	other.global_position = Vector3.ZERO
	game._resolve_player_contacts()
	if not _check(actor.global_position.distance_to(other.global_position) >= game.PLAYER_SEPARATION - 0.001, "Overlapping teammates were not separated."):
		return
	if not _check(game._teammate_avoidance(actor).length_squared() > 0.01, "AI does not avoid nearby teammates."):
		return
	print("PASS: kickoff, keyboard passing, first touch and player separation")
	quit(0)
