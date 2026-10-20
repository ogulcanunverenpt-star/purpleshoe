extends Node

@onready var auth_panel: Control = $CanvasLayer/Control/AuthPanel
@onready var login_username_edit: LineEdit = $CanvasLayer/Control/AuthPanel/VBox/UsernameEdit
@onready var login_password_edit: LineEdit = $CanvasLayer/Control/AuthPanel/VBox/PasswordEdit
@onready var auth_status_label: Label = $CanvasLayer/Control/AuthPanel/VBox/AuthStatusLabel
@onready var login_btn: Button = $CanvasLayer/Control/AuthPanel/VBox/LoginBtn
@onready var register_btn: Button = $CanvasLayer/Control/AuthPanel/VBox/RegisterBtn

@onready var main_panel: Control = $CanvasLayer/Control/MainPanel
@onready var user_info_label: Label = $CanvasLayer/Control/MainPanel/Header/UserInfoLabel
@onready var return_to_game_btn: Button = $CanvasLayer/Control/MainPanel/Header/ReturnToGameBtn
@onready var logout_btn: Button = $CanvasLayer/Control/MainPanel/Header/LogoutBtn

# Tabs
@onready var friends_tab: Control = $CanvasLayer/Control/MainPanel/TabContainer/Friends
@onready var create_room_tab: Control = $CanvasLayer/Control/MainPanel/TabContainer/CreateRoom

# Friends UI
@onready var friends_list_container: VBoxContainer = $CanvasLayer/Control/MainPanel/TabContainer/Friends/HBox/LeftVBox/FriendsScroll/FriendsVBox
@onready var online_users_vbox: VBoxContainer = $CanvasLayer/Control/MainPanel/TabContainer/Friends/HBox/LeftVBox/OnlineUsersScroll/OnlineUsersVBox
@onready var pending_requests_vbox: VBoxContainer = $CanvasLayer/Control/MainPanel/TabContainer/Friends/HBox/LeftVBox/PendingVBox
@onready var search_input: LineEdit = $CanvasLayer/Control/MainPanel/TabContainer/Friends/HBox/LeftVBox/SearchHBox/SearchInput
@onready var search_btn: Button = $CanvasLayer/Control/MainPanel/TabContainer/Friends/HBox/LeftVBox/SearchHBox/SearchBtn
@onready var search_results_vbox: VBoxContainer = $CanvasLayer/Control/MainPanel/TabContainer/Friends/HBox/LeftVBox/SearchResultsVBox

# Chat UI
@onready var chat_friend_label: Label = $CanvasLayer/Control/MainPanel/TabContainer/Friends/HBox/ChatVBox/FriendTitleLabel
@onready var chat_text_edit: TextEdit = $CanvasLayer/Control/MainPanel/TabContainer/Friends/HBox/ChatVBox/ChatHistory
@onready var chat_input: LineEdit = $CanvasLayer/Control/MainPanel/TabContainer/Friends/HBox/ChatVBox/InputHBox/ChatInput
@onready var chat_send_btn: Button = $CanvasLayer/Control/MainPanel/TabContainer/Friends/HBox/ChatVBox/InputHBox/SendBtn

# Create Room UI
@onready var mode_option: OptionButton = $CanvasLayer/Control/MainPanel/TabContainer/CreateRoom/VBox/ModeOption
@onready var duration_option: OptionButton = $CanvasLayer/Control/MainPanel/TabContainer/CreateRoom/VBox/DurationOption
@onready var friends_checkboxes_vbox: VBoxContainer = $CanvasLayer/Control/MainPanel/TabContainer/CreateRoom/VBox/FriendsScroll/CheckboxesVBox
@onready var request_room_btn: Button = $CanvasLayer/Control/MainPanel/TabContainer/CreateRoom/VBox/RequestRoomBtn
@onready var room_status_label: Label = $CanvasLayer/Control/MainPanel/TabContainer/CreateRoom/VBox/RoomStatusLabel

