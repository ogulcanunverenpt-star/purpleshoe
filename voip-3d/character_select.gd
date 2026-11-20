extends Control

const WORLD_JOIN_TIMEOUT_MSEC := 20000

@onready var preview_root: Node3D = $Panel/Margin/VBox/Preview/Viewport/World/PreviewRoot
@onready var selected_label: Label = $Panel/Margin/VBox/SelectedLabel
@onready var status_label: Label = $Panel/Margin/VBox/StatusLabel
@onready var continue_button: Button = $Panel/Margin/VBox/ContinueButton
@onready var preview: SubViewportContainer = $Panel/Margin/VBox/Preview
@onready var choices: GridContainer = $Panel/Margin/VBox/AvatarChoices
@onready var title_label: Label = $Panel/Margin/VBox/Title
@onready var subtitle_label: Label = $Panel/Margin/VBox/Subtitle
@onready var content: VBoxContainer = $Panel/Margin/VBox

var selected_avatar := AvatarCatalog.MAN
var preview_model: Node3D
var avatar_buttons: Dictionary = {}
var joining_world := false


func _ready() -> void:
	MatrixClient.session_expired.connect(_on_session_expired)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	avatar_buttons = {
		AvatarCatalog.MAN: $Panel/Margin/VBox/AvatarChoices/Man,
		AvatarCatalog.JOURNALIST: $Panel/Margin/VBox/AvatarChoices/Journalist,
		AvatarCatalog.GOALKEEPER: $Panel/Margin/VBox/AvatarChoices/Goalkeeper,
		AvatarCatalog.ROBOT: $Panel/Margin/VBox/AvatarChoices/Robot,
	}
	avatar_buttons[AvatarCatalog.MAN].pressed.connect(_select_avatar.bind(AvatarCatalog.MAN))
	avatar_buttons[AvatarCatalog.JOURNALIST].pressed.connect(_select_avatar.bind(AvatarCatalog.JOURNALIST))
	avatar_buttons[AvatarCatalog.GOALKEEPER].pressed.connect(_select_avatar.bind(AvatarCatalog.GOALKEEPER))
	avatar_buttons[AvatarCatalog.ROBOT].pressed.connect(_select_avatar.bind(AvatarCatalog.ROBOT))
	continue_button.pressed.connect(_on_continue_pressed)
	get_viewport().size_changed.connect(_layout_for_screen)
	_layout_for_screen()
	selected_avatar = MatrixClient.selected_avatar_id()
	_select_avatar(selected_avatar)
	if not MatchManager.last_rejection.is_empty():
		status_label.text = MatchManager.last_rejection
		MatchManager.last_rejection = ""


func _layout_for_screen() -> void:
	var size := get_viewport_rect().size
	var compact := size.y < 650.0
	choices.columns = 4 if compact and size.x >= 600.0 else 2
	content.add_theme_constant_override("separation", 4 if compact else 8)
	title_label.add_theme_font_size_override("font_size", 24 if compact else 34)
	subtitle_label.visible = not compact
	preview.custom_minimum_size.y = clampf(size.y * 0.22, 60.0, 140.0) if compact else 320.0
	continue_button.custom_minimum_size.y = 48.0 if compact else 58.0
	for button: Button in avatar_buttons.values():
		button.custom_minimum_size.y = 42.0 if compact else 52.0
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _on_session_expired() -> void:
	get_tree().change_scene_to_file.call_deferred("res://lobby.tscn")

func _exit_tree() -> void:
	if joining_world:
		MatchManager.disconnect_client()

func _on_server_disconnected() -> void:
	if joining_world:
		MatchManager.last_rejection = "The game server disconnected before joining the open world."
		push_warning(MatchManager.last_rejection)
		MatchManager.disconnect_client()


func _process(delta: float) -> void:
	preview_root.rotate_y(delta * 0.65)


