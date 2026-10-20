extends Node3D
## OVERLAND - orchestration for a chunk-streamed open world you WALK and DRIVE across.
## Fully offline: world.json, quests.json, models and audio are read from res://openworld (no CDN, no cloud backend).
## Wires the streaming systems, keeps the player/camera/HUD PERSISTENT across cell streaming, and adds:
##   - the selected football avatar with shared locomotion clips
##   - GRAVITY so the player walks the rolling terrain, and a DRIVE mode (enter/exit a car via the DRIVE btn)
##   - per-DISTRICT music + a live HUD + district-discovery persistence (local save, overland_save.gd)
##   - MULTIPLAYER presence (overland_net.gd) and 15 portals across three activity hubs
## CHUNK MODE (world.mode=="chunk") replaces the one-resident zone streamer with ChunkManager (3x3 ring).

const L_WORLD := 1
const L_PLAYER := 2
const L_ENEMY := 4

const CAM_DIST := 8.5
const DRIVE_CAM_DIST := 12.5
const CAM_HEAD := 1.6
const CAM_PITCH_MIN := -1.30
const CAM_PITCH_MAX := -0.12
const LOOK_SENS := 0.006

const WALK_SPEED := 6.0
const DRIVE_SPEED := 18.0
const GRAVITY := 26.0
const JUMP_VELOCITY := 8.0
const FOOTBALL_MODEL_UTILS := preload("res://football_model_utils.gd")
const CAR_MODEL_PATH := "res://openworld/models/lamborghini_centenario_lp770_interior_sdc.glb"
const CAR_ENTER_ANIMATION_PATH := "res://openworld/models/entering_car.fbx"
const CAR_EXIT_ANIMATION_PATH := "res://openworld/models/exiting_car.fbx"
const CAR_TARGET_LENGTH := 4.8
const CAR_DOOR_ANIMATION_SPEED := 5.0
const CAR_PAINT_COLORS := [
	Color("#d62828"), Color("#087ac6"), Color("#e3b624"), Color("#15804e"),
	Color("#6b42b5"), Color("#eeeeee"), Color("#24272b"), Color("#e36b1f")
]

# The three districts the player can discover (drives the discovery count + music).
const DISTRICTS := {"downtown": "Downtown", "country": "Countryside", "oldtown": "Old-Town"}
const DISTRICT_MUSIC := {"downtown": "music_city", "country": "music_country", "oldtown": "music_town"}
const DISTRICT_COUNT := 3

var origin := "res://openworld"
var world_path := "res://openworld/world.json"
var quests_path := "res://openworld/quests.json"
var props_pool: Array = []

const PORTAL_RADIUS := 2.2
const MENU_SCENE := "res://lobby.tscn"
const PORTAL_HUBS := [
	{"mode": "free_kick", "title": "FREE KICK", "centre": Vector2(10.0, 70.0), "color": Color(1.0, 0.66, 0.12)},
	{"mode": "match", "title": "MATCH", "centre": Vector2(10.0, 130.0), "color": Color(0.2, 0.65, 1.0)},
	{"mode": "conference", "title": "SES KONFERANSI", "centre": Vector2(10.0, 250.0), "color": Color(0.76, 0.38, 1.0)}
]

var world_data := {}
var quests_data := {}

var env: Environment
var sun: DirectionalLight3D
var player: CharacterBody3D
var cam: Camera3D
var cam_rig: Node3D
var cam_spring: SpringArm3D
var cam_yaw := 0.0
var cam_pitch := -0.5
var look_idx := -1
var look_last := Vector2.ZERO

# animated avatar
var body_mesh: MeshInstance3D
var player_avatar: Node3D
var player_anim: AnimationPlayer
var clip_idle := ""
var clip_walk := ""
var clip_run := ""
var clip_jump := ""
var _jump_requested := false

# drive mode
var driving := false
var car_world: Node3D           # the parked car in the world (persistent)
var car_on_player: Node3D       # the car shown on the player while driving
var car_base_y := 0.0           # the car mesh's base offset (so it seats on the ground)
var car_model_yaw_offset := 0.0
var _vehicle_transition_busy := false
var _vehicle_enter_animation := ""
var _vehicle_exit_animation := ""

var rpg: RpgState
var builder: AreaBuilder
var interaction: InteractionSystem
var scene_manager: SceneManager
var quest: QuestSystem
var weather: Weather3D
var chunk_manager: ChunkManager
var chunk_mode := false
var auto_roam := false
var _roam_t := 0.0

# local save + discovery
var save_store: OverlandSave
var net: OverlandNet
var portals: Array[Dictionary] = []
var _portal_cooldown := 0.0
var _portal_busy := false
var discovered := {}
var current_district := ""
var _save_t := 0.0
var _pending_teleport = null

var move_idx := -1
var move_origin := Vector2.ZERO
var move_vec := Vector2.ZERO

var hud_layer: CanvasLayer
var title_label: Label
var world_panel: PanelContainer
var world_label: RichTextLabel
var hint_label: Label
var _hint_t := 0.0

var talk_req_panel: PanelContainer
var talk_req_label: Label
var talk_accept_btn: Button
var talk_decline_btn: Button
var talk_pending_user := ""

var matrix_chat_box: VBoxContainer
var matrix_chat_history: TextEdit
var matrix_chat_input: LineEdit
var matrix_chat_toggle_btn: Button

var invite_modal_overland: PanelContainer
var invite_label_overland: Label
var pending_overland_invite: Dictionary = {}

var use_btn: Button
var drive_btn: Button
var jump_btn: Button
var ptt_btn: Button
var _ptt_touch_active := false
var _ptt_key_active := false
var joystick: MobileVirtualJoystick
var _insets := {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}
var _prev_scale_mode := Window.CONTENT_SCALE_MODE_DISABLED
var _prev_scale_aspect := Window.CONTENT_SCALE_ASPECT_KEEP


