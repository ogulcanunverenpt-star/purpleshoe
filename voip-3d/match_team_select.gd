extends Control

@onready var red_button: Button = $Center/Panel/Options/Red
@onready var blue_button: Button = $Center/Panel/Options/Blue
@onready var status_label: Label = $Center/Panel/Options/Status

var connecting := false
var connected := false

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	MatchManager.local_role_changed.connect(_on_joined)
	MatchManager.role_selection_rejected.connect(_on_rejected)
	red_button.pressed.connect(_choose_team.bind(MatchManager.TEAM_RED))
	blue_button.pressed.connect(_choose_team.bind(MatchManager.TEAM_BLUE))
	$Center/Panel/Options/Back.pressed.connect(_back)
	if NetJoin.pending_match_connection.is_empty():
		status_label.text = "Room information is missing. Return to the lobby."
		red_button.disabled = true
		blue_button.disabled = true

func _choose_team(team: int) -> void:
	if connecting:
		return
	connecting = true
	red_button.disabled = true
	blue_button.disabled = true
	status_label.text = "Joining the selected team..."
	if connected:
		MatchManager.requested_team = team
		NetJoin.return_to_game_connection["team"] = team
		MatchManager.request_join.rpc_id(1, team, MatchManager.ROLE_PLAYER, MatchManager.requested_username, MatchManager.MODE_MATCH, MatchManager.requested_room_token)
		return
	var room := NetJoin.pending_match_connection
	var result := NetJoin.create_client(
		String(room.get("host", "")), int(room.get("port", 0)), team,
		MatchManager.ROLE_PLAYER, MatrixClient.local_username(), MatchManager.MODE_MATCH,
		int(room.get("transport", NetJoin.TRANSPORT_WEBSOCKET)), String(room.get("token", "")), true, false
	)
	if not result.get("ok", false):
		_on_rejected(String(result.get("message", "Could not connect.")))
	else:
		connected = true

func _on_joined(_role: int) -> void:
	NetJoin.pending_match_connection.clear()
	get_tree().change_scene_to_file.call_deferred(NetJoin.game_scene_for(MatchManager.MODE_MATCH))

func _on_rejected(message: String) -> void:
	connecting = false
	red_button.disabled = false
	blue_button.disabled = false
	status_label.text = message

func _back() -> void:
	if connected:
		MatchManager.disconnect_client()
	NetJoin.pending_match_connection.clear()
	get_tree().change_scene_to_file("res://lobby.tscn")