func _select_avatar(avatar_id: String) -> void:
	avatar_id = AvatarCatalog.canonical_avatar_id(avatar_id)
	if not AvatarCatalog.is_valid_avatar(avatar_id):
		push_error("Unknown avatar selection: %s" % avatar_id)
		return
	var avatar_scene := AvatarCatalog.scene_for(avatar_id)
	if avatar_scene == null:
		status_label.text = "Could not load this character's model."
		return
	var new_preview := avatar_scene.instantiate() as Node3D
	new_preview.name = "%sPreview" % avatar_id.capitalize()
	preview_root.add_child(new_preview)
	if avatar_id == AvatarCatalog.MAN and not AvatarCatalog.apply_male_textures(new_preview):
		new_preview.queue_free()
		status_label.text = "Could not load the male character's textures."
		return
	if not AvatarCatalog.fit_model_to_height(new_preview, 1.85):
		new_preview.queue_free()
		status_label.text = "This character's model cannot be displayed."
		return
	for skeleton in new_preview.find_children("*", "Skeleton3D", true, false):
		(skeleton as Skeleton3D).reset_bone_poses()
	for player in new_preview.find_children("*", "AnimationPlayer", true, false):
		(player as AnimationPlayer).stop()
	if is_instance_valid(preview_model):
		preview_model.queue_free()
	preview_model = new_preview
	selected_avatar = avatar_id
	selected_label.text = "Selected character: %s" % AvatarCatalog.display_name(avatar_id)
	status_label.text = "The model preview is rotating. Your selection is saved when you continue."
	_update_avatar_buttons()


func _update_avatar_buttons() -> void:
	for avatar_id: String in avatar_buttons:
		var button := avatar_buttons[avatar_id] as Button
		var is_selected := avatar_id == selected_avatar
		button.button_pressed = is_selected
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.34, 0.22, 0.53) if is_selected else Color(0.16, 0.14, 0.22)
		style.border_color = Color(0.78, 0.64, 1.0) if is_selected else Color(0.36, 0.31, 0.45)
		style.set_border_width_all(2 if is_selected else 1)
		style.set_corner_radius_all(10)
		button.add_theme_stylebox_override("normal", style)
		button.add_theme_color_override("font_color", Color.WHITE)


func _on_continue_pressed() -> void:
	if not MatrixClient.save_selected_avatar_id(selected_avatar):
		status_label.text = MatrixClient.avatar_save_error
		return
	continue_button.disabled = true
	status_label.text = "Connecting to the open world..."
	var room := await MatrixClient.join_shared_room("overland")
	if not is_inside_tree():
		return
	if not room.get("success", false):
		status_label.text = "Could not connect to the open world: %s" % String(room.get("error", "The server did not respond."))
		continue_button.disabled = false
		return

	MatchManager.preferred_mode = MatchManager.MODE_OVERLAND
	joining_world = true
	var result := NetJoin.create_client(
		String(room.get("host", "")),
		int(room.get("port", 0)),
		MatchManager.TEAM_AUTO,
		MatchManager.ROLE_PLAYER,
		MatrixClient.local_username(),
		MatchManager.MODE_OVERLAND,
		NetJoin.TRANSPORT_WEBSOCKET,
		String(room.get("token", "")),
		false,
		false
	)
	if not result.get("ok", false):
		joining_world = false
		status_label.text = "Could not connect to the open-world server: %s" % String(result.get("message", ""))
		continue_button.disabled = false
		return

	var error := await _wait_for_world_connection()
	if not is_inside_tree():
		return
	if not error.is_empty():
		MatchManager.disconnect_client()
		joining_world = false
		MatchManager.last_rejection = ""
		status_label.text = "%s (%s:%d)" % [error, String(room.get("host", "")), int(room.get("port", 0))]
		continue_button.disabled = false
		return
	joining_world = false
	var scene_error := get_tree().change_scene_to_file(NetJoin.OVERLAND_SCENE)
	if scene_error != OK:
		MatchManager.disconnect_client()
		status_label.text = "Could not open the world: %s" % error_string(scene_error)
		continue_button.disabled = false


func _wait_for_world_connection() -> String:
	var deadline := Time.get_ticks_msec() + WORLD_JOIN_TIMEOUT_MSEC
	while is_inside_tree() and Time.get_ticks_msec() < deadline:
		if not MatchManager.last_rejection.is_empty():
			return MatchManager.last_rejection
		var peer := multiplayer.multiplayer_peer
		if peer != null and not (peer is OfflineMultiplayerPeer) and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			if MatchManager.roster.has(multiplayer.get_unique_id()):
				return ""
		await get_tree().process_frame
	return "Timed out waiting for the open-world server."
