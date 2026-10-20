extends Node

const BALL_SCENE = preload("res://footballsoccer_ball.glb")
const GOAL_SCENE = preload("res://football_goal.glb")
const PLAYER_SCENE = preload("res://gdbot.glb")
const GOALKEEPER_SCENE = preload("res://goalkeeper_stylized.glb")
const KEEPER_DIVE_SCENE = preload("res://goalkeeper_diving_save_requested.glb")
const HUMAN_MODEL_SCENE = preload("res://Assets/FootballHuman/Soccer Pass.fbx")
const HUMAN_PENALTY_KICK_SCENE = preload("res://Assets/FootballHuman/Soccer Penalty Kick.fbx")
const FOOTBALL_MODEL_UTILS = preload("res://football_model_utils.gd")

const BALL_RADIUS := 0.148
const BALL_START := Vector3(0.0, BALL_RADIUS, -2.5)
const GOAL_LINE := -25.8
const KEEPER_LINE := -25.2
const GOAL_WIDTH := 7.32
const GOAL_HALF_WIDTH := GOAL_WIDTH * 0.5
const GOAL_HEIGHT := 2.44
const GOAL_DEPTH := 2.0
const PLAYER_HEIGHT := 1.87
const GRAVITY := 9.8
const WINNING_SCORE := 5
const KEEPER_MOVE_SPEED := 3.2
const KEEPER_DIVE_DISTANCE := 0.9
const STRIKER_KICK_CONTACT_TIME := 1.25
const STRIKER_CONTACT_SEARCH_START := 0.2
const STRIKER_FOOT_REACH := 0.6
const STRIKER_PENALTY_LIBRARY := &"football"
const STRIKER_PENALTY_CLIP := &"football/penalty_kick"
const POST_SHOT_DELAY := 3.5

@onready var players: Node3D = $"../players"
@onready var ground: CSGBox3D = $"../CSGBox3D"

var ball: Node3D
var aim_arrow: Node3D
var goal_root: Node3D
var goal_net_parts: Array[Node3D] = []
var keeper_root: Node3D
var keeper_model: Node3D
var keeper_model_base_scale := Vector3.ONE
var keeper_visuals: Array[VisualInstance3D] = []
var keeper_skeleton: Skeleton3D
var keeper_animation: AnimationPlayer
var striker_root: Node3D
var striker_model: Node3D
var striker_skeleton: Skeleton3D
var striker_animation: AnimationPlayer
var striker_is_human := false
var striker_team := -1
var striker_rest_position := Vector3(-1.15, 0.0, BALL_START.z + 4.5)
var striker_kick_bones: Array[int] = []
var striker_kick_rest_rotations: Array[Quaternion] = []
var striker_arm_bones: Array[int] = []
var striker_arm_rest_rotations: Array[Quaternion] = []
var ball_velocity := Vector3.ZERO
var target_ball_position := BALL_START
var target_ball_rotation := Vector3.ZERO
var ball_active := false
var kick_pending := false
var pending_ball_start := BALL_START
var pending_ball_velocity := Vector3.ZERO
var striker_run_up_start := Vector3.ZERO
var striker_run_up_target := Vector3.ZERO
var striker_kick_elapsed := 0.0
var striker_kick_pose_active := false
var striker_penalty_animation_active := false
var striker_penalty_animation_length := 0.0
var striker_penalty_contact_offset := Vector3.ZERO
var striker_penalty_hips_bone := -1
var striker_penalty_toe_bone := -1
var sync_timer := 0.0
var reset_timer := 0.0
var shot_elapsed := 0.0
var keeper_target_x := 0.0
var ball_curve := 0.0
var keeper_dive_cooldown := 0.0
var keeper_sync_timer := 0.0
var keeper_dive_start_x := 0.0
var keeper_save_confirmed := false
var keeper_save_timer := 0.0
var post_rebounded := false
var shot_result_reported := false
var pending_role_swap := false
var ball_in_net := false
var goals := 0
var saves := 0
var shots_taken := 0
var last_shooter_id := 0
var last_keeper_id := 0
var player_a_id := 0
var player_b_id := 0
var player_scores: Dictionary = {}
var match_clock := 0.0
var clock_sync_timer := 0.0
var contest_finished := false
var keeper_step_time := 0.0
var keeper_movement_axis := 0.0
var keeper_depth_axis := 0.0
var keeper_is_diving := false
var keeper_leg_bones: Array[int] = []
var keeper_leg_rest_rotations: Array[Quaternion] = []
var keeper_leg_rest_positions: Array[Vector3] = []
var keeper_arm_bones: Array[int] = []
var keeper_arm_rest_rotations: Array[Quaternion] = []
var keeper_has_ball := false
var score_label: Label
var result_label: Label
var instruction_label: Label
var power_bar: ProgressBar
var role_label: Label

func _ready():
	match_clock = float(MatchManager.match_duration_minutes * 60)
	MatchManager.local_role_changed.connect(_on_local_role_changed)
	MatchManager.role_selection_rejected.connect(_on_role_selection_rejected)
	MatchManager.match_state_changed.connect(_on_match_state_changed)
	MatchManager.roster_changed.connect(_on_roster_changed)
	_build_pitch()
	_build_assets()
	_build_hud()
	_on_match_state_changed(MatchManager.match_ready)

func _build_pitch():
	ground.position = Vector3(0, -0.5, 0)
	ground.size = Vector3(44, 1, 58)
	var turf = StandardMaterial3D.new()
	turf.albedo_color = Color(0.12, 0.32, 0.2)
	turf.roughness = 1.0
	ground.material = turf

	var line_material = StandardMaterial3D.new()
	line_material.albedo_color = Color(0.88, 0.9, 0.82)
	line_material.roughness = 0.85
	_add_marking("TouchlineLeft", Vector3(-20, 0.012, 0), Vector3(0.12, 0.025, 52), line_material)
	_add_marking("TouchlineRight", Vector3(20, 0.012, 0), Vector3(0.12, 0.025, 52), line_material)
	_add_marking("EndlineNear", Vector3(0, 0.012, 25.8), Vector3(40, 0.025, 0.12), line_material)
	_add_marking("EndlineFar", Vector3(0, 0.012, GOAL_LINE), Vector3(40, 0.025, 0.12), line_material)
	_add_marking("HalfwayLine", Vector3(0, 0.012, 0), Vector3(40, 0.025, 0.12), line_material)
	_add_marking("BoxTop", Vector3(0, 0.012, -10.8), Vector3(16, 0.025, 0.12), line_material)
	_add_marking("BoxLeft", Vector3(-8, 0.012, -14.2), Vector3(0.12, 0.025, 6.8), line_material)
	_add_marking("BoxRight", Vector3(8, 0.012, -14.2), Vector3(0.12, 0.025, 6.8), line_material)
	_add_marking("PenaltySpot", Vector3(0, 0.025, -6.6), Vector3(0.22, 0.04, 0.22), line_material)

func _add_marking(node_name: String, position: Vector3, size: Vector3, material: Material):
	var marking = MeshInstance3D.new()
	marking.name = node_name
	var box = BoxMesh.new()
	box.size = size
	marking.mesh = box
	marking.material_override = material
	marking.position = position
	add_child(marking)

