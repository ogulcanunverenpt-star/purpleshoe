class_name GBody extends RefCounted
## THE BODY A THING STANDS IN — one footprint and height band in its owner's frame, read by everything
## that asks where a person or a creature ends: personal space, the turn guard, the probe and wall rays,
## the hostile reach, the push direction, and main / chunk_manager when the player walks into or strikes
## it. Every one of them used to assume a round body at the origin, so a horse held the player off its
## MIDDLE and dragged them with its head (people rig).
##
## MOVED HERE, NOT COPIED. These are the formulas WanderAgent kept for the crowd (set_body, body_point,
## _body_gap, reach_to, _body_reach and the geometry inside _clear_of_player and _face_heading) and
## chunk_manager._crowd_body's shape rule. Locked inside WanderAgent, nothing else could read them — not
## an enemy, a mount, a peer or a projectile — so each kept a body model of its own: a constant 0.4 x
## 1.5 m capsule at an enemy's origin, a mount's bind-pose box. The people rig holds this file to the old
## code bit for bit (section 12 (n): a frozen copy of it, 500 random bodies, every answer).
##
## THE SHAPE. NONE (walk-through: drawn under SOLID_MIN_DIM, or the author opted out), ROUND (a capsule:
## a person) or BOX (the box a creature draws). A footprint centre `c` and half extents `half` or a radius
## `r`, owner-local XZ, over a height band y0..y1 from the owner's feet. A BOX may be cut into z-slice
## `parts` when one box over a whole creature holds too much air; an empty `parts` is ONE box (N = 1),
## which is the crowd's.
##
## THE OWNER'S TRANSFORM IS APPLIED ON READ — its position, its yaw and GCast.vary's scale, on every query,
## both ways: the footprint is the body the physics has (a 0.94-scaled raptor's is 6% smaller, a 1.1
## horse's 10% bigger). Only personal space's gap() keeps a round body's radius at its unscaled floor — a
## policy, not the body: the 3D queries read the capsule the physics scales. It is read in the owner's
## parent frame, as WanderAgent read itself — for every owner so far a cell root at the origin.
##
## collider() builds the physics from the same numbers, so the collider and the math cannot disagree, and
## stamps the owner on it (meta gbody_owner): GBody.of() is how whatever the physics hands back finds the
## body, and whoever answers for it.
##
## ONE GBody PER OWNER. A GBody carries its owner (every query reads that one transform), so an instance
## shared by two — a per-model cache, say — answers both from whichever owned_by it last: build one each
## (the fit is what is memoised, per model, in GPose; building a body from it is cheap).

enum { NONE, ROUND, BOX }

# THE CROWD'S PERSON: the body a crowd member stands in when nothing could be measured, and the unit
# every reach is tuned in (a person's CENTRE distance — see reach). Human-ish and deliberately SLIMMER
# than the authored NPC's 0.5/1.8 capsule, so a knot of people in a doorway still lets the player through.
const CROWD_RADIUS := 0.34
const CROWD_HEIGHT := 1.7
const CROWD_MIN_H := 0.3       # a creature's box is never lower than this: the player meets it as a wall, not a step
# The shared SOLID contract (chunk_manager / area_builder SOLID_MIN_DIM, world-streaming.md §8), pinned
# here as every other placement writer pins it: anything drawn smaller than this is walk-through.
const SOLID_MIN_DIM := 0.45
const ENEMY_R := 0.45          # an enemy PERSON's capsule radius, at most (the enemy roles' r_cap)
const ENEMY_SLICES := 5        # the boxes an enemy creature's body is cut into, nose to tail
# THE SIZE AN ENEMY IS DRAWN AT, unless its height is given (normalise): never taller than ENEMY_MAX_H — a giant must not
# fill the frame at melee range (gamefeel P1) — nor longer than ENEMY_MAX_L across its footprint (a library rat drew
# 6.81 m long and a manta 11.7 under the old height-only cap), and never smaller than ENEMY_MIN across: a real wasp is
# 3 cm and a real spider 25, a speck nobody could see, aim at or hit.
const ENEMY_MAX_H := 3.0
const ENEMY_MAX_L := 4.5
const ENEMY_MIN := 0.6
# A PERSON'S OWN HEIGHT, kept when it is a person's (the user, 2026-10-04: "keep each person's own height when it's in a
# normal human range (about 1.5-1.95 m), and only bring clearly wrong ones, like the Kenney figures, into that range"):
# measured as the hero path measures (GPose.char_height), and outside it scaled to the hero's GRig.PERSON_H.
const PERSON_BAND := Vector2(1.50, 1.95)

