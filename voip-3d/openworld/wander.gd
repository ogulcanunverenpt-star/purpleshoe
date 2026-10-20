class_name WanderAgent extends Node3D
## CROWD LOCOMOTION — makes a populated character (a Meshy/library person) WALK instead of standing still: it
## strolls to a random target within a radius of its home, pauses, picks a new one — following the terrain, facing
## its heading, and playing its WALK clip while moving / IDLE while paused (so a `populate` cast reads as a LIVING
## crowd, not statues). Cheap: pure transform movement (no physics body), but COLLISION-AWARE: two short raycasts (a
## torso ray + a shin ray, so LOW props the torso ray flies over are still caught) validate each stroll target and
## probe ahead while walking, so agents route around solid objects instead of clipping through them (colliderless
## worlds: rays hit nothing -> behaviour identical to before). Movement ticks
## in _physics_process because space-state queries are only valid there. The model is a child of this node;
## `setup()` wires it. Used by chunk_manager when a `populate` entry sets behaviour:"wander".

const RAY_H := 1.0          # torso obstacle ray flies ~1m above the ground (over kerbs, under archways)
const LOW_RAY_H := 0.35     # shin ray — catches low props (~0.5m planters/crates) the torso ray flies clean over, yet still clears kerbs (~0.1-0.3m)
const PROBE_AHEAD := 1.5    # while walking, look this far ahead for something solid
const PROBE_EVERY := 0.6    # seconds between forward probes (cheap: <=2 rays per probe, torso ray short-circuits ~3-4 rays/s per moving agent)
const PICK_TRIES := 6       # target resamples before giving up and idling in place
const RESEAT_AFTER := 3     # consecutive fully-blocked picks before the agent gives up on `home` and adopts where it stands
# ALARM — the crowd reacting to violence near it. See alarm() / assault() / MOOD.
enum { MOOD_CALM, MOOD_FLEE, MOOD_COWER, MOOD_CONFRONT, MOOD_HOSTILE }
## WHAT WALKING INTO SOMEBODY DID — shove() and InteractionSystem.shove_npc() return it. NONE = the
## grace window swallowed it; BUMP = it landed and cost only the cheap currency; ASSAULT = it was the
## BUMP_AT-th bump, which counted as one assault (and assault() has already told the world). NONE
## stays first (0), so `if agent.shove(...)` still reads "did it land".
enum Contact { NONE, BUMP, ASSAULT }
const FLEE_TIME := 5.0       # seconds of running before the agent settles back into a stroll
const FLEE_MULT := 2.1       # speed multiplier while fleeing (a scared villager outpaces a strolling one)
const FLEE_NEAR := 9.0       # metres to break for when the trouble is close
const FLEE_FAR := 16.0       # ...and when it is right on top of them
const COWER_TIME := 4.5      # seconds frozen, watching, before nerve returns
const COWER_PANIC := 3.5     # trouble closer than this and nobody freezes — they run
const CONFRONT_TIME := 7.0   # seconds squared up before backing down
const CONFRONT_KEEP := 2.6   # how close a confronting villager will close before holding
const CONFRONT_MULT := 1.35  # they walk in with purpose, they don't sprint
const CONFRONT_NERVE := 0.68 # adjusted nerve at or above this -> square up
const COWER_NERVE := 0.30    # ...at or below this -> freeze
const NERVE_PERSONAL := 0.20 # it happened TO them: one notch braver (being shoved != hearing a shot)
const NERVE_HARD := 0.15     # ...but it happening right on top of them is one notch more frightening
# ESCALATION — being assaulted repeatedly turns a civilian into a threat. See assault().
# A BUMP IS NOT A BLOW. Shipped 2026-09-23 charging both to one counter, so three contacts — about
# four seconds of walking through a crowded quay — turned a villager hostile. Walking into somebody
# is rude; it is not assault, and it must not buy the same escalation a swung weapon does.
const BUMP_AT := 8           # bumps before the accumulated rudeness counts as ONE assault
const BUMP_FORGET := 12.0    # ...and seconds of being left alone that forgives one bump
const HOSTILE_AT := 3        # STRIKES before a game one fights back
const HOSTILE_TIMID := 2     # ...and how many MORE a timid one absorbs first
const HOSTILE_NERVE := 0.5   # the nerve that divides the two
const HOSTILE_MULT := 1.8    # chase speed multiplier
const HOSTILE_REACH := 1.9   # metres at which they start swinging
const HOSTILE_GIVEUP := 34.0 # ...and at which they lose you (they stay angry — `assaults` is not reset)
const HOSTILE_DMG := 6.0     # per-swing damage, well under an enemy's 9
# NOBODY DEALS DAMAGE THEY CANNOT SHOW. Shipped 2026-09-23 calling take_damage straight after
# _play(_idle) — and not one wander model in a real world has an attack clip, so the player's health
# fell while a villager stood in an idle pose. A civilian who cannot swing SHOVES instead: physical,
# readable, needs no clip, and costs the player position rather than health.
const FLINCH_TIME := 0.75    # seconds of the recoil a struck person shows
const FLINCH_TILT := 0.62    # radians (~36 deg) they reel back through at its peak
const HOSTILE_PUSH := 3.4    # metres/sec of shove a clipless civilian delivers instead of damage
const HOSTILE_CD := 1.1      # seconds between swings
const SHOVE_DIST := 0.9      # metres a shoved person is pushed
const SHOVE_TIME := 0.45     # ...over this long
const SHOVE_GRACE := 1.2     # a shove cannot re-land inside this, so LEANING on someone is one push, not sixty
const BLOW_KICK := 1.9       # a blow throws them at this many shoves' speed...
const BLOW_HOLD := 1.6       # ...for this many SHOVE_TIMEs: 2.7 m (people rig: 2.79)
const SHOT_KICK := 1.0       # a shot staggers them a bump's push instead: 0.9 m over SHOVE_TIME (see assault)
# ROOTED — a `populate` character the world authored as behaviour:"static". See `rooted`.
const ROOTED_SHOVE := 0.3    # fraction of SHOVE_DIST they give when pushed (they hold their ground)
const ROOTED_RETURN := 1.1   # m/s they walk back onto their mark afterwards
# PERSONAL SPACE — how close a crowd member's own motion may carry it to the player. See _clear_of_player.
const PLAYER_RADIUS := 0.4   # main.gd _build_player: the player's capsule
const SPACE_SKIN := 0.02     # ...and a hair more, so standing next to someone is touching, never overlapping

