extends Node3D

const LOBBY_PLAYER_SCENE = preload("res://lobby_player.tscn")
const PARK_SPAWN_CENTER := Vector2(-48.0, 31.0)
const FARM_PORTAL_POSITION := Vector2(-53.0, 28.0)

@onready var players: Node3D = $Players
@onready var online_players_label: Label = $CanvasLayer/HUD/VBox/OnlinePlayersLabel
@onready var status_label: Label = $CanvasLayer/HUD/StatusLabel
@onready var mobile_jump_button: Button = $CanvasLayer/HUD/MobileJumpButton
@onready var mobile_portal_button: Button = $CanvasLayer/HUD/MobilePortalButton
@onready var mobile_aim_joystick: MobileVirtualJoystick = $CanvasLayer/HUD/MobileAimJoystick
@onready var mobile_aim_label: Label = $CanvasLayer/HUD/MobileAimLabel

var nearby_portal := ""
var portal_busy := false
var rain_particles: CPUParticles3D


func _ready() -> void:
	MatchManager.player_state_changed.connect(_on_player_state_changed)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	MatrixClient.matrix_auth_completed.connect(_on_matrix_auth_completed)
	var touch_device := _is_touch_device()
	mobile_jump_button.visible = touch_device
	mobile_aim_joystick.visible = touch_device
	mobile_aim_label.visible = touch_device
	mobile_portal_button.visible = false

	await get_tree().physics_frame
	_build_game_huts()
	_build_farm_portal()
	_build_lobby_portals()
	_spawn_existing_players()
	_setup_rain()
	_update_online_players()

	if MatrixClient.is_logged_in() and multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		call_deferred("_connect_to_plaza")
	elif not multiplayer.has_multiplayer_peer():
		_spawn_player(1)
	if not MatrixClient.matrix_auth_warning.is_empty():
		_show_matrix_auth_warning(MatrixClient.matrix_auth_warning)
		MatrixClient.matrix_auth_warning = ""


func _process(_delta: float) -> void:
	if not is_instance_valid(rain_particles) or not rain_particles.is_inside_tree():
		return
	var local_player := players.get_node_or_null(str(multiplayer.get_unique_id())) as Node3D
	if local_player:
		rain_particles.global_position = local_player.global_position + Vector3(0.0, 11.0, 0.0)


func _setup_rain() -> void:
	rain_particles = CPUParticles3D.new()
	rain_particles.name = "Rain"
	rain_particles.amount = 240
	rain_particles.lifetime = 1.15
	rain_particles.preprocess = 1.15
	rain_particles.emitting = true
	rain_particles.local_coords = true
	rain_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rain_particles.visibility_aabb = AABB(Vector3(-20.0, -20.0, -20.0), Vector3(40.0, 40.0, 40.0))
	rain_particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	rain_particles.emission_box_extents = Vector3(15.0, 6.0, 15.0)
	rain_particles.direction = Vector3(-0.12, -1.0, 0.08)
	rain_particles.spread = 5.0
	rain_particles.initial_velocity_min = 16.0
	rain_particles.initial_velocity_max = 20.0
	rain_particles.gravity = Vector3(0.0, -1.5, 0.0)
	rain_particles.scale_amount_min = 0.75
	rain_particles.scale_amount_max = 1.15
	rain_particles.color = Color(0.67, 0.78, 0.92, 0.55)

	var rain_mesh := QuadMesh.new()
	rain_mesh.size = Vector2(0.035, 0.45)
	var rain_material := StandardMaterial3D.new()
	rain_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rain_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rain_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	rain_material.albedo_color = Color(0.67, 0.78, 0.92, 0.55)
	rain_mesh.material = rain_material
	rain_particles.mesh = rain_mesh
	add_child(rain_particles)


func _on_matrix_auth_completed(success: bool, message: String) -> void:
	if not success:
		MatrixClient.matrix_auth_warning = ""
		_show_matrix_auth_warning(message)