## THE ROLE POLICY: what a role's body is fitted over (fit: the clips, phases per clip, and whether a person's
## clips are sampled at all) and the numbers its shape rule is built from (from_extent). One table, so the
## parse-time warm (AreaBuilder._prewarm_fit) and the spawner ask GPose for the same fit, and the memo the
## warm fills is the one the spawner reads.
##   crowd      the clips a crowd member plays (WanderAgent.fit_clips), a person's rest pose only — and, a person's, how each
##              of those clips draws its soles ("ground": GPose.ground_rise, step 5d).
##   mount      a RIDDEN body (Vehicle, 2026-10-04): the gaits it plays on the ground (GClip.gait_clips) at 12
##              phases a clip, a person's too: a mount on a humanoid rig is all gait — monster_Skeleton's run stood
##              2.26 m out of a hull fitted to its rest pose, which is the crowd's rule for a person (review). 12, not
##              the crowd's 8: 8 phases fall between the beats of the default dragon's wingbeat and miss 0.18 m of
##              its span a side; 12 agree with 24 and 96 within 4 mm at 57% of 24's cost (dragon 11.6 vs 19.3 ms).
##              Its setup also reads what it draws at rest vertex by vertex (its keel), so this fit takes those
##              points too ("points"): skinned where the mount was set up they were 1.5-2.6 ms of a library default's
##              2.1-3.9 ms setup (2026-10-04). Its box is skinned DENSE (the slices' sample: GPose.fit_job): its hull is
##              that box and nothing more since the ride's rock left every mount that moves on its own legs (F1, step
##              5b), and the crowd's 600 vertices a surface left the stegosaurus's own gait 0.053 m past it. And what it
##              draws without its legs in each of those poses ("keel": GPose.fit_job): what it rests on while its feet stand
##              on the ground (GFeet), read in the same pass (step 5c).
##   mount_air  a FLYER's body in the air: the same, over its flap and glide — the clips it never plays on the
##              ground, which held 0.44 m of width and 0.78 m of height in the default dragon's walking box.
##   enemy      an ENEMY's body while it MOVES (enemy.gd, 2026-10-05): a person in the crowd's capsule, its radius never
##              over ENEMY_R — the crowd's depth rule gave the default skeleton 0.73 m, and six parked round the player
##              held them still in 8 of 96 escape runs (0 of 96 capped; enemy-bodies review) —, anything else in
##              ENEMY_SLICES boxes cut nose to tail (GPose.body_fit's slices) over the poses it holds while it moves: its
##              idle and its gaits (idle, walk, run, swim, fly) at 12 phases a clip (8 fall between a wingbeat's beats:
##              the bat's 0.17 m of wing outside the box) — its flight ("fast") at 24: a wingbeat's keys fell between 12
##              too, and the bat's wing reached 0.076 m past its body at 5/8 of its beat (the enemy rig) —, NEVER its attack. Fitted over the attack, a frog's lunge
##              stood as a 2.13 m invisible wall and it bit from 3 m of air; one box round every clip left a median 38%
##              of the hits on 71 models in the air, five bands 16-22% (review). The attack is read on its own: how far
##              it reaches past the body and when it lands (the fit's strike) — the bite's, not the wall's. An enemy is
##              never walk-through ("solid"): one too small to meet was one nobody could hit. A person's clips stand where its
##              rest stands ("ground", as the crowd's).
##              The fit's bands keep each clip's poses apart on one grid, so enemy.gd cuts the body of each state from
##              the clips it shows in it (_shown) — PARKED, its idle's poses alone: a gait's sweep held in a body that
##              stands still is a wall in front of what it draws (the horse's gallop put its front hooves 1.17 m ahead of
##              its idle nose; review).
##   npc_seated a SEATED named NPC (interaction._seated_body, 2026-10-05): the boxes GPose.posed_fit cuts from what it
##              draws sitting — each as tall as what it holds (a foot's box is a foot high, not CROWD_MIN_H), and none
##              walk-through: a shin is small and still somebody.
## The Vehicle builds its hull from the mount fits itself (the ride's rock sweeps it for a mount with no move clip of its
## own, F1; GBody.box names it).
const ROLES := {
	"crowd": {"radius": CROWD_RADIUS, "height": CROWD_HEIGHT, "min_h": CROWD_MIN_H,
		"phases": GPose.FIT_POSES, "pose_persons": false, "ground": true},
	"mount": {"phases": 12, "pose_persons": true, "gaits": "ground", "points": true, "dense": true, "keel": true},
	"mount_air": {"phases": 12, "pose_persons": true, "gaits": "air", "dense": true},
	"enemy": {"radius": CROWD_RADIUS, "height": CROWD_HEIGHT, "min_h": CROWD_MIN_H, "r_cap": ENEMY_R, "solid": true,
		"below": true, "phases": 12, "pose_persons": false, "slices": ENEMY_SLICES,
		"clips": ["idle", "walk", "run", "swim", "fly"], "fast": ["fly"], "strike": "attack", "ground": true},
	"npc_seated": {"radius": CROWD_RADIUS, "height": CROWD_HEIGHT, "min_h": 0.05, "solid": true},
}
## THE NATURAL SIZE OF EVERY LIBRARY CREATURE, and of every library humanoid that is not a human — a real adult, or for
## a fantasy one a size its kind is told at — by its path on the asset origin (natural_of). D11 (2026-09-30): used for
## an enemy (under ENEMY_MAX_H / ENEMY_MAX_L / ENEMY_MIN) and a herd or a named creature alike, unless the build sizes it
## (enemy_height, a boss's height; a populate entry's or a named NPC's max_size / target_size / scale). A library GLB
## is drawn at any scale (the fox 155 m nose to tail, the T-rex 31, a mire dragon 1.0), and every role sized it its
## own way: a 0.96 m T-rex as an enemy, a 2 m fox in a herd, a 6.92 m horse as a named NPC.
## THE DATUM each row names, on the drawn rest box (GPose.body_fit's rest): "h" its height, the top of the head, ears or
## horns (a horse 2.3 m — 1.6 at the withers; a sheep 1.0); "l" nose to tail along +Z, the tail as drawn (a fox 1.05:
## 0.65 of body and 0.4 of tail); "w" its span across (a manta's wings, a spider's legs). Whichever the model draws
## plainly: a coiled snake has no length to read, so it is the height it rears to; a bat's rest holds its wings up, so it
## is the height that spans 1.5 m in flight. Held to the manifests by the enemy rig's census (every library creature and
## every library humanoid named here or a human), and to the size each comes out at, within 1%.
const NATURAL := {
	"godot-assets/animals/dinosaur_Apatosaurus": {"l": 22.0},
	"godot-assets/animals/dinosaur_Parasaurolophus": {"l": 9.5},
	"godot-assets/animals/dinosaur_Stegosaurus": {"l": 9.0},
	"godot-assets/animals/dinosaur_Trex": {"l": 12.3},
	"godot-assets/animals/dinosaur_Triceratops": {"l": 8.5},
	"godot-assets/animals/dinosaur_Velociraptor": {"l": 2.0},
	"godot-assets/animals/easy_Frog": {"l": 0.2},
	"godot-assets/animals/easy_Rat": {"l": 0.4},
	"godot-assets/animals/easy_Snake": {"h": 0.6},
	"godot-assets/animals/easy_Snake_angry": {"h": 0.6},
	"godot-assets/animals/easy_Spider": {"w": 0.25},
	"godot-assets/animals/easy_Wasp": {"l": 0.03},
	"godot-assets/animals/farm_Cow": {"h": 1.7},
	"godot-assets/animals/farm_Horse": {"h": 2.3},
	"godot-assets/animals/farm_Llama": {"h": 1.8},
	"godot-assets/animals/farm_Pig": {"l": 1.7},
	"godot-assets/animals/farm_Pug": {"h": 0.35},
	"godot-assets/animals/farm_Sheep": {"h": 1.0},
	"godot-assets/animals/farm_Zebra": {"h": 2.0},
	"godot-assets/animals/fish_Dolphin": {"l": 2.5},
	"godot-assets/animals/fish_Fish1": {"l": 0.6},
	"godot-assets/animals/fish_Fish2": {"l": 0.4},
	"godot-assets/animals/fish_Fish3": {"l": 0.3},
	"godot-assets/animals/fish_Manta_ray": {"w": 5.0},
	"godot-assets/animals/fish_Shark": {"l": 4.0},
	"godot-assets/animals/fish_Whale": {"l": 14.0},
	"godot-assets/animals/fox": {"l": 1.05},
	"godot-assets/animals/monster_Bat": {"h": 1.44},
	"godot-assets/animals/monster_Dragon": {"l": 6.0},
	"godot-assets/animals/monster_Skeleton": {"h": 2.0},
	"godot-assets/animals/monster_Slime": {"h": 1.0},
	"godot-assets/enemies/q_dino_apatosaurus": {"l": 22.0},
	"godot-assets/enemies/q_dino_parasaurolophus": {"l": 9.5},
	"godot-assets/enemies/q_dino_stegosaurus": {"l": 9.0},
	"godot-assets/enemies/q_dino_trex": {"l": 12.3},
	"godot-assets/enemies/q_dino_triceratops": {"l": 8.5},
	"godot-assets/enemies/q_dino_velociraptor": {"l": 2.0},
	"godot-assets/enemies/q_enemy_frog": {"l": 0.2},
	"godot-assets/enemies/q_enemy_rat": {"l": 0.4},
	"godot-assets/enemies/q_enemy_snake": {"h": 0.6},
	"godot-assets/enemies/q_enemy_snake_angry": {"h": 0.6},
	"godot-assets/enemies/q_enemy_spider": {"w": 0.25},
	"godot-assets/enemies/q_enemy_wasp": {"l": 0.03},
	"godot-assets/enemies/q_monster_bat": {"h": 1.44},
	"godot-assets/enemies/q_monster_dragon": {"l": 6.0},
	"godot-assets/enemies/q_monster_skeleton": {"h": 2.0},
	"godot-assets/enemies/q_monster_slime": {"h": 1.0},
	"godot-assets/realistic_characters/alien": {"h": 1.8},
	"meshy-library/other-swamp/enemies/mire_dragon": {"l": 5.0},
	"meshy-library/other-swamp/enemies/hydra_dragon": {"l": 5.0},
	"meshy-library/other-swamp/enemies/bog_lurker": {"h": 2.2},
	"meshy-library/other-swamp/enemies/murk_reaver": {"h": 2.5},
	"meshy-library/other-swamp/enemies/pike_pirate": {"h": 1.9},
	"meshy-library/other-swamp/enemies/rat_bandit": {"h": 1.6},
	"meshy-library/fantasy-medieval/enemies/storm_troll": {"h": 2.8},
	"meshy-library/rural/characters/heron_villager": {"h": 1.9},
	"meshy-library/rural/characters/heron_elder": {"h": 1.85},
	"meshy-library/rural/characters/heron_fisher": {"h": 1.9},
}

var kind := NONE
var c := Vector2.ZERO          # footprint centre, owner-local XZ
var half := Vector2.ZERO       # BOX half extents (x, z), owner-local
var r := CROWD_RADIUS          # ROUND radius
var y0 := 0.0                  # the height band, up from the owner's feet
var y1 := CROWD_HEIGHT
var parts: Array[GBody] = []   # a BOX cut into z-slices (one-box GBodies in the same frame); empty = one box
var owner: Node3D = null       # whose transform every query reads, and whom collider() names
# THE LEAN IT IS DRAWN WITH (set_lean): a creature on a slope (lean_on), owner-local, about its origin — the body leans with it
var lean := Transform3D.IDENTITY
var _leaned := false           # ...it is not upright (lean is not IDENTITY): what every query asks first
var _bounds: GBody = null      # ...and the upright boxes round its leaned boxes (leaned_bounds), built for the lean _bounds_at
var _bounds_at := Transform3D.IDENTITY
var _bounds_ok := false
var _cols: Array = []          # the colliders collider() built from it (weak): they lean with it
var _far := -1.0               # its farthest corner from the origin (_tilt_moved; -1: not yet read)
# ITS BOXES WHERE ITS OWNER STANDS (_prisms), kept while the owner has not moved: gap_to, dist3 and nearest3 laid a sliced
# body out again on every call — a parked T-rex measured a still player at 12 us a call, every tick (step 4's review). The
# numbers above are set when a body is built and never after, so the owner's transform is all that can make them stale.
var _pc: Array = []
var _pc_at := Vector3.INF
var _pc_yaw := NAN
var _pc_s := NAN
static var gap_calls := 0      # gap_to calls, ever, and the times a body was laid out where its owner stands (_prisms):
static var prism_builds := 0   # the enemy rig counts what a parked tick measures
# NONE still MEASURES like the default person (a round CROWD_RADIUS on the origin), as WanderAgent's walk-
# through bodies always did: a swing at a horse with collider:false lands on its middle (assault_crowd),
# and only personal space and the turn guard ask whether there is anything to meet.


## A round body: a capsule of `radius`, `height` tall, standing on the owner's origin.
static func round(radius: float, height: float) -> GBody:
	var b := GBody.new()
	b.kind = ROUND
	b.r = radius
	b.y1 = maxf(height, radius * 2.0)
	return b


## A box body: `size`, centred on the owner-local point `at` — a hull the owner already built from those
## numbers (Vehicle: its BoxShape3D), named so whatever the physics hands back finds who answers for it.
static func box(at: Vector3, size: Vector3) -> GBody:
	var b := GBody.new()
	b.kind = BOX
	b.c = Vector2(at.x, at.z)
	b.half = Vector2(size.x, size.z) * 0.5
	b.y0 = at.y - size.y * 0.5
	b.y1 = at.y + size.y * 0.5
	return b


## THE BODY GPose.body_fit MEASURED, under `role`'s policy: a person in a capsule sized from their rest
## pose, anything else in the box it draws over every clip it plays (fit.aabb) — or, cut into slices (an
## enemy's fit), in the boxes those draw (from_slices). `xf` places the model in its owner (populate: the
## model's own transform inside the wrap). `cap` overrides the role's capsule cap (a boss's). A fit that
## measured nothing is the role's calibrated person.
static func from_fit(fit: Dictionary, role: String, xf := Transform3D.IDENTITY, cap := -1.0) -> GBody:
	if not bool(fit.get("ok", false)):
		return from_extent(true, AABB(), role, cap)
	var person := bool(fit["person"])
	if not person and fit.has("slices"):
		return from_slices(fit["slices"], role, xf)
	return from_extent(person, xf * (fit["rest" if person else "aabb"] as AABB), role, cap)