# Modal Invites
@onready var invite_modal: Window = $CanvasLayer/Control/InviteModal
@onready var invite_modal_label: Label = $CanvasLayer/Control/InviteModal/VBox/InviteLabel
@onready var accept_invite_btn: Button = $CanvasLayer/Control/InviteModal/VBox/HBox/AcceptBtn
@onready var decline_invite_btn: Button = $CanvasLayer/Control/InviteModal/VBox/HBox/DeclineBtn

# Role / Team Selection Modal
@onready var role_modal: Window = $CanvasLayer/Control/RoleModal
@onready var role_modal_title: Label = $CanvasLayer/Control/RoleModal/VBox/TitleLabel
@onready var role_option_btn: OptionButton = $CanvasLayer/Control/RoleModal/VBox/RoleOption
@onready var team_option_btn: OptionButton = $CanvasLayer/Control/RoleModal/VBox/TeamOption
@onready var join_room_btn: Button = $CanvasLayer/Control/RoleModal/VBox/JoinRoomBtn

var active_chat_friend := ""
var current_pending_invite: Dictionary = {}
var selected_invitees: Dictionary = {}  # friend_id -> bool (persistent selection)
var pending_room_invites: Array = []
var top_banner: PanelContainer = null


func _ready() -> void:
	if _check_cmdline_args():
		return # Server mode started from CLI, scene changed

	_apply_large_theme($CanvasLayer/Control)
	_setup_top_banner()

	_setup_ui_options()
	_connect_matrix_signals()
	return_to_game_btn.visible = MatrixClient.open_lobby_from_game

	auth_panel.visible = true
	main_panel.visible = false
	invite_modal.visible = false
	role_modal.visible = false

	if MatrixClient.is_logged_in():
		_on_logged_in(MatrixClient.user_id)
	else:
		auth_status_label.text = "Log in or register."

	if not MatchManager.last_rejection.is_empty():
		auth_status_label.text = MatchManager.last_rejection
		MatchManager.last_rejection = ""


func _apply_large_theme(node: Node) -> void:
	if node is Control:
		node.add_theme_font_size_override("font_size", 26)

		if node is Button:
			node.custom_minimum_size.y = maxf(node.custom_minimum_size.y, 64.0)
			node.add_theme_font_size_override("font_size", 26)
		elif node is LineEdit:
			node.custom_minimum_size.y = maxf(node.custom_minimum_size.y, 60.0)
			node.add_theme_font_size_override("font_size", 26)
		elif node is OptionButton:
			node.custom_minimum_size.y = maxf(node.custom_minimum_size.y, 60.0)
			node.add_theme_font_size_override("font_size", 26)
		elif node is CheckBox:
			node.custom_minimum_size.y = maxf(node.custom_minimum_size.y, 56.0)
			node.add_theme_font_size_override("font_size", 26)
		elif node is Label:
			node.add_theme_font_size_override("font_size", 24)
		elif node is TextEdit:
			node.add_theme_font_size_override("font_size", 24)
		elif node is TabContainer:
			node.add_theme_font_size_override("font_size", 28)

	for child in node.get_children():
		_apply_large_theme(child)