func _exit_tree() -> void:
	if net != null:
		net.set_ptt_active(false)
	# the free-kick game and menu use the project's default window scaling
	var w := get_window()
	if w != null:
		w.content_scale_mode = _prev_scale_mode
		w.content_scale_aspect = _prev_scale_aspect


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		# Dedicated server: no world to render, only presence relay for the connected players.
		net = OverlandNet.new()
		net.name = "OverlandNet"
		add_child(net)
		net.setup(self)
		return

	var w := get_window()
	_prev_scale_mode = w.content_scale_mode
	_prev_scale_aspect = w.content_scale_aspect
	# force full-screen fill + relayout on resize (web canvas size isn't final on frame 0)
	w.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	w.size_changed.connect(_relayout_ui)
	w.focus_exited.connect(_on_window_focus_exited)

	_build_env()
	_build_player()
	weather = Weather3D.new()
	add_child(weather)
	weather.setup(env, sun, cam_rig)
	_build_hud()
	AudioManager.show_tap_overlay()

	rpg = RpgState.new()
	add_child(rpg)

	builder = AreaBuilder.new()
	builder.origin = origin
	builder.world_url = world_path
	builder.env = env
	add_child(builder)

	interaction = InteractionSystem.new()
	add_child(interaction)

	scene_manager = SceneManager.new()
	add_child(scene_manager)

	quest = QuestSystem.new()
	add_child(quest)
	quest.setup(rpg)

	interaction.setup(player, rpg, scene_manager, quest, hud_layer)
	scene_manager.setup(player, builder, interaction, self, hud_layer)
	scene_manager.area_entered.connect(quest.notify_area)

	chunk_manager = ChunkManager.new()
	add_child(chunk_manager)
	chunk_manager.setup(player, builder, self, env, interaction, rpg)
	chunk_manager.area_entered.connect(quest.notify_area)
	chunk_manager.area_entered.connect(_on_area_entered)

	save_store = OverlandSave.new()
	add_child(save_store)
	save_store.loaded.connect(_on_backend_loaded)

	net = OverlandNet.new()
	net.name = "OverlandNet"
	add_child(net)
	net.setup(self)

	if MatrixClient.is_logged_in():
		MatrixClient.talk_request_received.connect(_on_talk_request_received)
		MatrixClient.chat_message_received.connect(_on_matrix_chat_received)
		MatrixClient.room_invite_received.connect(_on_room_invite_received_in_overland)

	await get_tree().process_frame
	await get_tree().process_frame
	_relayout_ui()
	_boot()


