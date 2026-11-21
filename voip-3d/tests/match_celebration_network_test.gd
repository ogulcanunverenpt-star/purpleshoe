extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _fail(message: String) -> void:
	push_error(message)
	quit(1)

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var is_host := args[0] == "host"
	var port := int(args[1])
	var manager := root.get_node("MatchManager")
	var peer := ENetMultiplayerPeer.new()
	if is_host:
		if peer.create_server(port, 2) != OK:
			_fail("Could not start celebration test server.")
			return
		root.multiplayer.multiplayer_peer = peer
		manager.start_server(manager.TEAM_RED, manager.ROLE_PLAYER, "Host", false, 5, manager.MODE_MATCH, true)
		manager.match_scene_ready[1] = true
	else:
		manager.start_client(manager.TEAM_BLUE, manager.ROLE_PLAYER, "Client", manager.MODE_MATCH, "", true)
		if peer.create_client("127.0.0.1", port) != OK:
			_fail("Could not connect celebration test client.")
			return
		root.multiplayer.multiplayer_peer = peer
		for attempt in range(1200):
			if manager.local_team() == manager.TEAM_BLUE:
				break
			await create_timer(0.05).timeout
		if manager.local_team() != manager.TEAM_BLUE:
			_fail("Celebration test client did not join.")
			return
	if change_scene_to_file("res://match.tscn") != OK:
		_fail("Could not load match scene.")
		return
	for attempt in range(1200):
		if not is_host and peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
			_fail("Celebration test client disconnected while loading the lineup.")
			return
		if manager.match_ready and current_scene.get_node("players").has_node("10105") \
				and current_scene.get_node("players").has_node("10005"):
			break
		await create_timer(0.05).timeout
	var world := current_scene
	var players := world.get_node("players")
	if not manager.match_ready or not players.has_node("10105") or not players.has_node("10005"):
		_fail("Celebration test lineup was not synchronized.")
		return
	var game := world.get_node("FootballMatchController")
	var scorer := players.get_node("10105") as CharacterBody3D
	for player in players.get_children():
		player.set_physics_process(false)
	if is_host:
		game.set_physics_process(false)
		var client_player := players.get_node("10005") as CharacterBody3D
		var client_id: int = client_player.controller_peer_id
		for attempt in range(1200):
			if not is_instance_valid(client_player):
				_fail("Celebration test client disconnected.")
				return
			if game.selected_entity_by_peer.get(client_id, "") == "10005":
				break
			await create_timer(0.05).timeout
		if game.selected_entity_by_peer.get(client_id, "") != "10005":
			_fail("Celebration test client was not ready.")
			return
		for player in players.get_children():
			if player is CharacterBody3D and player.team == manager.TEAM_RED:
				player.global_position = Vector3(20, 0, 20)
		scorer.global_position = Vector3.ZERO
		players.get_node("10101").global_position = Vector3(2, 0, 0)
		players.get_node("10102").global_position = Vector3(-2, 0, 0)
		players.get_node("10103").global_position = Vector3(0, 0, 2)
		game.last_ball_actor_name = scorer.name
		game._score_goal(manager.TEAM_RED)
		var duration: float = maxf(scorer.goal_celebration_duration(StringName(scorer.current_animation)), scorer.goal_celebration_duration(&"goal_victory"))
		await create_timer(duration + 1.2).timeout
		if game.goal_celebration_active or game.kickoff_team != manager.TEAM_BLUE or not game.ball.freeze:
			_fail("Host did not prepare a human kickoff after the celebration.")
			return
		for attempt in range(1200):
			if game.controller_input_by_peer.get(client_id, {}).get("move", Vector2.ZERO) == Vector2.DOWN:
				break
			await create_timer(0.05).timeout
		if game.controller_input_by_peer.get(client_id, {}).get("move", Vector2.ZERO) != Vector2.DOWN:
			_fail("Client did not acknowledge the restored kickoff.")
			return
		for attempt in range(1200):
			if game.kickoff_team == -1 and not game.ball.freeze:
				break
			await create_timer(0.05).timeout
		if game.kickoff_team != -1 or game.ball.freeze:
			_fail("Client did not take the kickoff.")
			return
		print("PASS host goal celebration and human kickoff")
		for attempt in range(100):
			if root.multiplayer.get_peers().is_empty():
				break
			await create_timer(0.05).timeout
		world.queue_free()
		await process_frame
		quit(0)
		return
	game._set_local_selection(players.get_node("10005"))
	game.request_entity_selection.rpc_id(1, "10005", game.local_possession_selection_revision)
	for attempt in range(1200):
		if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
			_fail("Celebration test client disconnected before the goal.")
			return
		if game.goal_celebration_active:
			break
		await create_timer(0.05).timeout
	if not game.goal_celebration_active:
		_fail("Goal celebration did not reach the client.")
		return
	var chosen := StringName(scorer.current_animation)
	if not game.FOOTBALL_MODEL_UTILS.GOAL_CELEBRATION_SCENES.has(chosen) \
			or scorer.animation_player.get_animation(chosen).loop_mode != Animation.LOOP_NONE:
		_fail("Client scorer did not start a non-looping dance.")
		return
	await create_timer(1.0).timeout
	var victories := 0
	for player in players.get_children():
		if player is CharacterBody3D and player.team == manager.TEAM_RED and player.current_animation == "goal_victory":
			victories += 1
	if victories != 3 or scorer.current_animation != String(chosen) or not game.goal_celebration_active:
		_fail("Client did not observe the scorer and three teammates celebrating.")
		return
	var duration: float = maxf(scorer.goal_celebration_duration(chosen), scorer.goal_celebration_duration(&"goal_victory"))
	await create_timer(duration + 1.0).timeout
	if game.goal_celebration_active or game.kickoff_team != manager.TEAM_BLUE or scorer.current_animation != "Idle" \
			or game.get_local_selected_player() != players.get_node("10008"):
		_fail("Client did not select the kickoff taker after the celebration.")
		return
	for attempt in range(5):
		game.submit_controller_input(players.get_node("10008"), Vector2.DOWN, 0.0, false, false)
		await create_timer(0.1).timeout
	game.request_ball_action(Vector3.FORWARD, 0.5, 0.0, "pass")
	for attempt in range(1200):
		if game.kickoff_team == -1:
			break
		await create_timer(0.05).timeout
	if game.kickoff_team != -1:
		_fail("Client kickoff was not accepted by the host.")
		return
	print("PASS client goal celebration, teammates and human kickoff")
	world.queue_free()
	await process_frame
	quit(0)