func _check_cmdline_args() -> bool:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = OS.get_cmdline_args()

	var is_server := false
	var port := 12806
	var mode_id := MatchManager.MODE_FREE_KICK
	var minutes := 10
	var transport_id := NetJoin.TRANSPORT_WEBSOCKET
	var room_tokens: Array = []

	var i := 0
	while i < args.size():
		var arg := String(args[i])
		if arg == "--server":
			is_server = true
		elif arg == "--port" and i + 1 < args.size():
			port = int(args[i + 1])
			i += 1
		elif arg.begins_with("--port="):
			port = int(arg.substr(7))
		elif arg == "--mode" and i + 1 < args.size():
			mode_id = NetJoin.parse_mode(args[i + 1])
			i += 1
		elif arg.begins_with("--mode="):
			mode_id = NetJoin.parse_mode(arg.substr(7))
		elif arg == "--minutes" and i + 1 < args.size():
			minutes = int(args[i + 1])
			i += 1
		elif arg.begins_with("--minutes="):
			minutes = int(arg.substr(10))
		elif arg == "--tokens" and i + 1 < args.size():
			room_tokens = Array(args[i + 1].split(","))
			i += 1
		elif arg.begins_with("--tokens="):
			room_tokens = Array(arg.substr(9).split(","))
		i += 1

	if is_server:
		print("[CLI] Headless/Server mode starting on port %d, mode %d..." % [port, mode_id])
		var res := NetJoin.create_server(port, MatchManager.TEAM_AUTO, MatchManager.ROLE_PLAYER, "DedicatedServer", minutes, mode_id, transport_id, room_tokens, "", "", false)
		if res.get("ok", false):
			get_tree().change_scene_to_file.call_deferred(NetJoin.game_scene_for(mode_id))
			return true
		else:
			push_error("Failed to start headless server: %s" % res.get("message", ""))
	return false


func _setup_ui_options() -> void:
	var tabs: TabContainer = $CanvasLayer/Control/MainPanel/TabContainer
	if tabs.get_tab_count() >= 3:
		tabs.set_tab_title(0, "Friends")
		tabs.set_tab_title(1, "Create Room")
		tabs.set_tab_title(2, "Openworld")

	# Modes
	mode_option.clear()
	mode_option.add_item("Free Kick (2 Players)", MatchManager.MODE_FREE_KICK)
	mode_option.add_item("Match (11v11; 2 team captains)", MatchManager.MODE_MATCH)
	mode_option.add_item("Sesli Konferans", MatchManager.MODE_CONFERENCE)
	mode_option.add_item("Open World", MatchManager.MODE_OVERLAND)
	mode_option.select(0)

	# Durations
	duration_option.clear()
	for m in range(5, 91, 5):
		duration_option.add_item("%d Dakika" % m, m)
	duration_option.select(0)
	room_status_label.text = "Choose a game mode and friends. Invites remain available even if your friends return to the lobby."

	# Role Modal Options
	role_option_btn.clear()
	role_option_btn.add_item("Field Player / Striker", MatchManager.ROLE_PLAYER)
	role_option_btn.add_item("Goalkeeper", MatchManager.ROLE_GOALKEEPER)
	role_option_btn.select(0)

	team_option_btn.clear()
	team_option_btn.add_item("Auto Team", MatchManager.TEAM_AUTO)
	team_option_btn.add_item("Blue Team", MatchManager.TEAM_BLUE)
	team_option_btn.add_item("Red Team", MatchManager.TEAM_RED)
	team_option_btn.select(0)


func _connect_matrix_signals() -> void:
	MatrixClient.logged_in.connect(_on_logged_in)
	MatrixClient.login_failed.connect(_on_login_failed)
	MatrixClient.matrix_auth_completed.connect(_on_matrix_auth_completed)
	MatrixClient.friends_updated.connect(_refresh_friends_ui)
	MatrixClient.friend_request_received.connect(_on_friend_request_received)
	MatrixClient.friend_accepted.connect(func(_uid): _refresh_friends_ui())
	MatrixClient.chat_message_received.connect(_on_chat_message_received)
	MatrixClient.room_invite_received.connect(_on_room_invite_received)
	MatrixClient.presence_updated.connect(_refresh_online_users_ui)


# ---------------- Auth Handlers ----------------

func _on_login_btn_pressed() -> void:
	var u := login_username_edit.text.strip_edges()
	var p := login_password_edit.text
	if u.is_empty() or p.is_empty():
		auth_status_label.text = "Username and password are required."
		return
	AudioManager.unlock()
	auth_status_label.text = "Logging in..."
	MatrixClient.login(u, p)