func _build_assets():
	var goal = GOAL_SCENE.instantiate() as Node3D
	goal.name = "GoalNet"
	goal_root = goal
	goal.position = Vector3(0, 0, GOAL_LINE)
	goal.rotation.y = 0.0
	_remove_import_helpers(goal)
	add_child(goal)
	var frame := goal.find_child("Rectangle001_post_0", true, false) as MeshInstance3D
	if frame == null:
		push_error("The goal model has no frame mesh.")
		return
	var root_inverse: Transform3D = goal.global_transform.affine_inverse()
	var frame_bounds := _get_transformed_aabb(frame.get_aabb(), root_inverse * frame.global_transform)
	if frame_bounds.size.x <= 0.0 or frame_bounds.size.y <= 0.0:
		push_error("The goal model has invalid frame bounds.")
		return
	var scale_x: float = GOAL_WIDTH / frame_bounds.size.x
	var scale_y: float = GOAL_HEIGHT / frame_bounds.size.y
	goal.scale = Vector3(scale_x, scale_y, scale_x)
	goal.position = Vector3(0.0, 0.0, GOAL_LINE)
	goal.force_update_transform()
	frame.force_update_transform()
	var scaled_frame_bounds := _get_transformed_aabb(frame.get_aabb(), frame.global_transform)
	goal.global_position += Vector3(
		0.0,
		-scaled_frame_bounds.position.y,
		GOAL_LINE - scaled_frame_bounds.get_center().z
	)
	goal.force_update_transform()
	frame.force_update_transform()
	for mesh in goal.find_children("*", "MeshInstance3D", true, false):
		if mesh.name.to_lower().contains("rope"):
			goal_net_parts.append(mesh as Node3D)
	if goal_net_parts.is_empty():
		push_error("The goal model contains no net mesh parts.")
		return

	keeper_root = Node3D.new()
	keeper_root.name = "Goalkeeper"
	keeper_root.position = Vector3(0, 0, KEEPER_LINE)
	keeper_root.rotation.y = 0.0
	keeper_model = GOALKEEPER_SCENE.instantiate() as Node3D
	keeper_model.name = "StylizedGoalkeeper"
	keeper_root.add_child(keeper_model)
	add_child(keeper_root)
	var keeper_bounds = _get_visual_bounds(keeper_model)
	if keeper_bounds.size.y <= 0.0:
		push_error("The goalkeeper model has invalid visual bounds.")
		return
	keeper_model.scale = Vector3.ONE * (PLAYER_HEIGHT / keeper_bounds.size.y)
	keeper_model_base_scale = keeper_model.scale
	keeper_model.position.y = -keeper_bounds.position.y * keeper_model.scale.y
	for visual_node in keeper_model.find_children("*", "VisualInstance3D", true, false):
		keeper_visuals.append(visual_node as VisualInstance3D)
	keeper_animation = _find_animation_player(keeper_model)
	keeper_skeleton = _find_skeleton(keeper_model)
	if keeper_animation == null or keeper_skeleton == null:
		push_error("The goalkeeper model requires an AnimationPlayer and Skeleton3D.")
		return
	_cache_keeper_step_bones()
	_cache_keeper_arm_bones()
	keeper_animation.stop()
	var dive_source := KEEPER_DIVE_SCENE.instantiate() as Node3D
	dive_source.visible = false
	keeper_root.add_child(dive_source)
	var dive_source_animation := _find_animation_player(dive_source)
	if dive_source_animation == null:
		push_error("The goalkeeper dive asset has no AnimationPlayer.")
		return
	_copy_keeper_dive_animations(dive_source_animation)

	ball = BALL_SCENE.instantiate() as Node3D
	ball.name = "FreeKickBall"
	ball.position = BALL_START
	ball.scale = Vector3.ONE * 1.6
	add_child(ball)
	_build_aim_arrow()

	striker_root = Node3D.new()
	striker_root.position = striker_rest_position
	striker_root.rotation.y = PI
	add_child(striker_root)
	_refresh_striker_model()

func _on_roster_changed() -> void:
	call_deferred("_refresh_striker_model")

func _refresh_striker_model() -> void:
	if striker_root == null:
		return
	var shooter_id := _peer_for_role(MatchManager.ROLE_PLAYER)
	var next_team := MatchManager.team_for_peer(shooter_id)
	if striker_model != null and striker_team == next_team:
		return
	if striker_model:
		striker_model.queue_free()
	striker_team = next_team
	striker_is_human = striker_team == MatchManager.TEAM_RED
	striker_root.name = "HumanShooter" if striker_is_human else "RobotShooter"
	striker_model = (HUMAN_MODEL_SCENE if striker_is_human else PLAYER_SCENE).instantiate() as Node3D
	striker_model.name = "HumanFootballer" if striker_is_human else "RobotFootballer"
	striker_root.add_child(striker_model)
	striker_penalty_animation_active = false
	striker_penalty_animation_length = 0.0
	striker_penalty_contact_offset = Vector3.ZERO
	striker_penalty_hips_bone = -1
	striker_penalty_toe_bone = -1
	if striker_is_human:
		AvatarCatalog.apply_male_textures(striker_model)
	var striker_bounds = _get_visual_bounds(striker_model)
	if striker_bounds.size.y <= 0.0:
		push_error("The striker model has invalid visual bounds.")
		return
	striker_model.scale = Vector3.ONE * (PLAYER_HEIGHT / striker_bounds.size.y)
	striker_model.position.y = -striker_bounds.position.y * striker_model.scale.y
	var striker_skeletons = striker_model.find_children("*", "Skeleton3D", true, false)
	if striker_skeletons.is_empty():
		push_error("The striker model has no Skeleton3D.")
		return
	striker_skeleton = striker_skeletons[0] as Skeleton3D
	striker_animation = _find_animation_player(striker_model)
	if striker_animation == null:
		push_error("The striker model has no AnimationPlayer.")
		return
	if striker_is_human:
		FOOTBALL_MODEL_UTILS.install_human_animations(striker_animation, striker_model)
		_install_striker_penalty_animation()
	FOOTBALL_MODEL_UTILS.configure_locomotion_loops(striker_animation)
	striker_kick_bones.clear()
	striker_kick_rest_rotations.clear()
	striker_arm_bones.clear()
	striker_arm_rest_rotations.clear()
	_cache_striker_bones()
	_play_gdbot_animation(striker_animation, &"Idle")


func _install_striker_penalty_animation() -> void:
	var source_model := HUMAN_PENALTY_KICK_SCENE.instantiate() as Node3D
	var source_animation_player := _find_animation_player(source_model)
	if source_animation_player == null:
		source_model.free()
		push_error("The human penalty kick asset has no AnimationPlayer.")
		return
	var source_animation: Animation
	for animation_name: StringName in source_animation_player.get_animation_list():
		if animation_name != &"RESET":
			source_animation = source_animation_player.get_animation(animation_name)
			break
	source_model.free()
	if source_animation == null:
		push_error("The human penalty kick asset has no usable animation.")
		return

	var animation := FOOTBALL_MODEL_UTILS.retarget_animation(source_animation, striker_model, striker_skeleton)
	var library := AnimationLibrary.new()
	var add_result := library.add_animation(&"penalty_kick", animation)
	if add_result != OK:
		push_error("Could not add the human penalty kick animation: %s" % error_string(add_result))
		return
	add_result = striker_animation.add_animation_library(STRIKER_PENALTY_LIBRARY, library)
	if add_result != OK:
		push_error("Could not install the human penalty kick animation: %s" % error_string(add_result))
		return
	if animation.length < STRIKER_KICK_CONTACT_TIME:
		push_error("The human penalty kick animation ends before foot contact.")
		return
	striker_penalty_animation_length = animation.length
	striker_penalty_hips_bone = _find_striker_bone("hips")
	striker_penalty_toe_bone = _find_striker_bone("righttoebase")
	if striker_penalty_toe_bone < 0:
		striker_penalty_toe_bone = _find_striker_bone("rightfoot")
	if striker_penalty_hips_bone < 0 or striker_penalty_toe_bone < 0:
		striker_penalty_animation_length = 0.0
		push_error("The human striker skeleton is missing its hips or right foot bone.")
		return
	striker_penalty_contact_offset = _sample_striker_penalty_bone(striker_penalty_toe_bone)
	if not is_finite(striker_penalty_contact_offset.x) or not is_finite(striker_penalty_contact_offset.z):
		push_error("Could not calculate the human striker foot contact point.")
		striker_penalty_animation_length = 0.0


func _find_striker_bone(name_fragment: String) -> int:
	for bone_index in range(striker_skeleton.get_bone_count()):
		if String(striker_skeleton.get_bone_name(bone_index)).to_lower().ends_with(name_fragment):
			return bone_index
	return -1


func _sample_striker_penalty_bone(bone_index: int) -> Vector3:
	striker_animation.play(STRIKER_PENALTY_CLIP)
	striker_animation.seek(STRIKER_KICK_CONTACT_TIME, true)
	striker_skeleton.force_update_all_bone_transforms()
	var bone_world_position := striker_skeleton.global_transform * striker_skeleton.get_bone_global_pose(bone_index)
	var root_local_position := striker_root.to_local(bone_world_position.origin)
	striker_animation.play(&"Idle")
	striker_animation.seek(0.0, true)
	striker_skeleton.force_update_all_bone_transforms()
	return root_local_position


func _get_transformed_aabb(bounds: AABB, transform: Transform3D) -> AABB:
	var min_point := Vector3(INF, INF, INF)
	var max_point := Vector3(-INF, -INF, -INF)
	for x in [0, 1]:
		for y in [0, 1]:
			for z in [0, 1]:
				var corner := bounds.position + bounds.size * Vector3(x, y, z)
				var point := transform * corner
				min_point = min_point.min(point)
				max_point = max_point.max(point)
	return AABB(min_point, max_point - min_point)