func _read_json(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	return JSON.parse_string(file.get_as_text())


func _boot() -> void:
	builder.props_pool = props_pool
	var world = _read_json(world_path)
	if not (world is Dictionary):
		title_label.text = "world.json could not be loaded"
		return
	world_data = world
	_apply_weather(world)

	var qdata = _read_json(quests_path)
	if qdata is Dictionary:
		quests_data = qdata
		quest.load_quests(qdata)
		var first_quest = quests_data.get("quests", [])
		if first_quest.size() > 0:
			quest.start(first_quest[0].get("id", ""))

	if String(world.get("mode", "")) == "chunk":
		chunk_mode = true
		scene_manager._fade.visible = false
		sun.shadow_enabled = true
		sun.shadow_normal_bias = 2.0
		sun.directional_shadow_max_distance = 46.0
		await chunk_manager.start(world)
		_spawn_car()
		_build_portal()
		save_store.boot()   # load save (teleport)
	else:
		scene_manager.start(world)


# ---------------- movement ----------------

func _physics_process(delta: float) -> void:
	if player == null:
		return
	if _vehicle_transition_busy:
		player.velocity = Vector3.ZERO
		return
	if chunk_mode:
		_chunk_physics(delta)
		return
	if scene_manager == null or scene_manager.transitioning or scene_manager.current_root == null:
		return
	var j_val := joystick.value if joystick != null else Vector2.ZERO
	var v := _keyboard_vec() + move_vec + j_val
	if v.length() > 1.0:
		v = v.normalized()
	var dir := Basis(Vector3.UP, cam_yaw) * Vector3(v.x, 0.0, v.y)
	player.velocity.x = dir.x * WALK_SPEED
	player.velocity.z = dir.z * WALK_SPEED
	_update_vertical_velocity(delta)
	if dir.length() > 0.1:
		var look := player.global_position - dir
		player.look_at(Vector3(look.x, player.global_position.y, look.z), Vector3.UP)
	player.move_and_slide()
	_animate_player(dir.length() > 0.1, not player.is_on_floor())


func _chunk_physics(delta: float) -> void:
	var j_val := joystick.value if joystick != null else Vector2.ZERO
	var v := _keyboard_vec() + move_vec + j_val
	if auto_roam and chunk_manager != null:
		_roam_t += delta
		var rect := chunk_manager.grid_world_rect()
		var tt := fmod(_roam_t * 0.05, 2.0)
		var f := tt if tt <= 1.0 else (2.0 - tt)
		var target := Vector3(rect.position.x, 0.0, rect.position.y).lerp(
			Vector3(rect.end.x, 0.0, rect.end.y), f)
		var to := target - player.global_position
		v = Vector2(to.x, to.z)
	if v.length() > 1.0:
		v = v.normalized()
	var dir := Vector3(v.x, 0.0, v.y) if auto_roam else Basis(Vector3.UP, cam_yaw) * Vector3(v.x, 0.0, v.y)
	var spd := DRIVE_SPEED if driving else WALK_SPEED
	player.velocity.x = dir.x * spd
	player.velocity.z = dir.z * spd
	_update_vertical_velocity(delta)
	if dir.length() > 0.1:
		var look := player.global_position - dir
		player.look_at(Vector3(look.x, player.global_position.y, look.z), Vector3.UP)
	player.move_and_slide()
	_animate_player(dir.length() > 0.1, not player.is_on_floor())


func _update_vertical_velocity(delta: float) -> void:
	var jump_pressed := Input.is_action_just_pressed("ui_accept") or _jump_requested
	_jump_requested = false
	if player.is_on_floor():
		player.velocity.y = JUMP_VELOCITY if jump_pressed and not driving else -2.0
	else:
		player.velocity.y -= GRAVITY * delta


func _process(delta: float) -> void:
	if cam_rig and player:
		cam_rig.global_position = player.global_position + Vector3(0.0, CAM_HEAD + (0.9 if driving else 0.0), 0.0)
		cam_rig.rotation.y = cam_yaw
		cam_spring.rotation.x = cam_pitch
		var target_len := DRIVE_CAM_DIST if driving else CAM_DIST
		cam_spring.spring_length = lerpf(cam_spring.spring_length, target_len, clampf(delta * 4.0, 0.0, 1.0))
	if chunk_mode and chunk_manager != null:
		chunk_manager.tick(delta)
	# periodic autosave (position + discovered) so a restart RESUMES where you were
	if save_store != null and chunk_mode:
		_save_t += delta
		if _save_t >= 8.0:
			_save_t = 0.0
			save_store.save(_save_data())
	_update_portal(delta)
	if _hint_t > 0.0:
		_hint_t -= delta
		if _hint_t <= 0.0 and hint_label != null:
			hint_label.visible = false
	_refresh_stats()


# ---------------- district discovery + music ----------------

func _district_for(area_id: String) -> String:
	# area_id is "c<gx>_<gz>"; classify by gz band (matches the authored layout).
	var us := area_id.substr(1).split("_")
	if us.size() < 2:
		return "country"
	var gz := int(us[1])
	if gz <= 2:
		return "downtown"
	if gz >= 10:
		return "oldtown"
	return "country"


func _on_area_entered(area_id: String) -> void:
	var d := _district_for(area_id)
	if d == current_district:
		return
	current_district = d
	var mk := String(DISTRICT_MUSIC.get(d, ""))
	if mk != "" and ResourceLoader.exists("res://openworld/audio/%s.ogg" % mk):
		AudioManager.play_music(load("res://openworld/audio/%s.ogg" % mk))
	if not discovered.has(d):
		discovered[d] = true
		_flash_hint("Discovered %s!  (%d/%d districts)" % [DISTRICTS.get(d, d), discovered.size(), DISTRICT_COUNT])
		AudioManager.play_sfx("pickup")
		if save_store != null:
			save_store.save(_save_data())


func _save_data() -> Dictionary:
	return {"pos": [snappedf(player.global_position.x, 0.1), snappedf(player.global_position.z, 0.1)],
		"discovered": discovered.keys()}


func _on_backend_loaded(data: Dictionary) -> void:
	var disc = data.get("discovered", [])
	if disc is Array:
		for d in disc:
			if DISTRICTS.has(String(d)):
				discovered[String(d)] = true
	var pos = data.get("pos", null)
	if pos is Array and (pos as Array).size() >= 2 and player != null:
		var px := float(pos[0])
		var pz := float(pos[1])
		player.global_position = Vector3(px, _ground_y(px, pz) + 1.5, pz)
		_flash_hint("Welcome back - resuming where you left off.")


func _on_world_stats(_v: int, _d: int) -> void:
	_refresh_stats()


# ---------------- plaza portal hubs ----------------

func _build_portal() -> void:
	portals.clear()
	var portal_offsets := [
		Vector2.ZERO,
		Vector2(-5.5, 0.0),
		Vector2(5.5, 0.0),
		Vector2(0.0, -5.5),
		Vector2(0.0, 5.5)
	]
	for hub_index in range(PORTAL_HUBS.size()):
		var hub: Dictionary = PORTAL_HUBS[hub_index]
		for portal_index in range(portal_offsets.size()):
			var offset: Vector2 = portal_offsets[portal_index]
			var centre: Vector2 = hub.centre
			var spot := Vector3(centre.x + offset.x, 0.0, centre.y + offset.y)
			spot.y = _ground_y(spot.x, spot.z)
			var portal_id := "%s_%02d" % [String(hub.mode), portal_index + 1]
			var root := Node3D.new()
			root.name = "Portal_%s" % portal_id
			add_child(root)
			root.global_position = spot

			var glow := StandardMaterial3D.new()
			glow.albedo_color = hub.color
			glow.emission_enabled = true
			glow.emission = hub.color
			glow.emission_energy_multiplier = 1.6
			glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

			var ring := MeshInstance3D.new()
			var torus := TorusMesh.new()
			torus.inner_radius = PORTAL_RADIUS - 0.25
			torus.outer_radius = PORTAL_RADIUS
			ring.mesh = torus
			ring.material_override = glow
			ring.position.y = 0.08
			root.add_child(ring)

			var orb := MeshInstance3D.new()
			var sphere := SphereMesh.new()
			sphere.radius = 0.42
			sphere.height = 0.84
			orb.mesh = sphere
			orb.material_override = glow
			orb.position.y = 1.5
			root.add_child(orb)

			var light := OmniLight3D.new()
			light.light_color = hub.color
			light.omni_range = 7.0
			light.position.y = 1.5
			root.add_child(light)

			var label := Label3D.new()
			label.text = "%s %02d" % [String(hub.title), portal_index + 1]
			label.font_size = 48
			label.pixel_size = 0.008
			label.outline_size = 12
			label.modulate = hub.color.lightened(0.25)
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.position.y = 2.6
			root.add_child(label)
			portals.append({
				"id": portal_id,
				"mode": String(hub.mode),
				"title": String(hub.title),
				"node": root,
				"orb": orb,
				"position": spot
			})


func _nearest_portal() -> Dictionary:
	if player == null or driving:
		return {}
	var nearest: Dictionary = {}
	var nearest_distance := PORTAL_RADIUS + 0.6
	for entry in portals:
		var portal_position: Vector3 = entry.position
		var distance := Vector2(player.global_position.x - portal_position.x, player.global_position.z - portal_position.z).length()
		if distance <= nearest_distance:
			nearest = entry
			nearest_distance = distance
	return nearest


func _update_portal(delta: float) -> void:
	_portal_cooldown = maxf(0.0, _portal_cooldown - delta)
	for entry in portals:
		var orb: Node3D = entry.orb
		if is_instance_valid(orb):
			orb.position.y = 1.5 + sin(Time.get_ticks_msec() * 0.003) * 0.12
	if interaction == null or _portal_busy:
		return
	var nearest := _nearest_portal()
	if not nearest.is_empty():
		interaction.prompt.text = "USE  >  Enter %s portal" % nearest.title


# Called by the USE button / E key to join the selected shared portal room.
func try_enter_portal() -> bool:
	var nearest := _nearest_portal()
	if nearest.is_empty() or _portal_cooldown > 0.0 or _portal_busy:
		return false
	_portal_cooldown = 1.5
	_portal_busy = true
	if save_store != null:
		save_store.save(_save_data())
	_join_portal_room(nearest)
	return true


func _join_portal_room(portal_info: Dictionary) -> void:
	var portal_mode := String(portal_info.mode)
	var mode_id := NetJoin.parse_mode(portal_mode)
	var result := await MatrixClient.join_shared_room(portal_mode, String(portal_info.id))
	if not is_inside_tree():
		return
	if not result.get("success", false):
		_portal_busy = false
		_flash_hint("Could not open room: %s" % String(result.get("error", "The server did not respond.")))
		return
	MatchManager.preferred_mode = mode_id
	var join_result := NetJoin.create_client(
		String(result.get("host", "")),
		int(result.get("port", 0)),
		MatchManager.TEAM_AUTO,
		MatchManager.ROLE_PLAYER,
		MatrixClient.local_username(),
		mode_id,
		NetJoin.TRANSPORT_WEBSOCKET,
		String(result.get("token", ""))
	)
	if not join_result.get("ok", false):
		_portal_busy = false
		_flash_hint("Could not connect to room: %s" % String(join_result.get("message", "")))


# ---------------- drive ----------------

func _spawn_car() -> void:
	if not ResourceLoader.exists(CAR_MODEL_PATH):
		push_error("The Overland car model is missing: %s" % CAR_MODEL_PATH)
		return
	var car_scene := load(CAR_MODEL_PATH) as PackedScene
	if car_scene == null:
		push_error("The Overland car model could not be loaded: %s" % CAR_MODEL_PATH)
		return
	car_world = car_scene.instantiate() as Node3D
	if car_world == null:
		push_error("The Overland car model did not instantiate as Node3D.")
		return
	add_child(car_world)
	car_world.rotation.y = player.rotation.y
	_configure_car_model(car_world)
	var car_color: Color = CAR_PAINT_COLORS[randi_range(0, CAR_PAINT_COLORS.size() - 1)]
	if not _apply_car_color(car_world, car_color):
		return
	if car_on_player != null and not _apply_car_color(car_on_player, car_color):
		return
	car_base_y = _subtree_aabb(car_world).position.y   # world min-y with the car at origin -> base offset
	var sp := player.global_position + car_world.global_transform.basis.x * 3.5
	car_world.global_position = Vector3(sp.x, _ground_y(sp.x, sp.z) - car_base_y, sp.z)
	var car_sign := interaction.add_sign("CAR", car_world.global_position + Vector3(0, 2.4, 0), Color(0.7, 0.9, 1.0), self)
	car_sign.font_size = 34
	car_sign.pixel_size = 0.006
	car_sign.visible = true


func _toggle_drive() -> void:
	if _vehicle_transition_busy:
		return
	if driving:
		await _exit_vehicle()
	elif car_world != null and is_instance_valid(car_world):
		await _enter_vehicle()
	else:
		_flash_hint("Your car isn't ready yet.")


func _enter_vehicle() -> void:
	if player == null or car_world == null or not is_instance_valid(car_world):
		push_error("Cannot enter the Overland car because the player or car is unavailable.")
		return
	_vehicle_transition_busy = true
	if drive_btn != null:
		drive_btn.disabled = true
		drive_btn.text = "ENTERING..."
	var car_yaw := car_world.rotation.y
	var seat_position := Vector3(
		car_world.global_position.x,
		_ground_y(car_world.global_position.x, car_world.global_position.z),
		car_world.global_position.z
	)
	player.rotation.y = car_yaw - car_model_yaw_offset
	if player_avatar != null:
		player_avatar.visible = true
	elif body_mesh != null:
		body_mesh.visible = true
	var transition_duration := _play_vehicle_animation(_vehicle_enter_animation, 1.2)
	var door_duration := _start_car_door_motion(car_world, true, minf(transition_duration * 0.2, 1.2))
	AudioManager.play_sfx("door")
	var tween := create_tween()
	tween.tween_property(player, "global_position", seat_position, transition_duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if door_duration > 0.0:
		await get_tree().create_timer(door_duration).timeout
		_hold_car_door_pose(car_world, true)
	await tween.finished
	var close_duration := _start_car_door_motion(car_world, false, minf(transition_duration * 0.2, 1.2))
	if close_duration > 0.0:
		await get_tree().create_timer(close_duration).timeout
		_hold_car_door_pose(car_world, false)
	car_world.visible = false
	if car_on_player != null:
		car_on_player.visible = true
	if player_avatar != null:
		player_avatar.visible = false
	elif body_mesh != null:
		body_mesh.visible = false
	driving = true
	_vehicle_transition_busy = false
	if drive_btn != null:
		drive_btn.disabled = false
		drive_btn.text = "EXIT"
	_flash_hint("Driving! Left joystick to move, drag right to look. Tap EXIT to step out.")
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__ov_driving=true", true)


func _exit_vehicle() -> void:
	if player == null or car_world == null or not is_instance_valid(car_world):
		push_error("Cannot exit the Overland car because the player or car is unavailable.")
		return
	_vehicle_transition_busy = true
	driving = false
	if drive_btn != null:
		drive_btn.disabled = true
		drive_btn.text = "EXITING..."
	if car_on_player != null:
		car_on_player.visible = false
	car_world.visible = true
	car_world.rotation.y = player.rotation.y + car_model_yaw_offset
	car_world.global_position = Vector3(
		player.global_position.x,
		_ground_y(player.global_position.x, player.global_position.z) - car_base_y,
		player.global_position.z
	)
	if player_avatar != null:
		player_avatar.visible = true
	elif body_mesh != null:
		body_mesh.visible = true
	var transition_duration := _play_vehicle_animation(_vehicle_exit_animation, 1.2)
	var door_duration := _start_car_door_motion(car_world, true, minf(transition_duration * 0.2, 1.2))
	AudioManager.play_sfx("door")
	var exit_position := player.global_position + car_world.global_transform.basis.x * 1.7
	exit_position.y = _ground_y(exit_position.x, exit_position.z)
	var tween := create_tween()
	tween.tween_property(player, "global_position", exit_position, transition_duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if door_duration > 0.0:
		await get_tree().create_timer(door_duration).timeout
		_hold_car_door_pose(car_world, true)
	await tween.finished
	var close_duration := _start_car_door_motion(car_world, false, minf(transition_duration * 0.2, 1.2))
	if close_duration > 0.0:
		await get_tree().create_timer(close_duration).timeout
		_hold_car_door_pose(car_world, false)
	_animate_player(false, false)
	_vehicle_transition_busy = false
	if drive_btn != null:
		drive_btn.disabled = false
		drive_btn.text = "DRIVE"
	_flash_hint("You step out of the car.")
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__ov_driving=false", true)


func _play_vehicle_animation(animation_name: String, fallback_duration: float) -> float:
	if player_anim != null and not animation_name.is_empty() and player_anim.has_animation(animation_name):
		var animation := player_anim.get_animation(animation_name)
		animation.loop_mode = Animation.LOOP_NONE
		player_anim.play(animation_name)
		return animation.length
	if player_anim != null:
		var fallback_animation := clip_run if clip_run != "" else clip_walk
		if fallback_animation != "" and player_anim.has_animation(fallback_animation):
			player_anim.play(fallback_animation)
	return fallback_duration


func _start_car_door_motion(car: Node3D, opening: bool, duration: float) -> float:
	var animation_player := _find_ap(car)
	if animation_player == null:
		push_error("The Overland car has no AnimationPlayer for its doors.")
		return 0.0
	var animation_name := _pick_clip(animation_player, ["animation"])
	if animation_name.is_empty():
		push_error("The Overland car has no door animation clip.")
		return 0.0
	var animation := animation_player.get_animation(animation_name)
	if animation.length <= 0.0:
		push_error("The Overland car door animation has no duration.")
		return 0.0
	animation.loop_mode = Animation.LOOP_NONE
	var safe_duration := maxf(duration, 0.1)
	var speed := animation.length / safe_duration
	animation_player.play(animation_name, -1.0, speed, not opening)
	return animation.length / speed


func _hold_car_door_pose(car: Node3D, open: bool) -> void:
	var animation_player := _find_ap(car)
	if animation_player == null:
		return
	var animation_name := _pick_clip(animation_player, ["animation"])
	if animation_name.is_empty():
		return
	var animation := animation_player.get_animation(animation_name)
	animation_player.seek(animation.length if open else 0.0, true)
	animation_player.pause()
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__ov_driving=" + ("true" if driving else "false"), true)


# ---------------- hooks (no enemies in this world; kept for enemy.gd contract) ----------------

func take_damage(d: float) -> void:
	AudioManager.play_sfx("hurt")
	if rpg and rpg.take_damage(d):
		rpg.hp = rpg.max_hp


func on_enemy_killed(type: String) -> void:
	if quest:
		quest.notify_kill(type)


# ---------------- input (unhandled so HUD buttons + dialogue consume their touch first) ----------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.physical_keycode == KEY_V:
		if not event.echo:
			_ptt_key_active = event.pressed
			_refresh_ptt_state()
		return
	if scene_manager == null or scene_manager.transitioning:
		return
	var half := get_viewport().get_visible_rect().size.x * 0.5
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E:
		_on_use()
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			if event.position.x < half and move_idx == -1:
				move_idx = event.index
				move_origin = event.position
				move_vec = Vector2.ZERO
			elif event.position.x >= half and look_idx == -1:
				look_idx = event.index
				look_last = event.position
		else:
			if event.index == move_idx:
				move_idx = -1
				move_vec = Vector2.ZERO
			elif event.index == look_idx:
				look_idx = -1
	elif event is InputEventScreenDrag:
		if event.index == move_idx:
			move_vec = ((event.position - move_origin) / 80.0).limit_length(1.0)
		elif event.index == look_idx:
			_apply_look(event.position - look_last)
			look_last = event.position
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0 and move_idx == -1 and look_idx == -1:
		_apply_look(event.relative)


func _apply_look(d: Vector2) -> void:
	cam_yaw -= d.x * LOOK_SENS
	cam_pitch = clampf(cam_pitch - d.y * LOOK_SENS, CAM_PITCH_MIN, CAM_PITCH_MAX)


func _keyboard_vec() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): v.x += 1.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): v.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): v.y += 1.0
	return v


