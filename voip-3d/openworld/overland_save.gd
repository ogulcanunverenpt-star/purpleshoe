class_name OverlandSave extends Node
## Local persistence for Overland (replaces the old Supabase backend).
## Stores the player's position and discovered districts in user://overland_save.json
## (IndexedDB on web, app storage on Android, user data dir on desktop).

signal loaded(data: Dictionary)

const SAVE_PATH := "user://overland_save.json"


func boot() -> void:
	loaded.emit(_read())


func save(data: Dictionary) -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(data))


func _read() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return {}
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}