func _find_animation_player(model: Node) -> AnimationPlayer:
	var animation_players = model.find_children("*", "AnimationPlayer", true, false)
	return animation_players[0] as AnimationPlayer if not animation_players.is_empty() else null

func _find_skeleton(model: Node) -> Skeleton3D:
	var skeletons = model.find_children("*", "Skeleton3D", true, false)
	return skeletons[0] as Skeleton3D if not skeletons.is_empty() else null

func _play_gdbot_animation(animation_player: AnimationPlayer, animation_name: StringName):
	if animation_player.has_animation(animation_name):
		animation_player.play(animation_name)

func _cache_keeper_step_bones():
	for bone_suffix in ["LeftUpLeg", "LeftLeg", "LeftFoot", "RightUpLeg", "RightLeg", "RightFoot"]:
		for bone_index in range(keeper_skeleton.get_bone_count()):
			if _normalized_keeper_bone_name(keeper_skeleton.get_bone_name(bone_index)) == bone_suffix:
				keeper_leg_bones.append(bone_index)
				keeper_leg_rest_rotations.append(keeper_skeleton.get_bone_pose_rotation(bone_index))
				keeper_leg_rest_positions.append(keeper_skeleton.get_bone_pose_position(bone_index))
				break

func _cache_keeper_arm_bones():
	for bone_suffix in ["LeftArm", "LeftForeArm", "RightArm", "RightForeArm"]:
		var bone_index := -1
		for candidate_index in range(keeper_skeleton.get_bone_count()):
			if _normalized_keeper_bone_name(keeper_skeleton.get_bone_name(candidate_index)) == bone_suffix:
				bone_index = candidate_index
				break
		if bone_index < 0:
			push_error("The goalkeeper model is missing arm bone %s." % bone_suffix)
			return
		keeper_arm_bones.append(bone_index)
		keeper_arm_rest_rotations.append(keeper_skeleton.get_bone_pose_rotation(bone_index))

func _copy_keeper_dive_animations(source: AnimationPlayer):
	var target_player := AnimationPlayer.new()
	target_player.name = "KeeperDiveAnimationPlayer"
	target_player.root_node = NodePath("..")
	keeper_root.add_child(target_player)
	var library := AnimationLibrary.new()
	var skeleton_path := keeper_root.get_path_to(keeper_skeleton)
	var imported_count := 0
	for animation_name in source.get_animation_list():
		if animation_name != &"RESET":
			var animation := source.get_animation(animation_name).duplicate(true) as Animation
			for track_index in range(animation.get_track_count()):
				var track_path := str(animation.track_get_path(track_index))
				var separator := track_path.rfind(":")
				if separator < 0:
					continue
				var source_bone_name := _normalized_keeper_bone_name(track_path.substr(separator + 1))
				var target_bone_name := ""
				for bone_index in range(keeper_skeleton.get_bone_count()):
					var candidate := keeper_skeleton.get_bone_name(bone_index)
					if _normalized_keeper_bone_name(candidate) == source_bone_name:
						target_bone_name = candidate
						break
				if target_bone_name.is_empty():
					continue
				if source_bone_name == "Hips" and animation.track_get_type(track_index) == Animation.TYPE_POSITION_3D and animation.track_get_key_count(track_index) > 0:
					var target_hips := keeper_skeleton.find_bone(target_bone_name)
					var source_hips_position: Vector3 = animation.track_get_key_value(track_index, 0)
					var target_hips_height := keeper_skeleton.get_bone_pose_position(target_hips).y
					if absf(source_hips_position.y) > 0.001 and target_hips_height > 0.0:
						var position_scale := target_hips_height / source_hips_position.y
						for key_index in range(animation.track_get_key_count(track_index)):
							var key_position: Vector3 = animation.track_get_key_value(track_index, key_index)
							animation.track_set_key_value(track_index, key_index, key_position * position_scale)
				animation.track_set_path(track_index, NodePath("%s:%s" % [skeleton_path, target_bone_name]))
			var result := library.add_animation(animation_name, animation)
			if result != OK:
				push_error("Could not retarget goalkeeper animation %s: %s" % [animation_name, error_string(result)])
			else:
				imported_count += 1
	if imported_count == 0:
		push_error("No goalkeeper dive animations could be retargeted to the stylized goalkeeper.")
		return
	target_player.add_animation_library(&"", library)
	keeper_animation = target_player

func _normalized_keeper_bone_name(bone_name: String) -> String:
	var normalized_name := bone_name.trim_prefix("mixamorig_").trim_prefix("mixamorig:")
	var suffix_index := normalized_name.rfind("_")
	if suffix_index >= 0 and normalized_name.substr(suffix_index + 1).is_valid_int():
		normalized_name = normalized_name.substr(0, suffix_index)
	return normalized_name

func _cache_striker_bones():
	for bone_name in ["upperleg.R", "lowerleg.R", "foot.R"]:
		for bone_index in range(striker_skeleton.get_bone_count()):
			if striker_skeleton.get_bone_name(bone_index) == bone_name:
				striker_kick_bones.append(bone_index)
				striker_kick_rest_rotations.append(striker_skeleton.get_bone_pose_rotation(bone_index))
				break
	for bone_name in ["upperarm.L", "upperarm.R"]:
		for bone_index in range(striker_skeleton.get_bone_count()):
			if striker_skeleton.get_bone_name(bone_index) == bone_name:
				striker_arm_bones.append(bone_index)
				striker_arm_rest_rotations.append(striker_skeleton.get_bone_pose_rotation(bone_index))
				break

func _get_visual_bounds(root: Node3D) -> AABB:
	var found := false
	var combined := AABB()
	var root_inverse = root.global_transform.affine_inverse()
	for child in root.find_children("*", "VisualInstance3D", true, false):
		var visual = child as VisualInstance3D
		var relative_transform = root_inverse * visual.global_transform
		var bounds = visual.get_aabb() * relative_transform
		if found:
			combined = combined.merge(bounds)
		else:
			combined = bounds
			found = true
	return combined

func _play_striker_kick():
	if striker_root == null or striker_animation == null:
		return
	striker_penalty_animation_active = striker_is_human and striker_penalty_animation_length > 0.0
	if striker_penalty_animation_active:
		var contact_offset_world := striker_root.transform.basis * striker_penalty_contact_offset
		striker_run_up_start = Vector3(
			BALL_START.x - contact_offset_world.x,
			striker_rest_position.y,
			BALL_START.z - contact_offset_world.z
		)
		striker_run_up_target = striker_run_up_start
	else:
		striker_run_up_start = striker_rest_position
		striker_run_up_target = BALL_START + Vector3(-0.2, 0.0, 0.7)
	striker_root.position = striker_run_up_start
	striker_kick_elapsed = 0.0
	striker_kick_pose_active = false
	if striker_penalty_animation_active:
		striker_animation.play(STRIKER_PENALTY_CLIP)
		striker_animation.seek(0.0, true)
		return
	_play_gdbot_animation(striker_animation, &"run")

func _update_striker_kick_pose():
	if striker_skeleton == null or striker_kick_bones.size() < 3:
		return
	var time := striker_kick_elapsed - STRIKER_KICK_CONTACT_TIME
	
	if time < 0.0:
		return
	var swing := 0.0
	if time < 0.16:
		swing = -0.48 * time / 0.16
	elif time < 0.34:
		swing = lerpf(-0.48, 1.1, (time - 0.16) / 0.18)
	elif time < 0.62:
		swing = lerpf(1.1, 0.0, (time - 0.34) / 0.28)
	if time >= 0.62:
		for bone_index in striker_kick_bones:
			striker_skeleton.reset_bone_pose(bone_index)
		for bone_index in striker_arm_bones:
			striker_skeleton.reset_bone_pose(bone_index)
		return
	striker_skeleton.set_bone_pose_rotation(
		striker_kick_bones[0],
		striker_kick_rest_rotations[0] * Quaternion(Vector3.RIGHT, swing)
	)
	striker_skeleton.set_bone_pose_rotation(
		striker_kick_bones[1],
		striker_kick_rest_rotations[1] * Quaternion(Vector3.RIGHT, -maxf(swing, 0.0) * 0.62)
	)
	striker_skeleton.set_bone_pose_rotation(
		striker_kick_bones[2],
		striker_kick_rest_rotations[2] * Quaternion(Vector3.RIGHT, -swing * 0.22)
	)
	for index in range(striker_arm_bones.size()):
		var side := 1.0 if index == 0 else -1.0
		striker_skeleton.set_bone_pose_rotation(
			striker_arm_bones[index],
			striker_arm_rest_rotations[index] * Quaternion(Vector3.FORWARD, side * 0.48)
		)

