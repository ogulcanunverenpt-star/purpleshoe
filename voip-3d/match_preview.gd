extends "res://world.gd"

func _enter_tree() -> void:
	if multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		MatchManager.game_mode = MatchManager.MODE_MATCH
		MatchManager.match_duration_minutes = 5
		MatchManager.roster = {
			1: {"team": MatchManager.TEAM_BLUE, "role": MatchManager.ROLE_PLAYER, "username": "Preview Blue"},
			2: {"team": MatchManager.TEAM_RED, "role": MatchManager.ROLE_PLAYER, "username": "Preview Red"},
		}
		MatchManager.match_ready = true
	super._enter_tree()
