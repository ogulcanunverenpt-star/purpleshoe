extends Node

const BALL_SCENE = preload("res://footballsoccer_ball.glb")
const GOAL_SCENE = preload("res://football_goal.glb")
const FIELD_HALF_WIDTH := 34.0
const FIELD_HALF_LENGTH := 52.5
const BOUNDARY_WALL_HEIGHT := 24.0
const GOAL_HALF_WIDTH := 3.66
const GOAL_HEIGHT := 2.44
const PENALTY_AREA_HALF_WIDTH := 20.15
const PENALTY_AREA_DEPTH := 16.5
const SIX_YARD_DEPTH := 5.5
const PENALTY_SPOT_DISTANCE := 11.0
const PENALTY_ARC_RADIUS := 9.15
const CENTER_CIRCLE_RADIUS := 9.15
const FREE_KICK_DEFENDER_DISTANCE := 10.0
const CORNER_ARC_RADIUS := 1.0
const BALL_RADIUS := 0.11
const BALL_START := Vector3(0.0, BALL_RADIUS, 0.0)
const RED_GOAL_LINE_Z := -FIELD_HALF_LENGTH
const BLUE_GOAL_LINE_Z := FIELD_HALF_LENGTH
const BALL_LAYER := 4
const TACKLE_SPEED := 9.0
const TEAM_BLUE_COLOR := Color(0.08, 0.34, 0.95)
const TEAM_RED_COLOR := Color(0.9, 0.08, 0.12)

@onready var players: Node3D = $"../players"
@onready var ground: CSGBox3D = $"../CSGBox3D"
@onready var match_environment: Node3D = $"../MatchEnvironment"

var ball: RigidBody3D
var goal_nets: Dictionary = {}
var blue_score := 0
var red_score := 0
var match_clock := 300.0
var game_started := false
var kickoff_delay := 0.0
var goal_celebration_active := false
var set_piece_timer := 0.0
var set_piece_active := false
var set_piece_taker_name := ""
var set_piece_direction := Vector3.FORWARD
var set_piece_kind := ""
var foul_cooldown_until := 0
var restart_position := BALL_START
var ball_curve := 0.0
var kickoff_team := -1
var kickoff_wait := 0.0
var last_ball_actor_name := ""
var sync_timer := 0.0
var clock_sync_timer := 0.0
var last_ball_position := BALL_START
var diving_peers: Dictionary = {}
var contact_cooldowns: Dictionary = {}
var match_rng := RandomNumberGenerator.new()
var selected_entity_by_peer: Dictionary = {}
var controller_input_by_peer: Dictionary = {}
var offside_team := -1
var offside_candidates: Dictionary = {}
var local_selected_entity: CharacterBody3D
var cross_run_assignments: Dictionary = {}
var ai_action_cooldowns: Dictionary = {}
var ai_tackle_cooldowns: Dictionary = {}
var ai_keeper_dive_cooldowns: Dictionary = {}
var ai_ball_action_cooldown_until := 0
var local_q_held := false
var local_g_held := false
var waiting_label: Label
var scoreboard_home_score: Label
var scoreboard_away_score: Label
var scoreboard_clock: Label
var action_label: Label
var match_end_label: Label
var power_bar: ProgressBar
var aim_indicator: MeshInstance3D
var aim_indicator_mesh: ImmediateMesh
var aim_indicator_material: StandardMaterial3D

func _ready():
	match_rng.randomize()
	match_clock = float(MatchManager.match_duration_minutes * 60)
	MatchManager.match_state_changed.connect(_on_match_state_changed)
	MatchManager.role_selection_rejected.connect(_on_role_selection_rejected)
	match_environment.visible = true
	ground.visible = false
	goal_nets[MatchManager.TEAM_BLUE] = _fit_goal(MatchManager.TEAM_BLUE)
	goal_nets[MatchManager.TEAM_RED] = _fit_goal(MatchManager.TEAM_RED)
	_build_boundary_walls()
	_build_ball()
	_build_hud()
	_build_aim_indicator()
	_on_match_state_changed(MatchManager.match_ready)

func _fit_goal(team: int) -> Array[Node3D]:
	var goal_name := "BlueGoal" if team == MatchManager.TEAM_BLUE else "RedGoal"
	var goal := match_environment.get_node_or_null(goal_name)
	if goal == null:
		push_error("Match scene is missing %s." % goal_name)
		return []
	var frame := goal.find_child("Rectangle001_post_0", true, false) as MeshInstance3D
	if frame == null:
		push_error("%s is missing its frame mesh." % goal_name)
		return []
	var root_inverse: Transform3D = goal.global_transform.affine_inverse()
	var frame_bounds := _get_transformed_aabb(frame.get_aabb(), root_inverse * frame.global_transform)
	if frame_bounds.size.x <= 0.0 or frame_bounds.size.y <= 0.0:
		push_error("%s has invalid goal frame bounds." % goal_name)
		return []
	var outward_sign := 1.0 if team == MatchManager.TEAM_BLUE else -1.0
	var goal_z := FIELD_HALF_LENGTH * outward_sign
	var scale_x: float = GOAL_HALF_WIDTH * 2.0 / frame_bounds.size.x
	var scale_y: float = GOAL_HEIGHT / frame_bounds.size.y
	goal.rotation.y = PI if outward_sign > 0.0 else 0.0
	goal.scale = Vector3(scale_x, scale_y, scale_x)
	goal.position = Vector3(0.0, 0.0, goal_z)
	goal.force_update_transform()
	frame.force_update_transform()
	var scaled_frame_bounds := _get_transformed_aabb(frame.get_aabb(), frame.global_transform)
	goal.global_position += Vector3(
		0.0,
		-scaled_frame_bounds.position.y,
		goal_z - scaled_frame_bounds.get_center().z
	)
	goal.force_update_transform()
	frame.force_update_transform()
	var net_parts: Array[Node3D] = []
	for mesh in goal.find_children("*", "MeshInstance3D", true, false):
		if mesh.name.to_lower().contains("rope"):
			net_parts.append(mesh as Node3D)
	if net_parts.is_empty():
		push_error("%s contains no net mesh parts." % goal_name)
	return net_parts

func _get_transformed_aabb(bounds: AABB, transform: Transform3D) -> AABB:
	var min_point := Vector3(INF, INF, INF)
	var max_point := Vector3(-INF, -INF, -INF)
	for x in [0, 1]:
		for y in [0, 1]:
			for z in [0, 1]:
				var corner := bounds.position + bounds.size * Vector3(x, y, z)
				var point := transform * corner
				min_point = min_point.min(point)
				max_point = max_point.max(point)
	return AABB(min_point, max_point - min_point)

func _build_pitch():
	ground.position = Vector3(0, -0.5, 0)
	ground.size = Vector3(FIELD_HALF_WIDTH * 2.0, 1.0, FIELD_HALF_LENGTH * 2.0)
	var turf = StandardMaterial3D.new()
	turf.albedo_color = Color(0.08, 0.22, 0.13)
	turf.roughness = 1.0
	ground.material = turf

	var line_material = StandardMaterial3D.new()
	line_material.albedo_color = Color(0.91, 0.91, 0.84)
	line_material.roughness = 0.9
	_add_line("TouchlineLeft", Vector3(-FIELD_HALF_WIDTH, 0.012, 0), Vector3(0.12, 0.025, FIELD_HALF_LENGTH * 2.0), line_material)
	_add_line("TouchlineRight", Vector3(FIELD_HALF_WIDTH, 0.012, 0), Vector3(0.12, 0.025, FIELD_HALF_LENGTH * 2.0), line_material)
	_add_line("EndlineNear", Vector3(0, 0.012, -FIELD_HALF_LENGTH), Vector3(FIELD_HALF_WIDTH * 2.0, 0.025, 0.12), line_material)
	_add_line("EndlineFar", Vector3(0, 0.012, FIELD_HALF_LENGTH), Vector3(FIELD_HALF_WIDTH * 2.0, 0.025, 0.12), line_material)
	_add_line("HalfwayLine", Vector3(0, 0.012, 0), Vector3(FIELD_HALF_WIDTH * 2.0, 0.025, 0.12), line_material)
	_add_circle("CenterCircle", Vector3(0, 0.025, 0), 9.15, 64, line_material)
	_add_spot("CenterSpot", Vector3(0, 0.025, 0), 0.12, line_material)
	for sign in [-1.0, 1.0]:
		var goal_z = sign * (FIELD_HALF_LENGTH - PENALTY_AREA_DEPTH)
		var penalty_box_center_z = sign * (FIELD_HALF_LENGTH - PENALTY_AREA_DEPTH * 0.5)
		var six_yard_top_z = sign * (FIELD_HALF_LENGTH - SIX_YARD_DEPTH)
		var six_yard_center_z = sign * (FIELD_HALF_LENGTH - SIX_YARD_DEPTH * 0.5)
		var penalty_spot_z = sign * (FIELD_HALF_LENGTH - PENALTY_SPOT_DISTANCE)
		_add_line("PenaltyBoxTop%s" % sign, Vector3(0, 0.012, goal_z), Vector3(PENALTY_AREA_HALF_WIDTH * 2.0, 0.025, 0.12), line_material)
		_add_line("PenaltyBoxLeft%s" % sign, Vector3(-PENALTY_AREA_HALF_WIDTH, 0.012, penalty_box_center_z), Vector3(0.12, 0.025, PENALTY_AREA_DEPTH), line_material)
		_add_line("PenaltyBoxRight%s" % sign, Vector3(PENALTY_AREA_HALF_WIDTH, 0.012, penalty_box_center_z), Vector3(0.12, 0.025, PENALTY_AREA_DEPTH), line_material)
		_add_line("SixYardTop%s" % sign, Vector3(0, 0.012, six_yard_top_z), Vector3(18.32, 0.025, 0.12), line_material)
		_add_line("SixYardLeft%s" % sign, Vector3(-9.16, 0.012, six_yard_center_z), Vector3(0.12, 0.025, SIX_YARD_DEPTH), line_material)
		_add_line("SixYardRight%s" % sign, Vector3(9.16, 0.012, six_yard_center_z), Vector3(0.12, 0.025, SIX_YARD_DEPTH), line_material)
		_add_spot("PenaltySpot%s" % sign, Vector3(0, 0.025, penalty_spot_z), 0.12, line_material)
		var arc_start := asin((PENALTY_AREA_DEPTH - PENALTY_SPOT_DISTANCE) / PENALTY_ARC_RADIUS)
		_add_arc("PenaltyArc%s" % sign, Vector3(0, 0.025, penalty_spot_z), PENALTY_ARC_RADIUS, arc_start, PI - arc_start, 40, -sign, line_material)
	for side in [-1.0, 1.0]:
		for end_sign in [-1.0, 1.0]:
			_add_corner_arc(
				"CornerArc%s_%s" % [side, end_sign],
				Vector3(side * FIELD_HALF_WIDTH, 0.025, end_sign * FIELD_HALF_LENGTH),
				CORNER_ARC_RADIUS,
				side,
				end_sign,
				16,
				line_material
			)

func _add_line(node_name: String, position: Vector3, size: Vector3, material: Material):
	var instance = MeshInstance3D.new()
	instance.name = node_name
	var box = BoxMesh.new()
	box.size = size
	instance.mesh = box
	instance.material_override = material
	instance.position = position
	add_child(instance)

func _add_circle(node_name: String, position: Vector3, radius: float, point_count: int, material: Material):
	var points := PackedVector3Array()
	for index in range(point_count + 1):
		var angle = TAU * float(index) / point_count
		points.append(Vector3(cos(angle) * radius, 0.0, sin(angle) * radius))
	var mesh = ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, material)
	for point in points:
		mesh.surface_add_vertex(point)
	mesh.surface_end()
	var instance = MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = position
	add_child(instance)

