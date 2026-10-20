extends CharacterBody3D

const SPEED = 5.0
const SPRINT_SPEED = 8.0
const JUMP_SPEED = 5.0
const TACKLE_SPEED = 9.0
const FIELD_HALF_WIDTH := 34.0
const FIELD_HALF_LENGTH := 52.5
const PENALTY_AREA_HALF_WIDTH := 20.15
const PENALTY_AREA_DEPTH := 16.5
const mouse_sensitivity = 0.003
const KEEPER_COLOR := Color(1.0, 0.78, 0.05)
const ROBOT_TEAM_TINT := Color(0.48, 0.68, 1.0)
const HUMAN_TEAM_KIT_COLOR := Color(0.88, 0.08, 0.1)
const PLAYER_HEIGHT := 1.87
const MAX_ACTION_CHARGE_SECONDS := 1.5
const MATCH_KEEPER_SCENE = preload("res://goalkeeper_stylized.glb")
const KEEPER_DIVE_SCENE = preload("res://goalkeeper_diving_save_requested.glb")
const HUMAN_MODEL_SCENE = preload("res://Assets/FootballHuman/Soccer Pass.fbx")
const KICK_SOCCERBALL_ANIMATION_SCENE = preload("res://Assets/FootballHuman/Kick Soccerball.fbx")
const FALL_FLAT_ANIMATION_SCENE = preload("res://Assets/FootballHuman/Fall Flat.fbx")
const GOAL_FLIP_ANIMATION_SCENE = preload("res://Assets/MatchCelebrations/Running Forward Flip.fbx")
const HUMAN_GOAL_CELEBRATION_SCENE = preload("res://Assets/MatchCelebrations/Slide Hip Hop Dance.fbx")
const ROBOT_GOAL_CELEBRATION_SCENE = preload("res://Assets/MatchCelebrations/Hip Hop Dancing.fbx")
const FOOTBALL_MODEL_UTILS = preload("res://football_model_utils.gd")

@export var team := MatchManager.TEAM_AUTO:
	set(value):
		team = value
		_schedule_match_spawn_refresh()
@export var role := -1:
	set(value):
		role = value
		_schedule_match_spawn_refresh()
@export var username := "Player":
	set(value):
		username = value
		_schedule_match_spawn_refresh()
@export var controller_peer_id := 0
@export var field_slot := -1
@export var is_ai := false
var spawn_position := Vector3.ZERO
var is_diving := false
var is_local_selected := false

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var keeper_input_cooldown := 0.0
var keeper_space_pressed := false
var keeper_aim_side := 0
var selected_curve := 0.0
var tackle_timer := 0.0
var tackle_stun_timer := 0.0
var goal_celebration_active := false
var tackle_key_held := false
var pass_key_held := false
var through_key_held := false
var cross_key_held := false
var clearance_key_held := false
var set_piece_aiming := false
var player_push_cooldown := 0.0
var charging_action := ""
var dive_timer := 0.0
var sprint_active := false
var contact_impulse := Vector3.ZERO
var current_animation := ""
var match_animation_sync_ready := true
var animation_player: AnimationPlayer
var active_model: Node3D
var human_model: Node3D
var human_model_active := false
var robot_model_fitted := false
var bot_skeleton: Skeleton3D
var kick_bones: Array[int] = []
var kick_rest_rotations: Array[Quaternion] = []
var kick_animation_time := 0.0
var match_keeper_model: Node3D
var match_keeper_base_scale := Vector3.ONE
var match_keeper_base_position := Vector3.ZERO
var match_keeper_dive_start_y := 0.0
var match_keeper_visuals: Array[VisualInstance3D] = []
var match_keeper_skeleton: Skeleton3D
var match_keeper_animation: AnimationPlayer
var match_keeper_leg_bones: Array[int] = []
var match_keeper_leg_rest_rotations: Array[Quaternion] = []
var match_keeper_leg_rest_positions: Array[Vector3] = []
var match_keeper_arm_bones: Array[int] = []
var match_keeper_arm_rest_rotations: Array[Quaternion] = []
var match_keeper_step_time := 0.0
var match_keeper_movement_axis := 0.0
var match_keeper_forward_axis := 0.0
var match_input_sync_timer := 0.0
var match_jump_held := false
var match_tackle_held := false
var match_clear_held := false
var selection_ring: MeshInstance3D

@onready var bot: Node3D = $GDBot
@onready var name_tag: Label3D = $NameTag
@onready var mobile_ui: CanvasLayer = $MobileUI
@onready var joystick: MobileVirtualJoystick = $MobileUI/MovementJoystick
@onready var aim_joystick: MobileVirtualJoystick = $MobileUI/AimJoystick
@onready var aim_label: Label = $MobileUI/AimLabel
@onready var shot_button: Button = $MobileUI/ShotBtn
@onready var curve_left_button: Button = $MobileUI/CurveLeftBtn
@onready var curve_right_button: Button = $MobileUI/CurveRightBtn
@onready var pass_button: Button = $MobileUI/PassBtn
@onready var through_button: Button = $MobileUI/ThroughBtn
@onready var cross_button: Button = $MobileUI/CrossBtn
@onready var tackle_button: Button = $MobileUI/TackleBtn
@onready var jump_button: Button = $MobileUI/JumpBtn
@onready var sprint_button: Button = $MobileUI/SprintBtn

var shot_charge := 0.0
var shot_charging := false

func _enter_tree():
	set_multiplayer_authority(1 if MatchManager.game_mode == MatchManager.MODE_MATCH else name.to_int())

func _schedule_match_spawn_refresh() -> void:
	if is_node_ready() and MatchManager.game_mode == MatchManager.MODE_MATCH:
		call_deferred("_refresh_match_spawn_properties")

func _refresh_match_spawn_properties() -> void:
	if not is_inside_tree() or MatchManager.game_mode != MatchManager.MODE_MATCH:
		return
	_configure_team_model()
	if role == MatchManager.ROLE_GOALKEEPER:
		_apply_match_keeper_spawn()
		if active_model:
			active_model.visible = false
		bot.visible = false
		if match_keeper_model == null:
			_setup_match_keeper_model()
	_update_name_tag()
	_set_local_selected(is_local_selected)

func _ready():
	if MatchManager.game_mode == MatchManager.MODE_MATCH:
		match_animation_sync_ready = false
		call_deferred("_enable_match_animation_sync")
	if jump_button:
		jump_button.custom_minimum_size = Vector2(160, 90)
		jump_button.add_theme_font_size_override("font_size", 26)
	if MatchManager.game_mode != MatchManager.MODE_MATCH:
		get_node("audioManager").setupAudio(name.to_int())
	MatchManager.player_state_changed.connect(_on_player_state_changed)
	if MatchManager.game_mode != MatchManager.MODE_MATCH and role < 0:
		role = MatchManager.role_for_peer(name.to_int())
	if MatchManager.game_mode != MatchManager.MODE_MATCH and team == MatchManager.TEAM_AUTO:
		team = MatchManager.team_for_peer(name.to_int())
	if MatchManager.game_mode != MatchManager.MODE_MATCH:
		username = MatchManager.username_for_peer(name.to_int())
	if MatchManager.game_mode == MatchManager.MODE_MATCH and role == MatchManager.ROLE_GOALKEEPER:
		_apply_match_keeper_spawn()
	bot.rotation.y = PI
	_configure_team_model()
	if MatchManager.game_mode == MatchManager.MODE_MATCH and role == MatchManager.ROLE_GOALKEEPER:
		if active_model:
			active_model.visible = false
		bot.visible = false
		_setup_match_keeper_model()
	_update_name_tag()
	name_tag.visible = true
	var free_kick_game = get_tree().current_scene.get_node_or_null("FreeKickController")
	if free_kick_game:
		if active_model:
			active_model.visible = false
		name_tag.visible = false
	shot_button.button_down.connect(_on_shot_button_down)
	tackle_button.button_down.connect(_on_tackle_button_down)
	jump_button.button_down.connect(_on_jump_button_down)
	_update_role_controls()
	
	if MatchManager.game_mode == MatchManager.MODE_MATCH:
		_set_local_selected(false)
		return
	if !is_multiplayer_authority():
		return
	
	$Camera3D.current = true
	$MeshInstance3D.visible = false
	if active_model:
		active_model.visible = false
	name_tag.visible = false

	if OS.has_feature("mobile") or OS.get_name() == "Android":
		mobile_ui.visible = true
	_apply_free_kick_role_view()
	if MatchManager.game_mode == MatchManager.MODE_MATCH:
		_apply_match_camera()
	_update_role_controls()