func _apply_weather(world: Dictionary) -> void:
	if weather == null:
		return
	var sky = world.get("sky", null)
	if sky is Dictionary:
		weather.apply(sky)


# ---------------- world build (persistent player/env/hud) ----------------

func _build_env() -> void:
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.08, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.66)
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 4.0
	env.tonemap_white = 4.0
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.06
	env.adjustment_saturation = 1.14
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -45.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)


func _build_player() -> void:
	player = CharacterBody3D.new()
	player.collision_layer = L_PLAYER
	player.collision_mask = L_WORLD | L_ENEMY
	player.floor_snap_length = 1.2
	player.floor_max_angle = deg_to_rad(52.0)
	player.up_direction = Vector3.UP
	add_child(player)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.7
	cs.shape = cap
	cs.position.y = 0.9
	player.add_child(cs)
	# placeholder capsule body (hidden once the avatar loads)
	body_mesh = MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.4
	cm.height = 1.7
	body_mesh.mesh = cm
	body_mesh.position.y = 0.9
	body_mesh.material_override = _mat(Color(0.3, 0.6, 0.95))
	player.add_child(body_mesh)
	_build_avatar()
	var player_name := Label3D.new()
	player_name.name = "PlayerName"
	player_name.text = MatrixClient.local_username()
	player_name.font_size = 48
	player_name.pixel_size = 0.007
	player_name.outline_size = 10
	player_name.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	player_name.position.y = 2.35
	player.add_child(player_name)
	# A matching car instance follows the player while driving.
	var car_scene := load(CAR_MODEL_PATH) as PackedScene
	if car_scene == null:
		push_error("The Overland car model could not be loaded: %s" % CAR_MODEL_PATH)
	else:
		car_on_player = car_scene.instantiate() as Node3D
		if car_on_player == null:
			push_error("The attached Overland car did not instantiate as Node3D.")
		else:
			player.add_child(car_on_player)
			car_on_player.rotation.y = 0.0
			_configure_car_model(car_on_player)
			car_on_player.visible = false

	cam_rig = Node3D.new()
	add_child(cam_rig)
	cam_spring = SpringArm3D.new()
	cam_spring.spring_length = CAM_DIST
	cam_spring.collision_mask = L_WORLD
	cam_spring.margin = 0.3
	cam_spring.rotation.x = cam_pitch
	cam_rig.add_child(cam_spring)
	cam = Camera3D.new()
	cam.fov = 64.0
	cam.far = 900.0
	cam_spring.add_child(cam)


