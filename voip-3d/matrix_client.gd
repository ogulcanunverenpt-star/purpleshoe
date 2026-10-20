extends Node
## SERVER CLIENT — the identity, friend request, chat, and room spawning backbone
## for voip-3d, talking to the Node.js backend server.

signal logged_in(user_id: String)
signal login_failed(reason: String)
signal matrix_auth_completed(success: bool, message: String)
signal friend_request_received(from_user_id: String, display_name: String)
signal friend_accepted(from_user_id: String)
signal friends_updated
signal room_invite_received(from_user_id: String, payload: Dictionary)
signal presence_updated
signal world_info_received(payload: Dictionary)
signal talk_request_received(from_user_id: String)
signal talk_response_received(from_user_id: String, accepted: bool)
signal chat_message_received(other_user_id: String, body: String, local_echo: bool)

var SERVER_URL := "http://192.168.1.9:3000"
const PRODUCTION_SERVER_URL := "https://gamebler.xyz"
const MATRIX_SERVER_URL := "https://matrix.gamebler.xyz"
const CONFIG_PATH := "user://account.cfg"
const CHAT_HISTORY_PATH := "user://chat_history.json"
const AVATAR_CONFIG_PATH := "user://avatar_preferences.cfg"

var access_token := ""
var user_id := ""
var matrix_access_token := ""
var matrix_user_id := ""
var matrix_device_id := ""
var matrix_auth_warning := ""
var open_lobby_from_game := false
var pending_friend_requests: Dictionary = {}   # username -> display_name
var _friends_cache: Array = []
var _online_users: Array[String] = []
var _pending_room_invites: Array[Dictionary] = []
var _chat_history: Dictionary = {}
var _last_sync_ts: int = 0
var _syncing := false
var _auth_generation := 0
var _avatar_preferences := ConfigFile.new()


func _ready() -> void:
	_load_config()
	_load_chat_history()
	_load_avatar_preferences()
	if access_token != "":
		_start_sync()


func is_logged_in() -> bool:
	return access_token != ""


func local_username() -> String:
	return user_id


func selected_avatar_id() -> String:
	var avatar_id := String(_avatar_preferences.get_value("avatars", user_id, AvatarCatalog.MAN))
	if not AvatarCatalog.is_valid_avatar(avatar_id):
		push_warning("Ignoring invalid saved avatar selection for %s: %s" % [user_id, avatar_id])
		return AvatarCatalog.MAN
	return AvatarCatalog.canonical_avatar_id(avatar_id)


func save_selected_avatar_id(avatar_id: String) -> bool:
	if not AvatarCatalog.is_valid_avatar(avatar_id):
		push_error("Refusing to save unknown avatar selection: %s" % avatar_id)
		return false
	if user_id.strip_edges().is_empty():
		push_error("Cannot save an avatar selection without an authenticated account.")
		return false
	_avatar_preferences.set_value("avatars", user_id, AvatarCatalog.canonical_avatar_id(avatar_id))
	var save_result := _avatar_preferences.save(AVATAR_CONFIG_PATH)
	if save_result != OK:
		push_error("Could not save avatar selection: %s" % error_string(save_result))
		return false
	return true


func friends_list() -> Array:
	return _friends_cache


func online_users() -> Array[String]:
	return _online_users.duplicate()


func is_user_online(username: String) -> bool:
	return _online_users.has(username)


func pending_room_invites() -> Array[Dictionary]:
	return _pending_room_invites.duplicate(true)


# ---------------- Auth ----------------

func register(username: String, password: String) -> void:
	var body := {"username": username, "password": password}
	var res = await _raw_request("POST", "/api/register", body, false)
	_finish_auth(res, username, password, true)


func login(username: String, password: String) -> void:
	var body := {"username": username, "password": password}
	var res = await _raw_request("POST", "/api/login", body, false)
	_finish_auth(res, username, password, false)


