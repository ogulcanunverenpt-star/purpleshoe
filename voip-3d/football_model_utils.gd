extends RefCounted

const HUMAN_ANIMATION_LIBRARY = preload("res://Assets/FootballHuman/human_animations.tres")
const MATCH_JERSEY_SHADER = preload("res://match_jersey.gdshader")
const GOAL_CELEBRATION_SCENES := {
	&"goal_flip": preload("res://Assets/MatchCelebrations/Running Forward Flip.fbx"),
	&"goal_slide": preload("res://Assets/MatchCelebrations/Slide Hip Hop Dance.fbx"),
	&"goal_hiphop": preload("res://Assets/MatchCelebrations/Hip Hop Dancing Supplied.fbx"),
}
const GOAL_TEAMMATE_ANIMATION = preload("res://Assets/MatchCelebrations/Victory.fbx")

static func apply_match_jersey(model_root: Node3D, jersey_color: Color) -> bool:
	var body := model_root.find_child("new_body", true, false) as MeshInstance3D
	var skeletons := model_root.find_children("*", "Skeleton3D", true, false)
	if body == null or body.mesh == null or skeletons.is_empty():
		push_error("Cannot apply match jersey: human body or skeleton is missing.")
		return false
	var skin_material := body.get_surface_override_material(0) as BaseMaterial3D
	var skeleton := skeletons[0] as Skeleton3D
	var hips_index := skeleton.find_bone("mixamorig_Hips")
	var neck_index := skeleton.find_bone("mixamorig_Neck")
	var arm_index := skeleton.find_bone("mixamorig_LeftArm")
	var forearm_index := skeleton.find_bone("mixamorig_LeftForeArm")
	if skin_material == null or skin_material.albedo_texture == null or min(hips_index, neck_index, arm_index, forearm_index) < 0:
		push_error("Cannot apply match jersey: skin texture or expected bones are missing.")
		return false
	if body.mesh.get_blend_shape_count() != 0:
		push_error("Cannot apply match jersey to a mesh with blend shapes.")
		return false
	var hips := body.to_local(skeleton.to_global(skeleton.get_bone_global_rest(hips_index).origin))
	var neck := body.to_local(skeleton.to_global(skeleton.get_bone_global_rest(neck_index).origin))
	var arm := body.to_local(skeleton.to_global(skeleton.get_bone_global_rest(arm_index).origin))
	var forearm := body.to_local(skeleton.to_global(skeleton.get_bone_global_rest(forearm_index).origin))
	var sleeve_width := absf(arm.x - hips.x) + absf(forearm.x - arm.x) * 0.5
	var shirt_mesh := ArrayMesh.new()
	for surface in range(body.mesh.get_surface_count()):
		var arrays := body.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var colors := PackedColorArray()
		colors.resize(vertices.size())
		for i in range(vertices.size()):
			var vertex := vertices[i]
			var covered := vertex.y >= hips.y + 0.025 and vertex.y <= neck.y - 0.02 \
					and absf(vertex.x - hips.x) <= sleeve_width
			colors[i] = Color(1.0, 1.0, 1.0, 1.0 if covered else 0.0)
		arrays[Mesh.ARRAY_COLOR] = colors
		shirt_mesh.add_surface_from_arrays(body.mesh.surface_get_primitive_type(surface), arrays)
		shirt_mesh.surface_set_material(surface, body.mesh.surface_get_material(surface))
	body.mesh = shirt_mesh
	var jersey_material := ShaderMaterial.new()
	jersey_material.shader = MATCH_JERSEY_SHADER
	jersey_material.set_shader_parameter("skin_texture", skin_material.albedo_texture)
	jersey_material.set_shader_parameter("jersey_color", jersey_color)
	for surface in range(shirt_mesh.get_surface_count()):
		body.set_surface_override_material(surface, jersey_material)
	return true


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