# Build the avatar selected at login and retarget the shared football locomotion clips.
func _build_avatar() -> void:
	var avatar_id := MatrixClient.selected_avatar_id()
	if not AvatarCatalog.is_valid_avatar(avatar_id):
		push_error("The selected Overland avatar is invalid: %s" % avatar_id)
		return
	var avatar_scene := AvatarCatalog.scene_for(avatar_id)
	if avatar_scene == null:
		return
	var model := avatar_scene.instantiate() as Node3D
	if model == null:
		push_error("The selected Overland avatar did not instantiate: %s" % avatar_id)
		return
	if avatar_id == AvatarCatalog.MAN and not AvatarCatalog.apply_male_textures(model):
		model.free()
		return
	if not AvatarCatalog.fit_model_to_height(model, 1.85):
		model.free()
		return
	player_avatar = model
	player.add_child(player_avatar)
	player_avatar.rotation.y = 0.0
	player_anim = _find_ap(player_avatar)
	if player_anim == null and AvatarCatalog.supports_shared_human_animations(avatar_id):
		player_anim = AnimationPlayer.new()
		player_anim.name = "OverlandAnimationPlayer"
		player_avatar.add_child(player_anim)
	if player_anim != null:
		if AvatarCatalog.supports_shared_human_animations(avatar_id):
			FOOTBALL_MODEL_UTILS.install_human_animations(player_anim, player_avatar)
		FOOTBALL_MODEL_UTILS.configure_locomotion_loops(player_anim)
		clip_idle = _pick_clip(player_anim, ["idle", "stand"])
		clip_walk = _pick_clip(player_anim, ["walk"])
		clip_run = _pick_clip(player_anim, ["run", "jog", "sprint"])
		clip_jump = _pick_clip(player_anim, ["jump"])
	if player_anim != null:
		if clip_run == "" or not player_anim.has_animation(clip_run):
			clip_run = clip_walk
		if clip_walk == "" or not player_anim.has_animation(clip_walk):
			clip_walk = clip_idle
		for c in [clip_idle, clip_walk, clip_run]:
			if c != "" and player_anim.has_animation(c):
				player_anim.get_animation(c).loop_mode = Animation.LOOP_LINEAR
		if AvatarCatalog.supports_shared_human_animations(avatar_id):
			_install_vehicle_animations(player_avatar, player_anim)
	if body_mesh != null:
		body_mesh.visible = false
	_animate_player(false, false)


