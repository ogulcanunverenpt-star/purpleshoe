extends Node3D

const DEFAULT_PORT = 12806

@onready var ip_edit: LineEdit = $CanvasLayer/Control/VBoxContainer/IpLineEdit
@onready var port_edit: LineEdit = $CanvasLayer/Control/VBoxContainer/PortLineEdit
@onready var status_label: Label = $CanvasLayer/Control/VBoxContainer/StatusLabel
@onready var username_edit: LineEdit = $CanvasLayer/Control/VBoxContainer/UsernameLineEdit
@onready var game_mode_option: OptionButton = $CanvasLayer/Control/VBoxContainer/GameModeOption
@onready var team_option: OptionButton = $CanvasLayer/Control/VBoxContainer/TeamOption
@onready var role_option: OptionButton = $CanvasLayer/Control/VBoxContainer/RoleOption
@onready var match_duration_option: OptionButton = $CanvasLayer/Control/VBoxContainer/MatchDurationOption
@onready var roster_label: Label = $CanvasLayer/Control/VBoxContainer/RosterLabel
@onready var host_button: Button = $CanvasLayer/Control/VBoxContainer/HostButton

var transport_option: OptionButton

func _ready():
	var preferences = ConfigFile.new()
	preferences.load("user://player.cfg")
	username_edit.text = str(preferences.get_value("player", "username", "Player"))
	_build_transport_option()
	game_mode_option.add_item("Open World", MatchManager.MODE_OVERLAND)
	game_mode_option.add_item("Free Kick", MatchManager.MODE_FREE_KICK)
	game_mode_option.add_item("Match", MatchManager.MODE_MATCH)
	game_mode_option.select(game_mode_option.get_item_index(MatchManager.preferred_mode))
	game_mode_option.item_selected.connect(_on_game_mode_selected)
	team_option.add_item("Auto Team", MatchManager.TEAM_AUTO)
	team_option.add_item("ROBOT Team", MatchManager.TEAM_BLUE)
	team_option.add_item("HUMAN Team", MatchManager.TEAM_RED)
	team_option.select(0)
	role_option.add_item("Starting Role: Striker", MatchManager.ROLE_PLAYER)
	role_option.add_item("Starting Role: Goalkeeper", MatchManager.ROLE_GOALKEEPER)
	role_option.select(0)
	_on_game_mode_selected(game_mode_option.selected)
	for minutes in range(5, 91, 5):
		match_duration_option.add_item("%d dakika" % minutes, minutes)
	match_duration_option.select(0)
	MatchManager.roster_changed.connect(_update_roster_display)
	_update_roster_display()
	if not MatchManager.last_rejection.is_empty():
		status_label.text = MatchManager.last_rejection
		MatchManager.last_rejection = ""
	if OS.get_name() == "Android":
		OS.request_permissions()
	_start_from_command_line()

