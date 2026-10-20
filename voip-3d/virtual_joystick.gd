extends Control
class_name MobileVirtualJoystick

var value := Vector2.ZERO
var touch_index := -1

@export var radius := 68.0

func _ready():
	mouse_filter = Control.MOUSE_FILTER_STOP

func _input(event):
	if not is_visible_in_tree():
		return
	if event is InputEventScreenTouch:
		if event.pressed and touch_index == -1 and get_global_rect().has_point(event.position):
			touch_index = event.index
			_update_value(event.position)
			get_viewport().set_input_as_handled()
		elif not event.pressed and event.index == touch_index:
			touch_index = -1
			value = Vector2.ZERO
			queue_redraw()
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and event.index == touch_index:
		_update_value(event.position)
		get_viewport().set_input_as_handled()

func _update_value(screen_position: Vector2):
	var local_position = get_global_transform_with_canvas().affine_inverse() * screen_position
	var offset = local_position - size * 0.5
	if offset.length() > radius:
		offset = offset.normalized() * radius
	value = offset / radius
	queue_redraw()

func _draw():
	var center = size * 0.5
	draw_circle(center, radius, Color(0.05, 0.07, 0.09, 0.48))
	draw_arc(center, radius, 0.0, TAU, 48, Color(0.86, 0.9, 0.92, 0.68), 2.0, true)
	draw_circle(center + value * radius, radius * 0.34, Color(0.92, 0.94, 0.92, 0.9))
