extends Node

signal role_changed(peer_id: int, role: int)
signal local_role_changed(role: int)
signal role_selection_rejected(message: String)
signal match_state_changed(is_ready: bool)
signal player_state_changed(peer_id: int, team: int, role: int, username: String)
signal player_fell(peer_id: int, username: String)
signal player_disconnected(peer_id: int, username: String)
signal roster_changed

const TEAM_BLUE := 0
const TEAM_RED := 1
const TEAM_AUTO := 2
const ROLE_PLAYER := 0
const ROLE_GOALKEEPER := 1
const MODE_FREE_KICK := 0
const MODE_MATCH := 1
const MODE_OVERLAND := 2
const MODE_CONFERENCE := 3
const MAX_FREE_KICK_PLAYERS := 2
const MAX_OVERLAND_PLAYERS := 32
const MAX_CONFERENCE_PLAYERS := 20
const MAX_MATCH_PLAYERS := 1
const MIN_MATCH_PLAYERS := 1
const MAX_FIELD_PLAYERS_PER_TEAM := 10
const MAX_PLAYERS_PER_TEAM := MAX_FIELD_PLAYERS_PER_TEAM + 1
const MATCH_FORMATION_433 := [
	Vector2(-16.0, 10.0),
	Vector2(-5.0, 8.0),
	Vector2(5.0, 8.0),
	Vector2(16.0, 10.0),
	Vector2(-12.0, 23.0),
	Vector2(0.0, 26.0),
	Vector2(12.0, 23.0),
	Vector2(-14.0, 36.0),
	Vector2(0.0, 43.0),
	Vector2(14.0, 36.0)
]

var requested_role := ROLE_PLAYER
var requested_team := TEAM_AUTO
var requested_username := "Player"
var roster: Dictionary = {}
var last_rejection := ""
var match_ready := false
var match_duration_minutes := 5
var game_mode := MODE_FREE_KICK
var preferred_mode := MODE_MATCH
var valid_room_tokens: Array = []
var matrix_ids: Dictionary = {}

func start_server(host_team: int, host_role: int, username: String, dedicated: bool, duration_minutes: int = 5, selected_mode: int = MODE_FREE_KICK):
	if selected_mode != MODE_FREE_KICK and selected_mode != MODE_MATCH and selected_mode != MODE_OVERLAND and selected_mode != MODE_CONFERENCE:
		push_error("Invalid game mode.")
		return
	if selected_mode != MODE_CONFERENCE and (duration_minutes < 5 or duration_minutes > 90 or duration_minutes % 5 != 0):
		push_error("Match duration must be between 5 and 90 minutes in 5-minute increments.")
		return
	roster.clear()
	matrix_ids.clear()
	match_ready = false
	match_duration_minutes = duration_minutes
	game_mode = selected_mode
	requested_role = ROLE_PLAYER if selected_mode == MODE_MATCH else host_role
	requested_team = TEAM_RED if selected_mode == MODE_MATCH else _resolve_team(host_team, requested_role)
	requested_username = _sanitize_username(username)
	if not dedicated:
		_assign_peer(1, requested_team, requested_role, requested_username)
	_update_match_state()

var requested_room_token := ""

func start_client(team: int, role: int, username: String, selected_mode: int = MODE_FREE_KICK, room_token: String = ""):
	roster.clear()
	matrix_ids.clear()
	match_ready = false
	requested_role = role
	requested_team = team
	requested_username = _sanitize_username(username)
	requested_room_token = room_token
	game_mode = selected_mode
	last_rejection = ""
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server, CONNECT_ONE_SHOT)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed, CONNECT_ONE_SHOT)

func _on_connected_to_server():
	print("Connected to server as %s" % requested_username)
	request_join.rpc_id(1, requested_team, requested_role, requested_username, game_mode, requested_room_token)
	if MatrixClient.is_logged_in():
		announce_matrix_id.rpc_id(1, MatrixClient.user_id)

func _on_connection_failed():
	push_error("Could not connect to free-kick server")