func _install_vehicle_animations(model_root: Node3D, animation_player: AnimationPlayer) -> void:
	var skeleton_nodes := model_root.find_children("*", "Skeleton3D", true, false)
	if skeleton_nodes.is_empty():
		push_error("The selected human avatar has no Skeleton3D for vehicle animations.")
		return
	var target_skeleton := skeleton_nodes[0] as Skeleton3D
	var enter_animation := _retarget_vehicle_animation(CAR_ENTER_ANIMATION_PATH, model_root, target_skeleton)
	var exit_animation := _retarget_vehicle_animation(CAR_EXIT_ANIMATION_PATH, model_root, target_skeleton)
	if enter_animation == null or exit_animation == null:
		return
	var animation_library := AnimationLibrary.new()
	var enter_result := animation_library.add_animation(&"enter_car", enter_animation)
	if enter_result != OK:
		push_error("Could not add the car-entry animation: %s" % error_string(enter_result))
		return
	var exit_result := animation_library.add_animation(&"exit_car", exit_animation)
	if exit_result != OK:
		push_error("Could not add the car-exit animation: %s" % error_string(exit_result))
		return
	var library_result := animation_player.add_animation_library(&"vehicle", animation_library)
	if library_result != OK:
		push_error("Could not install vehicle animations: %s" % error_string(library_result))
		return
	_vehicle_enter_animation = "vehicle/enter_car"
	_vehicle_exit_animation = "vehicle/exit_car"


func _retarget_vehicle_animation(
	animation_path: String,
	model_root: Node3D,
	target_skeleton: Skeleton3D
) -> Animation:
	if not ResourceLoader.exists(animation_path):
		push_error("A vehicle animation source is missing: %s" % animation_path)
		return null
	var source_scene_resource := load(animation_path) as PackedScene
	if source_scene_resource == null:
		push_error("A vehicle animation source could not be loaded: %s" % animation_path)
		return null
	var source_scene := source_scene_resource.instantiate() as Node3D
	if source_scene == null:
		push_error("A vehicle animation source did not instantiate as Node3D: %s" % animation_path)
		return null
	var source_player := _find_ap(source_scene)
	if source_player == null:
		push_error("A vehicle animation source has no AnimationPlayer: %s" % animation_path)
		source_scene.free()
		return null
	var source_animation_name := _pick_clip(source_player, ["mixamo_com"])
	if source_animation_name.is_empty():
		push_error("A vehicle animation source has no Mixamo clip: %s" % animation_path)
		source_scene.free()
		return null
	var animation := FOOTBALL_MODEL_UTILS.retarget_animation(
		source_player.get_animation(source_animation_name),
		model_root,
		target_skeleton
	)
	for track_index in range(animation.get_track_count()):
		var track_path := animation.track_get_path(track_index)
		if track_path.get_subname_count() > 0 and "hips" in String(track_path.get_subname(track_path.get_subname_count() - 1)).to_lower():
			FOOTBALL_MODEL_UTILS.remove_locomotion_root_motion(animation, track_index)
	animation.loop_mode = Animation.LOOP_NONE
	source_scene.free()
	return animation


func _animate_player(moving: bool, jumping: bool) -> void:
	if driving or player_anim == null:
		return
	var want := clip_jump if jumping else clip_run if moving else clip_idle
	if want == "":
		want = clip_walk if moving else clip_idle
	if want != "" and player_anim.current_animation != want and player_anim.has_animation(want):
		player_anim.play(want)


func _pick_clip(ap: AnimationPlayer, keys: Array) -> String:
	for k in keys:
		for c in ap.get_animation_list():
			if String(k) in String(c).to_lower():
				return String(c)
	return ""


func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer and not (n as AnimationPlayer).get_animation_list().is_empty():
		return n
	for c in n.get_children():
		var r := _find_ap(c)
		if r != null:
			return r
	return null


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m


func _ground_y(wx: float, wz: float) -> float:
	if chunk_manager != null and chunk_manager.terrain != null:
		return chunk_manager.terrain.height(wx, wz)
	return 0.0


func _seat_avatar(node: Node3D) -> void:
	node.position.y -= _subtree_aabb(node).position.y


func _configure_car_model(node: Node3D) -> void:
	var bounds := _subtree_aabb(node)
	var length := maxf(bounds.size.x, bounds.size.z)
	if length <= 0.001:
		push_error("The Overland car model has no measurable mesh bounds.")
		return
	car_model_yaw_offset = PI * 0.5 if bounds.size.x > bounds.size.z else 0.0
	node.rotation.y += car_model_yaw_offset
	node.scale *= CAR_TARGET_LENGTH / length
	_seat_avatar(node)


func _apply_car_color(car: Node3D, color: Color) -> bool:
	var found_body_paint := false
	for node in car.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		for surface_index in range(mesh_instance.mesh.get_surface_count()):
			if mesh_instance.mesh.surface_get_name(surface_index) != "Body_Colour":
				continue
			found_body_paint = true
			var base_material := mesh_instance.get_active_material(surface_index)
			if base_material == null:
				push_error("The Lamborghini Body_Colour surface has no material.")
				return false
			var paint_material := base_material.duplicate() as StandardMaterial3D
			if paint_material == null:
				push_error("The Lamborghini Body_Colour material is not a StandardMaterial3D.")
				return false
			paint_material.albedo_color = color
			mesh_instance.set_surface_override_material(surface_index, paint_material)
	if not found_body_paint:
		push_error("The Lamborghini model has no Body_Colour surface to recolor.")
		return false
	return true


func _subtree_aabb(root: Node3D) -> AABB:
	var merged := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var wa: AABB = mi.global_transform * mi.get_aabb()
			if first:
				merged = wa
				first = false
			else:
				merged = merged.merge(wa)
	return merged


# ---------------- HUD ----------------