## A BOX cut into the z-slices `slices` (GPose.body_fit's or posed_fit's, owner-local through `xf`): one box each by the
## role's rule (from_extent), the union as the body's own box — what at_reach and the rays read the whole by. Empty bands
## are left out; nothing measured is the role's calibrated person.
static func from_slices(slices: Array, role: String, xf := Transform3D.IDENTITY) -> GBody:
	var b := GBody.new()
	var lo := Vector3.INF
	var hi := -Vector3.INF
	for sl: AABB in slices:
		if sl.size == Vector3.ZERO and sl.position == Vector3.ZERO:
			continue
		var q := from_extent(false, xf * sl, role)
		if q.kind != BOX:
			continue
		b.parts.append(q)
		lo = lo.min(Vector3(q.c.x - q.half.x, q.y0, q.c.y - q.half.y))
		hi = hi.max(Vector3(q.c.x + q.half.x, q.y1, q.c.y + q.half.y))
	if b.parts.is_empty():
		return from_extent(true, AABB(), role)
	b.kind = BOX
	b.c = Vector2((lo.x + hi.x) * 0.5, (lo.z + hi.z) * 0.5)
	b.half = Vector2(hi.x - lo.x, hi.z - lo.z) * 0.5
	b.y0 = lo.y
	b.y1 = hi.y
	if b.parts.size() == 1:
		b.parts.clear()   # one band is one box: the crowd's shape (N = 1)
	return b


## THE SHAPE RULE, on a measured extent `ext` (owner-local; AABB() = nothing measured: the calibrated person).
##   A PERSON gets a capsule centred on them: the role's radius, or 0.2 x their height for someone small
##   (a 1 m child is not 0.68 m wide), or half their rest DEPTH when that is more — the T-pose makes a
##   person's width a lie, their depth is not: a 1.35 m-deep troll stood in 0.34, and the player walked
##   0.26 m into it (people rig). As tall as their rest pose.
##   ANYTHING ELSE gets the box it draws: nose to tail, hoof to ear, flank to flank, from the ground up,
##   and never lower than the role's min_h — a 0.08 m serpent is a low wall, not a step to climb.
##   Anything measured under SOLID_MIN_DIM gets NO body: the shared SOLID contract every other object
##   follows, applied to what it draws (a rat or a chick is walk-through, like a pebble). Person or not:
##   an upright chick passes the person test (pelvis under head) and stood in a 0.2 m capsule.
##   AN ENEMY'S differs three ways (its roles): it is never walk-through ("solid": something nobody can meet
##   is something nobody can hit), a person's radius stops at its cap ("r_cap", or `cap`: a boss's), and what
##   it draws below its origin is body ("below"): a fish's origin is its middle, and its belly was cut off.
static func from_extent(person: bool, ext: AABB, role: String, cap := -1.0) -> GBody:
	var pol: Dictionary = ROLES[role]
	var b := GBody.new()
	var measured := ext.size != Vector3.ZERO
	if measured and maxf(ext.size.x, maxf(ext.size.y, ext.size.z)) < SOLID_MIN_DIM and not bool(pol.get("solid", false)):
		return b
	if person or not measured:
		var h: float = ext.size.y if measured else float(pol["height"])
		b.kind = ROUND
		# The radius AS THE PHYSICS HOLDS IT. A CapsuleShape3D keeps 32 bits, and this rule — and every
		# query after it — read the radius back off the shape when the rule built the shape itself.
		b.r = _f32(minf(pol["radius"], h * (float(pol["radius"]) / float(pol["height"]))))
		var cz := 0.0
		if measured and ext.size.z * 0.5 > b.r:
			b.r = ext.size.z * 0.5
			cz = ext.get_center().z      # sized by their depth, it spans it (kk_Knight: 0.54 behind, 0.77 ahead)
		var rcap := cap if cap >= 0.0 else float(pol.get("r_cap", INF))
		if b.r > rcap:
			b.r = _f32(rcap)   # an enemy's (`cap`: a boss's own): still centred on its depth, never wider than the cap
		b.c = Vector2(0.0, cz)
		b.y1 = maxf(h, b.r * 2.0)
		return b
	b.kind = BOX
	b.y0 = ext.position.y if bool(pol.get("below", false)) else maxf(ext.position.y, 0.0)   # a pose that dips below the feet is not body the player can meet
	b.y1 = maxf(ext.end.y, b.y0 + float(pol["min_h"]))
	b.half = Vector2(maxf(ext.size.x, 0.1), maxf(ext.size.z, 0.1)) * 0.5
	var cc := ext.get_center()
	b.c = Vector2(cc.x, cc.z)
	return b


## THE FIT `role`'s body is built from: the one call the parse-time warm (AreaBuilder._prewarm_fit) and the
## spawner both make, so the warm's memo entry is the one the spawner reads. GPose.body_fit over the clips
## the model will PLAY (WanderAgent.fit_clips, the lookup its setup() makes; a mount's gaits in the role's
## state, GClip.gait_clips, the lookup Vehicle plays them by; an enemy's roles by GClip.resolve, the lookup
## enemy.gd plays them by), at the role's phases (its "fast" roles' clips at twice them), cut into its slices,
## with its attack read as a strike.
static func fit(model: Node3D, role: String) -> Dictionary:
	var job := fit_job(model, role)
	while not job.step(-1):
		pass
	return job.fit


## The same fit as a job the parse-time warm works A PIECE AT A TIME (AreaBuilder._fit_drain; GPose.FitJob) — done before
## it starts when the fit is memoised.
static func fit_job(model: Node3D, role: String) -> GPose.FitJob:
	var pol: Dictionary = ROLES[role]
	var ap := GPose._find_anim_player(model)
	var clips := PackedStringArray()
	var fast := PackedStringArray()
	if pol.has("gaits"):
		clips = GClip.gait_clips(ap, String(pol["gaits"]) == "air")
	elif pol.has("clips"):
		for r in pol["clips"]:
			var c := GClip.resolve(ap, String(r))
			if c != "" and not clips.has(c):
				clips.append(c)
				if (pol.get("fast", []) as Array).has(r):
					fast.append(c)
	else:
		clips = WanderAgent.fit_clips(ap)
	if bool(pol.get("points", false)):
		GPose.drawn_rest_points(model)   # memoised per model, like the fit: the warm takes them, the spawner reads them
	return GPose.fit_job(model, clips, int(pol["phases"]), bool(pol["pose_persons"]), int(pol.get("slices", 0)),
		GClip.resolve(ap, String(pol["strike"])) if pol.has("strike") else "", fast, bool(pol.get("dense", false)),
		bool(pol.get("keel", false)), bool(pol.get("ground", false)))


## THE SCALE A MODEL IS DRAWN AT IN ITS ROLE — the one size rule an enemy, a populate entry and a named NPC are drawn by
## (the hero keeps HERO_HEIGHT: main._normalize_avatar_height), taken on what it DRAWS (`fit`: GPose.body_fit's rest): a
## factor for the model's scale. Every role used to size a GLB its own way — an enemy by bones and the un-skinned bind box,
## shrink-only to 3 m (a 0.96 m T-rex, a 6.81 m rat, a boss authored 8 m tall drawn 2.57-9.59), a herd by its largest
## dimension over 4 m to 2 m (a 2 m fox), a named NPC not at all (a 6.92 m horse), and every person at 1.65. `pol`:
##   role    "enemy" | "crowd" | "npc"
##   url     where the model came from: a library model (NATURAL) is drawn at its natural size
##   height  a drawn rest height the build gave (enemy_height, a boss's height): exactly that tall, nothing capped
##   max_size / target_size / scale   the entry's own rule (a populate entry's, a named NPC's): bigger than max_size (4 m)
##           is drawn target_size (2 m; `scale` read as target_size, as populate always has)
##   ch      a person's height as the hero path measures it (GPose.char_height; the drawn rest height without one)
## In order: the height given; the entry's own rule; the natural size; a PERSON's band (PERSON_BAND by ch: as drawn inside
## it, GRig.PERSON_H outside); anything else as its role always had it (an enemy as drawn, the crowd and an NPC over 4 m
## at 2 m). An enemy whose height was not given is then never taller than ENEMY_MAX_H, longer than ENEMY_MAX_L across
## its footprint, or smaller than ENEMY_MIN across.
static func normalise(fit: Dictionary, pol: Dictionary) -> float:
	var sz: Vector3 = (fit.get("rest", AABB()) as AABB).size
	if sz.y <= 0.01 and sz.x <= 0.01 and sz.z <= 0.01:
		return 1.0
	if float(pol.get("height", 0.0)) > 0.0 and sz.y > 0.01:
		return float(pol["height"]) / sz.y
	var mdim := maxf(sz.x, maxf(sz.y, sz.z))
	var s := 1.0
	var nat := natural_of(String(pol.get("url", "")))
	if pol.has("max_size") or pol.has("target_size") or pol.has("scale"):
		if mdim > float(pol.get("max_size", 4.0)):
			s = float(pol.get("target_size", pol.get("scale", 2.0))) / mdim
	elif not nat.is_empty():
		s = natural_scale(sz, nat)
	elif bool(fit.get("person", false)):
		var ch := float(pol.get("ch", sz.y))
		if ch > 0.05 and (ch < PERSON_BAND.x or ch > PERSON_BAND.y):
			s = GRig.PERSON_H / ch
	elif String(pol.get("role", "")) != "enemy" and mdim > 4.0:
		s = 2.0 / mdim
	if String(pol.get("role", "")) == "enemy":
		var foot := maxf(sz.x, sz.z)
		if sz.y > 0.01:
			s = minf(s, ENEMY_MAX_H / sz.y)
		if foot > 0.01:
			s = minf(s, ENEMY_MAX_L / foot)
		s = maxf(s, ENEMY_MIN / mdim)
	return s


