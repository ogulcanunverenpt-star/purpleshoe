extends Node

const SOUND_FILES := {
	"kick": "kick1.wav",
	"pass": "kick2.wav",
	"bounce": "bounce.wav",
	"post": "ballhitpost.wav",
	"catch": "catch.wav",
	"hit": "hit.wav",
	"slide": "slide1.wav",
	"slide_alt": "slide2.wav",
	"whistle": "whistle.wav",
	"foul": "foul.wav",
	"goal": "goal.wav",
	"net": "net1.wav",
	"ooh": "ooh.wav",
	"cross": "oohclap.wav",
	"applause": "applause.wav",
	"winner": "winner.wav",
}

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	for sound_name in SOUND_FILES:
		var path: String = "res://match_audio/" + SOUND_FILES[sound_name]
		var stream := load(path) as AudioStream
		if stream == null:
			push_error("Missing match sound: %s" % path)
			continue
		AudioManager.register_sfx("match_" + sound_name, stream)
	var crowd := load("res://match_audio/crowd.wav") as AudioStream
	var music := load("res://match_audio/Football_2v3.mp3") as AudioStream
	if crowd == null or music == null:
		push_error("Match crowd or music stream is missing.")
		return
	AudioManager.play_ambient(crowd, -18.0)
	AudioManager.play_music(music, -20.0)

func play_event(event: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	if not SOUND_FILES.has(event):
		push_error("Unknown match sound: %s" % event)
		return
	AudioManager.play_sfx("match_" + event, -6.0)

func _exit_tree() -> void:
	if DisplayServer.get_name() != "headless":
		AudioManager.reset_for_world_change()
