extends Node
## NET JOIN — shared connection logic used by both the manual host/connect screen
## (testScene.gd) and the Matrix-driven lobby (lobby.gd). Having ONE place that builds
## the multiplayer peer (ENet/UDP or WebSocket, with optional TLS) and starts MatchManager
## keeps the two entry points from drifting apart.

const DEFAULT_PORT = 12806
const TRANSPORT_UDP := 0
const TRANSPORT_WEBSOCKET := 1
const GAME_SCENE := "res://world.tscn"
const OVERLAND_SCENE := "res://openworld/main.tscn"
const CONFERENCE_SCENE := "res://AloneInTheDusk/Scenes/Conference.tscn"
const SHOWROOM_SCENE := "res://AloneInTheDusk/Scenes/ShowroomAssets.tscn"

static var peer: MultiplayerPeer

signal status(message: String)

var return_to_game_connection: Dictionary = {}
var can_resume_previous_game := false
var webview_return_scene := ""

func game_scene_for(mode: int) -> String:
	if mode == MatchManager.MODE_CONFERENCE:
		return SHOWROOM_SCENE
	if mode == MatchManager.MODE_MATCH:
		return "res://match.tscn"
	return OVERLAND_SCENE if mode == MatchManager.MODE_OVERLAND else GAME_SCENE

func websocket_url(host: String, port: int, secure: bool) -> String:
	if host.begins_with("ws://") or host.begins_with("wss://"):
		return host
	return "%s://%s:%d" % ["wss" if secure else "ws", host, port]

func _is_secure_page() -> bool:
	if not OS.has_feature("web"):
		return false
	return str(JavaScriptBridge.eval("window.location.protocol", true)) == "https:"

var ssh_tunnel_pid := -1

func start_ssh_tunnel(port: int, remote_host: String = "192.168.1.9", tunnel_user: String = "tunnel") -> int:
	stop_ssh_tunnel()
	var args := PackedStringArray(["-N", "-T", "-o", "StrictHostKeyChecking=no", "-R", "%d:localhost:%d" % [port, port], "%s@%s" % [tunnel_user, remote_host]])
	print("Starting SSH Reverse Tunnel: ssh ", " ".join(args))
	ssh_tunnel_pid = OS.create_process("ssh", args)
	return ssh_tunnel_pid


func stop_ssh_tunnel() -> void:
	if ssh_tunnel_pid > 0:
		OS.kill(ssh_tunnel_pid)
		ssh_tunnel_pid = -1


## Starts a dedicated/local server. `tls_cert_path`/`tls_key_path` (PEM files) enable WSS for
## WebSocket transport (needed so browser pages served over HTTPS can connect). `room_tokens`,
## when non-empty, locks the room: a joining client's `room_token` must be one of these
## (see MatchManager.request_join); each token is consumed on first successful join.
func create_server(port: int, host_team: int, host_role: int, username: String, match_minutes: int,
		selected_mode: int, transport: int, room_tokens: Array = [],
		tls_cert_path: String = "", tls_key_path: String = "", enable_tunnel: bool = false) -> Dictionary:
	username = username.strip_edges()
	if username.is_empty():
		return {"ok": false, "message": "Enter a username."}
	if port < 1 or port > 65535:
		return {"ok": false, "message": "Port must be between 1 and 65535."}
	if enable_tunnel:
		start_ssh_tunnel(port)
	var local_player_slots := 0 if DisplayServer.get_name() == "headless" else 1
	var max_clients := MatchManager.max_players_for_mode_id(selected_mode) - local_player_slots
	var transport_name := "WebSocket" if transport == TRANSPORT_WEBSOCKET else "UDP"
	var err: int
	if transport == TRANSPORT_WEBSOCKET:
		var ws_peer := WebSocketMultiplayerPeer.new()
		var tls_options: TLSOptions = null
		if tls_cert_path != "" and tls_key_path != "":
			var key := CryptoKey.new()
			var cert := X509Certificate.new()
			if key.load(tls_key_path) == OK and cert.load(tls_cert_path) == OK:
				tls_options = TLSOptions.server(key, cert)
			else:
				push_warning("Could not load TLS cert/key; serving plain ws:// instead of wss://")
		err = ws_peer.create_server(port, "*", tls_options)
		peer = ws_peer
	else:
		var enet_peer := ENetMultiplayerPeer.new()
		err = enet_peer.create_server(port, max_clients)
		peer = enet_peer
	if err != OK:
		var error_message = "Could not open %s port %d. The port may be in use; try another port." % [transport_name, port]
		push_error("%s (%s)" % [error_message, error_string(err)])
		return {"ok": false, "message": error_message}
	multiplayer.multiplayer_peer = peer
	MatchManager.valid_room_tokens = room_tokens.duplicate()
	MatchManager.start_server(host_team, host_role, username, DisplayServer.get_name() == "headless", match_minutes, selected_mode)
	var message = "Server listening on %s %d" % [transport_name, port]
	status.emit(message)
	return {"ok": true, "message": message}

