extends Node
const VOICE_PCM := preload("res://voice_pcm.gd")

@onready var input: AudioStreamPlayer
var index: int
var effect: AudioEffectCapture
@onready var playbackNode: AudioStreamPlayer3D = $"../AudioStreamPlayer3D"
var playback: AudioStreamGeneratorPlayback
@export var outputPath: NodePath
var inputThreshold: float = 0.005
var receiveBuffer := PackedFloat32Array()
var receiveReadOffset := 0

const MAX_QUEUED_SAMPLES := 12000
var microphone_start_attempted := false

func _ready():
	if outputPath:
		var node = get_node_or_null(outputPath)
		if node:
			if not node.playing:
				node.play()
			playback = node.get_stream_playback()

func setupAudio(id: int):
	input = $input
	set_multiplayer_authority(id)
	if is_multiplayer_authority():
		if OS.get_name() == "Android" and not OS.get_granted_permissions().has("android.permission.RECORD_AUDIO"):
			push_warning("Microphone permission was not granted")
			return
		input.stream = AudioStreamMicrophone.new()
		index = AudioServer.get_bus_index("Record")
		if index >= 0 and AudioServer.get_bus_effect_count(index) > 0:
			effect = AudioServer.get_bus_effect(index, 0)
		else:
			push_error("Record bus is missing its AudioEffectCapture")

func _process(_delta):
	# Authority records local microphone audio
	if is_multiplayer_authority():
		processMic()

	# Non-authorities play back received voice for this character
	if not is_multiplayer_authority():
		processVoice()

var ptt_active := false

func processMic():
	if effect == null or input == null:
		return

	if not ptt_active:
		if input.playing:
			input.stop()
		microphone_start_attempted = false
		return

	if not input.playing:
		if microphone_start_attempted:
			return
		microphone_start_attempted = true
		if AudioServer.get_input_device_list().is_empty():
			push_warning("No microphone input device is available")
			return
		input.play()
		if not input.playing:
			push_warning("Microphone input could not be started")
			return

	var frames_available = effect.get_frames_available()
	if frames_available <= 0:
		return

	var stereo_data: PackedVector2Array = effect.get_buffer(frames_available)
	if stereo_data.size() > 0:
		var encoded: Dictionary = VOICE_PCM.encode_mono_pcm16(stereo_data, AudioServer.get_mix_rate())
		if float(encoded["peak"]) < inputThreshold:
			return
		var data: PackedByteArray = encoded["data"]
		sendData.rpc(data, self.get_path())

func processVoice():
	if receiveBuffer.size() <= 0 or playback == null:
		return
	
	var available = playback.get_frames_available()
	var remaining = receiveBuffer.size() - receiveReadOffset
	var count = min(available, remaining)
	if count <= 0:
		return

	for i in range(count):
		var sample = receiveBuffer[receiveReadOffset + i]
		playback.push_frame(Vector2(sample, sample))

	receiveReadOffset += count
	if receiveReadOffset == receiveBuffer.size():
		receiveBuffer.clear()
		receiveReadOffset = 0
	elif receiveReadOffset >= 4096:
		receiveBuffer = receiveBuffer.slice(receiveReadOffset)
		receiveReadOffset = 0

func queueVoiceData(data: PackedByteArray):
	var sample_count = data.size() / 2
	var samples = PackedFloat32Array()
	samples.resize(sample_count)
	for i in range(sample_count):
		samples[i] = float(data.decode_s16(i * 2)) / 32768.0
	receiveBuffer.append_array(samples)
	if receiveBuffer.size() - receiveReadOffset > MAX_QUEUED_SAMPLES:
		receiveBuffer = receiveBuffer.slice(receiveBuffer.size() - MAX_QUEUED_SAMPLES)
		receiveReadOffset = 0

@rpc("any_peer", "call_remote", "unreliable_ordered")
func sendData(data: PackedByteArray, audioManagerPath: NodePath):
	var sender_id = multiplayer.get_remote_sender_id()
	
	if multiplayer.is_server():
		# Relay audio data from sender to all other connected peers
		for peer_id in multiplayer.get_peers():
			if peer_id != sender_id:
				sendData.rpc_id(peer_id, data, audioManagerPath)

		# If server is also host player (peer 1) and sender is remote client
		if sender_id != 1 and has_node(audioManagerPath):
			var target_node = get_node_or_null(audioManagerPath)
			if target_node and not target_node.is_multiplayer_authority():
				target_node.queueVoiceData(data)
	else:
		# Remote client receiving relayed audio packet
		if has_node(audioManagerPath):
			var target_node = get_node_or_null(audioManagerPath)
			if target_node and not target_node.is_multiplayer_authority():
				target_node.queueVoiceData(data)
