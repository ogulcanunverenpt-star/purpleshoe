extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
		quit(1)
	return condition

func _key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)

func _measure_dribble(game: Node, actor: CharacterBody3D, speed: float) -> Dictionary:
	game.game_started = false
	game.ball_owner_name = ""
	game.last_kick_control_until = 0
	actor.global_position = Vector3.ZERO
	actor.rotation.y = -PI / 2.0
	actor.velocity = Vector3(speed, 0.0, 0.0)
	game.ball.freeze = true
	game.ball.global_position = Vector3(0.65, game.BALL_RADIUS, 0.0)
	game.ball.linear_velocity = Vector3.ZERO
	game.ball.angular_velocity = Vector3.ZERO
	await physics_frame
	game.ball.freeze = false
	var sum_distance := 0.0
	var min_distance := INF
	var max_distance := 0.0
	for frame in range(150):
		await physics_frame
		actor.velocity = Vector3(speed, 0.0, 0.0)
		actor.move_and_slide()
		game._physics_process(1.0 / 60.0)
		game.update_player_dribble(actor, Vector3.RIGHT, 1.0 / 60.0)
		var distance: float = game.ball.global_position.x - actor.global_position.x
		if frame >= 15:
			sum_distance += distance
			min_distance = minf(min_distance, distance)
			max_distance = maxf(max_distance, distance)
	return {"mean": sum_distance / 135.0, "min": min_distance, "max": max_distance}

func _measure_pass_distance(game: Node, actor: CharacterBody3D, action: String) -> float:
	actor.global_position = Vector3.ZERO
	actor.velocity = Vector3.ZERO
	game.ball.freeze = true
	game.ball.global_position = game.BALL_START
	game.ball.linear_velocity = Vector3.ZERO
	game.ball.angular_velocity = Vector3.ZERO
	game.ball_owner_name = ""
	await physics_frame
	game.ball.freeze = false
	game._handle_ball_action(1, actor.name, Vector3.FORWARD, 0.65, 0.0, action)
	actor.global_position = Vector3(30, 0, 0)
	var distance := 0.0
	for _frame in range(180):
		await physics_frame
		distance = maxf(distance, -game.ball.global_position.z)
	return distance

