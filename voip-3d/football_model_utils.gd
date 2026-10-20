extends RefCounted

const HUMAN_ANIMATION_LIBRARY = preload("res://Assets/FootballHuman/human_animations.tres")


static func install_human_animations(animation_player: AnimationPlayer, model_root: Node3D) -> bool:
	var skeletons := model_root.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		push_error("Football animation target has no Skeleton3D.")
		return false
	var skeleton := skeletons[0] as Skeleton3D
	var skeleton_path := model_root.get_path_to(skeleton)
	for library_name: StringName in animation_player.get_animation_library_list():
		animation_player.remove_animation_library(library_name)
	var animation_library := HUMAN_ANIMATION_LIBRARY.duplicate(true) as AnimationLibrary
	for animation_name: StringName in animation_library.get_animation_list():
		var animation := animation_library.get_animation(animation_name)
		var normalized_animation_name := String(animation_name).to_lower()
		if normalized_animation_name in ["idle", "walk", "run", "backward"]:
			animation.loop_mode = Animation.LOOP_LINEAR
		for track_index in range(animation.get_track_count()):
			var track_path := animation.track_get_path(track_index)
			if track_path.get_subname_count() == 0:
				continue
			var source_bone_name := String(track_path.get_subname(0))
			var normalized_name := _normalized_bone_name(source_bone_name)
			var target_bone_name := ""
			var target_bone_index := -1
			for bone_index in range(skeleton.get_bone_count()):
				var candidate_name := String(skeleton.get_bone_name(bone_index))
				if _normalized_bone_name(candidate_name) == normalized_name:
					target_bone_name = candidate_name
					target_bone_index = bone_index
					break
			if target_bone_name.is_empty():
				push_warning("Football animation bone was not found on target skeleton: %s" % source_bone_name)
				continue
			if normalized_name == "hips":
				scale_hips_position_track(animation, track_index, skeleton, target_bone_index)
				if normalized_animation_name in ["walk", "run", "backward"]:
					remove_locomotion_root_motion(animation, track_index)
			animation.track_set_path(track_index, NodePath("%s:%s" % [skeleton_path, target_bone_name]))
	var add_result := animation_player.add_animation_library(&"", animation_library)
	if add_result != OK:
		push_error("Could not install football animation library: %s" % error_string(add_result))
		return false
	return true


static func install_human_action_animations(animation_player: AnimationPlayer, model_root: Node3D) -> bool:
	var skeletons := model_root.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		push_error("Football action animation target has no Skeleton3D.")
		return false
	var skeleton := skeletons[0] as Skeleton3D
	var animation_library: AnimationLibrary
	if animation_player.has_animation_library(&""):
		animation_library = animation_player.get_animation_library(&"")
	else:
		animation_library = AnimationLibrary.new()
		var library_result := animation_player.add_animation_library(&"", animation_library)
		if library_result != OK:
			push_error("Could not create the football action animation library: %s" % error_string(library_result))
			return false
	for animation_name: StringName in [&"pass", &"cross", &"tackle"]:
		var source_animation := HUMAN_ANIMATION_LIBRARY.get_animation(animation_name)
		var animation := retarget_animation(source_animation, model_root, skeleton, true)
		if animation.get_track_count() == 0:
			push_error("Football action animation has no bones compatible with the target model: %s" % animation_name)
			return false
		animation.loop_mode = Animation.LOOP_NONE
		if animation_library.has_animation(animation_name):
			animation_library.remove_animation(animation_name)
		var add_result := animation_library.add_animation(animation_name, animation)
		if add_result != OK:
			push_error("Could not install football action animation %s: %s" % [animation_name, error_string(add_result)])
			return false
	return true


static func configure_locomotion_loops(animation_player: AnimationPlayer) -> void:
	for animation_name: StringName in animation_player.get_animation_list():
		if String(animation_name).to_lower() in ["idle", "walk", "run", "backward"]:
			animation_player.get_animation(animation_name).loop_mode = Animation.LOOP_LINEAR