func _start_from_command_line():
	var arguments = _get_application_arguments()
	var server_mode := false
	var host := ""
	var port := DEFAULT_PORT
	var team := MatchManager.TEAM_AUTO
	var role := MatchManager.ROLE_PLAYER
	var username := "Player"
	var match_minutes := 5
	var selected_mode := MatchManager.MODE_MATCH
	var transport := NetJoin.TRANSPORT_UDP
	var room_tokens: Array = []
	var index := 0

	while index < arguments.size():
		var argument: String = arguments[index]
		if argument == "--server":
			server_mode = true
		elif argument == "--host" or argument == "--port" or argument == "--role" or argument == "--team" or argument == "--username" or argument == "--minutes" or argument == "--mode" or argument == "--transport" or argument == "--tokens":
			if index + 1 >= arguments.size():
				push_error("Missing value for %s" % argument)
				return
			var value: String = arguments[index + 1]
			index += 1
			if argument == "--host":
				host = value
			elif argument == "--role":
				role = _parse_role(value)
				if role < 0:
					push_error("Role must be player or goalkeeper")
					return
			elif argument == "--team":
				team = _parse_team(value)
				if team < 0:
					push_error("Team must be auto, robot, or human (blue/red aliases are also accepted)")
					return
			elif argument == "--username":
				username = value
			elif argument == "--minutes":
				if not value.is_valid_int():
					push_error("Invalid match duration: %s" % value)
					return
				match_minutes = value.to_int()
			elif argument == "--mode":
				selected_mode = _parse_mode(value)
				if selected_mode < 0:
					push_error("Mode must be free_kick, match or overland")
					return
			elif argument == "--transport":
				transport = _parse_transport(value)
				if transport < 0:
					push_error("Transport must be udp or ws")
					return
			elif argument == "--tokens":
				room_tokens = Array(value.split(","))
			else:
				if not value.is_valid_int():
					push_error("Invalid port: %s" % value)
					return
				port = value.to_int()
		elif argument.begins_with("--host="):
			host = argument.substr(7)
		elif argument.begins_with("--port="):
			var port_value = argument.substr(7)
			if not port_value.is_valid_int():
				push_error("Invalid port: %s" % port_value)
				return
			port = port_value.to_int()
		elif argument.begins_with("--role="):
			role = _parse_role(argument.substr(7))
			if role < 0:
				push_error("Role must be player or goalkeeper")
				return
		elif argument.begins_with("--team="):
			team = _parse_team(argument.substr(7))
			if team < 0:
				push_error("Team must be auto, robot, or human (blue/red aliases are also accepted)")
				return
		elif argument.begins_with("--username="):
			username = argument.substr(11)
		elif argument.begins_with("--minutes="):
			var minutes_value = argument.substr(10)
			if not minutes_value.is_valid_int():
				push_error("Invalid match duration: %s" % minutes_value)
				return
			match_minutes = minutes_value.to_int()
		elif argument.begins_with("--mode="):
			selected_mode = _parse_mode(argument.substr(7))
			if selected_mode < 0:
				push_error("Mode must be free_kick, match or overland")
				return
		elif argument.begins_with("--transport="):
			transport = _parse_transport(argument.substr(12))
			if transport < 0:
				push_error("Transport must be udp or ws")
				return
		elif argument.begins_with("--tokens="):
			room_tokens = Array(argument.substr(9).split(","))
		index += 1

	if port < 1 or port > 65535:
		push_error("Port must be between 1 and 65535")
		return
	if selected_mode == MatchManager.MODE_FREE_KICK or selected_mode == MatchManager.MODE_MATCH:
		if match_minutes < 5 or match_minutes > 90 or match_minutes % 5 != 0:
			push_error("Match duration must be between 5 and 90 minutes in 5-minute increments.")
			return
	if server_mode:
		createServer(host, port, team, role, username, match_minutes, selected_mode, transport, room_tokens)
	elif not host.is_empty():
		createClient(host, port, team, role, username, selected_mode, transport)

func _parse_mode(value: String) -> int:
	match value.to_lower():
		"free_kick", "freekick", "serbest-vurus", "serbest_vurus":
			return MatchManager.MODE_FREE_KICK
		"match", "mac":
			return MatchManager.MODE_MATCH
		"overland", "open_world", "acik-dunya", "acik_dunya":
			return MatchManager.MODE_OVERLAND
	return -1

func _parse_transport(value: String) -> int:
	match value.to_lower():
		"ws", "websocket":
			return NetJoin.TRANSPORT_WEBSOCKET
		"udp", "enet":
			return NetJoin.TRANSPORT_UDP
	return -1

func _on_game_mode_selected(index: int):
	var mode := game_mode_option.get_item_id(index)
	var is_match := mode == MatchManager.MODE_MATCH
	var is_overland := mode == MatchManager.MODE_OVERLAND
	team_option.disabled = not is_match
	role_option.disabled = is_overland
	match_duration_option.disabled = is_overland
	$CanvasLayer/Control/VBoxContainer/MatchRulesLabel.visible = is_match
	if not is_match:
		team_option.select(0)
	_update_roster_display()

func _parse_role(value: String) -> int:
	match value.to_lower():
		"player", "shooter", "sutör", "sutor":
			return MatchManager.ROLE_PLAYER
		"goalkeeper", "kaleci":
			return MatchManager.ROLE_GOALKEEPER
	return -1

func _parse_team(value: String) -> int:
	match value.to_lower():
		"auto", "balanced":
			return MatchManager.TEAM_AUTO
		"blue", "mavi", "robot":
			return MatchManager.TEAM_BLUE
		"red", "kırmızı", "kirmizi", "human", "insan":
			return MatchManager.TEAM_RED
	return -1

func _get_application_arguments() -> PackedStringArray:
	var user_arguments = OS.get_cmdline_user_args()
	if not user_arguments.is_empty():
		return user_arguments

	var application_arguments := PackedStringArray()
	var expecting_value := false
	for argument in OS.get_cmdline_args():
		if expecting_value:
			application_arguments.append(argument)
			expecting_value = false
		elif argument == "--server":
			application_arguments.append(argument)
		elif argument == "--host" or argument == "--port" or argument == "--role" or argument == "--team" or argument == "--username" or argument == "--minutes" or argument == "--mode" or argument == "--transport":
			application_arguments.append(argument)
			expecting_value = true
		elif argument.begins_with("--host=") or argument.begins_with("--port=") or argument.begins_with("--role=") or argument.begins_with("--team=") or argument.begins_with("--username=") or argument.begins_with("--minutes=") or argument.begins_with("--mode=") or argument.begins_with("--transport="):
			application_arguments.append(argument)
	return application_arguments