var terrain: GTerrain = null
var home: Vector2 = Vector2.ZERO
var radius := 6.0
var speed := 1.6
var _target: Vector2
var _pause := 0.0
var _probe := 0.0
var _fresh := true          # initial target not picked yet — deferred to the first physics tick (rays need physics)
var _anim: AnimationPlayer = null
var _walk := ""
var _swim := ""                 # swim/tread clip (empty -> GPose.swim fallback)
var _water_level := -1e9        # world water surface (-1e9 = no water block); passed from the spawner
var _aquatic := false           # true -> rides ANY water (fish/croc); false -> floats only when forced in
var _in_water := false          # last-frame float state (for the water->land GPose.stand transition)
var _idle := ""
var _relaxed := false           # the procedural stand is on (no idle clip) — any clip _play starts clears it
var _walk_phase := 0.0           # procedural-walk gait phase for a CLIPLESS crowd member (no clips -> would slide)
var _rng := RandomNumberGenerator.new()
var _exclude: Array[RID] = []   # this agent's own colliders — never mistake yourself for an obstacle
var _blocked_rounds := 0        # consecutive _pick_target failures — drives the escape escalation
## WHO THIS PERSON IS, 0..1 — rolled ONCE from the spawn seed and never re-rolled. A street of
## independent coin flips reads as dice; a street where the fishwife always squares up and the
## clerk always bolts reads as people. Drawn from its own generator so `_rng`'s sequence — and
## therefore every existing stroll pattern — is byte-identical to before this existed.
var nerve := 0.5
var mood := MOOD_CALM
var _mood_t := 0.0              # seconds left in the current mood; 0 -> back to a stroll (HOSTILE never expires)
var _threat := Vector2.ZERO     # where the trouble was, in XZ
var assaults := 0               # times THIS person has been STRUCK — the escalation counter
var bumps := 0                  # ...and walked into, which is a different and much cheaper thing
var shoves := 0                 # every contact that LANDED, ever (never decays; `bumps` is the debt that fades)
var npc_id := ""                # who this person is to the rules and the grudge book (chunk_manager's person key)
## A PERSON OR A CREATURE — GPose.body_fit's verdict on the model it wraps, which is the humanoid map's (GRig: an upright
## two-legged body with a head on top, read off its bones' names and its skeleton's shape, or a body of parts named as a
## person's, Kenney's); chunk_manager sets it. A hand-built agent, or a model with neither a skeleton nor such parts to
## judge, is a person, as everything was. Read by assault(): a creature struck or shot flinches and runs, and is never
## anybody's civilian.
var person := true
## A CREATURE STANDS ON THE GROUND UNDER ITS FEET, leaned with it by the rule a mount's chassis rests by (GBody.lean_on): set
## upright on its origin, a wandering cow at its natural 1.7 m stood 0.35 m into a 17 deg hillside and 0.72 m into Kestrel Bay's
## canyon wall, a horse 0.35 and 0.73 (step 5c; followups3's hoof-crest measured 0.23 and 0.47 at the 2 m it was drawn then).
## Its MODEL leans, under the agent — a flinch (rotation.x) composes over it — and so does its BODY (GBody.set_lean: what a
## shot, the player and a blow meet; its collider with it): drawn leaned on an upright body, a cow's drawing stood 0.23-0.28 m
## out of it on a 17 deg grade (step 5c's review). Its rays stay the agent's own. Level in the water. A PERSON STANDS UPRIGHT
## — leaned with the slope a villager stood 17 deg off plumb (hoof-crest C3). What a rigid body on four feet cannot do is
## left: a hoof 10-22 cm off a sharp crest, until a herd has feet of its own (GFeet's cost on a phone, measured on a ridden
## mount first).
var _model: Node3D = null       # the model it leans (its first child that draws) and the transform it was built with
var _model_rest := Transform3D()
## A PERSON STANDS ON THE GROUND IN EVERY CLIP (step 5d): populate grounds a person by its rest pose, and every clip carries its
## own ground — walking, a Meshy villager's soles stood 4.6-6.5 cm over flat ground and the warden's 6.2-9.1, a troll's 5.2-15.7
## into it; standing, a smuggler's idle 5.5 cm over it. `ground` is its fit's (GPose's: chunk_manager sets it), and the model
## stands with what its clip draws lowest on the ground under its feet (GPose.ground_rise): its walk by its phase every tick it
## walks — the phase the frame will draw, a tick on (read where it was drawn, a troll's walk stood 1.7 cm deeper) — anything
## else by its lowest moment, once, as it starts (a rooted person does not tick). Afloat, and in a procedural pose, as its rest.
var ground := {}
var _gmodel: Node3D = null      # the person's model it stands on its ground
var _stance: Array = []         # what its feet stand on (GBody.stance); [] (a person, or nothing to stand on): upright
var _hc := {}                   # the ground's lattice heights its lean read (GTerrain.height_cached)
var _bump_forget := 0.0         # seconds until the next bump is forgiven
var _nap: SceneTreeTimer = null # a sleeping rooted person's forgiveness clock (see _nap_begin)
var _nap_len := 0.0             # ...and what it was wound to
var _flinch := 0.0             # seconds left of the procedural recoil (see the note on assault)
var target_player: Node3D = null  # who they chase once hostile (chunk_manager wires it at spawn)
var world: Node = null            # main — the `take_damage` door an enemy already uses
var _atk := ""                  # attack clip name, "" when this rig has none
var _atk_cd := 0.0
var _stagger := 0.0             # seconds of being knocked back; overrides the stroll entirely
var _shove_v := Vector2.ZERO
var _shove_cd := 0.0
## STANDING THEIR GROUND ON PURPOSE. `populate` defaults to behaviour:"static", and that is an
## authored decision — a stall holder behind their stall, a sentry on their mark — not an oversight
## to correct by making them stroll. But "does not walk" was implemented as "has no script", so
## these people had no way to answer anything that happened to them: once the crowd became solid
## you could walk into one and be stopped by what was, as far as the game was concerned, a statue.
##
## A rooted agent gets the reaction an ANCHORED NPC gets and for the same reason — turn, watch,
## flinch, and return to the spot they were put on. It never strolls, never flees and never turns
## hostile, so the author's meaning survives intact.
##
## It also does not TICK: physics processing is off while calm and switched on only for the few
## seconds a reaction lasts, so a market square of thirty standing extras costs what it always did.
var rooted := false
## THE BODY THIS AGENT STANDS IN — the GBody chunk_manager built from what the model draws
## (GPose.body_fit). Everything that asks "where does this person or creature end" reads it: personal
## space, the turn guard, the probe and wall rays, the hostile reach, the push direction, and main /
## chunk_manager when the player walks into or strikes it — through the delegates below, read through
## this agent's own transform (GCast.vary's scale included). A hand-built agent that never calls
## set_body stands in the crowd's calibrated person, on its origin.
var body: GBody = GBody.round(GBody.CROWD_RADIUS, GBody.CROWD_HEIGHT).owned_by(self)


## Take the body the spawner built (null = none: walk-through). Call before setup(), like `rooted`.
func set_body(b: GBody) -> void:
	body = (b if b != null else GBody.new()).owned_by(self)


## The point of this body's footprint closest to `p` (XZ), with the agent at `at` facing `yaw` (GBody.nearest).
func body_point(p: Vector2, at := Vector2(INF, INF), yaw := NAN) -> Vector2:
	return body.nearest(p, at, yaw)


## Clear space between the body's footprint and the point `p`; negative = inside it (GBody.gap).
func _body_gap(p: Vector2, at: Vector2, yaw: float) -> float:
	return body.gap(p, at, yaw)


## How far `p` is from this body, in the unit every reach in the crowd was tuned in: a person's centre
## distance (GBody.reach).
func reach_to(p: Vector2, at := Vector2(INF, INF), yaw := NAN) -> float:
	return body.reach(p, at, yaw)


## How far the body reaches from the agent's origin in XZ direction `d` (GBody.support).
func _body_reach(d: Vector2) -> float:
	return body.support(d)


func setup(t: GTerrain, home_xz: Vector2, r: float, spd: float, seed_i: int, water_level := -1e9, aquatic := false) -> void:
	terrain = t
	home = home_xz
	radius = maxf(1.0, r)
	speed = maxf(0.2, spd)
	_water_level = water_level
	_aquatic = aquatic
	_rng.seed = seed_i
	# Own generator, deliberately: drawing `nerve` from `_rng` would shift every subsequent target
	# draw and re-shuffle the stroll of every crowd in every world.
	var nrng := RandomNumberGenerator.new()
	nrng.seed = seed_i ^ 0x5bf03635
	nerve = nrng.randf()
	_anim = _find_anim(self)
	var lc := life_clips(_anim)
	_walk = lc["walk"]
	_atk = lc["attack"]
	_idle = lc["idle"]
	_swim = lc["swim"]
	_collect_own_bodies(self)
	_model = null
	_stance = []
	_gmodel = null
	if person and not ground.is_empty():
		for c in get_children():
			if c is Node3D and not (c is CollisionObject3D):
				_gmodel = c as Node3D
				break
	if not person:
		for c in get_children():
			if c is Node3D and not (c is CollisionObject3D):
				_model = c as Node3D
				_model_rest = _model.transform
				_stance = GBody.stance(_model, self)
				break
	_lean()
	_target = home_xz
	_fresh = not rooted            # a rooted agent never picks a stroll target
	set_physics_process(not rooted)
	# A ROOTED PERSON STILL BREATHES. The only thing that ever started a clip on one was
	# _rooted_tick, and that runs only once something happens to them — so every standing extra in
	# a populated square stood in its imported pose, arms out (people rig: 0 of 6 static villagers
	# playing, hand 0.03-0.06 m below the shoulder), until the player shoved them. GLTF scenes do not
	# autoplay and nothing in populate plays anything, so it happens here, once. The clip loops on the
	# AnimationPlayer's own process: the physics tick stays off, so the price of a standing extra is
	# its idle animation — what a paused walker has always paid — and nothing more.
	if rooted:
		_idle_pose()