func _input(event):
	if MatchManager.game_mode == MatchManager.MODE_MATCH:
		if not is_local_selected:
			return
		if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			if role == MatchManager.ROLE_GOALKEEPER or set_piece_aiming:
				$Camera3D.rotation.y = clampf($Camera3D.rotation.y - event.relative.x * mouse_sensitivity, -0.8, 0.8)
			else:
				$Camera3D.rotation.y -= event.relative.x * mouse_sensitivity
			$Camera3D.rotate_x(-event.relative.y * mouse_sensitivity)
			$Camera3D.rotation.x = clampf($Camera3D.rotation.x, -deg_to_rad(70), deg_to_rad(70))
		if event is InputEventMouseButton and event.pressed and not mobile_ui.visible:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return
	if !is_multiplayer_authority():
		return

	# Desktop mouse look
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not _is_free_kick_keeper():
		if MatchManager.game_mode == MatchManager.MODE_MATCH and role == MatchManager.ROLE_GOALKEEPER:
			$Camera3D.rotation.y = clampf($Camera3D.rotation.y - event.relative.x * mouse_sensitivity, -0.8, 0.8)
		else:
			rotate_y(-event.relative.x * mouse_sensitivity)
		$Camera3D.rotate_x(-event.relative.y * mouse_sensitivity)
		$Camera3D.rotation.x = clampf($Camera3D.rotation.x, -deg_to_rad(70), deg_to_rad(70))
	if event is InputEventMouseButton and event.pressed and not mobile_ui.visible:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _apply_match_camera():
	if not is_local_selected:
		return
	var camera: Camera3D = $Camera3D
	camera.current = false
	if role == MatchManager.ROLE_GOALKEEPER:
		camera.position = Vector3(0.0, 1.65, 0.0)
		camera.rotation.x = deg_to_rad(-5.0)
	else:
		camera.position = Vector3(0.0, 3.0, 5.5)
		camera.rotation.x = deg_to_rad(-20.0)

func _set_local_selected(selected: bool) -> void:
	if not selected and set_piece_aiming:
		end_set_piece_aim()
	is_local_selected = selected
	var camera := $Camera3D as Camera3D
	camera.current = false
	mobile_ui.visible = selected and (OS.has_feature("mobile") or OS.get_name() == "Android")
	if active_model:
		active_model.visible = role != MatchManager.ROLE_GOALKEEPER
	if role == MatchManager.ROLE_GOALKEEPER:
		bot.visible = false
	if match_keeper_model:
		match_keeper_model.visible = true
	name_tag.visible = true
	if selected:
		_apply_match_camera()
		if selection_ring == null:
			selection_ring = MeshInstance3D.new()
			selection_ring.name = "LocalSelectionRing"
			var ring := TorusMesh.new()
			ring.inner_radius = 0.34
			ring.outer_radius = 0.43
			selection_ring.mesh = ring
			var ring_material := StandardMaterial3D.new()
			ring_material.albedo_color = Color(0.72, 0.18, 1.0, 0.98)
			ring_material.emission_enabled = true
			ring_material.emission = Color(0.62, 0.08, 1.0)
			ring_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			selection_ring.material_override = ring_material
			selection_ring.position.y = 0.045
			add_child(selection_ring)
		selection_ring.visible = true
	elif selection_ring:
		selection_ring.visible = false
	if MatchManager.game_mode == MatchManager.MODE_MATCH:
		_update_role_controls()

func _get_field_arrow_input() -> Vector2:
	return Vector2(
		float(Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_UP)),
		float(Input.is_key_pressed(KEY_LEFT)) - float(Input.is_key_pressed(KEY_RIGHT))
	)


func _submit_match_input(delta: float) -> void:
	match_input_sync_timer -= delta
	if match_input_sync_timer > 0.0:
		return
	match_input_sync_timer = 0.05
	var game := _get_game_controller()
	if game == null:
		return
	var move_input := _get_field_arrow_input()
	if mobile_ui.visible and joystick.value.length() > 0.1:
		move_input = joystick.value
	if role == MatchManager.ROLE_PLAYER and Input.is_key_pressed(KEY_S) and not game.can_local_shoot():
		var ball_node := game.get("ball") as Node3D
		if ball_node:
			var toward_ball := ball_node.global_position - global_position
			toward_ball.y = 0.0
			if toward_ball.length_squared() > 0.01:
				move_input = Vector2(toward_ball.x, toward_ball.z).normalized()
	var jump_pressed := Input.is_key_pressed(KEY_SPACE) or (mobile_ui.visible and jump_button.is_pressed())
	game.submit_controller_input(
		self,
		move_input.limit_length(1.0),
		$Camera3D.global_rotation.y,
		Input.is_key_pressed(KEY_E) or (mobile_ui.visible and sprint_button.is_pressed()),
		jump_pressed and not match_jump_held,
		Input.is_key_pressed(KEY_C)
	)
	match_jump_held = jump_pressed

func _update_match_local_process(delta: float) -> void:
	var game := _get_game_controller()
	if game == null or not game.game_started:
		return
	if mobile_ui.visible:
		$Camera3D.rotation.y = clampf($Camera3D.rotation.y - aim_joystick.value.x * 2.4 * delta, -PI, PI)
		$Camera3D.rotate_x(-aim_joystick.value.y * 2.0 * delta)
		$Camera3D.rotation.x = clampf($Camera3D.rotation.x, -deg_to_rad(70), deg_to_rad(70))
	if set_piece_aiming:
		_update_set_piece_aim(delta, game)
		return
	if role == MatchManager.ROLE_GOALKEEPER:
		var clear_pressed := Input.is_key_pressed(KEY_D)
		if clear_pressed and not match_clear_held:
			_request_action("clearance", 0.8)
		match_clear_held = clear_pressed
		var dive_pressed := Input.is_key_pressed(KEY_SPACE) or (mobile_ui.visible and jump_button.is_pressed())
		if dive_pressed and not match_jump_held:
			var keeper_axis := float(Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_LEFT))
			var side := signi(keeper_axis) if absf(keeper_axis) > 0.05 else 1
			game.request_keeper_dive(side)
		match_jump_held = dive_pressed
		return

	var can_act_on_ball: bool = game.can_local_shoot()
	var slide_tackle_pressed := Input.is_key_pressed(KEY_A) or (mobile_ui.visible and tackle_button.is_pressed())
	var tackle_pressed := Input.is_key_pressed(KEY_D) or slide_tackle_pressed
	if tackle_pressed and not match_tackle_held and not can_act_on_ball:
		_start_tackle(slide_tackle_pressed)
	match_tackle_held = tackle_pressed
	match_clear_held = Input.is_key_pressed(KEY_D)
	_update_match_action_charge(delta)