## The NATURAL row for a model fetched from `url` ({} for none): its path on the asset origin, without the host, a query
## or ".glb" — "godot-assets/animals/fox". By path, never by file name: a game's own Meshy fox.glb is not the library's.
static func natural_of(url: String) -> Dictionary:
	var p := url
	var q := p.find("?")
	if q >= 0:
		p = p.substr(0, q)
	var k := p.find("://")
	if k >= 0:
		p = p.substr(k + 3)
		var sl := p.find("/")
		p = p.substr(sl + 1) if sl >= 0 else ""
	p = p.trim_prefix("/").trim_suffix(".glb")
	return NATURAL.get(p, {})


## The factor that draws a rest box `sz` at the natural row `nat`'s datum (h, l or w).
static func natural_scale(sz: Vector3, nat: Dictionary) -> float:
	if nat.has("h") and sz.y > 0.001:
		return float(nat["h"]) / sz.y
	if nat.has("l") and sz.z > 0.001:
		return float(nat["l"]) / sz.z
	if nat.has("w") and sz.x > 0.001:
		return float(nat["w"]) / sz.x
	return 1.0


# ------------------------------------------------------------------------------------- the ground a body stands on

## THE PLANE A RIGID BODY STANDS ON over uneven ground, given the ground's height `y` under the four corners of a rectangle of
## half extents `h` (order (-x,-z), (-x,+z), (+x,-z), (+x,+z) in its own frame): Vector3(the plane's height at the rectangle's
## centre, its slope along +x, along +z), the slopes within `lim` (the tangent of the steepest lean it takes). It stands on its
## higher diagonal and, within the bound the other two corners set, takes the flattest attitude (Vehicle._plane_through says
## why: least squares drove a sill into the ground beside a crater). One rule for every body that stands: a vehicle's chassis
## on its tyres (Vehicle._plane_through) and a creature on its feet (lean_on).
static func rest_plane(y: PackedFloat32Array, h: Vector2, lim: float) -> Vector3:
	var hx := h.x
	var hz := h.y
	var k := (hx * hx - hz * hz) / (hx * hx + hz * hz)   # the flattest rotation, per unit of diagonal rise
	var a: float
	var gx: float
	var gz: float
	if y[0] + y[3] >= y[1] + y[2]:
		# stands on corners 0 (-x,-z) and 3 (+x,+z): gx*hx + gz*hz = c; free s = gx*hx - gz*hz, which puts corner 1 at a - s
		# and corner 2 at a + s — neither may go below its own height
		a = (y[0] + y[3]) * 0.5
		var c := (y[3] - y[0]) * 0.5
		var sv := clampf(c * k, y[2] - a, a - y[1])
		gx = (c + sv) / (2.0 * hx)
		gz = (c - sv) / (2.0 * hz)
	else:
		# stands on corners 1 (-x,+z) and 2 (+x,-z): gx*hx - gz*hz = c; free s = gx*hx + gz*hz puts corner 0 at a - s and
		# corner 3 at a + s
		a = (y[1] + y[2]) * 0.5
		var c := (y[2] - y[1]) * 0.5
		var sv := clampf(c * k, y[3] - a, a - y[0])
		gx = (sv + c) / (2.0 * hx)
		gz = (sv - c) / (2.0 * hz)
	gx = clampf(gx, -lim, lim)
	gz = clampf(gz, -lim, lim)
	# Only the lean clamp can have put a corner below its height; lift it back out if so.
	var lift := 0.0
	for i in 4:
		lift = maxf(lift, y[i] - (a + gx * hx * (-1.0 if i < 2 else 1.0) + gz * hz * (-1.0 if i % 2 == 0 else 1.0)))
	return Vector3(a + lift, gx, gz)


## The lean that lays a footprint flat on a plane of slopes (gx, gz) (rest_plane's): +z runs up the fall line, +y is the plane's
## normal, and +x = y × z lies in the plane too, so all four corners land on it.
static func rest_lean(gx: float, gz: float) -> Basis:
	var up := Vector3(-gx, 1.0, -gz).normalized()
	var fwd := Vector3(0.0, gz, 1.0).normalized()
	return Basis(up.cross(fwd).normalized(), up, fwd)


## A creature leans this far from upright at most (a mount's chassis: Vehicle.GROUND_TILT_MAX), and stands its feet this far in
## from its footprint's edge when it has no feet to stand on (Vehicle.CONTACT_INSET). It leans only STANDING ON THE TERRAIN: its
## origin within LEAN_ON of the ground under it, upright again LEAN_OFF further off it (lean_on). And its BODY leans with what
## it draws (set_lean), read across the ground and against another box through upright boxes round it, LEAN_LAYERS to each of
## its own boxes, rebuilt once the lean has moved LEAN_TOL at its ends (leaned_bounds).
const LEAN_MAX := 0.8
const STANCE_INSET := 0.75
const LEAN_ON := 0.05
const LEAN_OFF := 0.15
const LEAN_LAYERS := 3
const LEAN_TOL := 0.005
static var lean_reads := 0      # leans read off the terrain, ever (lean_on past its early outs): the rigs count what a tick reads
# ...and one that bites and steps by its body (an enemy: `held`) eases back to upright on a cliff, from LEAN_STEEP all the way by
# LEAN_UPRIGHT: leaned 45 deg, the boxes round its body that the turn guard and its step in read stood 0.3 m past it, and a
# horse uphill of a still player on a 45 deg slope turned and stepped in and back 28 times in 5 s, never biting (the enemy rig's
# (l3)) — upright there it parks and bites (3 in 5 s), its body upright with what it draws. Eased from 30 deg instead, a cow
# chasing up a 31 deg grade went 0.10 m into it (the enemy rig's (lean body): 0.033 leaned whole).
const LEAN_STEEP := deg_to_rad(35.0)
const LEAN_UPRIGHT := deg_to_rad(45.0)


## WHAT A CREATURE STANDS ON, in `owner`'s frame (its model hangs somewhere under it): [centre, half extents] of the rectangle
## its feet stand in at rest — three feet or more of GRig.legs (a quadruped's, a spider's) — else the footprint it draws at rest,
## STANCE_INSET in from its edges as a mount's tyres are (a biped's two feet stand side by side, a snake has none). [] when it
## draws nothing to stand on.
static func stance(model: Node3D, owner: Node3D) -> Array:
	var sk := GPose.skeleton_of(model)
	var legs := GRig.legs(model) if sk != null else []
	if legs.size() >= 3:
		var xf := GPose.xf_to(sk, owner)
		var lo := Vector2(INF, INF)
		var hi := -lo
		for L in legs:
			var f := xf * sk.get_bone_global_rest(int(L["foot"])).origin
			lo = lo.min(Vector2(f.x, f.z))
			hi = hi.max(Vector2(f.x, f.z))
		if hi.x - lo.x > 1e-3 and hi.y - lo.y > 1e-3:
			return [(lo + hi) * 0.5, (hi - lo) * 0.5]
	var ab := GPose.xf_to(model.get_parent(), owner) * GPose.drawn_aabb(model)
	if ab.size.x <= 1e-3 or ab.size.z <= 1e-3:
		return []
	var cc := ab.get_center()
	return [Vector2(cc.x, cc.z), Vector2(ab.size.x, ab.size.z) * 0.5 * STANCE_INSET]