func _add_spot(node_name: String, position: Vector3, radius: float, material: Material):
	var instance := MeshInstance3D.new()
	instance.name = node_name
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = 0.025
	mesh.radial_segments = 16
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	add_child(instance)

func _add_arc(node_name: String, position: Vector3, radius: float, start_angle: float, end_angle: float, point_count: int, forward_sign: float, material: Material):
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, material)
	for index in range(point_count + 1):
		var angle := lerpf(start_angle, end_angle, float(index) / point_count)
		mesh.surface_add_vertex(Vector3(cos(angle) * radius, 0.0, sin(angle) * radius * forward_sign))
	mesh.surface_end()
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = position
	add_child(instance)

func _add_corner_arc(node_name: String, corner: Vector3, radius: float, side: float, end_sign: float, point_count: int, material: Material):
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, material)
	for index in range(point_count + 1):
		var angle: float = PI * 0.5 * float(index) / point_count
		mesh.surface_add_vertex(Vector3(-side * cos(angle) * radius, 0.0, -end_sign * sin(angle) * radius))
	mesh.surface_end()
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = corner
	add_child(instance)

func _build_goals():
	_add_goal(MatchManager.TEAM_RED, RED_GOAL_LINE_Z, -PI / 2.0)
	_add_goal(MatchManager.TEAM_BLUE, BLUE_GOAL_LINE_Z, PI / 2.0)

func _add_goal(defending_team: int, goal_z: float, rotation_y: float):
	var goal = GOAL_SCENE.instantiate() as Node3D
	goal.name = "BlueGoal" if defending_team == MatchManager.TEAM_BLUE else "RedGoal"
	goal.position = Vector3(0, 0, goal_z)
	goal.rotation.y = rotation_y
	goal.scale = Vector3(3.66, 1.22, 1.7)
	for imported_camera in goal.find_children("*", "Camera3D", true, false):
		imported_camera.queue_free()
	for imported_light in goal.find_children("*", "Light3D", true, false):
		imported_light.queue_free()
	add_child(goal)
	var bounds = _get_visual_bounds(goal)
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
		push_error("The goal model has invalid visual bounds.")
		return
	goal.scale = Vector3(
		2.0 / bounds.size.x,
		GOAL_HEIGHT / bounds.size.y,
		(GOAL_HALF_WIDTH * 2.0) / bounds.size.z
	)
	goal.position.y = -bounds.position.y * goal.scale.y
	goal.position.z = goal_z + signf(goal_z) * bounds.end.x * goal.scale.x
	var net := goal.find_child("Plane", true, false) as Node3D
	if net == null:
		push_error("The goal model is missing its net mesh node.")
	else:
		goal_nets[defending_team] = net
	_add_goal_frame(defending_team, goal_z)

func _get_visual_bounds(root: Node3D) -> AABB:
	var found := false
	var combined := AABB()
	var root_inverse = root.global_transform.affine_inverse()
	for child in root.find_children("*", "VisualInstance3D", true, false):
		var visual = child as VisualInstance3D
		var relative_transform = root_inverse * visual.global_transform
		var bounds = visual.get_aabb() * relative_transform
		if found:
			combined = combined.merge(bounds)
		else:
			combined = bounds
			found = true
	return combined

func _add_goal_frame(defending_team: int, goal_z: float):
	var color = TEAM_BLUE_COLOR if defending_team == MatchManager.TEAM_BLUE else TEAM_RED_COLOR
	var frame_material = StandardMaterial3D.new()
	frame_material.albedo_color = Color(0.9, 0.92, 0.87)
	frame_material.metallic = 0.28
	frame_material.roughness = 0.36
	var field_sign = 1.0 if goal_z < 0 else -1.0
	var outward_sign = signf(goal_z)
	_add_goal_bar("GoalPostL%s" % defending_team, Vector3(-GOAL_HALF_WIDTH, GOAL_HEIGHT * 0.5, goal_z), Vector3(0.16, GOAL_HEIGHT, 0.16), frame_material, true, false)
	_add_goal_bar("GoalPostR%s" % defending_team, Vector3(GOAL_HALF_WIDTH, GOAL_HEIGHT * 0.5, goal_z), Vector3(0.16, GOAL_HEIGHT, 0.16), frame_material, true, false)
	_add_goal_bar("GoalCrossbar%s" % defending_team, Vector3(0, GOAL_HEIGHT, goal_z), Vector3(GOAL_HALF_WIDTH * 2.0, 0.16, 0.16), frame_material, true, false)
	_add_goal_bar("GoalBackStop%s" % defending_team, Vector3(0, GOAL_HEIGHT * 0.5, goal_z + outward_sign * 5.0), Vector3(GOAL_HALF_WIDTH * 2.0 + 1.0, GOAL_HEIGHT + 0.4, 0.2), _invisible_material())
	for side in [-1.0, 1.0]:
		_add_goal_bar("NetSide%s_%s" % [defending_team, side], Vector3(side * GOAL_HALF_WIDTH, GOAL_HEIGHT * 0.5, goal_z + outward_sign * 2.5), Vector3(0.08, GOAL_HEIGHT, 5.0), _invisible_material())
	_add_goal_bar("NetRoof%s" % defending_team, Vector3(0, GOAL_HEIGHT, goal_z + outward_sign * 2.5), Vector3(GOAL_HALF_WIDTH * 2.0, 0.08, 5.0), _invisible_material())
	var area_material = StandardMaterial3D.new()
	area_material.albedo_color = color
	area_material.emission_enabled = true
	area_material.emission = color * 0.35
	area_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_add_goal_bar("GoalTeamMarker%s" % defending_team, Vector3(0, 0.035, goal_z + field_sign * 5.2), Vector3(7.0, 0.03, 0.12), area_material, false)

func _invisible_material() -> StandardMaterial3D:
	var material = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.0, 0.0, 0.0, 0.0)
	return material

func _add_goal_bar(node_name: String, position: Vector3, size: Vector3, material: Material, with_collision := true, show_visual := true):
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = node_name
	var mesh = BoxMesh.new()
	mesh.size = size
	mesh_instance.mesh = mesh
	mesh_instance.material_override = material
	mesh_instance.position = position
	mesh_instance.visible = show_visual
	add_child(mesh_instance)
	if not with_collision:
		return
	var body = StaticBody3D.new()
	body.name = "%sCollision" % node_name
	body.position = position
	var shape = CollisionShape3D.new()
	var box = BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	add_child(body)

func _build_boundary_walls():
	_add_wall(Vector3(-FIELD_HALF_WIDTH - 0.15, BOUNDARY_WALL_HEIGHT * 0.5, 0), Vector3(0.3, BOUNDARY_WALL_HEIGHT, FIELD_HALF_LENGTH * 2.0))
	_add_wall(Vector3(FIELD_HALF_WIDTH + 0.15, BOUNDARY_WALL_HEIGHT * 0.5, 0), Vector3(0.3, BOUNDARY_WALL_HEIGHT, FIELD_HALF_LENGTH * 2.0))

func _add_wall(position: Vector3, size: Vector3):
	var body = StaticBody3D.new()
	body.position = position
	body.collision_layer = 1
	var physics_material := PhysicsMaterial.new()
	physics_material.friction = 0.2
	physics_material.bounce = 0.85
	body.physics_material_override = physics_material
	var shape = CollisionShape3D.new()
	var box = BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	add_child(body)

func _build_ball():
	ball = RigidBody3D.new()
	ball.name = "MatchBall"
	ball.mass = 0.43
	ball.gravity_scale = 1.0
	ball.linear_damp = 0.08
	ball.angular_damp = 0.14
	ball.continuous_cd = true
	ball.contact_monitor = true
	ball.max_contacts_reported = 8
	ball.collision_layer = BALL_LAYER
	ball.collision_mask = 1 | 2
	ball.can_sleep = false
	var physics_material = PhysicsMaterial.new()
	physics_material.friction = 0.32
	physics_material.bounce = 0.55
	ball.physics_material_override = physics_material
	var collision = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = BALL_RADIUS
	collision.shape = sphere
	ball.add_child(collision)
	var visual = BALL_SCENE.instantiate() as Node3D
	visual.name = "BallVisual"
	ball.add_child(visual)
	ball.position = BALL_START
	ball.freeze = true
	ball.body_entered.connect(_on_ball_body_entered)
	add_child(ball)
	var visual_bounds := _get_visual_bounds(visual)
	var visual_diameter := maxf(visual_bounds.size.x, maxf(visual_bounds.size.y, visual_bounds.size.z))
	if visual_diameter <= 0.0:
		push_error("Match ball model has invalid visual bounds.")
		ball.queue_free()
		ball = null
		return
	visual.scale = Vector3.ONE * (BALL_RADIUS * 2.0 / visual_diameter)

func _build_hud():
	if DisplayServer.get_name() == "headless":
		return
	var hud = CanvasLayer.new()
	hud.name = "MatchHUD"
	add_child(hud)
	var scoreboard_panel := PanelContainer.new()
	scoreboard_panel.name = "TVScoreboard"
	scoreboard_panel.anchor_left = 0.0
	scoreboard_panel.anchor_right = 0.0
	scoreboard_panel.offset_left = 24.0
	scoreboard_panel.offset_top = 22.0
	scoreboard_panel.offset_right = 540.0
	scoreboard_panel.offset_bottom = 88.0
	var scoreboard_style := StyleBoxFlat.new()
	scoreboard_style.bg_color = Color(0.035, 0.055, 0.085, 0.94)
	scoreboard_style.border_width_left = 5
	scoreboard_style.border_color = Color(0.93, 0.16, 0.2, 1.0)
	scoreboard_style.set_corner_radius_all(8)
	scoreboard_style.content_margin_left = 16.0
	scoreboard_style.content_margin_right = 16.0
	scoreboard_style.content_margin_top = 8.0
	scoreboard_style.content_margin_bottom = 8.0
	scoreboard_panel.add_theme_stylebox_override("panel", scoreboard_style)
	hud.add_child(scoreboard_panel)

	var scoreboard_row := HBoxContainer.new()
	scoreboard_row.add_theme_constant_override("separation", 12)
	scoreboard_panel.add_child(scoreboard_row)
	scoreboard_row.add_child(_make_score_label("HUMAN", 17, Color(1.0, 0.38, 0.38)))
	scoreboard_home_score = _make_score_label("0", 30, Color.WHITE)
	scoreboard_row.add_child(scoreboard_home_score)
	scoreboard_row.add_child(_make_score_label("-", 24, Color(0.72, 0.78, 0.86)))
	scoreboard_away_score = _make_score_label("0", 30, Color.WHITE)
	scoreboard_row.add_child(scoreboard_away_score)
	scoreboard_row.add_child(_make_score_label("ROBOT", 17, Color(0.35, 0.68, 1.0)))
	var clock_separator := _make_score_label("|", 22, Color(0.47, 0.54, 0.64))
	scoreboard_row.add_child(clock_separator)
	scoreboard_clock = _make_score_label("05:00", 23, Color(1.0, 0.82, 0.38))
	scoreboard_row.add_child(scoreboard_clock)

	var outv_panel := PanelContainer.new()
	outv_panel.name = "OUTVBadge"
	outv_panel.anchor_left = 1.0
	outv_panel.anchor_right = 1.0
	outv_panel.offset_left = -156.0
	outv_panel.offset_top = 22.0
	outv_panel.offset_right = -24.0
	outv_panel.offset_bottom = 78.0
	var outv_style := StyleBoxFlat.new()
	outv_style.bg_color = Color(0.035, 0.055, 0.085, 0.94)
	outv_style.border_width_bottom = 3
	outv_style.border_color = Color(0.2, 0.78, 0.6, 1.0)
	outv_style.set_corner_radius_all(8)
	outv_style.content_margin_left = 12.0
	outv_style.content_margin_right = 12.0
	outv_panel.add_theme_stylebox_override("panel", outv_style)
	hud.add_child(outv_panel)
	var outv_label := _make_score_label("OUTV", 27, Color.WHITE)
	outv_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outv_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outv_panel.add_child(outv_label)
	waiting_label = Label.new()
	waiting_label.anchor_left = 0.5
	waiting_label.anchor_top = 0.5
	waiting_label.anchor_right = 0.5
	waiting_label.anchor_bottom = 0.5
	waiting_label.offset_left = -280
	waiting_label.offset_top = -55
	waiting_label.offset_right = 280
	waiting_label.offset_bottom = 55
	waiting_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	waiting_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	waiting_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	waiting_label.add_theme_font_size_override("font_size", 28)
	hud.add_child(waiting_label)
	action_label = Label.new()
	action_label.anchor_left = 0.5
	action_label.anchor_top = 1.0
	action_label.anchor_right = 0.5
	action_label.anchor_bottom = 1.0
	action_label.offset_left = -370
	action_label.offset_top = -48
	action_label.offset_right = 370
	action_label.offset_bottom = -18
	action_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	action_label.add_theme_font_size_override("font_size", 16)
	hud.add_child(action_label)
	power_bar = ProgressBar.new()
	power_bar.anchor_left = 0.5
	power_bar.anchor_top = 1.0
	power_bar.anchor_right = 0.5
	power_bar.anchor_bottom = 1.0
	power_bar.offset_left = -145
	power_bar.offset_top = -88
	power_bar.offset_right = 145
	power_bar.offset_bottom = -68
	power_bar.max_value = 1.5
	power_bar.show_percentage = false
	power_bar.visible = false
	hud.add_child(power_bar)
	match_end_label = Label.new()
	match_end_label.anchor_left = 0.5
	match_end_label.anchor_top = 0.3
	match_end_label.anchor_right = 0.5
	match_end_label.anchor_bottom = 0.3
	match_end_label.offset_left = -300
	match_end_label.offset_right = 300
	match_end_label.offset_bottom = 80
	match_end_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	match_end_label.add_theme_font_size_override("font_size", 48)
	match_end_label.visible = false
	hud.add_child(match_end_label)
	hud.add_child(MatchManager.make_plaza_button())
	_update_scoreboard()