func _match_server_physics(delta: float) -> void:
	var game := _get_game_controller()
	if game == null or not game.game_started:
		velocity = Vector3.ZERO
		return
	if goal_celebration_active:
		velocity = Vector3.ZERO
		return
	tackle_timer = maxf(0.0, tackle_timer - delta)
	if role == MatchManager.ROLE_PLAYER and global_position.y < -3.0:
		global_position = spawn_position
		velocity = Vector3.ZERO
		contact_impulse = Vector3.ZERO
		is_diving = false
		rotation.z = 0.0
		return
	if role == MatchManager.ROLE_PLAYER and tackle_stun_timer > 0.0:
		tackle_stun_timer = maxf(0.0, tackle_stun_timer - delta)
		velocity.x = move_toward(velocity.x, 0.0, delta * 12.0)
		velocity.z = move_toward(velocity.z, 0.0, delta * 12.0)
		if not is_on_floor():
			velocity.y -= gravity * delta
		move_and_slide()
		global_position.x = clampf(global_position.x, -FIELD_HALF_WIDTH + 0.5, FIELD_HALF_WIDTH - 0.5)
		global_position.z = clampf(global_position.z, -FIELD_HALF_LENGTH + 0.5, FIELD_HALF_LENGTH - 0.5)
		return
	var input_state: Dictionary = game.server_input_for(self)
	if input_state.is_empty():
		input_state = game.ai_input_for(self, delta)
	var movement := Vector3.ZERO
	if input_state.has("world_move"):
		movement = input_state.world_move
	elif input_state.has("move"):
		movement = Vector3(input_state.move.x, 0.0, input_state.move.y)
	movement.y = 0.0
	if movement.length_squared() > 0.01:
		rotation.y = atan2(-movement.x, -movement.z)
	elif input_state.has("yaw"):
		rotation.y = input_state.yaw
	if role == MatchManager.ROLE_GOALKEEPER:
		match_keeper_movement_axis = input_state.get("move", Vector2.ZERO).x
		match_keeper_forward_axis = input_state.get("move", Vector2.ZERO).y
		if input_state.has("world_move"):
			position.x += movement.x * 6.0 * delta
			position.z += movement.z * 5.0 * delta
		else:
			position.x += input_state.get("move", Vector2.ZERO).x * 6.0 * delta
			position.z += input_state.get("move", Vector2.ZERO).y * 5.0 * delta
		position.x = clampf(position.x, -PENALTY_AREA_HALF_WIDTH, PENALTY_AREA_HALF_WIDTH)
		if position.z < 0.0:
			position.z = clampf(position.z, -FIELD_HALF_LENGTH, -FIELD_HALF_LENGTH + PENALTY_AREA_DEPTH)
		else:
			position.z = clampf(position.z, FIELD_HALF_LENGTH - PENALTY_AREA_DEPTH, FIELD_HALF_LENGTH)
		if input_state.get("jump", false):
			game.start_ai_keeper_dive(self)
		_update_match_keeper_footwork(delta)
		velocity = Vector3.ZERO
		game.try_ai_ball_action(self)
		return
	if input_state.get("jump", false) and is_on_floor():
		velocity.y = JUMP_SPEED
	if not is_on_floor():
		velocity.y -= gravity * delta
	var contain_active: bool = input_state.get("contain", false)
	var sprint_requested: bool = input_state.get("sprint", false) and not contain_active
	var speed := SPRINT_SPEED if sprint_requested else (minf(SPEED, 5.0) if contain_active else SPEED)
	sprint_active = sprint_requested
	var movement_strength := minf(movement.length(), 1.0)
	if movement_strength > 0.0:
		movement = movement.normalized()
		velocity.x = movement.x * speed * movement_strength
		velocity.z = movement.z * speed * movement_strength
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)
		velocity.z = move_toward(velocity.z, 0.0, SPEED)
	velocity.x += contact_impulse.x
	velocity.z += contact_impulse.z
	contact_impulse = contact_impulse.move_toward(Vector3.ZERO, delta * 7.0)
	var movement_velocity := velocity
	move_and_slide()
	global_position.x = clampf(global_position.x, -FIELD_HALF_WIDTH + 0.5, FIELD_HALF_WIDTH - 0.5)
	global_position.z = clampf(global_position.z, -FIELD_HALF_LENGTH + 0.5, FIELD_HALF_LENGTH - 0.5)
	_push_colliding_players(movement_velocity)
	_update_movement_animation()
	game.update_player_dribble(self, movement, delta)
	game.try_ai_ball_action(self)

func _apply_match_keeper_spawn():
	var marker_name := "BlueKeeperSpawn" if team == MatchManager.TEAM_BLUE else "RedKeeperSpawn"
	var marker := get_node_or_null("../../MatchEnvironment/%s" % marker_name) as Marker3D
	if marker == null:
		push_error("Missing match goalkeeper spawn marker: %s" % marker_name)
		return
	global_transform = marker.global_transform
	spawn_position = marker.global_position
	velocity = Vector3.ZERO