func _on_register_btn_pressed() -> void:
	var u := login_username_edit.text.strip_edges()
	var p := login_password_edit.text
	if u.is_empty() or p.is_empty():
		auth_status_label.text = "Username and password are required."
		return
	AudioManager.unlock()
	auth_status_label.text = "Registering..."
	MatrixClient.register(u, p)


func _on_logout_btn_pressed() -> void:
	MatrixClient.logout()
	MatrixClient.open_lobby_from_game = false
	return_to_game_btn.visible = false
	auth_panel.visible = true
	main_panel.visible = false
	auth_status_label.text = "Logged out."


func _on_logged_in(user_id: String) -> void:
	auth_panel.visible = false
	if MatrixClient.open_lobby_from_game:
		main_panel.visible = true
		user_info_label.text = "User: " + user_id
		return_to_game_btn.visible = true
		_refresh_friends_ui()
		_refresh_online_users_ui()
		for invite in MatrixClient.pending_room_invites():
			_add_pending_room_invite(String(invite.get("from", "")), invite)
		return
	auth_status_label.text = "Opening character selection..."
	print("[Lobby] Auth successful for ", user_id, ". Loading character selection...")
	get_tree().change_scene_to_file.call_deferred("res://character_select.tscn")


func _on_return_to_game_btn_pressed() -> void:
	MatrixClient.open_lobby_from_game = false
	if NetJoin.has_return_to_game():
		var result := NetJoin.return_to_game()
		if result.get("ok", false):
			return
		MatrixClient.open_lobby_from_game = true
		room_status_label.text = "Could not return to the game: " + String(result.get("message", "Could not connect to the server."))
		return
	get_tree().change_scene_to_file("res://Scenes/Demo.tscn")


func _on_login_failed(reason: String) -> void:
	auth_status_label.text = "Login Error: " + reason


func _on_matrix_auth_completed(success: bool, message: String) -> void:
	if success:
		return
	if MatrixClient.open_lobby_from_game:
		room_status_label.text = message
	else:
		auth_status_label.text = message


# ---------------- Friends & Search UI ----------------

func _refresh_friends_ui() -> void:
	# Save current checked state before clearing
	for cb in friends_checkboxes_vbox.get_children():
		if cb is CheckBox:
			var uid: String = str(cb.get_meta("user_id", cb.text)).strip_edges()
			if uid != "":
				selected_invitees[uid] = cb.button_pressed

	for c in friends_list_container.get_children():
		c.queue_free()
	for c in friends_checkboxes_vbox.get_children():
		c.queue_free()

	var friends := MatrixClient.friends_list()
	if friends.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "You have no friends yet."
		empty_lbl.add_theme_font_size_override("font_size", 24)
		friends_list_container.add_child(empty_lbl)

	for friend_id in friends:
		var btn := Button.new()
		btn.text = ("● " if MatrixClient.is_user_online(friend_id) else "○ ") + friend_id
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.custom_minimum_size.y = 60.0
		btn.add_theme_font_size_override("font_size", 26)
		btn.pressed.connect(func(): _open_chat_with(friend_id))
		friends_list_container.add_child(btn)

		var cb := CheckBox.new()
		cb.text = " " + friend_id
		cb.name = friend_id
		cb.set_meta("user_id", friend_id)
		cb.custom_minimum_size.y = 56.0
		cb.add_theme_font_size_override("font_size", 26)

		if selected_invitees.get(friend_id, false):
			cb.button_pressed = true

		cb.toggled.connect(func(pressed: bool):
			selected_invitees[friend_id] = pressed
		)
		friends_checkboxes_vbox.add_child(cb)

	_refresh_pending_requests()
	_refresh_online_users_ui()