func _run() -> void:
	Input.use_accumulated_input = false
	if change_scene_to_file("res://match.tscn") != OK:
		push_error("Could not load match scene.")
		quit(1)
		return
	for _frame in range(5):
		await process_frame
	var world := current_scene
	var game := world.get_node("FootballMatchController")
	var players := world.get_node("players")
	var manager := root.get_node("MatchManager")
	var center_circle := world.get_node("MatchEnvironment/CenterCircle") as MeshInstance3D
	var center_material := center_circle.material_override as StandardMaterial3D
	if not _check(center_circle.mesh != null and center_material != null and center_material.cull_mode == BaseMaterial3D.CULL_DISABLED, "Center circle is not visible from above."):
		return
	for sound_file in game.MATCH_AUDIO_SCRIPT.SOUND_FILES.values():
		var sound := load("res://match_audio/" + sound_file)
		if not _check(sound is AudioStream, "Match sound failed to load: %s" % sound_file):
			return
	for music_file in ["Football_2v3.mp3", "ucl_anthem.mp3", "madrid_goal.mp3"]:
		if not _check(load("res://match_audio/" + music_file) is AudioStream, "Match music failed to load: %s" % music_file):
			return
	var kickoff_player := players.get_node_or_null("10108") as CharacterBody3D
	if not _check(kickoff_player != null and kickoff_player.global_position.distance_to(Vector3(0, 0, -0.85)) < 0.1, "Initial kickoff player is not at the ball: %s" % (kickoff_player.global_position if kickoff_player else "missing")):
		return
	if not _check(game.ball.freeze and game.kickoff_team == manager.TEAM_RED, "Initial kickoff is not ready."):
		return
	var initial_keeper_positions := {}
	for child in players.get_children():
		if child is CharacterBody3D and child.role == manager.ROLE_GOALKEEPER:
			initial_keeper_positions[child.name] = child.global_position
	for half in [false, true]:
		game.second_half = half
		for kicking_team in [manager.TEAM_BLUE, manager.TEAM_RED]:
			game.kickoff_team = kicking_team
			game.reset_players_for_kickoff(kicking_team)
			for child in players.get_children():
				if child is CharacterBody3D:
					child.global_position = Vector3(0, 0, -game._own_half_sign(child.team) * 2.0)
			game._keep_opponents_out_of_center_circle()
			for child in players.get_children():
				if child is CharacterBody3D:
					var position: Vector3 = child.global_position
					if not _check(position.z * game._own_half_sign(child.team) >= 0.0 and (child.team == kicking_team or Vector2(position.x, position.z).length() >= game.CENTER_CIRCLE_RADIUS - 0.001), "Kickoff allowed a player across halfway or inside the opponents' center circle."):
						return
	game.second_half = false
	game.kickoff_team = manager.TEAM_RED
	game.reset_players_for_kickoff(game.kickoff_team)
	for player_name in initial_keeper_positions:
		players.get_node(String(player_name)).global_position = initial_keeper_positions[player_name]
	for child in players.get_children():
		if child is CharacterBody3D:
			child.set_physics_process(false)
			child.set_process(false)
			child.set_process_input(false)
			var slot: int = child.field_slot
			child.global_position = Vector3(-30.0 + float((slot + 1) % 10) * 5.0, 0.0, 35.0 if child.team == manager.TEAM_BLUE else -35.0)
	game.set_physics_process(false)
	game.kickoff_team = -1
	game.kickoff_delay = 0.0
	game.ball.freeze = true
	game.ball.global_position = Vector3(0, 2.0, 0)
	game.ball.linear_velocity = Vector3.ZERO
	await physics_frame
	game.ball.freeze = false
	var touched_ground := false
	var rebound_height := 0.0
	for _frame in range(150):
		await physics_frame
		if game.ball.global_position.y < 0.2:
			touched_ground = true
		if touched_ground:
			rebound_height = maxf(rebound_height, game.ball.global_position.y)
	if not _check(touched_ground and rebound_height >= 0.8, "Dropped ball did not visibly rebound: %s" % rebound_height):
		return
	game.ball.freeze = true
	game.ball.global_position = Vector3(0, 15, 0)
	game.ball.linear_velocity = Vector3.ZERO
	await physics_frame
	game.ball.freeze = false
	game.ball.linear_velocity = Vector3(3, -2, 0)
	touched_ground = false
	rebound_height = 0.0
	for _frame in range(250):
		await physics_frame
		if game.ball.global_position.y < 0.25:
			touched_ground = true
		if touched_ground:
			rebound_height = maxf(rebound_height, game.ball.global_position.y)
	if not _check(touched_ground and rebound_height >= 1.5 and rebound_height <= 3.5, "High ball rebound was too low or too high: %s" % rebound_height):
		return
	game.game_started = true
	game.last_ball_actor_name = ""
	game._restart_at_six_yard(Vector3(0, game.BALL_RADIUS, -game.FIELD_HALF_LENGTH - 1))
	var goal_kick_keeper := players.get_node(game.set_piece_taker_name) as CharacterBody3D
	game.ball.collision_mask = 1
	game._handle_ball_action(0, goal_kick_keeper.name, Vector3.BACK, 1.0, 0.0, "clearance", true)
	var goal_kick_apex := 0.0
	var post_bounce_speed := 0.0
	touched_ground = false
	rebound_height = 0.0
	for _frame in range(300):
		await physics_frame
		game._physics_process(1.0 / 60.0)
		goal_kick_apex = maxf(goal_kick_apex, game.ball.global_position.y)
		if not touched_ground and goal_kick_apex > 5.0 and game.ball.global_position.y < 0.25:
			touched_ground = true
			post_bounce_speed = absf(game.ball.linear_velocity.z)
		if touched_ground:
			rebound_height = maxf(rebound_height, game.ball.global_position.y)
		if touched_ground and game.ball.global_position.z > game.FIELD_HALF_LENGTH - 5.0:
			break
	if not _check(goal_kick_apex > 5.0 and touched_ground and rebound_height >= 1.5 and rebound_height <= 3.5 and post_bounce_speed > 10.0, "Goal kick rebound was too low or too high: apex=%s rebound=%s forward=%s" % [goal_kick_apex, rebound_height, post_bounce_speed]):
		return
	game.ball.collision_mask = 1 | 2
	game.ball.freeze = false
	game.ball.global_position = Vector3(0.0, 0.11, 0.0)
	var actor := players.get_node("10008") as CharacterBody3D
	var receiver := players.get_node("10007") as CharacterBody3D
	var other := players.get_node("10009") as CharacterBody3D
	actor.global_position = Vector3.ZERO
	receiver.global_position = Vector3(8.0, 0.0, 0.0)
	other.global_position = Vector3(0.0, 0.0, 8.0)
	game._set_local_selection(actor)
	game.controller_input_by_peer.clear()
	receiver.global_position = Vector3(30, 0, 35)
	other.global_position = Vector3(-30, 0, 35)
	game.ball.collision_mask = 1
	var pass_distance := await _measure_pass_distance(game, actor, "pass")
	var through_distance := await _measure_pass_distance(game, actor, "through")
	game.ball.collision_mask = 1 | 2
	if not _check(pass_distance >= 20.0 and through_distance >= 28.0 and through_distance > pass_distance, "Passes travelled too little: pass=%s through=%s" % [pass_distance, through_distance]):
		return
	game.ball.freeze = true
	game.ball.global_position = game.BALL_START
	game.ball.linear_velocity = Vector3.ZERO
	game.ball.angular_velocity = Vector3.ZERO
	await physics_frame
	game.ball.freeze = false
	game.ball_owner_name = ""
	actor.global_position = Vector3.ZERO
	receiver.global_position = Vector3(8, 0, 0)
	other.global_position = Vector3(0, 0, 8)
	game.cross_run_assignments[actor.name] = {"position": Vector3(20, 0, 0), "expires": Time.get_ticks_msec() + 10000}
	var selected_input: Dictionary = game.server_input_for(actor)
	if not _check(not selected_input.is_empty() and selected_input.get("move") == Vector2.ZERO, "Selected player was handed to the AI before input arrived."):
		return
	game.cross_run_assignments.clear()
	if not _check(game.can_local_shoot(), "Nearby selected player cannot pass or shoot."):
		return
	actor.set_process_input(true)
	game.ball_owner_name = actor.name
	_key(KEY_UP, true)
	_key(KEY_RIGHT, true)
	_key(KEY_D, true)
	_key(KEY_D, false)
	if not _check(game.ball.linear_velocity.x < -1.0 and game.ball.linear_velocity.z < -1.0, "A quick diagonal shot did not kick in the arrow direction."):
		return
	_key(KEY_UP, false)
	_key(KEY_RIGHT, false)
	for key_action in [{"key": KEY_D, "action": "shot"}, {"key": KEY_S, "action": "pass"}, {"key": KEY_W, "action": "through"}, {"key": KEY_A, "action": "cross"}]:
		game.ball.global_position = game.BALL_START
		game.ball.linear_velocity = Vector3.ZERO
		game.ball_owner_name = actor.name
		_key(KEY_F, true)
		_key(KEY_UP, true)
		_key(KEY_RIGHT, true)
		_key(key_action.key, true)
		actor._update_match_action_charge(0.5)
		if not _check(is_equal_approx(actor.selected_curve, 1.0 / sqrt(2.0)), "%s did not use the diagonal F curve." % key_action.action):
			return
		_key(KEY_F, false)
		_key(KEY_UP, false)
		_key(KEY_RIGHT, false)
		_key(key_action.key, false)
		if not _check(game.ball_curve > 0.7 and game.ball.angular_velocity.y > 10.0, "%s lost its F curve before release." % key_action.action):
			return
	game.ball.global_position = game.BALL_START
	game.ball_owner_name = actor.name
	_key(KEY_F, true)
	_key(KEY_LEFT, true)
	_key(KEY_S, true)
	_key(KEY_S, false)
	_key(KEY_LEFT, false)
	_key(KEY_F, false)
	if not _check(game.ball_curve < -0.99 and game.ball.angular_velocity.y < -15.0, "Left arrow did not curve the pass in the opposite direction."):
		return
	game.ball.freeze = true
	game.ball.global_position = Vector3(-0.46, game.BALL_RADIUS, -0.46)
	game.ball.linear_velocity = Vector3.ZERO
	await physics_frame
	game.ball.freeze = false
	game.ball_owner_name = actor.name
	game.last_kick_control_until = 0
	actor.global_position = Vector3.ZERO
	actor.velocity = Vector3.ZERO
	actor.match_movement_velocity = Vector3.ZERO
	game.controller_input_by_peer[1] = {"move": Vector2(-1, -1).normalized(), "sprint": true}
	_key(KEY_UP, true)
	_key(KEY_RIGHT, true)
	_key(KEY_E, true)
	_key(KEY_D, true)
	for _frame in range(60):
		await physics_frame
		actor._match_server_physics(1.0 / 60.0)
		actor._update_match_action_charge(1.0 / 60.0)
	_key(KEY_D, false)
	if not _check(actor.global_position.x < -2.0 and actor.global_position.z < -2.0 and game.ball_owner_name.is_empty() and game.ball.linear_velocity.x < -5.0 and game.ball.linear_velocity.z < -5.0, "Diagonal sprint shot failed: player=%s ball=%s owner=%s" % [actor.global_position, game.ball.linear_velocity, game.ball_owner_name]):
		return
	_key(KEY_UP, false)
	_key(KEY_RIGHT, false)
	_key(KEY_E, false)
	actor.set_process_input(false)
	actor.global_position = Vector3.ZERO
	actor.velocity = Vector3.ZERO
	actor.match_movement_velocity = Vector3.ZERO
	game.controller_input_by_peer.clear()
	game.ball.global_position = game.BALL_START
	game.ball.linear_velocity = Vector3.ZERO
	game.ball_owner_name = ""
	var saved_positions := {}
	for child in players.get_children():
		if child is CharacterBody3D:
			saved_positions[child.name] = child.global_position
	for wall_case in [{"position": Vector3(0, game.BALL_RADIUS, 10), "size": 0}, {"position": Vector3(0, game.BALL_RADIUS, -10), "size": 1}, {"position": Vector3(0, game.BALL_RADIUS, -25.9), "size": 1}, {"position": Vector3(0, game.BALL_RADIUS, -26.0), "size": 4}, {"position": Vector3(30, game.BALL_RADIUS, -30), "size": 1}]:
		actor.global_position = wall_case.position + Vector3(0, -game.BALL_RADIUS, 1.5)
		game._start_free_kick(wall_case.position, actor.team, "TEST")
		if not _check(game.set_piece_wall.size() == wall_case.size, "Wrong wall for %s: %s" % [wall_case.position, game.set_piece_wall.size()]):
			return
		if not _check((not game.set_piece_formation.is_empty()) == (wall_case.position.z < 0), "Free-kick formation used in the wrong half."):
			return
		game._enforce_set_piece_spacing()
		if wall_case.position.z < 0:
			var placed_teams := {}
			for player_name in game.set_piece_formation:
				var placed := players.get_node(String(player_name)) as CharacterBody3D
				var target: Vector3 = game.set_piece_formation[player_name]
				var depth: float = game.FIELD_HALF_LENGTH - target.z * game._attack_sign(actor.team)
				if not _check(placed.role == manager.ROLE_PLAYER and player_name != game.set_piece_taker_name and not game.set_piece_wall.has(player_name) and absf(target.x) < game.PENALTY_AREA_HALF_WIDTH and depth >= 0.0 and depth <= game.PENALTY_AREA_DEPTH, "Free-kick player is not dispersed in the attacking penalty area."):
					return
				if placed.team != actor.team and not _check(Vector2(target.x - wall_case.position.x, target.z - wall_case.position.z).length() >= game.FREE_KICK_DEFENDER_DISTANCE, "Free-kick defender is too close to the ball."):
					return
				placed_teams[placed.team] = true
				if not _check(game.server_input_for(placed).world_move == Vector3.ZERO, "Free-kick formation player was not held in position."):
					return
			if not _check(placed_teams.has(actor.team) and placed_teams.size() == 2, "Free-kick formation did not include both teams."):
				return
		for wall_player_name in game.set_piece_wall:
			var wall_player := players.get_node(String(wall_player_name)) as CharacterBody3D
			var wall_distance := Vector2(wall_player.global_position.x - game.ball.global_position.x, wall_player.global_position.z - game.ball.global_position.z).length()
			if not _check(wall_player.team != actor.team and wall_player.role == manager.ROLE_PLAYER and wall_distance >= game.FREE_KICK_DEFENDER_DISTANCE and game.server_input_for(wall_player).world_move == Vector3.ZERO, "Free-kick wall is incorrectly positioned or moving."):
				return
	var other_taker := receiver if game.set_piece_taker_name != receiver.name else other
	other_taker.global_position = game.ball.global_position
	game._handle_ball_action(0, other_taker.name, Vector3.FORWARD, 0.5, 0.0, "pass", true)
	if not _check(game.set_piece_active and game.ball.freeze, "A non-taker could take the free kick."):
		return
	game._start_free_kick(Vector3(0, game.BALL_RADIUS, -41.5), actor.team, "PENALTY", "penalty")
	if not _check(game.set_piece_wall.is_empty(), "A penalty should not create a wall."):
		return
	if not _check(game.set_piece_formation.is_empty(), "A penalty should not use the free-kick formation."):
		return
	for half in [false, true]:
		game.second_half = half
		for side in [-1.0, 1.0]:
			var defending_team: int = manager.TEAM_RED
			var goal_sign: float = game._own_half_sign(defending_team)
			game._start_corner_kick(Vector3(side * game.FIELD_HALF_WIDTH, game.BALL_RADIUS, goal_sign * game.FIELD_HALF_LENGTH), defending_team)
			var taker := players.get_node(game.set_piece_taker_name) as CharacterBody3D
			var inside := 0
			var behind := 0
			if not _check(game.set_piece_formation.size() == 8, "Corner did not place eight attackers."):
				return
			for player_name in game.set_piece_formation:
				var placed := players.get_node(String(player_name)) as CharacterBody3D
				var target: Vector3 = game.set_piece_formation[player_name]
				var depth: float = game.FIELD_HALF_LENGTH - target.z * goal_sign
				if not _check(placed.team == taker.team and placed.role == manager.ROLE_PLAYER and placed != taker and absf(target.x) < game.PENALTY_AREA_HALF_WIDTH and Vector2(placed.global_position.x, placed.global_position.z).is_equal_approx(Vector2(target.x, target.z)), "Corner attacker was placed incorrectly."):
					return
				if depth <= game.PENALTY_AREA_DEPTH:
					inside += 1
				else:
					behind += 1
				placed.global_position.x += 3.0
			game._enforce_set_piece_spacing()
			for player_name in game.set_piece_formation:
				var placed := players.get_node(String(player_name)) as CharacterBody3D
				var target: Vector3 = game.set_piece_formation[player_name]
				if not _check(Vector2(placed.global_position.x, placed.global_position.z).is_equal_approx(Vector2(target.x, target.z)), "Corner formation did not hold before the kick."):
					return
			if not _check(inside > 0 and behind > 0, "Corner formation did not cover the box and its edge."):
				return
			game.start_ball_action(Vector3(0, 1, -goal_sign * 10), 0.0, "cross", taker.name)
			if not _check(game.set_piece_formation.is_empty() and not game.set_piece_active, "Corner formation remained locked after the kick."):
				return
	game.second_half = true
	actor.global_position = Vector3(0, 0, 28.5)
	game._start_free_kick(Vector3(0, game.BALL_RADIUS, 30), actor.team, "TEST")
	if not _check(game.set_piece_wall.size() == 4, "Second-half wall used the wrong attacking direction."):
		return
	if not _check(not game.set_piece_formation.is_empty(), "Second-half attacking free kick did not place players in the penalty area."):
		return
	for target in game.set_piece_formation.values():
		if not _check(target.z > game.FIELD_HALF_LENGTH - game.PENALTY_AREA_DEPTH, "Second-half free-kick formation used the wrong goal."):
			return
	game.second_half = false
	game.reset_ball(game.BALL_START, "restart")
	game.set_piece_timer = 0.0
	game.kickoff_delay = 0.0
	game.ball.freeze = false
	var test_keeper := players.get_node("10010") as CharacterBody3D
	var ai_keeper := players.get_node("10110") as CharacterBody3D
	game._set_local_selection(test_keeper)
	game.diving_peers.clear()
	game.ball.global_position = Vector3(0, game.BALL_RADIUS, game.FIELD_HALF_LENGTH - game.SIX_YARD_DEPTH - 0.1)
	game._start_keeper_dive(1, test_keeper.name, 1)
	if not _check(not game.diving_peers.has(test_keeper.name), "Goalkeeper dived outside the six-yard box."):
		return
	game.ball.global_position.z = game.FIELD_HALF_LENGTH - game.SIX_YARD_DEPTH + 0.1
	_key(KEY_SPACE, true)
	test_keeper.match_input_sync_timer = 0.0
	test_keeper._submit_match_input(0.1)
	test_keeper._update_match_local_process(0.016)
	_key(KEY_SPACE, false)
	if not _check(game.diving_peers.has(test_keeper.name), "Goalkeeper did not dive inside the six-yard box."):
		return
	game.diving_peers.clear()
	game.ball.global_position = Vector3(9.3, game.BALL_RADIUS, -48)
	game.start_ai_keeper_dive(ai_keeper)
	if not _check(not game.diving_peers.has(ai_keeper.name), "AI goalkeeper dived outside the side of the six-yard box."):
		return
	game.ball.global_position.x = 0.0
	game.start_ai_keeper_dive(ai_keeper)
	if not _check(game.diving_peers.has(ai_keeper.name), "AI goalkeeper could not dive inside the six-yard box."):
		return
	game.second_half = true
	if not _check(game._ball_in_keeper_six_yard_box(test_keeper) and not game._ball_in_keeper_six_yard_box(ai_keeper), "Six-yard goalkeeper restriction did not switch sides at halftime."):
		return
	game.second_half = false
	game.diving_peers.clear()
	test_keeper.set_diving_local(false, 0)
	ai_keeper.set_diving_local(false, 0)
	test_keeper.global_position = Vector3(20, 0, 0)
	game.ball.freeze = true
	game.ball.global_position = Vector3(20, 0.9, 1.3)
	game.ball.linear_velocity = Vector3.ZERO
	await physics_frame
	game.ball.freeze = false
	await physics_frame
	ai_keeper.global_position = Vector3(20, 0, 0)
	var action_serial: int = game.ball_action_serial
	game._handle_ball_action(0, ai_keeper.name, Vector3.FORWARD, 1.0, 0.0, "clearance", true)
	if not _check(game.ball_action_serial == action_serial, "AI goalkeeper cleared a ball without touching it."):
		return
	ai_keeper.global_position = saved_positions[ai_keeper.name]
	game._handle_ball_action(1, test_keeper.name, Vector3.FORWARD, 1.0, 0.0, "clearance")
	if not _check(game.ball.linear_velocity.length() < 2.0, "Goalkeeper cleared a ball without touching it."):
		return
	game.ball.freeze = true
	game.ball.global_position = Vector3(20, 0.9, 0.4)
	game.ball.linear_velocity = Vector3.ZERO
	await physics_frame
	game.ball.freeze = false
	for _frame in range(3):
		await physics_frame
	if not _check(game.ball.get_colliding_bodies().has(test_keeper), "Test ball did not contact the goalkeeper."):
		return
	game.diving_peers[test_keeper.name] = Time.get_ticks_msec() + 750
	test_keeper.is_diving = true
	game._on_ball_body_entered(test_keeper)
	if not _check(not game.ball.freeze and game.set_piece_timer <= 0.0, "A diving goalkeeper automatically stopped the ball on contact."):
		return
	test_keeper.is_diving = false
	game.diving_peers.clear()
	game._handle_ball_action(1, test_keeper.name, Vector3.FORWARD, 1.0, 0.0, "clearance")
	if not _check(game.ball.linear_velocity.length() > 10.0, "Goalkeeper could not clear a ball on contact."):
		return
	game._clear_kicker_collision_exception()
	var keeper_rotation := test_keeper.rotation
	test_keeper.rotation = Vector3.ZERO
	test_keeper.set_diving_local(true, 1)
	game.ball.gravity_scale = 0.0
	game.ball.collision_mask = 2
	for shot in [{"x": 20.0, "should_bounce": false}, {"x": 20.9, "should_bounce": true}]:
		game.ball.freeze = true
		game.ball.global_position = Vector3(shot.x, 0.9, 3.0)
		game.ball.linear_velocity = Vector3.ZERO
		await physics_frame
		game.ball.freeze = false
		game.ball.linear_velocity = Vector3.FORWARD * 10.0
		for _frame in range(35):
			await physics_frame
		if not _check(not game.ball.freeze and (game.ball.linear_velocity.z > 0.0) == shot.should_bounce, "Dive collision did not match the goalkeeper's position: %s" % shot):
			return
	test_keeper.set_diving_local(false, 0)
	test_keeper.rotation = keeper_rotation
	game.ball.gravity_scale = 1.0
	game.ball.collision_mask = 1 | 2
	for player_name in saved_positions:
		players.get_node(String(player_name)).global_position = saved_positions[player_name]
	game._set_local_selection(actor)
	game.ball_owner_name = ""
	var sprint_key := InputEventKey.new()
	sprint_key.keycode = KEY_E
	sprint_key.pressed = true
	Input.parse_input_event(sprint_key)
	var move_key := InputEventKey.new()
	move_key.keycode = KEY_DOWN
	move_key.pressed = true
	Input.parse_input_event(move_key)
	for key_action in [{"key": KEY_S, "action": "pass"}, {"key": KEY_W, "action": "through"}, {"key": KEY_D, "action": "shot"}, {"key": KEY_A, "action": "cross"}]:
		game.ball.freeze = false
		game.ball.global_position = Vector3(0, game.BALL_RADIUS, 0)
		game.ball.linear_velocity = Vector3.ZERO
		game.ball_owner_name = ""
		var key := InputEventKey.new()
		key.keycode = key_action.key
		key.pressed = true
		Input.parse_input_event(key)
		await process_frame
		actor._update_match_action_charge(0.3)
		game.ball_owner_name = other.name
		actor._update_match_action_charge(0.1)
		if not _check(actor.charging_action == key_action.action and game.ball.linear_velocity.length() < 0.1, "Charging %s ended before its key was released." % key_action.action):
			return
		game.ball_owner_name = ""
		key.pressed = false
		Input.parse_input_event(key.duplicate())
		await process_frame
		actor._update_match_action_charge(0.0)
		if not _check(game.ball.linear_velocity.length() > 3.0 and game.last_ball_actor_name == actor.name, "%s failed on release while sprinting." % key_action.action):
			return
		if not _check(game.ball.get_collision_exceptions().has(actor), "Kicker can immediately collide with their own %s." % key_action.action):
			return
	game.last_kick_control_until = 0
	game.game_started = false
	game._physics_process(0.0)
	game.game_started = true
	if not _check(not game.ball.get_collision_exceptions().has(actor), "Kicker collision exception did not expire."):
		return
	sprint_key.pressed = false
	move_key.pressed = false
	Input.parse_input_event(sprint_key)
	Input.parse_input_event(move_key)
	actor.global_position = Vector3.ZERO
	actor.rotation.y = -PI / 2.0
	actor.velocity = Vector3.ZERO
	actor.match_movement_velocity = Vector3.ZERO
	game.ball.freeze = true
	game.ball.global_position = Vector3(0.65, game.BALL_RADIUS, 0)
	game.ball.linear_velocity = Vector3.ZERO
	await physics_frame
	game.ball.freeze = false
	game.ball_owner_name = actor.name
	game.last_kick_control_until = 0
	game.controller_input_by_peer[1] = {"move": Vector2.RIGHT, "sprint": true}
	sprint_key.pressed = true
	move_key.pressed = true
	var running_pass := InputEventKey.new()
	running_pass.keycode = KEY_S
	running_pass.pressed = true
	Input.parse_input_event(sprint_key)
	Input.parse_input_event(move_key)
	Input.parse_input_event(running_pass)
	await process_frame
	for _frame in range(60):
		await physics_frame
		actor._match_server_physics(1.0 / 60.0)
		actor._update_match_action_charge(1.0 / 60.0)
	if not _check(actor.global_position.x > 4.0 and game.ball_owner_name == actor.name, "Sprinting dribble lost possession before the pass."):
		return
	running_pass.pressed = false
	Input.parse_input_event(running_pass)
	Input.flush_buffered_events()
	await process_frame
	actor._update_match_action_charge(0.0)
	if not _check(game.ball.linear_velocity.x > actor.velocity.x and game.ball_owner_name.is_empty(), "Running pass did not leave the sprinting player: ball=%s player=%s owner=%s charge=%s key=%s mobile=%s button=%s" % [game.ball.linear_velocity, actor.velocity, game.ball_owner_name, actor.charging_action, Input.is_key_pressed(KEY_S), actor.mobile_ui.visible, actor.pass_button.is_pressed()]):
		return
	sprint_key.pressed = false
	move_key.pressed = false
	Input.parse_input_event(sprint_key)
	Input.parse_input_event(move_key)
	actor.global_position = Vector3.ZERO
	actor.velocity = Vector3.ZERO
	actor.match_movement_velocity = Vector3.ZERO
	game.controller_input_by_peer.clear()
	game.reset_ball(game.BALL_START, "restart")
	if not _check(not game.ball.get_collision_exceptions().has(actor), "Restart retained the previous kicker collision exception."):
		return
	for key_action in [{"key": KEY_S, "action": "pass", "kind": "throw_in"}, {"key": KEY_W, "action": "through", "kind": "free_kick"}, {"key": KEY_D, "action": "shot", "kind": "free_kick"}, {"key": KEY_A, "action": "cross", "kind": "corner"}]:
		game.reset_ball(game.BALL_START, "restart")
		game.begin_set_piece(actor.name, Vector3(-1.5, 0, 0), Vector3.RIGHT, key_action.kind)
		game.kickoff_delay = 1.0
		var key := InputEventKey.new()
		key.keycode = key_action.key
		key.pressed = true
		Input.parse_input_event(key)
		await process_frame
		actor._update_match_action_charge(0.5)
		key.pressed = false
		Input.parse_input_event(key)
		await process_frame
		actor._update_match_action_charge(0.0)
		if not _check(not game.set_piece_active and not game.ball.freeze and game.ball.linear_velocity.length() > 3.0 and game.ball.linear_velocity.y > 0.0, "Set piece %s did not kick on release." % key_action.action):
			return
	for player_name in saved_positions:
		players.get_node(String(player_name)).global_position = saved_positions[player_name]
	var keeper := players.get_node("10010") as CharacterBody3D
	var keeper_position := keeper.global_position
	game.reset_ball(game.BALL_START, "restart")
	game.begin_set_piece(keeper.name, Vector3(-1.3, 0, 0), Vector3.RIGHT, "goal_kick")
	game.kickoff_delay = 1.0
	var keeper_key := InputEventKey.new()
	keeper_key.keycode = KEY_D
	keeper_key.pressed = true
	Input.parse_input_event(keeper_key)
	await process_frame
	keeper._update_match_action_charge(0.5)
	keeper_key.pressed = false
	Input.parse_input_event(keeper_key)
	await process_frame
	keeper._update_match_action_charge(0.0)
	if not _check(not game.set_piece_active and not game.ball.freeze and game.ball.linear_velocity.length() > 10.0, "Goalkeeper could not take the goal kick."):
		return
	keeper.global_position = keeper_position
	game._set_local_selection(actor)
	actor.global_position = Vector3.ZERO
	game.ball.global_position = Vector3(0, game.BALL_RADIUS, 0)
	game.ball.linear_velocity = Vector3.ZERO
	game.ball_owner_name = ""
	game.kickoff_delay = 0.0
	game.set_piece_timer = 0.0
	other.global_position = Vector3(0.1, 0, 0)
	game.ball_owner_name = actor.name
	var q_key := InputEventKey.new()
	q_key.keycode = KEY_Q
	q_key.pressed = true
	Input.parse_input_event(q_key)
	await process_frame
	var through_key := InputEventKey.new()
	through_key.keycode = KEY_W
	through_key.pressed = true
	Input.parse_input_event(through_key)
	await process_frame
	actor._update_match_action_charge(0.5)
	q_key.pressed = false
	Input.parse_input_event(q_key)
	await process_frame
	if not _check(game.get_local_selected_player() == actor and actor.charging_action == "lofted_through", "Q+W switched players or lost the lofted pass."):
		return
	through_key.pressed = false
	Input.parse_input_event(through_key)
	await process_frame
	actor._update_match_action_charge(0.0)
	if not _check(game.ball.linear_velocity.y > 2.0, "Lofted through ball did not kick on release."):
		return
	other.global_position = Vector3(0.0, 0.0, 8.0)
	game.ball.global_position = Vector3(0, game.BALL_RADIUS, 0)
	game.ball.linear_velocity = Vector3.ZERO
	game.ball_owner_name = ""
	if not _check(game._pass_receiver(actor, Vector3.RIGHT, 30.0) == receiver, "Pass assist chose the wrong teammate."):
		return
	game._handle_ball_action(1, actor.name, Vector3.RIGHT, 0.5, 0.0, "pass")
	if not _check(game.ball.linear_velocity.x > 5.0 and absf(game.ball.linear_velocity.z) < 0.1, "Pass was not kicked toward the selected teammate: %s" % game.ball.linear_velocity):
		return
	var pass_velocity: Vector3 = game.ball.linear_velocity
	game.update_player_dribble(actor, Vector3.RIGHT, 0.016)
	if not _check(game.ball.linear_velocity.is_equal_approx(pass_velocity), "The passer immediately intercepted their own pass."):
		return
	game._handle_ball_action(1, actor.name, Vector3.RIGHT, 1.0, 0.0, "pass")
	if not _check(game.ball.linear_velocity.x > pass_velocity.x, "Holding a pass did not increase its power."):
		return
	game.ball.linear_velocity = Vector3.ZERO
	game.ball.global_position = Vector3(0, 0.11, 0)
	var down := InputEventKey.new()
	down.keycode = KEY_DOWN
	down.pressed = true
	Input.parse_input_event(down)
	var pass_key := InputEventKey.new()
	pass_key.keycode = KEY_S
	pass_key.pressed = true
	Input.parse_input_event(pass_key)
	await process_frame
	actor._update_match_action_charge(0.5)
	pass_key.pressed = false
	Input.parse_input_event(pass_key)
	await process_frame
	actor._update_match_action_charge(0.0)
	down.pressed = false
	Input.parse_input_event(down)
	if not _check(game.ball.linear_velocity.x > 5.0, "S and the direction keys did not produce a pass."):
		return
	receiver.contact_impulse = Vector3.ZERO
	game._on_ball_body_entered(receiver)
	if not _check(receiver.contact_impulse.is_zero_approx(), "Receiving a pass knocked over the teammate."):
		return
	game.ball.global_position = Vector3(0, game.BALL_RADIUS, 0)
	game.ball.linear_velocity = Vector3.ZERO
	receiver.velocity = Vector3(0, 0, -5)
	game._handle_ball_action(1, actor.name, Vector3.RIGHT, 0.7, 0.0, "through")
	if not _check(game.ball.linear_velocity.z < -0.5 and game.cross_run_assignments.has(receiver.name), "Through ball did not lead the moving receiver into space."):
		return
	game.cross_run_assignments.clear()
	var curve_force: Vector3 = game._magnus_force(Vector3.UP * 10.0, Vector3.RIGHT * 20.0)
	if not _check(curve_force.z < 0.0 and game._magnus_force(Vector3.ZERO, Vector3.RIGHT).is_zero_approx(), "Magnus force has the wrong direction or acts without spin."):
		return
	game.controller_input_by_peer[1] = {"move": Vector2.ZERO, "contain": true}
	game.first_touch_cooldowns.clear()
	game.ball.linear_velocity = Vector3(10, 0, 0)
	game._apply_first_touch(actor)
	game._update_ball_trap(0.05)
	if not _check(game.ball.linear_velocity.x < 10.0 and game.ball.linear_velocity.x > 0.0, "Control input did not smoothly trap an incoming ball."):
		return
	game.controller_input_by_peer[1] = {"move": Vector2.ZERO, "contain": false}
	game.first_touch_cooldowns.clear()
	actor.velocity = Vector3(8, 0, 0)
	game.ball.linear_velocity = Vector3(10, 0, 0)
	game._apply_first_touch(actor)
	if not _check(game.ball.linear_velocity.y > 0.3, "Fast first touch did not deflect the ball."):
		return
	game.first_touch_cooldowns.clear()
	game.ball.linear_velocity = Vector3.RIGHT
	game._apply_first_touch(actor)
	if not _check(game.ball.linear_velocity.y > 0.3, "Sprinting did not deflect a slow incoming ball."):
		return
	actor.velocity = Vector3.ZERO
	actor.contact_impulse = Vector3.ZERO
	actor.match_movement_velocity = Vector3.ZERO
	actor.tackle_stun_timer = 0.0
	actor.global_position = Vector3(-25, 0, 10)
	game.ball.freeze = true
	game.controller_input_by_peer[1] = {"move": Vector2.RIGHT, "sprint": false}
	await physics_frame
	actor._match_server_physics(0.1)
	if not _check(actor.velocity.x > 0.1 and actor.velocity.x < actor.SPEED, "Movement accelerated instantly instead of building momentum: velocity=%s movement=%s selected=%s stun=%s position=%s" % [actor.velocity, actor.match_movement_velocity, game.selected_entity_by_peer, actor.tackle_stun_timer, actor.global_position]):
		return
	game.controller_input_by_peer[1] = {"move": Vector2.ZERO}
	actor._match_server_physics(0.02)
	if not _check(actor.velocity.x > 0.0, "Movement stopped instantly instead of decelerating."):
		return
	actor.match_movement_velocity = Vector3.ZERO
	actor.contact_impulse = Vector3(2, 0, 0)
	actor._match_server_physics(0.05)
	var first_push_speed: float = actor.velocity.x
	actor._match_server_physics(0.05)
	if not _check(actor.velocity.x < first_push_speed, "Contact impulses accumulated across movement frames."):
		return
	actor.contact_impulse = Vector3.ZERO
	var opponent := players.get_node("10108") as CharacterBody3D
	game.ball.global_position = Vector3(0, game.BALL_RADIUS, 0)
	actor.global_position = Vector3(2, 0, 0)
	other.global_position = Vector3(6, 0, 0)
	opponent.global_position = Vector3.ZERO
	if not _check(game._ai_tactical_state(actor) == game.AIState.PRESS and game._ai_tactical_state(other) == game.AIState.COVER, "Defensive AI did not restrict pressing to the closest player."):
		return
	actor.global_position = Vector3.ZERO
	opponent.global_position = Vector3(20, 0, 20)
	if not _check(game._ai_tactical_state(actor) == game.AIState.DRIBBLE and game._ai_tactical_state(other) == game.AIState.ATTACK_RUN, "Off-ball teammate did not switch to an attacking run."):
		return
	other.global_position = Vector3(0, 0, 8)
	actor.global_position = Vector3.ZERO
	actor.velocity = Vector3.ZERO
	game.ball.global_position = Vector3(0.8, game.BALL_RADIUS, 0)
	game.ball.linear_velocity = Vector3.ZERO
	game.ball.freeze = false
	var power_events := {"count": 0}
	actor.power_shot_triggered.connect(func(): power_events.count += 1)
	var shift_key := InputEventKey.new()
	shift_key.keycode = KEY_SHIFT
	shift_key.pressed = true
	var shot_key := InputEventKey.new()
	shot_key.keycode = KEY_D
	shot_key.pressed = true
	Input.parse_input_event(shift_key)
	Input.parse_input_event(shot_key)
	await process_frame
	actor._update_match_action_charge(1.0)
	shift_key.pressed = false
	Input.parse_input_event(shift_key.duplicate())
	await process_frame
	actor._update_match_action_charge(0.0)
	if not _check(actor.charging_action == "power_shot", "Releasing Shift early changed the charged power shot."):
		return
	shot_key.pressed = false
	Input.parse_input_event(shot_key.duplicate())
	await process_frame
	actor._update_match_action_charge(0.0)
	if not _check(game.ball.linear_velocity.length() < 1.0, "Power shot skipped the wind-up."):
		return
	await create_timer(game.POWER_SHOT_WINDUP + 0.1).timeout
	await physics_frame
	if not _check(power_events.count == 1 and game.ball.linear_velocity.length() > 25.0 and world.camera_shake_remaining > 0.0, "Power shot or its camera signal did not trigger."):
		return
	world.stadium_camera.fov = 45.0
	world._process(0.1)
	if not _check(world.stadium_camera.fov > 45.0, "Broadcast camera did not respond to ball speed."):
		return
	var camera_position: Vector3 = world.stadium_camera.global_position
	var time_scale := Engine.time_scale
	world.focus_goal_scorer(actor.name)
	world._process(0.05)
	if not _check(world.stadium_camera.global_position.is_equal_approx(camera_position) and Engine.time_scale == time_scale, "Goal camera hold changed the simulation or failed to hold."):
		return
	world.restore_stadium_camera()
	game.ball.freeze = true
	game.ball.global_position = Vector3(0.8, game.BALL_RADIUS, 0)
	game.ball.linear_velocity = Vector3.ZERO
	await physics_frame
	game.ball.freeze = false
	game._handle_ball_action(1, actor.name, Vector3.RIGHT, 1.0, 0.0, "power_shot")
	actor.global_position = Vector3(-5, 0, 0)
	await create_timer(game.POWER_SHOT_WINDUP + 0.1).timeout
	if not _check(power_events.count == 1 and game.ball.linear_velocity.length() < 3.0, "Power shot was not cancelled after losing the ball."):
		return
	actor.global_position = Vector3.ZERO
	other.global_position = Vector3.ZERO
	game._resolve_player_contacts()
	if not _check(actor.global_position.distance_to(other.global_position) >= game.PLAYER_SEPARATION - 0.001, "Overlapping teammates were not separated."):
		return
	if not _check(game._teammate_avoidance(actor).length_squared() > 0.01, "AI does not avoid nearby teammates."):
		return
	other.global_position = Vector3(0.0, 0.0, 8.0)
	actor.global_position = Vector3.ZERO
	actor.velocity = Vector3(2.0, 0.0, 0.0)
	actor.rotation.y = -PI / 2.0
	game.ball.global_position = Vector3(1.15, game.BALL_RADIUS, 0.0)
	game.ball.linear_velocity = Vector3.ZERO
	game.last_kick_control_until = 0
	game.ball_owner_name = ""
	game.update_player_dribble(actor, Vector3.RIGHT, 1.0 / 60.0)
	if not _check(game.ball_owner_name.is_empty(), "Player controlled a ball outside the trap area."):
		return
	actor.velocity = Vector3(8.0, 0.0, 0.0)
	game.ball.global_position = Vector3(0.65, game.BALL_RADIUS, 0)
	var ball_position: Vector3 = game.ball.global_position
	game.update_player_dribble(actor, Vector3.RIGHT, 1.0 / 60.0)
	if not _check(game.ball_owner_name == actor.name and game.ball.linear_velocity.x > 7.0 and game.ball.global_position.is_equal_approx(ball_position), "Trapped ball did not follow its owner using physics."):
		return
	game.update_player_dribble(other, Vector3.LEFT, 1.0 / 60.0)
	if not _check(game.ball_owner_name == actor.name, "Another player took a trapped ball without a tackle."):
		return
	game._handle_ball_action(1, actor.name, Vector3.RIGHT, 0.5, 0.0, "pass")
	if not _check(game.ball_owner_name.is_empty(), "Passing did not release possession."):
		return
	receiver.global_position = Vector3(8.0, 0.0, 20.0)
	var walking: Dictionary = await _measure_dribble(game, actor, 5.0)
	var sprinting: Dictionary = await _measure_dribble(game, actor, 8.0)
	if not _check(walking.min >= 0.25 and walking.max <= 1.1, "Walking dribble lost control: %s" % walking):
		return
	if not _check(sprinting.min >= 0.25 and sprinting.max <= 1.1, "Sprinting dribble lost control: %s" % sprinting):
		return
	game.game_started = true
	game.goal_celebration_active = true
	game._start_second_half()
	var blue_keeper := players.get_node("10010") as CharacterBody3D
	var red_keeper := players.get_node("10110") as CharacterBody3D
	if not _check(game.second_half and game._attack_sign(manager.TEAM_BLUE) == 1.0 and game._team_attacking_goal(1.0) == manager.TEAM_BLUE, "Second half did not switch attack directions and goal attribution."):
		return
	if not _check(blue_keeper.global_position.z < 0.0 and red_keeper.global_position.z > 0.0 and kickoff_player.global_position.z > 0.0, "Second half did not switch both teams' sides."):
		return
	if not _check(game.ball.freeze and game.kickoff_team == manager.TEAM_BLUE and not game.goal_celebration_active, "Second half did not resume with the other team's kickoff."):
		return
	print("PASS: possession, passing, tactical AI, halftime and match audio resources")
	quit(0)
