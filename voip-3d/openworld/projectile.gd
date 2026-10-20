class_name GProjectile extends Node3D
## POOLED KINEMATIC PROJECTILES (Wave 4) — arrows/bolts for ranged + thrown weapons. NO physics
## bodies of their own: pure kinematic advance + ONE intersect_ray per tick against every body a
## shot can meet (HIT_MASK: the world, enemies, other players, people) — the first body along the
## path is the one hit, whatever it is. Cheap and mobile-safe: one ray, no per-target loop.
##
##   GProjectile.fire(world_root, from, dir, def, on_hit=Callable(), exclude=[], mask=HIT_MASK)
##       -> GProjectile|null   spawn from the pool, velocity = dir.normalized() * speed
##   GProjectile.fire_at(world_root, from, to, def, on_hit=Callable(), exclude=[], mask=HIT_MASK)
##       -> GProjectile|null   aim at a POINT; when the def arcs (thrown) the launch velocity is
##                             ballistically compensated (+0.5*g*t up) so the drop lands ON `to` —
##                             under the first surface overhead (see _arc_vy)
##   GProjectile.pick_target(from, facing, targets, max_range, cone_deg=30.0, reaches=Callable())
##       -> Node3D|null        mobile AUTO-AIM: the nearest live target inside a `cone_deg`
##                             half-angle cone of `facing` (horizontal, like the melee arc) AND within
##                             range — the nearest one `reaches` says the shot can reach, given one;
##                             none it can -> the nearest. null -> caller fires straight ahead
##   GProjectile.aim_point(target) -> Vector3         the CENTRE OF THE TARGET'S BODY (GBody.of:
##                                                    the body its collider was built from), in the
##                                                    world; origin +1.0 m only for a target with no body
##   GProjectile.lead_point(target, muzzle, def) -> Vector3   aim_point advanced by the target's
##                                                    `velocity` over the flight time: where a
##                                                    moving body WILL be when the shot gets there
##   GProjectile.clear_muzzle(space, barrel, muzzle, exclude=[]) -> Vector3   the muzzle, pulled back
##                                                    to the first wall between the shooter (`barrel`:
##                                                    their axis at muzzle height) and it — never
##                                                    `exclude` (RIDs: their seat, their mount)
##   GProjectile.sight(space, q) -> Dictionary        intersect_ray for a LINE OF FIRE: a seat's body
##                                                    passed, its drawing met (GShapes.SIGHT_LAYER)
##   GProjectile.flash(at, parent)                    muzzle flash: emissive quad + OmniLight
##                                                    pulse, 0.08 s (fire()/fire_at() call it
##                                                    automatically at `from`)
##
## `def` = the merged weapon def (GEquip contract). Stats read with the pinned schema defaults:
## damage 1, speed 22 (from def.projectile.speed, then def.speed), arc true only for "thrown".
## `on_hit(collider, at, damage)` = what the SHOOTER decides a hit on that body means (main:
## an enemy or a player -> take_hit, a person -> an assault). EMPTY = a picture of a shot resolved
## elsewhere (another player's tracer): it still stops at the first body, and resolves nothing.
## `exclude` = nodes (or RIDs) the ray must ignore, each with every collider under it — the RIDER'S
## OWN MOUNT (a hull on world layer 1), a remote shooter's own body. `from` = where the shot leaves: the
## muzzle, which the shooter has pulled back out of any wall between their body and it (clear_muzzle).
## A body the muzzle is inside — a person pressed against the weapon side — is met right there (_launch).
##
## POOL: max 12 live, statically pooled and reused (oldest is recycled when full); zero per-frame
## allocations (the ray-query params, meshes, puffs and flash are all reused). Pool nodes parent
## to `world_root` — pass a PERSISTENT root (main), never a cell/area root, or the pool dies with
## the area (guards recreate it, but that wastes the pool). Impact puffs (one-shot CPUParticles3D)
## and the muzzle flash are pooled too (never freed — strictly cheaper than free-per-impact).
##
## HITS: the first body the tick's segment meets — a wall, an enemy, another player, a person —
## stops the shot at the point it met it: on_hit(collider, point, damage), a puff there, deactivate.
## A body is its collision shape, the one the physics has (a crowd member's is GPose.body_fit's,
## an enemy's its own): a shot 0.8 m wide of a 0.4 m capsule is a miss, not a hit on a 0.9 m chest
## sphere. A dead target has no body (enemy._die and peer_body.set_dead drop the layer), so shots
## pass it. No dependency on enemy.gd (works in both templates): the shooter's on_hit decides who a
## collider belongs to (main._shot_owner — GBody.of, the one owner contract).
## 3 s lifetime cap. Deactivated projectiles stop processing entirely.