func _refresh_online_users_ui() -> void:
	for child in online_users_vbox.get_children():
		child.queue_free()

	var online: Array[String] = []
	for username in MatrixClient.online_users():
		if username != MatrixClient.user_id:
			online.append(username)
	if online.is_empty():
		var empty_label := Label.new()
		empty_label.text = "No other users are online right now."
		online_users_vbox.add_child(empty_label)
		return

	for username in online:
		var row := HBoxContainer.new()
		var name_label := Label.new()
		name_label.text = "● " + username
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)

		var action_button := Button.new()
		action_button.custom_minimum_size = Vector2(150, 48)
		if MatrixClient.friends_list().has(username):
			action_button.text = "Chat"
			action_button.pressed.connect(func(): _open_chat_with(username))
		else:
			action_button.text = "Add Friend"
			action_button.pressed.connect(_send_online_friend_request.bind(username, action_button))
		row.add_child(action_button)
		online_users_vbox.add_child(row)


func _send_online_friend_request(username: String, button: Button) -> void:
	button.disabled = true
	button.text = "Sending request..."
	var result := await MatrixClient.send_friend_request(username)
	if result.get("success", false):
		button.text = "Request sent"
	else:
		button.disabled = false
		button.text = "Add Friend"
		room_status_label.text = "Could not send friend request: " + String(result.get("error", "The server did not respond."))


func _refresh_pending_requests() -> void:
	for c in pending_requests_vbox.get_children():
		c.queue_free()

	for req_user_id in MatrixClient.pending_friend_requests:
		var hbox := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = req_user_id
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_font_size_override("font_size", 24)
		hbox.add_child(lbl)

		var accept_b := Button.new()
		accept_b.text = "Kabul"
		accept_b.custom_minimum_size = Vector2(120, 52)
		accept_b.add_theme_font_size_override("font_size", 24)
		accept_b.pressed.connect(func(): MatrixClient.respond_friend_request(req_user_id, true))
		hbox.add_child(accept_b)

		var decline_b := Button.new()
		decline_b.text = "Red"
		decline_b.custom_minimum_size = Vector2(120, 52)
		decline_b.add_theme_font_size_override("font_size", 24)
		decline_b.pressed.connect(func(): MatrixClient.respond_friend_request(req_user_id, false))
		hbox.add_child(decline_b)

		pending_requests_vbox.add_child(hbox)

	# Room Invites in Pending Requests
	for inv in pending_room_invites:
		var from_u: String = inv.get("from", "Biri")
		var p: Dictionary = inv.get("payload", {})
		var hbox := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = "[Room Invitation] " + from_u
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_font_size_override("font_size", 22)
		hbox.add_child(lbl)

		var accept_b := Button.new()
		accept_b.text = "Join"
		accept_b.custom_minimum_size = Vector2(110, 48)
		accept_b.add_theme_font_size_override("font_size", 22)
		accept_b.pressed.connect(func():
			current_pending_invite = p
			_prepare_role_modal_for_mode(str(p.get("mode", "free_kick")))
			role_modal.popup_centered()
		)
		hbox.add_child(accept_b)

		var decline_b := Button.new()
		decline_b.text = "Remove"
		decline_b.custom_minimum_size = Vector2(90, 48)
		decline_b.add_theme_font_size_override("font_size", 22)
		decline_b.pressed.connect(_decline_room_invite.bind(p))
		hbox.add_child(decline_b)

		pending_requests_vbox.add_child(hbox)