## THE LEAN A CREATURE TAKES WHERE `owner` STANDS: its stance (stance()) set on the ground of `t` under it (rest_plane, read
## through height_cached into `cache`, cleared when the terrain is set up again: GTerrain.revision), turned with the owner's
## heading — the transform its model and its body go under (set_lean), in the owner's frame: the lean about its origin, at most
## `lim` each way, and the rise or drop that puts what it stands on onto that plane (the origin is on the ground under it; on a
## crest the plane runs under that). Upright and in place when there is nothing to stand on — and OFF THE TERRAIN: the plane
## it reads is the terrain's, so a creature on anything else (a deck, a rock, a bridge, a floor) or in the air was drawn on the
## terrain under it — an enemy cow on a 2 m deck 2.0 m into it, one walking off a 3 m deck drawn 2.6-2.9 m under its falling
## body (step 5c's review). Its origin within LEAN_ON of the terrain it leans whole, from there eased upright over LEAN_OFF
## more — the terrain read under the origin, where a round foot of `foot_r` (an enemy's mover: a capsule) stands its origin
## foot_r x (sec(slope) - 1) over the ground (a 0.45 m mover on a 31 deg slope 0.075 m: held to LEAN_ON alone, a cow there
## leaned 27.8 deg, not 31). `held`: upright again on a cliff (LEAN_STEEP .. LEAN_UPRIGHT).
## ON LEVEL GROUND IT READS NOTHING: everything it would read (its stance's reach round its origin) on quads level at one height
## (GTerrain.level_under), the plane is that height and the lean is the rise or drop onto it alone — what every read would have
## given. Read there every moving tick, a chasing creature near the player paid +13.6 us on a 30.7 us tick for a lean that moved
## nothing (step 5d's review); lean_reads counts the reads past it.
static func lean_on(owner: Node3D, t: GTerrain, cache: Dictionary, rect: Array, lim := LEAN_MAX, foot_r := 0.0,
		held := false) -> Transform3D:
	if rect.is_empty() or t == null:
		return Transform3D.IDENTITY
	var g := owner.global_transform
	var c: Vector2 = rect[0]
	var h: Vector2 = rect[1]
	var s := g.basis.get_scale().x
	var rr := (c.length() + h.length()) * s
	var lv := t.level_under(Rect2(g.origin.x - rr, g.origin.z - rr, rr * 2.0, rr * 2.0), cache)
	if is_finite(lv):
		var off0 := absf(g.origin.y - lv)
		if off0 >= LEAN_ON + LEAN_OFF:
			return Transform3D.IDENTITY
		var f0 := 1.0 if off0 <= LEAN_ON else (LEAN_ON + LEAN_OFF - off0) / LEAN_OFF
		return Transform3D(Basis(), Vector3(0.0, f0 * (lv - g.origin.y) / maxf(s, 1e-6), 0.0))
	lean_reads += 1
	if cache.size() > 4096 or int(cache.get(&"rev", -1)) != t.revision:
		cache.clear()
		cache[&"rev"] = t.revision
	var b := Basis(Vector3.UP, owner.global_rotation.y)
	var y := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	for i in 4:
		var w := g.origin + b * (Vector3(c.x + h.x * (-1.0 if i < 2 else 1.0), 0.0, c.y + h.y * (-1.0 if i % 2 == 0 else 1.0)) * s)
		y[i] = t.height_cached(w.x, w.z, cache)
	var pl := rest_plane(y, h * s, tan(lim))
	var on := LEAN_ON + foot_r * (sqrt(1.0 + pl.y * pl.y + pl.z * pl.z) - 1.0)
	var off := absf(g.origin.y - t.height_cached(g.origin.x, g.origin.z, cache))
	if off >= on + LEAN_OFF:
		return Transform3D.IDENTITY
	var o := pl.x - (pl.y * c.x + pl.z * c.y) * s   # the plane under the origin
	var lean := Transform3D(rest_lean(pl.y, pl.z), Vector3(0.0, (o - g.origin.y) / maxf(s, 1e-6), 0.0))
	var f := 1.0 if off <= on else (on + LEAN_OFF - off) / LEAN_OFF
	if held:
		f = minf(f, clampf((LEAN_UPRIGHT - atan(Vector2(pl.y, pl.z).length())) / (LEAN_UPRIGHT - LEAN_STEEP), 0.0, 1.0))
	return lean if f >= 1.0 else Transform3D.IDENTITY.interpolate_with(lean, f)


## `o` answers for this body from here on: every query reads its transform, and collider() names it. It
## rebinds, it never shares (one GBody per owner).
func owned_by(o: Node3D) -> GBody:
	owner = o
	if _bounds != null:
		_bounds.owner = o
	return self


## THE BODY LEANS WITH WHAT IT DRAWS (`l`: lean_on's — the transform its model or mesh goes under, owner-local): every collider
## collider() built from it is set under it, and every query reads it. Drawn leaned on an upright body, a herd cow on a 17 deg
## grade drew 0.23-0.28 m out of its body and an enemy cow 0.37-0.43, a T-rex on a 31 deg one 0.46 — shots at its head went
## through it (step 5c's review). A person never leans (no stance): only a BOX does.
##   EXACT: dist3, nearest3 and centre (a point mapped into its upright frame and back: the lean is rigid), gap_to a round body
##   (the capsule's axis against each box: _seg_box) — what a shot, a bite and a blow at the player on foot read — and the
##   colliders (the physics leans them as it draws them).
##   ROUND IT (leaned_bounds: upright boxes holding every leaned box, LEAN_LAYERS to one): the reads across the ground — its
##   footprint, the turn guard, the slot ring, the wall rays — reach3, and gap_to another box (a ridden hull): never inside
##   what it draws, at most a layer's tilt of air past it.
## A LEAN THAT MOVES NO POINT OF IT LEAN_TOL IS NONE. An enemy's mover hovers its CharacterBody3D's margin over flat ground
## (0.94 mm), lean_on gave it that drop, and an identity test (is_zero_approx: 1e-5) called it a lean: every read of a chasing
## creature on flat ground took the leaned path, every tick (210 of 210; a chasing tick far off 50.1 us against 32.5 before the
## lean, step 5c's re-check). upright() says so to whoever draws it.
func set_lean(l: Transform3D) -> void:
	if kind != BOX or upright(l):
		l = Transform3D.IDENTITY
	if l == lean:
		return
	lean = l
	_leaned = l != Transform3D.IDENTITY
	if _bounds_ok and _tilt_moved(_bounds_at, l) > LEAN_TOL:
		_bounds_ok = false
	for w in _cols:
		var col = (w as WeakRef).get_ref()
		if col is Node3D:
			(col as Node3D).transform = l * _col_base()


## The upright boxes every query across the ground reads this body by (set_lean): itself when it stands upright; leaned, each of
## its boxes cut into LEAN_LAYERS layers, the upright box round each layer leaned (grown LEAN_TOL: rebuilt only once the lean
## has moved that far at its ends) — in its own frame, owned by its owner.
func leaned_bounds() -> GBody:
	if not _leaned:
		return self
	if _bounds_ok:
		return _bounds
	if _bounds == null:
		_bounds = GBody.new()
		_bounds.kind = BOX
		_bounds.owner = owner
		for q: GBody in _parts_or_self():
			for k in LEAN_LAYERS:
				_bounds.parts.append(GBody.new())
				_bounds.parts[_bounds.parts.size() - 1].kind = BOX
	var ab := Basis(lean.basis.x.abs(), lean.basis.y.abs(), lean.basis.z.abs())   # |R|: the half extents of a leaned box
	var lo := Vector3.INF
	var hi := -Vector3.INF
	var i := 0
	for q: GBody in _parts_or_self():
		var dy := (q.y1 - q.y0) / float(LEAN_LAYERS)
		var hh := ab * Vector3(q.half.x, dy * 0.5, q.half.y) + Vector3.ONE * LEAN_TOL
		for k in LEAN_LAYERS:
			var cc := lean * Vector3(q.c.x, q.y0 + dy * (float(k) + 0.5), q.c.y)
			var p: GBody = _bounds.parts[i]
			p.c = Vector2(cc.x, cc.z)
			p.half = Vector2(hh.x, hh.z)
			p.y0 = cc.y - hh.y
			p.y1 = cc.y + hh.y
			lo = lo.min(cc - hh)
			hi = hi.max(cc + hh)
			i += 1
	_bounds.c = c
	_bounds.half = Vector2(maxf(hi.x - c.x, c.x - lo.x), maxf(hi.z - c.y, c.y - lo.z))
	_bounds.y0 = lo.y
	_bounds.y1 = hi.y
	_bounds._pc_at = Vector3.INF
	_bounds_at = lean
	_bounds_ok = true
	return _bounds


## Does the lean `l` move no point of this body more than LEAN_TOL (set_lean holds it upright)?
func upright(l: Transform3D) -> bool:
	return _tilt_moved(Transform3D.IDENTITY, l) <= LEAN_TOL


# How far a point of this body moves between leans `a` and `b`, at most: the bases' difference (its Frobenius norm, over the
# largest it stretches anything) times the farthest corner from the origin, and the origins'.
func _tilt_moved(a: Transform3D, b: Transform3D) -> float:
	if _far < 0.0:
		_far = 0.0
		for q: GBody in _parts_or_self():
			_far = maxf(_far, Vector3(absf(q.c.x) + q.half.x, maxf(absf(q.y0), absf(q.y1)), absf(q.c.y) + q.half.y).length())
	var d := Basis(a.basis.x - b.basis.x, a.basis.y - b.basis.y, a.basis.z - b.basis.z)
	return sqrt(d.x.length_squared() + d.y.length_squared() + d.z.length_squared()) * _far + a.origin.distance_to(b.origin)


# The rigid map its lean is where its owner stands, in the owner's parent frame (every query's): its upright body there is
# carried onto its leaned one.
func _lean_map() -> Transform3D:
	var s := absf(owner.scale.x)
	var yb := Basis(Vector3.UP, owner.rotation.y)
	var m := Transform3D(yb * lean.basis * yb.transposed(), Vector3.ZERO)
	m.origin = owner.position + yb * (lean.origin * s) - m.basis * owner.position
	return m


# Where collider() stands the body it builds, in the owner's frame (upright): the shape rule's.
func _col_base() -> Transform3D:
	if kind == ROUND:
		return Transform3D(Basis(), Vector3(c.x, y0 + maxf(y1 - y0, r * 2.0) * 0.5, c.y))
	if parts.is_empty():
		return Transform3D(Basis(), Vector3(c.x, (y0 + y1) * 0.5, c.y))
	return Transform3D()