func _build_transport_option():
	transport_option = OptionButton.new()
	transport_option.add_item("WebSocket (web + Android + PC)", NetJoin.TRANSPORT_WEBSOCKET)
	transport_option.add_item("UDP / ENet (Android + PC only)", NetJoin.TRANSPORT_UDP)
	var is_web := OS.has_feature("web")
	if is_web:
		transport_option.select(0)
		transport_option.disabled = true
		host_button.disabled = true
		host_button.tooltip_text = "Web browsers cannot host servers; host from the desktop or Android version."
	port_edit.placeholder_text = "Port"
	var container := port_edit.get_parent()
	container.add_child(transport_option)
	container.move_child(transport_option, port_edit.get_index() + 1)

func _selected_transport() -> int:
	if OS.has_feature("web") or transport_option == null:
		return NetJoin.TRANSPORT_WEBSOCKET
	return transport_option.get_selected_id()

func createServer(advertised_host: String = "", port: int = DEFAULT_PORT, host_team: int = MatchManager.TEAM_AUTO, host_role: int = MatchManager.ROLE_PLAYER, username: String = "Player", match_minutes: int = 5, selected_mode: int = MatchManager.MODE_FREE_KICK, transport: int = -1, room_tokens: Array = []):
	if transport < 0:
		transport = _selected_transport()
	var result := NetJoin.create_server(port, host_team, host_role, username, match_minutes, selected_mode, transport, room_tokens)
	if not result.ok:
		status_label.text = result.message
		return
	_save_username(username)
	var message: String = result.message
	if advertised_host == "0.0.0.0":
		push_warning("0.0.0.0 listens on all interfaces; clients must use the server's public IP")
	elif not advertised_host.is_empty():
		message += "; clients can connect to %s:%d" % [advertised_host, port]
	print(message)
	status_label.text = message
	get_tree().change_scene_to_file.call_deferred(NetJoin.game_scene_for(selected_mode))

func createClient(host: String = "", port: int = DEFAULT_PORT, team: int = MatchManager.TEAM_AUTO, role: int = MatchManager.ROLE_PLAYER, username: String = "Player", selected_mode: int = MatchManager.MODE_FREE_KICK, transport: int = -1):
	if transport < 0:
		transport = _selected_transport()
	var target_host := host.strip_edges()
	if target_host.is_empty():
		target_host = "192.168.1.9"
		if ip_edit and ip_edit.text.strip_edges() != "":
			target_host = ip_edit.text.strip_edges()
	var result := NetJoin.create_client(target_host, port, team, role, username, selected_mode, transport)
	if not result.ok:
		status_label.text = result.message
		return
	_save_username(username)
	print(result.message)
	status_label.text = result.message

func _on_host_button_down():
	var port = _get_selected_port()
	if port >= 0:
		createServer("", port, team_option.get_selected_id(), role_option.get_selected_id(), username_edit.text, match_duration_option.get_selected_id(), game_mode_option.get_selected_id())

func _on_connect_to_server_button_down():
	var port = _get_selected_port()
	if port >= 0:
		createClient("", port, team_option.get_selected_id(), role_option.get_selected_id(), username_edit.text, game_mode_option.get_selected_id())

func _get_selected_port() -> int:
	var value = port_edit.text.strip_edges()
	if not value.is_valid_int():
		status_label.text = "Enter a valid port number."
		return -1
	var port = value.to_int()
	if port < 1 or port > 65535:
		status_label.text = "Port must be between 1 and 65535."
		return -1
	return port

func _save_username(value: String):
	var preferences = ConfigFile.new()
	preferences.set_value("player", "username", value.strip_edges().substr(0, 18))
	preferences.save("user://player.cfg")

func _update_roster_display():
	var names: PackedStringArray = []
	for peer_id in MatchManager.roster:
		names.append(MatchManager.username_for_peer(peer_id))
	names.sort()
	var mode := game_mode_option.get_selected_id()
	var capacity := MatchManager.max_players_for_mode_id(mode) if mode != MatchManager.MODE_MATCH else MatchManager.MAX_MATCH_PLAYERS
	if mode == MatchManager.MODE_FREE_KICK:
		capacity = MatchManager.MAX_FREE_KICK_PLAYERS
	roster_label.text = "PLAYERS %d/%d" % [names.size(), capacity]
	if not names.is_empty():
		roster_label.text += "  |  " + " - ".join(names)