static func retarget_animation(
	source_animation: Animation,
	model_root: Node3D,
	target_skeleton: Skeleton3D,
	discard_unmapped_tracks := false
) -> Animation:
	var animation := source_animation.duplicate(true) as Animation
	var skeleton_path := model_root.get_path_to(target_skeleton)
	for track_index in range(animation.get_track_count() - 1, -1, -1):
		var track_path := animation.track_get_path(track_index)
		if track_path.get_subname_count() == 0:
			if discard_unmapped_tracks:
				animation.remove_track(track_index)
			continue
		var source_bone_name := String(track_path.get_subname(track_path.get_subname_count() - 1))
		var normalized_name := _normalized_bone_name(source_bone_name)
		var target_bone_name := ""
		var target_bone_index := -1
		for bone_index in range(target_skeleton.get_bone_count()):
			var candidate_name := String(target_skeleton.get_bone_name(bone_index))
			if _normalized_bone_name(candidate_name) == normalized_name:
				target_bone_name = candidate_name
				target_bone_index = bone_index
				break
		if target_bone_name.is_empty():
				if discard_unmapped_tracks:
					animation.remove_track(track_index)
				else:
					push_warning("Football animation bone was not found on target skeleton: %s" % source_bone_name)
				continue
		if normalized_name == "hips":
				scale_hips_position_track(animation, track_index, target_skeleton, target_bone_index)
		animation.track_set_path(track_index, NodePath("%s:%s" % [skeleton_path, target_bone_name]))
	return animation


static func remove_locomotion_root_motion(animation: Animation, track_index: int) -> void:
	var key_count := animation.track_get_key_count(track_index)
	if animation.track_get_type(track_index) != Animation.TYPE_POSITION_3D or key_count < 2:
		return
	var first_position: Vector3 = animation.track_get_key_value(track_index, 0)
	var last_position: Vector3 = animation.track_get_key_value(track_index, key_count - 1)
	var horizontal_delta := Vector2(last_position.x - first_position.x, last_position.z - first_position.z)
	if horizontal_delta.length_squared() <= 0.000001:
		return
	var final_key_time := animation.track_get_key_time(track_index, key_count - 1)
	if final_key_time <= 0.0:
		return
	for key_index in range(key_count):
		var key_position: Vector3 = animation.track_get_key_value(track_index, key_index)
		var progress := animation.track_get_key_time(track_index, key_index) / final_key_time
		key_position.x -= horizontal_delta.x * progress
		key_position.z -= horizontal_delta.y * progress
		animation.track_set_key_value(track_index, key_index, key_position)


static func scale_hips_position_track(
	animation: Animation,
	track_index: int,
	skeleton: Skeleton3D,
	hips_bone_index: int
) -> void:
	if (
		animation.track_get_type(track_index) != Animation.TYPE_POSITION_3D
		or animation.track_get_key_count(track_index) == 0
	):
		return
	var source_hips_position: Vector3 = animation.track_get_key_value(track_index, 0)
	var target_hips_height := skeleton.get_bone_pose_position(hips_bone_index).y
	if absf(source_hips_position.y) <= 0.001 or target_hips_height <= 0.0:
		return
	var position_scale := target_hips_height / source_hips_position.y
	for key_index in range(animation.track_get_key_count(track_index)):
		var key_position: Vector3 = animation.track_get_key_value(track_index, key_index)
		animation.track_set_key_value(track_index, key_index, key_position * position_scale)


static func _normalized_bone_name(bone_name: String) -> String:
	var normalized_name := bone_name.to_lower()
	normalized_name = normalized_name.trim_prefix("mixamorig_").trim_prefix("mixamorig:")
	normalized_name = normalized_name.trim_prefix("valvebiped_bip01_")
	var suffix_index := normalized_name.rfind("_")
	if suffix_index >= 0 and normalized_name.substr(suffix_index + 1).is_valid_int():
		normalized_name = normalized_name.substr(0, suffix_index)
	var bone_aliases := {
		"pelvis": "hips",
		"head1": "head",
		"neck1": "neck",
		"r_clavicle": "rightshoulder",
		"l_clavicle": "leftshoulder",
		"r_upperarm": "rightarm",
		"l_upperarm": "leftarm",
		"r_forearm": "rightforearm",
		"l_forearm": "leftforearm",
		"r_hand": "righthand",
		"l_hand": "lefthand",
		"r_thigh": "rightupleg",
		"l_thigh": "leftupleg",
		"r_calf": "rightleg",
		"l_calf": "leftleg",
		"r_foot": "rightfoot",
		"l_foot": "leftfoot",
		"r_toe0": "righttoebase",
		"l_toe0": "lefttoebase",
		"upperleg.l": "leftupleg",
		"upperleg.r": "rightupleg",
		"lowerleg.l": "leftleg",
		"lowerleg.r": "rightleg",
		"foot.l": "leftfoot",
		"foot.r": "rightfoot",
		"upperarm.l": "leftarm",
		"upperarm.r": "rightarm",
		"lowerarm.l": "leftforearm",
		"lowerarm.r": "rightforearm",
		"hand.l": "lefthand",
		"hand.r": "righthand",
		"fake_shoulder.l": "leftshoulder",
		"fake_shoulder.r": "rightshoulder",
		"torso": "spine",
	}
	return String(bone_aliases.get(normalized_name, normalized_name))
