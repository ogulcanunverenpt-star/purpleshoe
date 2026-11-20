extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if change_scene_to_file("res://character_select.tscn") != OK:
		push_error("Could not load character selection.")
		quit(1)
		return
	await create_timer(0.2).timeout
	if current_scene == null:
		push_error("Character selection did not become the current scene.")
		quit(1)
		return
	for screen_size in [Vector2i(800, 360), Vector2i(360, 640), Vector2i(1600, 900)]:
		root.size = screen_size
		current_scene.call("_layout_for_screen")
		current_scene.get("status_label").text = "Could not connect to the open world: The server did not respond. Please check the server address and try again."
		for _frame in range(3):
			await process_frame
		var button := current_scene.get("continue_button") as Button
		var rect := button.get_global_rect()
		if rect.position.x < 0 or rect.position.y < 0 or rect.end.x > screen_size.x or rect.end.y > screen_size.y:
			push_error("Character selection button is outside %s: %s" % [screen_size, rect])
			quit(1)
			return
	print("Character selection fits small and large screens.")
	quit()
