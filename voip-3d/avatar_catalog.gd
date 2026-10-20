extends RefCounted
class_name AvatarCatalog

const MAN := "man"
const JOURNALIST := "journalist"
const WOMAN := JOURNALIST
const LEGACY_WOMAN := "woman"
const LEGACY_RONALDO := "ronaldo"
const GOALKEEPER := "goalkeeper"
const ROBOT := "robot"


static func canonical_avatar_id(avatar_id: String) -> String:
	return JOURNALIST if avatar_id in [LEGACY_WOMAN, LEGACY_RONALDO] else avatar_id


static func is_valid_avatar(avatar_id: String) -> bool:
	return canonical_avatar_id(avatar_id) in [MAN, JOURNALIST, GOALKEEPER, ROBOT]


static func supports_shared_human_animations(avatar_id: String) -> bool:
	return canonical_avatar_id(avatar_id) in [MAN, JOURNALIST, GOALKEEPER]


static func display_name(avatar_id: String) -> String:
	match canonical_avatar_id(avatar_id):
		MAN:
			return "Male"
		JOURNALIST:
			return "Reporter"
		GOALKEEPER:
			return "Goalkeeper"
		ROBOT:
			return "Robot"
	return ""


static func scene_for(avatar_id: String) -> PackedScene:
	var scene_path := ""
	match canonical_avatar_id(avatar_id):
		MAN:
			scene_path = "res://Assets/FootballHuman/Soccer Pass.fbx"
		WOMAN:
			scene_path = "res://Assets/FootballHuman/fuse_woman_1.glb"
		GOALKEEPER:
			scene_path = "res://goalkeeper_stylized.glb"
		ROBOT:
			scene_path = "res://gdbot.glb"
	if scene_path.is_empty():
		push_error("Unknown avatar model requested: %s" % avatar_id)
		return null
	var packed_scene := load(scene_path) as PackedScene
	if packed_scene == null:
		push_error("Could not load avatar model: %s" % scene_path)
	return packed_scene


static func apply_male_textures(
	model_root: Node3D,
	clothing_color: Color = Color(0.17, 0.14, 0.24)
) -> bool:
	var skin_texture := load("res://Assets/FootballHuman/textures/Body_D2.tga.png") as Texture2D
	var hair_texture := load("res://Assets/FootballHuman/textures/hair_01_c.tga.png") as Texture2D
	if skin_texture == null or hair_texture == null:
		push_error("Male avatar skin or hair texture could not be loaded.")
		return false

	var skin_material := StandardMaterial3D.new()
	skin_material.resource_name = "MaleSkin"
	skin_material.albedo_texture = skin_texture
	skin_material.roughness = 0.82
	skin_material.metallic_specular = 0.25

	var hair_material := StandardMaterial3D.new()
	hair_material.resource_name = "MaleHair"
	hair_material.albedo_texture = hair_texture
	hair_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	hair_material.alpha_scissor_threshold = 0.3
	hair_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	hair_material.roughness = 0.9

	var clothing_material := StandardMaterial3D.new()
	clothing_material.resource_name = "MaleFootballShorts"
	clothing_material.albedo_color = clothing_color
	clothing_material.roughness = 0.85

	var found_body := false
	var found_pants := false
	var found_hair := false
	for child in model_root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		match String(mesh_instance.name):
			"new_body":
				found_body = _set_surface_material(mesh_instance, skin_material)
			"new_pant":
				found_pants = _set_surface_material(mesh_instance, clothing_material)
			"new_hair", "man__Beard003":
				found_hair = _set_surface_material(mesh_instance, hair_material) or found_hair
	if not found_body or not found_pants or not found_hair:
		push_error(
			"Male avatar mesh is missing a textured body, pants, or hair part (body=%s, pants=%s, hair=%s)."
			% [found_body, found_pants, found_hair]
		)
		return false
	return true


static func _set_surface_material(mesh_instance: MeshInstance3D, material: Material) -> bool:
	if mesh_instance.mesh == null or mesh_instance.mesh.get_surface_count() == 0:
		push_error("Male avatar mesh has no material surfaces: %s" % mesh_instance.name)
		return false
	for surface_index in range(mesh_instance.mesh.get_surface_count()):
		mesh_instance.set_surface_override_material(surface_index, material)
	return true


static func fit_model_to_height(model: Node3D, target_height: float) -> bool:
	if target_height <= 0.0:
		push_error("Avatar target height must be positive.")
		return false
	model.scale = Vector3.ONE
	model.position = Vector3.ZERO
	var bounds := _get_visual_bounds(model)
	if bounds.size.y <= 0.0:
		push_error("Avatar model has invalid visual bounds: %s" % model.name)
		return false
	model.scale = Vector3.ONE * (target_height / bounds.size.y)
	model.position.y = -bounds.position.y * model.scale.y
	return true


static func _get_visual_bounds(root: Node3D) -> AABB:
	var found := false
	var combined := AABB()
	for child in root.find_children("*", "VisualInstance3D", true, false):
		var visual := child as VisualInstance3D
		var relative_transform := Transform3D.IDENTITY
		var current: Node = visual
		while current != root:
			if current is Node3D:
				relative_transform = (current as Node3D).transform * relative_transform
			current = current.get_parent()
		var visual_bounds := _transform_aabb(visual.get_aabb(), relative_transform)
		if found:
			combined = combined.merge(visual_bounds)
		else:
			combined = visual_bounds
			found = true
	return combined if found else AABB()


static func _transform_aabb(bounds: AABB, transform: Transform3D) -> AABB:
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
