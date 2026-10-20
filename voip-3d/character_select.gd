extends Control

@onready var preview_root: Node3D = $Panel/Margin/VBox/Preview/Viewport/World/PreviewRoot
@onready var selected_label: Label = $Panel/Margin/VBox/SelectedLabel
@onready var status_label: Label = $Panel/Margin/VBox/StatusLabel
@onready var continue_button: Button = $Panel/Margin/VBox/ContinueButton

var selected_avatar := AvatarCatalog.MAN
var preview_model: Node3D
var avatar_buttons: Dictionary = {}


func _ready() -> void:
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
	selected_avatar = MatrixClient.selected_avatar_id()
	_select_avatar(selected_avatar)


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
	status_label.text = "The model preview is rotating. Your selection is saved to your account."
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
		status_label.text = "Could not save character selection. Check your device storage."
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
	var result := NetJoin.create_client(
		String(room.get("host", "")),
		int(room.get("port", 0)),
		MatchManager.TEAM_AUTO,
		MatchManager.ROLE_PLAYER,
		MatrixClient.local_username(),
		MatchManager.MODE_OVERLAND,
		NetJoin.TRANSPORT_WEBSOCKET,
		String(room.get("token", ""))
	)
	if not result.get("ok", false):
		status_label.text = "Could not connect to the open-world server: %s" % String(result.get("message", ""))
		continue_button.disabled = false
