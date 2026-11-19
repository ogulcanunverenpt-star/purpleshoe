extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var manager = load("res://openworld/chunk_manager.gd").new()
	manager.cell_size = 20.0
	manager.terrain = load("res://openworld/terrain.gd").new()
	manager.terrain.setup({"amplitude": 7.0, "frequency": 0.005, "seed": 91, "resolution": 10})
	var terrain_cell: Node3D = manager.terrain.cell_terrain(Vector3.ZERO, manager.cell_size, null, false)
	terrain_cell.free()
	var roads := Node3D.new()
	for direction in ["ew", "ns"]:
		manager._road_strip(roads, Vector3.ZERO, direction, 7.0)
	for overlay in roads.get_children():
		var mesh_instance := overlay as MeshInstance3D
		if mesh_instance == null or not mesh_instance.mesh is ArrayMesh:
			push_error("Road overlay is not a terrain-following mesh.")
			quit(1)
			return
		var vertices: PackedVector3Array = mesh_instance.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for i in range(0, vertices.size(), 3):
			var point := (vertices[i] + vertices[i + 1] + vertices[i + 2]) / 3.0
			var clearance: float = point.y - manager.terrain.height(point.x, point.z)
			if clearance < 0.005 or clearance > 0.04:
				push_error("Road surface does not follow terrain at %s: clearance %s" % [point, clearance])
				quit(1)
				return
	roads.free()
	manager.free()
	print("Open-world road terrain alignment passed.")
	quit()
