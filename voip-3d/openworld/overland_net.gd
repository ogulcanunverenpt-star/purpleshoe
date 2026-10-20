class_name OverlandNet extends Node
## Multiplayer presence for the Overland hub. Works over both ENet (UDP) and WebSocket peers:
## every client broadcasts its position a few times per second and the others render it as an avatar.
## A dedicated (headless) server only relays these packets and cleans up the roster on disconnect.

const SEND_INTERVAL := 0.05
const FOLLOW_SPEED := 12.0
const CAR_PATH := "res://openworld/models/lamborghini_centenario_lp770_interior_sdc.glb"
const MENU_SCENE := "res://lobby.tscn"
const FOOTBALL_MODEL_UTILS := preload("res://football_model_utils.gd")
const MAX_VOICE_PACKET_BYTES := 8192

var main: Node3D
var voice: OverlandVoice
var remotes: Dictionary = {}
var _send_timer := 0.0


func _ready() -> void:
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	MatchManager.roster_changed.connect(_refresh_names)


func setup(main_node: Node3D) -> void:
	main = main_node
	voice = OverlandVoice.new()
	voice.name = "OverlandVoice"
	add_child(voice)
	voice.voice_packet_ready.connect(_on_voice_packet_ready)


func set_ptt_active(active: bool) -> void:
	if voice != null:
		voice.set_ptt_active(active)


func is_online() -> bool:
	var peer := multiplayer.multiplayer_peer
	return peer != null and not (peer is OfflineMultiplayerPeer) \
		and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func player_count() -> int:
	if not is_online():
		return 1
	return maxi(1, remotes.size() + 1)


func _process(delta: float) -> void:
	if main == null or not is_online() or main.player == null:
		return
	_send_timer += delta
	if _send_timer >= SEND_INTERVAL:
		_send_timer = 0.0
		var moving: bool = main.player.velocity.length() > 0.5
		var jumping: bool = not main.player.is_on_floor()
		sync_state.rpc(
			main.player.global_position,
			main.player.rotation.y,
			moving,
			jumping,
			main.driving,
			MatrixClient.selected_avatar_id()
		)
	for id in remotes:
		_follow(remotes[id], delta)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func sync_state(position: Vector3, yaw: float, moving: bool, jumping: bool, in_car: bool, avatar_id: String) -> void:
	if main == null:
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = multiplayer.get_unique_id()
	if multiplayer.is_server():
		if not MatchManager.roster.has(id):
			return
		relay_sync_state.rpc(id, position, yaw, moving, jumping, in_car, avatar_id)
		return
	_update_remote_entry(id, position, yaw, moving, jumping, in_car, avatar_id)


@rpc("authority", "call_remote", "unreliable_ordered")
func relay_sync_state(id: int, position: Vector3, yaw: float, moving: bool, jumping: bool, in_car: bool, avatar_id: String) -> void:
	if main == null or id == multiplayer.get_unique_id():
		return
	_update_remote_entry(id, position, yaw, moving, jumping, in_car, avatar_id)


func _update_remote_entry(
	id: int,
	position: Vector3,
	yaw: float,
	moving: bool,
	jumping: bool,
	in_car: bool,
	avatar_id: String
) -> void:
	var entry: Dictionary = remotes.get(id, {})
	if entry.is_empty():
		entry = _create_remote(id, avatar_id)
		entry.node.global_position = position
		remotes[id] = entry
	elif entry.avatar_id != avatar_id:
		_replace_remote_avatar(entry, avatar_id)
	entry.target = position
	entry.yaw = yaw
	entry.moving = moving
	entry.jumping = jumping
	entry.in_car = in_car


func _on_voice_packet_ready(data: PackedByteArray) -> void:
	if not is_online() or data.is_empty() or data.size() > MAX_VOICE_PACKET_BYTES or data.size() % 2 != 0:
		return
	if multiplayer.is_server():
		var sender_id := multiplayer.get_unique_id()
		if MatchManager.roster.has(sender_id):
			_broadcast_voice_packet(sender_id, data)
	else:
		request_voice_relay.rpc_id(1, data)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func request_voice_relay(data: PackedByteArray) -> void:
	if not multiplayer.is_server() or data.is_empty() or data.size() > MAX_VOICE_PACKET_BYTES or data.size() % 2 != 0:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id == 0 or not MatchManager.roster.has(sender_id):
		return
	_broadcast_voice_packet(sender_id, data)


func _broadcast_voice_packet(sender_id: int, data: PackedByteArray) -> void:
	for peer_id in multiplayer.get_peers():
		if peer_id != sender_id:
			relay_voice_packet.rpc_id(peer_id, sender_id, data)


@rpc("authority", "call_remote", "unreliable_ordered")
func relay_voice_packet(sender_id: int, data: PackedByteArray) -> void:
	if multiplayer.is_server() or voice == null:
		return
	voice.queue_voice_packet(sender_id, data)


