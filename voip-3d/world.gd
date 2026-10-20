extends Node3D

const playerScene = preload("res://character.tscn")
const FREE_KICK_CONTROLLER_SCRIPT = preload("res://free_kick_controller.gd")
const FOOTBALL_MATCH_CONTROLLER_SCRIPT = preload("res://football_match_controller.gd")
const MATCH_CAMERA_OFFSET := Vector3(18.0, 14.0, 0.0)
const GOAL_CAMERA_OFFSET := Vector3(8.0, 5.0, 7.0)
const MATCH_CAMERA_FOLLOW_SPEED := 7.0

@onready var playersNode = $players

var game_notification_panel: PanelContainer
var game_notification_label: Label
var game_notification_timer: Timer
var stadium_camera: Camera3D
var match_camera_focus := Vector3.ZERO
var goal_camera_target: Node3D
var match_lineup_spawned := false

func _enter_tree():
	var game_controller: Node = get_node("GameController")
	var free_kick_ground := get_node_or_null("CSGBox3D") as CSGBox3D
	var match_environment := get_node_or_null("MatchEnvironment") as Node3D
	if free_kick_ground:
		free_kick_ground.visible = MatchManager.game_mode == MatchManager.MODE_FREE_KICK
		free_kick_ground.use_collision = MatchManager.game_mode == MatchManager.MODE_FREE_KICK
	if match_environment:
		match_environment.visible = MatchManager.game_mode == MatchManager.MODE_MATCH
	if MatchManager.game_mode == MatchManager.MODE_MATCH:
		game_controller.name = "FootballMatchController"
		game_controller.set_script(FOOTBALL_MATCH_CONTROLLER_SCRIPT)
	else:
		game_controller.name = "FreeKickController"
		game_controller.set_script(FREE_KICK_CONTROLLER_SCRIPT)

func _ready():
	if OS.get_name() == "Android":
		OS.request_permissions()

	if MatchManager.game_mode == MatchManager.MODE_MATCH:
		_setup_match_stadium_camera()
		var player_spawns := get_node_or_null("MatchEnvironment/PlayerSpawns") as Node3D
		if player_spawns:
			player_spawns.visible = false
		for keeper_name in ["BlueKeeperSpawn", "RedKeeperSpawn"]:
			var keeper_preview := get_node_or_null("MatchEnvironment/%s/EditorPreview" % keeper_name) as Node3D
			if keeper_preview:
				keeper_preview.visible = false

	MatchManager.player_state_changed.connect(_on_player_state_changed)
	MatchManager.match_state_changed.connect(_on_match_state_changed)
	MatchManager.player_fell.connect(_on_player_fell)
	MatchManager.player_disconnected.connect(_on_player_disconnected)
	_build_game_notifications()
	if multiplayer.is_server():
		push_warning("SERVER SESSION STARTED")
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		if MatchManager.game_mode == MatchManager.MODE_MATCH:
			_sync_match_lineup()
		else:
			for peer_id in MatchManager.roster:
				var assignment: Dictionary = MatchManager.roster[peer_id]
				createPlayer(peer_id, assignment.team, assignment.role, assignment.username)
	else:
		push_warning("CLIENT SESSION STARTED")

func _setup_match_stadium_camera() -> void:
	var camera := get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		push_error("Match world is missing its stadium Camera3D.")
		return
	stadium_camera = camera
	stadium_camera.position = MATCH_CAMERA_OFFSET
	stadium_camera.fov = 45.0
	stadium_camera.look_at(match_camera_focus, Vector3.UP)
	camera.make_current()

func _process(delta: float) -> void:
	if MatchManager.game_mode != MatchManager.MODE_MATCH or not is_instance_valid(stadium_camera):
		return
	var match_controller := get_node_or_null("FootballMatchController")
	if match_controller == null:
		return
	var tracked_ball := match_controller.get("ball") as Node3D
	if tracked_ball == null:
		return
	var target := tracked_ball.global_position
	var camera_offset := MATCH_CAMERA_OFFSET
	var target_fov := 45.0
	if is_instance_valid(goal_camera_target):
		target = goal_camera_target.global_position + Vector3.UP * 1.2
		camera_offset = GOAL_CAMERA_OFFSET
		target_fov = 36.0
	else:
		goal_camera_target = null
	var weight := 1.0 - exp(-MATCH_CAMERA_FOLLOW_SPEED * delta)
	match_camera_focus = match_camera_focus.lerp(target, weight)
	stadium_camera.global_position = stadium_camera.global_position.lerp(match_camera_focus + camera_offset, weight)
	stadium_camera.fov = lerpf(stadium_camera.fov, target_fov, weight)
	stadium_camera.look_at(match_camera_focus, Vector3.UP)