## THE PHYSICS THIS BODY DESCRIBES, built from the same numbers (null for NONE), with the owner stamped on
## it (meta gbody_owner) so a collider the physics hands back finds its body through GBody.of.
##
## A COLLIDER THAT WALKS IS NOT STATIC. Shipped 2026-09-23 as a StaticBody3D parented to a wander agent —
## that is, an immovable body with infinite mass, moved every frame. The physics server resolves that by
## refusing to yield: a villager walking into the player jams them instead of pushing past, two converging
## villagers wedge them solid, and one walking THROUGH where they stand drags them along. Both halves of
## "it freezes when I want to move, or won't stop when I want it to stop" are that one wrong class.
## AnimatableBody3D is the type for exactly this — a collider moved by script that still depenetrates
## properly against the bodies it meets.
func collider(layer: int, mask := 0) -> CollisionObject3D:
	if kind == NONE:
		return null
	var body := AnimatableBody3D.new()
	body.sync_to_physics = false       # the owner moves the PARENT; syncing would fight it
	body.collision_layer = layer
	body.collision_mask = mask         # 0: a body is collided WITH; it does not collide with anything
	if owner != null:
		body.set_meta("gbody_owner", owner)
	if kind == ROUND:
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = r
		cap.height = maxf(y1 - y0, r * 2.0)
		cs.shape = cap
		body.position = Vector3(c.x, y0 + cap.height * 0.5, c.y)
		body.add_child(cs)
	elif parts.is_empty():
		body.add_child(_box_shape(half, y1 - y0))
		body.position = Vector3(c.x, (y0 + y1) * 0.5, c.y)
	else:
		# sliced: the body stands on the owner's origin and each slice's box where it is
		for q in parts:
			var cs := _box_shape(q.half, q.y1 - q.y0)
			cs.position = Vector3(q.c.x, (q.y0 + q.y1) * 0.5, q.c.y)
			body.add_child(cs)
	# ...leaned with it (set_lean), now and from here on
	_cols.append(weakref(body))
	if _leaned:
		body.transform = lean * _col_base()
	return body


## THE BODY A NODE BELONGS TO. Walks up from `n` — a collider the physics handed back, one of its shapes,
## or an owner itself — to whoever answers for it: a node whose `body` is a GBody, or the gbody_owner
## collider() stamped. THE STAMP DECIDES where there is one: its owner's body — or nobody's, once that
## owner is gone (freed while its collider hangs on somewhere else: a collider need not hang under its
## owner) or when the stamp names no object at all. Never the body of whatever an orphan hangs under, and
## never an error: the stamp is read untyped, because assigning a freed instance (or a String) to a typed
## Object is a SCRIPT ERROR before any validity test can run (4.7.1). null: nobody's.
static func of(n: Node) -> GBody:
	while n != null:
		if n.has_meta("gbody_owner"):
			var o = n.get_meta("gbody_owner")
			var ob = o.get("body") if is_instance_valid(o) else null
			return ob if ob is GBody else null
		var b = n.get("body")
		if b is GBody:
			return b
		n = n.get_parent()
	return null


## The point of the footprint closest to `p` (XZ), with the owner at `at` facing `yaw` (default: where it
## stands, how it faces). A round body answers its centre: the direction to it is all anyone has ever
## asked of a person.
##
## THE CROWD'S HOTTEST QUERY (personal space and the push ask it every step a crowd member takes), so the
## one-box case is written out here rather than called: through _box_point, and with the owner's transform
## read property by property, the move cost a box +53% a call (0.69 -> 1.06 us, desktop headless); written
## out, +30% (0.70 -> 0.91 us — the rest is the delegate's call). The sliced loop below keeps _box_point,
## and the people rig holds the two to each other ("a sliced body is exactly its slices").
func nearest(p: Vector2, at := Vector2(INF, INF), yaw := NAN) -> Vector2:
	if _leaned:
		return leaned_bounds().nearest(p, at, yaw)
	var o := owner
	if at.x == INF:
		var op := o.position
		at = Vector2(op.x, op.z)
	if is_nan(yaw):
		yaw = o.rotation.y
	var s := absf(o.scale.x)
	var ex := Vector2(cos(yaw), -sin(yaw))
	var ez := Vector2(sin(yaw), cos(yaw))
	var cc := at + (ex * c.x + ez * c.y) * s
	if kind != BOX:
		return cc
	if parts.is_empty():
		var d := p - cc
		return cc + ex * clampf(d.dot(ex), -half.x * s, half.x * s) + ez * clampf(d.dot(ez), -half.y * s, half.y * s)
	var best := at
	var bd := INF
	for q in parts:
		var b := _box_point(p, at, ex, ez, s, q.c, q.half)
		if b.distance_squared_to(p) < bd:
			bd = b.distance_squared_to(p)
			best = b
	return best


## Clear space between the footprint and the point `p` (negative = `p` is inside it). GCast.vary scales
## the owner and the body with it (villager_man measured x1.092 -> 0.371 m) — but a round body never
## measures less than unscaled, so a person's floor is still the two capsules' 0.74 m.
func gap(p: Vector2, at := Vector2(INF, INF), yaw := NAN) -> float:
	var q := nearest(p, at, yaw)
	if kind != BOX:
		return p.distance_to(q) - r * maxf(1.0, absf(owner.scale.x))
	return p.distance_to(q) if q.distance_squared_to(p) > 1e-10 else -0.01


## How far `p` is from this body in the unit every reach in the crowd was tuned in: a PERSON's centre
## distance. A round body answers the distance to its centre; anything else the distance to its nearest
## point plus a person's radius — so one reach (HOSTILE_REACH, a swing's 2.4 m) is the same gap from a
## horse's skin as from a villager's, and a nearest-wins between the two compares like with like. (The
## swing compared a person's CENTRE with a box's SURFACE: a creature got 0.34 m more reach, and won a
## tie against a villager the blade was nearer to.)
func reach(p: Vector2, at := Vector2(INF, INF), yaw := NAN) -> float:
	if kind != BOX:
		return p.distance_to(nearest(p, at, yaw))
	return gap(p, at, yaw) + CROWD_RADIUS


## WHERE SOMEBODY KEEPING `reach_m` OF THIS BODY STANDS on the bearing `dir` from its centre: reach()'s inverse along
## one bearing, in the same person-centre unit. A round body answers its centre + dir * reach_m; a box the point on that
## bearing with reach_m - CROWD_RADIUS of clear space to its footprint — the rounded rectangle's edge, a face or a
## corner's arc (a sliced box: the furthest of its slices'). An enemy's surround slot (enemy.gd) is this ring: a ring
## at 1.7 m from a RIDER's origin put 36% of a horse's slots and 41% of a cow's inside the hull plus the enemy's 0.4 m,
## where an enemy aiming at one walks into the hull for ever (mount-hulls review, computed from the measured hulls).
func at_reach(dir: Vector2, reach_m: float, at := Vector2(INF, INF), yaw := NAN) -> Vector2:
	if _leaned:
		return leaned_bounds().at_reach(dir, reach_m, at, yaw)
	var o := owner
	if at.x == INF:
		at = Vector2(o.position.x, o.position.z)
	if is_nan(yaw):
		yaw = o.rotation.y
	var s := absf(o.scale.x)
	var ex := Vector2(cos(yaw), -sin(yaw))
	var ez := Vector2(sin(yaw), cos(yaw))
	var cc := at + (ex * c.x + ez * c.y) * s
	dir = dir.normalized() if dir.length_squared() > 1e-8 else ez
	if kind != BOX:
		return cc + dir * reach_m
	var g := maxf(reach_m - CROWD_RADIUS, 0.0)
	var dl := Vector2(dir.dot(ex), dir.dot(ez))
	var t := 0.0
	for q in _parts_or_self():
		var rel: Vector2 = cc - (at + (ex * q.c.x + ez * q.c.y) * s)
		t = maxf(t, _ray_exit(Vector2(rel.dot(ex), rel.dot(ez)), dl, q.half.x * s, q.half.y * s, g))
	return cc + dir * t


## WHERE SOMEBODY KEEPING `g` OF CLEAR SPACE FROM THIS BODY STANDS on the bearing `dir` from its centre: at_reach in
## gap_to's unit, clear space — a round body's centre + dir * (its radius, as the physics scales it, + g), a box's point
## `g` off its footprint. Where an enemy's own body parks round the player's (enemy.gd), whatever either body is: its
## origin goes this far out plus its own reach toward them.
func at_gap(dir: Vector2, g: float) -> Vector2:
	if kind != BOX:
		return at_reach(dir, r * absf(owner.scale.x) + g)
	return at_reach(dir, g + CROWD_RADIUS)


## How far the body reaches from the owner's origin in XZ direction `d`, past what a person centred on it
## reaches (the footprint's support function). 0 for a round body on the origin: the crowd's rays were
## calibrated from a person's centre and stay exactly as they were; an off-centre capsule reaches its
## offset further. A 2 m horse's is ~1.1 m nose-first and ~0.9 m rump-first.
func support(d: Vector2, yaw := NAN) -> float:
	if _leaned:
		return leaned_bounds().support(d, yaw)
	if d.length_squared() < 1e-8:
		return 0.0
	d = d.normalized()
	var o := owner
	if is_nan(yaw):
		yaw = o.rotation.y
	var s := absf(o.scale.x)
	var ex := Vector2(cos(yaw), -sin(yaw))
	var ez := Vector2(sin(yaw), cos(yaw))
	if parts.is_empty():   # written out, like nearest's one box: every step's wall ray asks it
		var cc := (ex * c.x + ez * c.y) * s
		return maxf(0.0, cc.dot(d) + (absf(d.dot(ex)) * half.x + absf(d.dot(ez)) * half.y) * s)
	var best := 0.0
	for q in parts:
		best = maxf(best, _box_support(d, ex, ez, s, q.c, q.half))
	return best