func _physics_process(delta):
	if MatchManager.game_mode == MatchManager.MODE_MATCH:
		if is_local_selected and controller_peer_id == multiplayer.get_unique_id():
			_submit_match_input(delta)
		if multiplayer.is_server():
			_match_server_physics(delta)
		elif is_local_selected:
			_submit_match_input(delta)
		return
	if !is_multiplayer_authority():
		return
	player_push_cooldown = maxf(0.0, player_push_cooldown - delta)
	var fell_out_of_world := global_position.y < -3.0
	if fell_out_of_world or absf(global_position.x) > FIELD_HALF_WIDTH + 2.0 or absf(global_position.z) > FIELD_HALF_LENGTH + 3.0:
		if fell_out_of_world:
			MatchManager.notify_local_player_fell()
		global_position = spawn_position
		velocity = Vector3.ZERO
		contact_impulse = Vector3.ZERO
		is_diving = false
		rotation.z = 0.0
		return
	if not MatchManager.match_ready:
		return
	var free_kick_game = get_tree().current_scene.get_node_or_null("FreeKickController")
	if free_kick_game:
		if role == MatchManager.ROLE_GOALKEEPER:
			global_position = free_kick_game.get_keeper_position()
			velocity = Vector3.ZERO
			var keeper_axis = float(Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_LEFT))
			var keeper_depth_axis = float(Input.is_key_pressed(KEY_UP)) - float(Input.is_key_pressed(KEY_DOWN))
			if mobile_ui.visible:
				keeper_axis = joystick.value.x
				keeper_depth_axis = -joystick.value.y
			if absf(keeper_axis) > 0.05:
				keeper_aim_side = signi(keeper_axis)
			free_kick_game.move_keeper(keeper_axis, keeper_depth_axis)
			var dive_pressed = Input.is_key_pressed(KEY_SPACE)
			if dive_pressed and not keeper_space_pressed:
				var dive_side = signi(keeper_axis) if absf(keeper_axis) > 0.05 else 1
				free_kick_game.request_keeper_dive(dive_side)
			keeper_space_pressed = dive_pressed
		else:
			velocity = Vector3.ZERO
		return
	if role == MatchManager.ROLE_GOALKEEPER:
		rotation.y = 0.0 if global_position.z > 0.0 else PI
		keeper_input_cooldown -= delta
		if keeper_input_cooldown <= 0.0:
			var keeper_input := _get_field_arrow_input()
			var keeper_axis := keeper_input.x
			var keeper_depth_axis := keeper_input.y
			if mobile_ui.visible:
				keeper_axis = joystick.value.x
				keeper_depth_axis = -joystick.value.y
			if absf(keeper_axis) > 0.1:
				keeper_aim_side = signi(keeper_axis)
			match_keeper_movement_axis = keeper_axis
			match_keeper_forward_axis = keeper_depth_axis
			position.x = clampf(position.x + keeper_axis * 6.0 * delta, -PENALTY_AREA_HALF_WIDTH, PENALTY_AREA_HALF_WIDTH)
			position.z += keeper_depth_axis * 5.0 * delta
			position.x = clampf(position.x + contact_impulse.x * delta, -PENALTY_AREA_HALF_WIDTH, PENALTY_AREA_HALF_WIDTH)
			position.z += contact_impulse.z * delta
			if position.z < 0.0:
				position.z = clampf(position.z, -FIELD_HALF_LENGTH, -FIELD_HALF_LENGTH + PENALTY_AREA_DEPTH)
			else:
				position.z = clampf(position.z, FIELD_HALF_LENGTH - PENALTY_AREA_DEPTH, FIELD_HALF_LENGTH)
			contact_impulse = contact_impulse.move_toward(Vector3.ZERO, delta * 7.0)
			keeper_input_cooldown = 0.05
		_update_match_keeper_footwork(delta)
		var space_pressed = Input.is_key_pressed(KEY_SPACE)
		if space_pressed and not keeper_space_pressed:
			var game = _get_game_controller()
			if game:
				game.request_keeper_dive(keeper_aim_side)
		keeper_space_pressed = space_pressed
		var clearance_pressed := Input.is_key_pressed(KEY_D) if MatchManager.game_mode == MatchManager.MODE_MATCH else Input.is_key_pressed(KEY_E)
		if clearance_pressed and not clearance_key_held:
			_request_action("clearance", 0.0)
		clearance_key_held = clearance_pressed
		return

	if not is_on_floor():
		velocity.y -= gravity * delta

	var input_dir := Vector2.ZERO
	if MatchManager.game_mode == MatchManager.MODE_MATCH:
		input_dir = Vector2(
			float(Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_LEFT)),
			float(Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_UP))
		)
	else:
		input_dir = Input.get_vector("a", "d", "w", "s")
	if mobile_ui.visible and joystick.value.length() > 0.1:
		input_dir = joystick.value

	var tackle_pressed = Input.is_key_pressed(KEY_F)
	if tackle_pressed and not tackle_key_held and tackle_timer <= 0.0:
		_start_tackle()
	tackle_key_held = tackle_pressed
	tackle_timer = maxf(0.0, tackle_timer - delta)
	var direction = transform.basis * Vector3(input_dir.x, 0, input_dir.y)
	var movement_strength = minf(direction.length(), 1.0)
	if movement_strength > 0.0:
		direction = direction.normalized()
		var sprint_key := KEY_E if MatchManager.game_mode == MatchManager.MODE_MATCH else KEY_SHIFT
		sprint_active = Input.is_key_pressed(sprint_key) or (mobile_ui.visible and sprint_button.is_pressed())
		var speed = SPRINT_SPEED if sprint_active else SPEED
		velocity.x = direction.x * speed * movement_strength
		velocity.z = direction.z * speed * movement_strength
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)
	velocity.x += contact_impulse.x
	velocity.z += contact_impulse.z
	contact_impulse = contact_impulse.move_toward(Vector3.ZERO, delta * 7.0)

	var movement_velocity := velocity
	move_and_slide()
	_push_colliding_players(movement_velocity)
	_update_movement_animation()
	
	if Input.is_action_just_pressed("esc"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if Input.is_key_pressed(KEY_SPACE) and is_on_floor():
		_jump()
func _process(delta: float):
	if kick_animation_time > 0.0:
		kick_animation_time += delta
		_update_kick_pose()
	if dive_timer > 0.0:
		dive_timer -= delta
		if dive_timer <= 0.0:
			set_diving_local(false, 0)
	_keep_match_keeper_above_pitch()
	if MatchManager.game_mode == MatchManager.MODE_MATCH:
		if is_local_selected:
			_update_match_local_process(delta)
		return
	if not is_multiplayer_authority():
		return
	if _is_free_kick_keeper():
		_update_free_kick_keeper_camera()
	elif mobile_ui.visible:
		if MatchManager.game_mode == MatchManager.MODE_MATCH and role == MatchManager.ROLE_GOALKEEPER:
			$Camera3D.rotation.y = clampf($Camera3D.rotation.y - aim_joystick.value.x * 2.4 * delta, -0.8, 0.8)
		else:
			rotate_y(-aim_joystick.value.x * 2.4 * delta)
		$Camera3D.rotate_x(-aim_joystick.value.y * 2.0 * delta)
		$Camera3D.rotation.x = clampf($Camera3D.rotation.x, -deg_to_rad(70), deg_to_rad(70))
	if MatchManager.game_mode == MatchManager.MODE_MATCH:
		_update_match_action_charge(delta)
		return
	var curve_axis = _get_curve_axis()
	var game = _get_game_controller()
	var can_shoot := false
	if game:
		can_shoot = game.can_local_shoot()
	var holding_keyboard_shot := MatchManager.game_mode == MatchManager.MODE_MATCH and Input.is_key_pressed(KEY_D)
	var holding_shot = can_shoot and role == MatchManager.ROLE_PLAYER and (
		(holding_keyboard_shot or (MatchManager.game_mode == MatchManager.MODE_FREE_KICK and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED))
		or (mobile_ui.visible and shot_button.is_pressed())
	)
	if holding_shot:
		shot_charging = true
		shot_charge = minf(shot_charge + delta, 1.5)
		if absf(curve_axis) > 0.05:
			selected_curve = curve_axis
	else:
		if shot_charging:
			_fire_shot(selected_curve)
		shot_charging = false
		shot_charge = 0.0
		selected_curve = 0.0
	if game:
		game.update_charge(shot_charge, shot_charging, selected_curve if shot_charging else 0.0)
		if MatchManager.game_mode == MatchManager.MODE_FREE_KICK:
			game.update_aim_preview(
				-$Camera3D.global_transform.basis.z,
				selected_curve,
				role == MatchManager.ROLE_PLAYER
			)

func _fire_shot(curve: float):
	var game = _get_game_controller()
	if game == null:
		return
	if human_model_active:
		_play_animation("shot")
	var shot_direction = -$Camera3D.global_transform.basis.z
	if MatchManager.game_mode == MatchManager.MODE_MATCH:
		game.request_ball_action(shot_direction, shot_charge / MAX_ACTION_CHARGE_SECONDS, curve, "shot", name)
	else:
		game.submit_shot(shot_direction, shot_charge, curve)

func begin_set_piece_aim() -> void:
	if not is_local_selected:
		return
	set_piece_aiming = true
	charging_action = ""
	shot_charge = 0.0
	shot_charging = false
	var camera := $Camera3D as Camera3D
	camera.position = Vector3(0.0, 3.0, 5.5)
	camera.rotation = Vector3(deg_to_rad(-12.0), 0.0, 0.0)
	camera.make_current()
	if not mobile_ui.visible:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func end_set_piece_aim() -> void:
	if not set_piece_aiming:
		return
	set_piece_aiming = false
	charging_action = ""
	shot_charge = 0.0
	shot_charging = false
	var camera := $Camera3D as Camera3D
	camera.rotation.y = 0.0
	_apply_match_camera()
	var stadium_camera := get_tree().current_scene.get("stadium_camera") as Camera3D
	if is_instance_valid(stadium_camera):
		stadium_camera.make_current()

func _update_set_piece_aim(delta: float, game: Node) -> void:
	var firing := (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED) \
		or Input.is_key_pressed(KEY_D) or (mobile_ui.visible and shot_button.is_pressed())
	var curve := _get_curve_axis()
	if firing:
		shot_charging = true
		shot_charge = minf(shot_charge + delta, MAX_ACTION_CHARGE_SECONDS)
	elif shot_charging:
		var action := "clearance" if role == MatchManager.ROLE_GOALKEEPER else "shot"
		if human_model_active:
			_play_animation("keeper_kick" if action == "clearance" else "shot")
		game.request_ball_action(
			-$Camera3D.global_transform.basis.z,
			maxf(shot_charge / MAX_ACTION_CHARGE_SECONDS, 0.15),
			curve,
			action,
			name
		)
		shot_charging = false
		shot_charge = 0.0
	game.update_charge(shot_charge, shot_charging, curve if shot_charging else 0.0, "shot")

func _update_match_action_charge(delta: float):
	var game := _get_game_controller()
	var next_action := ""
	if role == MatchManager.ROLE_PLAYER and game != null and game.can_local_shoot():
		if Input.is_key_pressed(KEY_D) or (mobile_ui.visible and shot_button.is_pressed()):
			next_action = "shot"
		elif Input.is_key_pressed(KEY_S) or (mobile_ui.visible and pass_button.is_pressed()):
			next_action = "pass"
		elif Input.is_key_pressed(KEY_W) or (mobile_ui.visible and through_button.is_pressed()):
			next_action = "lofted_through" if Input.is_key_pressed(KEY_Q) else "through"
		elif Input.is_key_pressed(KEY_A) or (mobile_ui.visible and cross_button.is_pressed()):
			next_action = "cross"

	if not next_action.is_empty():
		if charging_action != next_action:
			charging_action = next_action
			shot_charge = 0.0
			shot_charging = true
		shot_charge = minf(shot_charge + delta, MAX_ACTION_CHARGE_SECONDS)
	elif not charging_action.is_empty():
		if human_model_active:
			_play_animation("shot" if charging_action == "shot" else "pass")
		game.request_ball_action(
			-$Camera3D.global_transform.basis.z,
			shot_charge / MAX_ACTION_CHARGE_SECONDS,
			0.0,
			charging_action,
			name
		)
		charging_action = ""
		shot_charge = 0.0
		shot_charging = false

	if game:
		game.update_charge(shot_charge, shot_charging, 0.0, charging_action)

func _request_action(action: String, power: float):
	var game = _get_game_controller()
	if game:
		if human_model_active:
			if action == "clearance":
				_play_animation("keeper_kick")
			elif action == "pass" or action == "through" or action == "cross":
				_play_animation("pass")
		game.request_ball_action(-$Camera3D.global_transform.basis.z, power, 0.0, action, name if MatchManager.game_mode == MatchManager.MODE_MATCH else "")

func _get_game_controller() -> Node:
	var controller_name := "FootballMatchController" if MatchManager.game_mode == MatchManager.MODE_MATCH else "FreeKickController"
	return get_tree().current_scene.get_node_or_null(controller_name)

func _get_curve_axis() -> float:
	if mobile_ui.visible:
		return float(curve_right_button.is_pressed()) - float(curve_left_button.is_pressed())
	return float(Input.is_key_pressed(KEY_T)) - float(Input.is_key_pressed(KEY_R))

func _on_shot_button_down():
	if role != MatchManager.ROLE_GOALKEEPER:
		return
	_request_action("clearance", 0.0)

func _on_pass_button_down():
	if role == MatchManager.ROLE_PLAYER:
		_request_action("pass", 0.45)

func _on_through_button_down():
	if role == MatchManager.ROLE_PLAYER:
		_request_action("through", 0.55)

func _on_cross_button_down():
	if role == MatchManager.ROLE_PLAYER:
		_request_action("cross", 0.65)

func _on_tackle_button_down():
	if role == MatchManager.ROLE_PLAYER:
		_start_tackle()

func _on_jump_button_down():
	if role == MatchManager.ROLE_GOALKEEPER:
		var game = _get_game_controller()
		if game:
			var keeper_axis = float(Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_LEFT))
			if mobile_ui.visible:
				keeper_axis = joystick.value.x
			var dive_side = signi(keeper_axis) if absf(keeper_axis) > 0.05 else 1
			game.request_keeper_dive(dive_side)
	elif MatchManager.game_mode == MatchManager.MODE_MATCH:
		var game := _get_game_controller()
		if game:
			game.submit_controller_input(self, Vector2.ZERO, $Camera3D.global_rotation.y, false, true)
	else:
		_jump()

