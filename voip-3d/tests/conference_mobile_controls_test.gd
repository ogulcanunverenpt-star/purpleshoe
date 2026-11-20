extends SceneTree

const SCENES := [
	"res://AloneInTheDusk/Scenes/Conference.tscn",
	"res://AloneInTheDusk/Scenes/ShowroomAssets.tscn",
]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for scene_path in SCENES:
		if change_scene_to_file(scene_path) != OK:
			_fail("Could not load %s." % scene_path)
			return
		await create_timer(0.5).timeout
		var scene := current_scene
		if scene == null:
			_fail("Scene did not load: %s." % scene_path)
			return
		for screen_size in [Vector2i(800, 360), Vector2i(360, 640)]:
			root.size = screen_size
			scene.call("_layout_mobile_controls")
			for _frame in range(3):
				await process_frame
			var controls: Array[Control] = [
				scene.get("ptt_buttons"),
				scene.get("mobile_portal_button"),
				scene.get("mobile_jump_button"),
				scene.get("mobile_joystick"),
				scene.get("mobile_aim_joystick"),
			]
			for control in controls:
				var rect := control.get_global_rect()
				if rect.position.x < 0 or rect.position.y < 0 or rect.end.x > screen_size.x or rect.end.y > screen_size.y:
					_fail("%s is outside %s in %s: %s" % [control.name, screen_size, scene_path, rect])
					return
			for i in range(controls.size()):
				for j in range(i + 1, controls.size()):
					if controls[i].get_global_rect().intersects(controls[j].get_global_rect()):
						_fail("%s overlaps %s in %s at %s." % [controls[i].name, controls[j].name, scene_path, screen_size])
						return
		var player: Node = scene.get("players").get_node_or_null(str(scene.multiplayer.get_unique_id()))
		if player == null:
			_fail("Local player was not spawned in %s." % scene_path)
			return
		var ptt := scene.get("ptt_button") as Button
		ptt.button_down.emit()
		if not player.get("ptt_touch_active"):
			_fail("PTT did not activate.")
			return
		ptt.button_up.emit()
		if player.get("ptt_touch_active"):
			_fail("PTT did not deactivate on release.")
			return
		ptt.button_down.emit()
		root.focus_exited.emit()
		if player.get("ptt_touch_active"):
			_fail("PTT did not deactivate on focus loss.")
			return
		scene.call("_on_portal_body_entered", player, "lobby_park")
		var portal := scene.get("mobile_portal_button") as Button
		if scene.get("nearby_portal") != "lobby_park" or portal.text != "E · ENTER LOBBY":
			_fail("Lobby portal interaction was not prepared.")
			return
		scene.call("_on_portal_body_exited", player, "lobby_park")
		if not scene.get("nearby_portal").is_empty() or portal.visible:
			_fail("Lobby portal interaction did not clear on exit.")
			return
		scene.call("_on_portal_body_entered", player, "lobby_park")
		portal.pressed.emit()
		await create_timer(0.3).timeout
		if current_scene == null or current_scene.scene_file_path != "res://lobby.tscn":
			_fail("Lobby portal button did not open the lobby.")
			return
	print("Conference mobile controls and portal interactions passed.")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
