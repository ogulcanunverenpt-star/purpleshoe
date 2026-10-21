extends CharacterBody3D

const WALK_SPEED = 4.5
const RUN_SPEED = 8.5
const JUMP_VELOCITY = 5.0
const FALL_RESPAWN_DISTANCE := 40.0
const FOOTBALL_MODEL_UTILS = preload("res://football_model_utils.gd")
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

@onready var label_3d: Label3D = $Label3D
@onready var audio_manager: Node = $audioManager
@onready var audio_player_3d: AudioStreamPlayer3D = $AudioStreamPlayer3D
@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var aim_joystick: MobileVirtualJoystick = get_tree().current_scene.get_node_or_null("CanvasLayer/HUD/MobileAimJoystick") as MobileVirtualJoystick

var avatar_model: Node3D
var current_avatar_id := ""
var username := "Player"
var player_color := Color.WHITE
var anim_player: AnimationPlayer = null
var ptt_pressed := false
var ptt_touch_active := false
var spawn_position := Vector3.ZERO

func _enter_tree():
	set_multiplayer_authority(name.to_int())

func _ready():
	spawn_position = global_position

	if audio_manager:
		audio_manager.setupAudio(name.to_int())

	# Generate random unique color for this player
	player_color = Color(randf_range(0.2, 1.0), randf_range(0.2, 1.0), randf_range(0.2, 1.0))

	username = MatchManager.username_for_peer(name.to_int())
	if username.is_empty():
		username = "Player_%s" % name
	_apply_avatar_selection(MatrixClient.selected_avatar_id() if is_multiplayer_authority() else AvatarCatalog.ROBOT)
	if is_multiplayer_authority():
		call_deferred("publish_avatar_selection")
	_update_label_text()

	if is_multiplayer_authority():
		$SpringArm3D/Camera3D.make_current()


func publish_avatar_selection() -> void:
	if not is_multiplayer_authority():
		return
	var avatar_id := MatrixClient.selected_avatar_id()
	_apply_avatar_selection(avatar_id)
	if not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		sync_avatar_selection.rpc(avatar_id)


@rpc("any_peer", "call_local", "reliable")
func sync_avatar_selection(avatar_id: String) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id != 0 and sender_id != name.to_int():
		push_warning("Ignored avatar update from non-owner peer %d for player %s." % [sender_id, name])
		return
	_apply_avatar_selection(avatar_id)


func _apply_avatar_selection(avatar_id: String) -> void:
	if not AvatarCatalog.is_valid_avatar(avatar_id):
		push_error("Player %s sent an unknown avatar selection: %s" % [name, avatar_id])
		return
	if current_avatar_id == avatar_id and is_instance_valid(avatar_model):
		return
	var avatar_scene := AvatarCatalog.scene_for(avatar_id)
	if avatar_scene == null:
		return
	var new_model := avatar_scene.instantiate() as Node3D
	new_model.name = "%sAvatar" % avatar_id.capitalize()
	add_child(new_model)
	if avatar_id == AvatarCatalog.MAN and not AvatarCatalog.apply_male_textures(new_model):
		new_model.queue_free()
		return
	if not AvatarCatalog.fit_model_to_height(new_model, 1.8):
		new_model.queue_free()
		return
	if is_instance_valid(avatar_model):
		avatar_model.queue_free()
	avatar_model = new_model
	current_avatar_id = avatar_id
	if avatar_id == AvatarCatalog.ROBOT:
		_apply_random_color(player_color)
	_setup_animations()


func _setup_animations():
	if avatar_model == null:
		return
	var players = avatar_model.find_children("*", "AnimationPlayer", true, false)
	if players.size() > 0:
		anim_player = players[0] as AnimationPlayer
		if AvatarCatalog.supports_shared_human_animations(current_avatar_id):
			FOOTBALL_MODEL_UTILS.install_human_animations(anim_player, avatar_model)
		FOOTBALL_MODEL_UTILS.configure_locomotion_loops(anim_player)
		_play_anim("Idle")