func _role_name(value: int) -> String:
	if value == MatchManager.ROLE_GOALKEEPER:
		return "GOALKEEPER"
	return "PLAYER"

func _on_player_state_changed(peer_id: int, new_team: int, new_role: int, new_username: String):
	if peer_id != name.to_int() or new_team < 0:
		return
	team = new_team
	role = new_role
	username = new_username
	_configure_team_model()
	if MatchManager.game_mode == MatchManager.MODE_MATCH and role == MatchManager.ROLE_GOALKEEPER:
		_apply_match_keeper_spawn()
	if MatchManager.game_mode == MatchManager.MODE_MATCH and role == MatchManager.ROLE_GOALKEEPER and match_keeper_model == null:
		if active_model:
			active_model.visible = false
		bot.visible = false
		_setup_match_keeper_model()
	if get_tree().current_scene.get_node_or_null("FreeKickController") and active_model:
		active_model.visible = false
	_update_name_tag()
	_update_role_controls()
	if is_multiplayer_authority():
		if active_model:
			active_model.visible = false
		_apply_free_kick_role_view()
		if MatchManager.game_mode == MatchManager.MODE_MATCH:
			_apply_match_camera()
		mobile_ui.visible = OS.has_feature("mobile") or OS.get_name() == "Android"
		_update_role_controls()

func _apply_free_kick_role_view():
	if not is_multiplayer_authority():
		return
	var game = get_tree().current_scene.get_node_or_null("FreeKickController")
	if game == null:
		return
	var camera: Camera3D = $Camera3D
	if role == MatchManager.ROLE_GOALKEEPER:
		global_position = game.get_keeper_position()
		spawn_position = global_position
		rotation.y = PI
		game.set_keeper_first_person(false)
		_update_free_kick_keeper_camera()
	else:
		global_position = game.get_shooter_position()
		spawn_position = global_position
		rotation.y = 0.0
		camera.position = Vector3(0.0, 3.0, 5.5)
		game.set_keeper_first_person(false)
		camera.look_at(game.get_camera_focus_point(), Vector3.UP)
	camera.current = true

func _is_free_kick_keeper() -> bool:
	return role == MatchManager.ROLE_GOALKEEPER and get_tree().current_scene.get_node_or_null("FreeKickController") != null

# The keeper camera stays fixed behind the goal so the view does not follow keeper movement or dives.
func _update_free_kick_keeper_camera():
	var game = get_tree().current_scene.get_node_or_null("FreeKickController")
	if game == null:
		return
	var camera: Camera3D = $Camera3D
	camera.global_position = game.get_keeper_camera_position()
	camera.look_at(game.get_camera_focus_point(), Vector3.UP)
	camera.current = true

func _update_name_tag():
	if MatchManager.game_mode == MatchManager.MODE_MATCH or MatchManager.game_mode == MatchManager.MODE_FREE_KICK:
		var team_name := "HUMAN" if team == MatchManager.TEAM_RED else "ROBOT"
		name_tag.text = "%s | %s | %s" % [username, team_name, _role_name(role)]
	else:
		name_tag.text = "%s | %s" % [username, _role_name(role)]

func _configure_team_model() -> void:
	var use_human_model := team == MatchManager.TEAM_RED
	if active_model != null and human_model_active == use_human_model:
		return
	if animation_player:
		animation_player.stop()
	current_animation = ""
	kick_bones.clear()
	kick_rest_rotations.clear()
	if human_model:
		human_model.visible = false
	if use_human_model:
		if human_model == null or not is_instance_valid(human_model):
			human_model = HUMAN_MODEL_SCENE.instantiate() as Node3D
			human_model.name = "HumanFootballer"
			human_model.rotation.y = PI
			add_child(human_model)
			AvatarCatalog.apply_male_textures(human_model, HUMAN_TEAM_KIT_COLOR)
			_fit_model_height(human_model, PLAYER_HEIGHT)
		active_model = human_model
		bot.visible = false
	else:
		active_model = bot
		bot.visible = true
		if not robot_model_fitted:
			_fit_model_height(bot, PLAYER_HEIGHT)
			_tint_model(bot, ROBOT_TEAM_TINT)
			robot_model_fitted = true
	human_model_active = use_human_model
	active_model.visible = true
	_setup_animations()

func _fit_model_height(model: Node3D, target_height: float):
	AvatarCatalog.fit_model_to_height(model, target_height)

func _setup_match_keeper_model():
	match_keeper_model = MATCH_KEEPER_SCENE.instantiate() as Node3D
	match_keeper_model.name = "MatchGoalkeeperModel"
	match_keeper_model.rotation.y = PI
	add_child(match_keeper_model)
	_fit_model_height(match_keeper_model, PLAYER_HEIGHT)
	match_keeper_base_scale = match_keeper_model.scale
	match_keeper_base_position = match_keeper_model.position
	for visual in match_keeper_model.find_children("*", "VisualInstance3D", true, false):
		match_keeper_visuals.append(visual as VisualInstance3D)
	var skeletons := match_keeper_model.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		push_error("Match goalkeeper model has no Skeleton3D.")
		return
	match_keeper_skeleton = skeletons[0] as Skeleton3D
	_cache_match_keeper_leg_bones()
	_cache_match_keeper_arm_bones()
	_tint_model(match_keeper_model, KEEPER_COLOR)

	var dive_source := KEEPER_DIVE_SCENE.instantiate() as Node3D
	var source_players := dive_source.find_children("*", "AnimationPlayer", true, false)
	if source_players.is_empty():
		push_error("Goalkeeper dive asset has no AnimationPlayer.")
		dive_source.free()
		return
	var source_animation_player := source_players[0] as AnimationPlayer
	match_keeper_animation = AnimationPlayer.new()
	match_keeper_animation.name = "MatchKeeperDiveAnimationPlayer"
	match_keeper_animation.root_node = NodePath("..")
	add_child(match_keeper_animation)
	var library := AnimationLibrary.new()
	var skeleton_path := get_path_to(match_keeper_skeleton)
	var imported_count := 0
	for animation_name in source_animation_player.get_animation_list():
		if animation_name == &"RESET":
			continue
		var animation := source_animation_player.get_animation(animation_name).duplicate(true) as Animation
		for track_index in range(animation.get_track_count()):
			var track_path := str(animation.track_get_path(track_index))
			var separator := track_path.rfind(":")
			if separator < 0:
				continue
			var source_bone_name := _normalized_keeper_bone_name(track_path.substr(separator + 1))
			var target_bone_name := ""
			for bone_index in range(match_keeper_skeleton.get_bone_count()):
				var candidate := match_keeper_skeleton.get_bone_name(bone_index)
				if _normalized_keeper_bone_name(candidate) == source_bone_name:
					target_bone_name = candidate
					break
			if target_bone_name.is_empty():
				continue
			if source_bone_name.to_lower() == "hips":
				FOOTBALL_MODEL_UTILS.scale_hips_position_track(
					animation,
					track_index,
					match_keeper_skeleton,
					match_keeper_skeleton.find_bone(target_bone_name)
				)
			animation.track_set_path(track_index, NodePath("%s:%s" % [skeleton_path, target_bone_name]))
		var result := library.add_animation(animation_name, animation)
		if result != OK:
			push_error("Could not retarget match goalkeeper animation %s: %s" % [animation_name, error_string(result)])
		else:
			imported_count += 1
	if imported_count == 0:
		push_error("No goalkeeper dive animations could be retargeted for match mode.")
		match_keeper_animation.queue_free()
		match_keeper_animation = null
	else:
		match_keeper_animation.add_animation_library(&"", library)
	dive_source.free()
	_reset_match_keeper_pose()
	match_keeper_model.visible = true