func _physics_process(delta: float) -> void:
	if _shove_cd > 0.0:
		_shove_cd -= delta
	if bumps > 0:
		_bump_forget -= delta
		if _bump_forget <= 0.0:
			bumps -= 1
			_bump_forget = BUMP_FORGET
	# THE FLINCH, DRIVEN NOT PLAYED.
	#
	# "Can characters react when they get hit, with animations?" — they can react; they cannot be
	# ANIMATED into it, because not one wander model in a Meshy cast ships a hit clip (they carry
	# [idle, walk] and nothing else, the same wall the attack clip hit). So the recoil is driven
	# directly: a reel back through ~14 degrees that eases in and out, on top of the knockback the
	# stagger already gives. rotation.x is free — _face_heading only ever writes rotation.y — so
	# this costs one lerp and composes with whatever clip is playing underneath.
	#
	# A rig that DOES ship a hit/flinch clip should play it instead; that is a one-line
	# GClip.resolve(_anim, "hurt") away and worth doing the moment the cast has one.
	if _flinch > 0.0:
		_flinch = maxf(0.0, _flinch - delta)
		rotation.x = -FLINCH_TILT * sin(PI * (_flinch / FLINCH_TIME))
	if rooted:
		_rooted_tick(delta)
		return
	if _fresh:   # first tick after setup: pick the initial target here, where space-state queries are legal
		_fresh = false
		_pick_target()
	if _atk_cd > 0.0:
		_atk_cd -= delta
	# KNOCKED BACK. A shove is not a new destination — it is half a second of being moved by somebody
	# else — so it owns motion outright rather than arguing with the stroll for it.
	if _stagger > 0.0:
		_stagger = maxf(0.0, _stagger - delta)
		var sp := Vector2(position.x, position.z) + _shove_v * delta
		_advance(sp, (_threat - sp).normalized(), delta)   # stagger back but keep your eyes on them
		return
	if mood == MOOD_HOSTILE:
		_hostile_tick(delta)
		return
	if _mood_t > 0.0:
		_mood_t = maxf(0.0, _mood_t - delta)
		if _mood_t <= 0.0:
			mood = MOOD_CALM
			_pick_target()   # the fright is over — resume a stroll from wherever it left them
	# FROZEN AND WATCHING. Not every person runs: some stand rooted and stare, which is the reaction
	# that makes a street read as a street rather than a flock. They still face the trouble, so it is
	# legible as fear and not as a stuck agent — the failure mode this whole file has fought.
	# ...and turned where it stands, it stands on the ground the way it now faces (_turned).
	if mood == MOOD_COWER:
		_idle_pose()
		if _face_heading((_threat - Vector2(position.x, position.z)).normalized(), delta):
			_turned()
		return
	if _pause > 0.0:
		_pause -= delta
		_idle_pose()
		return
	var here := Vector2(position.x, position.z)
	var to := _target - here
	var dist := to.length()
	if dist < 0.4:
		# SQUARED UP. A confronter that reached its stand-off holds it and stares for the rest of the
		# mood, instead of treating the spot it picked as one more stroll waypoint and walking on.
		if mood == MOOD_CONFRONT and _mood_t > 0.0:
			_idle_pose()
			if _face_heading((_threat - here).normalized(), delta):
				_turned()
			return
		_pause = _rng.randf_range(1.5, 4.5)   # arrived -> idle a beat, then a new target
		_pick_target()
		return
	var dir := to / dist
	_probe -= delta
	if _probe <= 0.0:
		_probe = PROBE_EVERY
		# PROBE_AHEAD OF THE NOSE, NOT OF THE MIDDLE. A 5 m raptor's nose is 2.7 m ahead of its origin,
		# so a 1.5 m probe never left its own body: it walked its nose into the wall, the step test in
		# _advance held it there, and nothing ever rerouted it — walking in place against masonry
		# (people rig: 279 of 360 frames).
		if _blocked(here, here + dir * (PROBE_AHEAD + _body_reach(dir))):   # something solid moved into the path -> reroute now
			_pick_target()
			return
	_advance(here + dir * speed * _mood_mult() * delta, dir, delta)


## ONE STEP, wherever the mood is taking them: terrain height, the water float/swim pose, the clip,
## the clipless stride and the damped facing. Shared with the hostile chase so an angry villager who
## follows you into the harbour swims like everyone else instead of marching along the seabed — a
## detail that would have gone straight into a coastal town.
func _advance(np: Vector2, dir: Vector2, delta: float) -> void:
	# Round the player first, then the wall test below judges the step that is actually taken — a
	# slide round somebody's shoulder must not become a slide through the harbour office.
	np = _clear_of_player(Vector2(position.x, position.z), np)
	# WALLS APPLY TO EVERY KIND OF MOTION, NOT JUST THE STROLL.
	#
	# This wrote `position` outright. The stroll was safe because _pick_target only ever chooses a
	# destination with a clear line to it — but a SHOVE, a flee, a confront and a chase all move the
	# agent without asking anything, so a pushed villager walked straight through the harbour office.
	# One short ray over the step about to be taken covers all four, and costs a ray only while the
	# agent is actually moving (a calm one on its mark does not reach here). It runs to where the
	# BODY will end, not its middle: from there, a horse knocked backwards put its rump 0.92 m into
	# the wall before the ray reached it (people rig).
	var cur := Vector2(position.x, position.z)
	if np.distance_squared_to(cur) > 1e-6 and _blocked(cur, np + (np - cur).normalized() * _body_reach(np - cur)):
		np = cur     # hold position this frame; the mood that wanted the move keeps its timer
	var g := _ground(np.x, np.y)
	# WATER: float at the surface with a swim/tread pose in deep water instead of walking the seabed or
	# sinking out of view; a land animal floats only when forced in, an aquatic one rides any water.
	var st := GWater.float_state(_water_level, g, position.y, (0.0 if _aquatic else 0.6), 0.4)
	if bool(st["float"]):
		position = Vector3(np.x, float(st["y"]), np.y)
		if not _in_water:
			_enter_water()
		elif _swim != "":
			_play(_swim)
	else:
		if _in_water and _swim == "":
			GPose.stand(self)
		position = Vector3(np.x, g, np.y)
		if _walk != "":
			_play(_walk)
			_lift(_walk, true)
		else:
			# NO WALK CLIP (clipless, or a rig whose clips all name something else — a seated-only
			# character cast into a wander crowd): a procedural stride over the relaxed stand, never a
			# glide in whatever clip happened to be playing.
			_stand_procedural()
			_walk_phase += delta * (3.0 + speed * 2.0)
			GPose.walk(self, _walk_phase)
	_in_water = bool(st["float"])
	_face_heading(dir, delta)   # face the heading, DAMPED (deadzone + lerp — see _face_heading)
	_lean()


