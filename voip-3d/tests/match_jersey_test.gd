extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if change_scene_to_file("res://match.tscn") != OK:
		push_error("Could not load match scene.")
		quit(1)
		return
	for _frame in range(5):
		await process_frame
	var world := current_scene
	var human := world.get_node("players/10100")
	var body := human.human_model.find_child("new_body", true, false) as MeshInstance3D
	var material := body.get_surface_override_material(0) as ShaderMaterial
	if material == null or material.get_shader_parameter("jersey_color") != human.HUMAN_MATCH_JERSEY_COLOR:
		push_error("Human match player does not have the yellow jersey material.")
		quit(1)
		return
	var arrays := body.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var covered := 0
	var uncovered_head := 0
	for i in range(vertices.size()):
		if vertices[i].y > 1.15 and vertices[i].y < 1.5 and colors[i].a > 0.9:
			covered += 1
		if vertices[i].y > 1.65 and colors[i].a < 0.1:
			uncovered_head += 1
	if covered == 0 or uncovered_head == 0 or body.skin == null:
		push_error("Jersey mask did not cover the torso while preserving the skinned head.")
		quit(1)
		return
	var robot := world.get_node("players/10000")
	var game := world.get_node("FootballMatchController")
	var manager := root.get_node("MatchManager")
	game.set_physics_process(false)
	var players := world.get_node("players")
	for player in players.get_children():
		player.set_physics_process(false)
		if player is CharacterBody3D:
			player.global_position = Vector3(25, 0, 25)
	human.global_position = Vector3.ZERO
	players.get_node("10101").global_position = Vector3(2, 0, 0)
	players.get_node("10102").global_position = Vector3(-2, 0, 0)
	players.get_node("10103").global_position = Vector3(0, 0, 2)
	for clip in game.FOOTBALL_MODEL_UTILS.GOAL_CELEBRATION_SCENES:
		if not human.animation_player.has_animation(clip) or not robot.animation_player.has_animation(clip):
			push_error("Celebration clip is missing for a match team: %s" % clip)
			quit(1)
			return
		var animation: Animation = human.animation_player.get_animation(clip)
		var skeleton := human.active_model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
		var hips_path := NodePath("%s:mixamorig_Hips" % human.active_model.get_path_to(skeleton))
		var position_track := animation.find_track(hips_path, Animation.TYPE_POSITION_3D)
		var rotation_track := animation.find_track(hips_path, Animation.TYPE_ROTATION_3D)
		if position_track < 0 or rotation_track < 0:
			push_error("Goal dance is missing its retargeted root motion: %s" % clip)
			quit(1)
			return
		var midpoint := animation.length * 0.5
		var hips := animation.position_track_interpolate(position_track, midpoint)
		if absf(hips.x) > 0.5 or hips.y < 0.2 or hips.y > 2.5:
			push_error("Goal dance moves the human model away from its body: %s %s" % [clip, hips])
			quit(1)
			return
		if clip != &"goal_flip" and Basis(animation.rotation_track_interpolate(rotation_track, midpoint)).y.dot(Vector3.UP) < 0.5:
			push_error("Standing goal dance has a tilted root: %s" % clip)
			quit(1)
			return
		var robot_animation: Animation = robot.animation_player.get_animation(clip)
		var robot_skeleton := robot.active_model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
		var robot_path: NodePath = robot.active_model.get_path_to(robot_skeleton)
		var root_delta := Quaternion.IDENTITY
		var have_root_delta := false
		for bone in range(robot_skeleton.get_bone_count()):
			if robot_skeleton.get_bone_parent(bone) >= 0:
				continue
			var path := NodePath("%s:%s" % [robot_path, robot_skeleton.get_bone_name(bone)])
			var track := robot_animation.find_track(path, Animation.TYPE_ROTATION_3D)
			if track < 0:
				push_error("Robot goal dance is missing a root bone: %s" % path)
				quit(1)
				return
			var delta: Quaternion = robot_animation.rotation_track_interpolate(track, midpoint) \
					* robot_skeleton.get_bone_rest(bone).basis.get_rotation_quaternion().inverse()
			if have_root_delta and absf(root_delta.dot(delta)) < 0.999:
				push_error("Robot goal dance root bones do not move together.")
				quit(1)
				return
			root_delta = delta
			have_root_delta = true
	if not human.animation_player.has_animation(&"goal_victory") or not robot.animation_player.has_animation(&"goal_victory"):
		push_error("Victory animation is missing from a match team.")
		quit(1)
		return
	var celebrations: Array = game.FOOTBALL_MODEL_UTILS.GOAL_CELEBRATION_SCENES.keys()
	var test_rng := RandomNumberGenerator.new()
	for seed_value in range(1000):
		test_rng.seed = seed_value
		if celebrations[test_rng.randi_range(0, celebrations.size() - 1)] == &"goal_flip":
			game.match_rng.seed = seed_value
			break
	game.last_ball_actor_name = human.name
	game._score_goal(human.team)
	var chosen := StringName(human.current_animation)
	if not game.FOOTBALL_MODEL_UTILS.GOAL_CELEBRATION_SCENES.has(chosen) \
			or not robot.goal_celebration_active \
			or human.animation_player.get_animation(chosen).loop_mode != Animation.LOOP_NONE:
		push_error("The scorer did not start a supplied celebration clip.")
		quit(1)
		return
	human.sync_animation("run", 1.0)
	if human.current_animation != String(chosen):
		push_error("An old movement animation interrupted the scorer's dance.")
		quit(1)
		return
	await create_timer(human.goal_celebration_duration(chosen) + 0.3).timeout
	var celebrating_teammates := 0
	for player in players.get_children():
		if player is CharacterBody3D and player.team == human.team and player != human and player.current_animation == "goal_victory":
			celebrating_teammates += 1
			if player.global_position.distance_to(human.global_position) > 1.5:
				push_error("A celebrating teammate did not reach the scorer.")
				quit(1)
				return
	if celebrating_teammates != 3 or human.current_animation != String(chosen) \
			or human.animation_player.is_playing() or not game.goal_celebration_active:
		push_error("Three teammates did not play Victory while the scorer danced.")
		quit(1)
		return
	await create_timer(maxf(human.goal_celebration_duration(chosen), human.goal_celebration_duration(&"goal_victory")) + 1.0).timeout
	if game.goal_celebration_active or game.kickoff_team != manager.TEAM_BLUE or not game.ball.freeze \
			or human.animation_player.get_animation(chosen).loop_mode != Animation.LOOP_NONE:
		push_error("Goal celebration did not prepare a human kickoff after the dance.")
		quit(1)
		return
	var kickoff_taker := players.get_node("10008") as CharacterBody3D
	game._handle_ball_action(1, kickoff_taker.name, Vector3.FORWARD, 0.5, 0.0, "pass")
	if game.ball.freeze or game.kickoff_team != -1:
		push_error("The human kickoff did not restart play.")
		quit(1)
		return
	human.sync_animation(String(chosen), 1.0)
	if human.current_animation != "Idle":
		push_error("A late celebration animation interrupted kickoff.")
		quit(1)
		return
	print("PASS yellow human jersey, random dance and three Victory teammates")
	world.queue_free()
	await process_frame
	quit(0)
