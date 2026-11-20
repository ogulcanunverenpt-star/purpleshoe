extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var port := int(OS.get_cmdline_user_args()[0])
	var net := root.get_node("NetJoin")
	var manager := root.get_node("MatchManager")
	var matrix := root.get_node("MatrixClient")
	if change_scene_to_file("res://character_select.tscn") != OK:
		_fail("Could not load character selection.")
		return
	await create_timer(0.2).timeout
	var scene := current_scene
	var result: Dictionary = net.create_client(
		"127.0.0.1", port, manager.TEAM_AUTO, manager.ROLE_PLAYER,
		"ConnectionTest", manager.MODE_OVERLAND, net.TRANSPORT_WEBSOCKET, "", false, false
	)
	if not result.get("ok", false):
		_fail("Could not initiate connection: %s" % result)
		return
	var error: String = await scene.call("_wait_for_world_connection")
	if not error.is_empty() or current_scene != scene or not manager.roster.has(scene.multiplayer.get_unique_id()):
		_fail("Successful join was not acknowledged: %s" % error)
		return
	manager.disconnect_client()
	await process_frame
	result = net.create_client(
		"127.0.0.1", port + 1, manager.TEAM_AUTO, manager.ROLE_PLAYER,
		"ConnectionTest", manager.MODE_OVERLAND, net.TRANSPORT_WEBSOCKET, "", false, false
	)
	if not result.get("ok", false):
		_fail("Could not initiate failed-connection test: %s" % result)
		return
	error = await scene.call("_wait_for_world_connection")
	await process_frame
	if error.is_empty() or current_scene != scene:
		_fail("Connection failure was not kept on the selection screen.")
		return
	manager.disconnect_client()
	manager.last_rejection = "The server connection was lost."
	matrix.user_id = "ConnectionTest"
	matrix.access_token = "test"
	change_scene_to_file("res://lobby.tscn")
	await create_timer(0.3).timeout
	if current_scene == null or current_scene.scene_file_path != "res://character_select.tscn":
		_fail("Logged-in lobby did not return to selection.")
		return
	if current_scene.get("status_label").text != "The server connection was lost.":
		_fail("Disconnect reason was lost during the lobby transition.")
		return
	change_scene_to_file("res://openworld/main.tscn")
	await create_timer(0.3).timeout
	var audio := root.get_node("AudioManager")
	current_scene.weather = load("res://openworld/weather3d.gd").new()
	current_scene.add_child(current_scene.weather)
	audio.play_weather_path("res://openworld/audio/rain.ogg")
	if audio.get("_weather_cur") == "":
		_fail("Could not start weather audio.")
		return
	change_scene_to_file("res://character_select.tscn")
	await create_timer(0.3).timeout
	if audio.get("_weather_cur") != "":
		_fail("Weather audio was not stopped when leaving the world.")
		return
	print("Open-world join and connection error handling passed.")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
