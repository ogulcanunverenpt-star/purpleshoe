class_name PSXAssetWalker
extends CharacterBody3D
## First person walker for the demo scene.
##
## Drop the Player scene into any level, press play and walk. Mouse looks around,
## WASD moves, Shift runs, Space jumps, Escape frees the cursor.
##
## The camera sits at eye height on a separate node so head bob never rotates the
## body - a body that pitches with the view walks into the ground on a slope.
##
## [b]The defaults are built for this pack, which is not at human scale.[/b] Its
## fences measure 2.0 to 5.5 m and its telegraph poles 17.5 m, roughly three times
## a real one, so a 1.8 m walker looks like a child among the props. Eye height,
## capsule and speed are all scaled by the same factor - change [member world_scale]
## and the walker fits a normally sized level again.

@export_group("Scale")
## How much larger this world is than a human one. Everything below is written at
## human size and multiplied by this, so one number refits the walker to a level.
## Measured on this pack: fences 2.0-5.5 m, telegraph poles 17.5 m -> about 3.
@export_range(0.25, 10.0, 0.05) var world_scale: float = 3.0:
	set(value):
		world_scale = value
		_rescale()

@export_group("Movement")
## Metres per second at a normal walk, before world_scale. A person walks about
## 1.4 m/s; this is a little faster because a game world is emptier than a street.
@export_range(0.5, 12.0, 0.1) var walk_speed: float = 2.6
@export_range(0.5, 20.0, 0.1) var run_speed: float = 5.2
## Metres per second upward at the moment of the jump, before world_scale.
## 3.2 is a standing jump: about half a metre high and two thirds of a second in
## the air. Measured in engine at world_scale 3: 1.55 m and 0.65 s.
@export_range(0.0, 12.0, 0.1) var jump_velocity: float = 3.2
## Gravity scales with the world too, and leaving it out is what makes a large
## level feel like the moon. Make every length N times bigger and keep the same
## timing, and both speed and acceleration have to be N times bigger as well - so
## a 3x world needs about 29 m/s² for a jump that lands when the eye expects it.
## At 1.0 the walker falls at the project's own gravity.
@export_range(0.25, 10.0, 0.05) var gravity_scale: float = 1.0:
	set(value):
		gravity_scale = value
## How quickly the walker reaches full speed. Low numbers feel like ice.
@export_range(1.0, 40.0, 0.5) var acceleration: float = 12.0

## Tallest edge the walker climbs without jumping, before world_scale.
## CharacterBody3D has no step handling of its own: it stops dead against anything
## it cannot slide along, however low. In a pack built at three times human scale a
## kerb is 0.6 m and a road edge 0.8 m, so without this the walker jams on scenery
## a person would not even feel. Measured on this pack 2026-09-21: the walk stopped
## after twelve seconds at (-70.2, 21.3) on a 0.64 m edge and never moved again.
## 0.45 is a kerb at human size; at world_scale 3 that is 1.35 m.
@export_range(0.0, 1.0, 0.01) var max_step_height: float = 0.45

@export_group("Look")
@export_range(0.01, 1.0, 0.01) var mouse_sensitivity: float = 0.18
## Degrees the view can tilt up or down before it stops.
@export_range(30.0, 89.0, 1.0) var pitch_limit: float = 85.0

@export_group("Start")
## Put the walker on the ground before the first frame instead of dropping it.
## A spawn point left a few metres too high starts the demo with a fall the player
## did not ask for, and in a world three times human scale that fall lasts long
## enough to look like a bug. The probe looks down from high above the spawn point,
## so it also catches a point placed below the terrain.
@export var snap_to_ground_on_start: bool = true
## How far up the probe starts, before world_scale.
@export_range(1.0, 200.0, 1.0) var ground_probe_height: float = 60.0

@export_group("Head bob")
## Vertical sway while walking. Switch it off for a steady camera on video.
@export var head_bob_enabled: bool = true
@export_range(0.0, 0.2, 0.005) var head_bob_height: float = 0.035
@export_range(0.0, 30.0, 0.5) var head_bob_speed: float = 9.0
## Side to side sway, half the bob frequency - one sway per pair of steps, the way
## weight shifts from leg to leg. Vertical bob alone looks like a camera on a spring.
@export_range(0.0, 0.2, 0.005) var head_bob_side: float = 0.022
## Degrees the view rolls into that sway. Small: above about two degrees it stops
## looking like a head and starts looking like a boat.
@export_range(0.0, 4.0, 0.1) var head_bob_roll: float = 0.8


@onready var _head: Node3D = $Head
@onready var _camera: Camera3D = $Head/Camera3D
@onready var _shape: CollisionShape3D = $Collision

## Eye height and capsule at human size; world_scale multiplies both.
const EYE_HEIGHT := 1.65
const BODY_HEIGHT := 1.8
const BODY_RADIUS := 0.3

var _bob_time := 0.0
var _rest_height := 0.0
var _sway_roll := 0.0
## The hand either HOLDS and looks, or FLICKS the beam somewhere new. Without those two
## states the motion is continuous, and continuous motion is swaying, not searching.
## Stiffness of the current flick - each one differs, hence the varying intensity.
## Time to the next VIOLENT flick. A separate clock from the ordinary flicks, because
## this is meant to be an event the viewer is not braced for, not the strongest of a run.
## Every dozen seconds or so the hand RESTS - it stands completely still for a moment.
## Drop-outs left in the current burst - a bad contact rarely goes out just once.


func _ready() -> void:
	_rescale()
	_rest_height = _head.position.y
	if snap_to_ground_on_start:
		snap_to_ground()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Moves the walker down onto the first solid surface under the spawn point. Called