func _show_matrix_auth_warning(message: String) -> void:
	var banner := PanelContainer.new()
	banner.name = "MatrixAuthWarning"
	banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	banner.offset_left = -290
	banner.offset_top = 24
	banner.offset_right = 290
	banner.offset_bottom = 104
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.19, 0.17, 0.27, 0.97)
	panel_style.border_color = Color(0.67, 0.56, 0.9)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(8)
	banner.add_theme_stylebox_override("panel", panel_style)
	var warning_label := Label.new()
	warning_label.text = message
	warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warning_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warning_label.add_theme_color_override("font_color", Color(0.95, 0.92, 1.0))
	warning_label.add_theme_font_size_override("font_size", 16)
	banner.add_child(warning_label)
	$CanvasLayer.add_child(banner)
	await get_tree().create_timer(8.0).timeout
	if is_instance_valid(banner):
		banner.queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E:
		if not nearby_portal.is_empty() and not portal_busy:
			get_viewport().set_input_as_handled()
			_enter_portal(nearby_portal)


func _is_touch_device() -> bool:
	return OS.has_feature("mobile") or OS.get_name() == "Android" or DisplayServer.is_touchscreen_available()


func _on_mobile_jump_button_pressed() -> void:
	var player := players.get_node_or_null(str(multiplayer.get_unique_id()))
	if player and player.has_method("jump"):
		player.call("jump")


func _on_mobile_portal_button_pressed() -> void:
	if not nearby_portal.is_empty() and not portal_busy:
		_enter_portal(nearby_portal)


func _on_ptt_button_down() -> void:
	var player := players.get_node_or_null(str(multiplayer.get_unique_id()))
	if player and "ptt_touch_active" in player:
		player.set("ptt_touch_active", true)


func _on_ptt_button_up() -> void:
	var player := players.get_node_or_null(str(multiplayer.get_unique_id()))
	if player and "ptt_touch_active" in player:
		player.set("ptt_touch_active", false)


func _connect_to_plaza() -> void:
	status_label.text = "Connecting to the shared farm square..."
	var room: Dictionary = await MatrixClient.join_shared_room("plaza")
	if not room.get("success", false):
		status_label.text = "Could not connect to the square: %s" % room.get("error", "The server did not respond.")
		return

	await get_tree().create_timer(1.0).timeout
	if not is_inside_tree():
		return

	MatchManager.preferred_mode = MatchManager.MODE_CONFERENCE
	var result := NetJoin.create_client(
		String(room.get("host", "192.168.1.9")),
		int(room.get("port", 12810)),
		MatchManager.TEAM_AUTO,
		MatchManager.ROLE_PLAYER,
		MatrixClient.local_username(),
		MatchManager.MODE_CONFERENCE,
		NetJoin.TRANSPORT_WEBSOCKET,
		String(room.get("token", ""))
	)
	if not result.get("ok", false):
		status_label.text = "Could not connect to the square: %s" % result.get("message", "Could not establish a connection.")


func _spawn_existing_players() -> void:
	for peer_id in MatchManager.roster:
		_spawn_player(int(peer_id))
	if MatchManager.roster.is_empty() and multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		_spawn_player(1)


func _spawn_player(peer_id: int) -> void:
	if peer_id <= 0 or players.has_node(str(peer_id)):
		return

	var player := LOBBY_PLAYER_SCENE.instantiate() as Node3D
	player.name = str(peer_id)
	var angle := float(peer_id) * 2.399963
	var x := PARK_SPAWN_CENTER.x + cos(angle) * 2.5
	var z := PARK_SPAWN_CENTER.y + sin(angle) * 2.5
	player.position = Vector3(x, _ground_height_at(x, z), z)
	players.add_child(player, true)
	for existing_player in players.get_children():
		if existing_player.is_multiplayer_authority() and existing_player.has_method("publish_avatar_selection"):
			existing_player.call_deferred("publish_avatar_selection")


