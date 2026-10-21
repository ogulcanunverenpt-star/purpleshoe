extends Node3D

const LOBBY_PLAYER_SCENE = preload("res://lobby_player.tscn")

@onready var players_container: Node3D = $Players
@onready var online_players_label: Label = $CanvasLayer/HUD/VBox/OnlinePlayersLabel
@onready var status_label: Label = $CanvasLayer/HUD/StatusLabel


func _ready() -> void:
	_build_farm()
	MatchManager.player_state_changed.connect(_on_player_state_changed)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_spawn_all_players()
	_update_roster()


func _spawn_all_players() -> void:
	for peer_id in MatchManager.roster:
		_spawn_player(int(peer_id))
	if MatchManager.roster.is_empty() and multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		_spawn_player(1)


func _spawn_player(peer_id: int) -> void:
	if peer_id <= 0 or players_container.has_node(str(peer_id)):
		return

	var player := LOBBY_PLAYER_SCENE.instantiate() as Node3D
	player.name = str(peer_id)
	var angle := float(peer_id) * 2.399963
	player.position = Vector3(cos(angle) * 3.0, 0.0, sin(angle) * 3.0)
	players_container.add_child(player, true)


func _on_player_state_changed(peer_id: int, team: int, _role: int, _username: String) -> void:
	if team < 0:
		_remove_player(peer_id)
	else:
		_spawn_player(peer_id)
	_update_roster()


func _on_peer_disconnected(peer_id: int) -> void:
	_remove_player(peer_id)
	_update_roster()


func _remove_player(peer_id: int) -> void:
	var player := players_container.get_node_or_null(str(peer_id))
	if player:
		player.queue_free()


func _update_roster() -> void:
	var names: Array[String] = []
	for peer_id in MatchManager.roster:
		var username := MatchManager.username_for_peer(int(peer_id))
		names.append(username if not username.is_empty() else "Player_%d" % int(peer_id))
	online_players_label.text = "FARM VOICE CHAT · %d PLAYERS" % names.size()
	if not names.is_empty():
		online_players_label.text += "\n" + " · ".join(names)
	status_label.text = "Press V to talk · your gdbot display name is visible to other players"


func _on_ptt_button_down() -> void:
	var player := players_container.get_node_or_null(str(multiplayer.get_unique_id()))
	if player and "ptt_touch_active" in player:
		player.set("ptt_touch_active", true)


func _on_ptt_button_up() -> void:
	var player := players_container.get_node_or_null(str(multiplayer.get_unique_id()))
	if player and "ptt_touch_active" in player:
		player.set("ptt_touch_active", false)


func _on_exit_btn_pressed() -> void:
	get_tree().change_scene_to_file(NetJoin.SHOWROOM_SCENE)


func _build_farm() -> void:
	var farm := Node3D.new()
	farm.name = "FarmDecor"
	add_child(farm)

	var barn := Node3D.new()
	barn.name = "Barn"
	barn.position = Vector3(-13.0, 0.0, -10.0)
	farm.add_child(barn)
	_add_box(barn, "BarnBody", Vector3(0, 2.0, 0), Vector3(9.0, 4.0, 8.0), Color(0.64, 0.24, 0.16))
	_add_box(barn, "BarnRoofLeft", Vector3(-2.3, 4.35, 0), Vector3(5.0, 0.35, 9.0), Color(0.28, 0.17, 0.13), Vector3(0, 0, deg_to_rad(-26.0)))
	_add_box(barn, "BarnRoofRight", Vector3(2.3, 4.35, 0), Vector3(5.0, 0.35, 9.0), Color(0.28, 0.17, 0.13), Vector3(0, 0, deg_to_rad(26.0)))
	_add_box(barn, "BarnDoor", Vector3(0, 1.4, 4.08), Vector3(2.4, 2.8, 0.16), Color(0.3, 0.16, 0.09))
	_add_box(farm, "HayBaleOne", Vector3(-7.0, 0.65, -8.0), Vector3(1.8, 1.3, 1.5), Color(0.8, 0.61, 0.24))
	_add_box(farm, "HayBaleTwo", Vector3(-5.3, 0.65, -8.0), Vector3(1.8, 1.3, 1.5), Color(0.88, 0.69, 0.31))

	var soil := Color(0.32, 0.23, 0.14)
	var leaf := Color(0.24, 0.55, 0.2)
	for row in range(6):
		var x := 7.0 + float(row) * 1.4
		_add_box(farm, "CropBed%d" % row, Vector3(x, 0.08, 0.0), Vector3(0.9, 0.16, 25.0), soil)
		for crop in range(12):
			var z := -11.0 + float(crop) * 2.0
			_add_box(farm, "Crop%d_%d" % [row, crop], Vector3(x, 0.65, z), Vector3(0.32, 1.1, 0.32), leaf)
			_add_box(farm, "CropLeaf%d_%d" % [row, crop], Vector3(x + 0.18, 0.85, z), Vector3(0.62, 0.16, 0.16), Color(0.36, 0.7, 0.27))

	_build_fence(farm, Vector3(-20, 0, -20), Vector3(20, 0, 20), 10)
	_add_tree(farm, Vector3(-20.0, 0.0, 12.0))
	_add_tree(farm, Vector3(-17.0, 0.0, 16.0))
	_add_tree(farm, Vector3(20.0, 0.0, -16.0))
	_add_box(farm, "FarmTable", Vector3(0.0, 1.0, 4.0), Vector3(3.0, 0.2, 1.4), Color(0.43, 0.25, 0.13))
	_add_box(farm, "FarmBenchLeft", Vector3(-2.2, 0.55, 4.0), Vector3(2.6, 0.2, 0.55), Color(0.42, 0.26, 0.15))
	_add_box(farm, "FarmBenchRight", Vector3(2.2, 0.55, 4.0), Vector3(2.6, 0.2, 0.55), Color(0.42, 0.26, 0.15))


