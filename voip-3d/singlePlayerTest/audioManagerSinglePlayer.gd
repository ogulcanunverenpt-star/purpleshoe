extends Node

@onready var input: AudioStreamPlayer
var index: int
var effect: AudioEffectCapture
@onready var playbackNode = $"../AudioStreamPlayer3D"
var playback: AudioStreamGeneratorPlayback
@export var outputPath: NodePath
var inputThreshold: float = 0.005
var receiveBuffer:= PackedFloat32Array()

func _ready():
	playback = get_node(outputPath).get_stream_playback()
	pass

func setupAudio(id):
	#input = $input
	#input.stream = AudioStreamMicrophone.new()
	#input.play()
	index = AudioServer.get_bus_index("Record")
	effect = AudioServer.get_bus_effect(index, 0)

func _process(delta):
	processMic()
	#processVoice()

func processMic():
	var StereoData: PackedVector2Array = effect.get_buffer(effect.get_frames_available())
	#print(StereoData)
	if StereoData.size() > 0:
		var data = PackedFloat32Array()
		data.resize(StereoData.size())
		var maxAmplitude: float = 0.0
		
		for i in range(StereoData.size()):
			var value = (StereoData[i].x + StereoData[i].y) / 2
			maxAmplitude = max(value, maxAmplitude)
			data[i] = value
		if maxAmplitude < inputThreshold:
			return
		print(maxAmplitude)
		#sendData.rpc(data, self.get_path())

func processVoice():
	if receiveBuffer.size() <= 0:
		return
	
	for i in range(min(playback.get_frames_available(), receiveBuffer.size())):
		playback.push_frame(Vector2(receiveBuffer[0], receiveBuffer[0]))
		receiveBuffer.remove_at(0)

@rpc("any_peer", "call_remote")
func sendData(data: PackedFloat32Array, audioManagerPath: NodePath):
	if multiplayer.is_server():
		return
	print("recievied audio on %s from: %s" % [multiplayer.get_unique_id(), audioManagerPath])
	get_node(audioManagerPath).receiveBuffer.append_array(data)
	