const MAX_LIVE := 12
const LIFETIME := 3.0
const CHEST := Vector3(0.0, 1.0, 0.0)
## Every body a shot can meet: main.gd L_WORLD | L_ENEMY | L_PEER | L_CROWD, and a seat as it is drawn
## (L_SIGHT: GShapes.SIGHT_LAYER — its body's boxes are passed, see sight). The player's own layer
## (L_PLAYER) is not in it — a shooter never meets themselves; another player's tracer adds it.
const HIT_MASK := 1 | 4 | 8 | 16 | GShapes.SIGHT_LAYER
## Air kept between a lobbed throw's apex and the first surface over the thrower (see _arc_vy).
const ARC_CLEAR := 0.2
## How far short of a wall's face a muzzle pulled back out of it stops (see clear_muzzle).
const MUZZLE_BACK := 0.02
const GRAVITY := 9.8
const FLASH_TIME := 0.08

# schema defaults (duplicated tiny readers keep this module self-contained; GEquip.stat is the
# public one for main)
const DEF_DAMAGE := 1.0
const DEF_SPEED := 22.0

static var _pool: Array = []                 # GProjectile nodes, live + idle (max MAX_LIVE)
static var _flash_node: Node3D = null        # pooled muzzle flash (quad + light + timer)
static var _flash_timer: Timer = null
static var _puffs: Array = []                # ring of pooled impact puffs
static var _puff_i := 0
static var _mat_bolt: StandardMaterial3D = null
static var _mat_arrow: StandardMaterial3D = null
static var _point_q: PhysicsPointQueryParameters3D = null   # containment at launch (see contained)

var _active := false
var _vel := Vector3.ZERO
var _arc := false
var _dmg := 1.0
var _life := 0.0
var _born := 0
var _on_hit := Callable()
## The velocity it left the muzzle with — fire_at's answer, a throw's arc compensated and capped: what
## another player's picture of this shot must replay (main._fire_ranged -> netsync.report_shot).
var launch := Vector3.ZERO
var _ray: PhysicsRayQueryParameters3D
var _bolt: MeshInstance3D
var _arrow: MeshInstance3D


# ─────────────────────────────── public API ───────────────────────────────

## Fire along a DIRECTION (auto-aim missed / straight ahead). Velocity = dir.normalized()*speed;
## an arcing def then drops under gravity (no compensation — use fire_at for a known target).
static func fire(world_root: Node3D, from: Vector3, dir: Vector3, def: Dictionary, on_hit: Callable = Callable(), exclude: Array = [], mask: int = HIT_MASK) -> GProjectile:
	if world_root == null or not is_instance_valid(world_root) or not world_root.is_inside_tree():
		return null
	var v := dir
	if v.length() < 0.001:
		v = Vector3.BACK                      # stack convention: characters face +Z
	v = v.normalized() * _speed_of(def)
	return _spawn(world_root, from, v, def, on_hit, exclude, mask)