## A creature's model, and its body, onto the ground under its stance where it stands and faces now (GBody.lean_on); level in
## the water.
func _lean() -> void:
	if _model == null or _stance.is_empty():
		return
	var l := Transform3D.IDENTITY if _in_water else GBody.lean_on(self, terrain, _hc, _stance)
	_model.transform = l * _model_rest
	body.set_lean(l)


## TURNED WHERE IT STANDS, IT STANDS ON THE GROUND IT NOW FACES: a creature's lean is read for a heading (_lean: frozen and turned
## 87 deg on a 17 deg grade, a cow kept the lean it walked up with, 0.22-0.23 m into the grade for all of COWER_TIME — step 5c's
## re-check), and on a grade so is a person's lift (_lift: its feet reach other ground turned — a villager turned 90 deg there
## stood its idle's foot about 4 cm into it, step 5d's review).
func _turned() -> void:
	if person:
		_lift(String(_anim.current_animation) if _anim != null else "", false)
	else:
		_lean()


## PERSONAL SPACE: a crowd member's own motion never carries it INTO the player.
##
## The rays in _blocked do see the player (L_PLAYER), but only along the step's centre line, so
## they stop the agent's CENTRE at the player's capsule surface, 0.4 m out — by which point the
## agent's own capsule is buried in the player's. The crowd body is kinematic, so nothing refuses
## that overlap: the player's move_and_slide depenetrates the PLAYER, every tick, even standing
## still, and an idle player is carried off by whoever walks through them. The people rig measured
## 0.421 m of drag (closest 0.692 m) from one villager fleeing at 3.15 m/s through the forward
## probe's 0.6 s blind interval.
##
## So a step that would end inside the two radii keeps only its tangential part: the agent slides
## round the player instead of into them, and a step aimed dead at them becomes a hold until the
## forward probe reroutes. A step that does not bring it CLOSER is always allowed, so somebody the
## player walked into is never pinned there. Measured from the BODY, not the origin (GBody.clear_step).
func _clear_of_player(cur: Vector2, np: Vector2) -> Vector2:
	if target_player == null or not is_instance_valid(target_player) or not target_player.is_inside_tree():
		return np
	var tp: Vector3 = target_player.global_position
	return body.clear_step(cur, np, Vector2(tp.x, tp.z), PLAYER_RADIUS + SPACE_SKIN)


# DAMPED heading — mirrors enemy.gd `_face` (deadzone + lerp_angle). For a FIXED stroll target this is a
# near-no-op (the heading barely changes tick-to-tick), just a smoother pivot on direction changes. The reason
# it's here at all: if a game ever RETARGETS a WanderAgent to a MOVING target (an NPC that follows/flees the
# player), a moving target makes `dir` chatter every tick — the old hard `rotation.y = atan2(...)` would then
# kick the yaw a few degrees each frame and a skinned mesh lever-arm-amplifies that into a visible buzz (the
# exact creature-jitter enemy.gd cured with direct-chase + this same filter). `dir2` is a normalized XZ vector;
# `dir2.y` is the z-component (model -Z forward — SAME yaw the old atan2(dir.x, dir.y) produced, so facing is
# unchanged, only filtered). True when it turned (a caller that turns in place reads its lean again: _lean).
func _face_heading(dir2: Vector2, delta: float) -> bool:
	if dir2.length() < 0.05:
		return false
	var tgt := atan2(dir2.x, dir2.y)
	if absf(wrapf(tgt - rotation.y, -PI, PI)) < 0.05:
		return false   # ~2.9deg deadzone: already facing -> don't re-snap to sub-degree bearing noise
	var ny := lerp_angle(rotation.y, tgt, minf(1.0, 12.0 * delta))
	# A LONG BODY SWEEPS WHEN IT TURNS. A round one does not, so people always may — and never pay for
	# the player's position (asking turn_ok anyway cost a turning person +53% a tick, 0.65 -> 1.00 us). A
	# horse pivoting beside the player swung its head through them and carried them 0.36 m (people rig):
	# hold a turn step that would bring the body onto the player and closer than it is now (GBody.turn_ok)
	# — the same "never closer" rule _clear_of_player applies to steps. The reaction still plays; only
	# the facing waits.
	if body.kind == GBody.BOX and target_player != null and is_instance_valid(target_player) and target_player.is_inside_tree():
		var tp: Vector3 = target_player.global_position
		if not body.turn_ok(Vector2(position.x, position.z), rotation.y, ny, Vector2(tp.x, tp.z), PLAYER_RADIUS + SPACE_SKIN):
			return false
	rotation.y = ny
	return true


# Pick a stroll target the agent can actually reach: resample until the line here->candidate is clear of solid
# colliders (up to PICK_TRIES rays); every direction blocked -> idle in place and retry after the pause. Raycasts,
# so physics-tick only — every caller is on a _physics_process path.
#
# THE 3.4x DISAGREEMENT — why target selection ignores the shin ray.
# The PLAYER steps over anything up to `STEP_MAX` = 1.2 m (main.gd:53, the step-up assist). This agent
# treated anything above `LOW_RAY_H` = 0.35 m as a wall. 1.2 / 0.35 = 3.43, so every prop in the
# 0.35-1.2 m band — the band the shin ray's own comment names, "~0.5m planters/crates" — is a floor
# to the player and a wall to the crowd. In a dressed harbour town that band is where the crates,
# barrels, benches, bollards and lobster pots are, so a villager could be ringed by scenery the
# player walks straight over, veto every candidate, and stand still forever.
#
# Splitting the two uses fixes it without giving the agent a step-up it has no body for:
#   - CHOOSING a destination ignores the shin ray, so knee-high dressing cannot veto a whole
#     direction and box the crowd in.
#   - The forward PROBE while walking keeps it, so the agent still refuses to walk into a crate and
#     reroutes when one is in the way.
# "Can I eventually get there" and "is something right in front of me" are different questions and
# were being answered by the same ray.
func _pick_target() -> void:
	var here := Vector2(position.x, position.z)
	# ESCALATE WHEN BLOCKED, INSTEAD OF RE-ROLLING THE SAME SIX RAYS FOREVER.
	#
	# Every candidate used to be drawn around HOME. If home stopped being reachable from where the
	# agent stands — spawned inside a building, walled off by a structure that streamed in, nudged
	# behind a prop — all six rays failed, the agent idled, and on the next attempt it drew six more
	# candidates around the SAME unreachable home and failed identically. Nothing in the loop could
	# ever change the outcome, so the agent stood still permanently with its idle clip looping.
	# That is the "NPCs are not moving anything but have that animation" report.
	#
	# So: first failure -> sample around HERE at a reduced radius (find any open ground nearby);
	# second -> shrink further, because a tight interior only admits short hops; and after
	# RESEAT_AFTER consecutive failures, accept that home is gone and adopt the current position as
	# home. An agent that has genuinely been sealed into a 1 m box still cannot move — but that is a
	# placement bug, and the spawn-side footprint rejection in chunk_manager is what prevents it.
	var origin := home
	var rad := radius
	if _blocked_rounds == 1:
		origin = here
		rad = maxf(1.5, radius * 0.6)
	elif _blocked_rounds >= 2:
		origin = here
		rad = maxf(1.0, radius * 0.3)
	for _try in PICK_TRIES:
		var ang := _rng.randf() * TAU
		var rr := sqrt(_rng.randf()) * rad   # uniform over the disc
		var cand := origin + Vector2(cos(ang) * rr, sin(ang) * rr)
		# TORSO RAY ONLY FOR TARGET SELECTION — see THE 3.4x DISAGREEMENT below.
		if not _blocked(here, cand, false):
			_target = cand
			_blocked_rounds = 0
			return
	_blocked_rounds += 1
	if _blocked_rounds >= RESEAT_AFTER:
		home = here          # home is unreachable — wander from where we actually are
		_blocked_rounds = 0
	_target = here
	_pause = _rng.randf_range(1.5, 4.5)   # boxed in -> stand a beat, then try again WIDER


