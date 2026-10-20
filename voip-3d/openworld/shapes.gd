class_name GShapes
## SHAPE VOCABULARY — the FORM axis of the construction system. A small, VETTED, render-tested library of
## parametric solid factories. The agent only PARAMETERIZES these (it never emits raw vertices), so any
## architectural silhouette — house, pyramid, obelisk, pylon, tower, column, dome, spire — composes from the
## SAME vocabulary. Theme-agnostic: a pyramid and a gable house are two parameterizations, not two generators.
##
## Built mostly from Godot built-in primitive meshes (BoxMesh / CylinderMesh with top+bottom radius / PrismMesh /
## SphereMesh hemisphere) + transforms, so there is almost no hand-authored geometry to get wrong. The ONLY
## ArrayMesh shape is the rectangular frustum/pyramid (no primitive covers a rect base tapering to a smaller rect
## or a point); its faces are emitted with outward normals + correct winding computed from the convex centroid,
## so it can never render inside-out. gl_compatibility / WebGL2-safe.
##
## CONTRACT: every factory returns a MeshInstance3D (or Node3D for composed shapes) whose visual BASE sits at
## local y=0 and is CENTERED at local x=z=0 — so callers place a shape by its footprint corner/centre like a
## building. Materials are applied by the caller (surfaces.gd); add_collider() wraps a solid collider.

# ─────────────────────────────── primitive-based solids ───────────────────────────────

## A box. size = (width, height, depth). Base at y=0.
static func box(size: Vector3) -> MeshInstance3D:
	var m := BoxMesh.new()
	m.size = size
	return _mi(m, size.y * 0.5)


## A round/cone/n-gon vertical solid. bottom_r/top_r let it taper (top_r=0 -> cone/spire); sides controls the
## cross-section (sides=4 -> a square pier, 6 -> hex column, 8 -> octagon, >=24 -> round column). Base at y=0.
static func cylinder(bottom_r: float, top_r: float, height: float, sides: int = 24) -> MeshInstance3D:
	var m := CylinderMesh.new()
	m.bottom_radius = maxf(0.0, bottom_r)
	m.top_radius = maxf(0.0, top_r)
	m.height = height
	m.radial_segments = maxi(3, sides)
	m.rings = 1
	return _mi(m, height * 0.5)


## An n-sided straight prism (column/pier). sides=6 hex, 8 octagon, etc.
static func prism_ngon(sides: int, radius: float, height: float) -> MeshInstance3D:
	return cylinder(radius, radius, height, sides)


## A symmetric wedge / gable cross-section (triangular prism). For a GABLE ROOF: size=(span, ridge_height, depth)
## with the ridge running along Z; the two upper faces are the slopes, the ±Z faces are the gable ends. Base at y=0.
static func wedge(size: Vector3) -> MeshInstance3D:
	var m := PrismMesh.new()
	m.size = size
	return _mi(m, size.y * 0.5)


## A gable roof spanning footprint (x=span, y=depth) rising to ridge_height. (Alias of a wedge sized for a roof.)
static func roof_gable(footprint: Vector2, ridge_height: float) -> MeshInstance3D:
	return wedge(Vector3(footprint.x, ridge_height, footprint.y))


## A single-slope ramp (right-triangle prism) — for stairs substitutes, shed roofs, embankments. Rises along +X
## across `run`, by `rise`, `width` deep along Z. (PrismMesh with the peak pushed fully to one side.)
static func ramp(run: float, rise: float, width: float) -> MeshInstance3D:
	var m := PrismMesh.new()
	m.size = Vector3(run, rise, width)
	m.left_to_right = 0.0   # peak at one edge -> a right triangle, i.e. a single slope
	return _mi(m, rise * 0.5)


## A hemispherical / squashed dome. radius = base radius, height = how tall (a clipped/flattened dome if
## height<radius, a stretched one if >). Base at y=0.
static func dome(radius: float, height: float, segments: int = 16) -> MeshInstance3D:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = height          # for a hemisphere, `height` IS the vertical extent (base at y=0)
	m.is_hemisphere = true
	m.radial_segments = maxi(6, segments * 2)
	m.rings = maxi(3, segments)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	return mi


# ─────────────────────────────── ArrayMesh: rectangular frustum / pyramid ───────────────────────────────