## Fire AT a point (the auto-aimed body). Straight shot for flat defs; arcing defs get the exact
## ballistic compensation (v.y += 0.5*g*t for t = dist/speed), so the drop cancels at `to` — as far
## as the room over the thrower allows (_arc_vy).
static func fire_at(world_root: Node3D, from: Vector3, to: Vector3, def: Dictionary, on_hit: Callable = Callable(), exclude: Array = [], mask: int = HIT_MASK) -> GProjectile:
	if world_root == null or not is_instance_valid(world_root) or not world_root.is_inside_tree():
		return null
	var speed := _speed_of(def)
	var delta := to - from
	var dist := delta.length()
	if dist < 0.05 or speed < 0.05:
		return fire(world_root, from, delta, def, on_hit, exclude, mask)
	var t := dist / speed
	var v := delta / t
	if _arc_of(def):
		v.y = _arc_vy(world_root.get_world_3d().direct_space_state, from, v.y, v.y + 0.5 * GRAVITY * t, exclude)
	return _spawn(world_root, from, v, def, on_hit, exclude, mask)


## Mobile AUTO-AIM: nearest live target within `cone_deg` HALF-ANGLE of `facing` (flattened
## horizontal, matching the melee arc test) and within `max_range` (horizontal). Null = none.
##
## THE SHOT IS PHYSICAL, SO THE AIM PREFERS A SHOT THAT CAN LAND. A bystander or a wall on the line
## to the nearest target takes the shot (the first body is the one hit), so given `reaches` — the
## caller's answer to "would a shot at this target meet it first" — the nearest target it says yes to
## wins; with none it can reach it is the nearest anyway: the player pressed fire, and whoever stands
## in the way takes it. Civilians are never candidates: `targets` is the caller's list.
static func pick_target(from: Vector3, facing: Vector3, targets: Array, max_range: float, cone_deg: float = 30.0, reaches: Callable = Callable()) -> Node3D:
	var f := facing
	f.y = 0.0
	if f.length() < 0.001:
		return null
	f = f.normalized()
	var cos_limit := cos(deg_to_rad(cone_deg))
	var cands: Array = []
	for e in targets:
		if e == null or not is_instance_valid(e) or not (e is Node3D):
			continue
		if e.get("dead"):
			continue
		var to: Vector3 = (e as Node3D).global_position - from
		to.y = 0.0
		var d := to.length()
		if d < 0.01 or d > max_range:
			continue
		if f.dot(to / d) < cos_limit:
			continue
		cands.append([d, e])
	if cands.is_empty():
		return null
	cands.sort_custom(func(a, b) -> bool: return float(a[0]) < float(b[0]))
	if reaches.is_valid():
		for c in cands:
			if reaches.call(c[1]):
				return c[1]
	return cands[0][1]


## Where auto-aimed shots point: the CENTRE OF THE TARGET'S BODY — the body its collider was built
## from (GBody.of), so the aim and the hit read the same thing. "+1.0 m above the feet" was a chest
## for a person and 0.5 m over the back of anything drawn 0.5 m tall. Origin +1.0 m is kept only for
## a target with no body.
## IN THE WORLD: a GBody reads in its owner's PARENT frame (body.gd), and a shot flies in the world's.
## Every owner so far stands under a root at the origin, where the two agree; under a parent that is
## moved or turned they do not (people rig: the owner walk under a moved, turned root), so the centre
## goes through that parent's transform.
static func aim_point(target: Node3D) -> Vector3:
	var b := GBody.of(target)
	if b != null:
		var par: Node3D = (b.owner.get_parent() as Node3D) if b.owner != null else null
		return par.global_transform * b.centre() if par != null and par.is_inside_tree() else b.centre()
	return target.global_position + CHEST