## Connects as a client and switches to the game scene for `selected_mode`. `room_token`
## (if the target room is locked) is forwarded to the server's request_join RPC.
func create_client(host: String, port: int, team: int, role: int, username: String,
		selected_mode: int, transport: int, room_token: String = "") -> Dictionary:
	username = username.strip_edges()
	if username.is_empty():
		return {"ok": false, "message": "Enter a username."}
	if port < 1 or port > 65535:
		return {"ok": false, "message": "Port must be between 1 and 65535."}
	var target_host := host.strip_edges()
	if target_host.is_empty() or target_host == "0.0.0.0":
		return {"ok": false, "message": "A valid server address is required."}
	var err: int
	if transport == TRANSPORT_WEBSOCKET:
		var ws_peer := WebSocketMultiplayerPeer.new()
		err = ws_peer.create_client(websocket_url(target_host, port, _is_secure_page() or target_host.begins_with("wss://")))
		peer = ws_peer
	else:
		var enet_peer := ENetMultiplayerPeer.new()
		err = enet_peer.create_client(target_host, port)
		peer = enet_peer
	if err != OK:
		var message := "Connect error to %s:%d: %s" % [target_host, port, error_string(err)]
		push_error(message)
		return {"ok": false, "message": message}
	MatchManager.start_client(team, role, username, selected_mode, room_token)
	if selected_mode == MatchManager.MODE_FREE_KICK or selected_mode == MatchManager.MODE_MATCH:
		return_to_game_connection = {
			"host": target_host,
			"port": port,
			"team": team,
			"role": role,
			"username": username,
			"mode": selected_mode,
			"transport": transport,
			"room_token": room_token
		}
		can_resume_previous_game = false
	multiplayer.multiplayer_peer = peer
	var message := "Connecting to %s:%d" % [target_host, port]
	status.emit(message)
	get_tree().change_scene_to_file.call_deferred(game_scene_for(selected_mode))
	return {"ok": true, "message": message}

func has_return_to_game() -> bool:
	return can_resume_previous_game and not return_to_game_connection.is_empty()

func mark_return_to_game_available() -> void:
	can_resume_previous_game = not return_to_game_connection.is_empty()

func return_to_game() -> Dictionary:
	if not has_return_to_game():
		return {"ok": false, "message": "No match is available to resume."}
	var saved_connection := return_to_game_connection.duplicate(true)
	if String(saved_connection.get("username", "")) != MatrixClient.local_username():
		return {"ok": false, "message": "This match was started with a different user account."}
	MatchManager.disconnect_client()
	return create_client(
		String(saved_connection.get("host", "")),
		int(saved_connection.get("port", 0)),
		int(saved_connection.get("team", MatchManager.TEAM_AUTO)),
		int(saved_connection.get("role", MatchManager.ROLE_PLAYER)),
		String(saved_connection.get("username", "")),
		int(saved_connection.get("mode", MatchManager.MODE_FREE_KICK)),
		int(saved_connection.get("transport", TRANSPORT_WEBSOCKET)),
		String(saved_connection.get("room_token", ""))
	)

func return_from_webview() -> int:
	var target_scene := webview_return_scene
	if target_scene.is_empty():
		target_scene = SHOWROOM_SCENE
	var result := get_tree().change_scene_to_file(target_scene)
	if result == OK:
		webview_return_scene = ""
	else:
		push_error("Could not return from messages page to %s: %s" % [target_scene, error_string(result)])
	return result

func parse_mode(value: String) -> int:
	match value.to_lower():
		"free_kick", "freekick", "serbest-vurus", "serbest_vurus":
			return MatchManager.MODE_FREE_KICK
		"match", "mac":
			return MatchManager.MODE_MATCH
		"overland", "open_world", "acik-dunya", "acik_dunya":
			return MatchManager.MODE_OVERLAND
		"conference", "konferans":
			return MatchManager.MODE_CONFERENCE
	return -1

func parse_transport(value: String) -> int:
	match value.to_lower():
		"ws", "websocket":
			return TRANSPORT_WEBSOCKET
		"udp", "enet":
			return TRANSPORT_UDP
	return -1

func parse_role(value: String) -> int:
	match value.to_lower():
		"player", "shooter", "sutör", "sutor":
			return MatchManager.ROLE_PLAYER
		"goalkeeper", "kaleci":
			return MatchManager.ROLE_GOALKEEPER
	return -1

func parse_team(value: String) -> int:
	match value.to_lower():
		"auto", "balanced":
			return MatchManager.TEAM_AUTO
		"blue", "mavi":
			return MatchManager.TEAM_BLUE
		"red", "kırmızı", "kirmizi":
			return MatchManager.TEAM_RED
	return -1