func _finish_auth(res: Dictionary, username: String, password: String, is_register: bool) -> void:
	var body: Dictionary = res.get("body", {})
	if not body.get("success", false) and not body.has("token"):
		login_failed.emit(String(body.get("error", "Could not connect to the server, or the username or password is incorrect.")))
		return
	var authenticated_user := String(body.get("username", ""))
	if not user_id.is_empty() and user_id != authenticated_user:
		matrix_access_token = ""
		matrix_user_id = ""
		matrix_device_id = ""
	access_token = String(body.get("token", ""))
	user_id = authenticated_user
	matrix_auth_warning = ""
	_auth_generation += 1
	var auth_generation := _auth_generation
	_save_config()
	logged_in.emit(user_id)
	_start_sync()
	_authenticate_matrix(username, password, is_register, auth_generation)


func _authenticate_matrix(username: String, password: String, is_register: bool, auth_generation: int) -> void:
	var matrix_username := username.strip_edges()
	if matrix_username.begins_with("@"):
		matrix_username = matrix_username.substr(1)
	var server_separator := matrix_username.find(":")
	if server_separator >= 0:
		matrix_username = matrix_username.substr(0, server_separator)

	var payload: Dictionary
	var endpoint := "/_matrix/client/v3/login"
	if is_register:
		endpoint = "/_matrix/client/v3/register"
		payload = {
			"username": matrix_username,
			"password": password,
			"auth": {"type": "m.login.dummy"},
			"initial_device_display_name": "PurpleShoe Godot"
		}
	else:
		payload = {
			"type": "m.login.password",
			"identifier": {"type": "m.id.user", "user": matrix_username},
			"password": password,
			"initial_device_display_name": "PurpleShoe Godot"
		}

	var result: Dictionary = await _matrix_request(endpoint, payload)
	if auth_generation != _auth_generation:
		return
	if is_register and String(result.get("errcode", "")) == "M_USER_IN_USE":
		result = await _matrix_request("/_matrix/client/v3/login", {
			"type": "m.login.password",
			"identifier": {"type": "m.id.user", "user": matrix_username},
			"password": password,
			"initial_device_display_name": "PurpleShoe Godot"
		})
		if auth_generation != _auth_generation:
			return

	if not result.get("success", false):
		matrix_auth_warning = "Could not sync Matrix account: %s" % String(result.get("message", "Unknown server error"))
		push_warning(matrix_auth_warning)
		matrix_auth_completed.emit(false, matrix_auth_warning)
		return

	var matrix_body: Dictionary = result.get("body", {})
	matrix_access_token = String(matrix_body.get("access_token", ""))
	matrix_user_id = String(matrix_body.get("user_id", ""))
	matrix_device_id = String(matrix_body.get("device_id", ""))
	if matrix_access_token.is_empty() or matrix_user_id.is_empty():
		matrix_auth_warning = "The Matrix server reported a successful login but did not return session details."
		push_warning(matrix_auth_warning)
		matrix_auth_completed.emit(false, matrix_auth_warning)
		return
	_save_config()
	matrix_auth_warning = ""
	matrix_auth_completed.emit(true, "Matrix account connected: %s" % matrix_user_id)


func create_matrix_handoff_ticket() -> Dictionary:
	if matrix_access_token.is_empty() or matrix_user_id.is_empty():
		return {"success": false, "message": "No Matrix session is active yet. You can log in from the Messages page."}
	if not OS.is_debug_build() and not SERVER_URL.begins_with("https://"):
		return {"success": false, "message": "The production API URL must use HTTPS to securely transfer the Matrix session."}

	var response: Dictionary = await _raw_request("POST", "/api/matrix/handoff", {
		"matrix_access_token": matrix_access_token,
		"matrix_user_id": matrix_user_id,
		"matrix_device_id": matrix_device_id
	}, true, 12.0)
	var body: Dictionary = response.get("body", {})
	if int(response.get("code", 0)) < 200 or int(response.get("code", 0)) >= 300 or not body.get("success", false):
		return {
			"success": false,
			"message": String(body.get("error", "Could not obtain a Matrix session ticket."))
		}
	var ticket := String(body.get("ticket", ""))
	if ticket.is_empty():
		return {"success": false, "message": "The server did not return a valid Matrix session ticket."}
	return {"success": true, "ticket": ticket}