## LEAD. The chest sphere (0.9 m round a point) hid that nothing ever aimed where a moving target would
## BE: a foe strafing at 2.5 m/s moves 0.8-2.3 m during a 0.3-0.9 s flight, and the sphere forgave most
## of it. A shot tested against the body itself does not (people rig: 4 of 6 strafing-enemy shots hit
## with the sphere, 1 of 6 body-exact with no lead), so the aim leads: the body centre advanced by the
## target's `velocity` over the time the shot takes to reach it — twice, since that time depends on
## where it will be. A target with no `velocity` (a hand-placed dummy) is aimed at where it is.
static func lead_point(target: Node3D, muzzle: Vector3, def: Dictionary) -> Vector3:
	var p := aim_point(target)
	var v = target.get("velocity")
	var spd := _speed_of(def)
	if not (v is Vector3) or (v as Vector3).length_squared() < 1e-6 or spd < 0.05:
		return p
	var q := p
	for i in 2:
		q = p + (v as Vector3) * (muzzle.distance_to(q) / spd)
	return q


## THE WORLD BODIES A SHOT STARTS INSIDE (layer 1 only — never a person). hit_from_inside makes a ray
## report the body it starts in, which is what meets a target that moved onto the shot (see _launch) — and
## also what killed every shot fired from inside a world body that holds the shooter's hand. When a seat was
## one box over its bounds, a seat placed with `scale` held its own sitter's hand (harbour_bench from 1.25x,
## chapel_pew and office_chair_wooden from 1.5x: 22 of 80 seat x scale x hero shots died at the hand). A
## seat's body is now a few boxes a line of fire passes to meet the seat as drawn (sight), and the seat the
## shooter sits in is left out by name (main._fire_ranged), but a prop beside it still can: Kestrel Bay
## placed one harbour_bench twice on one spot, the second turned 180 deg, and at 1.25x and 1.5x the second
## one's box holds the hand of a hero seated on the first, 2-15 cm deep — without this all 12 of the people
## rig's (k6) shots die at the hand. What the shooter is inside is never what they shoot at, whatever it is.
static func contained(space: PhysicsDirectSpaceState3D, at: Vector3) -> Array[RID]:
	var out: Array[RID] = []
	if space == null or at == Vector3.INF:
		return out
	if _point_q == null:
		_point_q = PhysicsPointQueryParameters3D.new()
		_point_q.collision_mask = 1
	_point_q.position = at
	for d in space.intersect_point(_point_q, 8):
		out.append(d["rid"])
	return out


## THE HAND STOPS AT THE WALL: `muzzle`, pulled back to MUZZLE_BACK short of the first world surface on the
## path from the shooter's `barrel` to it, when one lies between. The muzzle is a hand's width to the side
## (0.36-0.57 m on the hero rigs, people rig 13b), so walking along a wall, a crate or a door jamb on the
## weapon side puts it inside or past that wall. A shot that leaves from inside a wall leaves that wall out
## (contained: it is what the shot starts in) and goes THROUGH it — an enemy in the next room, behind the wall
## the hand was in, was hit by all three heroes' shots; one that leaves from past a rail never meets the rail;
## and a hand on a crate's face died there (people rig). From the wall's face the flight decides what it
## meets: down the corridor, nothing; into the wall, its near face — a rail, the wall beside you, a plank
## pressed face-first are not shot through. Only the world (layer 1) stops the hand: a person pressed against
## the weapon side is still met, the muzzle inside them (the flight's first ray reports the body it starts
## in). What holds the shooter is no wall to them: `exclude`, the seat they sit in and the hull they ride
## with everything under them (main._fire_ranged), as the flight leaves them out. When a seat was one box
## round its bounds, the barrel was inside it and this ray, which does not report what it starts in, needed
## no list; leaving the seats and hulls out moved no hand of 244 shooters (160 seated at 1-2x, 84 riding all
## seven vehicle profiles; people rig (k7), 2026-10-02). A seat is now a few boxes this passes (sight) and
## the triangles it draws (GShapes.add_seat_collider), and a seated hand can be past its own seat's wood: a
## 1.25x bar_stool seats its sitter inside its disc, and every hero's hand came back 0.49-0.57 m (people rig).
static func clear_muzzle(space: PhysicsDirectSpaceState3D, barrel: Vector3, muzzle: Vector3, exclude: Array[RID] = []) -> Vector3:
	if space == null or barrel == Vector3.INF or barrel.distance_squared_to(muzzle) < 1e-6:
		return muzzle
	var q := PhysicsRayQueryParameters3D.create(barrel, muzzle, 1 | GShapes.SIGHT_LAYER)
	q.exclude = exclude
	var hit := sight(space, q)
	if hit.is_empty():
		return muzzle
	return (hit["position"] as Vector3) + (barrel - muzzle).normalized() * MUZZLE_BACK