func _on_search_btn_pressed() -> void:
	var term := search_input.text.strip_edges()
	if term.is_empty():
		return
	for c in search_results_vbox.get_children():
		c.queue_free()

	var results = await MatrixClient.search_users(term)
	for res in results:
		var uid: String = res.get("username", res.get("user_id", ""))
		if uid.is_empty() or uid == MatrixClient.user_id:
			continue
		var hbox := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = ("● " if bool(res.get("online", false)) else "○ ") + uid
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_font_size_override("font_size", 24)
		hbox.add_child(lbl)

		var add_b := Button.new()
		var already_friend := MatrixClient.friends_list().has(uid)
		add_b.text = "Friend" if already_friend else "Add"
		add_b.disabled = already_friend
		add_b.custom_minimum_size = Vector2(120, 52)
		add_b.add_theme_font_size_override("font_size", 24)
		if not already_friend:
			add_b.pressed.connect(_send_online_friend_request.bind(uid, add_b))
		hbox.add_child(add_b)
		search_results_vbox.add_child(hbox)


func _on_friend_request_received(_from_user_id: String, _display_name: String) -> void:
	_refresh_pending_requests()


# ---------------- Chat UI ----------------

func _open_chat_with(friend_id: String) -> void:
	active_chat_friend = friend_id
	chat_friend_label.text = "Chat: " + friend_id
	_render_chat_history(MatrixClient.chat_history_for(friend_id))
	var history := await MatrixClient.fetch_chat_history(friend_id)
	if active_chat_friend == friend_id:
		_render_chat_history(history)


func _render_chat_history(messages: Array[Dictionary]) -> void:
	var lines: PackedStringArray = []
	for message in messages:
		var prefix := "Ben: " if bool(message.get("outgoing", false)) else (active_chat_friend + ": ")
		lines.append(prefix + String(message.get("body", "")))
	chat_text_edit.text = "\n".join(lines)
	chat_text_edit.scroll_vertical = chat_text_edit.get_line_count()


func _on_chat_send_btn_pressed() -> void:
	var msg := chat_input.text.strip_edges()
	if msg.is_empty() or active_chat_friend.is_empty():
		return
	chat_input.text = ""
	MatrixClient.send_chat(active_chat_friend, msg)


func _on_chat_message_received(other_user_id: String, body: String, local_echo: bool) -> void:
	if active_chat_friend == other_user_id:
		var prefix := "Ben: " if local_echo else (other_user_id + ": ")
		chat_text_edit.text += prefix + body + "\n"


# ---------------- Create Room / Request ----------------

func _on_request_room_btn_pressed() -> void:
	var selected_mode_id := mode_option.get_selected_id()
	if selected_mode_id == MatchManager.MODE_OVERLAND:
		_connect_to_overland()
		return
	var mode_str := "free_kick"
	match selected_mode_id:
		MatchManager.MODE_FREE_KICK: mode_str = "free_kick"
		MatchManager.MODE_MATCH: mode_str = "match"
		MatchManager.MODE_CONFERENCE: mode_str = "conference"
		MatchManager.MODE_OVERLAND: mode_str = "overland"

	var minutes := duration_option.get_selected_id()
	var invitees: Array = []

	# Get all selected invitees
	for friend_id in selected_invitees:
		if selected_invitees[friend_id] == true and not invitees.has(friend_id):
			invitees.append(friend_id)

	for cb in friends_checkboxes_vbox.get_children():
		if cb is CheckBox and cb.button_pressed:
			var uid := str(cb.get_meta("user_id", cb.text)).strip_edges()
			if not invitees.has(uid):
				invitees.append(uid)

	room_status_label.text = "Creating room on the server..."
	request_room_btn.disabled = true

	var res := await MatrixClient.create_server_room(mode_str, invitees, minutes)
	if res.get("success", false):
		room_status_label.text = "Room created! Connecting..."
		var host: String = String(res.get("host", "192.168.1.9"))
		var port: int = int(res.get("port", 12810))
		var token: String = String(res.get("token", ""))

		await get_tree().create_timer(1.0).timeout
		var join_res := NetJoin.create_client(host, port, MatchManager.TEAM_AUTO, MatchManager.ROLE_PLAYER, MatrixClient.local_username(), selected_mode_id, NetJoin.TRANSPORT_WEBSOCKET, token)
		if not join_res.get("ok", false):
			room_status_label.text = "Connection Error: " + String(join_res.get("message", ""))
			request_room_btn.disabled = false
	else:
		room_status_label.text = "Error: " + str(res.get("error", "Could not create the room."))
		request_room_btn.disabled = false


