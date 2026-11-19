extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _fail(message: String) -> void:
	push_error(message)
	quit(1)

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var port := int(args[0])
	var retry_team := args[1] == "blue"
	var manager := root.get_node("MatchManager")
	var join := root.get_node("NetJoin")
	root.get_node("MatrixClient").set_process(false)
	root.get_node("MatrixClient").access_token = ""
	root.get_node("MatrixClient").user_id = "BlueTest" if retry_team else "RedTest"
	if args[1] == "solo":
		var result: Dictionary = join.create_client("127.0.0.1", port, manager.TEAM_AUTO, manager.ROLE_PLAYER, "RedTest", manager.MODE_MATCH, join.TRANSPORT_WEBSOCKET)
		if not result.get("ok", false):
			_fail("Solo portal could not connect.")
			return
		for _frame in range(600):
			await create_timer(0.025).timeout
			if manager.match_ready and current_scene and current_scene.scene_file_path == "res://match.tscn":
				var players := current_scene.get_node("players")
				var blue := players.get_node_or_null("10008") as CharacterBody3D
				var red := players.get_node_or_null("10108") as CharacterBody3D
				if blue != null and red != null:
					if manager.match_multiplayer or manager.local_team() != manager.TEAM_RED or blue.controller_peer_id != 1 or red.controller_peer_id != root.multiplayer.get_unique_id():
						_fail("Solo portal did not assign the human and robot teams.")
						return
					print("PASS solo portal human versus robot")
					manager.disconnect_client()
					quit(0)
					return
		_fail("Solo portal match did not start.")
		return
	join.pending_match_connection = {"host": "127.0.0.1", "port": port, "token": "", "transport": join.TRANSPORT_WEBSOCKET}
	if change_scene_to_file("res://match_team_select.tscn") != OK:
		_fail("Team selection scene failed to load.")
		return
	for _frame in range(5):
		await process_frame
	var selection := current_scene
	if selection == null:
		_fail("Team selection scene did not become active.")
		return
	selection._choose_team(manager.TEAM_RED)
	if retry_team:
		for _frame in range(400):
			await create_timer(0.025).timeout
			if not selection.connecting and selection.connected:
				break
		if selection.connecting or not selection.status_label.text.contains("captain"):
			_fail("Taken team did not allow retry: %s" % selection.status_label.text)
			return
		selection._choose_team(manager.TEAM_BLUE)
	for _frame in range(600):
		await create_timer(0.025).timeout
		if manager.match_ready and current_scene and current_scene.scene_file_path == "res://match.tscn":
			var players := current_scene.get_node("players")
			var controlled := 0
			for child in players.get_children():
				if child is CharacterBody3D and child.team == manager.local_team() and child.controller_peer_id == root.multiplayer.get_unique_id():
					controlled += 1
			if controlled == 11 and players.get_child_count() >= 23:
				var game := current_scene.get_node("FootballMatchController")
				if not game.game_started:
					_fail("Both captains joined but match did not start.")
					return
				for _wait in range(120):
					await create_timer(0.025).timeout
					if game.get_local_selected_player() != null:
						break
				var selected := game.get_local_selected_player() as CharacterBody3D
				if selected == null:
					_fail("Captain could not select their player.")
					return
				var start: Vector3 = selected.global_position
				for _move in range(50):
					game.submit_controller_input(selected, Vector2.RIGHT, 0.0, false, false)
					await create_timer(0.025).timeout
				if selected.global_position.distance_to(start) < 1.0:
					_fail("Captain movement did not reach the server.")
					return
				print("PASS multiplayer team=%d controlled=%d" % [manager.local_team(), controlled])
				if not retry_team:
					for _wait in range(300):
						await create_timer(0.025).timeout
						if not manager.match_ready:
							print("PASS match pauses after opponent disconnects")
							break
					if manager.match_ready:
						_fail("Match did not pause after opponent disconnected.")
						return
				manager.disconnect_client()
				quit(0)
				return
	_fail("Match did not sync both lineups and captains.")