@rpc("any_peer", "call_remote", "reliable")
func request_join(team: int, role: int, username: String, selected_mode: int, room_token: String = ""):
	if not multiplayer.is_server():
		return
	var peer_id = multiplayer.get_remote_sender_id()
	if roster.has(peer_id):
		return
	if selected_mode != game_mode:
		_reject_role(peer_id, "You must select the same game mode as the server.")
		return
	if game_mode == MODE_MATCH and team == TEAM_BLUE:
		_reject_role(peer_id, "The ROBOT team is controlled by the computer. Select the HUMAN (Red) team.")
		return
	if game_mode != MODE_OVERLAND and not valid_room_tokens.is_empty():
		if not valid_room_tokens.has(room_token):
			_reject_role(peer_id, "The invite is invalid or has expired.")
			return
		valid_room_tokens.erase(room_token)   # kişiye özel, tek kullanımlık davet
	if roster.size() >= max_players_for_mode():
		_reject_role(peer_id, "The player limit for this mode has been reached.")
		return
	if game_mode != MODE_CONFERENCE and role != ROLE_PLAYER and role != ROLE_GOALKEEPER:
		_reject_role(peer_id, "Invalid position selection.")
		return
	var clean_username = _sanitize_username(username)
	if clean_username.is_empty():
		_reject_role(peer_id, "A username is required.")
		return

	var assigned_role = ROLE_PLAYER if game_mode == MODE_MATCH else _choose_role(role)
	if assigned_role < 0:
		_reject_role(peer_id, "No suitable roles remain for this mode.")
		return
	var assigned_team := TEAM_BLUE if game_mode == MODE_FREE_KICK and assigned_role == ROLE_GOALKEEPER else TEAM_RED
	if game_mode == MODE_MATCH:
		assigned_team = _resolve_team(team, assigned_role)
		if assigned_team < 0:
			_reject_role(peer_id, "This team already has a captain. Select the other team.")
			return
	_assign_peer(peer_id, assigned_team, assigned_role, clean_username)

func _resolve_team(requested: int, role: int) -> int:
	if game_mode == MODE_OVERLAND or game_mode == MODE_CONFERENCE:
		return TEAM_BLUE
	if game_mode == MODE_FREE_KICK:
		return TEAM_BLUE if role == ROLE_GOALKEEPER else TEAM_RED
	if game_mode == MODE_MATCH:
		if requested == TEAM_BLUE:
			return -1
		return TEAM_RED if _team_has_room(TEAM_RED, role) else -1
	if requested == TEAM_BLUE or requested == TEAM_RED:
		return requested if _team_has_room(requested, role) else -1
	var blue_size := _team_size(TEAM_BLUE)
	var red_size := _team_size(TEAM_RED)
	var blue_has_room := _team_has_room(TEAM_BLUE, role)
	var red_has_room := _team_has_room(TEAM_RED, role)
	if not blue_has_room:
		return TEAM_RED if red_has_room else -1
	if not red_has_room:
		return TEAM_BLUE
	if _team_role_count(TEAM_BLUE, role) < _team_role_count(TEAM_RED, role):
		return TEAM_BLUE
	if _team_role_count(TEAM_RED, role) < _team_role_count(TEAM_BLUE, role):
		return TEAM_RED
	return TEAM_BLUE if blue_size <= red_size else TEAM_RED

func _team_has_room(team: int, role: int) -> bool:
	if game_mode == MODE_MATCH:
		return _team_size(team) == 0
	if role == ROLE_GOALKEEPER:
		return _team_role_count(team, ROLE_GOALKEEPER) == 0
	return _team_role_count(team, ROLE_PLAYER) < MAX_FIELD_PLAYERS_PER_TEAM

func _team_size(team: int) -> int:
	var count := 0
	for assignment in roster.values():
		if assignment.team == team:
			count += 1
	return count

func max_players_for_mode() -> int:
	return max_players_for_mode_id(game_mode)

func max_players_for_mode_id(mode: int) -> int:
	if mode == MODE_OVERLAND:
		return MAX_OVERLAND_PLAYERS
	if mode == MODE_CONFERENCE:
		return MAX_CONFERENCE_PLAYERS
	return MAX_FREE_KICK_PLAYERS if mode == MODE_FREE_KICK else MAX_MATCH_PLAYERS

func _assign_peer(peer_id: int, team: int, role: int, username: String):
	roster[peer_id] = {"team": team, "role": role, "username": username}
	for assigned_peer_id in roster:
		var assignment: Dictionary = roster[assigned_peer_id]
		sync_player_state.rpc(assigned_peer_id, assignment.team, assignment.role, assignment.username)
	roster_changed.emit()
	_update_match_state()