# ---------------- Overland Direct Entry ----------------

func _on_enter_overland_btn_pressed() -> void:
	_connect_to_overland()


func _connect_to_overland() -> void:
	room_status_label.text = "Connecting to the shared open world..."
	request_room_btn.disabled = true
	var res := await MatrixClient.join_shared_room("overland")
	if not is_inside_tree():
		return
	if not res.get("success", false):
		room_status_label.text = "Could not connect to the open world: %s" % String(res.get("error", "The server did not respond."))
		request_room_btn.disabled = false
		return

	MatchManager.preferred_mode = MatchManager.MODE_OVERLAND
	var join_result := NetJoin.create_client(
		String(res.get("host", "")),
		int(res.get("port", 0)),
		MatchManager.TEAM_AUTO,
		MatchManager.ROLE_PLAYER,
		MatrixClient.local_username(),
		MatchManager.MODE_OVERLAND,
		NetJoin.TRANSPORT_WEBSOCKET,
		String(res.get("token", ""))
	)
	if not join_result.get("ok", false):
		room_status_label.text = "Could not connect to the open-world server: %s" % String(join_result.get("message", ""))
		request_room_btn.disabled = false


# ---------------- Room Invites & One-Click Join ----------------

func _setup_top_banner() -> void:
	top_banner = PanelContainer.new()
	top_banner.name = "TopBannerNotification"
	top_banner.visible = false
	top_banner.anchor_left = 0.05
	top_banner.anchor_right = 0.95
	top_banner.anchor_top = 0.02
	top_banner.offset_bottom = 90

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.65, 0.25, 0.95)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(16)
	top_banner.add_theme_stylebox_override("panel", sb)

	var hbox := HBoxContainer.new()
	hbox.name = "BannerHBox"
	hbox.add_theme_constant_override("separation", 15)

	var lbl := Label.new()
	lbl.name = "BannerLabel"
	lbl.text = ""
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", 24)
	hbox.add_child(lbl)

	var btn := Button.new()
	btn.text = "Join Now"
	btn.custom_minimum_size = Vector2(160, 52)
	btn.add_theme_font_size_override("font_size", 22)
	btn.pressed.connect(func():
		top_banner.visible = false
		_prepare_role_modal_for_mode(str(current_pending_invite.get("mode", "free_kick")))
		role_modal.popup_centered()
	)
	hbox.add_child(btn)

	top_banner.add_child(hbox)
	$CanvasLayer/Control.add_child(top_banner)


func _show_top_invite_banner(text: String) -> void:
	if top_banner == null:
		_setup_top_banner()
	var hbox = top_banner.get_node("BannerHBox")
	var lbl = hbox.get_node("BannerLabel") if hbox else null
	if lbl:
		lbl.text = text
	top_banner.visible = true


func _add_pending_room_invite(from_user: String, payload: Dictionary) -> void:
	var invite_id := String(payload.get("invite_id", ""))
	for existing in pending_room_invites:
		var existing_payload: Dictionary = existing.get("payload", {})
		if invite_id != "" and String(existing_payload.get("invite_id", "")) == invite_id:
			return
	pending_room_invites.append({"from": from_user, "payload": payload})
	_refresh_pending_requests()


func _on_room_invite_received(from_user_id: String, payload: Dictionary) -> void:
	print("[Lobby] Room invite received from ", from_user_id, ": ", payload)
	current_pending_invite = payload
	var mode_name := str(payload.get("mode", "free_kick"))
	var from_disp := str(payload.get("from", from_user_id))

	invite_modal_label.text = " ROOM INVITATION RECEIVED! \n%s invited you to a %s game!" % [from_disp, mode_name.replace("_", " ").capitalize()]
	invite_modal.visible = true
	invite_modal.popup_centered()

	_show_top_invite_banner("%s invited you to a %s room! (Accept)" % [from_disp, mode_name.replace("_", " ").capitalize()])
	_add_pending_room_invite(from_disp, payload)