func _on_player_state_changed(peer_id: int, team: int, _role: int, _username: String) -> void:
	if team < 0:
		_remove_player(peer_id)
	else:
		_spawn_player(peer_id)
	_update_online_players()


func _on_peer_disconnected(peer_id: int) -> void:
	_remove_player(peer_id)
	_update_online_players()


func _remove_player(peer_id: int) -> void:
	var player := players.get_node_or_null(str(peer_id))
	if player:
		player.queue_free()


func _update_online_players() -> void:
	var names: Array[String] = []
	for peer_id in MatchManager.roster:
		names.append(MatchManager.username_for_peer(int(peer_id)))
	online_players_label.text = "FARM SQUARE · %d PLAYERS" % names.size()
	if not names.is_empty():
		online_players_label.text += "\n" + " · ".join(names)
	if nearby_portal.is_empty():
		status_label.text = "Move with the left joystick · Look around with the right joystick" if _is_touch_device() else "WASD: move · V: push to talk · E: use portal"


func _build_game_huts() -> void:
	_build_hut("MatchHut", "MATCH PORTAL", Vector3(-12.0, 0.0, 0.0), "match", Color(0.18, 0.43, 0.86))
	_build_hut("FreeKickHut", "FREE KICK", Vector3(12.0, 0.0, 0.0), "free_kick", Color(0.16, 0.78, 0.54))


func _build_hut(hut_name: String, title: String, location: Vector3, portal_id: String, glow: Color) -> void:
	var hut := Node3D.new()
	hut.name = hut_name
	hut.position = Vector3(location.x, _ground_height_at(location.x, location.z), location.z)
	add_child(hut)

	_add_box(hut, "Foundation", Vector3(0, 0.18, 0), Vector3(6.0, 0.36, 5.0), Color(0.34, 0.28, 0.21))
	_add_box(hut, "BackWall", Vector3(0, 1.7, -2.25), Vector3(5.6, 3.0, 0.35), Color(0.49, 0.31, 0.18))
	_add_box(hut, "LeftWall", Vector3(-2.65, 1.7, 0), Vector3(0.35, 3.0, 4.8), Color(0.56, 0.36, 0.2))
	_add_box(hut, "RightWall", Vector3(2.65, 1.7, 0), Vector3(0.35, 3.0, 4.8), Color(0.56, 0.36, 0.2))
	_add_box(hut, "LeftRoof", Vector3(-1.45, 3.25, 0), Vector3(3.35, 0.38, 5.5), Color(0.3, 0.13, 0.11), Vector3(0, 0, deg_to_rad(-28.0)))
	_add_box(hut, "RightRoof", Vector3(1.45, 3.25, 0), Vector3(3.35, 0.38, 5.5), Color(0.3, 0.13, 0.11), Vector3(0, 0, deg_to_rad(28.0)))
	_add_box(hut, "Door", Vector3(0, 1.15, -2.02), Vector3(1.45, 2.25, 0.12), Color(0.22, 0.13, 0.08))

	var sign := Label3D.new()
	sign.text = title
	sign.position = Vector3(0, 4.3, 2.65)
	sign.font_size = 48
	sign.outline_size = 10
	sign.modulate = glow.lightened(0.25)
	sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	hut.add_child(sign)

	var portal_position := hut.position + Vector3(0, 0.0, 3.35)
	_create_portal(portal_id, portal_position, glow)