func _make_score_label(label_text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = label_text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func request_ball_action(direction: Vector3, power: float, curve: float, action: String, actor_name: String = ""):
	if not game_started:
		return
	var local_id = multiplayer.get_unique_id()
	if actor_name.is_empty():
		var selected := get_local_selected_player()
		if selected == null:
			return
		actor_name = selected.name
	if multiplayer.is_server():
		_handle_ball_action(local_id, actor_name, direction, power, curve, action)
	else:
		request_action.rpc_id(1, actor_name, direction, power, curve, action)

func can_local_shoot() -> bool:
	if not game_started or ball == null:
		return false
	var player := get_local_selected_player()
	if player == null or player.role != MatchManager.ROLE_PLAYER or player.global_position.distance_to(ball.global_position) > 2.7:
		return false
	if not _team_has_ball_control(player.team):
		return false
	var camera := player.get_node_or_null("Camera3D") as Camera3D
	if camera == null or camera.is_position_behind(ball.global_position):
		return false
	var viewport_size := camera.get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0:
		return false
	var ball_screen_position := camera.unproject_position(ball.global_position)
	return absf(ball_screen_position.x - viewport_size.x * 0.5) <= viewport_size.x / 6.0

func get_local_selected_player() -> CharacterBody3D:
	if is_instance_valid(local_selected_entity):
		return local_selected_entity
	return null

func select_nearest_local_player() -> void:
	var team := MatchManager.local_team()
	if team < 0 or ball == null:
		return
	var nearest: CharacterBody3D
	var nearest_distance := INF
	for child in players.get_children():
		var candidate := child as CharacterBody3D
		if candidate == null or candidate.team != team or candidate.role != MatchManager.ROLE_PLAYER:
			continue
		var distance := candidate.global_position.distance_squared_to(ball.global_position)
		if distance < nearest_distance:
			nearest = candidate
			nearest_distance = distance
	if nearest:
		_set_local_selection(nearest)

func select_local_keeper() -> void:
	var team := MatchManager.local_team()
	for child in players.get_children():
		var candidate := child as CharacterBody3D
		if candidate and candidate.team == team and candidate.role == MatchManager.ROLE_GOALKEEPER:
			_set_local_selection(candidate)
			return

func _set_local_selection(player: CharacterBody3D) -> void:
	if player.controller_peer_id != multiplayer.get_unique_id() or player.team != MatchManager.local_team():
		return
	if local_selected_entity == player:
		return
	if is_instance_valid(local_selected_entity):
		local_selected_entity._set_local_selected(false)
	local_selected_entity = player
	local_selected_entity._set_local_selected(true)
	if multiplayer.is_server():
		var peer_id := multiplayer.get_unique_id()
		selected_entity_by_peer[peer_id] = player.name
		controller_input_by_peer.erase(peer_id)
	else:
		request_entity_selection.rpc_id(1, player.name)

@rpc("any_peer", "call_remote", "reliable")
func request_entity_selection(entity_name: String) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var entity := players.get_node_or_null(entity_name) as CharacterBody3D
	if entity == null or entity.controller_peer_id != peer_id or entity.team != MatchManager.team_for_peer(peer_id):
		return
	selected_entity_by_peer[peer_id] = entity_name
	controller_input_by_peer.erase(peer_id)

func submit_controller_input(player: CharacterBody3D, move: Vector2, yaw: float, sprint: bool, jump: bool, contain := false) -> void:
	if not is_instance_valid(player) or player.controller_peer_id != multiplayer.get_unique_id() or player.team != MatchManager.local_team():
		return
	var state := {"move": move.limit_length(1.0), "yaw": yaw, "sprint": sprint, "jump": jump, "contain": contain}
	if multiplayer.is_server():
		selected_entity_by_peer[multiplayer.get_unique_id()] = player.name
		controller_input_by_peer[multiplayer.get_unique_id()] = state
	else:
		submit_controller_input_rpc.rpc_id(1, player.name, state)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func submit_controller_input_rpc(entity_name: String, state: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var entity := players.get_node_or_null(entity_name) as CharacterBody3D
	if entity == null or entity.controller_peer_id != peer_id or entity.team != MatchManager.team_for_peer(peer_id) or selected_entity_by_peer.get(peer_id, "") != entity_name:
		return
	var move: Vector2 = state.get("move", Vector2.ZERO)
	controller_input_by_peer[peer_id] = {
		"move": move.limit_length(1.0),
		"yaw": float(state.get("yaw", entity.rotation.y)),
		"sprint": bool(state.get("sprint", false)),
		"jump": bool(state.get("jump", false)),
		"contain": bool(state.get("contain", false))
	}

func server_input_for(player: CharacterBody3D) -> Dictionary:
	if not multiplayer.is_server():
		return {}
	var peer_id: int = player.controller_peer_id
	if set_piece_active and player.name == set_piece_taker_name:
		return {"world_move": Vector3.ZERO, "yaw": player.rotation.y}
	var cross_target: Dictionary = cross_run_assignments.get(player.name, {})
	if not cross_target.is_empty() and int(cross_target.get("expires", 0)) > Time.get_ticks_msec():
		return {}
	if selected_entity_by_peer.get(peer_id, "") != player.name:
		return {}
	return controller_input_by_peer.get(peer_id, {})

func can_local_clear(player: CharacterBody3D) -> bool:
	return is_instance_valid(player) and player.global_position.distance_to(ball.global_position) <= 2.7 and can_player_clear(player)

func can_player_clear(player: CharacterBody3D) -> bool:
	for candidate in players.get_children():
		var opponent := candidate as CharacterBody3D
		if opponent == null or opponent.role != MatchManager.ROLE_PLAYER or opponent.team == player.team:
			continue
		if opponent.global_position.distance_to(player.global_position) <= 1.75:
			return true
	return false

func _team_has_ball_control(team: int) -> bool:
	var nearest := _nearest_player_to_ball()
	return nearest != null and nearest.team == team and nearest.global_position.distance_to(ball.global_position) <= 2.7

func update_player_dribble(player: CharacterBody3D, movement: Vector3, delta: float) -> void:
	if not multiplayer.is_server() or ball == null or ball.freeze or set_piece_active:
		return
	if player.role != MatchManager.ROLE_PLAYER or (not _is_player_selected(player) and not player.is_ai):
		return
	movement.y = 0.0
	if movement.length_squared() < 0.01 or player.global_position.distance_to(ball.global_position) > 2.0:
		return
	if not _team_has_ball_control(player.team) or _nearest_player_to_ball(player.team) != player:
		return
	var direction := movement.normalized()
	var target := player.global_position + direction * 0.95
	var correction := target - ball.global_position
	correction.y = 0.0
	var desired_velocity := direction * 3.4
	if correction.length() > 0.35:
		desired_velocity = correction.normalized() * minf(4.0, 1.8 + correction.length() * 1.8)
	var horizontal_velocity := Vector3(ball.linear_velocity.x, 0.0, ball.linear_velocity.z)
	var dribble_velocity := horizontal_velocity.lerp(desired_velocity, minf(delta * 8.0, 1.0))
	ball.linear_velocity.x = dribble_velocity.x
	ball.linear_velocity.z = dribble_velocity.z

func _nearest_player_to_ball(team := -1) -> CharacterBody3D:
	if ball == null:
		return null
	var nearest: CharacterBody3D
	var nearest_distance := INF
	for child in players.get_children():
		var candidate := child as CharacterBody3D
		if candidate == null:
			continue
		if team >= 0 and candidate.team != team:
			continue
		var distance := candidate.global_position.distance_squared_to(ball.global_position)
		if distance < nearest_distance:
			nearest = candidate
			nearest_distance = distance
	return nearest

func _is_player_selected(player: CharacterBody3D) -> bool:
	return selected_entity_by_peer.get(player.controller_peer_id, "") == player.name

func ai_input_for(player: CharacterBody3D, _delta: float) -> Dictionary:
	if ball == null:
		return {}
	var target := player.global_position
	var attack_sign := _attack_sign(player.team)
	if player.role == MatchManager.ROLE_GOALKEEPER:
		var goal_line_z := -attack_sign * FIELD_HALF_LENGTH
		var goal_z := -attack_sign * (FIELD_HALF_LENGTH - 3.0)
		var target_x := ball.global_position.x
		if absf(ball.linear_velocity.z) > 0.5 and ball.linear_velocity.z * attack_sign < 0.0:
			var time_to_goal := (goal_line_z - ball.global_position.z) / ball.linear_velocity.z
			if time_to_goal >= 0.0 and time_to_goal < 3.0:
				target_x += ball.linear_velocity.x * time_to_goal
		target = Vector3(clampf(target_x, -GOAL_HALF_WIDTH + 0.55, GOAL_HALF_WIDTH - 0.55), 0.0, goal_z)
		_try_ai_keeper_dive(player, attack_sign)
	else:
		var cross_target: Dictionary = cross_run_assignments.get(player.name, {})
		if not cross_target.is_empty() and int(cross_target.get("expires", 0)) > Time.get_ticks_msec():
			var landing: Vector3 = cross_target.position
			if player.global_position.distance_to(landing) > 1.2:
				target = landing
			else:
				cross_run_assignments.erase(player.name)
		else:
			cross_run_assignments.erase(player.name)
			var nearest_ai: CharacterBody3D
			var nearest_distance := INF
			for candidate_node in players.get_children():
				var candidate := candidate_node as CharacterBody3D
				if candidate == null or candidate.team != player.team or candidate.role != MatchManager.ROLE_PLAYER or _is_player_selected(candidate):
					continue
				var distance := candidate.global_position.distance_squared_to(ball.global_position)
				if distance < nearest_distance:
					nearest_ai = candidate
					nearest_distance = distance
			var other_team := MatchManager.TEAM_RED if player.team == MatchManager.TEAM_BLUE else MatchManager.TEAM_BLUE
			var teammate_on_ball := _nearest_player_to_ball(player.team)
			if _team_has_ball_control(player.team) and teammate_on_ball != null:
				if teammate_on_ball == player:
					target = _ai_dribble_target(player, attack_sign)
				else:
					target = _ai_support_position(player, teammate_on_ball, attack_sign)
			elif _team_has_ball_control(other_team):
				if nearest_ai == player and player.global_position.distance_to(ball.global_position) < 38.0:
					target = ball.global_position
				else:
					target = _ai_defensive_position(player, attack_sign)
			elif nearest_ai == player and player.global_position.distance_to(ball.global_position) < 38.0:
				target = ball.global_position
			else:
				target = _ai_defensive_position(player, attack_sign)
			target.x = clampf(target.x, -FIELD_HALF_WIDTH + 1.0, FIELD_HALF_WIDTH - 1.0)
			target.z = clampf(target.z, -FIELD_HALF_LENGTH + 1.0, FIELD_HALF_LENGTH - 1.0)
	target.y = 0.0
	var direction := target - player.global_position
	direction.y = 0.0
	if direction.length_squared() < 0.01:
		return {"world_move": Vector3.ZERO, "yaw": player.rotation.y, "sprint": false}
	direction = direction.normalized()
	var yaw := atan2(-direction.x, -direction.z)
	return {"world_move": direction, "yaw": yaw, "sprint": true}

func _ai_dribble_target(player: CharacterBody3D, attack_sign: float) -> Vector3:
	var forward := Vector3(0.0, 0.0, attack_sign)
	var target := player.global_position + forward * 6.0
	var nearest_opponent := _nearest_player_to_ball(
		MatchManager.TEAM_RED if player.team == MatchManager.TEAM_BLUE else MatchManager.TEAM_BLUE
	)
	if nearest_opponent != null and nearest_opponent.global_position.distance_to(player.global_position) < 5.0:
		var toward_opponent := nearest_opponent.global_position - player.global_position
		toward_opponent.y = 0.0
		var left := Vector3(-toward_opponent.z, 0.0, toward_opponent.x).normalized()
		var right := -left
		var left_space := _nearest_player_distance(nearest_opponent.team, player.global_position + left * 4.0)
		var right_space := _nearest_player_distance(nearest_opponent.team, player.global_position + right * 4.0)
		target += (left if left_space >= right_space else right) * 4.0
	return target

func _nearest_player_distance(team: int, position: Vector3) -> float:
	var nearest_distance := INF
	for child in players.get_children():
		var candidate := child as CharacterBody3D
		if candidate == null or candidate.team != team or candidate.role != MatchManager.ROLE_PLAYER:
			continue
		nearest_distance = minf(nearest_distance, candidate.global_position.distance_to(position))
	return nearest_distance

func _ai_support_position(player: CharacterBody3D, carrier: CharacterBody3D, attack_sign: float) -> Vector3:
	var slot := maxi(player.field_slot, 0)
	var lateral := float((slot % 3) - 1) * 9.0
	var target: Vector3 = player.spawn_position
	if slot <= 3:
		target.z += attack_sign * 4.0
	elif slot <= 6:
		target = carrier.global_position + Vector3(lateral, 0.0, attack_sign * 7.0)
	else:
		target = carrier.global_position + Vector3(lateral * 0.75, 0.0, attack_sign * 13.0)
		target.z = minf(attack_sign * target.z, _offside_line_progress(player.team) - 1.5) * attack_sign
	return target

func _ai_defensive_position(player: CharacterBody3D, attack_sign: float) -> Vector3:
	var slot := maxi(player.field_slot, 0)
	var target: Vector3 = player.spawn_position
	if slot >= 4 and slot <= 6:
		var lateral := float(slot - 5) * 10.0
		target = Vector3(ball.global_position.x * 0.35 + lateral, 0.0, ball.global_position.z - attack_sign * 9.0)
	elif slot >= 7:
		target.z = lerpf(target.z, ball.global_position.z - attack_sign * 16.0, 0.25)
	return target

func _try_ai_keeper_dive(player: CharacterBody3D, attack_sign: float) -> void:
	if not multiplayer.is_server() or _is_player_selected(player) or ball.global_position.distance_to(player.global_position) > 24.0:
		return
	if ball.linear_velocity.z * attack_sign >= -1.0:
		return
	if int(ai_keeper_dive_cooldowns.get(player.name, 0)) > Time.get_ticks_msec():
		return
	ai_keeper_dive_cooldowns[player.name] = Time.get_ticks_msec() + 1800
	start_ai_keeper_dive(player)

func try_ai_ball_action(player: CharacterBody3D) -> void:
	if not multiplayer.is_server() or not game_started or ball == null:
		return
	var other_team := MatchManager.TEAM_RED if player.team == MatchManager.TEAM_BLUE else MatchManager.TEAM_BLUE
	if _is_player_selected(player):
		var selected_input := server_input_for(player)
		if bool(selected_input.get("contain", false)) and not _team_has_ball_control(player.team):
			_try_contain_poke(player, other_team)
		return
	if _team_has_ball_control(other_team):
		_try_ai_tackle(player, other_team)
		return
	if player.global_position.distance_to(ball.global_position) > 2.25 or not _team_has_ball_control(player.team):
		return
	if ai_ball_action_cooldown_until > Time.get_ticks_msec():
		return
	if int(ai_action_cooldowns.get(player.name, 0)) > Time.get_ticks_msec():
		return
	var attack_sign := _attack_sign(player.team)
	var goal_distance := absf(attack_sign * FIELD_HALF_LENGTH - ball.global_position.z)
	var direction := Vector3.ZERO
	var action := ""
	if player.role == MatchManager.ROLE_GOALKEEPER:
		action = "clearance"
		direction = Vector3(match_rng.randf_range(-0.55, 0.55), 0.25, attack_sign)
	else:
		var receiver := _best_forward_teammate(player)
		var roll := match_rng.randf()
		var shot_chance := clampf(0.42 + (25.0 - goal_distance) * 0.025, 0.42, 0.82)
		if goal_distance < 25.0 and absf(player.global_position.x) < 28.0 and roll < shot_chance:
			action = "shot"
			direction = Vector3(-player.global_position.x * 0.03, 0.12, attack_sign)
		elif receiver != null and _has_nearby_opponent(player, 8.0) and match_rng.randf() < 0.62:
			direction = receiver.global_position - ball.global_position
			action = "through" if goal_distance > 32.0 else "pass"
		elif receiver != null and goal_distance > 24.0 and match_rng.randf() < 0.12:
			direction = receiver.global_position - ball.global_position
			action = "through"
	if action.is_empty():
		return
	ai_ball_action_cooldown_until = Time.get_ticks_msec() + 800
	ai_action_cooldowns[player.name] = Time.get_ticks_msec() + 1400
	_handle_ball_action(0, player.name, direction, 0.62, 0.0, action, true)

func _has_nearby_opponent(player: CharacterBody3D, radius: float) -> bool:
	var other_team := MatchManager.TEAM_RED if player.team == MatchManager.TEAM_BLUE else MatchManager.TEAM_BLUE
	for child in players.get_children():
		var opponent := child as CharacterBody3D
		if opponent == null or opponent.team != other_team or opponent.role != MatchManager.ROLE_PLAYER:
			continue
		if opponent.global_position.distance_to(player.global_position) <= radius:
			return true
	return false

func _try_ai_tackle(player: CharacterBody3D, opponent_team: int) -> void:
	if not multiplayer.is_server() or _is_player_selected(player) or player.role != MatchManager.ROLE_PLAYER:
		return
	var opponent := _nearest_player_to_ball(opponent_team)
	if opponent == null or opponent.role != MatchManager.ROLE_PLAYER:
		return
	if player.global_position.distance_to(opponent.global_position) > 2.4 or ball.global_position.distance_to(opponent.global_position) > 2.7:
		return
	var now := Time.get_ticks_msec()
	if int(ai_tackle_cooldowns.get(player.name, 0)) > now:
		return
	ai_tackle_cooldowns[player.name] = now + 1200
	if match_rng.randf() > 0.42:
		return
	var direction := opponent.global_position - player.global_position
	direction.y = 0.0
	if direction.length_squared() < 0.01:
		return
	_resolve_tackle(player, opponent, direction.normalized())

func _try_contain_poke(player: CharacterBody3D, opponent_team: int) -> void:
	if player.role != MatchManager.ROLE_PLAYER or ball == null or ball.freeze or set_piece_active:
		return
	var opponent := _nearest_player_to_ball(opponent_team)
	if opponent == null:
		return
	if player.global_position.distance_to(opponent.global_position) > 1.65 \
		or ball.global_position.distance_to(opponent.global_position) > 2.5:
		return
	var now := Time.get_ticks_msec()
	var cooldown_key := "contain_%s" % player.name
	if int(ai_tackle_cooldowns.get(cooldown_key, 0)) > now:
		return
	ai_tackle_cooldowns[cooldown_key] = now + 550
	var poke_direction := ball.global_position - opponent.global_position
	poke_direction.y = 0.0
	if poke_direction.length_squared() < 0.01:
		poke_direction = player.global_position - opponent.global_position
	poke_direction.y = 0.0
	if poke_direction.length_squared() < 0.01:
		return
	poke_direction = poke_direction.normalized()
	ball.linear_velocity += poke_direction * 3.5 + Vector3.UP * 0.15
	last_ball_actor_name = player.name
	_clear_offside_state()

func _best_forward_teammate(player: CharacterBody3D) -> CharacterBody3D:
	var attack_sign := _attack_sign(player.team)
	var best: CharacterBody3D
	var best_score := INF
	for child in players.get_children():
		var teammate := child as CharacterBody3D
		if teammate == null or teammate == player or teammate.team != player.team or teammate.role != MatchManager.ROLE_PLAYER:
			continue
		var progress := attack_sign * (teammate.global_position.z - player.global_position.z)
		if progress < -1.0:
			continue
		if _is_offside_position(teammate, player.team, ball.global_position):
			continue
		var score := player.global_position.distance_to(teammate.global_position) - progress * 0.15
		if score < best_score:
			best = teammate
			best_score = score
	return best

func _attack_sign(team: int) -> float:
	return -1.0 if team == MatchManager.TEAM_BLUE else 1.0

func _offside_line_progress(attacking_team: int) -> float:
	var attack_sign := _attack_sign(attacking_team)
	var defender_progress: Array[float] = []
	for child in players.get_children():
		var defender := child as CharacterBody3D
		if defender != null and defender.team != attacking_team:
			defender_progress.append(attack_sign * defender.global_position.z)
	if defender_progress.size() < 2:
		return FIELD_HALF_LENGTH
	defender_progress.sort()
	return maxf(attack_sign * ball.global_position.z, defender_progress[defender_progress.size() - 2])

func _is_offside_position(player: CharacterBody3D, attacking_team: int, ball_position: Vector3) -> bool:
	var attack_sign := _attack_sign(attacking_team)
	var player_progress := attack_sign * player.global_position.z
	var line_progress := maxf(attack_sign * ball_position.z, _offside_line_progress(attacking_team))
	return player_progress > 0.0 and player_progress > line_progress + 0.1

func _capture_offside_positions(passer: CharacterBody3D) -> void:
	offside_candidates.clear()
	offside_team = -1
	if set_piece_active and set_piece_kind in ["goal_kick", "corner", "throw_in"]:
		return
	for child in players.get_children():
		var attacker := child as CharacterBody3D
		if attacker == null or attacker.team != passer.team or attacker == passer:
			continue
		if _is_offside_position(attacker, passer.team, ball.global_position):
			offside_candidates[attacker.name] = true
	if not offside_candidates.is_empty():
		offside_team = passer.team

func _clear_offside_state() -> void:
	offside_team = -1
	offside_candidates.clear()

func _handle_offside_involvement(player: CharacterBody3D) -> bool:
	if offside_team < 0 or player.role not in [MatchManager.ROLE_PLAYER, MatchManager.ROLE_GOALKEEPER]:
		return false
	if player.team == offside_team and offside_candidates.has(player.name):
		var defending_team := MatchManager.TEAM_RED if offside_team == MatchManager.TEAM_BLUE else MatchManager.TEAM_BLUE
		_start_free_kick(
			Vector3(player.global_position.x, BALL_RADIUS, player.global_position.z),
			defending_team,
			"OFFSIDE | INDIRECT FREE KICK"
		)
		return true
	if player.team == offside_team:
		_clear_offside_state()
		return false
	for candidate_name in offside_candidates:
		var candidate := players.get_node_or_null(candidate_name) as CharacterBody3D
		if candidate != null and candidate.global_position.distance_to(player.global_position) < 1.15:
			var defending_team := MatchManager.TEAM_RED if offside_team == MatchManager.TEAM_BLUE else MatchManager.TEAM_BLUE
			_start_free_kick(
				Vector3(candidate.global_position.x, BALL_RADIUS, candidate.global_position.z),
				defending_team,
				"OFFSIDE | INDIRECT FREE KICK"
			)
			return true
	return false

func _assign_cross_receiver(player: CharacterBody3D, kick_velocity: Vector3) -> void:
	var airtime := clampf(2.0 * maxf(kick_velocity.y, 0.0) / 9.8, 0.35, 3.5)
	var landing := ball.global_position + Vector3(kick_velocity.x, 0.0, kick_velocity.z) * airtime
	landing.x = clampf(landing.x, -FIELD_HALF_WIDTH + 2.0, FIELD_HALF_WIDTH - 2.0)
	landing.z = clampf(landing.z, -FIELD_HALF_LENGTH + 2.0, FIELD_HALF_LENGTH - 2.0)
	var receiver: CharacterBody3D
	var best_distance := INF
	for child in players.get_children():
		var teammate := child as CharacterBody3D
		if teammate == null or teammate == player or teammate.team != player.team or teammate.role != MatchManager.ROLE_PLAYER:
			continue
		var distance := teammate.global_position.distance_to(landing)
		if distance < best_distance:
			receiver = teammate
			best_distance = distance
	if receiver:
		cross_run_assignments[receiver.name] = {"position": landing, "expires": Time.get_ticks_msec() + int(airtime * 1000.0) + 1800}

@rpc("any_peer", "call_remote", "reliable")
func request_action(actor_name: String, direction: Vector3, power: float, curve: float, action: String):
	if multiplayer.is_server():
		_handle_ball_action(multiplayer.get_remote_sender_id(), actor_name, direction, power, curve, action)

func _handle_ball_action(peer_id: int, actor_name: String, direction: Vector3, power: float, curve: float, action: String, ai_action := false):
	if not game_started or kickoff_delay > 0.0 or ball == null:
		return
	var player := players.get_node_or_null(actor_name) as CharacterBody3D
	if player == null or player.role not in [MatchManager.ROLE_PLAYER, MatchManager.ROLE_GOALKEEPER]:
		return
	if ai_action:
		if _is_player_selected(player):
			return
	elif selected_entity_by_peer.get(peer_id, "") != actor_name or player.controller_peer_id != peer_id:
		return
	var is_keeper: bool = player.role == MatchManager.ROLE_GOALKEEPER
	var is_taker: bool = set_piece_active and actor_name == set_piece_taker_name
	if not ai_action and player.team != MatchManager.team_for_peer(peer_id):
		return
	if is_keeper and action != "clearance":
		return
	if player.global_position.distance_to(ball.global_position) > 2.7:
		return
	if not is_keeper and action == "clearance" and not can_player_clear(player):
		return
	if kickoff_team >= 0 and not is_keeper and player.team != kickoff_team:
		return
	if action not in ["shot", "pass", "through", "lofted_through", "cross", "clearance"]:
		return
	if not is_keeper and not is_taker and action != "clearance" and not _team_has_ball_control(player.team):
		return
	set_piece_timer = 0.0
	_capture_offside_positions(player)
	if action == "clearance" and not is_keeper:
		var attack_sign := -1.0 if player.team == MatchManager.TEAM_BLUE else 1.0
		direction = Vector3(match_rng.randf_range(-0.8, 0.8), match_rng.randf_range(0.1, 0.45), attack_sign)
	elif direction.length_squared() < 0.01:
		direction = -player.global_transform.basis.z
	direction = direction.normalized()
	var safe_power = clampf(power, 0.15, 1.0)
	var forward_speed := 18.0
	var lift := 0.15
	match action:
		"pass":
			forward_speed = 4.0 + safe_power * 8.0
			lift = 0.04 + safe_power * 0.12
		"through":
			forward_speed = 6.0 + safe_power * 10.0
			lift = 0.05 + safe_power * 0.12
		"lofted_through":
			forward_speed = 7.0 + safe_power * 9.0
			lift = 0.24 + safe_power * 0.32
		"cross":
			forward_speed = 6.0 + safe_power * 12.0
			lift = 0.2 + safe_power * 0.6
		"clearance":
			forward_speed = 12.0 + safe_power * 14.0
			lift = 0.3 + safe_power * 0.4
		"shot":
			forward_speed = 13.0 + safe_power * 13.0
			lift = 0.18 + safe_power * 0.22
	var kick_velocity = direction * forward_speed
	kick_velocity.y += lift * forward_speed
	if action in ["cross", "lofted_through"]:
		_assign_cross_receiver(player, kick_velocity)
	start_ball_action.rpc(kick_velocity, clampf(curve, -1.0, 1.0), action, actor_name)

@rpc("authority", "call_local", "reliable")
func start_ball_action(kick_velocity: Vector3, curve: float, action: String, actor_name: String):
	ball_curve = curve
	last_ball_actor_name = actor_name
	kickoff_delay = 0.0
	set_piece_timer = 0.0
	kickoff_team = -1
	kickoff_wait = 0.0
	_clear_set_piece()
	var actor = players.get_node_or_null(actor_name)
	if actor:
		actor.play_action_local(action)
	if multiplayer.is_server():
		ball.freeze = false
		ball.sleeping = false
		ball.linear_velocity = kick_velocity
		ball.angular_velocity = Vector3(curve * 10.0, 0.0, -kick_velocity.x * 2.2)
	else:
		ball.freeze = true
	ball.sleeping = false
	if action_label:
		var action_names = {"shot": "SHOT!", "pass": "PASS", "through": "THROUGH BALL", "lofted_through": "LOFTED THROUGH BALL", "cross": "CROSS", "clearance": "CLEARANCE"}
		action_label.text = action_names.get(action, "")

func _on_ball_body_entered(body: Node):
	if not multiplayer.is_server() or not (body is CharacterBody3D):
		return
	var player := body as CharacterBody3D
	if _handle_offside_involvement(player):
		return
	last_ball_actor_name = player.name
	if player.role == MatchManager.ROLE_PLAYER and _is_player_selected(player):
		return
	if player.role == MatchManager.ROLE_GOALKEEPER:
		broadcast_player_action.rpc(player.name, "keeper_save")
		if int(diving_peers.get(player.name, 0)) > Time.get_ticks_msec():
			_stop_ball("SAVE")
		return
	var away = (player.global_position - ball.global_position).normalized()
	_apply_player_impulse(player.name, away * 2.2 + Vector3.UP * 0.35)
	ball.apply_central_impulse(-away * 0.35)
	if away.length_squared() > 0.0:
		broadcast_player_action.rpc(player.name, "fall")

func request_tackle(_position: Vector3, _forward: Vector3):
	if not game_started:
		return
	var selected := get_local_selected_player()
	if selected == null:
		return
	if multiplayer.is_server():
		_handle_tackle(multiplayer.get_unique_id(), selected.name)
	else:
		request_tackle_rpc.rpc_id(1, selected.name)

func request_player_action(action: String, actor_name: String = ""):
	if not game_started:
		return
	var selected := get_local_selected_player()
	if actor_name.is_empty():
		if selected == null:
			return
		actor_name = selected.name
	if multiplayer.is_server():
		_handle_player_action(multiplayer.get_unique_id(), actor_name, action)
	else:
		player_action_rpc.rpc_id(1, actor_name, action)

@rpc("any_peer", "call_remote", "reliable")
func player_action_rpc(actor_name: String, action: String):
	if multiplayer.is_server():
		_handle_player_action(multiplayer.get_remote_sender_id(), actor_name, action)

func _handle_player_action(peer_id: int, actor_name: String, action: String):
	if action not in ["tackle", "slide_tackle"]:
		return
	var player := players.get_node_or_null(actor_name) as CharacterBody3D
	if player == null or player.role != MatchManager.ROLE_PLAYER or player.controller_peer_id != peer_id or selected_entity_by_peer.get(peer_id, "") != actor_name:
		return
	_handle_tackle(peer_id, actor_name, action == "slide_tackle")

@rpc("any_peer", "call_remote", "reliable")
func request_tackle_rpc(actor_name: String):
	if multiplayer.is_server():
		_handle_tackle(multiplayer.get_remote_sender_id(), actor_name)

func _handle_tackle(peer_id: int, actor_name: String, slide := false):
	if not game_started or kickoff_delay > 0.0 or ball == null or ball.freeze:
		return
	var player := players.get_node_or_null(actor_name) as CharacterBody3D
	if player == null or player.team != MatchManager.team_for_peer(peer_id) or player.role != MatchManager.ROLE_PLAYER:
		return
	var opponent := _nearest_opponent_to_player(player)
	var tackle_range := 3.0 if slide else 2.4
	if opponent == null or player.global_position.distance_to(opponent.global_position) > tackle_range:
		_play_tackle_attempt(player, -player.global_transform.basis.z, slide)
		return
	var direction := opponent.global_position - player.global_position
	direction.y = 0.0
	if direction.length_squared() < 0.01:
		direction = -player.global_transform.basis.z
	_play_tackle_attempt(player, direction.normalized(), slide)
	_resolve_tackle_contact(player, opponent, direction.normalized())

func _nearest_opponent_to_player(player: CharacterBody3D) -> CharacterBody3D:
	var nearest: CharacterBody3D
	var nearest_distance := INF
	for child in players.get_children():
		var candidate := child as CharacterBody3D
		if candidate == null or candidate.role != MatchManager.ROLE_PLAYER or candidate.team == player.team:
			continue
		var distance := player.global_position.distance_squared_to(candidate.global_position)
		if distance < nearest_distance:
			nearest = candidate
			nearest_distance = distance
	return nearest

func _play_tackle_attempt(player: CharacterBody3D, direction: Vector3, slide := false) -> void:
	direction.y = 0.0
	if direction.length_squared() < 0.01:
		return
	direction = direction.normalized()
	player.rotation.y = atan2(-direction.x, -direction.z)
	player.tackle_timer = 0.9 if slide else 0.7
	player.contact_impulse = (player.contact_impulse + direction * (3.4 if slide else 2.0)).limit_length(5.0)
	broadcast_player_action.rpc(player.name, "slide_tackle" if slide else "tackle")

func _resolve_tackle(tackler: CharacterBody3D, opponent: CharacterBody3D, direction: Vector3) -> void:
	_play_tackle_attempt(tackler, direction)
	_resolve_tackle_contact(tackler, opponent, direction)

func _resolve_tackle_contact(tackler: CharacterBody3D, opponent: CharacterBody3D, direction: Vector3) -> void:
	if opponent.global_position.distance_to(ball.global_position) > 2.7 or tackler.global_position.distance_to(ball.global_position) > 3.5:
		if tackler.global_position.distance_to(opponent.global_position) <= 2.4:
			_call_foul(tackler.name, opponent.global_position)
		return
	var ball_direction := ball.global_position - opponent.global_position
	ball_direction.y = 0.0
	if ball_direction.length_squared() < 0.01:
		ball_direction = -direction
	ball_direction = ball_direction.normalized()
	ball.freeze = false
	ball.sleeping = false
	ball.linear_velocity = ball_direction * 8.0 + Vector3.UP * 0.7
	_clear_offside_state()
	opponent.is_diving = false
	opponent.rotation.z = 0.0
	opponent.velocity = direction * 2.2
	broadcast_player_action.rpc(opponent.name, "fall_flat")

@rpc("authority", "call_local", "reliable")
func broadcast_player_action(actor_name: String, animation_name: String):
	var player = players.get_node_or_null(actor_name)
	if player:
		player.play_action_local(animation_name)

func _call_foul(offender_name: String, foul_position: Vector3):
	var offender := players.get_node_or_null(offender_name) as CharacterBody3D
	if offender == null or set_piece_active or set_piece_timer > 0.0 or kickoff_delay > 0.0:
		return
	if Time.get_ticks_msec() < foul_cooldown_until:
		return
	foul_cooldown_until = Time.get_ticks_msec() + 4000
	var victim_team = MatchManager.TEAM_RED if offender.team == MatchManager.TEAM_BLUE else MatchManager.TEAM_BLUE
	var victim_attacks_toward = -1.0 if victim_team == MatchManager.TEAM_BLUE else 1.0
	var near_goal = absf(foul_position.z - victim_attacks_toward * FIELD_HALF_LENGTH) < 16.5 and absf(foul_position.x) < 20.0
	var location := Vector3(0, BALL_RADIUS, victim_attacks_toward * (FIELD_HALF_LENGTH - PENALTY_SPOT_DISTANCE)) if near_goal else Vector3(
		clampf(foul_position.x, -FIELD_HALF_WIDTH + 2.0, FIELD_HALF_WIDTH - 2.0),
		BALL_RADIUS,
		clampf(foul_position.z, -FIELD_HALF_LENGTH + 2.0, FIELD_HALF_LENGTH - 2.0)
	)
	_start_free_kick(location, victim_team, ("PENALTY" if near_goal else "FREE KICK") + " | MOUSE: AIM | LEFT CLICK: SHOOT")

func _nearest_field_player(location: Vector3, team: int) -> CharacterBody3D:
	var nearest: CharacterBody3D
	var nearest_distance := INF
	for child in players.get_children():
		var candidate := child as CharacterBody3D
		if candidate == null or candidate.role != MatchManager.ROLE_PLAYER or (team >= 0 and candidate.team != team):
			continue
		var distance := candidate.global_position.distance_squared_to(location)
		if distance < nearest_distance:
			nearest = candidate
			nearest_distance = distance
	return nearest

# Dead ball: the nearest player of the given team stands behind the ball facing the opponent goal.
func _start_free_kick(location: Vector3, team: int, message: String) -> void:
	var attack_z := -1.0 if team == MatchManager.TEAM_BLUE else 1.0
	var direction := Vector3(0.0, 0.0, attack_z * FIELD_HALF_LENGTH) - location
	direction.y = 0.0
	direction = direction.normalized()
	var taker := _nearest_field_player(location, team)
	reset_ball.rpc(location, message)
	if taker == null:
		push_error("Free kick restart is missing a field player for team %d." % team)
	else:
		begin_set_piece.rpc(taker.name, location - direction * 1.5, direction, "free_kick")
	kickoff_delay = 1.0

func _keep_opponents_out_of_center_circle() -> void:
	if kickoff_team < 0:
		return
	for child in players.get_children():
		var candidate := child as CharacterBody3D
		if candidate == null or candidate.role != MatchManager.ROLE_PLAYER or candidate.team == kickoff_team:
			continue
		var own_half := _own_half_sign(candidate.team)
		var position := candidate.global_position
		if position.z * own_half < 0.0:
			position.z = 0.0
		var offset := Vector3(position.x, 0.0, position.z)
		if offset.length() < CENTER_CIRCLE_RADIUS:
			if offset.length_squared() < 0.0001:
				offset = Vector3(0.0, 0.0, own_half)
			var pushed := offset.normalized() * CENTER_CIRCLE_RADIUS
			position.x = pushed.x
			position.z = pushed.z
		if not position.is_equal_approx(candidate.global_position):
			candidate.global_position = position

# Matches the side where reset_players_for_kickoff places each team's formation.
func _own_half_sign(team: int) -> float:
	return 1.0 if team == MatchManager.TEAM_BLUE else -1.0

func _auto_kickoff(delta: float) -> void:
	kickoff_wait += delta
	if kickoff_wait < 15.0:
		return
	kickoff_wait = 0.0
	var taker := _nearest_field_player(BALL_START, kickoff_team)
	var own_half := _own_half_sign(kickoff_team)
	var direction := Vector3(match_rng.randf_range(-0.25, 0.25), 0.15, own_half).normalized()
	if taker != null:
		_capture_offside_positions(taker)
	start_ball_action.rpc(direction * match_rng.randf_range(7.0, 10.0), 0.0, "pass", taker.name if taker != null else "")
func request_keeper_dive(side: int):
	if not game_started:
		return
	var selected := get_local_selected_player()
	if selected == null or selected.role != MatchManager.ROLE_GOALKEEPER:
		return
	if multiplayer.is_server():
		_start_keeper_dive(multiplayer.get_unique_id(), selected.name, side)
	else:
		keeper_dive_rpc.rpc_id(1, selected.name, side)

@rpc("any_peer", "call_remote", "reliable")
func keeper_dive_rpc(actor_name: String, side: int):
	if multiplayer.is_server():
		_start_keeper_dive(multiplayer.get_remote_sender_id(), actor_name, side)

func _start_keeper_dive(peer_id: int, actor_name: String, side: int):
	var player := players.get_node_or_null(actor_name) as CharacterBody3D
	if player == null or player.role != MatchManager.ROLE_GOALKEEPER or player.controller_peer_id != peer_id or selected_entity_by_peer.get(peer_id, "") != actor_name:
		return
	diving_peers[actor_name] = Time.get_ticks_msec() + 750
	broadcast_keeper_dive.rpc(actor_name, clampi(side, -1, 1))

func start_ai_keeper_dive(player: CharacterBody3D) -> void:
	if not multiplayer.is_server() or player.role != MatchManager.ROLE_GOALKEEPER or _is_player_selected(player):
		return
	diving_peers[player.name] = Time.get_ticks_msec() + 750
	broadcast_keeper_dive.rpc(player.name, 1 if ball.global_position.x >= player.global_position.x else -1)

@rpc("authority", "call_local", "reliable")
func broadcast_keeper_dive(actor_name: String, side: int):
	var player = players.get_node_or_null(actor_name)
	if player:
		player.set_diving_local(true, side)

func _stop_ball(message: String):
	reset_ball.rpc(ball.global_position, message)

@rpc("authority", "call_local", "reliable")
func reset_ball(position: Vector3, message: String):
	ball.freeze = true
	ball.global_position = position
	ball.linear_velocity = Vector3.ZERO
	ball.angular_velocity = Vector3.ZERO
	if action_label:
		action_label.text = message
	restart_position = position
	set_piece_timer = 15.0
	_clear_set_piece()
	_clear_offside_state()
	last_ball_actor_name = ""
	last_ball_position = position

func _build_net_visuals_placeholder():
	pass

func _physics_process(delta: float):
	if not multiplayer.is_server() or not game_started:
		return
	if goal_celebration_active:
		return
	_keep_opponents_out_of_center_circle()
	_enforce_set_piece_spacing()
	if kickoff_delay > 0.0:
		kickoff_delay = maxf(0.0, kickoff_delay - delta)
		ball.freeze = true
		ball.global_position = restart_position
		return
	if set_piece_timer > 0.0:
		set_piece_timer = maxf(0.0, set_piece_timer - delta)
		if set_piece_timer == 0.0 and ball.freeze:
			var shot_direction := set_piece_direction + Vector3(match_rng.randf_range(-0.3, 0.3), match_rng.randf_range(0.15, 0.48), 0.0) if set_piece_active else Vector3(match_rng.randf_range(-0.45, 0.45), match_rng.randf_range(0.15, 0.48), -signf(restart_position.z))
			var shot_velocity = shot_direction.normalized() * match_rng.randf_range(15.0, 23.0)
			if set_piece_active:
				var taker := players.get_node_or_null(set_piece_taker_name) as CharacterBody3D
				var taker_action := "clearance" if taker != null and taker.role == MatchManager.ROLE_GOALKEEPER else "shot"
				if taker != null:
					_capture_offside_positions(taker)
				start_ball_action.rpc(shot_velocity, 0.0, taker_action, set_piece_taker_name)
			else:
				start_ball_action.rpc(shot_velocity, match_rng.randf_range(-0.45, 0.45), "shot", "")
		return
	_resolve_player_contacts()
	if kickoff_team >= 0 and ball.freeze and not set_piece_active:
		_auto_kickoff(delta)
		return
	if ball.freeze:
		return
	if ball.global_position.y < -2.0:
		var drop_position := Vector3(
			clampf(last_ball_position.x, -FIELD_HALF_WIDTH + 2.0, FIELD_HALF_WIDTH - 2.0),
			BALL_RADIUS,
			clampf(last_ball_position.z, -FIELD_HALF_LENGTH + 2.0, FIELD_HALF_LENGTH - 2.0)
		)
		set_piece_timer = 0.0
		var nearest := _nearest_field_player(drop_position, -1)
		_start_free_kick(drop_position, nearest.team if nearest != null else MatchManager.TEAM_RED, "BALL RETURNED TO PLAY | MOUSE: AIM | LEFT CLICK: SHOOT")
		return
	if absf(ball_curve) > 0.01 and ball.linear_velocity.length() > 3.0:
		var horizontal_velocity = Vector3(ball.linear_velocity.x, 0.0, ball.linear_velocity.z)
		if horizontal_velocity.length_squared() > 0.01:
			var curve_direction = Vector3(-horizontal_velocity.z, 0.0, horizontal_velocity.x).normalized()
			ball.apply_central_force(curve_direction * ball_curve * horizontal_velocity.length() * 0.22)
	if last_ball_position.z > RED_GOAL_LINE_Z and ball.global_position.z <= RED_GOAL_LINE_Z:
		if absf(ball.global_position.x) < GOAL_HALF_WIDTH and ball.global_position.y < GOAL_HEIGHT:
			_score_goal(MatchManager.TEAM_BLUE)
			return
	if last_ball_position.z < BLUE_GOAL_LINE_Z and ball.global_position.z >= BLUE_GOAL_LINE_Z:
		if absf(ball.global_position.x) < GOAL_HALF_WIDTH and ball.global_position.y < GOAL_HEIGHT:
			_score_goal(MatchManager.TEAM_RED)
			return
	if absf(ball.global_position.x) > FIELD_HALF_WIDTH + BALL_RADIUS or absf(ball.global_position.z) > FIELD_HALF_LENGTH + BALL_RADIUS:
		_restart_at_six_yard(ball.global_position)
		return
	sync_timer += delta
	if sync_timer >= 0.05:
		sync_timer = 0.0
		sync_ball.rpc(ball.global_position, ball.rotation, ball.linear_velocity, ball.angular_velocity)
	last_ball_position = ball.global_position
	match_clock = maxf(0.0, match_clock - delta)
	clock_sync_timer += delta
	if clock_sync_timer >= 1.0:
		clock_sync_timer = 0.0
		sync_match_clock.rpc(match_clock)
	if match_clock <= 0.0:
		end_match.rpc(blue_score, red_score)
	_update_scoreboard()

func _process(delta: float):
	_process_selection_keys()
	_update_aim_indicator()
	if multiplayer.is_server() or ball == null or ball.freeze:
		return
	ball.global_position = ball.global_position.lerp(target_ball_position, minf(delta * 18.0, 1.0))
	ball.rotation = ball.rotation.lerp(target_ball_rotation, minf(delta * 14.0, 1.0))

func _process_selection_keys() -> void:
	var q_pressed := Input.is_key_pressed(KEY_Q)
	var g_pressed := Input.is_key_pressed(KEY_G)
	if game_started and MatchManager.local_team() >= 0:
		if q_pressed and not local_q_held:
			select_nearest_local_player()
		if g_pressed and not local_g_held:
			if get_local_selected_player() and get_local_selected_player().role == MatchManager.ROLE_GOALKEEPER:
				select_nearest_local_player()
			else:
				select_local_keeper()
	local_q_held = q_pressed
	local_g_held = g_pressed

func _build_aim_indicator() -> void:
	if DisplayServer.get_name() == "headless":
		return
	aim_indicator_mesh = ImmediateMesh.new()
	aim_indicator = MeshInstance3D.new()
	aim_indicator.name = "BallAimArrow"
	aim_indicator.mesh = aim_indicator_mesh
	aim_indicator.top_level = true
	aim_indicator.global_transform = Transform3D.IDENTITY
	aim_indicator.visible = false
	aim_indicator_material = StandardMaterial3D.new()
	aim_indicator_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	aim_indicator_material.albedo_color = Color(1.0, 0.86, 0.12)
	aim_indicator_material.emission_enabled = true
	aim_indicator_material.emission = Color(0.9, 0.65, 0.04)
	add_child(aim_indicator)

func _update_aim_indicator() -> void:
	if aim_indicator == null or ball == null:
		return
	var player := get_local_selected_player()
	var aiming_set_piece: bool = set_piece_active and player != null and player.name == set_piece_taker_name and player.set_piece_aiming
	if not aiming_set_piece and (ball.freeze or player == null or player.role != MatchManager.ROLE_PLAYER or not can_local_shoot()):
		aim_indicator.visible = false
		return
	var camera := player.get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		aim_indicator.visible = false
		return
	var direction := -camera.global_transform.basis.z.normalized()
	var start := ball.global_position + Vector3.UP * 0.2
	var length: float = 2.0 + player.shot_charge / 1.5 * 8.0
	var tip: Vector3 = start + direction * length
	var side := direction.cross(Vector3.UP).normalized() * 0.35
	aim_indicator_mesh.clear_surfaces()
	aim_indicator_mesh.surface_begin(Mesh.PRIMITIVE_LINES, aim_indicator_material)
	aim_indicator_mesh.surface_add_vertex(start)
	aim_indicator_mesh.surface_add_vertex(tip)
	aim_indicator_mesh.surface_add_vertex(tip)
	aim_indicator_mesh.surface_add_vertex(tip - direction * 0.7 + side)
	aim_indicator_mesh.surface_add_vertex(tip)
	aim_indicator_mesh.surface_add_vertex(tip - direction * 0.7 - side)
	aim_indicator_mesh.surface_end()
	aim_indicator.visible = true

func _restart_at_six_yard(out_position: Vector3):
	if absf(out_position.x) > FIELD_HALF_WIDTH + BALL_RADIUS \
		and absf(out_position.z) <= FIELD_HALF_LENGTH + BALL_RADIUS:
		_start_throw_in(out_position)
		return
	var end_sign := -1.0 if out_position.z < 0.0 else 1.0
	var defending_team := MatchManager.TEAM_BLUE if end_sign > 0.0 else MatchManager.TEAM_RED
	var last_touch := players.get_node_or_null(last_ball_actor_name) as CharacterBody3D
	if last_touch != null and last_touch.team == defending_team:
		_start_corner_kick(out_position, defending_team)
		return
	var restart_z := end_sign * (FIELD_HALF_LENGTH - 5.5)
	var restart_x := clampf(out_position.x, -9.0, 9.0)
	var restart_spot := Vector3(restart_x, BALL_RADIUS, restart_z)
	var keeper: CharacterBody3D
	for child in players.get_children():
		var candidate := child as CharacterBody3D
		if candidate == null or candidate.role != MatchManager.ROLE_GOALKEEPER or candidate.team != defending_team:
			continue
		keeper = candidate
		break
	reset_ball.rpc(restart_spot, "GOAL KICK | MOUSE: AIM | LEFT CLICK: SHOOT | 15 SEC")
	if keeper == null:
		push_error("Goal kick restart is missing a goalkeeper.")
	else:
		begin_set_piece.rpc(keeper.name, Vector3(restart_x, 0.0, restart_z + end_sign * 1.3), Vector3(0.0, 0.0, -end_sign), "goal_kick")
	kickoff_delay = 1.0

func _start_throw_in(out_position: Vector3) -> void:
	var last_touch := players.get_node_or_null(last_ball_actor_name) as CharacterBody3D
	var restarting_team := MatchManager.TEAM_RED if last_touch == null or last_touch.team == MatchManager.TEAM_BLUE else MatchManager.TEAM_BLUE
	var side_sign := signf(out_position.x)
	var location := Vector3(
		side_sign * (FIELD_HALF_WIDTH - 0.25),
		BALL_RADIUS,
		clampf(out_position.z, -FIELD_HALF_LENGTH + 0.75, FIELD_HALF_LENGTH - 0.75)
	)
	var taker := _nearest_field_player(location, restarting_team)
	reset_ball.rpc(location, "THROW-IN | TAKE WITHIN 15 SEC")
	if taker == null:
		push_error("Throw-in restart is missing a field player for team %d." % restarting_team)
		return
	var direction := Vector3(-side_sign * 0.25, 0.0, _attack_sign(restarting_team)).normalized()
	begin_set_piece.rpc(taker.name, location + Vector3(-side_sign * 1.0, 0.0, 0.0), direction, "throw_in")
	kickoff_delay = 1.0

func _start_corner_kick(out_position: Vector3, defending_team: int) -> void:
	var attacking_team := MatchManager.TEAM_RED if defending_team == MatchManager.TEAM_BLUE else MatchManager.TEAM_BLUE
	var side_sign := -1.0 if out_position.x < 0.0 else 1.0
	var end_sign := -1.0 if out_position.z < 0.0 else 1.0
	var location := Vector3(
		side_sign * (FIELD_HALF_WIDTH - 0.75),
		BALL_RADIUS,
		end_sign * (FIELD_HALF_LENGTH - 0.75)
	)
	var taker := _nearest_field_player(location, attacking_team)
	reset_ball.rpc(location, "CORNER | TAKE WITHIN 15 SEC")
	if taker == null:
		push_error("Corner restart is missing a field player for team %d." % attacking_team)
		return
	var direction := Vector3(-side_sign, 0.0, -end_sign * 0.3).normalized()
	begin_set_piece.rpc(
		taker.name,
		location - direction * 1.5,
		direction,
		"corner"
	)
	kickoff_delay = 1.0

@rpc("authority", "call_local", "reliable")
func begin_set_piece(taker_name: String, taker_position: Vector3, direction: Vector3, restart_kind: String) -> void:
	set_piece_active = true
	set_piece_taker_name = taker_name
	set_piece_direction = direction
	set_piece_kind = restart_kind
	var taker := players.get_node_or_null(taker_name) as CharacterBody3D
	if taker == null:
		push_error("Set piece references missing player %s." % taker_name)
		set_piece_active = false
		return
	taker.global_position = Vector3(taker_position.x, taker.global_position.y, taker_position.z)
	taker.velocity = Vector3.ZERO
	taker.rotation = Vector3(0.0, atan2(-direction.x, -direction.z), 0.0)
	if taker.controller_peer_id == multiplayer.get_unique_id():
		_set_local_selection(taker)
		taker.begin_set_piece_aim()

func _clear_set_piece() -> void:
	if set_piece_active:
		var taker := players.get_node_or_null(set_piece_taker_name) as CharacterBody3D
		if taker != null:
			taker.end_set_piece_aim()
	set_piece_active = false
	set_piece_taker_name = ""
	set_piece_kind = ""

func _enforce_set_piece_spacing() -> void:
	if not set_piece_active:
		return
	var taker := players.get_node_or_null(set_piece_taker_name) as CharacterBody3D
	if taker == null:
		return
	var restart := ball.global_position
	for child in players.get_children():
		var candidate := child as CharacterBody3D
		if candidate == null or candidate == taker:
			continue
		var position := candidate.global_position
		if set_piece_kind == "free_kick":
			if candidate.team == taker.team:
				continue
			var away := Vector3(position.x - restart.x, 0.0, position.z - restart.z)
			if away.length() >= FREE_KICK_DEFENDER_DISTANCE:
				continue
			if away.length_squared() < 0.0001:
				away = Vector3(-set_piece_direction.z, 0.0, set_piece_direction.x)
			var moved := restart + away.normalized() * (FREE_KICK_DEFENDER_DISTANCE + 0.1)
			position.x = clampf(moved.x, -FIELD_HALF_WIDTH + 0.5, FIELD_HALF_WIDTH - 0.5)
			position.z = clampf(moved.z, -FIELD_HALF_LENGTH + 0.5, FIELD_HALF_LENGTH - 0.5)
		elif set_piece_kind == "goal_kick":
			var goal_sign := signf(restart.z)
			var in_penalty_area := absf(position.x) < PENALTY_AREA_HALF_WIDTH + 0.5 \
				and absf(position.z - goal_sign * FIELD_HALF_LENGTH) < PENALTY_AREA_DEPTH + 0.5
			if not in_penalty_area:
				continue
			position.z = goal_sign * (FIELD_HALF_LENGTH - PENALTY_AREA_DEPTH - 0.75)
		elif set_piece_kind in ["throw_in", "corner"] and candidate.team != taker.team:
			var minimum_distance := 2.0 if set_piece_kind == "throw_in" else 9.15
			var away := Vector3(position.x - restart.x, 0.0, position.z - restart.z)
			if away.length() >= minimum_distance:
				continue
			if away.length_squared() < 0.0001:
				away = Vector3(-set_piece_direction.z, 0.0, set_piece_direction.x)
			var moved := restart + away.normalized() * (minimum_distance + 0.1)
			position.x = clampf(moved.x, -FIELD_HALF_WIDTH + 0.5, FIELD_HALF_WIDTH - 0.5)
			position.z = clampf(moved.z, -FIELD_HALF_LENGTH + 0.5, FIELD_HALF_LENGTH - 0.5)
		if not position.is_equal_approx(candidate.global_position):
			candidate.global_position = position
func _resolve_player_contacts():
	var field_players: Array[Node3D] = []
	for child in players.get_children():
		if child is CharacterBody3D:
			field_players.append(child as Node3D)
	for first_index in range(field_players.size()):
		var first = field_players[first_index]
		for second_index in range(first_index + 1, field_players.size()):
			var second = field_players[second_index]
			var separation = second.global_position - first.global_position
			separation.y = 0.0
			var distance = separation.length()
			if distance < 0.001 or distance >= 0.68:
				continue
			if first.team == second.team:
				continue
			var first_id: String = first.name
			var second_id: String = second.name
			var pair_key := "%s:%s" % [first_id, second_id] if first_id < second_id else "%s:%s" % [second_id, first_id]
			var now = Time.get_ticks_msec()
			if contact_cooldowns.get(pair_key, 0) > now:
				continue
			contact_cooldowns[pair_key] = now + 180
			var normal = separation.normalized()
			var shove = normal * (1.6 + (0.68 - distance) * 6.0)
			_apply_player_impulse(first_id, -shove)
			_apply_player_impulse(second_id, shove)

func _apply_player_impulse(actor_name: String, impulse: Vector3):
	var player := players.get_node_or_null(actor_name) as CharacterBody3D
	if player == null:
		return
	player.apply_contact_impulse_local(impulse)

var target_ball_position := BALL_START
var target_ball_rotation := Vector3.ZERO

@rpc("authority", "call_remote", "unreliable_ordered")
func sync_ball(position: Vector3, rotation: Vector3, _linear_velocity: Vector3, _angular_velocity: Vector3):
	target_ball_position = position
	target_ball_rotation = rotation
	if ball.freeze:
		ball.global_position = position
		ball.rotation = rotation

@rpc("authority", "call_remote", "unreliable_ordered")
func sync_match_clock(seconds_remaining: float):
	match_clock = seconds_remaining
	_update_scoreboard()

func _score_goal(team: int):
	if goal_celebration_active:
		return
	goal_celebration_active = true
	if team == MatchManager.TEAM_BLUE:
		blue_score += 1
	else:
		red_score += 1
	var defending_team := MatchManager.TEAM_RED if team == MatchManager.TEAM_BLUE else MatchManager.TEAM_BLUE
	shake_nets.rpc(defending_team)
	show_score.rpc(blue_score, red_score, "GOOOL!")
	var scorer := players.get_node_or_null(last_ball_actor_name) as CharacterBody3D
	if scorer == null or scorer.team != team or scorer.role != MatchManager.ROLE_PLAYER:
		scorer = _nearest_field_player(ball.global_position, team)
	if scorer != null:
		focus_goal_scorer_camera.rpc(scorer.name)
	reset_ball.rpc(ball.global_position, "GOOOL!")
	kickoff_delay = 0.0
	set_piece_timer = 0.0
	kickoff_team = MatchManager.TEAM_BLUE if team == MatchManager.TEAM_RED else MatchManager.TEAM_RED
	var flip_animation: StringName = &"goal_flip"
	var dance_animation: StringName = (
		&"human_goal_celebration"
		if team == MatchManager.TEAM_RED
		else &"robot_goal_celebration"
	)
	var celebration_duration := 0.0
	for child in players.get_children():
		var player := child as CharacterBody3D
		if player == null or player.role != MatchManager.ROLE_PLAYER or player.team != team:
			continue
		celebration_duration = maxf(
			celebration_duration,
			player.goal_celebration_duration(flip_animation, dance_animation)
		)
	start_goal_celebration.rpc(team, flip_animation, dance_animation)
	if celebration_duration > 0.0:
		await get_tree().create_timer(celebration_duration + 0.2).timeout
	if not is_inside_tree():
		return
	restore_goal_camera.rpc()
	reset_ball.rpc(BALL_START, "KICK-OFF")
	kickoff_delay = 3.0
	set_piece_timer = 0.0
	reset_players_for_kickoff.rpc(kickoff_team)

@rpc("authority", "call_local", "reliable")
func focus_goal_scorer_camera(player_name: String):
	var match_world := get_parent()
	if match_world == null or not match_world.has_method("focus_goal_scorer"):
		push_error("The match world cannot focus the goal scorer camera.")
		return
	match_world.call("focus_goal_scorer", player_name)

@rpc("authority", "call_local", "reliable")
func restore_goal_camera():
	var match_world := get_parent()
	if match_world == null or not match_world.has_method("restore_stadium_camera"):
		push_error("The match world cannot restore the stadium camera.")
		return
	match_world.call("restore_stadium_camera")

@rpc("authority", "call_local", "reliable")
func start_goal_celebration(team: int, flip_animation: StringName, dance_animation: StringName):
	for child in players.get_children():
		var player := child as CharacterBody3D
		if player == null or player.role != MatchManager.ROLE_PLAYER:
			continue
		if player.team == team:
			player.start_goal_celebration_local(flip_animation, dance_animation)
		else:
			player.pause_for_goal_celebration_local()

@rpc("authority", "call_local", "reliable")
func reset_players_for_kickoff(team_with_kickoff: int):
	for child in players.get_children():
		if not child is CharacterBody3D or child.role != MatchManager.ROLE_PLAYER:
			continue
		var player := child as CharacterBody3D
		player.goal_celebration_active = false
		var player_team: int = player.team
		var team_sign := _own_half_sign(player_team)
		var is_kickoff_player: bool = player_team == team_with_kickoff and player.field_slot == 8
		var team_name := "Blue" if player_team == MatchManager.TEAM_BLUE else "Red"
		var spawn_marker := get_node_or_null("../MatchEnvironment/PlayerSpawns/%sFieldPlayer%d" % [team_name, player.field_slot]) as Marker3D
		var formation_spawn := MatchManager.match_formation_position(player_team, player.field_slot)
		if spawn_marker:
			formation_spawn = spawn_marker.global_position
		formation_spawn.y = 0.0
		formation_spawn.z = team_sign * maxf(absf(formation_spawn.z), 8.0)
		if is_kickoff_player:
			player.global_position = Vector3(0.0, 0.0, team_sign * 0.85)
			player.rotation.y = 0.0 if player_team == MatchManager.TEAM_BLUE else PI
		else:
			if spawn_marker:
				player.global_position = formation_spawn
				player.global_rotation.y = spawn_marker.global_rotation.y
			else:
				player.global_position = formation_spawn
				player.rotation.y = 0.0 if player_team == MatchManager.TEAM_BLUE else PI
		player.velocity = Vector3.ZERO
		player.spawn_position = formation_spawn

@rpc("authority", "call_local", "reliable")
func shake_nets(defending_team: int):
	var net_parts: Array = goal_nets.get(defending_team, [])
	if net_parts.is_empty():
		push_error("Goal net for defending team %d is not available to shake." % defending_team)
		return
	for net_part in net_parts:
		if net_part is Node3D:
			_shake_goal_net(net_part)

func _shake_goal_net(net: Node3D):
	var tween := create_tween()
	var origin := net.position
	var origin_rotation := net.rotation
	for _index in range(3):
		tween.tween_property(net, "position:x", origin.x + 0.18, 0.07)
		tween.parallel().tween_property(net, "position:z", origin.z + 0.12, 0.07)
		tween.parallel().tween_property(net, "rotation:y", origin_rotation.y + deg_to_rad(5.0), 0.07)
		tween.tween_property(net, "position:x", origin.x - 0.18, 0.07)
		tween.parallel().tween_property(net, "position:z", origin.z - 0.12, 0.07)
		tween.parallel().tween_property(net, "rotation:y", origin_rotation.y - deg_to_rad(5.0), 0.07)
	tween.tween_property(net, "position", origin, 0.16)
	tween.parallel().tween_property(net, "rotation", origin_rotation, 0.16)

@rpc("authority", "call_local", "reliable")
func show_score(blue: int, red: int, message: String):
	blue_score = blue
	red_score = red
	if action_label:
		action_label.text = message
	_update_scoreboard()

@rpc("authority", "call_local", "reliable")
func end_match(blue: int, red: int):
	game_started = false
	if match_end_label:
		match_end_label.text = "ROBOT WINS" if blue > red else ("HUMAN WINS" if red > blue else "DRAW")
		match_end_label.visible = true
	if waiting_label:
		waiting_label.visible = true
		waiting_label.text = "MATCH OVER\n" + match_end_label.text

func _on_match_state_changed(ready: bool):
	game_started = ready
	if ready and multiplayer.is_server():
		sync_match_clock.rpc(match_clock)
		if kickoff_team < 0 and blue_score + red_score == 0 and ball != null and ball.global_position.distance_to(BALL_START) < 0.5:
			kickoff_team = MatchManager.TEAM_RED
	if ready:
		call_deferred("_select_initial_local_player")
	else:
		selected_entity_by_peer.clear()
		controller_input_by_peer.clear()
		if is_instance_valid(local_selected_entity):
			local_selected_entity._set_local_selected(false)
		local_selected_entity = null
	
	if waiting_label:
		waiting_label.visible = not ready
		waiting_label.text = "Waiting for a HUMAN player. The ROBOT team is controlled by the computer." if not ready else ""
	if action_label:
		if not ready:
			action_label.text = ""
		else:
			action_label.text = "Arrows: move | E: sprint | D: shoot/tackle | S: short pass | A: long pass/sliding tackle | W: through ball | Q+W: lofted through ball | C: mark | Q: switch player | G: goalkeeper"
	if not ready and ball:
		ball.freeze = true
		ball.position = BALL_START
		ball.linear_velocity = Vector3.ZERO
		ball.angular_velocity = Vector3.ZERO
	_update_scoreboard()

func _select_initial_local_player() -> void:
	for _attempt in range(20):
		await get_tree().process_frame
		if not game_started:
			return
		if MatchManager.local_team() < 0:
			return
		if is_instance_valid(local_selected_entity):
			return
		select_nearest_local_player()

func _on_role_selection_rejected(message: String):
	MatchManager.last_rejection = message
	MatchManager.disconnect_client()
	get_tree().change_scene_to_file("res://lobby.tscn")

func _update_scoreboard():
	if scoreboard_home_score:
		scoreboard_home_score.text = str(red_score)
		scoreboard_away_score.text = str(blue_score)
		scoreboard_clock.text = "%02d:%02d" % [int(match_clock) / 60, int(match_clock) % 60]

func update_charge(amount: float, charging: bool, curve: float, action: String = ""):
	if power_bar:
		var selected := get_local_selected_player()
		power_bar.visible = charging and game_started and selected != null and (selected.role == MatchManager.ROLE_PLAYER or set_piece_active)
		power_bar.value = amount
	if action_label and charging and not action.is_empty():
		var action_names := {"shot": "SHOT", "pass": "SHORT PASS", "through": "THROUGH BALL", "lofted_through": "LOFTED THROUGH BALL", "cross": "LONG PASS"}
		action_label.text = "%s POWER: %d%%" % [action_names.get(action, "KICK"), roundi(amount / 1.5 * 100.0)]
	if action_label and charging and absf(curve) > 0.05:
		action_label.text = "CURVE: %s" % ("RIGHT" if curve > 0.0 else "LEFT")