func _choose_role(requested: int) -> int:
	if roster.size() >= max_players_for_mode():
		return -1
	if game_mode == MODE_OVERLAND or game_mode == MODE_CONFERENCE:
		return ROLE_PLAYER
	if game_mode == MODE_MATCH:
		return requested
	if _role_count(requested) == 0:
		return requested
	var alternate_role = ROLE_GOALKEEPER if requested == ROLE_PLAYER else ROLE_PLAYER
	if _role_count(alternate_role) == 0:
		return alternate_role
	return -1

func _role_count(role: int) -> int:
	var count := 0
	for assignment in roster.values():
		if assignment.role == role:
			count += 1
	return count

func _team_role_count(team: int, role: int) -> int:
	var count := 0
	for assignment in roster.values():
		if assignment.team == team and assignment.role == role:
			count += 1
	return count

func swap_match_roles():
	if game_mode != MODE_FREE_KICK or not multiplayer.is_server() or not match_ready:
		return
	var shooter_id := 0
	var keeper_id := 0
	for peer_id in roster:
		if role_for_peer(peer_id) == ROLE_PLAYER:
			shooter_id = peer_id
		elif role_for_peer(peer_id) == ROLE_GOALKEEPER:
			keeper_id = peer_id
	if shooter_id == 0 or keeper_id == 0:
		return
	sync_match_roles.rpc(shooter_id, keeper_id)

@rpc("authority", "call_local", "reliable")
func sync_match_roles(shooter_id: int, keeper_id: int):
	if not roster.has(shooter_id) or not roster.has(keeper_id):
		return
	var shooter: Dictionary = roster[shooter_id]
	var keeper: Dictionary = roster[keeper_id]
	var shooter_team = shooter.team
	shooter.team = keeper.team
	shooter.role = ROLE_GOALKEEPER
	keeper.team = shooter_team
	keeper.role = ROLE_PLAYER
	roster[shooter_id] = shooter
	roster[keeper_id] = keeper
	player_state_changed.emit(shooter_id, shooter.team, shooter.role, shooter.username)
	player_state_changed.emit(keeper_id, keeper.team, keeper.role, keeper.username)
	if shooter_id == multiplayer.get_unique_id():
		local_role_changed.emit(ROLE_GOALKEEPER)
	elif keeper_id == multiplayer.get_unique_id():
		local_role_changed.emit(ROLE_PLAYER)
	roster_changed.emit()
	_update_match_state()

func _sanitize_username(value: String) -> String:
	var cleaned = value.strip_edges()
	return cleaned.substr(0, 18)

func _reject_role(peer_id: int, message: String):
	reject_role.rpc_id(peer_id, message)

@rpc("authority", "call_local", "reliable")
func sync_player_state(peer_id: int, team: int, role: int, username: String):
	if team < 0:
		roster.erase(peer_id)
	else:
		roster[peer_id] = {"team": team, "role": role, "username": username}
	player_state_changed.emit(peer_id, team, role, username)
	if team >= 0 and peer_id == multiplayer.get_unique_id():
		local_role_changed.emit(role)
	roster_changed.emit()
	_update_match_state()

@rpc("authority", "call_remote", "reliable")
func reject_role(message: String):
	last_rejection = message
	role_selection_rejected.emit(message)

func release_player(peer_id: int):
	if multiplayer.is_server() and roster.has(peer_id):
		var existing: Dictionary = roster[peer_id]
		player_disconnected_event.rpc(peer_id, existing.username)
		assign_player_state.rpc(peer_id, -1, -1, existing.username)

func notify_local_player_fell() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if multiplayer.is_server():
		_broadcast_player_fell(multiplayer.get_unique_id())
	else:
		request_player_fell_notification.rpc_id(1)

@rpc("any_peer", "call_remote", "reliable")
func request_player_fell_notification() -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not roster.has(peer_id):
		return
	_broadcast_player_fell(peer_id)

func _broadcast_player_fell(peer_id: int) -> void:
	player_fell_event.rpc(peer_id, username_for_peer(peer_id))

@rpc("authority", "call_local", "reliable")
func player_fell_event(peer_id: int, username: String) -> void:
	player_fell.emit(peer_id, username)

@rpc("authority", "call_local", "reliable")
func player_disconnected_event(peer_id: int, username: String) -> void:
	player_disconnected.emit(peer_id, username)