func _build_farm_portal() -> void:
	var portal_ground := _ground_height_at(FARM_PORTAL_POSITION.x, FARM_PORTAL_POSITION.y)
	_create_portal("farm", Vector3(FARM_PORTAL_POSITION.x, portal_ground, FARM_PORTAL_POSITION.y), Color(0.9, 0.66, 0.2))
	var sign_post := Node3D.new()
	sign_post.name = "FarmPortalSign"
	sign_post.position = Vector3(FARM_PORTAL_POSITION.x, portal_ground, FARM_PORTAL_POSITION.y - 2.0)
	add_child(sign_post)
	_add_box(sign_post, "SignPostLeft", Vector3(-1.45, 1.2, 0), Vector3(0.16, 2.4, 0.16), Color(0.28, 0.17, 0.1))
	_add_box(sign_post, "SignPostRight", Vector3(1.45, 1.2, 0), Vector3(0.16, 2.4, 0.16), Color(0.28, 0.17, 0.1))
	_add_box(sign_post, "SignBoard", Vector3(0, 2.15, 0), Vector3(4.2, 1.15, 0.24), Color(0.39, 0.24, 0.13))
	var sign := Label3D.new()
	sign.text = "VOICE CHAT FARM"
	sign.position = Vector3(0, 2.15, 0.14)
	sign.font_size = 32
	sign.outline_size = 8
	sign.modulate = Color(1.0, 0.83, 0.42)
	sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sign_post.add_child(sign)


func _build_lobby_portals() -> void:
	var park_position := Vector2(-40.0, 31.0)
	var park_frame := _create_portal(
		"lobby_park",
		Vector3(park_position.x, _ground_height_at(park_position.x, park_position.y), park_position.y),
		Color(0.53, 0.82, 1.0)
	)
	_add_portal_label(park_frame, "GAME LOBBY")

	var messages_position := Vector2(-61.0, 31.0)
	var messages_frame := _create_portal(
		"messages",
		Vector3(messages_position.x, _ground_height_at(messages_position.x, messages_position.y), messages_position.y),
		Color(0.62, 0.52, 0.88)
	)
	_add_portal_label(messages_frame, "MESSAGES")

	var bridge := get_node_or_null("prefab (#3)/Bridge_prefab (#1)/Bridge_prefab") as Node3D
	if bridge:
		var bridge_frame := _create_portal("lobby_bridge", Vector3(0.0, -0.12, 12.0), Color(0.53, 0.82, 1.0), bridge)
		_add_portal_label(bridge_frame, "GAME LOBBY")
	else:
		push_warning("Bridge prefab lobby portal target is missing")


func _add_portal_label(portal: Node3D, text: String) -> void:
	var sign := Label3D.new()
	sign.text = text
	sign.position = Vector3(0, 3.1, 0)
	sign.font_size = 36
	sign.outline_size = 8
	sign.modulate = Color(0.72, 0.9, 1.0)
	sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	portal.add_child(sign)


func _create_portal(portal_id: String, position: Vector3, glow: Color, parent: Node3D = null) -> Node3D:
	var frame := Node3D.new()
	frame.name = "%sPortal" % portal_id.capitalize()
	frame.position = position
	var portal_parent: Node3D = self
	if parent:
		portal_parent = parent
	portal_parent.add_child(frame)
	_add_box(frame, "Glow", Vector3(0, 1.15, 0), Vector3(1.65, 2.25, 0.16), Color(glow.r, glow.g, glow.b, 0.4), Vector3.ZERO, true)
	_add_box(frame, "LeftPost", Vector3(-1.05, 1.2, 0), Vector3(0.22, 2.5, 0.28), glow, Vector3.ZERO, true)
	_add_box(frame, "RightPost", Vector3(1.05, 1.2, 0), Vector3(0.22, 2.5, 0.28), glow, Vector3.ZERO, true)
	_add_box(frame, "Header", Vector3(0, 2.42, 0), Vector3(2.3, 0.22, 0.28), glow, Vector3.ZERO, true)

	var area := Area3D.new()
	area.name = "InteractionArea"
	area.position = Vector3(0, 1.1, 0)
	area.collision_layer = 0
	area.collision_mask = 1
	var shape_node := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(2.2, 2.4, 1.5)
	shape_node.shape = shape
	area.add_child(shape_node)
	frame.add_child(area)
	area.body_entered.connect(_on_portal_body_entered.bind(portal_id))
	area.body_exited.connect(_on_portal_body_exited.bind(portal_id))
	return frame