func _build_aim_arrow():
	aim_arrow = Node3D.new()
	aim_arrow.name = "ShotAimArrow"
	aim_arrow.visible = false
	add_child(aim_arrow)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.78, 0.12, 0.94)
	material.emission_enabled = true
	material.emission = Color(0.75, 0.42, 0.02)

	var shaft := MeshInstance3D.new()
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.035
	shaft_mesh.bottom_radius = 0.035
	shaft_mesh.height = 3.7
	shaft.mesh = shaft_mesh
	shaft.material_override = material
	shaft.rotation.x = PI / 2.0
	shaft.position.z = -1.85
	aim_arrow.add_child(shaft)

	var tip := MeshInstance3D.new()
	var tip_mesh := CylinderMesh.new()
	tip_mesh.top_radius = 0.0
	tip_mesh.bottom_radius = 0.14
	tip_mesh.height = 0.36
	tip.mesh = tip_mesh
	tip.material_override = material
	tip.rotation.x = -PI / 2.0
	tip.position.z = -3.72
	aim_arrow.add_child(tip)

func update_aim_preview(direction: Vector3, curve: float, visible: bool):
	if aim_arrow == null or ball == null:
		return
	aim_arrow.visible = visible and can_local_shoot()
	if not aim_arrow.visible or direction.length_squared() < 0.001:
		return
	var average_direction = direction.normalized()
	average_direction.x += clampf(curve, -1.0, 1.0) * 0.12
	average_direction.y -= 0.08
	average_direction = average_direction.normalized()
	aim_arrow.global_position = ball.global_position + Vector3(0.0, 0.28, 0.0)
	aim_arrow.look_at(aim_arrow.global_position + average_direction, Vector3.UP)

func _resolve_keeper_ball_collision() -> bool:
	var closest_distance := INF
	var closest_point := Vector3.ZERO
	var contact_radius := 0.0
	if keeper_skeleton == null:
		var start := keeper_root.global_position + Vector3(0.0, 0.45, 0.0)
		var end := keeper_root.global_position + Vector3(0.0, 1.7, 0.0)
		var segment := end - start
		var amount := clampf((ball.global_position - start).dot(segment) / segment.length_squared(), 0.0, 1.0)
		closest_point = start + segment * amount
		closest_distance = ball.global_position.distance_to(closest_point)
		contact_radius = 0.42
	else:
		for bone_index in range(keeper_skeleton.get_bone_count()):
			var bone_name = keeper_skeleton.get_bone_name(bone_index)
			if bone_name.contains("Toe") or bone_name.contains("Thumb") or bone_name.contains("Index") or bone_name.contains("Middle") or bone_name.contains("Ring"):
				continue
			var bone_position = keeper_skeleton.global_transform * keeper_skeleton.get_bone_global_pose(bone_index).origin
			var radius = _keeper_bone_radius(bone_name)
			var distance = ball.global_position.distance_to(bone_position)
			if distance < closest_distance and distance <= BALL_RADIUS + radius:
				closest_distance = distance
				closest_point = bone_position
				contact_radius = BALL_RADIUS + radius
			var parent_index = keeper_skeleton.get_bone_parent(bone_index)
			if parent_index >= 0:
				var parent_position = keeper_skeleton.global_transform * keeper_skeleton.get_bone_global_pose(parent_index).origin
				var segment = bone_position - parent_position
				var segment_length_squared = segment.length_squared()
				if segment_length_squared > 0.000001:
					var amount = clampf((ball.global_position - parent_position).dot(segment) / segment_length_squared, 0.0, 1.0)
					var segment_point = parent_position + segment * amount
					distance = ball.global_position.distance_to(segment_point)
					if distance < closest_distance and distance <= BALL_RADIUS + radius:
						closest_distance = distance
						closest_point = segment_point
						contact_radius = BALL_RADIUS + radius
	if closest_distance == INF:
		return false
	var normal = ball.global_position - closest_point
	if normal.length_squared() < 0.000001:
		normal = Vector3(0.0, 0.0, 1.0)
	else:
		normal = normal.normalized()
	if ball_velocity.dot(normal) >= 0.0:
		return false
	ball.global_position = closest_point + normal * (contact_radius + 0.015)
	ball_velocity = ball_velocity.bounce(normal) * 0.72
	if ball_velocity.z > 0.5:
		keeper_save_confirmed = true
		keeper_save_timer = 0.28
	return true

func _try_keeper_catch() -> bool:
	if keeper_is_diving or keeper_has_ball or ball_velocity.z >= -0.5:
		return false
	var relative_x := ball.global_position.x - keeper_root.global_position.x
	if absf(relative_x) > 0.5 or ball.global_position.y < 0.48 or ball.global_position.y > 1.95:
		return false
	if absf(ball.global_position.z - keeper_root.global_position.z) > 0.55:
		return false
	keeper_has_ball = true
	keeper_save_confirmed = true
	keeper_save_timer = 1.0
	_reset_keeper_pose()
	ball.global_position = keeper_root.global_position + Vector3(0.0, 1.15, 0.42)
	ball_velocity = Vector3.ZERO
	_set_keeper_catch_pose()
	return true

func _set_keeper_catch_pose():
	if keeper_skeleton == null or keeper_arm_bones.size() != 4:
		return
	var arm_angles := [-0.9, 0.9, 0.9, -0.9]
	for index in range(keeper_arm_bones.size()):
		var axis := Vector3.FORWARD if index % 2 == 0 else Vector3.RIGHT
		keeper_skeleton.set_bone_pose_rotation(
			keeper_arm_bones[index],
			keeper_arm_rest_rotations[index] * Quaternion(axis, arm_angles[index])
		)

func _keeper_bone_radius(bone_name: String) -> float:
	if bone_name.contains("Head"):
		return 0.25
	if bone_name.contains("Hand"):
		return 0.2
	if bone_name.contains("Arm") or bone_name.contains("ForeArm"):
		return 0.22
	if bone_name.contains("Leg") or bone_name.contains("Foot"):
		return 0.24
	return 0.36

func _distance_to_segment(point: Vector3, start: Vector3, end: Vector3) -> float:
	var segment = end - start
	var length_squared = segment.length_squared()
	if length_squared <= 0.000001:
		return point.distance_to(start)
	var amount = clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(start + segment * amount)

func _shake_goal_net():
	for net_part in goal_net_parts:
		var origin := net_part.position
		var tween := create_tween()
		for _shake in range(3):
			tween.tween_property(net_part, "position:x", origin.x + 0.18, 0.07)
			tween.parallel().tween_property(net_part, "position:z", origin.z + 0.12, 0.07)
			tween.tween_property(net_part, "position:x", origin.x - 0.18, 0.07)
			tween.parallel().tween_property(net_part, "position:z", origin.z - 0.12, 0.07)
		tween.tween_property(net_part, "position", origin, 0.16)

@rpc("authority", "call_local", "reliable")
func shake_goal_net():
	_shake_goal_net()

func _remove_import_helpers(model: Node):
	for helper in model.find_children("*", "Camera3D", true, false):
		helper.queue_free()
	for helper in model.find_children("*", "Light3D", true, false):
		helper.queue_free()