## A LINE OF FIRE'S RAY: space.intersect_ray(q), but a seat's body is no wall to it — the boxes the
## player, the crowd and the cars bump into (GShapes.add_seat_collider), each a block or a part's bounds,
## with air in them. It goes on through them (each one met is left out of `q` and the ray cast again,
## once per seat it crosses) and meets what the seat draws: its sight, every triangle on
## GShapes.SIGHT_LAYER, which `q`'s mask must name (HIT_MASK does). The flight, the muzzle clamp, the
## throw's roof, main's aim along the facing and auto-aim's reach all ask it, so the shot that flies is
## the one that was aimed: a sitter is hit wherever nothing is drawn between, and shielded by the wood.
static func sight(space: PhysicsDirectSpaceState3D, q: PhysicsRayQueryParameters3D) -> Dictionary:
	var hit := space.intersect_ray(q)
	while not hit.is_empty() and GShapes.is_seat_body(hit.get("collider")):
		var ex := q.exclude
		ex.append(hit["rid"])
		q.exclude = ex
		hit = space.intersect_ray(q)
	return hit


## The RIDs a shot must not meet: each CollisionObject3D given AND every one under it (a mount whose
## hull is split into child bodies is still the rider's own mount), or a bare RID.
static func rids(exclude: Array) -> Array[RID]:
	var out: Array[RID] = []
	for x in exclude:
		if x is RID:
			out.append(x)
			continue
		if not (x is Node) or not is_instance_valid(x):
			continue
		if x is CollisionObject3D:
			out.append((x as CollisionObject3D).get_rid())
		for c in (x as Node).find_children("*", "CollisionObject3D", true, false):
			out.append((c as CollisionObject3D).get_rid())
	return out


## Muzzle flash at `at`: a brief emissive billboard quad + an OmniLight pulse (0.08 s), pooled
## (one node, restarted per shot). fire()/fire_at() call this automatically at the fire origin.
## Build every lazily-created combat node ONCE, at world start, instead of mid-fight.
##
## The pool projectile, the muzzle flash and the impact puffs were each created ON FIRST USE — inside
## the frame that fired, or the frame that connected. On the web build that means mesh creation,
## material creation and first-draw pipeline compilation land on the exact frame a player first shoots
## somebody, which is the worst possible moment and reads as the game stuttering the instant combat
## starts.
##
## The puffs are the worst of the three and explain the shape of the complaint: the ring grows to
## FOUR, one per impact, so the hitch repeats on the first four hits and then never again — which
## feels like the game "warming up" rather than like a bug.
##
## Everything is placed at `at`, drawn for the frames it takes to become real, then hidden. Doing it
## at spawn costs a blip nobody is looking at, instead of a stutter at the moment they are.
static func prewarm(world_root: Node3D, at: Vector3) -> void:
	if world_root == null or not is_instance_valid(world_root) or not world_root.is_inside_tree():
		return
	flash(at, world_root)
	var p := _acquire(world_root)
	if p != null:
		p.global_position = at
		p.visible = true
		# The puff ring is static and shared, so filling it from one projectile warms it for all.
		for i in range(4):
			p._puff(at)
		p._deactivate()
	print("GOGI_COMBAT_WARM pool=", _pool.size(), " puffs=", _puffs.size(),
		" flash=", _flash_node != null)


