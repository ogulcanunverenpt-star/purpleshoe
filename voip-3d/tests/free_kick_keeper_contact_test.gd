extends SceneTree

const CONTROLLER = preload("res://free_kick_controller.gd")

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
		quit(1)
	return condition

func _run() -> void:
	var game = CONTROLLER.new()
	var keeper := Node3D.new()
	root.add_child(keeper)
	var skeleton := Skeleton3D.new()
	keeper.add_child(skeleton)
	skeleton.add_bone("Hips")
	skeleton.set_bone_rest(0, Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)))
	var ball := Node3D.new()
	root.add_child(ball)
	game.keeper_root = keeper
	game.keeper_skeleton = skeleton
	game.ball = ball

	ball.global_position = Vector3(0.49, 1.0, 0.5)
	game.ball_velocity = Vector3.FORWARD * 10.0
	if not _check(not game._resolve_keeper_ball_collision() and not game.keeper_save_confirmed, "Keeper caught a ball outside contact range."):
		return

	ball.global_position = Vector3(0, 1.0, 0.45)
	game.ball_velocity = Vector3.BACK * 10.0
	if not _check(not game._resolve_keeper_ball_collision() and not game.keeper_save_confirmed, "Keeper caught a ball moving away."):
		return

	game.ball_velocity = Vector3.FORWARD * 10.0
	if not _check(game._resolve_keeper_ball_collision() and game.keeper_has_ball and game.keeper_save_confirmed, "Keeper did not catch a ball on contact."):
		return

	game.keeper_has_ball = false
	game.keeper_save_confirmed = false
	game.keeper_skeleton = null
	ball.global_position = Vector3(3, 1.0, 0)
	game.ball_velocity = Vector3.LEFT * 10.0
	if not _check(not game._resolve_keeper_ball_collision() and not game.keeper_save_confirmed, "Keeper without skeleton collided with a distant ball."):
		return

	game.free()
	keeper.free()
	ball.free()
	quit(0)