func _on_accept_invite_pressed() -> void:
	invite_modal.visible = false
	var mode_str := str(current_pending_invite.get("mode", "free_kick"))
	if mode_str == "overland":
		_join_current_invite(MatchManager.ROLE_PLAYER, MatchManager.TEAM_BLUE)
	else:
		_prepare_role_modal_for_mode(mode_str)
		role_modal.popup_centered()

func _prepare_role_modal_for_mode(mode_str: String) -> void:
	var is_match := NetJoin.parse_mode(mode_str) == MatchManager.MODE_MATCH
	role_option_btn.visible = not is_match
	role_modal_title.text = "HUMAN - ROBOT 11v11" if is_match else "%s Role and Team Selection" % mode_str.replace("_", " ").capitalize()
	team_option_btn.set_item_text(0, "Auto Team (HUMAN)" if is_match else "Auto Team")
	team_option_btn.set_item_text(1, "Blue Team (ROBOT - CPU)" if is_match else "Blue Team")
	team_option_btn.set_item_text(2, "Red Team (HUMAN)" if is_match else "Red Team")
	team_option_btn.set_item_disabled(1, is_match)
	if is_match:
		team_option_btn.select(2)
	else:
		team_option_btn.select(0)


func _on_decline_invite_pressed() -> void:
	invite_modal.visible = false
	_decline_room_invite(current_pending_invite)
	current_pending_invite.clear()


func _on_join_room_btn_pressed() -> void:
	role_modal.visible = false
	var selected_role := role_option_btn.get_selected_id()
	var selected_team := team_option_btn.get_selected_id()
	_join_current_invite(selected_role, selected_team)


func _join_current_invite(role: int, team: int) -> void:
	if current_pending_invite.is_empty():
		return

	var invite := current_pending_invite.duplicate(true)
	var invite_id := String(invite.get("invite_id", ""))
	if not invite_id.is_empty():
		var response := await MatrixClient.respond_room_invite(invite_id, true)
		if not response.get("success", false):
			room_status_label.text = "Could not accept invite: " + String(response.get("error", "The server did not respond."))
			return
		_remove_pending_room_invite(invite_id)

	var host: String = str(invite.get("host", "192.168.1.9"))
	var port: int = int(invite.get("port", NetJoin.DEFAULT_PORT))
	var token: String = str(invite.get("token", ""))
	var mode_str: String = str(invite.get("mode", "free_kick"))
	var transport_str: String = str(invite.get("transport", "ws"))

	var mode_id := NetJoin.parse_mode(mode_str)
	var transport_id := NetJoin.parse_transport(transport_str)

	NetJoin.create_client(host, port, team, role, MatrixClient.local_username(), mode_id, transport_id, token)
	if String(current_pending_invite.get("invite_id", "")) == invite_id:
		current_pending_invite.clear()


func _decline_room_invite(invite: Dictionary) -> void:
	var invite_id := String(invite.get("invite_id", ""))
	if invite_id.is_empty():
		return
	var response := await MatrixClient.respond_room_invite(invite_id, false)
	if response.get("success", false):
		_remove_pending_room_invite(invite_id)
	else:
		room_status_label.text = "Could not decline invite: " + String(response.get("error", "The server did not respond."))


func _remove_pending_room_invite(invite_id: String) -> void:
	for index in range(pending_room_invites.size() - 1, -1, -1):
		var item: Dictionary = pending_room_invites[index]
		var payload: Dictionary = item.get("payload", {})
		if String(payload.get("invite_id", "")) == invite_id:
			pending_room_invites.remove_at(index)
	_refresh_pending_requests()