## A rectangular solid that tapers with height: base (x=width, y=depth) at y=0 -> top (x,y) at y=height.
##   top == base  -> a box;  top < base -> battered/tapered (pylon, obelisk shaft, tower setback);
##   top == (0,0) -> a true pyramid (4 triangular faces to an apex). Supports non-uniform taper.
## The ONE hand-built shape — faces emitted with convex-outward normals + Godot-correct winding, so it is solid
## and never inside-out. Base at y=0, centred at x=z=0.
static func frustum(base: Vector2, top: Vector2, height: float) -> MeshInstance3D:
	var bx := base.x * 0.5
	var bz := base.y * 0.5
	var b := [
		Vector3(-bx, 0.0, -bz), Vector3(bx, 0.0, -bz),
		Vector3(bx, 0.0, bz), Vector3(-bx, 0.0, bz),
	]
	var centroid := Vector3(0.0, height * 0.5, 0.0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	if top.x <= 0.001 and top.y <= 0.001:
		# pyramid: 4 triangular sides to an apex + a base quad
		var apex := Vector3(0.0, height, 0.0)
		for i in 4:
			_emit_face(st, [b[i], b[(i + 1) % 4], apex], centroid)
		_emit_face(st, [b[0], b[1], b[2], b[3]], centroid)
	else:
		var tx := top.x * 0.5
		var tz := top.y * 0.5
		var t := [
			Vector3(-tx, height, -tz), Vector3(tx, height, -tz),
			Vector3(tx, height, tz), Vector3(-tx, height, tz),
		]
		for i in 4:
			_emit_face(st, [b[i], b[(i + 1) % 4], t[(i + 1) % 4], t[i]], centroid)
		_emit_face(st, [b[0], b[1], b[2], b[3]], centroid)   # bottom
		_emit_face(st, [t[0], t[1], t[2], t[3]], centroid)   # top
	st.generate_tangents()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	return mi


## A true pyramid (base -> apex). Convenience over frustum().
static func pyramid(base: Vector2, height: float) -> MeshInstance3D:
	return frustum(base, Vector2.ZERO, height)


# ─────────────────────────────── composed: a column ───────────────────────────────

## A column = round shaft + an optional base plinth + an optional capital flare. capital/base are simple
## frustum flares (a Meshy lotus/Doric/etc. capital can be swapped onto the slot by the caller). Returns a Node3D.
static func column(radius: float, height: float, sides: int = 24, capital: bool = true, plinth: bool = true) -> Node3D:
	var root := Node3D.new()
	var cap_h := height * 0.10 if capital else 0.0
	var base_h := height * 0.06 if plinth else 0.0
	var shaft_h := height - cap_h - base_h
	if plinth:
		var p := cylinder(radius * 1.25, radius * 1.1, base_h, sides)
		root.add_child(p)
	var shaft := cylinder(radius * 1.05, radius * 0.92, shaft_h, sides)   # slight entasis taper
	shaft.position.y = base_h
	root.add_child(shaft)
	if capital:
		var c := cylinder(radius * 0.95, radius * 1.3, cap_h, sides)       # flare out at the top
		c.position.y = base_h + shaft_h
		root.add_child(c)
	return root


# ─────────────────────────────── composed: stairs + wall-with-opening ───────────────────────────────

## A straight flight of STAIRS: stacked step-box visuals + ONE hidden RAMP collider (a rotated box
## StaticBody3D spanning the flight — the standard smooth-climb trick: the player walks up via
## move_and_slide with no per-step jitter; the step boxes are VISUAL-ONLY). Base at y=0, ascending
## +Y along -Z: the flight's foot is at z=0 and the top tread surface reaches y=`rise` at z=-`run`,
## width centred on x=0 (the caller rotates/positions the returned Node3D). The ramp plane runs half
## a step ABOVE the y=0->rise diagonal so feet track the tread tops (±half a step at either end).
static func stairs(width: float, rise: float, run: float, steps: int, material: Material = null) -> Node3D:
	var root := Node3D.new()
	var n := maxi(2, steps)
	var step_h := rise / float(n)
	var step_d := run / float(n)
	for i in n:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(width, step_h * float(i + 1), step_d)   # stacked-solid steps: no see-through gaps
		mi.mesh = bm
		mi.position = Vector3(0.0, step_h * float(i + 1) * 0.5, -(float(i) + 0.5) * step_d)
		if material != null:
			mi.material_override = material
		root.add_child(mi)
	# the ONE ramp collider: a thin box tilted to the flight's slope. The top surface runs from
	# GROUND LEVEL at the entry (z=+step_d/2, y=0) to the landing (z=-run, y=rise) — starting AT
	# ground is load-bearing: a surface that begins half a step up presents a small vertical face
	# that move_and_slide treats as a WALL (no step-up in Godot), so the player just stops at the
	# flight's foot instead of climbing (caught by the Wave-2 walk-up probe).
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	var z0 := step_d * 0.5                            # entry point (touches ground just before step 1)
	var dz := z0 - (-run)                             # horizontal extent of the ramp surface
	bs.size = Vector3(width, 0.3, sqrt(dz * dz + rise * rise))
	cs.shape = bs
	var ang := atan2(rise, dz)                        # rotation about +X lifts the -Z end
	cs.rotation.x = ang
	var mid := Vector3(0.0, rise * 0.5, (z0 - run) * 0.5)   # ramp-surface midpoint
	var nrm := Vector3(0.0, cos(ang), sin(ang))       # surface normal after the tilt
	cs.position = mid - nrm * 0.15                    # sink the box half its thickness under the surface
	body.add_child(cs)
	root.add_child(body)
	return root


## A WALL SLAB with an optional rectangular OPENING (doorway / arch / stairwell edge): composed from
## 2-3 boxes (left jamb, right jamb, lintel) so the gap is genuinely walkable-through — the primitive
## both doorways and stairwell edges build on. The wall runs along X (`w` wide, `h` tall, `t` thick
## along Z), base at y=0, centred at x=z=0; the opening rises from y=0 and `opening_center_x` slides
## it along the wall. opening_w<=0 (or opening_h<=0) -> ONE solid box (a plain slab). Every box gets
## a matching BoxShape3D on ONE shared StaticBody3D; `solid=false` skips collision entirely (e.g. a
## visual-only interior lining layer). Materials via `material` (or the caller's set_material).
static func wall_with_opening(w: float, h: float, t: float, opening_w: float, opening_h: float, opening_center_x: float, material: Material = null, solid: bool = true) -> Node3D:
	var root := Node3D.new()
	var ow := clampf(opening_w, 0.0, maxf(0.0, w - 0.2))
	var oh := clampf(opening_h, 0.0, h)
	var pieces: Array = []   # [size: Vector3, centre: Vector3] per box
	if ow <= 0.01 or oh <= 0.01:
		pieces.append([Vector3(w, h, t), Vector3(0.0, h * 0.5, 0.0)])
	else:
		var ocx := clampf(opening_center_x, -w * 0.5 + ow * 0.5, w * 0.5 - ow * 0.5)
		var lx1 := ocx - ow * 0.5   # opening's left edge
		var rx0 := ocx + ow * 0.5   # opening's right edge
		if lx1 + w * 0.5 > 0.01:
			pieces.append([Vector3(lx1 + w * 0.5, h, t), Vector3((lx1 - w * 0.5) * 0.5, h * 0.5, 0.0)])
		if w * 0.5 - rx0 > 0.01:
			pieces.append([Vector3(w * 0.5 - rx0, h, t), Vector3((rx0 + w * 0.5) * 0.5, h * 0.5, 0.0)])
		if h - oh > 0.01:
			pieces.append([Vector3(ow, h - oh, t), Vector3(ocx, (oh + h) * 0.5, 0.0)])
	var body: StaticBody3D = null
	if solid:
		body = StaticBody3D.new()
		body.collision_layer = 1
	for pc in pieces:
		var sz: Vector3 = pc[0]
		var ct: Vector3 = pc[1]
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = sz
		mi.mesh = bm
		mi.position = ct
		if material != null:
			mi.material_override = material
		root.add_child(mi)
		if body != null:
			var cs := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			bs.size = sz
			cs.shape = bs
			cs.position = ct
			body.add_child(cs)
	if body != null:
		root.add_child(body)
	return root


# ─────────────────────────────── colliders + materials ───────────────────────────────

## A LADDER — two vertical side-rail boxes (along X at ±width/2) + horizontal rungs every ~0.3m. Base at y=0,
## centred at x=z=0, rising +Y to `height`; the climb face is the ±Z plane. Returns a Node3D. NO collider ON
## PURPOSE — it is WALK-THROUGH: the player-controller drives the vertical climb along Y (interaction.gd
## registers it as a "Climb" target), and a solid ladder would read as a WALL and block the very ascent it
## exists for. A wood/metal-ish material is baked in (set_material) so a placed ladder is visible without a
## surface pass (a caller may still override via set_material); meta "ladder_h" carries the climb extent so a
## placement/interaction path can read it back off the node.
static func ladder(height: float, width := 0.5) -> Node3D:
	var root := Node3D.new()
	var h := maxf(0.6, height)
	var rail := 0.06                          # side-rail / rung cross-section
	var hw := maxf(0.15, width) * 0.5
	for sx in [-hw, hw]:                       # the two vertical rails, base at y=0 -> top at y=h
		var r := box(Vector3(rail, h, rail))
		r.position.x = sx
		root.add_child(r)
	var gap := 0.3                             # rung spacing (~0.3 m)
	var n := maxi(1, int(h / gap))
	for i in range(1, n):                      # rungs between the rails (skip i=0 -> at the floor)
		var rung := box(Vector3(hw * 2.0 + rail, rail, rail))
		rung.position.y = gap * float(i) - rail * 0.5   # box centres its own y at rail*0.5, so offset back
		root.add_child(rung)
	set_material(root, _ladder_mat())
	root.set_meta("ladder_h", h)
	return root


## Apply a material to every MeshInstance3D under `node` (or to a single MeshInstance3D).
static func set_material(node: Node, mat: Material) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_override = mat
	for c in node.get_children():
		set_material(c, mat)


## Wrap a built shape with a solid STATIC collider so the player can't walk through it. mode "box" (cheap, from
## AABB) or "mesh" (trimesh, exact — for walk-into shells/arches). Returns the same node, collider added as a child.
##
## THE COLLIDER IS A CHILD, SO IT IS MEASURED IN THE NODE'S OWN FRAME. It was measured in the node's PARENT frame — the
## node's own position, scale and yaw included — and then hung under the node, where that same transform is applied a
## second time. Every caller whose node was not still at the identity got a box somewhere else: a populate prop
## normalised by `target_size` was scaled twice (a Kenney stander drawn 1.65 m tall stood in a box 0-1.07 m, and a rifle
## shot 1.2 m up flew through him — the K merge's re-check; a crate grown 1.6x drew 1.66 m and blocked 2.65 m), a placed
## tree's trunk pole rose by its whole base height again (drawn 4.99-9.21 m on ground 5 m up, its pole 9.99-14.21: on
## ground higher than the player is tall, walk-through), and a shape part's box floated half its height over the shape
## it wraps.
static func add_collider(node: Node3D, mode: String = "box") -> Node3D:
	if mode == "mesh":
		for mi in _all_meshes(node):
			mi.create_trimesh_collision()
	elif mode == "trunk":
		# TREES: a slim vertical TRUNK column at the canopy centre instead of a canopy-wide box, so the
		# player walks freely through the foliage and only the narrow trunk blocks them. Radius ~ a small
		# fraction of the footprint (bounded), height = the full model so it can't be walked/jumped over.
		var tab := _aabb(node)
		if tab.size.y > 0.01:
			var tbody := StaticBody3D.new()
			tbody.collision_layer = 1
			var tcs := CollisionShape3D.new()
			var cyl := CylinderShape3D.new()
			# the radius is a size in METRES (3% of the footprint, 3-8 cm): read at the size the node is drawn and
			# handed back in its own units, which the node's scale then draws again
			var fs := maxf((absf(node.scale.x) + absf(node.scale.z)) * 0.5, 1e-4)
			cyl.radius = clampf(minf(tab.size.x, tab.size.z) * fs * 0.03, 0.03, 0.08) / fs
			cyl.height = tab.size.y
			tcs.shape = cyl
			tcs.position = Vector3(0.0, tab.position.y + tab.size.y * 0.5, 0.0)   # pole at the trunk PIVOT (x=z=0), not the offset canopy AABB centre
			tbody.add_child(tcs)
			node.add_child(tbody)
	else:
		var ab := _aabb(node)
		if ab.size.length() > 0.01:
			var body := StaticBody3D.new()
			body.collision_layer = 1
			var cs := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = ab.size
			cs.shape = box
			cs.position = ab.position + ab.size * 0.5
			body.add_child(cs)
			node.add_child(body)
	return node


# ─────────────────────────────── a seat's collider ───────────────────────────────

const SEAT_CELL := 0.04      # the fit's grid: 4 cm of the model's own units — a slat, an arm, the edge of a plank
const SEAT_GRID := 96        # ...and never more cells than this along the model's longest side (a 3.8 m pew is still 4 cm)
const SEAT_LIP := 0.02       # what is drawn this little over the seat surface is the seat's block, not a part over it
## AT MOST THIS MANY BOXES IN A SEAT'S BODY. Every box is a shape each body moving near the seat tests every tick, and an
## exact cover of what a seat draws was 15-1466 of them (a decorated bench 1466, a KayKit couch with pillows 735): eight
## soft KayKit seats in a room took the player's tick from 132 to 1383 us at p95 (step 1b's re-check). What a body
## bumps into needs no slat-by-slat truth — a shot does, and it has the sight (SIGHT_LAYER). Ten, measured (2026-10-04):
## a seat's block and parts come to 5-13 boxes on the people rig's eleven seats and 15 at most on the catalog's (a holiday
## chair_large), and the fewest the office chair's merge to with none in its sitter's keep-out is 9; at ten, eight of the
## soft seats cost a frame of the player walking among them 1.1x what their bounds' boxes did (people rig (p7)).
const SEAT_BOXES := 10
const SEAT_KEEP_R := 0.8     # the sitter's open air: this far either way of the seat point along x and z (a sitter's knees,
const SEAT_KEEP_H := 1.0     # ...their hands at their sides, their back leant on the backrest), and this high over the seat
const SEAT_FITS_MAX := 64    # fits remembered, the least recently used dropped first (a model fetched again is new meshes)
## THE LAYER A LINE OF FIRE MEETS A SEAT ON — bit 6 (32), main.gd L_SIGHT. A seat's drawn triangles, exactly, as
## ConcavePolygonShape3D, on a layer that no body's mask includes and no query but a shot's names (GProjectile.HIT_MASK,
## GProjectile.sight): a ray against a trimesh is about what one against a box is (0.7-3.3 us a ray near a seat), a
## capsule swept against one is not (4.6-17.4 ms a tick for eight seats, step 1b's fix round), so the shot gets the
## drawing and the bodies get the boxes. Layers 1-5 are L_WORLD, L_PLAYER, L_ENEMY, L_PEER and L_CROWD (main.gd).
const SIGHT_LAYER := 32
const SIGHT_TRIS := 1500     # triangles per sight shape: one piece of a slice (0.7 ms to build on a desktop)
const SEAT_BODY := &"gogi_seat_body"   # meta on a seat's body: boxes a line of fire passes through (GProjectile.sight)
static var _seat_fits := {}  # mesh ids + seat height (cm) -> {boxes: [[BoxShape3D, Transform3D], ...], sight: [ConcavePolygonShape3D],
                             # keep: the sitter's keep-out (AABB), parts: the boxes it had before SEAT_BOXES}
static var _seat_lru: Array[String] = []
## Fits built where a seat was PLACED — nobody built that model's ahead, when its GLB was parsed (area_builder.mark_seat).
## The people rig reads it: a game's seats are fitted at parse, never in the frame that places them.
static var seat_fits_placed := 0
## Pieces TriRead has read, ever — a surface opened, READ_PIECE vertices snapped or corners gathered (the people rig counts
## a heavy pew's: a seat's triangles are read in pieces at parse, never whole, (p16)).
static var read_pieces := 0


## A SEAT'S COLLIDER: TWO BODIES HUNG UNDER `node`, so they turn, move and scale with it — what a body bumps into, and
## what a shot meets. `seat_y` is the seat surface's height in `node`'s own frame — the one InteractionSystem.add_seat
## measured, where the sitter is put. Returns the body (null: nothing drawn).
##
## Every prop collider was a box over the prop's whole bounds, and a seat's bounds hold its backrest, its arms and its end
## panels — so the box filled the space its sitter sits in: Hal on a harbour_bench (1.80 x 1.00 x 0.71 m, slab at 0.45)
## was shielded from both ends by a box where only air is drawn over the seat, a seated hero's hand started inside the
## bench, and on a placed prop (AreaBuilder._add_prop_collision) the box hung on the cell root, square to the world: turned
## 45 deg, a bench's box was 1.77 m on a side. Step 1b fitted the collider to what the seat draws, every box within 2 cm
## of it, and a shot met the seat exactly where it is drawn — at 15-1466 boxes a seat, which every body moving near one
## paid for each tick (the re-check: 8 KayKit seats, the player's tick 132 -> 1383 us at p95). So the collider is two:
##   THE BODY (L_WORLD, what the player, the crowd, an enemy and a car bump into): a few boxes — the seat block, solid
##     from the seat's base up to its surface, and one box over each part drawn above it (a backrest, an arm, an end
##     panel), none of them where the sitter sits (SeatFit.keep), at most SEAT_BOXES;
##   THE SIGHT (SIGHT_LAYER, what a line of fire meets — GProjectile.sight passes the body's boxes): the triangles it
##     draws, every one of them, as ConcavePolygonShape3D — shot through the gap between two slats, stopped by the wood.
##
## Built ONCE PER MODEL AND SEAT HEIGHT, every copy sharing the shapes — and built where the GLB is parsed (area_builder:
## a slice per frame inside the parse budget, on the main thread), not where it is placed. A seat whose fit nobody built
## ahead (a scale whose seat height measures a centimetre off the one fitted at parse) builds it here, whole, and counts it
## (seat_fits_placed).
static func add_seat_collider(node: Node3D, seat_y: float) -> StaticBody3D:
	var ids := seat_ids(node)
	var cm := roundi(seat_y * 100.0)
	var key := _seat_find(ids, cm)
	if key == "":
		var fit := SeatFit.new(_tris(node), cm, ids, _seat_sight(ids), seat_y)
		fit.step(1 << 62)
		seat_fits_placed += 1
		key = seat_fit_put(fit)
	var got: Dictionary = _seat_fits[key]
	if not (got["sight"] as Array).is_empty():
		var sight := StaticBody3D.new()
		sight.name = "SeatSight"
		sight.collision_layer = SIGHT_LAYER
		sight.collision_mask = 0
		for shp in got["sight"]:
			var scs := CollisionShape3D.new()
			scs.shape = shp
			sight.add_child(scs)
		node.add_child(sight)
	var parts: Array = got["boxes"]
	if parts.is_empty():
		return null
	var body := StaticBody3D.new()
	body.name = "SeatBody"
	body.collision_layer = 1
	body.set_meta(SEAT_BODY, true)
	for p in parts:
		var cs := CollisionShape3D.new()
		cs.shape = p[0]
		cs.transform = p[1]
		body.add_child(cs)
	node.add_child(body)
	return body


## Whether `o` (what a ray met) is a seat's body: boxes a line of fire passes through to the seat's sight.
static func is_seat_body(o: Object) -> bool:
	return o != null and is_instance_valid(o) and o.has_meta(SEAT_BODY)


## Which model `node` draws, for the fit memo: its meshes, by identity (every copy of a cached GLB shares them).
static func seat_ids(node: Node3D) -> String:
	var ids := PackedStringArray()
	for mi in _all_meshes(node):
		ids.append(str((mi as MeshInstance3D).mesh.get_instance_id()))
	return ",".join(ids)


## The remembered fit of the model `ids` at the seat height `cm` — or one a centimetre either side, which is the same
## fit: a populated bench at GCast.vary's scale measures its slatted slab a few millimetres off its neighbour's (people
## rig), so two copies straddle a centimetre, and the fit's grid is 4 cm. "" when there is none.
static func _seat_find(ids: String, cm: int) -> String:
	for d in [0, -1, 1]:
		var key := "%s|%d" % [ids, cm + d]
		if _seat_fits.has(key):
			_seat_lru.erase(key)
			_seat_lru.append(key)
			return key
	return ""


## The sight of the model `ids` a remembered fit already holds — one per model, whatever its seat heights ([]: none yet).
static func _seat_sight(ids: String) -> Array:
	for key in _seat_fits:
		if String(key).begins_with(ids + "|"):
			return _seat_fits[key]["sight"]
	return []


## Remember a finished fit (main thread: the shapes are physics resources) and return its key. The least recently used
## goes first past SEAT_FITS_MAX — only that one: the others are still placed.
static func seat_fit_put(fit: SeatFit) -> String:
	var key := "%s|%d" % [fit.ids, fit.cm]
	var parts: Array = []
	for b in fit.boxes:
		var bs := BoxShape3D.new()
		bs.size = (b[1] as Vector3).max(Vector3.ONE * 0.002)
		parts.append([bs, b[0]])
	if not _seat_fits.has(key):
		while _seat_lru.size() >= SEAT_FITS_MAX:
			_seat_fits.erase(_seat_lru.pop_front())
		_seat_lru.append(key)
	_seat_fits[key] = {"boxes": parts, "sight": fit.sight, "keep": fit.keep, "parts": fit.parts}
	return key


## Forget every fit of the model `ids` (seat_ids) — its meshes are going: AreaBuilder frees the template every copy of it
## was made from (_free_template), and a re-fetched model is new meshes, so nothing could find that fit again; its boxes
## and its sight were held to the next world (43 seat models' after a world switch, static memory 30.1 -> 37.1 MB: step
## 1b's verifier). The copies placed keep their shapes: their bodies hold them.
static func seat_fits_drop(ids: String) -> void:
	if ids == "":
		return
	for key in _seat_fits.keys():
		if String(key).begins_with(ids + "|"):
			_seat_fits.erase(key)
			_seat_lru.erase(key)


## Every triangle `node` draws, three corners each, in its own frame (detachment-safe, as _aabb): each mesh's faces in one
## native transform — 0.05-0.09 ms for a Kestrel seat whose faces were read before, where the GDScript loop it replaced, a
## vertex at a time, took 0.23-0.42. The first read of a mesh's faces builds Godot's triangle mesh for it: 1.0-1.9 ms.
static func _tris(node: Node3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var stack: Array = [[node, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var pair: Array = stack.pop_back()
		var n: Node = pair[0]
		var xf: Transform3D = pair[1]
		for c in n.get_children():
			stack.append([c, xf * (c as Node3D).transform if c is Node3D else xf])
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			out.append_array(xf * GPose.faces((n as MeshInstance3D).mesh))
	return out


const READ_PIECE := 4096     # TriRead: vertices snapped, or corners gathered, between looks at the clock (~0.3 ms here)
const READ_SNAP := Vector3(0.0001, 0.0001, 0.0001)   # how Godot's triangle mesh stores a corner (TriangleMesh::create)

## EVERY TRIANGLE `node` DRAWS, A PIECE AT A TIME: what _tris returns — the same triangles, in the same order, to the same
## bit — as steps (area_builder's SeatJob). step(deadline) works until Time.get_ticks_usec() passes `deadline` and says
## whether it is done; `out` then holds the triangles. _tris asks each mesh for its faces in one native call, and the
## first such call builds Godot's triangle mesh for it, a BVH nothing here reads: 4.1 ms for a pew of 12456 triangles and
## 17.4 ms for one of 49824, in one frame — the longest piece of a seat's parse-time work (step 1b's verifier read it as
## 18.9 ms of the measure's; the measure's own surface read is 0.09 ms for that pew's 31039 vertices, 2026-10-04). Here
## a surface's arrays are one call, and its corners are snapped to 0.1 mm — as that triangle mesh stores them, so what
## _tris reads off it is what this reads — and gathered through its indices, READ_PIECE at a time. A triangle strip is
## read whole, as _tris reads it (no catalog seat has one).
class TriRead extends RefCounted:
	var out := PackedVector3Array()
	var _meshes: Array = []            # [Mesh, its transform to `node`], in _tris' order
	var _m := 0
	var _si := 0                       # the mesh in hand's next surface
	var _held := false                 # a surface's arrays are in hand
	var _v := PackedVector3Array()     # ...its vertices, snapped up to _vi
	var _idx := PackedInt32Array()     # ...its indices (empty: not indexed)
	var _vi := 0
	var _ti := 0                       # ...its corners gathered so far
	var _part := PackedVector3Array()  # the mesh in hand's triangles so far, in its own frame

	func _init(node: Node3D) -> void:
		var stack: Array = [[node, Transform3D.IDENTITY]]
		while not stack.is_empty():
			var pair: Array = stack.pop_back()
			var n: Node = pair[0]
			var xf: Transform3D = pair[1]
			for c in n.get_children():
				stack.append([c, xf * (c as Node3D).transform if c is Node3D else xf])
			if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
				_meshes.append([(n as MeshInstance3D).mesh, xf])

	func step(deadline: int) -> bool:
		var first := true
		while _m < _meshes.size():
			if not first and Time.get_ticks_usec() > deadline:
				return false
			first = false
			GShapes.read_pieces += 1
			var mesh: Mesh = _meshes[_m][0]
			if not _held:
				if _si >= mesh.get_surface_count():
					out.append_array((_meshes[_m][1] as Transform3D) * _part)
					_part = PackedVector3Array()
					_m += 1
					_si = 0
					continue
				var si := _si
				_si += 1
				var prim: int = (mesh as ArrayMesh).surface_get_primitive_type(si) if mesh is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
				if prim == Mesh.PRIMITIVE_TRIANGLE_STRIP:
					_part = GPose.faces(mesh)   # every surface of it, as _tris reads it: the mesh is read whole
					_si = mesh.get_surface_count()
					continue
				if prim != Mesh.PRIMITIVE_TRIANGLES:
					continue
				var arr := GPose.surface_arrays(mesh, si)
				if arr.size() <= Mesh.ARRAY_INDEX or not (arr[Mesh.ARRAY_VERTEX] is PackedVector3Array):
					continue
				_v = arr[Mesh.ARRAY_VERTEX]
				_idx = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
				_vi = 0
				_ti = 0
				_held = true
				continue
			var v := _v
			var e := mini(_vi + READ_PIECE, v.size())
			if _vi < v.size():
				for i in range(_vi, e):
					v[i] = v[i].snapped(GShapes.READ_SNAP)
				_vi = e
				_v = v
				continue
			var idx := _idx
			var n := idx.size() if not idx.is_empty() else v.size()
			n -= n % 3
			var at := _part.size()
			var k := mini(_ti + READ_PIECE, n)
			_part.resize(at + k - _ti)
			var part := _part
			if idx.is_empty():
				for i in range(_ti, k):
					part[at + i - _ti] = v[i]
			else:
				for i in range(_ti, k):
					part[at + i - _ti] = v[idx[i]]
			_part = part
			_ti = k
			if _ti >= n:
				_held = false
				_v = PackedVector3Array()
				_idx = PackedInt32Array()
		return true


## A SEAT'S FIT, BUILT IN STEPS: add_seat_collider's sight and boxes for the triangles `T` (the seat's own frame) of a seat
## whose surface is `seat_y` up (`seat_cm` rounded: the memo's), `sight_of` the sight a fit of the same model already built
## (it is not built twice). The surface as measured, never rounded: a box whose top face lies exactly where the player's
## capsule turns from cylinder to hemisphere — 0.45 m over their feet — is no wall to it (GodotPhysics; measured: a
## capsule walked through such a box entirely, 1e-4 m off either way it stopped), and a chapel_pew rounded to 43 cm under
## SEAT_LIP's 2 cm stood its block top exactly there: the player walked 0.37 m into the pew. On
## the main thread — the shapes are physics resources — and a slice at a time: step(deadline) works until
## Time.get_ticks_usec() passes `deadline` and says whether it is done; no piece of it is longer than a sight shape's
## SIGHT_TRIS triangles or a few thousand of anything else (1.9 ms at most on a desktop, the whole fit 12-155 ms: area_builder
## runs it inside the parse budget, people rig (p10)). Then `sight` holds the sight's shapes, `boxes` the body's boxes
## ([Transform3D, size], the seat's own frame), `keep` where its sitter goes and `parts` the boxes before the cap.
##
## THE GRID: x and z in cells from the seat's lowest corner, y in cells from the seat surface. At or under the surface
## (+ SEAT_LIP), per column (x, z): the top of what is drawn there and its XZ extent — the seat block, solid from the
## seat's base; over it, per cell, whether anything is drawn in it and the extent of what is. A triangle is cut into the
## cells it crosses conservatively — by scanning its plane along its two shallow axes, so a cell it touches is never missed
## and a gap in the grid is a gap in the mesh — or, two cells or fewer each way, taken as its box. One drawn wholly under
## the lip only needs its columns: its shadow on the ground is scanned instead, at its own top (its plane's over the cell,
## when it lies flat).
class SeatFit extends RefCounted:
	const DONE := 9
	var ids := ""
	var cm := 0
	var boxes: Array = []
	var sight: Array = []
	var keep := AABB()                 # where the sitter goes (stage 5), the seat's own frame: no box enters it
	var parts := 0                     # the boxes before SEAT_BOXES merged any (stage 8)
	var _T := PackedVector3Array()
	var _G := PackedVector3Array()     # the triangles in cells, from (lo.x, the seat, lo.z)
	var _stage := 0
	var _i := 0
	var _lo := Vector3.INF
	var _hi := -Vector3.INF
	var _s := 0.0
	var _c := 1.0
	var _nx := 1
	var _nz := 1
	var _nyu := 1
	var _gmin := Vector3i.ZERO
	var _gmax := Vector3i.ZERO
	var _lip := 0.0
	var _top := PackedFloat32Array()   # per column: the top of what is drawn at or under the lip (-INF: nothing)
	var _cb := PackedFloat32Array()    # ...and its XZ extent: x0 x1 z0 z1
	var _over := PackedByteArray()     # ...and whether anything is drawn over the lip in it too
	var _up := PackedByteArray()       # per cell over the seat: something drawn in it
	var _ub6 := PackedFloat32Array()   # ...and its extent: x0 x1 y0 y1 z0 z1
	var _pc := PackedFloat32Array()    # the pieces of triangles over the lip: x0 y0 z0 x1 y1 z1, each inside one cell
	var _np := 0
	var _sub := 0                      # stage 5's pass
	var _tc := PackedByteArray()       # per cell over the seat: a drawn surface touches a face of it (_touched)
	var _pk := PackedInt32Array()      # ...the cells that are not open (drawn or touched), as prefix sums
	var _ki := 0                       # ...the seed the keep-out is grown from next, and the biggest open box yet
	var _kvol := 0
	var _ka := Vector3i.ZERO           # the keep-out in cells, a..b (empty: _kb.x < _ka.x)
	var _kb := Vector3i(-1, -1, -1)
	var _dl := PackedInt32Array()      # the drawn cells over the seat (stage 3 lists them)
	var _uf := PackedInt32Array()      # stage 6: per cell over the seat, its union-find parent (-1: nothing drawn)
	var _lab := PackedInt32Array()     # ...the root of the part it is drawn in
	var _clo := PackedInt32Array()     # per part (at its root): its cells' bounds, x y z
	var _chi := PackedInt32Array()
	var _side := PackedInt32Array()    # per cell of a part round the keep-out: the side of it it lies past
	var _mass := PackedInt32Array([0, 0, 0, 0, 0])   # what is drawn past each side of the keep-out: x-, x+, z-, z+, y+
	var _sp := PackedInt32Array([0, 0, 0, 0, 0])     # one cell's distances past each of them (_sep)
	var _part_of := {}                 # ...a piece's root -> its cells
	var _work: Array = []              # stage 7: the pieces, each its cells
	var _wi := 0                       # ...the piece in hand, the cell in hand, and the pass (0 its spread, 1 its extent)
	var _wj := 0
	var _wpass := 0
	var _ws := Vector3.ZERO            # ...its cells' centres summed, and their second moments (3 x 3)
	var _wm := PackedFloat64Array([0, 0, 0, 0, 0, 0, 0, 0, 0])
	var _we0 := Vector3.INF            # ...what it draws, square to the grid
	var _we1 := -Vector3.INF
	var _wax: Array = []               # ...its own axes, and its extent along them
	var _wlo := PackedFloat64Array()
	var _whi := PackedFloat64Array()
	var _cost := PackedFloat32Array()  # stage 8: what merging each pair of boxes adds (INF: never)
	var _pend := PackedInt32Array()    # ...the pairs still to work out, i * boxes + j
	var _live := 0                     # ...and the boxes left (0: not started)

	func _init(T: PackedVector3Array, seat_cm: int, mesh_ids := "", sight_of: Array = [], seat_y := NAN) -> void:
		ids = mesh_ids
		cm = seat_cm
		_s = seat_y if is_finite(seat_y) else seat_cm / 100.0   # the grid's floor: the seat surface
		_T = T
		sight = sight_of
		if T.size() < 3:
			_stage = DONE
		elif not sight.is_empty():
			_stage = 1

	func step(deadline: int) -> bool:
		while _stage < DONE:
			var finished: bool
			match _stage:
				0:
					finished = _sight(deadline)
				1:
					finished = _bounds(deadline)
				2:
					finished = _scan(deadline)
				3:
					finished = _file(deadline)
				4:
					boxes.append_array(_block())
					finished = true
				5:
					finished = _keep(deadline)
				6:
					finished = _parts(deadline)
				7:
					finished = _pieces(deadline)
				_:
					finished = _cap(deadline)
			if not finished:
				return false
			_stage += 1
			_i = 0
			if Time.get_ticks_usec() > deadline and _stage < DONE:
				return false
		return true

	## Stage 0: THE SIGHT — every triangle, SIGHT_TRIS at a time, each lot a ConcavePolygonShape3D that answers from both
	## faces: a seat GLB is not a closed solid, and a slat seen from behind is a face too.
	func _sight(deadline: int) -> bool:
		var n := _T.size()
		var i := _i
		while i < n:
			if i > _i and Time.get_ticks_usec() > deadline:
				_i = i
				return false
			var j := mini(n, i + 3 * GShapes.SIGHT_TRIS)
			var shp := ConcavePolygonShape3D.new()
			shp.backface_collision = true
			shp.set_faces(_T.slice(i, j))
			sight.append(shp)
			i = j
		return true

	## Stage 1: what the triangles span, and the grid over it.
	func _bounds(deadline: int) -> bool:
		var T := _T
		var lo := _lo
		var hi := _hi
		var i := _i
		while i < T.size():
			if (i & 4095) == 0 and i > _i and Time.get_ticks_usec() > deadline:
				_i = i
				_lo = lo
				_hi = hi
				return false
			lo = lo.min(T[i])
			hi = hi.max(T[i])
			i += 1
		_lo = lo
		_hi = hi
		_c = maxf(GShapes.SEAT_CELL, (hi - lo)[(hi - lo).max_axis_index()] / float(GShapes.SEAT_GRID))
		_nx = maxi(1, ceili((hi.x - lo.x) / _c - 1e-6))
		_nz = maxi(1, ceili((hi.z - lo.z) / _c - 1e-6))
		_nyu = maxi(1, ceili((hi.y - _s) / _c - 1e-6))
		_gmin = Vector3i(0, mini(-1, floori((lo.y - _s) / _c)), 0)
		_gmax = Vector3i(_nx - 1, _nyu - 1, _nz - 1)
		var inv := 1.0 / _c
		_lip = GShapes.SEAT_LIP * inv
		_top.resize(_nx * _nz)
		_top.fill(-INF)
		_cb.resize(_nx * _nz * 4)
		_over.resize(_nx * _nz)
		_up.resize(_nx * _nyu * _nz)
		_ub6.resize(_nx * _nyu * _nz * 6)
		_pc.resize(6 * 4096)
		_G = Transform3D(Basis.from_scale(Vector3.ONE * inv), -Vector3(lo.x, _s, lo.z) * inv) * T
		return true

	## Stage 2: every triangle cut into what it draws — over the lip, pieces of it, one per cell; at or under, its columns.
	func _scan(deadline: int) -> bool:
		var G := _G
		var top := _top
		var cb := _cb
		var pc := _pc
		var nx := _nx
		var nz := _nz
		var lip := _lip
		var gmin := _gmin
		var gmax := _gmax
		var np := _np
		var t := _i
		var work := 0   # cells the triangles since the last look at the clock span: a KayKit couch's faces are 1.5 m across
		while t < G.size() - 2:
			if ((t & 255) == 0 or work >= 1024) and t > _i:
				work = 0
				if Time.get_ticks_usec() > deadline:
					_i = t
					_np = np
					_pc = pc
					return false
			var A := G[t]
			var B := G[t + 1]
			var C := G[t + 2]
			t += 3
			var mn := A.min(B).min(C)
			var mx := A.max(B).max(C)
			work += int((mx.x - mn.x + 1.0) * (mx.y - mn.y + 1.0) * (mx.z - mn.z + 1.0))
			var n := (B - A).cross(C - A)
			var d := n.abs().max_axis_index()
			if absf(n[d]) < 1e-12:
				continue   # no area: it draws nothing
			var flat := d == 1
			var u := (d + 1) % 3
			var v := (d + 2) % 3
			if mx.y <= lip:
				if (floori(mx.x) - floori(mn.x)) <= 1 and (floori(mx.z) - floori(mn.z)) <= 1:
					for cx in range(clampi(floori(mn.x), 0, nx - 1), clampi(floori(mx.x), 0, nx - 1) + 1):
						for cz in range(clampi(floori(mn.z), 0, nz - 1), clampi(floori(mx.z), 0, nz - 1) + 1):
							_column(cx * nz + cz, minf(mx.y, lip), maxf(mn.x, cx), minf(mx.x, cx + 1), maxf(mn.z, cz), minf(mx.z, cz + 1))
					continue
				u = 2
				v = 0
			elif (floori(mx.x) - floori(mn.x)) <= 1 and (floori(mx.y) - floori(mn.y)) <= 1 and (floori(mx.z) - floori(mn.z)) <= 1:
				for cx in range(floori(mn.x), floori(mx.x) + 1):
					for cy in range(floori(mn.y), floori(mx.y) + 1):
						for cz in range(floori(mn.z), floori(mx.z) + 1):
							if 6 * np + 6 > pc.size():
								pc.resize(pc.size() * 2)
							pc[6 * np] = maxf(mn.x, cx)
							pc[6 * np + 1] = maxf(mn.y, cy)
							pc[6 * np + 2] = maxf(mn.z, cz)
							pc[6 * np + 3] = minf(mx.x, cx + 1)
							pc[6 * np + 4] = minf(mx.y, cy + 1)
							pc[6 * np + 5] = minf(mx.z, cz + 1)
							np += 1
				continue
			var gu := -n[u] / n[d] if d != v and d != u else 0.0
			var gv := -n[v] / n[d] if d != v and d != u else 0.0
			for iv in range(clampi(floori(mn[v]), gmin[v], gmax[v]), clampi(floori(mx[v]), gmin[v], gmax[v]) + 1):
				var v0 := maxf(float(iv), mn[v])
				var v1 := minf(float(iv + 1), mx[v])
				if v1 < v0:
					continue
				# the triangle's extent along u inside this row: its three edges, clipped to the row
				var umin := INF
				var umax := -INF
				for e in 3:
					var P: Vector3 = A if e == 0 else (B if e == 1 else C)
					var Q: Vector3 = B if e == 0 else (C if e == 1 else A)
					var pa := minf(P[v], Q[v])
					var pb := maxf(P[v], Q[v])
					if pb < v0 or pa > v1:
						continue
					if pb - pa < 1e-9:
						umin = minf(umin, minf(P[u], Q[u]))
						umax = maxf(umax, maxf(P[u], Q[u]))
						continue
					var w := (Q[u] - P[u]) / (Q[v] - P[v])
					var ua: float = P[u] + w * (maxf(pa, v0) - P[v])
					var ub: float = P[u] + w * (minf(pb, v1) - P[v])
					umin = minf(umin, minf(ua, ub))
					umax = maxf(umax, maxf(ua, ub))
				if umin > umax:
					continue
				var dv := gv * (v1 - v0)
				for iu in range(clampi(floori(umin), gmin[u], gmax[u]), clampi(floori(umax), gmin[u], gmax[u]) + 1):
					var ua := maxf(float(iu), umin)
					var ub := minf(float(iu + 1), umax)
					if ub < ua:
						continue
					if mx.y <= lip:
						# UNDER THE SEAT: the column (x = v, z = u) and its top — the plane's highest over the cell when the
						# triangle lies flat, its own top when it stands
						var tp := mx.y
						if flat:
							var py := A.y - n.x / n.y * (v0 - A.x) - n.z / n.y * (ua - A.z)
							tp = minf(py + maxf(-n.x / n.y * (v1 - v0), 0.0) + maxf(-n.z / n.y * (ub - ua), 0.0), mx.y)
						_column(clampi(iv, 0, nx - 1) * nz + clampi(iu, 0, nz - 1), minf(tp, lip), v0, v1, ua, ub)
						continue
					# the plane over this patch of the row: its lowest and highest depth along d, within the triangle's own extent
					var base := A[d] + gu * (ua - A[u]) + gv * (v0 - A[v])
					var du := gu * (ub - ua)
					var dlo := maxf(base + minf(du, 0.0) + minf(dv, 0.0), mn[d])
					var dhi := minf(base + maxf(du, 0.0) + maxf(dv, 0.0), mx[d])
					if dhi < dlo:
						dlo = (dlo + dhi) * 0.5
						dhi = dlo
					for id in range(clampi(floori(dlo), gmin[d], gmax[d]), clampi(floori(dhi), gmin[d], gmax[d]) + 1):
						if 6 * np + 6 > pc.size():
							pc.resize(pc.size() * 2)
						var o := 6 * np
						pc[o + u] = ua
						pc[o + 3 + u] = ub
						pc[o + v] = v0
						pc[o + 3 + v] = v1
						pc[o + d] = maxf(dlo, float(id))
						pc[o + 3 + d] = minf(dhi, float(id + 1))
						np += 1
		_np = np
		_pc = pc
		return true

	## Column `k` holds something at or under the lip up to `tp`, over x0..x1, z0..z1.
	func _column(k: int, tp: float, x0: float, x1: float, z0: float, z1: float) -> void:
		if _top[k] == -INF:
			_top[k] = tp
			_cb[4 * k] = x0
			_cb[4 * k + 1] = x1
			_cb[4 * k + 2] = z0
			_cb[4 * k + 3] = z1
		else:
			_top[k] = maxf(_top[k], tp)
			_cb[4 * k] = minf(_cb[4 * k], x0)
			_cb[4 * k + 1] = maxf(_cb[4 * k + 1], x1)
			_cb[4 * k + 2] = minf(_cb[4 * k + 2], z0)
			_cb[4 * k + 3] = maxf(_cb[4 * k + 3], z1)

	## Stage 3: FILE THE PIECES — what of one is at or under the seat's lip goes to its column, what rises past it to its cells.
	func _file(deadline: int) -> bool:
		var pc := _pc
		var up := _up
		var ub6 := _ub6
		var nx := _nx
		var nz := _nz
		var nyu := _nyu
		var lip := _lip
		var i := _i
		while i < 6 * _np:
			if i % 3072 == 0 and i > _i and Time.get_ticks_usec() > deadline:
				_i = i
				return false
			var x0 := pc[i]
			var y0 := pc[i + 1]
			var z0 := pc[i + 2]
			var x1 := pc[i + 3]
			var y1 := pc[i + 4]
			var z1 := pc[i + 5]
			i += 6
			var ix := clampi(floori((x0 + x1) * 0.5), 0, nx - 1)
			var iz := clampi(floori((z0 + z1) * 0.5), 0, nz - 1)
			if y0 <= lip:
				_column(ix * nz + iz, minf(y1, lip), x0, x1, z0, z1)
			if y1 > lip:
				_over[ix * nz + iz] = 1
				for iy in range(clampi(floori(maxf(y0, lip)), 0, nyu - 1), clampi(floori(y1), 0, nyu - 1) + 1):
					var k := (iy * nx + ix) * nz + iz
					var ya := maxf(maxf(y0, 0.0), float(iy))
					var yb := minf(y1, float(iy + 1))
					if up[k] == 0:
						up[k] = 1
						_dl.append(k)
						ub6[6 * k] = x0
						ub6[6 * k + 1] = x1
						ub6[6 * k + 2] = ya
						ub6[6 * k + 3] = yb
						ub6[6 * k + 4] = z0
						ub6[6 * k + 5] = z1
					else:
						ub6[6 * k] = minf(ub6[6 * k], x0)
						ub6[6 * k + 1] = maxf(ub6[6 * k + 1], x1)
						ub6[6 * k + 2] = minf(ub6[6 * k + 2], ya)
						ub6[6 * k + 3] = maxf(ub6[6 * k + 3], yb)
						ub6[6 * k + 4] = minf(ub6[6 * k + 4], z0)
						ub6[6 * k + 5] = maxf(ub6[6 * k + 5], z1)
		_pc = PackedFloat32Array()   # the pieces are filed: let them go
		return true


	## Stage 4: THE SEAT BLOCK — what is drawn at or under the seat surface (its lip included), solid from the seat's base
	## up to the top of what is drawn there: the legs, the frame, a couch's base, the slab, the feet of whatever stands on
	## it — and up to the surface where something drawn over it stands on what is drawn under it (an arm, a back, an end
	## panel: inside a KayKit couch's arm the column held only its underside, 0.01 m, a hollow under 0.49 m of arm). The
	## columns drawn at all, merged along z, then x, each box up to the highest of its columns (a column between two
	## seat-height ones along x or z is the seat too: the gap between two slats); merged by their tops, a bar_stool's
	## footrest ring and legs were 13 boxes of the 15 its body had. Nobody passes under a seat, and the crowd's shin ray
	## must not either; nothing of a sitter is under its surface but their legs, in front of it.
	func _block() -> Array:
		var nx := _nx
		var nz := _nz
		var sl := nx * nz
		var top := _top
		for k in sl:
			if top[k] != -INF and _over[k] != 0:
				top[k] = maxf(top[k], 0.0)
		var cb := _cb
		var c := _c
		var lo := _lo
		var s := _s
		var out: Array = []
		var q := PackedInt32Array()
		q.resize(sl)
		for k in sl:
			q[k] = -1000000 if top[k] == -INF else ceili(minf(top[k], 0.0) - 1e-4)
		var slot := PackedByteArray()
		slot.resize(sl)
		for ix in nx:
			for iz in nz:
				var k := ix * nz + iz
				if q[k] != 0 and ((ix > 0 and ix < nx - 1 and q[k - nz] == 0 and q[k + nz] == 0)
						or (iz > 0 and iz < nz - 1 and q[k - 1] == 0 and q[k + 1] == 0)):
					slot[k] = 1
		for k in sl:
			if slot[k]:
				q[k] = 0
		var used := PackedByteArray()
		used.resize(sl)
		for ix in nx:
			for iz in nz:
				var k := ix * nz + iz
				if used[k] or q[k] == -1000000:
					continue
				var z1 := iz
				while z1 + 1 < nz and not used[k + z1 + 1 - iz] and q[k + z1 + 1 - iz] != -1000000:
					z1 += 1
				var x1 := ix
				while x1 + 1 < nx:
					var ok := true
					for zz in range(iz, z1 + 1):
						var kk := (x1 + 1) * nz + zz
						if used[kk] or q[kk] == -1000000:
							ok = false
							break
					if not ok:
						break
					x1 += 1
				var mn := Vector2(INF, INF)
				var mx := Vector2(-INF, -INF)
				var ty := -INF
				for xx in range(ix, x1 + 1):
					for zz in range(iz, z1 + 1):
						var kk := xx * nz + zz
						used[kk] = 1
						if top[kk] == -INF:   # a slat's gap: the whole cell, at the seat
							mn = mn.min(Vector2(xx, zz))
							mx = mx.max(Vector2(xx + 1, zz + 1))
							ty = maxf(ty, 0.0)
						else:
							mn = mn.min(Vector2(cb[4 * kk], cb[4 * kk + 2]))
							mx = mx.max(Vector2(cb[4 * kk + 1], cb[4 * kk + 3]))
							ty = maxf(ty, 0.0 if slot[kk] else top[kk])
				var b0 := Vector3(lo.x + mn.x * c, lo.y, lo.z + mn.y * c)
				var b1 := Vector3(lo.x + mx.x * c, s + ty * c, lo.z + mx.y * c)
				if b1.y > b0.y:
					out.append([Transform3D(Basis.IDENTITY, (b0 + b1) * 0.5), b1 - b0])
		return out

	## Stage 5: WHERE THE SITTER GOES — the sitter's keep-out, one box no box of the body enters (stages 6-8): the open air
	## over the seat round the seat point (the drawn bounds' centre, where add_seat puts the hips: _sit_player), grown from
	## an open cell over it a layer at a time each way in turn while every cell of the layer is open — stopped by a
	## backrest, an arm, an end panel, by SEAT_KEEP_R either way of the seat point and SEAT_KEEP_H up. Open: nothing drawn in
	## it, and nothing drawn up to a face of it (_touched: a sitter there touches the seat; a gap that narrow between two
	## slats is the seat's). Grown from each column within 3 cells of the seat point (its lowest open cell, 3 or fewer over
	## the seat), three ways each — each way in turn, up alone then across, across then up — and the biggest kept that
	## reaches the edge of the grid or of that reach: open air. One seed grown across first stopped under whatever leans over
	## the seat point (the sci-fi chair's back: a box 4 cm tall); a box that reaches neither is air shut in what is drawn —
	## the hollow of a pumpkin 0.9 m across on kk_halloween's decorated bench, where its seat measures (grown from the seed
	## nearest the seat point alone, the keep-out stood there and the bench's boxes where its sitters were, 2000-5000 of their
	## points), or the inside of a closed cushion (mod_house's kitchen bar stool: a drum 0.81-0.93 m, the seat measured at
	## its underside, under SEAT_BAND_HI — no keep-out at all rather than a 16 x 6 x 16 cm pocket in it). Two passes, a slice
	## at a time — the touched cells (_touch), every cell that is not open counted (3D prefix sums: a layer's in eight reads)
	## — then the seeds, one a slice.
	func _keep(deadline: int) -> bool:
		var nx := _nx
		var nz := _nz
		var nyu := _nyu
		var sl := nx * nz
		var n := sl * nyu
		var px := nx + 1
		var pz := nz + 1
		if _sub == 0 and _i == 0:
			_pk.resize(px * (nyu + 1) * pz)
			_pk.fill(0)
			_tc.resize(n)
			_tc.fill(0)
		while _sub < 2:
			if _sub == 0:
				if not _touch(deadline):
					return false
			else:
				var ps := _pk
				var up := _up
				var tc := _tc
				var k := _i
				while k < n:
					if (k & 1023) == 0 and k > _i and Time.get_ticks_usec() > deadline:
						_i = k
						return false
					var iy := k / sl
					var r := k % sl
					var o := ((iy + 1) * px + r / nz + 1) * pz + r % nz + 1
					ps[o] = (1 if up[k] != 0 or tc[k] != 0 else 0) + ps[o - pz * px] + ps[o - pz] + ps[o - 1] - ps[o - pz * px - pz] \
						- ps[o - pz * px - 1] - ps[o - pz - 1] + ps[o - pz * px - pz - 1]
					k += 1
			_i = 0
			_sub += 1
			if _sub < 2 and Time.get_ticks_usec() > deadline:
				return false
		_tc = PackedByteArray()
		var sx := clampi(floori(((_lo.x + _hi.x) * 0.5 - _lo.x) / _c), 0, nx - 1)
		var sz := clampi(floori(((_lo.z + _hi.z) * 0.5 - _lo.z) / _c), 0, nz - 1)
		var rr := ceili(GShapes.SEAT_KEEP_R / _c)
		var lo3 := Vector3i(maxi(sx - rr, 0), 0, maxi(sz - rr, 0))
		var hi3 := Vector3i(mini(sx + rr, nx - 1), mini(nyu, ceili(GShapes.SEAT_KEEP_H / _c)) - 1, mini(sz + rr, nz - 1))
		var lat := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(2, -1), Vector2i(2, 1)]
		var up1 := [Vector2i(1, 1), Vector2i(1, -1)]
		var first := true
		while _ki < 7 * 7:
			if not first and Time.get_ticks_usec() > deadline:
				return false
			first = false
			var s0 := Vector3i(sx + (_ki / 7) - 3, -1, sz + (_ki % 7) - 3)
			_ki += 1
			if s0.x < lo3.x or s0.x > hi3.x or s0.z < lo3.z or s0.z > hi3.z:
				continue
			for iy in mini(hi3.y + 1, 4):
				if GShapes._seat_drawn(_pk, px, pz, Vector3i(s0.x, iy, s0.z), Vector3i(s0.x, iy, s0.z)) == 0:
					s0.y = iy
					break
			if s0.y < 0:
				continue
			for order in [[lat + up1], [up1, lat], [lat, up1]]:
				var a1 := s0
				var b1 := s0
				for dirs: Array in order:
					var grew := true
					while grew:
						grew = false
						for dir: Vector2i in dirs:
							var a2 := a1
							var b2 := b1
							if dir.y > 0:
								if b1[dir.x] + 1 > hi3[dir.x]:
									continue
								a2[dir.x] = b1[dir.x] + 1
								b2[dir.x] = b1[dir.x] + 1
							else:
								if a1[dir.x] - 1 < lo3[dir.x]:
									continue
								a2[dir.x] = a1[dir.x] - 1
								b2[dir.x] = a1[dir.x] - 1
							if GShapes._seat_drawn(_pk, px, pz, a2, b2) == 0:
								if dir.y > 0:
									b1[dir.x] += 1
								else:
									a1[dir.x] -= 1
								grew = true
				var vol := (b1.x - a1.x + 1) * (b1.y - a1.y + 1) * (b1.z - a1.z + 1)
				var open := a1.x == lo3.x or b1.x == hi3.x or a1.z == lo3.z or b1.z == hi3.z or b1.y == hi3.y
				if open and vol > _kvol:
					_kvol = vol
					_ka = a1
					_kb = b1
		_sub = 0
		_pk = PackedInt32Array()
		if _kvol == 0:
			return true
		# in the model's units, from over the lip (the block's), and out to the keep-out's reach wherever it meets the grid's
		# edge: past it nothing is drawn and nothing is boxed (a bar_stool's sitter sits wholly over its grid's top)
		var k0 := Vector3(_lo.x + _ka.x * _c, _s + maxf(_ka.y * _c, GShapes.SEAT_LIP), _lo.z + _ka.z * _c)
		var k1 := Vector3(_lo.x + (_kb.x + 1) * _c, _s + (_kb.y + 1) * _c, _lo.z + (_kb.z + 1) * _c)
		var sp := Vector3((_lo.x + _hi.x) * 0.5, _s, (_lo.z + _hi.z) * 0.5)
		if _ka.x == 0:
			k0.x = minf(k0.x, sp.x - GShapes.SEAT_KEEP_R)
		if _kb.x == nx - 1:
			k1.x = maxf(k1.x, sp.x + GShapes.SEAT_KEEP_R)
		if _ka.z == 0:
			k0.z = minf(k0.z, sp.z - GShapes.SEAT_KEEP_R)
		if _kb.z == nz - 1:
			k1.z = maxf(k1.z, sp.z + GShapes.SEAT_KEEP_R)
		if _kb.y == nyu - 1:
			k1.y = maxf(k1.y, _s + GShapes.SEAT_KEEP_H)
		keep = AABB(k0, k1 - k0)
		return true

	## Stage 5's pass 0: THE TOUCHED CELLS — every empty cell what a drawn neighbour draws reaches the face of (within a
	## quarter cell), marked from the drawn cells' side: a sitter there touches the seat (the people rig counts no sitter
	## point within 4 cm of what is drawn), and a gap that narrow between two slats is the seat's. Any cell of the 26 within
	## half a cell was too many: the boxes then bridged the notch between a KayKit couch's back cushions over Hal's back.
	func _touch(deadline: int) -> bool:
		var nx := _nx
		var nz := _nz
		var nyu := _nyu
		var sl := nx * nz
		var up := _up
		var ub6 := _ub6
		var q := _i
		while q < _dl.size():
			if (q & 255) == 0 and q > _i and Time.get_ticks_usec() > deadline:
				_i = q
				return false
			var k := _dl[q]
			q += 1
			var iy := k / sl
			var r := k % sl
			var ix := r / nz
			var iz := r % nz
			var o := 6 * k
			if ix > 0 and up[k - nz] == 0 and ub6[o] <= ix + 0.25:
				_tc[k - nz] = 1
			if ix < nx - 1 and up[k + nz] == 0 and ub6[o + 1] >= ix + 0.75:
				_tc[k + nz] = 1
			if iy > 0 and up[k - sl] == 0 and ub6[o + 2] <= iy + 0.25:
				_tc[k - sl] = 1
			if iy < nyu - 1 and up[k + sl] == 0 and ub6[o + 3] >= iy + 0.75:
				_tc[k + sl] = 1
			if iz > 0 and up[k - 1] == 0 and ub6[o + 4] <= iz + 0.25:
				_tc[k - 1] = 1
			if iz < nz - 1 and up[k + 1] == 0 and ub6[o + 5] >= iz + 0.75:
				_tc[k + 1] = 1
		return true

	## Stage 6: THE PARTS DRAWN OVER THE SEAT — its drawn cells, face to face: a backrest, an arm, an end panel, a pumpkin.
	## A part that reaches round the keep-out (a KayKit couch's back and arms are one) is cut by the side of it each cell
	## lies past — the side it lies farthest past, a tie to the side with the most drawn beyond it (the cell at the corner
	## of an arm and a back stays the arm's: given to the back, it stood the back's box at the keep-out's face all the way
	## up) — and each piece, face to face, is a part. Union-find a drawn cell at a time, six passes a slice per call (256
	## cells a look at the clock): the parts; each part's bounds at its root; what is drawn past each side; each cell's side;
	## the pieces; each piece's cells, gathered for stage 7.
	func _parts(deadline: int) -> bool:
		var nx := _nx
		var nz := _nz
		var sl := nx * nz
		var n := sl * _nyu
		var up := _up
		var cuts := _kb.x >= _ka.x
		if _sub == 0 and _i == 0:
			_dl.sort()   # a cell's neighbours behind it are joined before it: index order
			_uf.resize(n)
			_uf.fill(-1)
			_lab.resize(n)
			_clo.resize(3 * n)
			_clo.fill(1 << 30)
			_chi.resize(3 * n)
			_chi.fill(-1)
			_side.resize(n)
			_mass.fill(0)
		var uf := _uf
		var dl := _dl
		while _sub < 6:
			var q := _i
			while q < dl.size():
				if (q & 255) == 0 and q > _i and Time.get_ticks_usec() > deadline:
					_i = q
					return false
				var kk := dl[q]
				q += 1
				var iz := kk % nz
				var ix := (kk % sl) / nz
				var iy := kk / sl
				match _sub:
					0:   # the parts: every drawn cell joined to its drawn neighbours behind it on z, x and y
						uf[kk] = kk
						if iz > 0 and up[kk - 1] != 0:
							GShapes._uf_join(uf, kk, kk - 1)
						if ix > 0 and up[kk - nz] != 0:
							GShapes._uf_join(uf, kk, kk - nz)
						if iy > 0 and up[kk - sl] != 0:
							GShapes._uf_join(uf, kk, kk - sl)
					1:   # each part's cells' bounds, kept at its root
						var rt := GShapes._uf_root(uf, kk)
						_lab[kk] = rt
						_clo[3 * rt] = mini(_clo[3 * rt], ix)
						_chi[3 * rt] = maxi(_chi[3 * rt], ix)
						_clo[3 * rt + 1] = mini(_clo[3 * rt + 1], iy)
						_chi[3 * rt + 1] = maxi(_chi[3 * rt + 1], iy)
						_clo[3 * rt + 2] = mini(_clo[3 * rt + 2], iz)
						_chi[3 * rt + 2] = maxi(_chi[3 * rt + 2], iz)
					2:   # what is drawn past each side of the keep-out (x-, x+, z-, z+, y+), by the parts that reach round it
						if cuts and _round(_lab[kk]):
							_sep(ix, iy, iz)
							for j in 5:
								if _sp[j] > 0:
									_mass[j] += 1
					3:   # ...the side each of their cells lies past
						if cuts and _round(_lab[kk]):
							_sep(ix, iy, iz)
							var best := -1
							for j in 5:
								if _sp[j] > 0 and (best < 0 or _sp[j] > _sp[best] or (_sp[j] == _sp[best] and _mass[j] > _mass[best])):
									best = j
							_side[kk] = best
					4:   # ...and the pieces each side holds, face to face (every other part keeps its own root)
						uf[kk] = kk
						if cuts and _round(_lab[kk]):
							if iz > 0 and up[kk - 1] != 0 and _lab[kk - 1] == _lab[kk] and _side[kk - 1] == _side[kk]:
								GShapes._uf_join(uf, kk, kk - 1)
							if ix > 0 and up[kk - nz] != 0 and _lab[kk - nz] == _lab[kk] and _side[kk - nz] == _side[kk]:
								GShapes._uf_join(uf, kk, kk - nz)
							if iy > 0 and up[kk - sl] != 0 and _lab[kk - sl] == _lab[kk] and _side[kk - sl] == _side[kk]:
								GShapes._uf_join(uf, kk, kk - sl)
					_:   # each piece's cells, by its root
						var p: int = GShapes._uf_root(uf, kk) if cuts and _round(_lab[kk]) else _lab[kk]
						var got: PackedInt32Array = _part_of.get(p, PackedInt32Array())
						got.append(kk)
						_part_of[p] = got   # a packed array taken out of a container is a copy: put back
			_i = 0
			_sub += 1
			if _sub == 4:
				uf.fill(-1)
			if _sub < 6 and Time.get_ticks_usec() > deadline:
				return false
		for p in _part_of:
			_work.append(_part_of[p])
		_uf = PackedInt32Array()
		_lab = PackedInt32Array()
		_clo = PackedInt32Array()
		_chi = PackedInt32Array()
		_side = PackedInt32Array()
		_part_of = {}
		_sub = 0
		return true

	## Whether the part rooted at `rt` reaches round the keep-out: its cells' bounds overlap it on all three axes.
	func _round(rt: int) -> bool:
		return _clo[3 * rt] <= _kb.x and _chi[3 * rt] >= _ka.x and _clo[3 * rt + 1] <= _kb.y and _chi[3 * rt + 1] >= _ka.y \
			and _clo[3 * rt + 2] <= _kb.z and _chi[3 * rt + 2] >= _ka.z

	## How far out of the keep-out cell (ix, iy, iz) lies past each side, in cells, into _sp: x-, x+, z-, z+, y+ (<= 0: not
	## past it).
	func _sep(ix: int, iy: int, iz: int) -> void:
		_sp[0] = _ka.x - ix
		_sp[1] = ix - _kb.x
		_sp[2] = _ka.z - iz
		_sp[3] = iz - _kb.z
		_sp[4] = iy - _kb.y

	## Stage 7: A BOX PER PIECE — the box over what its cells draw along the piece's own axes (the principal axes of the
	## corners of what its cells draw: a backrest that leans back is one box leaning with it, as close to its face at the top
	## as at the bottom), or square to the grid where that is the smaller or the other would enter the keep-out. A piece a
	## few slices: its spread summed 512 cells at a time, then the axes, then its extent along them, 512 cells at a time.
	func _pieces(deadline: int) -> bool:
		var first := true
		while _wi < _work.size():
			var cells: PackedInt32Array = _work[_wi]
			var n := cells.size()
			while _wj < n:
				if not first and Time.get_ticks_usec() > deadline:
					return false
				first = false
				var j1 := mini(n, _wj + 512)
				for q in range(_wj, j1):
					var o := 6 * cells[q]
					var c0 := Vector3(_ub6[o], _ub6[o + 2], _ub6[o + 4])
					var c1 := Vector3(_ub6[o + 1], _ub6[o + 3], _ub6[o + 5])
					if _wpass == 0:
						# the spread of the cell's 8 corners: its centre's, plus a box's own (h² per axis)
						var cc := (c0 + c1) * 0.5
						var hh := (c1 - c0) * 0.5
						_ws += cc
						for r in 3:
							for t in 3:
								_wm[3 * r + t] += cc[r] * cc[t] + (hh[r] * hh[r] if r == t else 0.0)
						_we0 = _we0.min(c0)
						_we1 = _we1.max(c1)
					else:
						var cc := (c0 + c1) * 0.5
						var hh := (c1 - c0) * 0.5
						for r in 3:
							var ax: Vector3 = _wax[r]
							var m := ax.dot(cc)
							var e := absf(ax.x) * hh.x + absf(ax.y) * hh.y + absf(ax.z) * hh.z
							_wlo[r] = minf(_wlo[r], m - e)
							_whi[r] = maxf(_whi[r], m + e)
				_wj = j1
				if _wj == n and _wpass == 0:
					_wpass = 1
					_wj = 0
					_wax = GShapes._axes(_wm, _ws, n)
					_wlo = PackedFloat64Array([INF, INF, INF])
					_whi = PackedFloat64Array([-INF, -INF, -INF])
			# the box along its axes, or square to the grid
			var ax: Array = _wax
			var mid := Vector3((_wlo[0] + _whi[0]) * 0.5, (_wlo[1] + _whi[1]) * 0.5, (_wlo[2] + _whi[2]) * 0.5)
			var obb := [Transform3D(Basis(ax[0], ax[1], ax[2]), (ax[0] as Vector3) * mid.x + (ax[1] as Vector3) * mid.y + (ax[2] as Vector3) * mid.z),
				Vector3(_whi[0] - _wlo[0], _whi[1] - _wlo[1], _whi[2] - _wlo[2])]
			var aab := [Transform3D(Basis.IDENTITY, (_we0 + _we1) * 0.5), _we1 - _we0]
			var bx: Array = aab
			if (obb[1] as Vector3).x * (obb[1] as Vector3).y * (obb[1] as Vector3).z < (_we1 - _we0).x * (_we1 - _we0).y * (_we1 - _we0).z \
					and not _meets_keep(obb):
				bx = obb
			boxes.append([Transform3D((bx[0] as Transform3D).basis, Vector3(_lo.x, _s, _lo.z) + (bx[0] as Transform3D).origin * _c),
				(bx[1] as Vector3) * _c])
			_wi += 1
			_wj = 0
			_wpass = 0
			_ws = Vector3.ZERO
			_wm.fill(0.0)
			_we0 = Vector3.INF
			_we1 = -Vector3.INF
		_work = []
		return true

	## Whether a box [Transform3D, size] (cells, from the grid's corner) enters the keep-out — from over the lip — by more
	## than a millimetre.
	func _meets_keep(bx: Array) -> bool:
		if _kb.x < _ka.x:
			return false
		var y0 := maxf(_ka.y, _lip)
		var kxf := Transform3D(Basis.IDENTITY, Vector3((_ka.x + _kb.x + 1) * 0.5, (y0 + _kb.y + 1) * 0.5, (_ka.z + _kb.z + 1) * 0.5))
		return GShapes._boxes_meet(bx[0], bx[1], kxf, Vector3(_kb.x - _ka.x + 1, _kb.y + 1 - y0, _kb.z - _ka.z + 1), 0.001 / _c)

	## Stage 8: AT MOST SEAT_BOXES. Over the cap (a bench decorated with a dozen pumpkins), the two boxes whose union adds
	## the least volume to what the two held go together — never into the keep-out — until it fits, or no two can. What
	## each pair would cost is worked out once and, after a merge, only the merged box's pairs: 8 pairs a look at the clock.
	func _cap(deadline: int) -> bool:
		var m := boxes.size()
		if _live == 0:
			parts = m
			if m <= GShapes.SEAT_BOXES:
				return true
			_live = m
			_cost.resize(m * m)
			_cost.fill(INF)
			for i in m:
				for j in range(i + 1, m):
					_pend.append(i * m + j)
		var first := true
		while true:
			while not _pend.is_empty():
				if not first and Time.get_ticks_usec() > deadline:
					return false
				first = false
				for q in mini(8, _pend.size()):
					var ij: int = _pend[_pend.size() - 1]
					_pend.resize(_pend.size() - 1)
					_cap_pair(ij / m, ij % m)
			if _live <= GShapes.SEAT_BOXES:
				break
			var bi := -1
			var bc := INF
			for q in _cost.size():
				if _cost[q] < bc:
					bc = _cost[q]
					bi = q
			if bi < 0:
				break
			var i := bi / m
			var j := bi % m
			boxes[i] = _union(boxes[i], boxes[j])
			boxes[j] = null
			for q in m:
				_cost[j * m + q] = INF
				_cost[q * m + j] = INF
				if q != i and boxes[q] != null:
					_pend.append(mini(i, q) * m + maxi(i, q))
			_live -= 1
		boxes = boxes.filter(func(x): return x != null)
		_cost = PackedFloat32Array()
		return true

	## The box round two boxes ([Transform3D, size], the seat's own frame): along the axes of their 16 corners.
	func _union(A: Array, B: Array) -> Array:
		var pts := PackedVector3Array()
		for bx in [A, B]:
			var h: Vector3 = (bx[1] as Vector3) * 0.5
			for j in 8:
				pts.append((bx[0] as Transform3D) * Vector3(h.x * (1 if (j & 1) else -1), h.y * (1 if (j & 2) else -1), h.z * (1 if (j & 4) else -1)))
		return GShapes._obb(pts)

	## What merging boxes `i` and `j` would add (INF: a union entering the keep-out).
	func _cap_pair(i: int, j: int) -> void:
		var m := boxes.size()
		if boxes[i] == null or boxes[j] == null:
			return
		var A: Array = boxes[i]
		var B: Array = boxes[j]
		var U := _union(A, B)
		var cost := INF
		# the keep-out test is in cells, from the grid's corner: the union taken there
		var cu := Transform3D((U[0] as Transform3D).basis, ((U[0] as Transform3D).origin - Vector3(_lo.x, _s, _lo.z)) / _c)
		if not _meets_keep([cu, (U[1] as Vector3) / _c]):
			var vo := func(bx: Array) -> float: return (bx[1] as Vector3).x * (bx[1] as Vector3).y * (bx[1] as Vector3).z
			cost = vo.call(U) - vo.call(A) - vo.call(B)
		_cost[mini(i, j) * m + maxi(i, j)] = cost


## THE BOX ROUND `pts` ALONG THEIR OWN AXES (_axes), and the extent of the points along each. [Transform3D (the axes,
## the box's centre), size].
static func _obb(pts: PackedVector3Array) -> Array:
	var sm := Vector3.ZERO
	var mm := PackedFloat64Array([0, 0, 0, 0, 0, 0, 0, 0, 0])
	for p in pts:
		sm += p
		for r in 3:
			for t in 3:
				mm[3 * r + t] += p[r] * p[t]
	var ax := _axes(mm, sm, pts.size())
	var lo := Vector3.INF
	var hi := -Vector3.INF
	for p in pts:
		var l := Vector3((ax[0] as Vector3).dot(p), (ax[1] as Vector3).dot(p), (ax[2] as Vector3).dot(p))
		lo = lo.min(l)
		hi = hi.max(l)
	var mid := (lo + hi) * 0.5
	return [Transform3D(Basis(ax[0], ax[1], ax[2]), (ax[0] as Vector3) * mid.x + (ax[1] as Vector3) * mid.y + (ax[2] as Vector3) * mid.z), hi - lo]


## THE PRINCIPAL AXES of `n` points whose sum is `sm` and whose second moments are `mm` (3 x 3, row-major): the
## eigenvectors of their covariance (Jacobi), as three orthonormal Vector3 (right-handed).
static func _axes(mm: PackedFloat64Array, sm: Vector3, n: int) -> Array:
	var c := sm / float(maxi(n, 1))
	var m := [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
	for r in 3:
		for t in 3:
			m[r][t] = mm[3 * r + t] / float(maxi(n, 1)) - c[r] * c[t]
	var v := [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
	for sweep in 16:
		if absf(m[0][1]) + absf(m[0][2]) + absf(m[1][2]) < 1e-12:
			break
		for pq in [[0, 1], [0, 2], [1, 2]]:
			var p: int = pq[0]
			var q: int = pq[1]
			if absf(m[p][q]) < 1e-15:
				continue
			var th: float = (m[q][q] - m[p][p]) / (2.0 * m[p][q])
			var t: float = signf(th) / (absf(th) + sqrt(th * th + 1.0)) if th != 0.0 else 1.0
			var co := 1.0 / sqrt(t * t + 1.0)
			var si := t * co
			for k in 3:
				var mkp: float = m[k][p]
				var mkq: float = m[k][q]
				m[k][p] = co * mkp - si * mkq
				m[k][q] = si * mkp + co * mkq
			for k in 3:
				var mpk: float = m[p][k]
				var mqk: float = m[q][k]
				m[p][k] = co * mpk - si * mqk
				m[q][k] = si * mpk + co * mqk
			for k in 3:
				var vkp: float = v[k][p]
				var vkq: float = v[k][q]
				v[k][p] = co * vkp - si * vkq
				v[k][q] = si * vkp + co * vkq
	var ax := Vector3(v[0][0], v[1][0], v[2][0]).normalized()
	var ay := Vector3(v[0][1], v[1][1], v[2][1]).normalized()
	var az := ax.cross(ay).normalized()
	ay = az.cross(ax).normalized()
	return [ax, ay, az]


## Whether two boxes ([Transform3D, size] each) overlap by more than `tol` along every one of their 15 separating axes.
static func _boxes_meet(xa: Transform3D, sa: Vector3, xb: Transform3D, sb: Vector3, tol: float) -> bool:
	var ha := sa * 0.5
	var hb := sb * 0.5
	var A := [xa.basis.x.normalized(), xa.basis.y.normalized(), xa.basis.z.normalized()]
	var B := [xb.basis.x.normalized(), xb.basis.y.normalized(), xb.basis.z.normalized()]
	var axes: Array = A + B
	for i in 3:
		for j in 3:
			var cr: Vector3 = (A[i] as Vector3).cross(B[j])
			if cr.length_squared() > 1e-10:
				axes.append(cr.normalized())
	var d := xb.origin - xa.origin
	for ax: Vector3 in axes:
		var ra := absf(ax.dot(A[0])) * ha.x + absf(ax.dot(A[1])) * ha.y + absf(ax.dot(A[2])) * ha.z
		var rb := absf(ax.dot(B[0])) * hb.x + absf(ax.dot(B[1])) * hb.y + absf(ax.dot(B[2])) * hb.z
		if absf(d.dot(ax)) >= ra + rb - tol:
			return false
	return true


## How many counted cells the cell box `a`..`b` holds, from `ps`: SeatFit._keep's 3D prefix sums, (nx + 1) x (ny + 1)
## x (nz + 1), z fastest, then x, then y.
static func _seat_drawn(ps: PackedInt32Array, px: int, pz: int, a: Vector3i, b: Vector3i) -> int:
	var x0 := a.x
	var x1 := b.x + 1
	var y0 := a.y
	var y1 := b.y + 1
	var z0 := a.z
	var z1 := b.z + 1
	return ps[(y1 * px + x1) * pz + z1] - ps[(y0 * px + x1) * pz + z1] - ps[(y1 * px + x0) * pz + z1] - ps[(y1 * px + x1) * pz + z0] \
		+ ps[(y0 * px + x0) * pz + z1] + ps[(y0 * px + x1) * pz + z0] + ps[(y1 * px + x0) * pz + z0] - ps[(y0 * px + x0) * pz + z0]


## Union-find over a seat's cells (SeatFit stage 6): the root of `k`, halving the path as it goes.
static func _uf_root(uf: PackedInt32Array, k: int) -> int:
	while uf[k] != k:
		uf[k] = uf[uf[k]]
		k = uf[k]
	return k


## ...and `a`'s and `b`'s sets made one (the lower root wins: a part's root is its first cell).
static func _uf_join(uf: PackedInt32Array, a: int, b: int) -> void:
	var ra := _uf_root(uf, a)
	var rb := _uf_root(uf, b)
	if ra < rb:
		uf[rb] = ra
	elif rb < ra:
		uf[ra] = rb


# ─────────────────────────────── internals ───────────────────────────────

# A plain wood/metal-ish material baked into the ladder factory (the ONE built-in that ships a default
# material — a placed ladder must read as a rung structure even without a surface pass; a caller may still
# override via set_material). Kept private + minimal; the surface cookbook (surfaces.gd) owns richer looks.
static func _ladder_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.40, 0.27, 0.15)   # weathered wood; a metal ladder overrides via set_material
	m.roughness = 0.8
	return m


static func _mi(mesh: Mesh, base_offset_y: float) -> MeshInstance3D:
	# Built-in primitive meshes are centred at the origin; lift by half-height so the BASE rests at y=0.
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position.y = base_offset_y
	return mi


# Emit one convex, planar face (tri or quad) with an OUTWARD normal (away from the solid's centroid) and
# Godot-correct CLOCKWISE-from-outside winding (Godot's front-face convention) — so it is lit right AND not
# back-culled. Convention-independent: derived from geometry, never from the caller's vertex order.
static func _emit_face(st: SurfaceTool, verts: Array, centroid: Vector3) -> void:
	var v0: Vector3 = verts[0]
	var v1: Vector3 = verts[1]
	var v2: Vector3 = verts[2]
	var g := (v1 - v0).cross(v2 - v0)
	if g.length() < 1e-9:
		return   # degenerate
	var fc := Vector3.ZERO
	for v in verts:
		fc += v
	fc /= float(verts.size())
	var outward := fc - centroid
	var n: Vector3
	var ordered: Array
	if g.dot(outward) > 0.0:
		# current order is CCW-from-outside -> reverse to get CW (front-facing); normal already outward
		n = g.normalized()
		ordered = verts.duplicate()
		ordered.reverse()
	else:
		n = (-g).normalized()
		ordered = verts
	# fan-triangulate the (convex) face
	for ti in range(1, ordered.size() - 1):
		for vert in [ordered[0], ordered[ti], ordered[ti + 1]]:
			st.set_normal(n)
			st.set_uv(_planar_uv(vert, n))
			st.add_vertex(vert)


# Simple world-space planar UV (1 unit = 1 tile). Triplanar materials ignore this; it keeps non-triplanar
# materials from stretching catastrophically.
static func _planar_uv(v: Vector3, n: Vector3) -> Vector2:
	var an := Vector3(absf(n.x), absf(n.y), absf(n.z))
	if an.y >= an.x and an.y >= an.z:
		return Vector2(v.x, v.z)
	if an.x >= an.z:
		return Vector2(v.z, v.y)
	return Vector2(v.x, v.y)


static func _all_meshes(node: Node) -> Array:
	var out: Array = []
	var stack: Array = [node]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


## What `node` draws, in its OWN frame (its own transform left out: the collider built from this hangs under it).
static func _aabb(node: Node3D) -> AABB:
	# DETACHMENT-SAFE (mirrors AreaBuilder._world_aabb): accumulates
	# transforms manually — structure parts are measured while still
	# detached, where global_transform is IDENTITY + an error line.
	var merged := AABB()
	var first := true
	var stack: Array = [[node, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var pair: Array = stack.pop_back()
		var n: Node = pair[0]
		var xf: Transform3D = pair[1]
		for c in n.get_children():
			var cx := xf
			if c is Node3D:
				cx = xf * (c as Node3D).transform
			stack.append([c, cx])
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var wa: AABB = xf * (n as MeshInstance3D).get_aabb()
			if first:
				merged = wa
				first = false
			else:
				merged = merged.merge(wa)
	return merged