func _build_hud() -> void:
	hud_layer = CanvasLayer.new()
	add_child(hud_layer)

	title_label = Label.new()
	title_label.add_theme_font_size_override("font_size", 26)
	title_label.add_theme_color_override("font_color", Color(0.96, 0.98, 0.9))
	title_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	title_label.add_theme_constant_override("outline_size", 6)
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hud_layer.add_child(title_label)

	world_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.09, 0.72)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(12)
	sb.border_width_left = 2; sb.border_width_top = 2; sb.border_width_right = 2; sb.border_width_bottom = 2
	sb.border_color = Color(0.4, 0.6, 0.8, 0.6)
	world_panel.add_theme_stylebox_override("panel", sb)
	world_label = RichTextLabel.new()
	world_label.bbcode_enabled = true
	world_label.fit_content = true
	world_label.scroll_active = false
	world_label.custom_minimum_size = Vector2(238, 0)
	world_label.add_theme_font_size_override("normal_font_size", 20)
	world_label.add_theme_font_size_override("bold_font_size", 22)
	world_panel.add_child(world_label)
	hud_layer.add_child(world_panel)

	hint_label = Label.new()
	hint_label.add_theme_font_size_override("font_size", 24)
	hint_label.add_theme_color_override("font_color", Color(1, 1, 0.7))
	hint_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	hint_label.add_theme_constant_override("outline_size", 6)
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_layer.add_child(hint_label)

	use_btn = _button("USE", _on_use)
	drive_btn = _button("DRIVE", _toggle_drive)
	jump_btn = _button("JUMP", _on_jump_button_pressed)
	ptt_btn = Button.new()
	ptt_btn.text = "PUSH TO TALK"
	ptt_btn.add_theme_font_size_override("font_size", 22)
	ptt_btn.focus_mode = Control.FOCUS_NONE
	ptt_btn.button_down.connect(_on_ptt_button_down)
	ptt_btn.button_up.connect(_on_ptt_button_up)
	hud_layer.add_child(ptt_btn)

	joystick = MobileVirtualJoystick.new()
	joystick.name = "MobileJoystick"
	joystick.custom_minimum_size = Vector2(180, 180)
	hud_layer.add_child(joystick)

	_build_matrix_ui()
	_flash_hint("Left side: move  /  SPACE or JUMP: jump  /  V or PUSH TO TALK: microphone  /  USE or E: portal")


func _build_matrix_ui() -> void:
	matrix_chat_toggle_btn = _button("CHAT", _toggle_matrix_chat)

	matrix_chat_box = VBoxContainer.new()
	matrix_chat_box.visible = false
	matrix_chat_box.custom_minimum_size = Vector2(320, 220)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.09, 0.85)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(8)

	matrix_chat_history = TextEdit.new()
	matrix_chat_history.editable = false
	matrix_chat_history.custom_minimum_size = Vector2(0, 160)
	matrix_chat_history.size_flags_vertical = Control.SIZE_EXPAND_FILL
	matrix_chat_box.add_child(matrix_chat_history)

	var input_hbox := HBoxContainer.new()
	matrix_chat_input = LineEdit.new()
	matrix_chat_input.placeholder_text = "Matrix message..."
	matrix_chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_hbox.add_child(matrix_chat_input)

	var send_btn := Button.new()
	send_btn.text = "Send"
	send_btn.pressed.connect(_send_matrix_chat)
	input_hbox.add_child(send_btn)

	matrix_chat_box.add_child(input_hbox)
	hud_layer.add_child(matrix_chat_box)

	# Talk Request Panel
	talk_req_panel = PanelContainer.new()
	talk_req_panel.visible = false
	var tbox := VBoxContainer.new()
	talk_req_label = Label.new()
	talk_req_label.text = "Voice Chat Request"
	tbox.add_child(talk_req_label)

	var thbox := HBoxContainer.new()
	talk_accept_btn = Button.new()
	talk_accept_btn.text = "Kabul Et"
	talk_accept_btn.pressed.connect(_accept_talk_req)
	thbox.add_child(talk_accept_btn)

	talk_decline_btn = Button.new()
	talk_decline_btn.text = "Reddet"
	talk_decline_btn.pressed.connect(_decline_talk_req)
	thbox.add_child(talk_decline_btn)

	tbox.add_child(thbox)
	talk_req_panel.add_child(tbox)
	hud_layer.add_child(talk_req_panel)

	# Overland Invite Modal Panel
	invite_modal_overland = PanelContainer.new()
	invite_modal_overland.visible = false
	var ibox := VBoxContainer.new()
	invite_label_overland = Label.new()
	invite_label_overland.text = "Room Invitation Received"
	ibox.add_child(invite_label_overland)

	var ihbox := HBoxContainer.new()
	var iaccept_btn := Button.new()
	iaccept_btn.text = "Kabul Et"
	iaccept_btn.pressed.connect(_accept_overland_invite)
	ihbox.add_child(iaccept_btn)

	var idecline_btn := Button.new()
	idecline_btn.text = "Reddet"
	idecline_btn.pressed.connect(_decline_overland_invite)
	ihbox.add_child(idecline_btn)

	ibox.add_child(ihbox)
	invite_modal_overland.add_child(ibox)
	hud_layer.add_child(invite_modal_overland)


func _on_room_invite_received_in_overland(from_user_id: String, payload: Dictionary) -> void:
	pending_overland_invite = payload
	var mode_name := str(payload.get("mode", "free_kick"))
	var from_disp := str(payload.get("from_display", from_user_id))
	if invite_label_overland:
		invite_label_overland.text = "%s invited you to %s!" % [from_disp, mode_name.capitalize()]
	if invite_modal_overland:
		invite_modal_overland.visible = true


func _accept_overland_invite() -> void:
	if invite_modal_overland:
		invite_modal_overland.visible = false
	if pending_overland_invite.is_empty():
		return
	var host: String = str(pending_overland_invite.get("host", pending_overland_invite.get("address", "192.168.1.9")))
	var port: int = int(pending_overland_invite.get("port", NetJoin.DEFAULT_PORT))
	var token: String = str(pending_overland_invite.get("token", ""))
	var mode_str: String = str(pending_overland_invite.get("mode", "free_kick"))
	var transport_str: String = str(pending_overland_invite.get("transport", "ws"))
	var mode_id := NetJoin.parse_mode(mode_str)
	var transport_id := NetJoin.parse_transport(transport_str)

	NetJoin.create_client(host, port, MatchManager.TEAM_AUTO, MatchManager.ROLE_PLAYER, MatrixClient.local_username(), mode_id, transport_id, token)


func _decline_overland_invite() -> void:
	if invite_modal_overland:
		invite_modal_overland.visible = false
	pending_overland_invite.clear()


func _toggle_matrix_chat() -> void:
	if matrix_chat_box:
		matrix_chat_box.visible = not matrix_chat_box.visible


func _send_matrix_chat() -> void:
	if matrix_chat_input == null or matrix_chat_input.text.strip_edges().is_empty():
		return
	var msg := matrix_chat_input.text.strip_edges()
	matrix_chat_input.text = ""
	var friends := MatrixClient.friends_list()
	if not friends.is_empty():
		MatrixClient.send_chat(friends[0], msg)
	else:
		matrix_chat_history.text += "System: You have no friends yet.\n"