func _normalized_keeper_bone_name(bone_name: String) -> String:
	var normalized_name := bone_name.trim_prefix("mixamorig_").trim_prefix("mixamorig:")
	var suffix_index := normalized_name.rfind("_")
	if suffix_index >= 0 and normalized_name.substr(suffix_index + 1).is_valid_int():
		normalized_name = normalized_name.substr(0, suffix_index)
	return normalized_name

func _cache_match_keeper_leg_bones():
	for bone_suffix in ["LeftUpLeg", "LeftLeg", "LeftFoot", "RightUpLeg", "RightLeg", "RightFoot"]:
		for bone_index in range(match_keeper_skeleton.get_bone_count()):
			if _normalized_keeper_bone_name(match_keeper_skeleton.get_bone_name(bone_index)) == bone_suffix:
				match_keeper_leg_bones.append(bone_index)
				match_keeper_leg_rest_rotations.append(match_keeper_skeleton.get_bone_pose_rotation(bone_index))
				match_keeper_leg_rest_positions.append(match_keeper_skeleton.get_bone_pose_position(bone_index))
				break

func _cache_match_keeper_arm_bones():
	for bone_suffix in ["LeftArm", "LeftForeArm", "RightArm", "RightForeArm"]:
		for bone_index in range(match_keeper_skeleton.get_bone_count()):
			if _normalized_keeper_bone_name(match_keeper_skeleton.get_bone_name(bone_index)) == bone_suffix:
				match_keeper_arm_bones.append(bone_index)
				match_keeper_arm_rest_rotations.append(match_keeper_skeleton.get_bone_pose_rotation(bone_index))
				break
	if match_keeper_arm_bones.size() != 4:
		push_error("Match goalkeeper model is missing arm bones required for the keeper stance.")

func _set_match_keeper_catch_pose():
	if match_keeper_skeleton == null or match_keeper_arm_bones.size() != 4:
		return
	var arm_angles := [-0.9, 0.9, 0.9, -0.9]
	for index in range(match_keeper_arm_bones.size()):
		var axis := Vector3.FORWARD if index % 2 == 0 else Vector3.RIGHT
		match_keeper_skeleton.set_bone_pose_rotation(
			match_keeper_arm_bones[index],
			match_keeper_arm_rest_rotations[index] * Quaternion(axis, arm_angles[index])
		)

func _reset_match_keeper_pose():
	if match_keeper_animation:
		match_keeper_animation.stop()
	if match_keeper_skeleton:
		for bone_index in range(match_keeper_skeleton.get_bone_count()):
			match_keeper_skeleton.reset_bone_pose(bone_index)

func _update_match_keeper_footwork(delta: float):
	if match_keeper_skeleton == null or match_keeper_leg_bones.size() != 6 or is_diving:
		return
	var movement := Vector2(match_keeper_movement_axis, match_keeper_forward_axis)
	var strength := clampf(movement.length(), 0.0, 1.0)
	match_keeper_step_time += delta * strength * 12.0
	if strength < 0.05:
		for index in range(match_keeper_leg_bones.size()):
			match_keeper_skeleton.set_bone_pose_rotation(match_keeper_leg_bones[index], match_keeper_leg_rest_rotations[index])
			match_keeper_skeleton.set_bone_pose_position(match_keeper_leg_bones[index], match_keeper_leg_rest_positions[index])
		for index in range(match_keeper_arm_bones.size()):
			match_keeper_skeleton.set_bone_pose_rotation(match_keeper_arm_bones[index], match_keeper_arm_rest_rotations[index])
		match_keeper_model.rotation = Vector3(0.0, PI, 0.0)
		return
	match_keeper_model.rotation.x = -match_keeper_forward_axis * 0.08
	match_keeper_model.rotation.z = -match_keeper_movement_axis * 0.08
	var stride := sin(match_keeper_step_time)
	var left_step := stride * strength
	var right_step := -left_step
	var angles := [
		left_step * 0.52,
		-maxf(left_step, 0.0) * 0.42,
		-maxf(left_step, 0.0) * 0.2,
		right_step * 0.52,
		-maxf(right_step, 0.0) * 0.42,
		-maxf(right_step, 0.0) * 0.2
	]
	for index in range(match_keeper_leg_bones.size()):
		match_keeper_skeleton.set_bone_pose_rotation(
			match_keeper_leg_bones[index],
			match_keeper_leg_rest_rotations[index] * Quaternion(Vector3.RIGHT, angles[index])
		)
		var step := left_step if index < 3 else right_step
		var foot_lift := maxf(step, 0.0) * 0.7 if index == 2 or index == 5 else 0.0
		var stride_offset := step * 0.4 if index == 2 or index == 5 else 0.0
		match_keeper_skeleton.set_bone_pose_position(
			match_keeper_leg_bones[index],
			match_keeper_leg_rest_positions[index] + Vector3(match_keeper_movement_axis * strength * 0.04, foot_lift, stride_offset)
		)
	if match_keeper_arm_bones.size() == 4:
		var arm_angles := [-stride * 0.42, -0.18, stride * 0.42, 0.18]
		for index in range(match_keeper_arm_bones.size()):
			match_keeper_skeleton.set_bone_pose_rotation(
				match_keeper_arm_bones[index],
				match_keeper_arm_rest_rotations[index] * Quaternion(Vector3.RIGHT, arm_angles[index])
			)

func _keep_match_keeper_above_pitch():
	if not is_diving or match_keeper_model == null:
		return
	var minimum_y := INF
	for visual in match_keeper_visuals:
		if not is_instance_valid(visual):
			continue
		var bounds := visual.get_aabb()
		for x in [bounds.position.x, bounds.end.x]:
			for y in [bounds.position.y, bounds.end.y]:
				for z in [bounds.position.z, bounds.end.z]:
					minimum_y = minf(minimum_y, (visual.global_transform * Vector3(x, y, z)).y)
	if match_keeper_skeleton:
		for bone_index in range(match_keeper_skeleton.get_bone_count()):
			var bone_world_position := match_keeper_skeleton.global_transform * match_keeper_skeleton.get_bone_global_pose(bone_index).origin
			minimum_y = minf(minimum_y, bone_world_position.y - 0.12)
	if is_finite(minimum_y):
		position.y += 0.03 - minimum_y

func _tint_model(model: Node3D, color: Color):
	for mesh_node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := mesh_node as MeshInstance3D
		if mesh.mesh == null:
			continue
		for surface in range(mesh.mesh.get_surface_count()):
			var current := mesh.get_active_material(surface)
			var tinted := StandardMaterial3D.new()
			if current is StandardMaterial3D:
				tinted = current.duplicate() as StandardMaterial3D
			tinted.albedo_color = color
			mesh.set_surface_override_material(surface, tinted)