static func retarget_goal_dance(source_animation: Animation, source_model: Node3D, model_root: Node3D, target_skeleton: Skeleton3D, target_player: AnimationPlayer) -> Animation:
	var source_skeletons := source_model.find_children("*", "Skeleton3D", true, false)
	if source_skeletons.is_empty():
		push_error("Goal dance source has no skeleton.")
		return null
	var source_skeleton := source_skeletons[0] as Skeleton3D
	var source_parent := source_skeleton.get_parent() as Node3D
	var source_hips := source_skeleton.find_bone("ValveBiped_Bip01_Pelvis")
	var target_hips := target_skeleton.find_bone("mixamorig_Hips")
	var robot := target_hips < 0
	if robot:
		target_hips = target_skeleton.find_bone("hips")
	if source_parent == null or source_parent.get_parent() != source_model or source_hips < 0 or target_hips < 0:
		push_error("Goal dance skeleton hierarchy is incompatible with the target model.")
		return null
	var parent_path := source_model.get_path_to(source_parent)
	var position_track := -1
	var rotation_track := -1
	for i in range(source_animation.get_track_count()):
		if source_animation.track_get_path(i) != parent_path:
			continue
		if source_animation.track_get_type(i) == Animation.TYPE_POSITION_3D:
			position_track = i
		elif source_animation.track_get_type(i) == Animation.TYPE_ROTATION_3D:
			rotation_track = i
	if position_track < 0 or rotation_track < 0:
		push_error("Goal dance is missing its animated skeleton root.")
		return null
	var animation := source_animation.duplicate(true) as Animation
	var skeleton_path := model_root.get_path_to(target_skeleton)
	var source_basis := source_parent.transform.basis * source_skeleton.transform.basis
	var target_basis := target_skeleton.transform.basis
	for track in range(animation.get_track_count() - 1, -1, -1):
		var path := animation.track_get_path(track)
		if path.get_subname_count() == 0 or animation.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			animation.remove_track(track)
			continue
		var bone_name := String(path.get_subname(path.get_subname_count() - 1))
		var source_index := source_skeleton.find_bone(bone_name)
		var target_index := -1
		for i in range(target_skeleton.get_bone_count()):
			if _normalized_bone_name(target_skeleton.get_bone_name(i)) == _normalized_bone_name(bone_name):
				target_index = i
				break
		if source_index < 0 or target_index < 0:
			animation.remove_track(track)
			continue
		var source_rest := source_skeleton.get_bone_rest(source_index).basis.get_rotation_quaternion()
		var target_rest := target_skeleton.get_bone_rest(target_index).basis.get_rotation_quaternion()
		var source_global := (source_basis * source_skeleton.get_bone_global_rest(source_index).basis).orthonormalized().get_rotation_quaternion()
		var target_global := (target_basis * target_skeleton.get_bone_global_rest(target_index).basis).orthonormalized().get_rotation_quaternion()
		var alignment := source_global.inverse() * target_global
		for key in range(animation.track_get_key_count(track)):
			var source_rotation: Quaternion = animation.track_get_key_value(track, key)
			var delta := source_rest.inverse() * source_rotation
			animation.track_set_key_value(track, key, (target_rest * alignment.inverse() * delta * alignment).normalized())
		animation.track_set_path(track, NodePath("%s:%s" % [skeleton_path, target_skeleton.get_bone_name(target_index)]))
	var source_hips_rest := source_skeleton.get_bone_global_rest(source_hips)
	var source_rest_transform := source_parent.transform * source_skeleton.transform * source_hips_rest
	var target_path := NodePath("%s:%s" % [skeleton_path, target_skeleton.get_bone_name(target_hips)])
	var target_position := target_skeleton.get_bone_global_rest(target_hips).origin
	if not robot:
		if not target_player.has_animation(&"Idle"):
			push_error("Goal dance target has no idle animation.")
			return null
		var idle := target_player.get_animation(&"Idle")
		var idle_track := idle.find_track(target_path, Animation.TYPE_POSITION_3D)
		if idle_track < 0:
			push_error("Goal dance target idle animation has no hip position.")
			return null
		target_position = idle.position_track_interpolate(idle_track, 0.0)
	if source_rest_transform.origin.y <= 0.001 or target_position.y <= 0.0:
		push_error("Goal dance skeleton has an invalid hip height.")
		return null
	var scale := target_position.y / source_rest_transform.origin.y
	var rest_rotation := source_rest_transform.basis.orthonormalized().get_rotation_quaternion()
	var root_bones: Array[int] = [target_hips]
	if robot:
		root_bones.clear()
		for i in range(target_skeleton.get_bone_count()):
			if target_skeleton.get_bone_parent(i) < 0:
				root_bones.append(i)
	var root_tracks: Array[Vector2i] = []
	for bone in root_bones:
		var root_path := NodePath("%s:%s" % [skeleton_path, target_skeleton.get_bone_name(bone)])
		var position_index := animation.add_track(Animation.TYPE_POSITION_3D)
		animation.track_set_path(position_index, root_path)
		var rotation_index := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(rotation_index, root_path)
		root_tracks.append(Vector2i(position_index, rotation_index))
	var samples := ceili(source_animation.length * 30.0)
	for i in range(samples + 1):
		var time := minf(float(i) / 30.0, source_animation.length)
		var source_position := source_animation.position_track_interpolate(position_track, time)
		var source_rotation := source_animation.rotation_track_interpolate(rotation_track, time)
		var animated_transform := Transform3D(Basis(source_rotation), source_position) * source_skeleton.transform * source_hips_rest
		var delta_rotation := animated_transform.basis.orthonormalized().get_rotation_quaternion() * rest_rotation.inverse()
		for root_index in range(root_bones.size()):
			var bone := root_bones[root_index]
			var root_rest := target_skeleton.get_bone_rest(bone)
			var position := target_position
			if robot:
				position += delta_rotation * (root_rest.origin - target_position)
				position.y += (animated_transform.origin.y - source_rest_transform.origin.y) * scale
			else:
				position.y = animated_transform.origin.y * scale
			animation.position_track_insert_key(root_tracks[root_index].x, time, position)
			var rotation := delta_rotation * root_rest.basis.get_rotation_quaternion()
			animation.rotation_track_insert_key(root_tracks[root_index].y, time, rotation.normalized())
	return animation


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