func _on_matrix_chat_received(sender: String, body: String, local_echo: bool) -> void:
	if matrix_chat_history:
		var prefix := "Ben: " if local_echo else (sender + ": ")
		matrix_chat_history.text += prefix + body + "\n"
		if not matrix_chat_box.visible:
			_flash_hint("New chat message: " + sender)


func _on_talk_request_received(from_user_id: String) -> void:
	talk_pending_user = from_user_id
	if talk_req_label:
		talk_req_label.text = "%s wants to voice chat with you." % from_user_id
	if talk_req_panel:
		talk_req_panel.visible = true


func _accept_talk_req() -> void:
	if talk_req_panel:
		talk_req_panel.visible = false
	if not talk_pending_user.is_empty():
		MatrixClient.send_talk_response(talk_pending_user, true)
		_flash_hint("Voice chat started with %s." % talk_pending_user)
		talk_pending_user = ""


func _decline_talk_req() -> void:
	if talk_req_panel:
		talk_req_panel.visible = false
	if not talk_pending_user.is_empty():
		MatrixClient.send_talk_response(talk_pending_user, false)
		talk_pending_user = ""


func _on_use() -> void:
	if not try_enter_portal():
		interaction.try_use()


func _on_jump_button_pressed() -> void:
	_jump_requested = true


func _on_ptt_button_down() -> void:
	_ptt_touch_active = true
	_refresh_ptt_state()


func _on_ptt_button_up() -> void:
	_ptt_touch_active = false
	_refresh_ptt_state()


func _refresh_ptt_state() -> void:
	var active := _ptt_touch_active or _ptt_key_active
	if net != null:
		net.set_ptt_active(active)
	if ptt_btn != null:
		ptt_btn.text = "SPEAKING" if active else "PUSH TO TALK"


func _on_window_focus_exited() -> void:
	_ptt_key_active = false
	_ptt_touch_active = false
	_refresh_ptt_state()


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 26)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	hud_layer.add_child(b)
	return b


func _flash_hint(text: String) -> void:
	if hint_label == null:
		return
	hint_label.text = text
	hint_label.visible = true
	_hint_t = 6.0


func _relayout_ui() -> void:
	if hud_layer == null:
		return
	_insets = _safe_insets()
	var vp := get_viewport().get_visible_rect().size
	var mtop: float = maxf(14.0, float(_insets.get("top", 0.0)))
	var mleft: float = maxf(16.0, float(_insets.get("left", 0.0)))
	var mright: float = maxf(16.0, float(_insets.get("right", 0.0)))
	var mbot: float = maxf(18.0, float(_insets.get("bottom", 0.0)))
	var pw := 260.0
	if world_panel:
		world_panel.reset_size()
		pw = world_panel.size.x if world_panel.size.x > 0.0 else 260.0
		world_panel.position = Vector2(vp.x - pw - mright, mtop)
	if title_label:
		title_label.position = Vector2(mleft, mtop)
		title_label.size = Vector2(maxf(130.0, vp.x - pw - mright - mleft - 14.0), 0.0)
	var bw := 150.0
	var bh := 92.0
	var gap := 14.0
	if use_btn:
		use_btn.size = Vector2(bw, bh)
		use_btn.position = Vector2(vp.x - bw - mright, vp.y - bh - mbot)
	if drive_btn:
		drive_btn.size = Vector2(bw, bh)
		drive_btn.position = Vector2(vp.x - bw - mright, vp.y - bh * 2.0 - gap - mbot)
	if jump_btn:
		jump_btn.size = Vector2(bw, bh)
		jump_btn.position = Vector2(vp.x - bw - mright, vp.y - bh * 3.0 - gap * 2.0 - mbot)
	if ptt_btn:
		ptt_btn.size = Vector2(bw, bh)
		ptt_btn.position = Vector2((vp.x - bw) * 0.5, vp.y - bh - mbot)
	if hint_label:
		hint_label.size = Vector2(vp.x - 40.0, 40.0)
		hint_label.position = Vector2(20.0, vp.y - bh - mbot - 56.0)
	if matrix_chat_toggle_btn:
		matrix_chat_toggle_btn.size = Vector2(bw, bh)
		matrix_chat_toggle_btn.position = Vector2(mleft, vp.y - bh - mbot)
	if matrix_chat_box:
		matrix_chat_box.position = Vector2(mleft, vp.y - bh - mbot - 230.0)
	if joystick:
		joystick.size = Vector2(180, 180)
		joystick.position = Vector2(mleft + 20.0, vp.y - 180.0 - mbot - 110.0)
	if talk_req_panel:
		talk_req_panel.position = Vector2((vp.x - 300.0) * 0.5, 80.0)
	if invite_modal_overland:
		invite_modal_overland.position = Vector2((vp.x - 320.0) * 0.5, (vp.y - 120.0) * 0.5)


func _refresh_stats() -> void:
	if title_label == null:
		return
	var dname := String(DISTRICTS.get(current_district, "The Open Road"))
	title_label.text = "OPENWORLD\n%s  |  %d fps" % [dname, Engine.get_frames_per_second()]
	if world_label != null:
		var found := discovered.size()
		var names: Array = []
		for k in DISTRICTS:
			if discovered.has(k):
				names.append(String(DISTRICTS[k]))
		var yours := ", ".join(names) if not names.is_empty() else "none yet"
		var done := "  [DONE]" if (rpg and rpg.has_flag("saw_the_world")) else ""
		var online := net.player_count() if net != null else 1
		world_label.text = "[b]PLAYERS[/b]\nOnline: %d\n\n[b]You[/b]: %d / %d regions\n%s\n\n[b]Goal[/b]: old town plaza%s" % [
			online, found, DISTRICT_COUNT, yours, done]


# ---------------- safe area ----------------

func _safe_insets() -> Dictionary:
	if not OS.has_feature("web"):
		return {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}
	var js := """(() => { const d = document.createElement('div'); d.style.cssText =
		'position:fixed;top:env(safe-area-inset-top);bottom:env(safe-area-inset-bottom);left:env(safe-area-inset-left);right:env(safe-area-inset-right)';
		document.body.appendChild(d); const r = getComputedStyle(d);
		const o = {top:parseFloat(r.top)||0, bottom:parseFloat(r.bottom)||0, left:parseFloat(r.left)||0, right:parseFloat(r.right)||0};
		d.remove(); return JSON.stringify(o); })()"""
	var raw: String = str(JavaScriptBridge.eval(js, true))
	var d: Dictionary = JSON.parse_string(raw) if raw != "" and raw != "null" else {}
	return d if d is Dictionary else {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}
