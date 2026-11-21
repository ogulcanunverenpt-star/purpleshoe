extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
		quit(1)
	return condition

func _tap_q(game: Node) -> void:
	var key := InputEventKey.new()
	key.keycode = KEY_Q
	key.pressed = true
	Input.parse_input_event(key)
	await process_frame
	game._process_selection_keys()
	key.pressed = false
	Input.parse_input_event(key)
	await process_frame
	game._process_selection_keys()

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
	manager.roster.erase(2)
	game.set_process(false)
	game.set_physics_process(false)
	for player in players.get_children():
		player.set_process(false)
		player.set_physics_process(false)
		if player is CharacterBody3D:
			player.global_position = Vector3(30, 0, 40 if player.team == manager.TEAM_BLUE else -40)
	var passer := players.get_node("10005") as CharacterBody3D
	var receiver := players.get_node("10006") as CharacterBody3D
	var nearby := players.get_node("10004") as CharacterBody3D
	var opponent := players.get_node("10100") as CharacterBody3D
	passer.global_position = Vector3.ZERO
	receiver.global_position = Vector3(10, 0, 0)
	nearby.global_position = Vector3(0, 0, 4)
	game.game_started = true
	game.kickoff_team = -1
	game.kickoff_delay = 0.0
	game.ball.freeze = true
	game.ball.global_position = Vector3(0, game.BALL_RADIUS, 0)
	game.ball.linear_velocity = Vector3.ZERO
	game.ball_owner_name = passer.name
	game._set_local_selection(passer)
	game._handle_ball_action(1, passer.name, Vector3.RIGHT, 0.5, 0.0, "pass")
	if not _check(game.pass_receiver_name == receiver.name and game.ball_owner_name.is_empty(), "Pass receiver was not recorded: receiver=%s owner=%s selected=%s set_piece=%s" % [game.pass_receiver_name, game.ball_owner_name, game.selected_entity_by_peer, game.set_piece_active]):
		return
	await _tap_q(game)
	if not _check(game.get_local_selected_player() == receiver and receiver.selection_ring.visible and not passer.selection_ring.visible, "Q did not select the pass receiver and move the ring."):
		return
	game.submit_controller_input(receiver, Vector2.RIGHT, 0.0, false, false)
	if not _check(game.selected_entity_by_peer[1] == receiver.name and game.server_input_for(receiver).get("move") == Vector2.RIGHT, "Control did not move to the selected receiver."):
		return
	game._set_local_selection(passer)
	game.ball_owner_name = ""
	game.ball.global_position = receiver.global_position + Vector3(0, game.BALL_RADIUS, 0)
	game._on_ball_body_entered(receiver)
	if not _check(game.get_local_selected_player() == receiver and receiver.selection_ring.visible, "Control did not move to a teammate touching the ball."):
		return
	game._set_local_selection(passer)
	game.ball_owner_name = passer.name
	game.ball.global_position = Vector3(0, game.BALL_RADIUS, 0)
	game._handle_ball_action(1, passer.name, Vector3.RIGHT, 0.5, 0.0, "pass")
	game._set_local_selection(nearby)
	game.ball.global_position = receiver.global_position + Vector3(0, game.BALL_RADIUS, 0)
	game._on_ball_body_entered(receiver)
	if not _check(game.get_local_selected_player() == receiver, "Receiving the ball did not override the earlier manual selection."):
		return
	game.ball_owner_name = receiver.name
	game.ai_ball_action_cooldown_until = 0
	game.ai_action_cooldowns.clear()
	var action_serial: int = game.ball_action_serial
	game.try_ai_ball_action(receiver)
	if not _check(game.ball_owner_name == receiver.name and game.ball_action_serial == action_serial, "The human-controlled player acted on the ball automatically."):
		return
	game._set_local_selection(passer)
	game.ball_owner_name = passer.name
	game.ball.global_position = Vector3(0, game.BALL_RADIUS, 0)
	game._handle_ball_action(1, passer.name, Vector3.RIGHT, 0.5, 0.0, "pass")
	game._on_ball_body_entered(opponent)
	if not _check(game.pass_receiver_name.is_empty(), "An opponent's interception did not cancel the pass target."):
		return
	await _tap_q(game)
	if not _check(game.get_local_selected_player() == nearby, "Q did not select the nearest other teammate after an interception."):
		return
	game.ball_owner_name = opponent.name
	game._follow_pass_receiver_selection()
	if not _check(game.get_local_selected_player() == nearby, "An opponent taking the ball changed the local selection."):
		return
	game.ball_owner_name = ""
	game.last_ball_actor_name = opponent.name
	game.ball.global_position = nearby.global_position + Vector3(0, game.BALL_RADIUS, 0)
	game._on_ball_body_entered(nearby)
	if not _check(game.get_local_selected_player() == nearby and nearby.selection_ring.visible, "An intercepted ball did not select the winning teammate."):
		return
	game.ball_owner_name = ""
	game.last_ball_actor_name = opponent.name
	game.last_kick_control_until = 0
	game.ball.global_position = receiver.global_position + Vector3(0.3, game.BALL_RADIUS, 0)
	game.ball.linear_velocity = Vector3.ZERO
	game._clear_offside_state()
	game.update_player_dribble(receiver, Vector3.ZERO, 0.016)
	if not _check(game.ball_owner_name == receiver.name and game.get_local_selected_player() == receiver, "Gaining control without a collision did not select the new holder."):
		return
	var keeper := players.get_node("10010") as CharacterBody3D
	game.ball_owner_name = ""
	game.last_ball_actor_name = opponent.name
	game._on_ball_body_entered(keeper)
	if not _check(game.get_local_selected_player() == keeper and keeper.selection_ring.visible, "A goalkeeper's touch did not transfer human control."):
		return
	game.kickoff_team = manager.TEAM_BLUE
	game.ball.freeze = true
	game.reset_players_for_kickoff(game.kickoff_team)
	game._auto_kickoff(15.0)
	if not _check(game.ball.freeze and game.kickoff_team == manager.TEAM_BLUE and game.get_local_selected_player().field_slot == 8, "A human kickoff was taken automatically or its taker was not selected."):
		return
	game.kickoff_team = -1
	game._start_free_kick(Vector3(0, game.BALL_RADIUS, 0), manager.TEAM_BLUE, "FREE KICK")
	game.kickoff_delay = 0.0
	game._physics_process(30.0)
	if not _check(game.set_piece_active and game.ball.freeze, "A human set piece was taken automatically after the timeout."):
		return
	var human_taker := players.get_node(game.set_piece_taker_name) as CharacterBody3D
	var human_camera := human_taker.get_node("Camera3D") as Camera3D
	human_taker._refresh_match_spawn_properties()
	if not _check(human_taker.set_piece_aiming and human_camera.is_current(), "The human set-piece camera did not stay active after a player refresh."):
		return
	game._clear_set_piece()
	if not _check(world.stadium_camera.is_current(), "The stadium camera was not restored after the human set piece."):
		return
	game._start_free_kick(Vector3(0, game.BALL_RADIUS, 0), manager.TEAM_RED, "FREE KICK")
	var ai_taker := players.get_node(game.set_piece_taker_name) as CharacterBody3D
	if not _check(is_instance_valid(world.set_piece_view_camera) and world.set_piece_view_camera.is_current() \
			and world.set_piece_view_camera.get_parent() == ai_taker \
			and world.set_piece_view_camera.position == ai_taker.SET_PIECE_CAMERA_POSITION \
			and world.set_piece_view_camera.rotation.is_equal_approx(ai_taker.SET_PIECE_CAMERA_ROTATION), "The AI set piece did not use the behind-player camera."):
		return
	game._clear_set_piece()
	if not _check(world.stadium_camera.is_current(), "The stadium camera was not restored after the AI set piece."):
		return
	game.kickoff_team = manager.TEAM_RED
	game.ball.freeze = true
	game.ball.global_position = game.BALL_START
	game.reset_players_for_kickoff(game.kickoff_team)
	game._auto_kickoff(15.0)
	if not _check(not game.ball.freeze and game.kickoff_team == -1, "The AI team did not take its kickoff."):
		return
	print("PASS Q selection, pass receiver, nearest teammate and interception")
	await create_timer(1.0).timeout
	world.queue_free()
	await process_frame
	quit(0)