## THE STEP THAT NEVER CLOSES ON `p`: the geometry of personal space (WanderAgent._clear_of_player). The
## owner stepping from `cur` to `next` keeps `min_gap` of clear space between this body and the point `p`
## (the player's axis), or loses the inward part of the step. A step that ends clear, or that does not
## bring the body CLOSER, stands as it is, so somebody the player walked into is never pinned there; one
## aimed dead at them keeps only its tangential part — a slide round their shoulder, or a hold until the
## forward probe reroutes. NONE never stops anything.
##
## MEASURED FROM THE BODY, NOT THE ORIGIN. A horse kept the player 0.74 m off its middle, which is a metre
## inside its head: fleeing through an idle player it carried them 0.75 m on its nose (people rig). The
## same test on the footprint's nearest point is exactly the old circle for a person.
func clear_step(cur: Vector2, next: Vector2, p: Vector2, min_gap: float) -> Vector2:
	if kind == NONE:
		return next
	if gap(p, next, owner.rotation.y) >= min_gap:
		return next
	var out := nearest(p, cur) - p
	var l := out.length()
	if l < 0.001:
		return next                      # dead on top of them: every way out is away, none is inward
	var n := out / l
	var step := next - cur
	var radial := step.dot(n)
	if radial >= 0.0:
		return next                      # not closer (out or round): the player's move, not ours
	return cur + (step - n * radial)     # drop the inward part: |result - p| >= |cur - p|


## THE TURN THAT NEVER SWEEPS ONTO `p`: the geometry of WanderAgent._face_heading's guard. A long body
## sweeps when it turns and a round one does not, so a person always may. Turning at `at` from `yaw0` to
## `yaw1` waits when it would bring the body within `min_gap` of `p` AND closer than it is now; a turn
## that takes it away is never held, even with `p` inside the skin.
func turn_ok(at: Vector2, yaw0: float, yaw1: float, p: Vector2, min_gap: float) -> bool:
	if kind != BOX:
		return true
	var g1 := gap(p, at, yaw1)
	return not (g1 < min_gap and g1 < gap(p, at, yaw0))


## reach() with the height band too: a body hovering over `p`'s band — feet at `p.y`, `band` tall (a flyer
## over the player) — is that much further away. On the ground (every crowd member) the bands overlap and
## this is reach().
func reach3(p: Vector3, band: float) -> float:
	if _leaned:
		return leaned_bounds().reach3(p, band)
	var q := Vector2(p.x, p.z)
	if parts.is_empty():
		return _with_dy(reach(q), _band_gap(p.y, p.y + band, y0, y1))
	var best := INF
	for b in _boxes(q):
		best = minf(best, _with_dy(float(b[4]) + CROWD_RADIUS, _band_gap(p.y, p.y + band, b[2], b[3])))
	return best


## The point of the body closest to `p`, in 3D (the owner's parent frame, as every query) — `p` itself when it is inside:
## a capsule's or a box's, whichever of a sliced body's boxes is nearest. Where a bite leaves from and a blow lands
## (enemy._sees, main._attack): their line of sight runs from here.
func nearest3(p: Vector3) -> Vector3:
	if _leaned:
		var m := _lean_map()
		return m * _nearest3_up(m.affine_inverse() * p)
	return _nearest3_up(p)


# nearest3 of the body upright.
func _nearest3_up(p: Vector3) -> Vector3:
	var best := p
	var bd := INF
	for b in _prisms():
		var q := Vector3.ZERO
		if b[0]:
			var ax := Vector3((b[1] as Vector2).x, clampf(p.y, float(b[6]), float(b[7])), (b[1] as Vector2).y)
			var d := p - ax
			q = p if d.length() <= float(b[2]) else ax + d.normalized() * float(b[2])
		else:
			var rel: Vector2 = Vector2(p.x, p.z) - (b[1] as Vector2)
			var hx := float((b[5] as Vector2).x)
			var hz := float((b[5] as Vector2).y)
			var f: Vector2 = (b[1] as Vector2) + (b[3] as Vector2) * clampf(rel.dot(b[3]), -hx, hx) + (b[4] as Vector2) * clampf(rel.dot(b[4]), -hz, hz)
			q = Vector3(f.x, clampf(p.y, float(b[6]), float(b[7])), f.y)
		if q.distance_squared_to(p) < bd:
			bd = q.distance_squared_to(p)
			best = q
	return best


## Where a shot at this body should go: the middle of its volume (a person's middle, a creature's barrel)
## — the centre of the shape collider() builds, or the mean of a sliced body's boxes.
func centre() -> Vector3:
	if _leaned:
		return _lean_map() * _centre_up()
	return _centre_up()


# centre of the body upright.
func _centre_up() -> Vector3:
	if kind != BOX:
		return _to_owner(Vector3(c.x, y0 + maxf(y1 - y0, r * 2.0) * 0.5, c.y))
	if parts.is_empty():
		return _to_owner(Vector3(c.x, (y0 + y1) * 0.5, c.y))
	var sum := Vector3.ZERO
	for q in parts:
		sum += Vector3(q.c.x, (q.y0 + q.y1) * 0.5, q.c.y)
	return _to_owner(sum / float(parts.size()))


## How far the point `p` is from the body (0 inside) — from the shape collider() builds, exactly: a box is
## its footprint swept over its height band, a capsule its axis grown by the radius the physics scales.
## Not a cylinder at gap()'s unscaled radius (that floor is personal space's policy, not the body): read
## that way, the people rig's capsules came out up to 2.46 m off what the physics has — a cylinder's
## square rim stands up to 0.41 r proud of a capsule's rounded end, and a 0.85-scaled capsule is 15%
## slimmer than the floor. The camera's fade test.
func dist3(p: Vector3) -> float:
	if _leaned:
		p = _lean_map().affine_inverse() * p
	var q := Vector2(p.x, p.z)
	if kind != BOX:
		var cap: Array = _prisms()[0]
		return maxf(0.0, _with_dy(q.distance_to(cap[1]), maxf(float(cap[6]) - p.y, p.y - float(cap[7]))) - float(cap[2]))
	var best := INF
	for b in _boxes(q):
		best = minf(best, _with_dy(maxf(0.0, float(b[4])), _band_gap(p.y, p.y, b[2], b[3])))
	return best


## THE CLEAR SPACE BETWEEN TWO BODIES, each where its own owner stands, as the shapes collider() builds:
## each a CORE — a box, or a capsule's axis — grown by its radius (a box's is 0). The cores' footprint gap
## and height gap combine as for any two separated boxes, and the radii come off after, so two capsules
## measure exactly as capsules (their rounded ends, the radius the physics scales — read as floored
## cylinders, two of the people rig's bodies 1.009 m apart came out 0.938). Negative when they
## overlap: two capsules by their true depth, anything with a box only by its sign (gap()'s -0.01 inside a
## box, less a capsule's radius — how deep is not measured).
func gap_to(other: GBody) -> float:
	gap_calls += 1
	if _leaned or other._leaned:
		# A LEANED BODY (set_lean): against a round one exactly (_gap_round: what a bite at the player on foot reads), anything
		# else through the upright boxes round it
		if not other._leaned and other.kind == ROUND:
			return _gap_round(other)
		if not _leaned and kind == ROUND:
			return other._gap_round(self)
		return _gap_prisms(leaned_bounds()._prisms(), other.leaned_bounds()._prisms())
	return _gap_prisms(_prisms(), other._prisms())


# gap_to's measure between two bodies' prisms (_prisms).
static func _gap_prisms(A: Array, B: Array) -> float:
	var best := INF
	for a in A:
		for b in B:
			var dxz := _prism_gap(a, b)
			var dy := maxf(float(b[6]) - float(a[7]), float(a[6]) - float(b[7]))
			var d := dxz
			if dy > 0.0:
				d = dy if dxz <= 0.0 else sqrt(dxz * dxz + dy * dy)
			best = minf(best, d - float(a[2]) - float(b[2]))
	return best


# A LEANED box body's clear space to a round one `o`, exactly: the capsule's axis (its core) carried into this body's upright
# frame (its owner's, unscaled), its least distance to each box (_seg_box), less the capsule's radius — and, the axis inside a
# box, gap()'s -0.01 less it, as gap_to has a box's overlap.
func _gap_round(o: GBody) -> float:
	var cap: Array = o._prisms()[0]
	var cxz: Vector2 = cap[1]
	var s := absf(owner.scale.x)
	var inv := (Transform3D(Basis(Vector3.UP, owner.rotation.y).scaled(Vector3.ONE * s), owner.position) * lean).affine_inverse()
	var a := inv * Vector3(cxz.x, float(cap[6]), cxz.y)
	var d := inv * Vector3(cxz.x, float(cap[7]), cxz.y) - a
	var best := INF
	for q: GBody in _parts_or_self():
		var d2 := _seg_box(a, d, Vector3(q.c.x - q.half.x, q.y0, q.c.y - q.half.y), Vector3(q.c.x + q.half.x, q.y1, q.c.y + q.half.y))
		best = minf(best, sqrt(d2) * s if d2 > 1e-12 else -0.01)
	return best - float(cap[2])


