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
			_fail("Could not start test server.")
			return
		root.multiplayer.multiplayer_peer = peer
		manager.start_server(manager.TEAM_RED, manager.ROLE_PLAYER, "Host", false, 5, manager.MODE_MATCH, true)
		manager.match_scene_ready[1] = true
	else:
		manager.start_client(manager.TEAM_BLUE, manager.ROLE_PLAYER, "Client", manager.MODE_MATCH, "", true)
		if peer.create_client("127.0.0.1", port) != OK:
			_fail("Could not connect test client.")
			return
		root.multiplayer.multiplayer_peer = peer
		for _attempt in range(300):
			if manager.local_team() == manager.TEAM_BLUE:
				break
			await create_timer(0.05).timeout
		if manager.local_team() != manager.TEAM_BLUE:
			_fail("Client did not join the blue team.")
			return
	if change_scene_to_file("res://match.tscn") != OK:
		_fail("Could not load match scene.")
		return
	for _attempt in range(300):
		if manager.match_ready and current_scene.get_node("players").has_node("10006"):
			break
		await create_timer(0.05).timeout
	var world := current_scene
	var players := world.get_node("players")
	if not manager.match_ready or not players.has_node("10006"):
		_fail("Match lineup was not synchronized.")
		return
	var game := world.get_node("FootballMatchController")
	var passer := players.get_node("10005") as CharacterBody3D
	var receiver := players.get_node("10006") as CharacterBody3D
	var next_receiver := players.get_node("10004") as CharacterBody3D
	var host_receiver := players.get_node("10104") as CharacterBody3D
	for player in players.get_children():
		player.set_physics_process(false)
	if is_host:
		game.set_physics_process(false)
		game.ball.collision_mask = 0
		for _attempt in range(300):
			if game.selected_entity_by_peer.get(passer.controller_peer_id, "") == passer.name:
				break
			await create_timer(0.05).timeout
		if game.selected_entity_by_peer.get(passer.controller_peer_id, "") != passer.name:
			_fail("Client selection did not reach the server.")
			return
		game.start_ball_action.rpc(Vector3.RIGHT * 10.0, 0.0, "pass", passer.name, receiver.name)
		for _attempt in range(300):
			if not is_instance_valid(receiver):
				_fail("Client disconnected before completing selection.")
				return
			if game.selected_entity_by_peer.get(receiver.controller_peer_id, "") == receiver.name \
					and game.controller_input_by_peer.get(receiver.controller_peer_id, {}).get("move", Vector2.ZERO) == Vector2.RIGHT:
				print("PASS server received receiver selection and input")
				break
			await create_timer(0.05).timeout
		if game.selected_entity_by_peer.get(receiver.controller_peer_id, "") != receiver.name \
				or game.controller_input_by_peer.get(receiver.controller_peer_id, {}).get("move", Vector2.ZERO) != Vector2.RIGHT:
			_fail("Receiver selection or input did not reach the server.")
			return
		game.start_ball_action.rpc(Vector3.RIGHT * 10.0, 0.0, "pass", receiver.name, next_receiver.name)
		game._on_ball_body_entered(next_receiver)
		for _attempt in range(300):
			if game.selected_entity_by_peer.get(next_receiver.controller_peer_id, "") == next_receiver.name \
					and game.controller_input_by_peer.get(next_receiver.controller_peer_id, {}).get("move", Vector2.ZERO) == Vector2.DOWN:
				break
			await create_timer(0.05).timeout
		if game.selected_entity_by_peer.get(next_receiver.controller_peer_id, "") != next_receiver.name \
				or game.controller_input_by_peer.get(next_receiver.controller_peer_id, {}).get("move", Vector2.ZERO) != Vector2.DOWN:
			_fail("Automatic client possession selection or input did not reach the server.")
			return
		game.ball_owner_name = ""
		game.last_ball_actor_name = next_receiver.name
		game._on_ball_body_entered(host_receiver)
		if game.get_local_selected_player() != host_receiver or not host_receiver.selection_ring.visible:
			_fail("The host did not gain control after intercepting the ball.")
			return
		print("PASS server synchronized client possession and host interception")
		await create_timer(2.0).timeout
		quit(0)
	else:
		game.set_process(false)
		game._set_local_selection(passer)
		for _attempt in range(300):
			if game.pass_receiver_name == receiver.name:
				break
			await create_timer(0.05).timeout
		if game.pass_receiver_name != receiver.name:
			_fail("Pass receiver was not synchronized to the client.")
			return
		var key := InputEventKey.new()
		key.keycode = KEY_Q
		key.pressed = true
		Input.parse_input_event(key)
		await process_frame
		game._process_selection_keys()
		key.pressed = false
		Input.parse_input_event(key.duplicate())
		await process_frame
		game._process_selection_keys()
		if game.get_local_selected_player() != receiver:
			_fail("Client Q did not select the pass receiver: selected=%s owner=%s target=%s" % [game.get_local_selected_player(), game.ball_owner_name, game.pass_receiver_name])
			return
		for _attempt in range(10):
			game.submit_controller_input(receiver, Vector2.RIGHT, 0.0, false, false)
			await create_timer(0.05).timeout
		print("PASS client selected synchronized pass receiver")
		for _attempt in range(300):
			if game.get_local_selected_player() == next_receiver:
				break
			await create_timer(0.05).timeout
		if game.get_local_selected_player() != next_receiver or not next_receiver.selection_ring.visible:
			_fail("Client did not automatically select the teammate who received the ball.")
			return
		game.request_entity_selection.rpc_id(1, receiver.name, game.local_possession_selection_revision - 1)
		for _attempt in range(10):
			game.submit_controller_input(next_receiver, Vector2.DOWN, 0.0, false, false)
			await create_timer(0.05).timeout
		print("PASS client automatic possession selection and input")
		world.queue_free()
		await process_frame
		quit(0)
