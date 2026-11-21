extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _fail(message: String) -> void:
	push_error(message)
	quit(1)

func _run() -> void:
	Input.use_accumulated_input = false
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(0, 1) != OK:
		_fail("Could not start the local AI match server.")
		return
	root.multiplayer.multiplayer_peer = peer
	var manager := root.get_node("MatchManager")
	manager.start_server(manager.TEAM_RED, manager.ROLE_PLAYER, "Test", false, 5, manager.MODE_MATCH, false)
	if change_scene_to_file("res://match.tscn") != OK:
		_fail("Could not load the match.")
		return
	for _frame in range(10):
		await process_frame
	var world := current_scene
	var game := world.get_node("FootballMatchController")
	var players := world.get_node("players")
	var controlled := game.get_local_selected_player() as CharacterBody3D
	var lineup_size := 0
	for player in players.get_children():
		if player is CharacterBody3D:
			lineup_size += 1
	if not manager.match_ready or manager.local_team() != manager.TEAM_RED or manager.roster.size() != 1 \
			or lineup_size != 22 or controlled == null or controlled.team != manager.TEAM_RED:
		_fail("Human-versus-AI match did not start: ready=%s team=%s roster=%s lineup=%s selected=%s" % [manager.match_ready, manager.local_team(), manager.roster, lineup_size, controlled])
		return
	var starting_x := controlled.global_position.x
	var key := InputEventKey.new()
	key.keycode = KEY_DOWN
	key.pressed = true
	Input.parse_input_event(key)
	for _frame in range(60):
		await physics_frame
	key.pressed = false
	Input.parse_input_event(key)
	if controlled.global_position.x <= starting_x + 0.5 or game.get_local_selected_player() != controlled:
		_fail("The selected human player did not respond: start=%s position=%s selected=%s input=%s" % [starting_x, controlled.global_position, game.get_local_selected_player(), game.controller_input_by_peer])
		return
	game._auto_kickoff(15.0)
	if not game.ball.freeze or game.kickoff_team != manager.TEAM_RED:
		_fail("The human kickoff was taken automatically.")
		return
	controlled.global_position = Vector3(0, 0, game._own_half_sign(controlled.team) * 0.85)
	controlled.velocity = Vector3.ZERO
	controlled.match_movement_velocity = Vector3.ZERO
	game._handle_ball_action(1, controlled.name, Vector3.BACK, 0.5, 0.0, "pass")
	if game.ball.freeze or game.kickoff_team != -1:
		_fail("The human kickoff did not start play.")
		return
	var initial_ball: Vector3 = game.ball.global_position
	var max_ball_distance := 0.0
	var robot := players.get_node("10005") as CharacterBody3D
	var robot_start := robot.global_position
	var touched_actors := {}
	for _frame in range(900):
		await physics_frame
		max_ball_distance = maxf(max_ball_distance, game.ball.global_position.distance_to(initial_ball))
		if not game.last_ball_actor_name.is_empty():
			touched_actors[game.last_ball_actor_name] = true
	if max_ball_distance < 5.0 or robot.global_position.distance_to(robot_start) < 1.0 or touched_actors.size() < 2:
		_fail("AI match did not progress: ball distance=%s robot movement=%s actors=%s" % [max_ball_distance, robot.global_position.distance_to(robot_start), touched_actors.keys()])
		return
	print("PASS human-versus-AI match: ball distance=%s actors=%s" % [max_ball_distance, touched_actors.keys()])
	world.queue_free()
	await process_frame
	peer.close()
	quit(0)