func focus_goal_scorer(player_name: String) -> void:
	goal_camera_target = playersNode.get_node_or_null(player_name) as Node3D
	if goal_camera_target == null:
		push_error("Could not find goal scorer %s for the celebration camera." % player_name)

func restore_stadium_camera() -> void:
	goal_camera_target = null

func _build_game_notifications() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var canvas := CanvasLayer.new()
	canvas.name = "GameNotifications"
	add_child(canvas)

	game_notification_panel = PanelContainer.new()
	game_notification_panel.anchor_left = 0.5
	game_notification_panel.anchor_right = 0.5
	game_notification_panel.offset_left = -260.0
	game_notification_panel.offset_top = 82.0
	game_notification_panel.offset_right = 260.0
	game_notification_panel.offset_bottom = 142.0
	game_notification_panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.1, 0.13, 0.94)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(12)
	game_notification_panel.add_theme_stylebox_override("panel", style)
	canvas.add_child(game_notification_panel)

	game_notification_label = Label.new()
	game_notification_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	game_notification_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	game_notification_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	game_notification_label.add_theme_font_size_override("font_size", 22)
	game_notification_panel.add_child(game_notification_label)

	game_notification_timer = Timer.new()
	game_notification_timer.one_shot = true
	game_notification_timer.wait_time = 4.0
	game_notification_timer.timeout.connect(func(): game_notification_panel.hide())
	add_child(game_notification_timer)

func _on_player_fell(peer_id: int, username: String) -> void:
	if peer_id != multiplayer.get_unique_id():
		_show_game_notification("%s fell and respawned." % username)

func _on_player_disconnected(peer_id: int, username: String) -> void:
	if peer_id != multiplayer.get_unique_id():
		_show_game_notification("%s left the game." % username)

func _show_game_notification(message: String) -> void:
	if game_notification_panel == null:
		return
	game_notification_label.text = message
	game_notification_panel.show()
	game_notification_timer.start()

func _on_player_state_changed(peer_id: int, team: int, role: int, username: String):
	if not multiplayer.is_server():
		return
	if MatchManager.game_mode == MatchManager.MODE_MATCH:
		_sync_match_lineup()
		return
	if team < 0:
		removePlayer(peer_id)
	else:
		createPlayer(peer_id, team, role, username)

func _on_match_state_changed(_ready: bool) -> void:
	if multiplayer.is_server() and MatchManager.game_mode == MatchManager.MODE_MATCH:
		_sync_match_lineup()

func _sync_match_lineup() -> void:
	if not multiplayer.is_server():
		return
	if not MatchManager.match_ready:
		_clear_match_lineup()
		return
	if match_lineup_spawned:
		return
	for team in [MatchManager.TEAM_BLUE, MatchManager.TEAM_RED]:
		var captain_id := -1
		for peer_id in MatchManager.roster:
			var assignment: Dictionary = MatchManager.roster[peer_id]
			if assignment.team == team:
				captain_id = int(peer_id)
				break
		if captain_id < 0:
			if team == MatchManager.TEAM_BLUE:
				captain_id = 1
			else:
				push_error("Match is ready without a HUMAN captain.")
				return
		for field_slot in range(MatchManager.MAX_FIELD_PLAYERS_PER_TEAM):
			var player = playerScene.instantiate()
			player.name = str(10000 + team * 100 + field_slot)
			player.team = team
			player.role = MatchManager.ROLE_PLAYER
			player.username = "%s %d" % ["HUMAN" if team == MatchManager.TEAM_RED else "ROBOT", field_slot + 1]
			player.controller_peer_id = captain_id
			player.field_slot = field_slot
			player.is_ai = true
			var spawn_marker := _match_field_spawn(team, field_slot)
			var player_spawn_position := Vector3.ZERO
			var player_spawn_yaw := 0.0
			if spawn_marker:
				player_spawn_position = spawn_marker.global_position
				player_spawn_position.y = 0.0
				var own_half_sign := 1.0 if team == MatchManager.TEAM_BLUE else -1.0
				player_spawn_position.z = own_half_sign * maxf(absf(player_spawn_position.z), 8.0)
				player_spawn_yaw = spawn_marker.global_rotation.y
			else:
				player_spawn_position = MatchManager.match_formation_position(team, field_slot)
				player_spawn_yaw = 0.0 if team == MatchManager.TEAM_BLUE else PI
			playersNode.add_child(player, true)
			player.global_position = player_spawn_position
			player.global_rotation.y = player_spawn_yaw
			player.velocity = Vector3.ZERO
			player.spawn_position = player.global_position
		var keeper = playerScene.instantiate()
		keeper.name = str(10000 + team * 100 + MatchManager.MAX_FIELD_PLAYERS_PER_TEAM)
		keeper.team = team
		keeper.role = MatchManager.ROLE_GOALKEEPER
		keeper.username = "%s GOALKEEPER" % ("HUMAN" if team == MatchManager.TEAM_RED else "ROBOT")
		keeper.controller_peer_id = captain_id
		keeper.field_slot = -1
		keeper.is_ai = true
		playersNode.add_child(keeper, true)
	match_lineup_spawned = true