# TRUE when a solid collider sits between XZ points `a` and `b`. Sampled at TWO heights above the terrain: the torso
# ray (RAY_H) clears kerbs/steps and passes under archways; the shin ray (LOW_RAY_H) catches low props the torso ray
# would fly clean over. Blocked if EITHER hits (the torso ray short-circuits, so a clear path costs 2 rays, a wall 1).
# Space-state access — only valid during _physics_process. Colliderless worlds: intersect_ray returns an EMPTY
# Dictionary (never an error), so both rays are FALSE and behaviour matches the pre-collision build.
func _blocked(a: Vector2, b: Vector2, low := true) -> bool:
	var w := get_world_3d()
	if w == null:
		return false
	var ss := w.direct_space_state
	var ga := _ground(a.x, a.y)
	var gb := _ground(b.x, b.y)
	if _ray_solid(ss, a, ga, b, gb, RAY_H):
		return true
	return low and _ray_solid(ss, a, ga, b, gb, LOW_RAY_H)


# One height sample of _blocked: is a solid body between `a` and `b` at height `h` above each end's terrain?
func _ray_solid(ss: PhysicsDirectSpaceState3D, a: Vector2, ga: float, b: Vector2, gb: float, h: float) -> bool:
	var from := Vector3(a.x, ga + h, a.y)
	var dest := Vector3(b.x, gb + h, b.y)
	var q := PhysicsRayQueryParameters3D.create(from, dest)
	# THE WORLD LAYER ONLY (a projectile's ray is the opposite case: it is asking which BODY it meets,
	# people included). These rays mean "is there scenery in the way"; on the default all-layers mask they
	# also answer "is there a PERSON in the way", and once the crowd became solid that made a market
	# square self-jamming: every agent vetoes every direction that has somebody standing in it, and a
	# crowd dense enough to be worth calling a crowd never moves again. Routing around people is what
	# the forward probe and the re-home escalation are for; it is not the terrain question.
	# L_WORLD *and* L_PLAYER (main.gd: 1 and 2). The world half is the narrowing described above.
	# The player half is what lets the crowd be SOLID again without jamming anybody: an agent that
	# treats the player as an obstacle walks around them instead of into them, which is the contact
	# that used to wedge the movement solver. Crowd-on-crowd is still excluded — that is the market
	# square self-jam this comment exists to prevent.
	q.collision_mask = 1 | 2
	q.exclude = _exclude
	return not ss.intersect_ray(q).is_empty()


# The wrapped model may carry its own collider (populate `collider` option / the solid-by-default pass) — collect
# every CollisionObject3D under this node so the agent's rays skip its own body.
func _collect_own_bodies(n: Node) -> void:
	if n is CollisionObject3D:
		_exclude.append((n as CollisionObject3D).get_rid())
	for c in n.get_children():
		_collect_own_bodies(c)


## The ground under this person.
##
## REVERTED 2026-09-24, same day, after it shipped and floated the crowd. It briefly asked the
## streamer for `surface_y`, to fix a report that the whole cast stands too low. That lookup answers
## "the HIGHEST floor plate whose FOOTPRINT RECTANGLE contains this point" — which is the right
## question for a prop an author placed inside a room, and the wrong one for a person who walks.
## A villager strolling anywhere within a multi-storey building's footprint, including outside its
## walls, was lifted to its top floor: a strip of harbour standing in mid-air with people and a lamp
## on it.
##
## The report it was meant to fix said ALL characters look sunk, everywhere. Out on open terrain
## these two functions return the same number, so a plate-versus-terrain gap could never have
## explained "all" — the contradiction was in the report and the fix was written anyway. The real
## cause is still open.
func _ground(x: float, z: float) -> float:
	return terrain.height(x, z) if terrain != null else 0.0


func _play(clip: String) -> void:
	if _anim == null or clip == "":
		return
	_relaxed = false
	if _anim.current_animation != clip:
		var a := _anim.get_animation(clip)
		if a != null:
			a.loop_mode = Animation.LOOP_LINEAR
		_anim.play(clip)
		_lift(clip, false)


## A person's model stood on the ground under its feet in what `clip` draws (`ground`: GPose.ground_rise, at the phase the next frame
## draws when `phased`) — the terrain's, standing on it; anything else it stands on (a deck, a floor), level where it stands —
## and afloat as its rest stands on it.
func _lift(clip: String, phased: bool) -> void:
	if _gmodel == null or not is_inside_tree():
		return
	if _in_water:
		_gmodel.position.y = -float(ground["rest"]) * _gmodel.scale.y
		return
	var at := 0.0
	var span := 0.0
	if _anim != null:
		at = _anim.current_animation_position + get_physics_process_delta_time() * _anim.get_playing_speed()
		span = _anim.current_animation_length
	var m := _gmodel.transform
	m.origin.y = 0.0
	var gp := global_position
	var r := GPose.ground_rise(ground, clip, phased, at, span, Transform3D(Basis(Vector3.UP, global_rotation.y).scaled(Vector3.ONE * global_basis.get_scale().y), gp),
		m, terrain, _hc, gp)
	if is_finite(r):
		_gmodel.position.y = r


## STANDING STILL — the idle clip, or (none that qualifies) the procedural stand. Every branch that
## holds a person in place comes through here, so none of them can undo the tread: they each called
## _play(_idle) directly, and a floater that paused mid-swim stood up in its standing idle on the
## water (people rig, pre-GClip: villager_man playing "idle" in 58 of 58 deep-water samples, the
## smuggler "attack" and "idle" 29 each, pub_regular "idle_sitting" 58).
func _idle_pose() -> void:
	if _in_water:
		return
	if _walk == "":
		GPose.walk_stop(self)   # a procedural stride returns its legs to the stand
	if _idle != "":
		_play(_idle)
	else:
		_stand_procedural()


## The relaxed stand for a rig with no idle clip (GPose.stand_relaxed): nothing left playing, arms down.
## The rest pose of every Meshy/KayKit person is a T-pose, so "no clip" must never mean "rest pose".
## Once per stand — _play clears the flag the moment a real clip takes the body back.
func _stand_procedural() -> void:
	if _relaxed:
		return
	_relaxed = true
	GPose.stand_relaxed(self)
	_lift("", false)


## Into deep water: the swim clip, or GPose.tread — the idle held and leaned into a tread (the relaxed
## stand when there is no idle). Never a walk frame frozen mid-stride, never the rest pose, never a
## standing clip left playing upright on the surface.
func _enter_water() -> void:
	if _swim != "":
		GPose.walk_stop(self)
		_play(_swim)
		_lift("", false)
		return
	_relaxed = _idle == ""
	GPose.tread(self, _idle)
	_lift("", false)