func _build_hud():
	if DisplayServer.get_name() == "headless":
		return
	var hud = CanvasLayer.new()
	hud.name = "FreeKickHUD"
	add_child(hud)

	score_label = Label.new()
	score_label.anchor_left = 0.5
	score_label.anchor_right = 0.5
	score_label.offset_left = -390
	score_label.offset_top = 22
	score_label.offset_right = 390
	score_label.offset_bottom = 66
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_label.add_theme_font_size_override("font_size", 27)
	score_label.add_theme_color_override("font_color", Color(0.94, 0.96, 0.88))
	hud.add_child(score_label)
	_update_score()

	result_label = Label.new()
	result_label.anchor_left = 0.5
	result_label.anchor_top = 0.36
	result_label.anchor_right = 0.5
	result_label.anchor_bottom = 0.36
	result_label.offset_left = -240
	result_label.offset_right = 240
	result_label.offset_bottom = 60
	result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_label.add_theme_font_size_override("font_size", 42)
	result_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.32))
	result_label.visible = false
	hud.add_child(result_label)

	power_bar = ProgressBar.new()
	power_bar.anchor_left = 0.5
	power_bar.anchor_top = 1.0
	power_bar.anchor_right = 0.5
	power_bar.anchor_bottom = 1.0
	power_bar.offset_left = -150
	power_bar.offset_top = -96
	power_bar.offset_right = 150
	power_bar.offset_bottom = -76
	power_bar.max_value = 1.5
	power_bar.show_percentage = false
	power_bar.visible = false
	hud.add_child(power_bar)

	instruction_label = Label.new()
	instruction_label.anchor_left = 0.5
	instruction_label.anchor_top = 1.0
	instruction_label.anchor_right = 0.5
	instruction_label.anchor_bottom = 1.0
	instruction_label.offset_left = -300
	instruction_label.offset_top = -66
	instruction_label.offset_right = 300
	instruction_label.offset_bottom = -38
	instruction_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	instruction_label.text = "Waiting for opponent..."
	instruction_label.add_theme_font_size_override("font_size", 16)
	instruction_label.add_theme_color_override("font_color", Color(0.9, 0.92, 0.85))
	hud.add_child(instruction_label)

	role_label = Label.new()
	role_label.anchor_left = 1.0
	role_label.anchor_right = 1.0
	role_label.offset_left = -250
	role_label.offset_top = 28
	role_label.offset_right = -28
	role_label.offset_bottom = 58
	role_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	role_label.add_theme_font_size_override("font_size", 18)
	role_label.add_theme_color_override("font_color", Color(0.88, 0.93, 0.84))
	hud.add_child(role_label)
	hud.add_child(MatchManager.make_plaza_button())
	_on_local_role_changed(MatchManager.local_role())
	if MatchManager.match_ready:
		_on_match_state_changed(true)

func update_charge(amount: float, charging: bool, curve: float = 0.0):
	if power_bar:
		power_bar.visible = charging
		power_bar.value = amount
	if instruction_label and charging and absf(curve) > 0.05:
		instruction_label.text = "CURVE: %s" % ("RIGHT" if curve > 0.0 else "LEFT")
	elif instruction_label and not charging and MatchManager.match_ready:
		_update_instructions()

func submit_shot(direction: Vector3, power: float, curve: float):
	if not can_local_shoot():
		return
	if multiplayer.is_server():
		_handle_shot(1, direction, power, curve)
	else:
		request_shot.rpc_id(1, direction, power, curve)

@rpc("any_peer", "call_remote", "reliable")
func request_shot(direction: Vector3, power: float, curve: float):
	if multiplayer.is_server():
		_handle_shot(multiplayer.get_remote_sender_id(), direction, power, curve)

func _handle_shot(shooter_id: int, direction: Vector3, power: float, curve: float):
	if not MatchManager.match_ready or ball_active or kick_pending or reset_timer > 0:
		return
	if MatchManager.role_for_peer(shooter_id) != MatchManager.ROLE_PLAYER or shooter_id != _peer_for_role(MatchManager.ROLE_PLAYER):
		return
	if contest_finished:
		return
	var shooter = players.get_node_or_null(str(shooter_id))
	if shooter == null or shooter.global_position.distance_to(BALL_START) > 9.0:
		return
	if direction.z >= -0.05:
		return

	direction.y = clampf(direction.y, 0.3, 0.68)
	direction = direction.normalized()
	var shot_speed = 20.0 + clampf(power, 0.0, 1.5) * 2.5
	var velocity = direction * shot_speed
	keeper_target_x = keeper_root.position.x
	start_shot.rpc(BALL_START, velocity, clampf(curve, -1.0, 1.0), keeper_target_x, shooter_id, _peer_for_role(MatchManager.ROLE_GOALKEEPER))

func can_local_shoot() -> bool:
	if not MatchManager.match_ready or contest_finished or ball_active or kick_pending or reset_timer > 0.0:
		return false
	return MatchManager.local_role() == MatchManager.ROLE_PLAYER

@rpc("authority", "call_local", "reliable")
func start_shot(start_position: Vector3, velocity: Vector3, curve: float, target_x: float, shooter_id: int, keeper_id: int):
	ball.position = start_position
	ball.rotation = Vector3.ZERO
	ball_velocity = Vector3.ZERO
	pending_ball_start = start_position
	pending_ball_velocity = velocity
	ball_curve = curve
	keeper_save_confirmed = false
	keeper_save_timer = 0.0
	post_rebounded = false
	shot_result_reported = false
	target_ball_position = start_position
	ball_active = false
	kick_pending = true
	shot_elapsed = 0.0
	sync_timer = 0.0
	striker_animation.speed_scale = 1.0
	keeper_target_x = target_x
	keeper_root.position.x = target_x
	last_shooter_id = shooter_id
	last_keeper_id = keeper_id
	_play_striker_kick()
	if power_bar:
		power_bar.visible = false
	if aim_arrow:
		aim_arrow.visible = false

@rpc("authority", "call_local", "reliable")
func release_shot_ball(start_position: Vector3, velocity: Vector3):
	ball.position = start_position
	ball.rotation = Vector3.ZERO
	ball_velocity = velocity
	target_ball_position = start_position
	target_ball_rotation = Vector3.ZERO
	kick_pending = false
	ball_active = true
	shot_elapsed = 0.0
	sync_timer = 0.0


func _striker_foot_touches_ball() -> bool:
	if striker_skeleton == null or ball == null:
		return false
	var foot_bone_index := striker_penalty_toe_bone
	if foot_bone_index < 0 and striker_kick_bones.size() >= 3:
		foot_bone_index = striker_kick_bones[2]
	if foot_bone_index < 0:
		return false
	striker_skeleton.force_update_all_bone_transforms()
	var foot_transform := striker_skeleton.global_transform * striker_skeleton.get_bone_global_pose(foot_bone_index)
	return foot_transform.origin.distance_to(ball.global_position) <= BALL_RADIUS + STRIKER_FOOT_REACH


func move_keeper(axis: float, depth_axis: float = 0.0):
	if not MatchManager.match_ready or reset_timer > 0 or contest_finished:
		return
	keeper_movement_axis = clampf(axis, -1.0, 1.0)
	keeper_depth_axis = clampf(depth_axis, -1.0, 1.0)
	if multiplayer.is_server():
		_apply_keeper_movement(axis, depth_axis)
	else:
		request_keeper_movement.rpc_id(1, axis, depth_axis)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func request_keeper_movement(axis: float, depth_axis: float):
	if not multiplayer.is_server():
		return
	var peer_id = multiplayer.get_remote_sender_id()
	if MatchManager.role_for_peer(peer_id) != MatchManager.ROLE_GOALKEEPER or peer_id != _peer_for_role(MatchManager.ROLE_GOALKEEPER):
		return
	if reset_timer > 0:
		return
	_apply_keeper_movement(axis, depth_axis)

func _apply_keeper_movement(axis: float, depth_axis: float):
	keeper_movement_axis = clampf(axis, -1.0, 1.0)
	keeper_depth_axis = clampf(depth_axis, -1.0, 1.0)

func request_keeper_dive(side: int):
	if not MatchManager.match_ready or MatchManager.local_role() != MatchManager.ROLE_GOALKEEPER:
		return
	if multiplayer.is_server():
		_handle_keeper_dive(1, side)
	else:
		request_dive.rpc_id(1, side)

@rpc("any_peer", "call_remote", "reliable")
func request_dive(side: int):
	if multiplayer.is_server():
		_handle_keeper_dive(multiplayer.get_remote_sender_id(), side)

func _handle_keeper_dive(peer_id: int, side: int):
	if not MatchManager.match_ready or MatchManager.role_for_peer(peer_id) != MatchManager.ROLE_GOALKEEPER or peer_id != _peer_for_role(MatchManager.ROLE_GOALKEEPER):
		return
	if keeper_dive_cooldown > 0.0 or reset_timer > 0.0:
		return
	keeper_dive_cooldown = 1.1
	start_keeper_dive.rpc(clampi(side, -1, 1))