func _clear_match_lineup() -> void:
	for child in playersNode.get_children():
		if child is CharacterBody3D:
			child.queue_free()
	match_lineup_spawned = false

func _match_field_spawn(team: int, field_slot: int) -> Marker3D:
	var team_name := "Blue" if team == MatchManager.TEAM_BLUE else "Red"
	return get_node_or_null("MatchEnvironment/PlayerSpawns/%sFieldPlayer%d" % [team_name, field_slot]) as Marker3D

func createPlayer(id: int, team: int, role: int, username: String):
	print("CREATE PLAYER %s TEAM %s ROLE %s" % [id, team, role])
	if playersNode.has_node(str(id)):
		return
	var player = playerScene.instantiate()
	player.name = str(id)
	player.team = team
	player.role = role
	player.username = username
	var goalkeeper_spawn: Marker3D
	if MatchManager.game_mode == MatchManager.MODE_MATCH:
		if role == MatchManager.ROLE_GOALKEEPER:
			var spawn_name := "BlueKeeperSpawn" if team == MatchManager.TEAM_BLUE else "RedKeeperSpawn"
			goalkeeper_spawn = get_node_or_null("MatchEnvironment/%s" % spawn_name) as Marker3D
			if goalkeeper_spawn == null:
				push_error("Missing goalkeeper spawn marker: %s" % spawn_name)
				player.queue_free()
				return
			player.position = goalkeeper_spawn.global_position
			player.rotation.y = goalkeeper_spawn.global_rotation.y
		else:
			var field_index := 0
			for existing in playersNode.get_children():
				if existing is CharacterBody3D and existing.get("team") == team and existing.get("role") == MatchManager.ROLE_PLAYER:
					field_index += 1
			var spawn_marker := _match_field_spawn(team, field_index)
			if spawn_marker:
				player.position = spawn_marker.global_position
				player.rotation.y = spawn_marker.global_rotation.y
			else:
				var side := -1.0 if team == MatchManager.TEAM_RED else 1.0
				player.position = Vector3(-1.4 + float(field_index % 3) * 1.4, 0.0, side * (2.5 + float(field_index / 3) * 1.5))
				player.rotation.y = 0.0 if team == MatchManager.TEAM_BLUE else PI
	elif role == MatchManager.ROLE_GOALKEEPER:
		player.position = Vector3(0, 0, -25.2)
		player.rotation.y = PI
	else:
		var field_index = MatchManager.field_player_count(team) - 1
		player.position = Vector3(-1.15 + float(field_index % 3) * 1.15, 0, 2.5 + float(field_index / 3) * 1.2)
		player.rotation.y = 0.0
	player.spawn_position = player.position
	playersNode.add_child(player, true)
	if goalkeeper_spawn:
		player.global_transform = goalkeeper_spawn.global_transform
		player.spawn_position = goalkeeper_spawn.global_position

func removePlayer(id: int):
	print("REMOVE PLAYER: ", str(id))
	var player = playersNode.get_node_or_null(str(id))
	if player:
		player.call_deferred("queue_free")

func _on_peer_disconnected(id: int):
	if MatchManager.roster.has(id):
		MatchManager.release_player(id)
	else:
		removePlayer(id)