# The least squared distance between the segment a + d t (t in 0..1) and the box lo..hi. It is a sum, axis by axis, of how
# far the point is out of the box's slab — one quadratic in t between the points where the segment crosses a face's plane —
# so the least is the least of each piece's.
static func _seg_box(a: Vector3, d: Vector3, lo: Vector3, hi: Vector3) -> float:
	var ts := PackedFloat64Array([0.0, 1.0])
	for i in 3:
		if absf(d[i]) > 1e-12:
			for e: float in [lo[i], hi[i]]:
				var t := (e - a[i]) / d[i]
				if t > 0.0 and t < 1.0:
					ts.append(t)
	ts.sort()
	var best := INF
	for k in ts.size() - 1:
		var t0 := ts[k]
		var t1 := ts[k + 1]
		var m := a + d * ((t0 + t1) * 0.5)
		var qa := 0.0
		var qb := 0.0
		var qc := 0.0
		for i in 3:
			var out := m[i] < lo[i] or m[i] > hi[i]
			if out:
				var u: float = a[i] - (lo[i] if m[i] < lo[i] else hi[i])
				qa += d[i] * d[i]
				qb += 2.0 * u * d[i]
				qc += u * u
		var t := clampf(-qb / (2.0 * qa), t0, t1) if qa > 1e-18 else t0
		best = minf(best, maxf(0.0, (qa * t + qb) * t + qc))
	return best


# ---------------------------------------------------------------- the geometry behind the queries

# The point of one box's footprint closest to `p`, the owner's frame given as `at`, axes `ex`/`ez`, scale `s`.
static func _box_point(p: Vector2, at: Vector2, ex: Vector2, ez: Vector2, s: float, bc: Vector2, bh: Vector2) -> Vector2:
	var cc := at + (ex * bc.x + ez * bc.y) * s
	var d := p - cc
	return cc + ex * clampf(d.dot(ex), -bh.x * s, bh.x * s) + ez * clampf(d.dot(ez), -bh.y * s, bh.y * s)


# One footprint's support function in direction `d` (unit), measured from the owner's origin.
static func _box_support(d: Vector2, ex: Vector2, ez: Vector2, s: float, bc: Vector2, bh: Vector2) -> float:
	var cc := (ex * bc.x + ez * bc.y) * s
	return maxf(0.0, cc.dot(d) + (absf(d.dot(ex)) * bh.x + absf(d.dot(ez)) * bh.y) * s)


# The far end of the ray o + d t (d a unit vector, t >= 0) through the rectangle |x| <= hx, |z| <= hz grown by `g` with
# rounded corners — two slabs and four corner discs, whose union is that convex shape, so its exit is theirs at its
# furthest. -1 when the ray misses it.
static func _ray_exit(o: Vector2, d: Vector2, hx: float, hz: float, g: float) -> float:
	var best := -1.0
	for slab in [Vector2(hx + g, hz), Vector2(hx, hz + g)]:
		var t0 := -INF
		var t1 := INF
		for i in 2:
			if absf(d[i]) < 1e-9:
				if absf(o[i]) > slab[i]:
					t1 = -INF
				continue
			var a: float = (-slab[i] - o[i]) / d[i]
			var b: float = (slab[i] - o[i]) / d[i]
			t0 = maxf(t0, minf(a, b))
			t1 = minf(t1, maxf(a, b))
		if t1 >= t0 and t1 >= 0.0:
			best = maxf(best, t1)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var oc := o - Vector2(hx * sx, hz * sz)
			var b := oc.dot(d)
			var disc := b * b - (oc.length_squared() - g * g)
			if disc >= 0.0 and -b + sqrt(disc) >= 0.0:
				best = maxf(best, -b + sqrt(disc))
	return best


# One box's shape for collider(): half extents `h` (x, z), `height` tall.
static func _box_shape(h: Vector2, height: float) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = Vector3(h.x * 2.0, height, h.y * 2.0)
	cs.shape = bx
	return cs


# The nearest 32-bit float to `x`: what a shape's property stores.
static func _f32(x: float) -> float:
	return PackedFloat32Array([x])[0]


# The clear space between the band lo..hi (world y) and an owner-local band b0..b1 (<= 0: they overlap).
func _band_gap(lo: float, hi: float, b0: float, b1: float) -> float:
	var s := absf(owner.scale.x)
	return maxf(owner.position.y + b0 * s - hi, lo - (owner.position.y + b1 * s))


# A horizontal distance `h` and a vertical gap `dy` combined: Pythagoras once the bands are apart.
static func _with_dy(h: float, dy: float) -> float:
	return sqrt(h * h + dy * dy) if dy > 0.0 else h


# An owner-local point in the owner's frame: rotated by its yaw, scaled, placed — the same transform the
# footprint queries apply.
func _to_owner(v: Vector3) -> Vector3:
	var s := absf(owner.scale.x)
	var yaw := owner.rotation.y
	var w := Vector2(owner.position.x, owner.position.z) + (Vector2(cos(yaw), -sin(yaw)) * v.x + Vector2(sin(yaw), cos(yaw)) * v.z) * s
	return Vector3(w.x, owner.position.y + v.y * s, w.y)


# A BOX body's boxes as [c, half, y0, y1, gap to `p`] (one, or every slice) where the owner stands.
func _boxes(p := Vector2.ZERO) -> Array:
	var at := Vector2(owner.position.x, owner.position.z)
	var yaw := owner.rotation.y
	var s := absf(owner.scale.x)
	var ex := Vector2(cos(yaw), -sin(yaw))
	var ez := Vector2(sin(yaw), cos(yaw))
	var out: Array = []
	for q in _parts_or_self():
		var b := _box_point(p, at, ex, ez, s, q.c, q.half)
		out.append([q.c, q.half, q.y0, q.y1, p.distance_to(b) if b.distance_squared_to(p) > 1e-10 else -0.01])
	return out


# A BOX body's boxes: its slices, or itself.
func _parts_or_self() -> Array:
	var list: Array = [self]
	if not parts.is_empty():
		list = parts
	return list


# This body as world prisms for gap_to and dist3, one per box: [round?, centre, radius, ex, ez, half, core
# y lo, core y hi]. A box's core is itself (radius 0); a capsule's is its AXIS, a radius short of each end,
# and its radius the one the physics scales.
func _prisms() -> Array:
	var op := owner.position
	var yaw := owner.rotation.y
	var s := absf(owner.scale.x)
	if op == _pc_at and yaw == _pc_yaw and s == _pc_s:
		return _pc   # where it was laid out last: the same numbers
	prism_builds += 1
	var at := Vector2(op.x, op.z)
	var ex := Vector2(cos(yaw), -sin(yaw))
	var ez := Vector2(sin(yaw), cos(yaw))
	var oy := op.y
	var out: Array = []
	if kind != BOX:
		var h := maxf(y1 - y0, r * 2.0)   # as tall as collider() builds it
		out = [[true, at + (ex * c.x + ez * c.y) * s, r * s, ex, ez, Vector2.ZERO, oy + (y0 + r) * s, oy + (y0 + h - r) * s]]
	else:
		for q in _parts_or_self():
			out.append([false, at + (ex * q.c.x + ez * q.c.y) * s, 0.0, ex, ez, q.half * s, oy + q.y0 * s, oy + q.y1 * s])
	_pc = out
	_pc_at = op
	_pc_yaw = yaw
	_pc_s = s
	return out


# The clear XZ space between two prisms' CORES — an axis is a point, a box its footprint (negative = they
# overlap); gap_to takes the radii off.
static func _prism_gap(a: Array, b: Array) -> float:
	if a[0] and b[0]:
		return (a[1] as Vector2).distance_to(b[1])
	if a[0] or b[0]:
		return _rect_gap(a[1] if a[0] else b[1], b if a[0] else a)
	# two rectangles: apart along any of their four axes (separating axis), or touching
	for ax in [a[3], a[4], b[3], b[4]]:
		if _proj_apart(a, b, ax):
			var best := INF
			for v in _corners(a):
				best = minf(best, _rect_gap(v, b))
			for v in _corners(b):
				best = minf(best, _rect_gap(v, a))
			return best
	return -0.01


# The clear space from the point `p` to a box prism's footprint (gap()'s convention: -0.01 inside).
static func _rect_gap(p: Vector2, bx: Array) -> float:
	var d: Vector2 = p - (bx[1] as Vector2)
	var hx := float((bx[5] as Vector2).x)
	var hz := float((bx[5] as Vector2).y)
	var q: Vector2 = (bx[1] as Vector2) + (bx[3] as Vector2) * clampf(d.dot(bx[3]), -hx, hx) + (bx[4] as Vector2) * clampf(d.dot(bx[4]), -hz, hz)
	return p.distance_to(q) if q.distance_squared_to(p) > 1e-10 else -0.01


# A box prism's four footprint corners.
static func _corners(bx: Array) -> Array:
	var cc: Vector2 = bx[1]
	var hx: Vector2 = (bx[3] as Vector2) * (bx[5] as Vector2).x
	var hz: Vector2 = (bx[4] as Vector2) * (bx[5] as Vector2).y
	return [cc + hx + hz, cc + hx - hz, cc - hx + hz, cc - hx - hz]


# Do the two rectangles' shadows on the axis `ax` (unit) miss each other?
static func _proj_apart(a: Array, b: Array, ax: Vector2) -> bool:
	var lo := INF
	var hi := -INF
	for v in _corners(a):
		lo = minf(lo, v.dot(ax))
		hi = maxf(hi, v.dot(ax))
	var lo2 := INF
	var hi2 := -INF
	for v in _corners(b):
		lo2 = minf(lo2, v.dot(ax))
		hi2 = maxf(hi2, v.dot(ax))
	return hi < lo2 or hi2 < lo