@rpc("authority", "call_local", "reliable")
func start_keeper_dive(side: int):
	keeper_movement_axis = 0.0
	keeper_depth_axis = 0.0
	keeper_model.scale = keeper_model_base_scale
	keeper_model.rotation = Vector3.ZERO
	var start_x := keeper_root.position.x
	keeper_dive_start_x = start_x
	keeper_target_x = start_x
	if side == 0:
		_play_keeper_jump(start_x)
		return
	var dive_duration := _play_keeper_animation()
	if dive_duration <= 0.0:
		return
	keeper_model.scale.x = absf(keeper_model_base_scale.x) * (1.0 if side > 0 else -1.0)
	var dive_x := clampf(start_x - side * KEEPER_DIVE_DISTANCE, -3.0, 3.0)
	var travel_time := minf(0.5, dive_duration * 0.2)
	var outward_tween := create_tween()
	outward_tween.set_parallel(true)
	outward_tween.tween_property(keeper_root, "position:x", dive_x, travel_time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	outward_tween.tween_property(keeper_root, "rotation:z", side * 0.3, travel_time)
	outward_tween.set_parallel(false)
	_return_keeper_dive_after(start_x, travel_time, maxf(0.0, dive_duration - travel_time * 2.0))

func _return_keeper_dive_after(start_x: float, travel_time: float, hold_time: float):
	await get_tree().create_timer(travel_time + hold_time).timeout
	var return_tween := create_tween()
	return_tween.set_parallel(true)
	return_tween.tween_property(keeper_root, "position:x", start_x, travel_time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	return_tween.tween_property(keeper_root, "rotation:z", 0.0, travel_time)
	return_tween.set_parallel(false)
	await return_tween.finished
	_finish_keeper_dive()

func _play_keeper_jump(start_x: float):
	keeper_model.scale = keeper_model_base_scale
	_reset_keeper_pose()
	keeper_is_diving = true
	keeper_root.position.x = start_x
	keeper_root.rotation.z = 0.0
	var tween = create_tween()
	tween.tween_property(keeper_root, "position:y", 0.55, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(keeper_root, "position:y", 0.0, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(_finish_keeper_jump)

func _finish_keeper_jump():
	keeper_is_diving = false
	_reset_keeper_pose()
	_reset_keeper_step_pose()

func _play_keeper_animation() -> float:
	var animation_name := &"mixamo_com"
	if keeper_animation == null or not keeper_animation.has_animation(animation_name):
		push_error("The goalkeeper dive animation is not available.")
		return 0.0
	_reset_keeper_pose()
	_reset_keeper_step_pose()
	keeper_is_diving = true
	keeper_animation.play(animation_name)
	return keeper_animation.get_animation(animation_name).length

func _finish_keeper_dive():
	keeper_is_diving = false
	keeper_root.position.x = keeper_dive_start_x
	keeper_root.position.y = 0.0
	keeper_root.rotation.z = 0.0
	keeper_model.scale = keeper_model_base_scale
	keeper_model.rotation = Vector3.ZERO
	_reset_keeper_pose()
	_reset_keeper_step_pose()

func _reset_keeper_pose():
	if keeper_animation:
		keeper_animation.stop()
	if keeper_skeleton:
		for bone_index in range(keeper_skeleton.get_bone_count()):
			keeper_skeleton.reset_bone_pose(bone_index)

@rpc("authority", "call_remote", "unreliable_ordered")
func sync_keeper_position(position_x: float, position_z: float, movement_axis: float, depth_axis: float):
	keeper_root.position.x = lerpf(keeper_root.position.x, position_x, 0.7)
	keeper_root.position.z = lerpf(keeper_root.position.z, position_z, 0.7)
	keeper_movement_axis = movement_axis
	keeper_depth_axis = depth_axis

func _physics_process(delta: float):
	_update_keeper_footwork(delta)
	if keeper_is_diving:
		_keep_keeper_above_pitch()
	if not multiplayer.is_server() or not MatchManager.match_ready or contest_finished:
		return
	if reset_timer <= 0.0 and not keeper_is_diving and Vector2(keeper_movement_axis, keeper_depth_axis).length() > 0.01:
		keeper_root.position.x = clampf(
			keeper_root.position.x - keeper_movement_axis * KEEPER_MOVE_SPEED * delta,
			-3.0,
			3.0
		)
		keeper_root.position.z = clampf(
			keeper_root.position.z + keeper_depth_axis * KEEPER_MOVE_SPEED * delta,
			KEEPER_LINE - 0.5,
			KEEPER_LINE + 1.8
		)
		keeper_target_x = keeper_root.position.x
	keeper_sync_timer += delta
	if keeper_sync_timer >= 0.05:
		keeper_sync_timer = 0.0
		sync_keeper_position.rpc(keeper_root.position.x, keeper_root.position.z, keeper_movement_axis, keeper_depth_axis)
	match_clock = maxf(0.0, match_clock - delta)
	clock_sync_timer += delta
	if clock_sync_timer >= 1.0:
		clock_sync_timer = 0.0
		sync_match_clock.rpc(match_clock)
	if match_clock <= 0.0:
		_finish_contest()
		return
	keeper_dive_cooldown = maxf(0.0, keeper_dive_cooldown - delta)
	if reset_timer > 0:
		reset_timer -= delta
		if reset_timer <= 0:
			if pending_role_swap:
				pending_role_swap = false
				MatchManager.swap_match_roles()
			reset_round.rpc()
			return
		if not ball_active:
			return
	if kick_pending:
		if striker_is_human and striker_penalty_animation_length > 0.0:
			if (
				striker_kick_elapsed >= STRIKER_CONTACT_SEARCH_START
				and _striker_foot_touches_ball()
			):
				release_shot_ball.rpc(pending_ball_start, pending_ball_velocity)
			elif striker_kick_elapsed >= striker_penalty_animation_length:
				push_error("The human striker animation finished without contacting the ball; resetting the shot.")
				reset_round.rpc()
			return
		if striker_kick_elapsed >= STRIKER_KICK_CONTACT_TIME:
			release_shot_ball.rpc(pending_ball_start, pending_ball_velocity)
		return
	if not ball_active:
		return
	if keeper_has_ball:
		ball.position = keeper_root.global_position + Vector3(0.0, 1.15, 0.42)
		ball_velocity = Vector3.ZERO
		if not shot_result_reported:
			keeper_save_timer -= delta
			if keeper_save_timer <= 0.0:
				_finish_shot("GOALKEEPER SAVE", false)
				return
		_sync_ball_state(delta)
		return

	var old_position = ball.position
	shot_elapsed += delta
	ball_velocity.y -= GRAVITY * delta
	if ball.position.y > BALL_RADIUS + 0.12:
		ball_velocity.x += ball_curve * ball_velocity.length() * 0.12 * delta
	ball.position += ball_velocity * delta
	ball.rotation.x += ball_velocity.z * delta / BALL_RADIUS
	ball.rotation.z -= ball_velocity.x * delta / BALL_RADIUS

	if not shot_result_reported:
		if not keeper_save_confirmed:
			if not _try_keeper_catch():
				_resolve_keeper_ball_collision()
		else:
			keeper_save_timer -= delta
			if keeper_save_timer <= 0.0:
				_finish_shot("GOALKEEPER SAVE", false)
				return
		if old_position.z > GOAL_LINE and ball.position.z <= GOAL_LINE:
			if _try_goal_frame_rebound():
				post_rebounded = true
			else:
				var scored = absf(ball.position.x) <= GOAL_HALF_WIDTH and ball.position.y > BALL_RADIUS and ball.position.y < GOAL_HEIGHT
				_finish_shot("GOOOL!" if scored else "AUT!", scored)
				return
		if post_rebounded and old_position.z <= GOAL_LINE and ball.position.z > GOAL_LINE:
			_finish_shot("HIT THE POST", false)
			return

	if ball.position.y < BALL_RADIUS:
		ball.position.y = BALL_RADIUS
		if ball_velocity.y < -1.0:
			ball_velocity.y = -ball_velocity.y * 0.42
		else:
			ball_velocity.y = 0.0
		ball_velocity.x *= 0.78
		ball_velocity.z *= 0.78
		if ball_velocity.length() < 2.0:
			if shot_result_reported:
				ball_velocity = Vector3.ZERO
			else:
				_finish_shot("OFF TARGET", false)
				return
	if ball_in_net:
		_contain_ball_in_net()
	if not shot_result_reported and (shot_elapsed > 3.5 or absf(ball.position.x) > 25.0):
		_finish_shot("GOALKEEPER SAVE" if keeper_save_confirmed else "OFF TARGET", false)
		return

	_sync_ball_state(delta)

func _sync_ball_state(delta: float):
	sync_timer += delta
	if sync_timer >= 0.05:
		sync_timer = 0.0
		sync_ball.rpc(ball.position, ball.rotation)

func _contain_ball_in_net():
	var back_z := GOAL_LINE - GOAL_DEPTH + BALL_RADIUS
	var side_x := GOAL_HALF_WIDTH - BALL_RADIUS
	if ball.position.z < back_z:
		ball.position.z = back_z
		ball_velocity.z = absf(ball_velocity.z) * 0.2
		ball_velocity.x *= 0.6
	if absf(ball.position.x) > side_x:
		ball.position.x = signf(ball.position.x) * side_x
		ball_velocity.x = -ball_velocity.x * 0.2
	var roof_y := GOAL_HEIGHT - BALL_RADIUS
	if ball.position.y > roof_y:
		ball.position.y = roof_y
		ball_velocity.y = -absf(ball_velocity.y) * 0.2
	if ball.position.z > GOAL_LINE and ball_velocity.z > 0.0:
		ball_velocity.z = 0.0
		ball.position.z = GOAL_LINE

func _keep_keeper_above_pitch():
	if not keeper_is_diving:
		return
	var minimum_y := INF
	for visual in keeper_visuals:
		if not is_instance_valid(visual):
			continue
		var bounds := visual.get_aabb()
		for x in [bounds.position.x, bounds.end.x]:
			for y in [bounds.position.y, bounds.end.y]:
				for z in [bounds.position.z, bounds.end.z]:
					minimum_y = minf(minimum_y, (visual.global_transform * Vector3(x, y, z)).y)
	if keeper_skeleton:
		for bone_index in range(keeper_skeleton.get_bone_count()):
			var bone_world_position := keeper_skeleton.global_transform * keeper_skeleton.get_bone_global_pose(bone_index).origin
			minimum_y = minf(minimum_y, bone_world_position.y - 0.12)
	if not is_finite(minimum_y):
		return
	keeper_root.position.y += 0.03 - minimum_y

func _process(delta: float):
	_keep_keeper_above_pitch()
	if keeper_has_ball:
		_set_keeper_catch_pose()
	if kick_pending or striker_kick_pose_active:
		striker_kick_elapsed += delta
	if kick_pending and not striker_penalty_animation_active:
		var run_up_weight := clampf(striker_kick_elapsed / STRIKER_KICK_CONTACT_TIME, 0.0, 1.0)
		striker_root.position = striker_run_up_start.lerp(striker_run_up_target, run_up_weight)
		striker_root.position.y += sin(striker_kick_elapsed * TAU * 2.4) * 0.035 * (1.0 - run_up_weight)
	if striker_kick_elapsed >= STRIKER_KICK_CONTACT_TIME:
		if not striker_kick_pose_active:
			striker_kick_pose_active = true
			if not striker_penalty_animation_active:
				_play_gdbot_animation(striker_animation, &"shot" if striker_is_human else &"Idle")
	if striker_penalty_animation_active:
		if striker_kick_elapsed >= striker_penalty_animation_length:
			_finish_striker_penalty_animation()
	elif striker_kick_pose_active:
		if striker_kick_elapsed < STRIKER_KICK_CONTACT_TIME + 0.62:
			_update_striker_kick_pose()
		else:
			for bone_index in striker_kick_bones:
				striker_skeleton.reset_bone_pose(bone_index)
			for bone_index in striker_arm_bones:
				striker_skeleton.reset_bone_pose(bone_index)
			striker_kick_pose_active = false
			if striker_is_human:
				_play_gdbot_animation(striker_animation, &"Idle")
	if ball_active and not multiplayer.is_server() and ball != null:
		ball.position = ball.position.lerp(target_ball_position, minf(delta * 16.0, 1.0))
		ball.rotation = ball.rotation.lerp(target_ball_rotation, minf(delta * 12.0, 1.0))


func _finish_striker_penalty_animation() -> void:
	striker_animation.seek(striker_penalty_animation_length, true)
	striker_skeleton.force_update_all_bone_transforms()
	var animated_hips := _striker_bone_position_in_root(striker_penalty_hips_bone)
	striker_animation.play(&"Idle")
	striker_animation.seek(0.0, true)
	striker_skeleton.force_update_all_bone_transforms()
	var idle_hips := _striker_bone_position_in_root(striker_penalty_hips_bone)
	var root_motion := animated_hips - idle_hips
	root_motion.y = 0.0
	striker_root.position += striker_root.transform.basis * root_motion
	striker_penalty_animation_active = false
	striker_kick_pose_active = false


func _striker_bone_position_in_root(bone_index: int) -> Vector3:
	var bone_world_position := striker_skeleton.global_transform * striker_skeleton.get_bone_global_pose(bone_index)
	return striker_root.to_local(bone_world_position.origin)


func _update_keeper_footwork(delta: float):
	var movement := Vector2(-keeper_movement_axis, keeper_depth_axis)
	var strength := clampf(movement.length(), 0.0, 1.0)
	keeper_step_time += delta * strength * 12.0
	if keeper_skeleton == null or keeper_leg_bones.size() != 6 or keeper_is_diving or keeper_has_ball:
		return
	if strength < 0.05:
		_reset_keeper_step_pose()
		keeper_model.rotation = Vector3.ZERO
		return
	keeper_model.rotation.x = -keeper_depth_axis * 0.08
	keeper_model.rotation.z = -movement.x * 0.08
	var stride = sin(keeper_step_time)
	var left_step = stride * strength
	var right_step = -left_step
	var angles = [
		left_step * 0.52,
		-maxf(left_step, 0.0) * 0.42,
		-maxf(left_step, 0.0) * 0.2,
		right_step * 0.52,
		-maxf(right_step, 0.0) * 0.42,
		-maxf(right_step, 0.0) * 0.2
	]
	for index in range(keeper_leg_bones.size()):
		keeper_skeleton.set_bone_pose_rotation(
			keeper_leg_bones[index],
			keeper_leg_rest_rotations[index] * Quaternion(Vector3.RIGHT, angles[index])
		)
		var step = left_step if index < 3 else right_step
		var foot_lift = maxf(step, 0.0) * 0.7 if index == 2 or index == 5 else 0.0
		var stride_offset = step * 0.4 if index == 2 or index == 5 else 0.0
		keeper_skeleton.set_bone_pose_position(
			keeper_leg_bones[index],
			keeper_leg_rest_positions[index] + Vector3(keeper_movement_axis * strength * 0.04, foot_lift, stride_offset)
		)
	if keeper_arm_bones.size() == 4:
		var arm_angles := [-stride * 0.42, -0.18, stride * 0.42, 0.18]
		for index in range(keeper_arm_bones.size()):
			keeper_skeleton.set_bone_pose_rotation(
				keeper_arm_bones[index],
				keeper_arm_rest_rotations[index] * Quaternion(Vector3.RIGHT, arm_angles[index])
			)

@rpc("authority", "call_remote", "unreliable_ordered")
func sync_ball(position: Vector3, rotation: Vector3):
	target_ball_position = position
	target_ball_rotation = rotation

func _try_goal_frame_rebound() -> bool:
	var frame_radius := BALL_RADIUS + 0.08
	for side in [-1.0, 1.0]:
		var post_center := Vector3(side * GOAL_HALF_WIDTH, clampf(ball.position.y, 0.0, GOAL_HEIGHT), GOAL_LINE)
		var offset := ball.position - post_center
		if offset.length() <= frame_radius:
			var normal := Vector3(side * 0.55, 0.0, 0.84).normalized()
			if ball_velocity.dot(normal) < 0.0:
				ball_velocity = ball_velocity.bounce(normal) * 0.72
				ball.position = post_center + normal * (frame_radius + 0.015)
				return true
	if absf(ball.position.x) <= GOAL_HALF_WIDTH and absf(ball.position.y - GOAL_HEIGHT) <= frame_radius:
		var normal := Vector3(0.0, -0.65 if ball.position.y < GOAL_HEIGHT else 0.65, 0.76).normalized()
		if ball_velocity.dot(normal) < 0.0:
			ball_velocity = ball_velocity.bounce(normal) * 0.72
			ball.position = Vector3(ball.position.x, GOAL_HEIGHT, GOAL_LINE) + normal * (frame_radius + 0.015)
			return true
	return false

func _finish_shot(result: String, scored: bool):
	if shot_result_reported:
		return
	shot_result_reported = true
	shots_taken += 1
	if scored:
		goals += 1
		ball_in_net = true
		player_scores[last_shooter_id] = int(player_scores.get(last_shooter_id, 0)) + 1
		shake_goal_net.rpc()
	elif result == "GOALKEEPER SAVE":
		saves += 1
		player_scores[last_keeper_id] = int(player_scores.get(last_keeper_id, 0)) + 1
	contest_finished = (
		int(player_scores.get(last_shooter_id, 0)) >= WINNING_SCORE
		or int(player_scores.get(last_keeper_id, 0)) >= WINNING_SCORE
	)
	pending_role_swap = not contest_finished
	reset_timer = POST_SHOT_DELAY if not contest_finished else 0.0
	ball_active = not contest_finished
	show_result.rpc(result, goals, saves, shots_taken, contest_finished, player_scores, _winner_peer_id())
	if contest_finished:
		_finish_contest()

func _finish_contest():
	contest_finished = true
	reset_timer = 0.0
	ball_active = false
	end_contest.rpc(goals, saves, shots_taken, player_scores, _winner_peer_id())

@rpc("authority", "call_remote", "unreliable_ordered")
func sync_match_clock(seconds_remaining: float):
	match_clock = seconds_remaining
	_update_score()

@rpc("authority", "call_local", "reliable")
func show_result(result: String, goal_count: int, save_count: int, shot_count: int, finished: bool, scores: Dictionary, winner_id: int):
	goals = goal_count
	saves = save_count
	shots_taken = shot_count
	contest_finished = finished
	player_scores = scores
	ball_active = not finished
	_update_score()
	if result_label:
		result_label.text = "%s\n%s" % [_winner_text(winner_id), result] if finished else result
		result_label.visible = true
	if instruction_label:
		_update_instructions()

@rpc("authority", "call_local", "reliable")
func end_contest(goal_count: int, save_count: int, shot_count: int, scores: Dictionary, winner_id: int):
	goals = goal_count
	saves = save_count
	shots_taken = shot_count
	player_scores = scores
	contest_finished = true
	reset_timer = 0.0
	_update_score()
	if result_label:
		result_label.text = "%s\nGOALS: %d  |  SAVES: %d" % [_winner_text(winner_id), goals, saves]
		result_label.visible = true
	if instruction_label:
		instruction_label.text = "FIRST TO 5 POINTS WINS"

@rpc("authority", "call_local", "reliable")
func reset_round():
	ball.position = BALL_START
	ball.rotation = Vector3.ZERO
	ball_velocity = Vector3.ZERO
	shot_result_reported = false
	ball_in_net = false
	pending_role_swap = false
	kick_pending = false
	pending_ball_velocity = Vector3.ZERO
	striker_kick_elapsed = 0.0
	striker_kick_pose_active = false
	striker_penalty_animation_active = false
	target_ball_position = BALL_START
	target_ball_rotation = Vector3.ZERO
	ball_active = false
	shot_elapsed = 0.0
	reset_timer = 0.0
	keeper_movement_axis = 0.0
	keeper_depth_axis = 0.0
	keeper_is_diving = false
	keeper_has_ball = false
	_reset_keeper_pose()
	_reset_keeper_step_pose()
	keeper_save_confirmed = false
	keeper_save_timer = 0.0
	keeper_model.scale = keeper_model_base_scale
	keeper_root.position.x = 0.0
	keeper_root.position.z = KEEPER_LINE
	keeper_root.position.y = 0.0
	striker_root.position = striker_rest_position
	if striker_animation:
		striker_animation.stop()
		_play_gdbot_animation(striker_animation, &"Idle")
	if striker_skeleton:
		for bone_index in striker_kick_bones:
			striker_skeleton.reset_bone_pose(bone_index)
		for bone_index in striker_arm_bones:
			striker_skeleton.reset_bone_pose(bone_index)
	_reset_keeper_pose()
	_reset_keeper_step_pose()
	keeper_root.rotation.z = 0.0
	if result_label:
		result_label.visible = false
	_update_instructions()

func _update_score():
	if score_label:
		score_label.text = "%s %02d  -  %02d %s    GOALS %d | SAVES %d | SHOTS %d    %02d:%02d" % [
			MatchManager.username_for_peer(player_a_id),
			int(player_scores.get(player_a_id, 0)),
			int(player_scores.get(player_b_id, 0)),
			MatchManager.username_for_peer(player_b_id),
			goals,
			saves,
			shots_taken,
			int(match_clock) / 60,
			int(match_clock) % 60
		]

func _peer_for_role(role: int) -> int:
	for peer_id in MatchManager.roster:
		if MatchManager.role_for_peer(peer_id) == role:
			return peer_id
	return 0

func _winner_peer_id() -> int:
	if player_scores.is_empty():
		return 0
	if player_a_id == player_b_id or player_b_id == 0:
		return 0
	var score_a = int(player_scores.get(player_a_id, 0))
	var score_b = int(player_scores.get(player_b_id, 0))
	if score_a == score_b:
		return 0
	return player_a_id if score_a > score_b else player_b_id

func _winner_text(winner_id: int) -> String:
	if winner_id == 0:
		return "DRAW"
	return "%s WINS" % MatchManager.username_for_peer(winner_id)

func get_keeper_position() -> Vector3:
	return keeper_root.global_position if keeper_root else Vector3(0.0, 0.0, KEEPER_LINE)

func set_keeper_first_person(enabled: bool):
	if keeper_model:
		keeper_model.visible = not enabled

func get_shooter_position() -> Vector3:
	return Vector3(-1.15, 0.0, BALL_START.z + 4.5)

func get_keeper_camera_position() -> Vector3:
	return Vector3(0.0, 3.0, KEEPER_LINE - 5.5)

func get_camera_focus_point() -> Vector3:
	return BALL_START + Vector3(0.0, 0.45, 0.0)

func _reset_keeper_step_pose():
	if keeper_skeleton == null:
		return
	for index in range(keeper_leg_bones.size()):
		keeper_skeleton.set_bone_pose_rotation(keeper_leg_bones[index], keeper_leg_rest_rotations[index])
		keeper_skeleton.set_bone_pose_position(keeper_leg_bones[index], keeper_leg_rest_positions[index])
	for index in range(keeper_arm_bones.size()):
		keeper_skeleton.set_bone_pose_rotation(keeper_arm_bones[index], keeper_arm_rest_rotations[index])

func _on_local_role_changed(role: int):
	if role_label:
		var team_name := "HUMAN" if MatchManager.team_for_peer(multiplayer.get_unique_id()) == MatchManager.TEAM_RED else "ROBOT"
		var role_name := "GOALKEEPER" if role == MatchManager.ROLE_GOALKEEPER else "STRIKER"
		role_label.text = "%s | %s | THIRD PERSON" % [team_name, role_name]
	_update_instructions()

func _on_role_selection_rejected(message: String):
	MatchManager.last_rejection = message
	MatchManager.disconnect_client()
	get_tree().change_scene_to_file("res://lobby.tscn")

func _on_match_state_changed(is_ready: bool):
	if not is_ready:
		if instruction_label:
			instruction_label.text = "Waiting for opponent..."
		if power_bar:
			power_bar.visible = false
		ball_active = false
		goals = 0
		saves = 0
		shots_taken = 0
		player_a_id = 0
		player_b_id = 0
		player_scores.clear()
		last_shooter_id = 0
		last_keeper_id = 0
		contest_finished = false
		match_clock = float(MatchManager.match_duration_minutes * 60)
		reset_timer = 0.0
		_update_score()
		ball.position = BALL_START
		target_ball_position = BALL_START
		match_clock = float(MatchManager.match_duration_minutes * 60)
		if keeper_root:
			keeper_root.position.x = 0.0
			keeper_root.rotation.z = 0.0
			keeper_is_diving = false
			pending_role_swap = false
			_reset_keeper_step_pose()
		_update_score()
		return
	var peer_ids: Array[int] = []
	for peer_id in MatchManager.roster:
		peer_ids.append(peer_id)
	peer_ids.sort()
	if peer_ids.size() == 2:
		player_a_id = peer_ids[0]
		player_b_id = peer_ids[1]
		if not player_scores.has(player_a_id):
			player_scores[player_a_id] = 0
		if not player_scores.has(player_b_id):
			player_scores[player_b_id] = 0
	if multiplayer.is_server():
		sync_match_clock.rpc(match_clock)
	_update_score()
	_update_instructions()
	if role_label:
		_on_local_role_changed(MatchManager.local_role())

func _update_instructions():
	if instruction_label == null or not MatchManager.match_ready:
		return
	if contest_finished:
		instruction_label.text = "FIRST TO 5 POINTS WINS"
		return
	if MatchManager.local_role() == MatchManager.ROLE_GOALKEEPER:
		if OS.has_feature("mobile") or OS.get_name() == "Android":
			instruction_label.text = "GOALKEEPER (FPS): Move left/right with the joystick  |  DIVE"
		else:
			instruction_label.text = "GOALKEEPER (FPS): ← / → move  |  SPACE to dive"
		return
	if OS.has_feature("mobile") or OS.get_name() == "Android":
		instruction_label.text = "STRIKER (THIRD PERSON): Drag to aim  |  Hold SHOOT  |  CURVE +/-"
	else:
		instruction_label.text = "STRIKER (THIRD PERSON): Aim with the mouse  |  Hold and release left click  |  R/T to curve"