func _play_anim(anim_name: String):
	if anim_player == null:
		return
	if anim_player.current_animation == anim_name and anim_player.is_playing():
		return
	if anim_player.has_animation(anim_name):
		anim_player.play(anim_name)
	elif anim_player.has_animation(anim_name.capitalize()):
		anim_player.play(anim_name.capitalize())
	elif anim_player.has_animation(anim_name.to_lower()):
		anim_player.play(anim_name.to_lower())

func _apply_random_color(color: Color):
	if avatar_model == null:
		return
	for child in avatar_model.find_children("*", "MeshInstance3D", true, false):
		var mesh_inst := child as MeshInstance3D
		if mesh_inst and mesh_inst.mesh:
			for surface_idx in range(mesh_inst.mesh.get_surface_count()):
				var mat = mesh_inst.get_surface_override_material(surface_idx)
				if mat == null:
					var orig_mat = mesh_inst.mesh.surface_get_material(surface_idx)
					mat = orig_mat.duplicate() if orig_mat else StandardMaterial3D.new()
				else:
					mat = mat.duplicate()
				if mat is StandardMaterial3D:
					(mat as StandardMaterial3D).albedo_color = color
				mesh_inst.set_surface_override_material(surface_idx, mat)

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	if not is_instance_valid(avatar_model):
		return
	if global_position.y < spawn_position.y - FALL_RESPAWN_DISTANCE:
		global_position = spawn_position
		velocity = Vector3.ZERO

	# Handle Press-To-Talk (PTT)
	ptt_pressed = Input.is_key_pressed(KEY_V) or ptt_touch_active
	if audio_manager:
		audio_manager.ptt_active = ptt_pressed
	_update_label_text()
	sync_ptt.rpc(ptt_pressed)

	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Jump
	if Input.is_action_just_pressed("ui_accept"):
		jump()

	if aim_joystick and aim_joystick.is_visible_in_tree():
		spring_arm.rotation.y -= aim_joystick.value.x * 2.4 * delta
		spring_arm.rotation.x = clampf(
			spring_arm.rotation.x - aim_joystick.value.y * 1.8 * delta,
			deg_to_rad(-66.0),
			deg_to_rad(12.0)
		)

	# Movement & Sprinting
	var is_sprinting := Input.is_key_pressed(KEY_SHIFT)
	var speed := RUN_SPEED if is_sprinting else WALK_SPEED
	var input_dir := Input.get_vector("a", "d", "w", "s")
	var joystick := get_tree().current_scene.get_node_or_null("CanvasLayer/HUD/MobileJoystick") as MobileVirtualJoystick
	if joystick and joystick.value.length() > 0.05:
		input_dir = joystick.value
	var cam_basis: Basis = $SpringArm3D.global_transform.basis
	var direction := (cam_basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	direction.y = 0.0
	direction = direction.normalized()

	if direction != Vector3.ZERO:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
		var facing_yaw := atan2(direction.x, direction.z)
		avatar_model.rotation.y = lerp_angle(avatar_model.rotation.y, facing_yaw, delta * 12.0)
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

	move_and_slide()

	# Animations
	var jumping := not is_on_floor()
	if jumping:
		_play_anim("jump")
	elif direction != Vector3.ZERO:
		if is_sprinting:
			_play_anim("run")
		else:
			_play_anim("walk")
	else:
		_play_anim("Idle")

	sync_position.rpc(global_position, avatar_model.rotation.y, ptt_pressed)

func jump() -> void:
	if not is_multiplayer_authority() or not is_on_floor():
		return
	velocity.y = JUMP_VELOCITY

func _update_label_text():
	if label_3d:
		var status_str := "🔊 [SPEAKING]" if ptt_pressed else "🔇 [V: PUSH TO TALK]"
		label_3d.text = "%s\n%s" % [username, status_str]

@rpc("any_peer", "call_remote", "unreliable")
func sync_position(pos: Vector3, rot_y: float, ptt: bool):
	if not is_multiplayer_authority():
		global_position = pos
		if avatar_model:
			avatar_model.rotation.y = rot_y
		ptt_pressed = ptt
		_update_label_text()

@rpc("any_peer", "call_remote", "unreliable")
func sync_ptt(ptt: bool):
	ptt_pressed = ptt
	_update_label_text()