## WHAT THIS PERSON PLAYS, by role — {walk, attack, idle, swim}. The ONE lookup: setup() assigns it,
## and the body the spawner fits to the model (fit_clips -> GPose.body_fit) is measured over the same
## answer, so a body can never be fitted to clips the agent does not play (nor to the attack, which no
## posed body plays: fit_clips).
static func life_clips(ap: AnimationPlayer) -> Dictionary:
	var c := {"walk": "", "attack": "", "idle": "", "swim": ""}
	if ap == null:
		return c
	# ONE RESOLVER (clip_role.gd), AND NO FALLBACK TO A CLIP THAT NAMES SOMETHING ELSE. These
	# used to settle for the rig's FIRST clip, alphabetically: a smuggler that ended up in the
	# harbour looped "attack" as its swim, a villager floated upright in its standing "idle", and a
	# pub regular (only clip: idle_sitting) stood and strolled in an invisible chair. "" now means
	# "this rig cannot show that role", and the procedural pose (GPose) owns it.
	c["walk"] = GClip.resolve(ap, "walk")
	# Whether this person can SWING. Empty for every villager in a Meshy cast, which is exactly
	# why the damage path in _hostile_tick has to ask. The lookup that settled for clips[0] gave a
	# Kestrel Bay villager shipping [idle, walk] _atk = "idle": the _hostile_tick gate saw an attack
	# clip, played idle and took 6 HP every 1.1 s — the 2026-09-23 defect (people rig: hp 76.0 after
	# four "swings" in an idle pose). GClip never settles, and a clip that also names a hurt, a block
	# or a throw ("Melee_Block_Hit", "Throw") is not a swing either.
	c["attack"] = GClip.resolve(ap, "attack")
	c["idle"] = GClip.resolve(ap, "idle")
	c["swim"] = GClip.resolve(ap, "swim")
	# A CREATURE THAT ONLY SWIMS OR FLIES — a library fish ships [Swim], a bat [Flying, Attack,
	# Death, Hit] — has no standing pose to hold: swimming or flapping in place IS its idle. The
	# first-clip fallback happened to hand a static fish its Swim; without this it froze at rest.
	if c["idle"] == "" and c["walk"] == "":
		c["idle"] = c["swim"] if c["swim"] != "" else GClip.resolve(ap, "fly")
	return c


## The clips a body is fitted over: the ones it is drawn in — idle, walk, and the swim it plays afloat,
## each once. A creature's box has to hold the pose it is actually in, and each of these reaches past
## the rest pose somewhere. NEVER ITS ATTACK: only a person turns hostile and swings (assault()), and a
## person's body is their rest pose (GBody's crowd role poses no person), so an attack clip is a pose
## no crowd body is ever drawn in (decision 3: a creature struck or shot flees). Fitted over it, a herd
## drawn at its natural size stood in its attack's sweep: an Apatosaurus 21.19 m wide where it draws
## 2.53, a Stegosaurus 10.21 where it draws 1.99 (step 4's review).
static func fit_clips(ap: AnimationPlayer) -> PackedStringArray:
	var out := PackedStringArray()
	var lc := life_clips(ap)
	for k in ["idle", "walk", "swim"]:
		var c := String(lc[k])
		if c != "" and not out.has(c):
			out.append(c)
	return out


func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim(c)
		if r != null:
			return r
	return null


## REACT TO TROUBLE NEARBY — a scare, not an injury. chunk_manager.alarm_crowd() fans this out.
##
## This is the crowd half of "NPCs should react like GTA". A villager standing next to someone
## swinging a boat hook should not carry on strolling as if nothing happened — and the thing that
## sells it is not the one you hit, it is the six people around them all reacting at once.
##
## What they DO is `nerve`'s business (see _react): most run, the timid freeze, the bold square up.
## A scare never touches `assaults` — swinging at empty air a hundred times must not turn a town
## hostile. Only something landing ON a person does that, which is what assault() is for.
##
## `hard` = the trouble is close, so it lands harder. Someone already fighting is not scared off by
## it: _react refuses to overwrite HOSTILE.
##
## A CREATURE RUNS FROM A SCARE TOO — it squares up to nobody (see assault). A bold horse that heard
## trouble walked at its source like a person keeping a stand-off, and once every hit was heard 14 m
## round where it landed (main._projectile_hit) that source was the shooter: a herd round a horse shot
## 29 m out came 8 m closer to the rifle in 4 s, all eight (people rig). Its nerve still picks between
## running and freezing.
func alarm(from: Vector2, hard: bool) -> void:
	_threat = from
	_react(hard, false, person)


## IT HAPPENED TO THEM — struck (`how` "strike"), shot ("shot": a projectile met their body,
## main._projectile_hit), or walked into once too often ("shove", from shove()). Returns the running total.
##
## THE COUNTER IS THE WHOLE POINT. A civilian who is hit once is frightened; a civilian who is hit
## four times is an enemy. Without a count, "reaction" is a flinch animation and the world stays
## consequence-free — you can beat a market square all afternoon and every stall holder greets you
## the same way afterwards. With one, violence has a price that the player discovers by paying it.
##
## ...AND THE COUNTER IS WHAT TELLS THE WORLD. `npc_assaulted` fires here, on the blow that counts,
## and `npc_hostile` on the blow that turns them — never from a caller. main used to re-derive "was
## that an assault, did they just cross" at four call sites with three different crossing rules, and
## the shove one reported EVERY bump as an assault with the count unchanged (people rig: 16 bumps ->
## 16 events, counts 0 x7, 1, 1 x7, 2). Here one event per count holds by construction, whichever
## path lands the blow — including the ones that do not exist yet.
##
## Nerve buys patience, not immunity: a timid person absorbs HOSTILE_TIMID more before turning, but
## everyone turns eventually. Being cowed forever would read as broken, not as characterisation.
func assault(from: Vector2, how := "strike") -> int:
	_threat = from
	# Being struck shows on the body whatever it does to the mood — a person who takes a boat hook
	# and does not move reads as broken, and that was true even before they could turn hostile.
	_flinch = FLINCH_TIME
	var away := _push_dir(from)
	if away.length() > 0.01:
		# A STRIKE HITS HARDER THAN A SHOULDER. Being hit throws them further and for longer than
		# being walked into, which is the whole difference the two currencies exist to express —
		# and at the old values a blow and a bump looked identical, so neither read as much.
		# ...AND A SHOT IS NOT A BLOW'S SWEEP. Through this same door an arrow threw its victim the
		# blow's 2.79 m (people rig) — like nothing an arrow does, and out of the line of the next
		# shot. A shot staggers them a bump's push (0.9 m); the flinch and the count are the blow's.
		var shot := how == "shot"
		_shove_v = away.normalized() * (SHOVE_DIST * (ROOTED_SHOVE if rooted else (SHOT_KICK if shot else BLOW_KICK)) / SHOVE_TIME)
		_stagger = maxf(_stagger, SHOVE_TIME * (1.0 if shot else BLOW_HOLD))
	# A CREATURE IS NOT A CIVILIAN. A horse in a herd, a sheep, a shark — anything the humanoid map (GRig,
	# through GPose.body_fit) does not call a person — climbed the same ladder: three arrows turned a bold farm_Horse HOSTILE and it
	# charged the player from 6.78 m to 2.67 m in 4 s, and every arrow fired npc_assaulted, so a game's
	# wanted level (rules.md) counted deer it cannot tell from villagers (a rule cannot read a payload,
	# and a stroller's id is "cell/entry/i"). Struck or shot, a creature flinches, is thrown, and runs or
	# freezes as its nerve has it — never squares up, never turns, and tells the world nothing.
	if not person:
		assaults += 1
		_react(true, true, false)
		return assaults
	# EVERY BLOW COUNTS. This returned before counting once they were hostile, so the 4th and 5th
	# strike on a villager who had turned reported `count` 3, 3 while a rooted one and an anchored NPC
	# kept counting. It is how many times THIS person has been assaulted; it cannot stall mid-beating.
	assaults += 1
	# A ROOTED PERSON NEVER TURNS ON YOU. They cannot chase, so "hostile" would mean a stationary
	# attacker that swings at whoever walks past — a trap in the scenery, not a character. The count
	# still rises, so the `npc_assaulted` event a game builds its own consequences on is identical
	# for both kinds; only the reaction they are physically capable of differs.
	var turns := mood != MOOD_HOSTILE and not rooted and assaults >= HOSTILE_AT + (0 if nerve >= HOSTILE_NERVE else HOSTILE_TIMID)
	if turns:
		mood = MOOD_HOSTILE
		_mood_t = 0.0        # hostility does not time out; only losing you (HOSTILE_GIVEUP) ends the chase
		_pause = 0.0
		_atk_cd = HOSTILE_CD * 0.5   # a beat to close before the first swing
	else:
		_react(true, true)   # a fright — or, for someone already fighting, nothing (see _react)
	fire("npc_assaulted", {"id": npc_id, "how": how, "count": assaults, "hostile": mood == MOOD_HOSTILE})
	if turns:
		fire("npc_hostile", {"id": npc_id, "how": how, "count": assaults})
	return assaults


