@tool
extends Node
## Puts the PSX look into a project that has never seen this pack.
##
## The shaders in Shaders/ declare their numbers as `global uniform`, and a global uniform is
## backed by an entry under Project Settings > Shader Globals. That list belongs to the project,
## not to the .gdshader file, so copying Shaders/ into an existing project brings the shaders
## and leaves the list empty: the materials have nothing behind them and the surfaces come out
## untextured, with no message pointing at the cause.
##
## Attach this script to any Node in your scene and the entries are created for you, in the
## editor and in a running game alike. An entry your project already has is left exactly as it
## is, so numbers you tuned yourself survive an update of this pack.
##
## The demo scene does not need this script: the entries are already in this project's
## project.godot. It is here for the moment you take the shaders somewhere else.

## Every global the shaders read, with the value this pack ships.
const GLOBALS := {
	"psx_texture_resolution": 256.0,  ## Simulated texture size in pixels.
	"psx_colour_levels": 58.0,        ## Steps per colour channel.
	"psx_vertex_snap": 432.0,         ## Grid the vertices snap to; the wobble of the era.
	"psx_affine_amount": 0.39,        ## Texture warp on sloped surfaces.
	"psx_dither": 1.0,                ## Strength of the dot pattern.
	"psx_screen_height": 360.0,       ## Rendered height before the image is blown back up.
}


func _ready() -> void:
	ensure_globals()


## Creates the globals the project is missing and returns how many there were. Zero means the
## project already had them, which is the case in this pack's own project.
func ensure_globals() -> int:
	var added: Array[String] = []
	var live: Array = RenderingServer.global_shader_parameter_get_list()
	for key: String in GLOBALS:
		var value: float = GLOBALS[key]
		var setting := "shader_globals/" + key
		if not ProjectSettings.has_setting(setting):
			ProjectSettings.set_setting(setting, {"type": "float", "value": value})
			added.append(key)
		# The renderer keeps its own list and a running game never re-reads Project Settings,
		# so a global added here has to reach both.
		if not live.has(StringName(key)):
			RenderingServer.global_shader_parameter_add(
					key, RenderingServer.GLOBAL_VAR_TYPE_FLOAT, value)
	if added.is_empty():
		return 0
	if Engine.is_editor_hint():
		# Written to project.godot so the look survives a restart of the editor.
		ProjectSettings.save()
	print_rich("[color=green]Alone in the Dusk:[/color] added %d shader globals this project "
			% added.size() + "was missing (%s). The look is live; nothing else to set up."
			% ", ".join(added))
	return added.size()