func _matrix_request(path: String, payload: Dictionary, token: String = "") -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 12.0
	add_child(req)
	var headers := PackedStringArray(["Content-Type: application/json"])
	if not token.is_empty():
		headers.append("Authorization: Bearer %s" % token)
	var err := req.request(MATRIX_SERVER_URL + path, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		req.queue_free()
		return {"success": false, "message": "Could not send request to the Matrix server: %s" % error_string(err)}
	var response = await req.request_completed
	req.queue_free()
	var code: int = response[1]
	var raw := (response[3] as PackedByteArray).get_string_from_utf8()
	var parsed = JSON.parse_string(raw) if not raw.is_empty() else {}
	var response_body: Dictionary = parsed if parsed is Dictionary else {}
	if code < 200 or code >= 300:
		return {
			"success": false,
			"errcode": String(response_body.get("errcode", "")),
			"message": String(response_body.get("error", "HTTP %d" % code)),
			"body": response_body
		}
	return {"success": true, "body": response_body}


func _logout_matrix(token: String) -> void:
	var result: Dictionary = await _matrix_request("/_matrix/client/v3/logout", {}, token)
	if not result.get("success", false):
		push_warning("Could not log out of Matrix: %s" % String(result.get("message", "Unknown server error")))


func logout() -> void:
	_auth_generation += 1
	if not matrix_access_token.is_empty():
		_logout_matrix(matrix_access_token)
	_syncing = false
	access_token = ""
	user_id = ""
	matrix_access_token = ""
	matrix_user_id = ""
	matrix_device_id = ""
	matrix_auth_warning = ""
	pending_friend_requests.clear()
	_friends_cache.clear()
	_online_users.clear()
	_pending_room_invites.clear()
	presence_updated.emit()
	var dir := DirAccess.open("user://")
	if dir:
		dir.remove("account.cfg")


func _load_config() -> void:
	var default_server_url := "http://192.168.1.9:3000" if OS.is_debug_build() else PRODUCTION_SERVER_URL
	SERVER_URL = default_server_url
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	access_token = str(cfg.get_value("account", "access_token", ""))
	user_id = str(cfg.get_value("account", "user_id", ""))
	SERVER_URL = str(cfg.get_value("account", "server_url", default_server_url))
	if not OS.is_debug_build() and SERVER_URL.begins_with("http://"):
		SERVER_URL = PRODUCTION_SERVER_URL
	matrix_access_token = str(cfg.get_value("account", "matrix_access_token", ""))
	matrix_user_id = str(cfg.get_value("account", "matrix_user_id", ""))
	matrix_device_id = str(cfg.get_value("account", "matrix_device_id", ""))


func _load_avatar_preferences() -> void:
	if not FileAccess.file_exists(AVATAR_CONFIG_PATH):
		return
	var load_result := _avatar_preferences.load(AVATAR_CONFIG_PATH)
	if load_result != OK:
		push_error("Could not load avatar preferences: %s" % error_string(load_result))


func _save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("account", "access_token", access_token)
	cfg.set_value("account", "user_id", user_id)
	cfg.set_value("account", "server_url", SERVER_URL)
	cfg.set_value("account", "matrix_access_token", matrix_access_token)
	cfg.set_value("account", "matrix_user_id", matrix_user_id)
	cfg.set_value("account", "matrix_device_id", matrix_device_id)
	cfg.save(CONFIG_PATH)


# ---------------- Low-level HTTP ----------------

func _raw_request(method: String, path: String, body = null, authed: bool = true, timeout := 20.0) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = timeout
	add_child(req)
	var headers := PackedStringArray(["Content-Type: application/json"])
	if authed and access_token != "":
		headers.append("Authorization: Bearer %s" % access_token)
	var payload := "" if body == null else JSON.stringify(body)
	var http_method := HTTPClient.METHOD_GET
	match method:
		"POST": http_method = HTTPClient.METHOD_POST
		"PUT": http_method = HTTPClient.METHOD_PUT
		"DELETE": http_method = HTTPClient.METHOD_DELETE
	var err := req.request(SERVER_URL + path, headers, http_method, payload)
	if err != OK:
		req.queue_free()
		return {"code": 0, "body": {"error": error_string(err)}}
	var result = await req.request_completed
	req.queue_free()
	var code: int = result[1]
	var raw := (result[3] as PackedByteArray).get_string_from_utf8()
	var parsed = null
	if raw != "" and (raw.begins_with("{") or raw.begins_with("[")):
		parsed = JSON.parse_string(raw)
	return {"code": code, "body": parsed if parsed is Dictionary else {}}


# ---------------- Sync Loop (Polling) ----------------

func _start_sync() -> void:
	if _syncing:
		return
	_syncing = true
	_sync_loop()


func _sync_loop() -> void:
	while _syncing and access_token != "":
		var url := "/api/sync?since=%d" % _last_sync_ts
		var res = await _raw_request("GET", url, null, true, 10.0)
		if not _syncing:
			return
		var body: Dictionary = res.get("body", {})
		if res.get("code", 0) == 200 and body.get("success", false):
			_last_sync_ts = int(body.get("timestamp", _last_sync_ts))
			_handle_sync_payload(body)
		await get_tree().create_timer(2.0).timeout


func _handle_sync_payload(body: Dictionary) -> void:
	# Update friends
	if body.has("friends"):
		var new_friends: Array = body.get("friends", [])
		if new_friends != _friends_cache:
			_friends_cache = new_friends
			friends_updated.emit()

	# Update pending requests
	if body.has("pending_requests"):
		var reqs: Array = body.get("pending_requests", [])
		pending_friend_requests.clear()
		for r in reqs:
			var sender := String(r.get("sender", ""))
			if sender != "":
				pending_friend_requests[sender] = sender
		friends_updated.emit()

	if body.has("online_users"):
		var online: Array[String] = []
		for username in body.get("online_users", []):
			var clean_name := String(username)
			if not clean_name.is_empty() and not online.has(clean_name):
				online.append(clean_name)
		if online != _online_users:
			_online_users = online
			presence_updated.emit()

	var invite_payloads: Array[Dictionary] = []
	if body.has("pending_room_invites"):
		for invite in body.get("pending_room_invites", []):
			if invite is Dictionary:
				invite_payloads.append(_normalize_room_invite(invite))

	# Handle events
	for ev in body.get("events", []):
		var ev_type := String(ev.get("type", ""))
		match ev_type:
			"friend_request":
				var from_user := String(ev.get("from", ""))
				pending_friend_requests[from_user] = from_user
				friend_request_received.emit(from_user, from_user)
			"friend_accept":
				var from_user := String(ev.get("from", ""))
				if not _friends_cache.has(from_user):
					_friends_cache.append(from_user)
				friend_accepted.emit(from_user)
				friends_updated.emit()
			"chat_message":
				var sender := String(ev.get("sender", ""))
				var msg := String(ev.get("message", ""))
				var timestamp := float(ev.get("timestamp", Time.get_unix_time_from_system()))
				if timestamp > 100000000000.0:
					timestamp /= 1000.0
				_store_chat_message(sender, msg, false, String(ev.get("message_id", "")), timestamp)
				chat_message_received.emit(sender, msg, false)
			"room_invite":
				invite_payloads.append(_normalize_room_invite(ev))

	if body.has("pending_room_invites") or not invite_payloads.is_empty():
		var previous_ids: Dictionary = {}
		for invite in _pending_room_invites:
			previous_ids[String(invite.get("invite_id", ""))] = true
		_pending_room_invites.clear()
		var seen_ids: Dictionary = {}
		for invite in invite_payloads:
			var invite_id := String(invite.get("invite_id", ""))
			if seen_ids.has(invite_id):
				continue
			seen_ids[invite_id] = true
			_pending_room_invites.append(invite)
			if not previous_ids.has(invite_id):
				room_invite_received.emit(String(invite.get("from", "")), invite)


func _normalize_room_invite(invite: Dictionary) -> Dictionary:
	var normalized := invite.duplicate(true)
	if not normalized.has("invite_id"):
		normalized["invite_id"] = "%s:%s:%s" % [
			normalized.get("from", ""),
			normalized.get("port", ""),
			normalized.get("timestamp", "")
		]
	return normalized


# ---------------- Friends ----------------

func search_users(term: String) -> Array:
	if term.strip_edges() == "":
		return []
	var res = await _raw_request("GET", "/api/users/search?q=" + term.uri_encode(), null, true)
	return res.get("body", {}).get("users", [])


func send_friend_request(target_user_id: String) -> Dictionary:
	var res = await _raw_request("POST", "/api/friends/request", {"targetUsername": target_user_id}, true)
	var body: Dictionary = res.get("body", {})
	if res.get("code", 0) != 200 or not body.get("success", false):
		push_warning("Friend request could not be sent: %s" % body.get("error", "Server request failed"))
	return body


func respond_friend_request(target_user_id: String, accept: bool) -> void:
	pending_friend_requests.erase(target_user_id)
	await _raw_request("POST", "/api/friends/respond", {"targetUsername": target_user_id, "accept": accept}, true)
	friends_updated.emit()


# ---------------- Chat ----------------

func send_chat(target_user_id: String, text: String) -> void:
	var res = await _raw_request("POST", "/api/chat/send", {"recipient": target_user_id, "message": text}, true)
	var body: Dictionary = res.get("body", {})
	if res.get("code", 0) != 200 or not body.get("success", false):
		push_warning("Chat message could not be sent: %s" % body.get("error", "Server request failed"))
		return
	_store_chat_message(target_user_id, text, true, String(body.get("message_id", "")))
	chat_message_received.emit(target_user_id, text, true)


func chat_history_for(friend_id: String) -> Array[Dictionary]:
	var account_history: Dictionary = _chat_history.get(user_id, {})
	var messages: Array = account_history.get(friend_id, [])
	var result: Array[Dictionary] = []
	for message in messages:
		if message is Dictionary:
			result.append(message.duplicate(true))
	return result


func fetch_chat_history(friend_id: String) -> Array[Dictionary]:
	var res = await _raw_request("GET", "/api/chat/history?with=" + friend_id.uri_encode(), null, true)
	var body: Dictionary = res.get("body", {})
	if res.get("code", 0) != 200 or not body.get("success", false):
		push_warning("Chat history could not be loaded: %s" % body.get("error", "Server request failed"))
		return chat_history_for(friend_id)

	for message in body.get("messages", []):
		if not message is Dictionary:
			continue
		var sender := String(message.get("sender", ""))
		var other_user := String(message.get("recipient", "")) if sender == user_id else sender
		if other_user == friend_id:
			_store_chat_message(
				friend_id,
				String(message.get("message", "")),
				sender == user_id,
				String(message.get("id", "")),
				float(message.get("timestamp", Time.get_unix_time_from_system()))
			)
	return chat_history_for(friend_id)


func _load_chat_history() -> void:
	if not FileAccess.file_exists(CHAT_HISTORY_PATH):
		return
	var file := FileAccess.open(CHAT_HISTORY_PATH, FileAccess.READ)
	if file == null:
		push_error("Could not open local chat history for reading")
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		_chat_history = parsed
	else:
		push_warning("Local chat history file is invalid and was ignored")


func _save_chat_history() -> void:
	var file := FileAccess.open(CHAT_HISTORY_PATH, FileAccess.WRITE)
	if file == null:
		push_error("Could not save local chat history")
		return
	file.store_string(JSON.stringify(_chat_history))


func _store_chat_message(friend_id: String, text: String, outgoing: bool, message_id: String = "", timestamp: float = -1.0) -> void:
	if friend_id.is_empty() or text.is_empty() or user_id.is_empty():
		return
	var account_history: Dictionary = _chat_history.get(user_id, {})
	var messages: Array = account_history.get(friend_id, [])
	if not message_id.is_empty():
		for message in messages:
			if message is Dictionary and String(message.get("id", "")) == message_id:
				return
	var created_at := timestamp if timestamp >= 0.0 else Time.get_unix_time_from_system()
	var entry := {
		"id": message_id,
		"body": text,
		"outgoing": outgoing,
		"timestamp": created_at
	}
	messages.append(entry)
	messages.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("timestamp", 0.0)) < float(b.get("timestamp", 0.0))
	)
	account_history[friend_id] = messages
	_chat_history[user_id] = account_history
	_save_chat_history()