## The rule layer's funnel: main's director, the same door InteractionSystem.fire uses. This is the
## "touches quests and factions" half — the engine ships no faction model and should not invent one,
## but it owes a world the events, so a world can raise a wanted level, fail a peace quest or close a
## district's shops off the escalation the crowd is already reacting to. check-rule-vocab.mjs reads the
## event names off the fire() calls in this file. Null-safe: a world with no rules, or a crowd with no
## `world` wired (the 3d template's), pays one branch.
func fire(event: String, payload: Dictionary) -> void:
	if world == null or not is_instance_valid(world):
		return
	var d = world.get("director")
	if d != null and d.has_method("fire"):
		d.fire(event, payload)


## WALKED INTO. main._shove_contacts calls this for any crowd member the player walks into, and
## returns what it did (Contact): NONE inside the grace window, BUMP, or ASSAULT on the BUMP_AT-th.
##
## THE GRACE WINDOW IS LOAD-BEARING. Contact is reported every physics tick a body is touched, so
## without it, leaning on somebody would be sixty assaults a second and the entire street would be
## hostile before the player understood they had done anything. One push is one push.
func shove(from: Vector2, strength := 1.0) -> Contact:
	if _shove_cd > 0.0:
		return Contact.NONE
	_shove_cd = SHOVE_GRACE
	shoves += 1
	var away := _push_dir(from)
	if away.length() < 0.01:
		away = Vector2(_rng.randf() * 2.0 - 1.0, _rng.randf() * 2.0 - 1.0)
	_shove_v = away.normalized() * (SHOVE_DIST * (ROOTED_SHOVE if rooted else 1.0) / SHOVE_TIME) * clampf(strength, 0.2, 2.0)
	_stagger = SHOVE_TIME
	# BUMPS ARE THEIR OWN CURRENCY, AND THEY FADE. Being walked into makes somebody react — they
	# stagger, they turn, they may break away — but it is not the thing that makes them fight you.
	# Only when the rudeness is sustained (BUMP_AT of them, faster than BUMP_FORGET can forgive) does
	# it convert into ONE assault, which then escalates on the normal ladder.
	_threat = from
	# PUSHING INTO SOMEONE WHO IS ALREADY FIGHTING YOU IS NOT A NEW PROVOCATION. They are chasing you
	# and you are in their face — that is their fight, not rudeness — so it costs nothing: no bump, no
	# count, no event. Charged like any other contact, every 8th re-reported an assault on a person who
	# was swinging at the player (people rig: counts 4, 5 over 20 s of walking into one).
	if mood == MOOD_HOSTILE:
		return Contact.BUMP
	_nap_end()   # what a rooted person forgave while asleep comes off BEFORE this bump goes on
	bumps += 1
	_bump_forget = BUMP_FORGET
	if bumps >= BUMP_AT:
		bumps = 0
		assault(from, "shove")
		return Contact.ASSAULT
	_react(true, true)   # personal AND close — being walked into is both
	return Contact.BUMP


## Which way a push from `from` moves this body: away from the part of it that was touched. A round
## body is pushed off its centre, exactly as before; a long one square off the flank or rump the player
## met, where "away from its middle" shoved a horse touched at the hindquarters along its own length
## (people rig: 35 deg off the line the player walked in on). From inside the footprint, off the
## middle is all there is.
func _push_dir(from: Vector2) -> Vector2:
	var away := body_point(from) - from
	if away.length() < 0.01:
		away = Vector2(position.x, position.z) - from
	return away


## WHO YOU ARE DECIDES WHAT YOU DO.
##
## One reaction for everybody is what made the first pass read as a flock: the whole street broke in
## the same direction at the same moment, which is an effect, not a crowd. `nerve` is fixed per
## person, so the same villager always answers trouble the same way and the street acquires
## characters — the one who bolts, the one who stands rooted, the one who comes at you.
##
## `personal` (it happened TO them rather than near them) shifts everyone one notch braver, and
## `hard` (it happened right on top of them) one notch more frightened. Both are adjustments to the
## trait, never replacements for it.
##
## A FRIGHT NEVER OVERWRITES A FIGHT. This is the one function that writes a fright mood, so it is
## the one place that refuses to on someone HOSTILE: only losing the player (_hostile_tick —
## HOSTILE_GIVEUP, or no target) ends hostility. The rule used to be a copy in each caller, and the
## caller without one — being walked into — talked a hostile villager down to CONFRONT and then
## CALM: 1024 of 1200 ticks not hostile while the player pressed into them, and npc_hostile fired
## three times for one person as they re-crossed.
##
## `square_up` false: a creature, struck, shot or scared (assault, alarm) — it has no stand-off to keep,
## so the nerve that would square a person up runs it instead (a bold horse closing to 2.6 m reads as a
## charge).
func _react(hard: bool, personal: bool, square_up := true) -> void:
	if mood == MOOD_HOSTILE:
		return
	if rooted:
		# Every mood below is a destination, and a rooted person has none. They get the one reaction
		# that does not contradict standing still: freeze, watch, and (if it was personal) flinch.
		mood = MOOD_COWER
		_mood_t = COWER_TIME
		_nap_end()                  # awake again: the tick takes the forgiveness countdown back
		set_physics_process(true)
		return
	var n := nerve + (NERVE_PERSONAL if personal else 0.0) - (NERVE_HARD if hard else 0.0)
	var here := Vector2(position.x, position.z)
	var away := here - _threat
	if away.length() < 0.01:
		away = Vector2(_rng.randf() * 2.0 - 1.0, _rng.randf() * 2.0 - 1.0)
	away = away.normalized()
	_pause = 0.0
	_blocked_rounds = 0
	_probe = 0.0        # whichever way they go, that path was never validated — re-probe at once
	if square_up and n >= CONFRONT_NERVE:
		mood = MOOD_CONFRONT
		_mood_t = CONFRONT_TIME
		# Close to a stand-off rather than to the threat itself: walking INTO the player would read
		# as an attack, and a confronter is not attacking — that is what hostility is for.
		_target = _threat + away * CONFRONT_KEEP
		return
	# NOBODY FREEZES WITH IT ON TOP OF THEM. Standing rooted reads as nerve at eight metres and as a
	# broken agent at two, so the panic radius overrides the trait.
	if n <= COWER_NERVE and here.distance_to(_threat) > COWER_PANIC:
		mood = MOOD_COWER
		_mood_t = COWER_TIME
		return
	mood = MOOD_FLEE
	_mood_t = FLEE_TIME
	# Jittered per agent so a scattering crowd fans out instead of forming an orderly column, and
	# `home` moves to the destination: someone who fled should then wander where they ended up
	# rather than strolling straight back into the danger they just ran from.
	_target = here + away.rotated(_rng.randf_range(-0.6, 0.6)) * (FLEE_FAR if hard else FLEE_NEAR)
	home = _target


func _mood_mult() -> float:
	match mood:
		MOOD_FLEE:
			return FLEE_MULT
		MOOD_CONFRONT:
			return CONFRONT_MULT
	return 1.0