static func flash(at: Vector3, parent: Node3D) -> void:
	if parent == null or not is_instance_valid(parent) or not parent.is_inside_tree():
		return
	if _flash_node == null or not is_instance_valid(_flash_node):
		_flash_node = _make_flash()
		_flash_timer = _flash_node.get_node("FlashTimer") as Timer
	var par := _flash_node.get_parent()
	if par == null:
		parent.add_child(_flash_node)
	elif par != parent:
		par.remove_child(_flash_node)
		parent.add_child(_flash_node)
	_flash_node.global_position = at
	_flash_node.visible = true
	_flash_timer.start()


# ─────────────────────────────── flight ───────────────────────────────

func _init() -> void:
	name = "GProjectile"
	_ray = PhysicsRayQueryParameters3D.new()   # reused every tick — no per-frame allocation
	_ray.collision_mask = HIT_MASK             # every body a shot can meet (see HIT_MASK)
	if _mat_bolt == null:
		_mat_bolt = StandardMaterial3D.new()
		_mat_bolt.albedo_color = Color(1.0, 0.85, 0.4)
		_mat_bolt.emission_enabled = true
		_mat_bolt.emission = Color(1.0, 0.8, 0.35)
		_mat_bolt.emission_energy_multiplier = 2.5
		_mat_arrow = StandardMaterial3D.new()
		_mat_arrow.albedo_color = Color(0.5, 0.35, 0.2)
		_mat_arrow.emission_enabled = true
		_mat_arrow.emission = Color(0.9, 0.7, 0.4)
		_mat_arrow.emission_energy_multiplier = 0.6
	_bolt = MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.07
	sph.height = 0.14
	sph.radial_segments = 8
	sph.rings = 4
	_bolt.mesh = sph
	_bolt.material_override = _mat_bolt
	add_child(_bolt)
	_arrow = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.03, 0.03, 0.42)
	_arrow.mesh = bm
	_arrow.material_override = _mat_arrow
	add_child(_arrow)
	visible = false
	set_physics_process(false)


func _physics_process(delta: float) -> void:
	if not _active:
		return
	_life -= delta
	if _life <= 0.0:
		_deactivate()
		return
	if _arc:
		_vel.y -= GRAVITY * delta
	var from := global_position
	var to := from + _vel * delta
	# ONE RAY, EVERY BODY: the first thing along this tick's segment — a wall, an enemy, another player,
	# a person — is what the shot meets. The path begins at the muzzle, already pulled back out of any wall
	# between the shooter and it (clear_muzzle), and a person the muzzle is inside is met by the first ray
	# (it reports the body it starts in: _launch). It used to begin at the shooter's own axis: once the
	# muzzle stopped at the wall, that path met nothing the muzzle's does not except a body OVERLAPPING the
	# shooter (a peer's body passing through theirs, a seated neighbour's capsule round their arm), which
	# then took every shot whatever its direction — a villager 0.2 m behind took the arrow meant for an
	# enemy 8 m ahead (people rig: 293 of 1878 probe shots, each with a body inside the shooter's own).
	if is_inside_tree():
		_ray.from = from
		_ray.to = to
		var hit := sight(get_world_3d().direct_space_state, _ray)
		if not hit.is_empty():
			var at: Vector3 = hit["position"]
			if _on_hit.is_valid():
				_on_hit.call(hit["collider"], at, _dmg)   # the shooter decides what meeting it means
			_puff(at)
			_deactivate()
			return
	global_position = to
	_orient()


