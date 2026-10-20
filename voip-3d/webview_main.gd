extends Control

const DEBUG_PORTAL_URL := "http://192.168.1.9:5173/"
const PRODUCTION_PORTAL_URL := "https://gamebler.xyz/"
const WEB_FRAME_ID := "purpleshoe-game-portal"

var _return_callback = null


func _ready() -> void:
	var base_url := DEBUG_PORTAL_URL if OS.is_debug_build() else PRODUCTION_PORTAL_URL
	var portal_url := base_url + "?source=godot"
	var handoff_error := ""
	if not MatrixClient.matrix_access_token.is_empty():
		var handoff: Dictionary = await MatrixClient.create_matrix_handoff_ticket()
		if handoff.get("success", false):
			portal_url += "#ps_handoff=%s" % String(handoff.get("ticket", ""))
		else:
			handoff_error = String(handoff.get("message", "Could not obtain a Matrix session ticket."))

	if OS.has_feature("web"):
		_open_web_portal(portal_url)
	else:
		var open_result := OS.shell_open(portal_url)
		_build_overlay(portal_url, open_result, handoff_error)
		if open_result != OK:
			push_error("Could not open PurpleShoe in the system browser: %s" % error_string(open_result))


func _open_web_portal(url: String) -> void:
	var callback := JavaScriptBridge.create_callback(Callable(self, "_on_web_portal_return"))
	_return_callback = callback
	var window := JavaScriptBridge.get_interface("window")
	window.set("psGodotReturnCallback", callback)

	var url_json := JSON.stringify(url)
	var expected_origin := "http://192.168.1.9:5173" if OS.is_debug_build() else "https://gamebler.xyz"
	var expected_origin_json := JSON.stringify(expected_origin)
	var frame_id_json := JSON.stringify(WEB_FRAME_ID)
	var script := """
		(() => {
			const oldFrame = document.getElementById(%s);
			if (oldFrame) oldFrame.remove();
			const frame = document.createElement("iframe");
			frame.id = %s;
			frame.src = %s;
			frame.title = "PurpleShoe Messages";
			frame.allow = "camera; microphone; autoplay; clipboard-read; clipboard-write; display-capture";
			frame.referrerPolicy = "no-referrer";
			Object.assign(frame.style, {
				position: "fixed", inset: "0", width: "100vw", height: "100vh",
				border: "0", zIndex: "2147483000", background: "#111018"
			});
			const onMessage = (event) => {
				if (event.origin !== %s || !event.data || event.data.type !== "purpleshoe:return-to-game") return;
				window.removeEventListener("message", onMessage);
				frame.remove();
				const returnToGame = window.psGodotReturnCallback;
				delete window.psGodotReturnCallback;
				if (returnToGame) returnToGame();
			};
			window.addEventListener("message", onMessage);
			document.body.appendChild(frame);
		})()
	""" % [frame_id_json, frame_id_json, url_json, expected_origin_json]
	JavaScriptBridge.eval(script)
	get_tree().paused = true


func _on_web_portal_return(_arguments: Array) -> void:
	get_tree().paused = false
	var result := NetJoin.return_from_webview()
	if result != OK:
		push_error("Could not return to the game: %s" % error_string(result))


func _build_overlay(url: String, open_result: int, handoff_error: String) -> void:
	var color_rect := ColorRect.new()
	color_rect.color = Color(0.15, 0.14, 0.22, 0.97)
	color_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(color_rect)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vbox.custom_minimum_size = Vector2(500, 300)
	vbox.add_theme_constant_override("separation", 20)
	color_rect.add_child(vbox)

	var title := Label.new()
	title.text = "PURPLESHOE MESSAGES"
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var info := Label.new()
	info.text = "PurpleShoe Messages opened in your system browser:\n%s\n\nSwitch back to the game window to return to the game." % url
	if open_result != OK:
		info.text += "\n\nCould not open browser: %s" % error_string(open_result)
	if not handoff_error.is_empty():
		info.text += "\n\nCould not transfer the Matrix session automatically: %s" % handoff_error
	info.add_theme_font_size_override("font_size", 20)
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(info)

	var open_btn := Button.new()
	open_btn.text = "Reopen Browser"
	open_btn.custom_minimum_size = Vector2(0, 60)
	open_btn.add_theme_font_size_override("font_size", 22)
	open_btn.pressed.connect(func():
		var result := OS.shell_open(url)
		if result != OK:
			push_error("Could not open PurpleShoe in the system browser: %s" % error_string(result))
			info.text = "Could not open browser: %s" % error_string(result)
	)
	vbox.add_child(open_btn)

	var return_btn := Button.new()
	return_btn.text = "Return to Game"
	return_btn.custom_minimum_size = Vector2(0, 60)
	return_btn.add_theme_font_size_override("font_size", 22)
	return_btn.pressed.connect(_return_to_game)
	vbox.add_child(return_btn)


func _return_to_game() -> void:
	var result := NetJoin.return_from_webview()
	if result != OK:
		push_error("Could not return to the game: %s" % error_string(result))


func join_room(host: String, port: int, token: String, mode_str: String) -> void:
	var mode_id := NetJoin.parse_mode(mode_str)
	NetJoin.create_client(host, port, MatchManager.TEAM_AUTO, MatchManager.ROLE_PLAYER, "Player", mode_id, NetJoin.TRANSPORT_WEBSOCKET, token)