## A ROOTED PERSON REACTING — turn to face the trouble, absorb a push, walk back onto the mark.
##
## Returning to `home` is the part that makes this safe to give a static crowd at all. A shove that
## simply displaced them would drift a stall holder out from behind their stall and a sentry off
## their post, one push at a time, with nothing to put them back — the author placed them at that
## exact point and the engine has no business keeping the change.
##
## Switches processing back OFF once everything has settled, so a standing crowd is free again.
func _rooted_tick(delta: float) -> void:
	if _mood_t > 0.0:
		_mood_t = maxf(0.0, _mood_t - delta)
	var cur := Vector2(position.x, position.z)
	var here := cur
	if _stagger > 0.0:
		_stagger = maxf(0.0, _stagger - delta)
		here += _shove_v * delta
	else:
		var back := home - here
		var d := back.length()
		if d > 0.01:
			here += back / d * minf(d, ROOTED_RETURN * delta)
	# THE WALK HOME GOES ROUND THE PLAYER, NOT THROUGH THEM. Whoever just pushed this person off
	# their mark is standing right beside it, so the return walked straight back into them and
	# shouldered an idle player 0.065 m, at up to 1.1 m/s, after they had let go of the stick (people
	# rig, STOP case). Same personal-space rule as every _advance step: the person waits at the
	# player's shoulder and finishes the walk once they move.
	here = _clear_of_player(cur, here)
	# AND NOT THROUGH A WALL. The one position write in this file that skipped the wall guard
	# _advance has: a rooted villager 0.3 m from a wall, struck toward it, was knocked 0.43 m and
	# its centre ended at x 2.14 against a face at 2.0 (people rig) — stood inside the masonry, then
	# walked back out of it. chunk_manager's POPULATE_CLEAR keeps a mark 1 m off DECLARED footprints
	# only, and only when one of its SCATTER_TRIES spots came up clear; nothing else keeps a rooted
	# person away from masonry. To the body's edge, like _advance's: a rooted horse knocked backwards
	# put its rump 0.27 m through the wall behind it with its middle still clear (people rig).
	if here.distance_squared_to(cur) > 1e-6 and _blocked(cur, here + (here - cur).normalized() * _body_reach(here - cur)):
		here = cur     # the wall ends the knockback; the walk home starts from here
	position = Vector3(here.x, _ground(here.x, here.y), here.y)
	_idle_pose()
	_face_heading((_threat - here).normalized(), delta)
	_turned()
	# `_flinch` is in this condition deliberately: without it a rooted person can stop processing
	# mid-recoil and stay leaning backwards forever, which is a worse artefact than not flinching.
	if _stagger <= 0.0 and _mood_t <= 0.0 and _shove_cd <= 0.0 and _flinch <= 0.0 and here.distance_to(home) <= 0.01:
		mood = MOOD_CALM
		rotation.x = 0.0             # leave nobody tilted
		set_physics_process(false)   # back on the mark and done reacting — stop costing a frame
		_nap_begin()                 # ...but not stop forgiving


## A SLEEPING PERSON STILL FORGIVES. The bump debt fades in _physics_process, and a rooted person turns
## that tick off once they are back on their mark — so their forgiveness clock stopped with it, and a
## stall holder brushed past eight times in a whole session had never once been "left alone": the 8th
## brush was an assault, reported to the rules (people rig: 8 bumps 13 s apart -> debt 1..7, then
## npc_assaulted; a stroller the same way: debt 1 every time, nothing). Ticking until the debt is gone
## would charge every brushed extra a frame for up to BUMP_AT x BUMP_FORGET seconds, so the clock goes
## to the SceneTree instead: one timer wound long enough to forgive all of it — it pauses with the game
## and steps with physics, like the tick it stands in for — read back once when they wake (_nap_end).
## Nobody who holds nothing against you gets one.
func _nap_begin() -> void:
	_nap = null
	if bumps <= 0 or not is_inside_tree():
		return
	_nap_len = _bump_forget + float(bumps - 1) * BUMP_FORGET
	_nap = get_tree().create_timer(_nap_len, false, true)


## Awake again (a bump, a blow, a scare): take off what the nap forgave, by the tick's own arithmetic,
## and hand the tick what is left of the countdown.
func _nap_end() -> void:
	if _nap == null:
		return
	var left := _nap.time_left
	var slept := _nap_len - maxf(0.0, left)
	_nap = null
	if left <= 0.0:
		bumps = 0      # slept through all of it
		return
	while bumps > 0 and slept >= _bump_forget:
		slept -= _bump_forget
		bumps -= 1
		_bump_forget = BUMP_FORGET
	_bump_forget -= slept


## THEY FIGHT BACK. Chase, and swing on contact through the same `take_damage` door enemy.gd uses —
## so a hostile civilian costs HP, shows the hurt flash, and can kill exactly like anything else.
## Nothing here is a special case in main; the player never learns this was a villager.
##
## They keep the stroll's forward probe rather than charging through masonry: an angry fishmonger
## clipping a wall would undo the reaction it is meant to sell. Blocked -> deflect and keep coming.
func _hostile_tick(delta: float) -> void:
	if target_player == null or not is_instance_valid(target_player) or not target_player.is_inside_tree():
		mood = MOOD_CALM
		return
	var here := Vector2(position.x, position.z)
	var tp: Vector3 = target_player.global_position
	var to := Vector2(tp.x, tp.z) - here
	var d := to.length()
	if d > HOSTILE_GIVEUP:
		# Lost them. Back to a stroll — but STILL ANGRY: `assaults` is not cleared, so walking back
		# into this person picks the fight up where it stopped rather than starting a fresh one.
		mood = MOOD_CALM
		_pick_target()
		return
	var dir := to / maxf(0.001, d)
	# REACH IS FROM THE BODY'S EDGE. HOSTILE_REACH is a person's: 1.9 m from their centre, 1.56 m from
	# the surface of their capsule. Measured from a long creature's centre it never came — personal
	# space holds its NOSE off the player, so a 3.5 m pug's middle stayed 2.48 m away and it chased in
	# place, 0 blows in 8 s (people rig). The same 1.56 m from whichever part of it is nearest (reach_to).
	var reach := reach_to(Vector2(tp.x, tp.z), here, rotation.y)
	if reach <= HOSTILE_REACH:
		if _face_heading(dir, delta):
			_turned()
		if _atk_cd > 0.0:
			if _atk == "" or _anim == null or not _anim.is_playing():
				_idle_pose()
			return
		_atk_cd = HOSTILE_CD
		# THE RIG DECIDES WHAT THIS PERSON CAN DO TO YOU.
		#
		# With an attack clip: play it and take health, the way an enemy does. Without one — which is
		# every villager in a Meshy cast, all of whom ship [idle, walk] and nothing else — there is no
		# swing to show, so taking health would be an invisible cause with a visible effect. That is
		# the defect this replaces. They SHOVE instead: the same push they give when walked into,
		# turned outward, which reads instantly and needs no animation at all.
		if _atk != "":
			_play(_atk)
			if world != null and is_instance_valid(world) and world.has_method("take_damage"):
				world.call("take_damage", HOSTILE_DMG)
		else:
			_idle_pose()
			# THROUGH MAIN, NOT INTO THE PLAYER'S VELOCITY. This added HOSTILE_PUSH to
			# player.velocity directly, and main._chunk_physics ASSIGNS velocity.x/z from the stick
			# before every move_and_slide — main ticks before the crowd, so the push was overwritten
			# before it was ever integrated: the people rig measured 0.000 m of shove over four
			# swings: the "shove instead" above existed only as a comment. main.push_player adds an
			# impulse main itself integrates and decays, the same door take_damage is above.
			if world != null and is_instance_valid(world) and world.has_method("push_player"):
				world.call("push_player", Vector3(dir.x, 0.0, dir.y) * HOSTILE_PUSH)
		return
	_probe -= delta
	if _probe <= 0.0:
		_probe = PROBE_EVERY
		if _blocked(here, here + dir * PROBE_AHEAD):
			dir = dir.rotated(PI * 0.33 * (1.0 if _rng.randf() < 0.5 else -1.0))
	_advance(here + dir * speed * HOSTILE_MULT * delta, dir, delta)