func _launch(from: Vector3, vel: Vector3, def: Dictionary, on_hit: Callable, exclude: Array, mask: int) -> void:
	global_position = from
	_vel = vel
	launch = vel
	_arc = _arc_of(def)
	_dmg = _damage_of(def)
	_life = LIFETIME
	_born = Time.get_ticks_msec()
	_on_hit = on_hit
	_ray.collision_mask = mask
	# A BODY THAT MOVES ONTO THE SHOT IS MET. Targets move by script, and the physics server holds each
	# one where it was a tick ago (people rig 13c: 29 of 30 probes, peer, crowd and enemy bodies alike):
	# a player strafing across the line at 6 m/s moved 0.1 m onto the arrow between two ticks, so the
	# arrow's next segment STARTED inside them, and a ray never reports the body it starts in — it flew
	# through the middle of them (0.02 m from their axis, no hit; 0 of 12 tick phases met them). The
	# shot deactivates at its first hit, so what else it could start inside is what it was fired from
	# inside: a person the muzzle is pressed into, who is met; the world body that holds the shooter's
	# hand (the seat they sit on), excluded below (contained); the rider's own mount, by the caller.
	# A PICTURE OF A SHOT DOES NOT: another player's tracer starts at THEIR muzzle, which on this client
	# can sit inside one of our own people (a crowd body and a peer body never push each other), and
	# reporting it would stop the tracer at its own muzzle. Being drawn one tick late through a body that
	# moved onto it is a picture's whole error.
	_ray.hit_from_inside = on_hit.is_valid()
	var ex := rids(exclude)
	ex.append_array(contained(get_world_3d().direct_space_state if is_inside_tree() else null, from))
	_ray.exclude = ex
	var ranged := String(def.get("kind", "")) == "ranged"
	_arrow.visible = ranged                    # elongated box = arrow-ish
	_bolt.visible = not ranged                 # emissive sphere = bolt / thrown
	visible = true
	_active = true
	set_physics_process(true)
	_orient()


func _deactivate() -> void:
	_active = false
	visible = false
	_on_hit = Callable()                       # drop the shooter ref so it can free cleanly
	set_physics_process(false)


func _orient() -> void:
	if _vel.length_squared() < 0.001:
		return
	var d := _vel.normalized()
	if absf(d.dot(Vector3.UP)) < 0.98 and is_inside_tree():
		look_at(global_position + _vel)


# ─────────────────────────────── pool / spawn ───────────────────────────────

static func _spawn(world_root: Node3D, from: Vector3, vel: Vector3, def: Dictionary, on_hit: Callable, exclude: Array, mask: int) -> GProjectile:
	var proj := _acquire(world_root)
	proj._launch(from, vel, def, on_hit, exclude, mask)
	flash(from, world_root)
	return proj


# Reuse an idle pool node; grow to MAX_LIVE; else recycle the OLDEST live one. Freed entries
# (scene reload took the parent with them) are purged; nodes reparent to the given root.
static func _acquire(world_root: Node3D) -> GProjectile:
	for i in range(_pool.size() - 1, -1, -1):
		if not is_instance_valid(_pool[i]):
			_pool.remove_at(i)
	var proj: GProjectile = null
	for p in _pool:
		if not (p as GProjectile)._active:
			proj = p as GProjectile
			break
	if proj == null and _pool.size() < MAX_LIVE:
		proj = GProjectile.new()
		_pool.append(proj)
	if proj == null:
		var oldest := -1
		for p in _pool:
			var gp := p as GProjectile
			if oldest == -1 or gp._born < oldest:
				oldest = gp._born
				proj = gp
	var par := proj.get_parent()
	if par == null:
		world_root.add_child(proj)
	elif par != world_root:
		par.remove_child(proj)
		world_root.add_child(proj)
	return proj


# ─────────────────────────────── impact puff + flash ───────────────────────────────

# One-shot dust puff at an impact, from a pooled ring (never freed — reused round-robin).
func _puff(at: Vector3) -> void:
	var parent := get_parent()
	if parent == null or not parent.is_inside_tree():
		return
	for i in range(_puffs.size() - 1, -1, -1):
		if not is_instance_valid(_puffs[i]):
			_puffs.remove_at(i)
	if _puffs.size() < 4:
		_puffs.append(_make_puff())
	_puff_i = (_puff_i + 1) % _puffs.size()
	var p := _puffs[_puff_i] as CPUParticles3D
	var par := p.get_parent()
	if par == null:
		parent.add_child(p)
	elif par != parent:
		par.remove_child(p)
		parent.add_child(p)
	p.global_position = at
	p.restart()