func _update_role_controls():
	var free_kick_game = get_tree().current_scene.get_node_or_null("FreeKickController")
	if free_kick_game:
		var is_mobile := mobile_ui.visible
		var is_keeper := role == MatchManager.ROLE_GOALKEEPER
		shot_button.visible = not is_keeper and is_mobile
		pass_button.visible = false
		through_button.visible = false
		cross_button.visible = false
		tackle_button.visible = false
		jump_button.text = "DIVE"
		jump_button.visible = is_keeper and is_mobile
		sprint_button.visible = false
		curve_left_button.visible = not is_keeper and is_mobile
		curve_right_button.visible = not is_keeper and is_mobile
		aim_joystick.visible = not is_keeper and is_mobile
		aim_label.visible = aim_joystick.visible
		return
	if role == MatchManager.ROLE_GOALKEEPER:
		shot_button.text = "CLEAR"
		pass_button.visible = false
		through_button.visible = false
		cross_button.visible = false
		tackle_button.visible = false
		jump_button.text = "DIVE"
		jump_button.visible = mobile_ui.visible
		sprint_button.visible = false
		curve_left_button.visible = false
		curve_right_button.visible = false
		aim_joystick.visible = false
		aim_label.visible = false
	else:
		shot_button.text = "SHOOT"
		pass_button.visible = mobile_ui.visible
		through_button.visible = mobile_ui.visible
		cross_button.visible = mobile_ui.visible
		tackle_button.visible = mobile_ui.visible
		jump_button.text = "ZIPLA"
		jump_button.visible = mobile_ui.visible
		sprint_button.visible = mobile_ui.visible
		curve_left_button.visible = mobile_ui.visible
		curve_right_button.visible = mobile_ui.visible
		aim_joystick.visible = mobile_ui.visible
		aim_label.visible = aim_joystick.visible

func play_action_local(animation_name: String):
	if animation_name == "keeper_save" and match_keeper_model != null:
		_set_match_keeper_catch_pose()
		return
	if animation_name == "fall_flat":
		if animation_player != null and animation_player.has_animation(&"fall_flat"):
			tackle_stun_timer = maxf(tackle_stun_timer, animation_player.get_animation(&"fall_flat").length)
			_play_animation("fall_flat")
		else:
			tackle_stun_timer = maxf(tackle_stun_timer, 0.9)
			_play_animation("fall")
		return
	var clip_name := animation_name
	match animation_name:
		"kick", "shot", "clearance":
			clip_name = "kick"
		"through", "lofted_through":
			clip_name = "pass"
		"slide_tackle":
			clip_name = "tackle"
	if animation_player != null and animation_player.has_animation(clip_name):
		current_animation = ""
		_play_animation(clip_name)
	elif clip_name == "kick" and not human_model_active:
		kick_animation_time = 0.001
	elif clip_name == "tackle":
		_play_animation("fall")

func goal_celebration_duration(flip_animation: StringName, dance_animation: StringName) -> float:
	if animation_player == null:
		push_error("Cannot play a goal celebration without an AnimationPlayer.")
		return 0.0
	if not animation_player.has_animation(flip_animation) or not animation_player.has_animation(dance_animation):
		push_error("Goal celebration animations are not installed on player %s." % name)
		return 0.0
	return (
		animation_player.get_animation(flip_animation).length
		+ animation_player.get_animation(dance_animation).length
	)

func start_goal_celebration_local(flip_animation: StringName, dance_animation: StringName) -> void:
	if goal_celebration_duration(flip_animation, dance_animation) <= 0.0:
		return
	goal_celebration_active = true
	_play_animation(String(flip_animation))
	_play_goal_dance_after_flip(
		animation_player.get_animation(flip_animation).length,
		dance_animation
	)

func pause_for_goal_celebration_local() -> void:
	goal_celebration_active = true
	_play_animation("Idle")

func _play_goal_dance_after_flip(flip_duration: float, dance_animation: StringName) -> void:
	await get_tree().create_timer(flip_duration).timeout
	if not is_inside_tree() or not goal_celebration_active:
		return
	_play_animation(String(dance_animation))
	await get_tree().create_timer(animation_player.get_animation(dance_animation).length).timeout

func set_diving_local(active: bool, side: int):
	is_diving = active
	if match_keeper_model != null:
		if active:
			match_keeper_dive_start_y = position.y
			dive_timer = 0.72
			match_keeper_movement_axis = 0.0
			match_keeper_forward_axis = 0.0
			match_keeper_model.rotation.x = 0.0
			match_keeper_model.rotation.z = 0.0
			_reset_match_keeper_pose()
			_reset_match_keeper_footwork()
			var mirror := -1.0 if side < 0 else 1.0
			match_keeper_model.scale = Vector3(absf(match_keeper_base_scale.x) * mirror, match_keeper_base_scale.y, match_keeper_base_scale.z)
			match_keeper_model.position = match_keeper_base_position + Vector3(float(side) * 0.9, 0.0, 0.0)
			match_keeper_model.rotation.z = float(side) * 0.3
			if match_keeper_animation and match_keeper_animation.has_animation(&"mixamo_com"):
				match_keeper_animation.play(&"mixamo_com")
				dive_timer = match_keeper_animation.get_animation(&"mixamo_com").length
		else:
			position.y = match_keeper_dive_start_y
			match_keeper_model.position = match_keeper_base_position
			match_keeper_model.rotation = Vector3(0.0, PI, 0.0)
			match_keeper_model.scale = match_keeper_base_scale
			_reset_match_keeper_pose()
			_reset_match_keeper_footwork()
		return
	if active:
		dive_timer = 0.72
		rotation.z = -side * 0.8
		_play_animation("fall")
	else:
		rotation.z = 0.0
		_play_animation("Idle")

func _reset_match_keeper_footwork():
	if match_keeper_skeleton == null or match_keeper_leg_bones.size() != 6:
		return
	for index in range(match_keeper_leg_bones.size()):
		match_keeper_skeleton.set_bone_pose_rotation(match_keeper_leg_bones[index], match_keeper_leg_rest_rotations[index])
		match_keeper_skeleton.set_bone_pose_position(match_keeper_leg_bones[index], match_keeper_leg_rest_positions[index])
	for index in range(match_keeper_arm_bones.size()):
		match_keeper_skeleton.set_bone_pose_rotation(match_keeper_arm_bones[index], match_keeper_arm_rest_rotations[index])

func apply_contact_impulse_local(impulse: Vector3):
	if player_push_cooldown > 0.0:
		return
	var horizontal_impulse := Vector3(impulse.x, 0.0, impulse.z).limit_length(2.5)
	if horizontal_impulse.length() < 0.1:
		return
	contact_impulse = (contact_impulse + horizontal_impulse).limit_length(3.5)
	player_push_cooldown = 0.22
	if horizontal_impulse.length() > 2.0 and not is_diving:
		_play_animation("fall")

func _push_colliding_players(movement_velocity: Vector3):
	for collision_index in range(get_slide_collision_count()):
		var collision := get_slide_collision(collision_index)
		var other := collision.get_collider() as CharacterBody3D
		if other == null or not other.has_method("apply_contact_impulse"):
			continue
		var push_direction := -collision.get_normal()
		push_direction.y = 0.0
		if push_direction.length_squared() < 0.01:
			continue
		push_direction = push_direction.normalized()
		var relative_velocity := movement_velocity - other.velocity
		var impact_speed := relative_velocity.dot(push_direction)
		if impact_speed <= 0.1:
			continue
		var impulse := push_direction * clampf(impact_speed * 0.35, 0.6, 2.5)
		if other.is_multiplayer_authority():
			other.apply_contact_impulse_local(impulse)
		else:
			other.apply_contact_impulse.rpc_id(other.get_multiplayer_authority(), impulse)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func apply_contact_impulse(impulse: Vector3):
	if not is_multiplayer_authority():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id != 0:
		var source := get_tree().current_scene.get_node_or_null("players/%d" % sender_id) as CharacterBody3D
		if source == null or source.get_multiplayer_authority() != sender_id:
			return
		if source.global_position.distance_to(global_position) > 2.0:
			return
		var away_from_source := global_position - source.global_position
		var horizontal_impulse := Vector3(impulse.x, 0.0, impulse.z)
		away_from_source.y = 0.0
		if horizontal_impulse.length_squared() < 0.01 or away_from_source.length_squared() < 0.01:
			return
		if horizontal_impulse.normalized().dot(away_from_source.normalized()) < 0.5:
			return
	apply_contact_impulse_local(impulse)