func _create_remote(id: int, avatar_id: String) -> Dictionary:
	var root := Node3D.new()
	root.name = "Remote_%d" % id
	main.add_child(root)
	if voice != null:
		voice.attach_remote(id, root)

	var entry := {"node": root, "target": Vector3.ZERO, "yaw": 0.0, "moving": false, "jumping": false, "in_car": false,
		"anim": null, "avatar": null, "avatar_id": "", "car": null, "label": null, "current": "",
		"animator": null, "clip_idle": "", "clip_run": ""}
	_replace_remote_avatar(entry, avatar_id)

	var car: Node3D = _instance(CAR_PATH)
	if car == null:
		push_error("Could not create remote Overland Lamborghini: %s" % CAR_PATH)
	else:
		root.add_child(car)
		main._configure_car_model(car)
		car.visible = false
		entry.car = car

	var label := Label3D.new()
	label.text = MatchManager.username_for_peer(id)
	label.font_size = 48
	label.pixel_size = 0.007
	label.outline_size = 10
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position.y = 2.3
	root.add_child(label)
	entry.label = label
	return entry


func _replace_remote_avatar(entry: Dictionary, avatar_id: String) -> void:
	entry.avatar_id = avatar_id
	if not AvatarCatalog.is_valid_avatar(avatar_id):
		push_warning("Ignoring unknown remote avatar id: %s" % avatar_id)
		_install_fallback_avatar(entry)
		return
	var avatar_scene := AvatarCatalog.scene_for(avatar_id)
	if avatar_scene == null:
		_install_fallback_avatar(entry)
		return
	var avatar := avatar_scene.instantiate() as Node3D
	if avatar == null:
		push_error("Remote avatar did not instantiate: %s" % avatar_id)
		_install_fallback_avatar(entry)
		return
	if avatar_id == AvatarCatalog.MAN and not AvatarCatalog.apply_male_textures(avatar):
		avatar.free()
		_install_fallback_avatar(entry)
		return
	if not AvatarCatalog.fit_model_to_height(avatar, 1.85):
		avatar.free()
		_install_fallback_avatar(entry)
		return
	var root: Node3D = entry.node
	root.add_child(avatar)
	var previous: Node = entry.avatar
	if previous != null and is_instance_valid(previous):
		previous.queue_free()
	entry.avatar = avatar
	var player_anim: AnimationPlayer = main._find_ap(avatar)
	if player_anim == null and AvatarCatalog.supports_shared_human_animations(avatar_id):
		player_anim = AnimationPlayer.new()
		player_anim.name = "OverlandRemoteAnimationPlayer"
		avatar.add_child(player_anim)
	if player_anim != null:
		if AvatarCatalog.supports_shared_human_animations(avatar_id):
			FOOTBALL_MODEL_UTILS.install_human_animations(player_anim, avatar)
		FOOTBALL_MODEL_UTILS.configure_locomotion_loops(player_anim)
		entry.anim = player_anim
		entry.current = ""
		entry.clip_idle = main._pick_clip(player_anim, ["idle", "stand"])
		entry.clip_run = main._pick_clip(player_anim, ["run", "jog", "sprint"])
		if entry.clip_run.is_empty():
			entry.clip_run = main._pick_clip(player_anim, ["walk"])
	else:
		entry.anim = null
		entry.clip_idle = ""
		entry.clip_run = ""


func _install_fallback_avatar(entry: Dictionary) -> void:
	var avatar := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.7
	avatar.mesh = capsule
	avatar.position.y = 0.9
	var root: Node3D = entry.node
	root.add_child(avatar)
	var previous: Node = entry.avatar
	if previous != null and is_instance_valid(previous):
		previous.queue_free()
	entry.avatar = avatar
	entry.anim = null
	entry.clip_idle = ""
	entry.clip_run = ""


func _instance(path: String) -> Node3D:
	if not ResourceLoader.exists(path):
		return null
	var packed = load(path)
	return (packed as PackedScene).instantiate() as Node3D if packed is PackedScene else null


func _follow(entry: Dictionary, delta: float) -> void:
	var node: Node3D = entry.node
	var weight := clampf(delta * FOLLOW_SPEED, 0.0, 1.0)
	node.global_position = node.global_position.lerp(entry.target, weight)
	node.rotation.y = lerp_angle(node.rotation.y, entry.yaw, weight)
	var in_car: bool = entry.in_car
	if entry.avatar != null:
		entry.avatar.visible = not in_car or entry.car == null
	if entry.car != null:
		entry.car.visible = in_car
	var player_anim: AnimationPlayer = entry.anim
	if player_anim != null and not in_car:
		var want := String(entry.clip_run) if entry.moving else String(entry.clip_idle)
		if entry.jumping:
			want = main._pick_clip(player_anim, ["jump"])
		if not want.is_empty() and entry.current != want and player_anim.has_animation(want):
			player_anim.play(want)
			entry.current = want


func _refresh_names() -> void:
	for id in remotes:
		var label: Label3D = remotes[id].label
		if label != null:
			label.text = MatchManager.username_for_peer(id)


func _on_peer_disconnected(id: int) -> void:
	if voice != null:
		voice.remove_remote(id)
	if remotes.has(id):
		var node: Node = remotes[id].node
		if is_instance_valid(node):
			node.queue_free()
		remotes.erase(id)
	if multiplayer.is_server():
		MatchManager.release_player(id)


func _on_server_disconnected() -> void:
	if main == null:
		return
	MatchManager.last_rejection = "The server connection was lost."
	MatchManager.disconnect_client()
	get_tree().change_scene_to_file.call_deferred(MENU_SCENE)
