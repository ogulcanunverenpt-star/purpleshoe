class_name OverlandVoice extends Node

signal voice_packet_ready(data: PackedByteArray)

const VOICE_PCM := preload("res://voice_pcm.gd")
const INPUT_THRESHOLD := 0.005
const PACKET_SAMPLE_COUNT := 1200
const PACKET_BYTE_COUNT := PACKET_SAMPLE_COUNT * 2
const MAX_PENDING_PACKETS := 4
const MAX_REMOTE_QUEUE_PACKETS := 10
const MAX_INCOMING_PACKET_BYTES := 8192

var capture_effect: AudioEffectCapture
var input_player: AudioStreamPlayer
var ptt_active := false
var _outgoing_data := PackedByteArray()
var _remote_outputs: Dictionary = {}
var _pending_packets: Dictionary = {}
var _input_warning_sent := false


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var record_bus := AudioServer.get_bus_index("Record")
	if record_bus < 0:
		push_error("Overland PTT requires a Record audio bus.")
		return
	for effect_index in range(AudioServer.get_bus_effect_count(record_bus)):
		var bus_effect := AudioServer.get_bus_effect(record_bus, effect_index)
		if bus_effect is AudioEffectCapture:
			capture_effect = bus_effect as AudioEffectCapture
			break
	if capture_effect == null:
		push_error("Overland PTT requires an AudioEffectCapture on the Record bus.")
		return

	input_player = AudioStreamPlayer.new()
	input_player.name = "MicrophoneInput"
	input_player.stream = AudioStreamMicrophone.new()
	input_player.bus = &"Record"
	add_child(input_player)


func set_ptt_active(active: bool) -> void:
	if ptt_active == active:
		return
	if not active:
		_capture_audio()
		_flush_outgoing()
		if input_player != null and input_player.playing:
			input_player.stop()
		_discard_capture_buffer()
	ptt_active = active
	_input_warning_sent = false
	if active:
		_start_microphone()


func attach_remote(peer_id: int, root: Node3D) -> void:
	remove_remote(peer_id)
	var player := AudioStreamPlayer3D.new()
	player.name = "SpatialVoice"
	player.position.y = 1.5
	player.unit_size = 4.0
	player.max_distance = 28.0
	player.volume_db = 0.0
	root.add_child(player)
	player.finished.connect(_on_remote_stream_finished.bind(peer_id))
	_remote_outputs[peer_id] = {"player": player, "queue": []}
	var pending: Array = _pending_packets.get(peer_id, [])
	_pending_packets.erase(peer_id)
	for packet in pending:
		_enqueue_packet(peer_id, packet)


func remove_remote(peer_id: int) -> void:
	if _remote_outputs.has(peer_id):
		var player: AudioStreamPlayer3D = _remote_outputs[peer_id].player
		if is_instance_valid(player):
			player.stop()
			player.queue_free()
		_remote_outputs.erase(peer_id)
	_pending_packets.erase(peer_id)


func queue_voice_packet(peer_id: int, data: PackedByteArray) -> void:
	if data.is_empty() or data.size() > MAX_INCOMING_PACKET_BYTES or data.size() % 2 != 0:
		push_warning("Discarded invalid Overland voice packet.")
		return
	if not _remote_outputs.has(peer_id):
		var pending: Array = _pending_packets.get(peer_id, [])
		if pending.size() >= MAX_PENDING_PACKETS:
			pending.pop_front()
		pending.append(data.duplicate())
		_pending_packets[peer_id] = pending
		return
	_enqueue_packet(peer_id, data)


func _process(_delta: float) -> void:
	if not ptt_active:
		_discard_capture_buffer()
		return
	if not _is_online():
		if input_player != null and input_player.playing:
			input_player.stop()
		_outgoing_data.clear()
		_discard_capture_buffer()
		return
	if capture_effect == null or input_player == null:
		return
	if not _start_microphone():
		return
	_capture_audio()


func _start_microphone() -> bool:
	if input_player.playing:
		return true
	if OS.get_name() == "Android" and not OS.get_granted_permissions().has("android.permission.RECORD_AUDIO"):
		OS.request_permissions()
		if not _input_warning_sent:
			push_warning("Android microphone permission requested; press PUSH TO TALK again after granting it.")
			_input_warning_sent = true
		return false
	if not OS.has_feature("web") and AudioServer.get_input_device_list().is_empty():
		if not _input_warning_sent:
			push_warning("No microphone input device is available.")
			_input_warning_sent = true
		return false
	input_player.play()
	if not input_player.playing:
		if not _input_warning_sent:
			push_warning("Overland microphone input could not be started.")
			_input_warning_sent = true
		return false
	return true


func _capture_audio() -> void:
	if capture_effect == null:
		return
	var frames_available := capture_effect.get_frames_available()
	if frames_available <= 0:
		return
	var stereo_data := capture_effect.get_buffer(frames_available)
	var encoded: Dictionary = VOICE_PCM.encode_mono_pcm16(stereo_data, AudioServer.get_mix_rate())
	if float(encoded["peak"]) < INPUT_THRESHOLD:
		return
	var data: PackedByteArray = encoded["data"]
	_outgoing_data.append_array(data)
	while _outgoing_data.size() >= PACKET_BYTE_COUNT:
		_send_packet(_outgoing_data.slice(0, PACKET_BYTE_COUNT))
		_outgoing_data = _outgoing_data.slice(PACKET_BYTE_COUNT)


func _flush_outgoing() -> void:
	if not _outgoing_data.is_empty():
		_send_packet(_outgoing_data)
		_outgoing_data = PackedByteArray()


func _send_packet(data: PackedByteArray) -> void:
	if not data.is_empty():
		voice_packet_ready.emit(data)


func _is_online() -> bool:
	var peer := multiplayer.multiplayer_peer
	return peer != null and not (peer is OfflineMultiplayerPeer) \
		and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _discard_capture_buffer() -> void:
	if capture_effect == null:
		return
	var frames_available := capture_effect.get_frames_available()
	if frames_available > 0:
		capture_effect.get_buffer(frames_available)


func _enqueue_packet(peer_id: int, data: PackedByteArray) -> void:
	var state: Dictionary = _remote_outputs[peer_id]
	var queue: Array = state.queue
	if queue.size() >= MAX_REMOTE_QUEUE_PACKETS:
		queue.pop_front()
	queue.append(data.duplicate())
	state.queue = queue
	_remote_outputs[peer_id] = state
	_play_next_packet(peer_id)


func _play_next_packet(peer_id: int) -> void:
	if not _remote_outputs.has(peer_id):
		return
	var state: Dictionary = _remote_outputs[peer_id]
	var player: AudioStreamPlayer3D = state.player
	var queue: Array = state.queue
	if not is_instance_valid(player) or player.playing or queue.is_empty():
		return
	var data: PackedByteArray = queue.pop_front()
	state.queue = queue
	_remote_outputs[peer_id] = state
	var stream := AudioStreamWAV.new()
	stream.mix_rate = VOICE_PCM.SAMPLE_RATE
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.stereo = false
	stream.data = data
	player.stream = stream
	player.play()


func _on_remote_stream_finished(peer_id: int) -> void:
	_play_next_packet(peer_id)