func _setup_animations():
	if active_model == null:
		return
	var players = active_model.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		animation_player = players[0] as AnimationPlayer
		if human_model_active:
			FOOTBALL_MODEL_UTILS.install_human_animations(animation_player, active_model)
		if MatchManager.game_mode == MatchManager.MODE_MATCH and role == MatchManager.ROLE_PLAYER:
			if not human_model_active:
				FOOTBALL_MODEL_UTILS.install_human_action_animations(animation_player, active_model)
			_install_match_animation(
				KICK_SOCCERBALL_ANIMATION_SCENE,
				&"mixamo_com",
				&"kick"
			)
			_install_match_fall_flat_animation()
			_install_match_animation(GOAL_FLIP_ANIMATION_SCENE, &"mixamo_com", &"goal_flip")
			if team == MatchManager.TEAM_RED:
				_install_match_animation(
					HUMAN_GOAL_CELEBRATION_SCENE,
					&"mixamo_com",
					&"human_goal_celebration"
				)
			elif team == MatchManager.TEAM_BLUE:
				_install_match_animation(
					ROBOT_GOAL_CELEBRATION_SCENE,
					&"mixamo_com",
					&"robot_goal_celebration"
				)
		FOOTBALL_MODEL_UTILS.configure_locomotion_loops(animation_player)
		_play_animation("Idle")
	var skeletons = active_model.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		return
	bot_skeleton = skeletons[0] as Skeleton3D
	kick_bones.clear()
	kick_rest_rotations.clear()
	if not human_model_active:
		for bone_name in ["upperleg.R", "lowerleg.R", "foot.R"]:
			for bone_index in range(bot_skeleton.get_bone_count()):
				if bot_skeleton.get_bone_name(bone_index) == bone_name:
					kick_bones.append(bone_index)
					kick_rest_rotations.append(bot_skeleton.get_bone_pose_rotation(bone_index))
					break

func _install_match_fall_flat_animation() -> void:
	_install_match_animation(FALL_FLAT_ANIMATION_SCENE, &"mixamo_com", &"fall_flat")

func _install_match_animation(
	animation_scene: PackedScene,
	source_animation_name: StringName,
	target_animation_name: StringName
) -> void:
	var target_skeletons := active_model.find_children("*", "Skeleton3D", true, false)
	if target_skeletons.is_empty():
		push_error("The match player model has no Skeleton3D for animation %s." % target_animation_name)
		return
	var source_model := animation_scene.instantiate() as Node3D
	var source_players := source_model.find_children("*", "AnimationPlayer", true, false)
	if source_players.is_empty():
		source_model.free()
		push_error("Animation asset %s has no AnimationPlayer." % target_animation_name)
		return
	var source_player := source_players[0] as AnimationPlayer
	if not source_player.has_animation(source_animation_name):
		source_model.free()
		push_error(
			"Animation asset %s has no %s clip."
			% [target_animation_name, source_animation_name]
		)
		return
	var target_skeleton := target_skeletons[0] as Skeleton3D
	var animation := FOOTBALL_MODEL_UTILS.retarget_animation(
		source_player.get_animation(source_animation_name),
		active_model,
		target_skeleton,
		true
	)
	source_model.free()
	if animation.get_track_count() == 0:
		push_error("Animation %s has no bones compatible with the match player model." % target_animation_name)
		return
	animation.loop_mode = Animation.LOOP_NONE
	var library: AnimationLibrary
	if animation_player.has_animation_library(&""):
		library = animation_player.get_animation_library(&"")
	else:
		library = AnimationLibrary.new()
		var library_result := animation_player.add_animation_library(&"", library)
		if library_result != OK:
			push_error("Could not create the match player animation library: %s" % error_string(library_result))
			return
	if library.has_animation(target_animation_name):
		library.remove_animation(target_animation_name)
	var add_result := library.add_animation(target_animation_name, animation)
	if add_result != OK:
		push_error(
			"Could not install match player animation %s: %s"
			% [target_animation_name, error_string(add_result)]
		)

func _update_kick_pose():
	if bot_skeleton == null or kick_bones.size() < 3:
		if kick_animation_time > 0.55:
			kick_animation_time = 0.0
		return
	var time = kick_animation_time
	var swing: float
	if time < 0.14:
		swing = -0.45 * time / 0.14
	elif time < 0.28:
		swing = lerpf(-0.45, 1.05, (time - 0.14) / 0.14)
	elif time < 0.55:
		swing = lerpf(1.05, 0.0, (time - 0.28) / 0.27)
	else:
		for bone_index in kick_bones:
			bot_skeleton.reset_bone_pose(bone_index)
		kick_animation_time = 0.0
		return
	bot_skeleton.set_bone_pose_rotation(kick_bones[0], kick_rest_rotations[0] * Quaternion(Vector3.RIGHT, swing))
	bot_skeleton.set_bone_pose_rotation(kick_bones[1], kick_rest_rotations[1] * Quaternion(Vector3.RIGHT, -maxf(swing, 0.0) * 0.62))
	bot_skeleton.set_bone_pose_rotation(kick_bones[2], kick_rest_rotations[2] * Quaternion(Vector3.RIGHT, -swing * 0.22))

func _play_animation(animation_name: String):
	if animation_player == null or not animation_player.has_animation(animation_name):
		return
	var speed_scale = 1.35 if animation_name == "run" and sprint_active else 1.0
	var animation_changed = current_animation != animation_name
	var speed_changed = not is_equal_approx(animation_player.speed_scale, speed_scale)
	var needs_restart = not animation_player.is_playing()
	if not animation_changed and not speed_changed and not needs_restart:
		return
	current_animation = animation_name
	if animation_changed or needs_restart:
		animation_player.play(animation_name)
	animation_player.speed_scale = speed_scale
	if is_multiplayer_authority() and (MatchManager.game_mode != MatchManager.MODE_MATCH or match_animation_sync_ready):
		sync_animation.rpc(animation_name, speed_scale)

func _enable_match_animation_sync() -> void:
	await get_tree().create_timer(0.5).timeout
	if not is_inside_tree():
		return
	match_animation_sync_ready = true
	if is_multiplayer_authority() and not current_animation.is_empty():
		sync_animation.rpc(current_animation, animation_player.speed_scale)

@rpc("authority", "call_local", "unreliable_ordered")
func sync_animation(animation_name: String, speed_scale: float):
	if animation_player and animation_player.has_animation(animation_name):
		if current_animation != animation_name:
			current_animation = animation_name
			animation_player.play(animation_name)
		animation_player.speed_scale = speed_scale

func _update_movement_animation():
	if goal_celebration_active:
		return
	var horizontal_velocity := Vector3(velocity.x, 0.0, velocity.z)
	if tackle_timer > 0.0:
		_play_animation(
			"tackle"
			if animation_player != null and animation_player.has_animation(&"tackle")
			else "fall"
		)
	elif is_diving:
		_play_animation("fall")
	elif not is_on_floor():
		_play_animation("jump")
	elif human_model_active and horizontal_velocity.dot(-global_transform.basis.z) < -0.1:
		_play_animation("backward")
	elif horizontal_velocity.length() > SPEED * 0.7:
		_play_animation("run")
	elif velocity.length() > 0.25:
		_play_animation("walk")
	else:
		_play_animation("Idle")

func _jump():
	if not is_on_floor():
		return
	velocity.y = JUMP_SPEED
	_play_animation("jump")

func _start_tackle(slide := false):
	if MatchManager.game_mode == MatchManager.MODE_MATCH:
		var match_game := _get_game_controller()
		if match_game:
			match_game.request_player_action("slide_tackle" if slide else "tackle", name)
		return
	tackle_timer = 0.7
	var forward = -global_transform.basis.z
	velocity.x = forward.x * TACKLE_SPEED
	velocity.z = forward.z * TACKLE_SPEED
	_play_animation("tackle" if human_model_active else "fall")
	var game = _get_game_controller()
	if game:
		game.request_player_action("tackle")