static func _make_puff() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.name = "GProjectilePuff"
	p.amount = 12
	p.lifetime = 0.35
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = false
	p.direction = Vector3(0.0, 1.0, 0.0)
	p.spread = 80.0
	p.gravity = Vector3(0.0, 1.2, 0.0)
	p.initial_velocity_min = 1.2
	p.initial_velocity_max = 2.4
	p.damping_min = 2.0
	p.damping_max = 3.0
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	var q := QuadMesh.new()
	q.size = Vector2(0.14, 0.14)
	p.mesh = q
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.78, 0.72, 0.62, 0.9)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	p.material_override = m
	return p


static func _make_flash() -> Node3D:
	var root := Node3D.new()
	root.name = "GProjectileFlash"
	var quad := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.34, 0.34)
	quad.mesh = q
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.9, 0.6, 0.9)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.emission_enabled = true
	m.emission = Color(1.0, 0.85, 0.5)
	m.emission_energy_multiplier = 3.0
	quad.material_override = m
	root.add_child(quad)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.85, 0.55)
	light.light_energy = 3.0
	light.omni_range = 4.5
	light.shadow_enabled = false
	light.light_specular = 0.3
	root.add_child(light)
	var timer := Timer.new()
	timer.name = "FlashTimer"
	timer.wait_time = FLASH_TIME
	timer.one_shot = true
	timer.timeout.connect(func() -> void:
		if _flash_node != null and is_instance_valid(_flash_node):
			_flash_node.visible = false)
	root.add_child(timer)
	root.visible = false
	return root


# ─────────────────────────────── helpers ───────────────────────────────

## THE ARC STAYS UNDER THE ROOF: the launch's upward speed `vy`, cut to what the room over `from` allows.
## Drop compensation lobs a throw — an axe aimed 19 m out peaks 1.6 m over the hand, a range-30 spear at
## 28 m 3.5 m (people rig) — against a storey's 2.95 m ceiling (2.35 m at MIN_STOREY), where a throw that
## was never compensated never rose at all. One ray straight up from the hand at fire time finds the first
## surface overhead; the arc is cut to peak ARC_CLEAR under it (it falls short of the mark rather than into
## the ceiling), and with no room at all the throw goes flat at the mark (`flat_vy`), as it always did.
static func _arc_vy(space: PhysicsDirectSpaceState3D, from: Vector3, flat_vy: float, vy: float, exclude: Array) -> float:
	if vy <= 0.0 or space == null:
		return vy
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.UP * (vy * vy / (2.0 * GRAVITY) + ARC_CLEAR), 1 | GShapes.SIGHT_LAYER)
	q.exclude = rids(exclude)
	var hit := sight(space, q)
	if hit.is_empty():
		return vy
	var room := (hit["position"] as Vector3).y - from.y - ARC_CLEAR
	if room <= 0.0:
		return flat_vy
	return clampf(sqrt(2.0 * GRAVITY * room), flat_vy, vy)


static func _damage_of(def: Dictionary) -> float:
	return float(def.get("damage", DEF_DAMAGE))


static func _speed_of(def: Dictionary) -> float:
	var p = def.get("projectile", null)
	if p is Dictionary and (p as Dictionary).has("speed"):
		return float(p["speed"])
	return float(def.get("speed", DEF_SPEED))


static func _arc_of(def: Dictionary) -> bool:
	var p = def.get("projectile", null)
	if p is Dictionary and (p as Dictionary).has("arc"):
		return bool(p["arc"])
	return String(def.get("kind", "")) == "thrown"