@rpc("authority", "call_local", "reliable")
func assign_player_state(peer_id: int, team: int, role: int, username: String):
	if team < 0:
		roster.erase(peer_id)
	else:
		roster[peer_id] = {"team": team, "role": role, "username": username}
	player_state_changed.emit(peer_id, team, role, username)
	roster_changed.emit()
	_update_match_state()

func team_for_peer(peer_id: int) -> int:
	return roster.get(peer_id, {}).get("team", -1)

func role_for_peer(peer_id: int) -> int:
	return roster.get(peer_id, {}).get("role", -1)

func username_for_peer(peer_id: int) -> String:
	return roster.get(peer_id, {}).get("username", "Player")

func field_player_count(team: int) -> int:
	return _team_role_count(team, ROLE_PLAYER)

func _update_match_state():
	var ready := false
	#var game_mode = "asdasdsad"
	if game_mode == MODE_OVERLAND or game_mode == MODE_CONFERENCE:
		ready = roster.size() >= 1
	elif game_mode == MODE_FREE_KICK:
		ready = roster.size() == MAX_FREE_KICK_PLAYERS and _role_count(ROLE_GOALKEEPER) == 1 and _role_count(ROLE_PLAYER) == 1
	elif game_mode == MODE_MATCH:
		ready = roster.size() == MIN_MATCH_PLAYERS and _team_size(TEAM_RED) == 1 and _team_size(TEAM_BLUE) == 0
	else:
		ready = false
			
	if ready == match_ready:
		return
	match_ready = ready
	match_state_changed.emit(match_ready)

func local_role() -> int:
	return role_for_peer(multiplayer.get_unique_id())

func local_team() -> int:
	return team_for_peer(multiplayer.get_unique_id())

func match_formation_position(team: int, field_slot: int) -> Vector3:
	var own_half_sign := 1.0 if team == TEAM_BLUE else -1.0
	var slot := clampi(field_slot, 0, MATCH_FORMATION_433.size() - 1)
	return Vector3(MATCH_FORMATION_433[slot].x, 0.0, own_half_sign * MATCH_FORMATION_433[slot].y)

# ---------------- Matrix identity (Overland talk requests / chat need peer_id -> @user:server) ----------------

@rpc("any_peer", "call_remote", "reliable")
func announce_matrix_id(user_matrix_id: String):
	var sender := multiplayer.get_remote_sender_id()
	matrix_ids[sender] = user_matrix_id
	if multiplayer.is_server():
		sync_matrix_id.rpc(sender, user_matrix_id)

@rpc("authority", "call_local", "reliable")
func sync_matrix_id(peer_id: int, user_matrix_id: String):
	matrix_ids[peer_id] = user_matrix_id

func matrix_id_for_peer(peer_id: int) -> String:
	return str(matrix_ids.get(peer_id, ""))

func peer_for_matrix_id(target_matrix_id: String) -> int:
	for peer_id in matrix_ids:
		if matrix_ids[peer_id] == target_matrix_id:
			return peer_id
	return 0

func leave_to_plaza():
	preferred_mode = MODE_OVERLAND
	NetJoin.mark_return_to_game_available()
	disconnect_client()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_rejoin_overland()

func _rejoin_overland() -> void:
	var room := await MatrixClient.join_shared_room("overland")
	if not room.get("success", false):
		push_error("Could not return to Overland: %s" % String(room.get("error", "Shared world unavailable.")))
		get_tree().change_scene_to_file.call_deferred("res://lobby.tscn")
		return
	var join_result := NetJoin.create_client(
		String(room.get("host", "")),
		int(room.get("port", 0)),
		TEAM_AUTO,
		ROLE_PLAYER,
		MatrixClient.local_username(),
		MODE_OVERLAND,
		NetJoin.TRANSPORT_WEBSOCKET,
		String(room.get("token", ""))
	)
	if not join_result.get("ok", false):
		push_error("Could not reconnect to Overland: %s" % String(join_result.get("message", "")))
		get_tree().change_scene_to_file.call_deferred("res://lobby.tscn")

func make_plaza_button() -> Button:
	var button := Button.new()
	button.text = "Return to Plaza"
	button.focus_mode = Control.FOCUS_NONE
	button.position = Vector2(20, 20)
	button.size = Vector2(150, 44)
	button.pressed.connect(leave_to_plaza)
	return button

func disconnect_client():
	roster.clear()
	_update_match_state()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