func _on_portal_body_entered(body: Node3D, portal_id: String) -> void:
	if body.get_multiplayer_authority() != multiplayer.get_unique_id():
		return
	nearby_portal = portal_id
	var title := "free kick"
	if portal_id == "farm":
		title = "farm"
	elif portal_id.begins_with("lobby_"):
		title = "lobby"
	elif portal_id == "match":
		title = "match"
	elif portal_id == "messages":
		title = "messages"
	status_label.text = "E · Enter %s" % title
	mobile_portal_button.text = "ENTER %s" % title.to_upper()
	mobile_portal_button.visible = _is_touch_device()


func _on_portal_body_exited(body: Node3D, portal_id: String) -> void:
	if body.get_multiplayer_authority() == multiplayer.get_unique_id() and nearby_portal == portal_id:
		nearby_portal = ""
		mobile_portal_button.visible = false
		_update_online_players()


func _enter_portal(portal_id: String) -> void:
	if portal_id == "messages":
		var current_scene := get_tree().current_scene
		NetJoin.webview_return_scene = current_scene.scene_file_path if current_scene else ""
		var result := get_tree().change_scene_to_file("res://webview_main.tscn")
		if result != OK:
			NetJoin.webview_return_scene = ""
			status_label.text = "Could not open messages: %s" % error_string(result)
		return
	if portal_id == "farm":
		get_tree().change_scene_to_file("res://building_lobby.tscn")
		return
	if portal_id.begins_with("lobby_"):
		MatrixClient.open_lobby_from_game = true
		var result := get_tree().change_scene_to_file("res://lobby.tscn")
		if result != OK:
			MatrixClient.open_lobby_from_game = false
			status_label.text = "Could not open lobby: %s" % error_string(result)
		return

	portal_busy = true
	var room_mode := "match" if portal_id == "match" else "free_kick"
	status_label.text = "Connecting to the shared game room..."
	var room: Dictionary = await MatrixClient.join_shared_room(room_mode)
	if not room.get("success", false):
		status_label.text = "Could not open room: %s" % room.get("error", "The server did not respond.")
		portal_busy = false
		return

	await get_tree().create_timer(1.0).timeout
	if not is_inside_tree():
		return

	MatchManager.disconnect_client()
	var mode_id := MatchManager.MODE_MATCH if portal_id == "match" else MatchManager.MODE_FREE_KICK
	var result := NetJoin.create_client(
		String(room.get("host", "192.168.1.9")),
		int(room.get("port", 12810)),
		MatchManager.TEAM_AUTO,
		MatchManager.ROLE_PLAYER,
		MatrixClient.local_username(),
		mode_id,
		NetJoin.TRANSPORT_WEBSOCKET,
		String(room.get("token", ""))
	)
	if not result.get("ok", false):
		status_label.text = "Could not connect to the game room: %s" % result.get("message", "Could not establish a connection.")
		portal_busy = false


func _ground_height_at(x: float, z: float) -> float:
	var terrain := get_node_or_null("Terrain")
	if terrain == null:
		return 0.0
	var query := PhysicsRayQueryParameters3D.create(Vector3(x, 300.0, z), Vector3(x, -300.0, z))
	var excluded: Array[RID] = []
	for _attempt in range(32):
		query.exclude = excluded
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty():
			break
		if hit.get("collider") == terrain:
			return float(hit.position.y)
		excluded.append(hit.get("rid"))
	return 0.0


func _add_box(parent: Node3D, node_name: String, position: Vector3, size: Vector3, color: Color, rotation := Vector3.ZERO, emissive := false) -> void:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.position = position
	instance.rotation = rotation
	var box := BoxMesh.new()
	box.size = size
	instance.mesh = box
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.84
	if color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if emissive:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 1.8
	instance.material_override = material
	parent.add_child(instance)