## on ready and usable from a recording script that teleports the walker around.
func snap_to_ground() -> void:
	var space := get_world_3d().direct_space_state
	var top := global_position + Vector3.UP * ground_probe_height * world_scale
	var bottom := global_position + Vector3.DOWN * ground_probe_height * world_scale
	var query := PhysicsRayQueryParameters3D.create(top, bottom)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return
	# Ground plus a hair, so the first physics frame settles instead of starting
	# inside the surface and being pushed out sideways.
	global_position = hit["position"] + Vector3.UP * 0.02 * world_scale
	velocity = Vector3.ZERO


## Capsule, eye height and the camera's far plane all follow world_scale. The far
## plane matters: a walker three times the size covers ground three times faster,
## and a clipping plane left at human distance cuts the horizon off mid-stride.
func _rescale() -> void:
	if not is_inside_tree():
		return
	var s := world_scale
	_head.position.y = EYE_HEIGHT * s
	_rest_height = _head.position.y
	if _shape and _shape.shape is CapsuleShape3D:
		var capsule := _shape.shape as CapsuleShape3D
		capsule.height = BODY_HEIGHT * s
		capsule.radius = BODY_RADIUS * s
		_shape.position.y = capsule.height * 0.5
	if _camera:
		# DEPTH PRECISION IS DECIDED BY THE RATIO OF THESE TWO NUMBERS, not by their
		# values. It was 0.15 to 1800, which is 1:12000 - over that span the buffer loses
		# resolution in the distance and two surfaces lying close together start to
		# flicker. Measured 2026-09-22: 35 rays out of 4400 hit a mesh standing less than
		# 8 cm above the terrain, so the scene holds dozens of such pairs. Now 0.6 to
		# 1200, which is 1:2000 - six times the precision at zero cost to the picture:
		# nothing in this scene comes closer to the eye than 0.6 units (0.2 human metres),
		# and the fog eats the horizon long before 1200 anyway.
		_camera.far = 400.0 * s
		_camera.near = 0.2 * s


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Yaw turns the whole body, pitch only the head. Rotating the body on both
		# axes would tip the collision capsule over and the walker would sink.
		rotate_y(-deg_to_rad(event.relative.x * mouse_sensitivity))
		_head.rotation.x = clampf(
				_head.rotation.x - deg_to_rad(event.relative.y * mouse_sensitivity),
				-deg_to_rad(pitch_limit), deg_to_rad(pitch_limit))
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = (Input.MOUSE_MODE_VISIBLE
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
				else Input.MOUSE_MODE_CAPTURED)
	elif event is InputEventMouseButton and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * gravity_scale * world_scale * delta
	elif Input.is_key_pressed(KEY_SPACE):
		velocity.y = jump_velocity * world_scale

	var wish := Vector2(
			float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
			float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	if wish.length_squared() > 1.0:
		wish = wish.normalized()

	var speed := (run_speed if Input.is_key_pressed(KEY_SHIFT) else walk_speed) * world_scale
	var dir := (transform.basis * Vector3(wish.x, 0.0, wish.y))
	var target := Vector3(dir.x * speed, velocity.y, dir.z * speed)
	velocity.x = move_toward(velocity.x, target.x, acceleration * world_scale * delta)
	velocity.z = move_toward(velocity.z, target.z, acceleration * world_scale * delta)

	move_and_slide()
	if is_on_wall():
		_step_up(dir)
	_bob(delta, speed)


## Three probes, in the order a leg would do it: is there room to rise, is there room
## to move forward up there, and is there ground to come down onto. Any of the three
## failing means this is a wall, not a step, and the walker stays where it is.
func _step_up(direction: Vector3) -> void:
	if max_step_height <= 0.0 or direction.length_squared() < 0.01:
		return
	var step := max_step_height * world_scale
	var forward := direction.normalized() * BODY_RADIUS * world_scale * 1.6
	var here := global_transform
	if test_move(here, Vector3.UP * step):
		return
	var top := Transform3D(here.basis, here.origin + Vector3.UP * step)
	if test_move(top, forward):
		return
	var ahead := Transform3D(here.basis, top.origin + forward)
	# With no ground underneath this is not a step but a ledge - climbing it would
	# lift the player into the air over a drop.
	if not test_move(ahead, Vector3.DOWN * (step + 0.1)):
		return
	global_position = ahead.origin


func _bob(delta: float, speed: float) -> void:
	var flat_speed := Vector2(velocity.x, velocity.z).length()
	var moving := is_on_floor() and flat_speed > 0.1 * world_scale
	var height := _rest_height
	var side := 0.0
	var roll := 0.0

	if head_bob_enabled and moving:
		# Sway follows real speed, not the key held down, so slowing against
		# a wall calms the camera instead of bobbing on the spot.
		_bob_time += delta * head_bob_speed * (flat_speed / maxf(speed, 0.001))
		height += sin(_bob_time) * head_bob_height * world_scale
		# Half frequency: the body leans onto one leg, then onto the other.
		side = sin(_bob_time * 0.5) * head_bob_side * world_scale
		roll = -sin(_bob_time * 0.5) * deg_to_rad(head_bob_roll)
	elif not head_bob_enabled:
		_bob_time = 0.0
	else:
		_bob_time = 0.0

	if not head_bob_enabled:
		_head.position = Vector3(0.0, _rest_height, 0.0)
		_head.rotation.z = 0.0
		return

	_head.position.y = height
	_head.position.x = side
	_sway_roll = lerpf(_sway_roll, roll, clampf(delta * 6.0, 0.0, 1.0))
	_head.rotation.z = _sway_roll