func respond_room_invite(invite_id: String, accept: bool) -> Dictionary:
	var res = await _raw_request(
		"POST",
		"/api/rooms/invites/respond",
		{"invite_id": invite_id, "accept": accept},
		true
	)
	var body: Dictionary = res.get("body", {})
	if res.get("code", 0) == 200 and body.get("success", false):
		for index in range(_pending_room_invites.size() - 1, -1, -1):
			if String(_pending_room_invites[index].get("invite_id", "")) == invite_id:
				_pending_room_invites.remove_at(index)
	return body


# ---------------- Rooms ----------------

func create_server_room(mode_str: String, invitees: Array, match_minutes: int) -> Dictionary:
	var body := {
		"mode": mode_str,
		"match_minutes": match_minutes,
		"invitees": invitees
	}
	var res = await _raw_request("POST", "/api/rooms/create", body, true, 15.0)
	var resp_body: Dictionary = res.get("body", {})
	return resp_body


func join_shared_room(mode_str: String, portal_id: String = "") -> Dictionary:
	var body := {"mode": mode_str}
	if not portal_id.is_empty():
		body["portal_id"] = portal_id
	var res = await _raw_request("POST", "/api/rooms/shared", body, true, 30.0)
	var resp_body: Dictionary = res.get("body", {})
	if res.get("code", 0) != 200 and not resp_body.has("error"):
		resp_body["error"] = "Could not connect to the shared room server."
	return resp_body


func send_direct_room_invites(invitees: Array, mode_str: String, port: int, match_minutes: int = 5, address: String = "192.168.1.9", transport_str: String = "ws") -> Array:
	var tokens: Array = []
	for target_user_id in invitees:
		var tok := _generate_random_token()
		tokens.append(tok)
	return tokens


func request_room(mode: String, invitees: Array, match_minutes: int = 5, existing_room_id: String = "") -> void:
	create_server_room(mode, invitees, match_minutes)


func request_world() -> void:
	join_shared_room("overland")


func send_talk_request(target_user_id: String) -> void:
	send_chat(target_user_id, "[Voice Chat Request]")


func send_talk_response(target_user_id: String, accepted: bool) -> void:
	send_chat(target_user_id, "[Voice Chat Request %s]" % ("Accepted" if accepted else "Declined"))


func get_online_users() -> Array:
	var res = await _raw_request("GET", "/api/online-users", null, true)
	return res.get("body", {}).get("users", [])


func _generate_random_token() -> String:
	var chars := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	var res := ""
	for i in range(16):
		res += chars[randi() % chars.length()]
	return res