func _build_fence(parent: Node3D, first: Vector3, last: Vector3, sections: int) -> void:
	for index in range(sections + 1):
		var ratio := float(index) / float(sections)
		var x := lerpf(first.x, last.x, ratio)
		var z := lerpf(first.z, last.z, ratio)
		_add_box(parent, "FencePostNorth%d" % index, Vector3(x, 0.7, first.z), Vector3(0.22, 1.4, 0.22), Color(0.38, 0.23, 0.12))
		_add_box(parent, "FencePostSouth%d" % index, Vector3(x, 0.7, last.z), Vector3(0.22, 1.4, 0.22), Color(0.38, 0.23, 0.12))
		_add_box(parent, "FencePostWest%d" % index, Vector3(first.x, 0.7, z), Vector3(0.22, 1.4, 0.22), Color(0.38, 0.23, 0.12))
		_add_box(parent, "FencePostEast%d" % index, Vector3(last.x, 0.7, z), Vector3(0.22, 1.4, 0.22), Color(0.38, 0.23, 0.12))
		if index < sections:
			var next_x := lerpf(first.x, last.x, float(index + 1) / float(sections))
			var next_z := lerpf(first.z, last.z, float(index + 1) / float(sections))
			var width := absf(next_x - x)
			var depth := absf(next_z - z)
			for rail_y in [0.45, 1.0]:
				_add_box(parent, "FenceRailNorth%d_%s" % [index, rail_y], Vector3((x + next_x) * 0.5, rail_y, first.z), Vector3(width, 0.14, 0.14), Color(0.49, 0.31, 0.16))
				_add_box(parent, "FenceRailSouth%d_%s" % [index, rail_y], Vector3((x + next_x) * 0.5, rail_y, last.z), Vector3(width, 0.14, 0.14), Color(0.49, 0.31, 0.16))
				_add_box(parent, "FenceRailWest%d_%s" % [index, rail_y], Vector3(first.x, rail_y, (z + next_z) * 0.5), Vector3(0.14, 0.14, depth), Color(0.49, 0.31, 0.16))
				_add_box(parent, "FenceRailEast%d_%s" % [index, rail_y], Vector3(last.x, rail_y, (z + next_z) * 0.5), Vector3(0.14, 0.14, depth), Color(0.49, 0.31, 0.16))


func _add_tree(parent: Node3D, position: Vector3) -> void:
	var trunk := MeshInstance3D.new()
	trunk.position = position + Vector3(0, 1.5, 0)
	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.35
	trunk_mesh.bottom_radius = 0.5
	trunk_mesh.height = 3.0
	trunk.mesh = trunk_mesh
	trunk.material_override = _material(Color(0.35, 0.2, 0.11))
	parent.add_child(trunk)

	var crown := MeshInstance3D.new()
	crown.position = position + Vector3(0, 4.2, 0)
	var crown_mesh := SphereMesh.new()
	crown_mesh.radius = 2.3
	crown_mesh.height = 4.0
	crown.mesh = crown_mesh
	crown.material_override = _material(Color(0.25, 0.47, 0.19))
	parent.add_child(crown)


func _add_box(parent: Node3D, node_name: String, position: Vector3, size: Vector3, color: Color, rotation := Vector3.ZERO) -> void:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.position = position
	instance.rotation = rotation
	var box := BoxMesh.new()
	box.size = size
	instance.mesh = box
	instance.material_override = _material(color)
	parent.add_child(instance)


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.92
	return material
