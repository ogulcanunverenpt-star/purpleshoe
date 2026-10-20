extends CharacterBody3D
## Enemy: a CharacterBody3D that chases its own encircle slot DIRECTLY (a distinct golden-angle bearing per
## enemy, so they ENCIRCLE the player instead of clumping). Melee w/ cooldown, health, death. The streamed
## KayKit skeleton GLBs carry NO embedded clips, so the animations are RETARGETED from the packed
## kk_rig_medium_* libraries via AnimRig (anim_rig.gd) — see animation.md. Falls back to no-anim if those
## libs aren't packed.
##
## IT MOVES ON ONE BODY AND IS MET AS ANOTHER (2026-10-05, the enemy-bodies step). Every enemy was the same
## 0.4 x 1.5 m capsule at its origin, and every consumer measured from that origin: on 69 of the 71 castable
## models the player walked into a head or a tail, 40 parked with their body round the player, 22 bit from
## inside their own body, arrows hit 6-25% of a long creature side-on, and flyers and swimmers never bit at
## all. Now it MOVES on a slim round capsule at its origin (the mover: never wider than ENEMY_R, so it still
## passes a door and turns by a wall) and is MET as the body it DRAWS (GBody, role "enemy": a person's capsule,
## a creature's ENEMY_SLICES boxes nose to tail, parked or moving), a collider of its own on L_ENEMY that the
## player walks into, a shot meets and a blow lands on — and that stops being a wall where a wall already is.
## Its bite measures that body to the body the player is attacked as (main.player_body: their own, or the hull
## they ride), in 3D, with a line of sight, and lands when its attack is drawn reaching them (the strike).
## No NavigationAgent3D: nothing ever asked one for a path (the direct chase below), and every enemy carried
## one configured for nothing.

var world: Node
var player: Node3D
var anim: AnimationPlayer
var mesh_root: Node3D

var _hp_marks: Array = []   # hp fractions the rule layer watches for THIS kind (see _report_hp_crossing)
var hp := 120.0             # base pool. Raised from 90 for clearer multi-hit feel; combined with the
                            # per-hit cap in take_hit (a single blow can never exceed HIT_CAP_FRAC of
                            # hp_max) this GUARANTEES no weapon one-shots an enemy — always 2+ clean
                            # hits, regardless of weapon upgrades. Per-region/tier scaling: playbook #16.
var hp_max := 120.0         # spawn pool, captured in setup(); the never-one-shot cap is relative to it
const HIT_CAP_FRAC := 0.55  # a single hit removes at most this fraction of hp_max -> min 2 hits to kill
var speed := 3.3
var kind := "skeleton"      # reported on death -> kill_count quest match (honors cell.enemy_type)
var dead := false
## THE BODY IT STANDS IN NOW (GBody, owner this node): body_idle parked, body_move moving — what a shot that
## meets its collider resolves to (main._projectile_hit, GBody.of), what auto-aim aims at (its centre), what a
## blow reaches (main._attack) and what its bite measures from. A PERSON's is one capsule, the mover itself; a
## creature's two bodies each hang a collider of their own (_cols), the one it stands in on L_ENEMY.
var body: GBody = null
var body_idle: GBody = null
var body_move: GBody = null
var _cols := {}             # GBody -> its AnimatableBody3D (a creature's two bodies; a person's body is the mover)
var _mover: CollisionShape3D = null   # the capsule it moves on: its middle is the side of every wall it is on (sight_from)
var _wall_tick := 0         # ticks to the moving body's next wall check (_walls)
var _wall_xf := Transform3D()   # where the body it stands in was last checked against the walls (_walls), and which body
var _wall_body: GBody = null
var _walls_off := 0         # how many of its boxes the last wall check switched off
var _last_xf := Transform3D()   # its transform a tick ago: a body that has just stopped is checked where it stopped
## STILL (_physics_process): it, the body it attacks and the body it stands in all as they were a tick ago — then what it measured
## between the two is what it would measure again, and it does not (_in_reach, the adjust's gap): parked beside a still player,
## an enemy's tick measured them again every tick, its bodies' boxes rebuilt each time (a parked T-rex 18-20 us a tick against
## 4-5 before the bodies; gap_to 12 us a call: step 4's review). `_pb` is the player's body this tick, asked once.
var _pb: GBody = null
var _was_xf := Transform3D()
var _was_pxf := Transform3D()
var _was_pb: GBody = null
var _was_body: GBody = null
var _reach_memo := -1       # _in_reach's bodies' half (in its window and facing) while nothing has moved (-1: not measured
#                             since) — never its sight: that is the world's, looked at each time a bite asks (_in_reach)
var _gap_memo := NAN        # the adjust's gap while nothing has moved
var _seen := true           # what its last look said (_in_reach): a look that says otherwise has the world changed between them
static var rays := 0        # world rays its lines of sight and wall checks have cast (the enemy rig counts them)
var url := ""               # the model's url: a library model is drawn at its natural size (GBody.normalise)
## THE STRIKE: how far its attack, as drawn, reaches past the front of its parked body (GPose.body_fit's strike)
## and when in the attack clip it lands (contact, a fraction of the clip). Its bite is measured from the body,
## so a lunge needs no collider inflated to hold it: fitted over the attack, a frog stood as a 2.13 m invisible
## wall and bit from 3 m of air (enemy-bodies review).
var strike_reach := 0.0
var contact := 0.4
var _front := 0.4           # its parked body's reach ahead of its origin, toward what it faces (where its slot puts it)
var _bite_t := -1.0         # seconds to the contact of an attack under way (-1: none)
var _foot_pb: GBody = null  # the player's round body when no world answers main.player_body (a rig's bare enemy)
var _moves_by := "words"    # how its flying or swimming was decided: the type's "words", or "authored" by the build
var atk_cd := 0.0
var flash_t := 0.0
var slot_angle := 0.0       # distinct approach angle so enemies encircle, not clump
var surround_radius := 1.7
var attack_range := 2.0

var c_idle := ""
var c_walk := ""
var c_run := ""             # run/gallop/sprint clip: a chaser at running pace plays it (see _move_clip)
var c_swim := ""            # swim/tread clip (empty -> GPose.tread)
var c_fly := ""             # fly/flap clip for aerial creatures (bat/pterodactyl); empty -> falls back to walk
var c_attack := ""
var c_die := ""
var c_hurt := ""
var hurt_t := 0.0           # brief flinch hold so locomotion doesn't override the hurt clip
var _cur := ""


const MAX_ENEMY_H := 3.0    # an authored height over this is a BOSS (GBody.ENEMY_MAX_H caps every other enemy's drawn height); 4.0 still walled a portrait frame at melee range (gamefeel P1)
const CAM_FADE_NEAR := 1.6  # hide the enemy mesh when the camera is this close to a person-sized body's CENTRE so a body pressed against the lens can't wall the view
const CAM_FADE_GAP := 1.2   # ...measured to the BODY it draws (GBody.dist3): CAM_FADE_NEAR less a 0.4 m capsule, the same lens distance for a person, and a 4.5 m creature's tail no longer fills the lens 3 m from its middle
# THE UNIT EVERY AUTHORED REACH WAS TUNED IN. attack_range (enemy_range, 2.0) and surround_radius (1.7) are centre
# distances between two 0.4 m capsules — every enemy's and the player's — so in clear space between two bodies they
# are 2 x PERSON_R0 less: a bite reaches 1.2 m of air, a parked enemy keeps 0.9. A person-sized enemy bites and parks
# exactly where it did; a 4.5 m creature does it from its own nose, not from 2 m behind it.
const PERSON_R0 := 0.4
const PLAYER_R := 0.4       # the player's capsule (main._build_player)
# NO BODY STEPS OR TURNS CLOSER TO THE PLAYER'S AXIS THAN THIS: their capsule and 5 cm of air. At their radius exactly a
# body sliding round them was in contact every tick and the physics dragged them along with it — a T-rex slid 1.2 m round
# a still player and carried them 0.73 m, a cow 1.08 (the enemy rig's never-closer group). The drag itself was the player
# taking the body's motion as a platform's (main._build_player: platform_floor_layers); the air is still a turn's margin —
# at their radius exactly, a horse turning beside a still player moved them 0.42 m and a snake 0.31 (step 4's fix round).
const KEEP_OFF := PLAYER_R + 0.05
const DEFAULT_CONTACT := 0.4   # where an attack nothing could measure lands in its clip (the KayKit chop's own is measured: the enemy rig)
const WALL_EVERY := 4       # physics ticks between a moving body's wall checks (_walls)
const WALL_OFF_EVERY := 60  # ...and a still one's while a box of it is off: the wall it reached through may have gone
const BITE_CONE := 60.0     # deg either side of its facing within which what it attacks must stand (_facing)
const SIGHT_RETRY := 0.25   # s an enemy in its bite's window with a wall in the way waits before it looks again (_strike)
# THE SWOOP AND THE LUNGE (D12): a flyer dives on its target and a swimmer dashes at it, bites on CONTACT, and recovers
# to its stand-off. They trailed at 2.6-5.9 m and their bite reached 2.0 m from their origin, so neither ever bit (0 in
# 30 s; enemy-bodies investigation); a flyer swoops from ATTACK_ARM of its stand-off, a swimmer lunges from the same.
const ATTACK_ARM := 3.0     # m of clear space past its stand-off from which a flyer swoops / a swimmer lunges
const SWOOP_SPEED := 7.0    # m/s down the dive (a bat's stoop; the player walks 4-6)
const LUNGE_SPEED := 3.9    # m/s along the water — still under the player's SWIM_SPEED 4.2 (main.gd): a swimmer out-swims a lunge
const STRIKE_TIME := 2.0    # s a swoop or a lunge chases before it gives up and recovers
const LUNGE_CONTACT := 0.1  # m of clear space between the bodies at which a swoop or a lunge bites (_lunge)
const KEEP_OFF_PACE := 1.5  # x its speed: how fast a flyer or a swimmer goes back out to its stand-off (_keep_off)
const RECOVER_TIME := 0.9   # s it climbs or backs off before it trails again
# THE CLIPS A CLIPLESS KAYKIT SKELETON PLAYS (AnimRig): the warm takes its body with them (AreaBuilder._prewarm_fit
# reads this), so its spawn fits nothing cold.
const RIG_CLIPS := {"idle": "Idle_A", "walk": "Walking_A", "attack": "Melee_1H_Attack_Chop", "death": "Death_A", "hurt": "Hit_A"}
# WHO FLIES AND WHO SWIMS, BY WHOLE WORDS (GClip.tokens: "giant_bat", "GiantBat" -> giant, bat; a word, or its plural).
# The substrings these were read by made a mammoth, a behemoth, a wombat, an impala, a shrimp, a scarecrow, a combat
# droid and a battle mage fly, and a gray wolf, a stray dog and a steel golem swim (enemy-bodies review, through the
# real setup) — and a flyer or a swimmer fights differently now. A "dragon" walks unless the build says enemy_aerial or
# enemy_hover. verify.mjs carries the same tables (ETYPE, between its markers) and check-clip-vocab.mjs holds them equal.
const AERIAL_WORDS := ["bat", "pterodactyl", "pteranodon", "ptero", "pteran", "wyvern", "bird", "eagle", "hawk", "falcon",
	"vulture", "owl", "raven", "crow", "gull", "seagull", "parrot", "wasp", "hornet", "bee", "dragonfly", "butterfly",
	"moth", "fly", "firefly", "harpy", "imp", "fairy", "pixie", "griffin", "gryphon", "phoenix", "gargoyle"]
const AQUATIC_WORDS := ["shark", "croc", "crocodile", "gator", "alligator", "serpent", "eel", "piranha", "marlin",
	"squid", "octopus", "kraken", "manta", "ray", "stingray", "dolphin", "whale", "orca", "fish", "catfish", "swordfish",
	"jellyfish", "crab", "lobster", "shrimp", "prawn"]
# ...AND A WORD BUILT ON ONE: a single word ENDING in one of these heads is that creature — an anglerfish, a pufferfish and a
# starfish swim, a hummingbird, a bumblebee and a nighthawk fly — unless it only looks like one (FALSE_HEADS: an elfish
# archer, a mohawk raider, a scarecrow). Read by whole words alone, 17 such types the substring reader got right walked
# (anglerfish, pufferfish, lionfish, goldfish, starfish, blowfish; hummingbird, blackbird, songbird, thunderbird, firebird,
# bumblebee, honeybee, seahawk, nighthawk, warhawk, stormcrow: step 4's review). No head that ends a common word that is no
# creature (bat: combat, wombat; ray: gray, stray; eel: steel; moth: mammoth): those stay whole words.
const AERIAL_HEADS := ["bird", "bee", "hawk", "crow", "fly", "gull"]
const AQUATIC_HEADS := ["fish", "shark", "whale", "crab", "serpent"]
const FALSE_HEADS := ["elfish", "selfish", "unselfish", "wolfish", "dwarfish", "oafish", "raffish", "standoffish", "mohawk",
	"tomahawk", "scarecrow", "jailbird", "frisbee"]
const RUN_PACE := 2.6       # m/s at and above which a moving enemy plays its run clip, below it its walk (_move_clip) — hero_anim's RUN_EXIT, the pace below which the hero stops running
const ANIM_LOD_DIST := 26.0 # past this many metres from the player, FREEZE the skinned pose (stop the per-frame AnimationMixer skeleton update — the dominant main-thread cost when a camp packs dozens of skinned bodies); the close attacking cluster stays fully animated
static var _spawn_seq := 0  # monotonic across ALL enemies -> golden-angle encircle bearings that stay distinct ACROSS cells (a per-cell index repeats bearings between cells, so RVO agents fought the same point = blob vibration)
var _cam_hidden := false    # near-camera fade state (hysteresis) so a body hovering at the fade threshold doesn't flip visible/hidden every frame = flicker
var _walk_phase := 0.0      # procedural-walk gait phase for CLIPLESS creatures (anim == null) so they stride instead of sliding
var _moving := false        # dir-hysteresis (0.35 off / 0.7 on): RVO jostle at the slot can't flip walk/idle/desired/velocity-hold every frame = jitter
var _park_slot := Vector3.INF   # the slot it last stopped at: it chases again only once THAT has moved (the player did)
var _gwalk := false         # true while GPose.walk drives the legs -> walk_stop runs ONCE on the stop edge (no per-frame WALK_META rebuild)
var _ground_stuck := false  # ground-stick latch (mirrors the player's main.gd fix): pinned to the heightmap this tick, so gravity doesn't re-fire and yo-yo the body over a not-yet-streamed collider = the FPS-independent vertical buzz
var _lod_far := false        # cached distance>ANIM_LOD_DIST (set in _physics_process, read by _process for the render-rate procedural walk)
# PARK-LOCK: the enemy-only "whole body vibrates, even standing still" buzz was ROOT-CAUSED by an
# A/B pair of freeze tests — freezing the ANIM (body still moving) was smooth, AND freezing the BODY (anim still
# playing) was smooth (user-confirmed A/B). So the buzz is neither the clip nor the movement alone: it is
# the per-PHYSICS-TICK body transform being micro-noisy (move_and_slide's collision/gravity re-solve on uneven
# island terrain + damped _face yaw) while the render-rate skinned ANIMATION amplifies that base-transform noise
# out at the limbs — worst on big creatures (colossus/snake/dino) where the lever arm magnifies a sub-degree wobble.
# FTI faithfully interpolates THROUGH the noisy per-tick waypoints; it can't denoise them. Fix: when a creature
# has ARRIVED and is holding its slot on the ground, hold its transform byte-stable (skip _face + move_and_slide)
# so FTI sees prev==curr = zero base wobble = smooth skin — the passive-child hero's exact no-buzz regime. Full
# physics resumes the instant it chases (position stays continuous, so no snap/reset needed). Parked creatures
# also do zero move/nav/collision work -> the same near-camp lag cut that A/B showed.
var _parked := false
var _adjust := 0            # stopped out of its bite: -1 stepping back from the player, 1 stepping in (_physics_process)
var _vel := Vector3.ZERO    # the move's own velocity state, tick to tick (_on_safe_velocity): `velocity` shows its motion
# INTERPOLATED-MESH DRIVE: the moving-creature "only the creature vibrates, scene is smooth" jitter is
# the skinned mesh rendering at the RAW 60Hz physics-tick position (an active skeleton animation defeats the mesh
# subtree's own physics interpolation) while the FTI-smooth world glides -> a translating creature jumps ~speed/60
# per tick RELATIVE to the smooth scene. Freeze the anim (no skeleton update -> FTI works) or the body (no motion)
# -> smooth; interpolation on/off was a no-op because the anim overrode it either way; the hero is camera-locked to
# its own interpolated xform so it's masked. Fix: make mesh_root TOP-LEVEL + interp-OFF and set its global_transform
# from the body's get_global_transform_interpolated() every render frame -> the skin rides the SAME smooth path.
var _mesh_local := Transform3D.IDENTITY   # mesh_root's captured local offset (usually identity), preserved in the drive
var _mesh_driven := false                  # true once mesh_root is top-level-driven from the interpolated body xform
# VISUAL POSITION SMOOTHING: the confirmed moving-creature "shakes in place" is the BODY's per-tick
# position being noisy — move_and_slide sliding over the bumpy terrain trimesh + nav-path chatter + the analytic
# ground-snap produce a few-mm back-and-forth wobble every physics tick, which interpolation faithfully reproduces
# (drawing the mesh on the interpolated body path did NOT fix it — it still shook). The player/hero is smooth because it
# moves from clean joystick velocity, not nav-over-terrain. Fix: low-pass ONLY the RENDER position of the mesh
# (the invisible physics body keeps its exact collision position) -> erases the high-freq tremble, keeps the motion.
var _vis_pos := Vector3.ZERO               # exponentially-smoothed render position for mesh_root
const VIS_SMOOTH_TAU := 0.04               # LIGHT backstop now that direct-chase removes the nav-path wobble at the source; higher = smoother but more visual lag behind the body
# A CREATURE STANDS ON THE GROUND UNDER ITS FEET, leaned with it as a herd's is (GBody.lean_on, the rule a mount's chassis rests
# by): drawn upright on its origin, on step 4's own code a chasing cow stood 0.43 m into a 17 deg hillside and 0.88 m into Kestrel
# Bay's canyon wall, a raptor 0.35 m into a 17 deg slope it ran down (step 5c). What it DRAWS leans (mesh_root, in _process) and
# so does its BODY (GBody.set_lean: both of its bodies and their colliders), so what a shot, a bite and a blow meet is what is
# drawn: drawn leaned on its upright body, an enemy cow on a 17 deg grade drew 0.37-0.43 m out of it and a T-rex on a 31 deg one
# 0.46, and held to that body it leaned so little a cow stood 0.38 m into Kestrel Bay's wall (step 5c's review). Its mover stays
# upright (the capsule the physics walks). Only on the terrain (GBody.lean_on), and upright again on a cliff past 35-45 deg (its
# turn guard and its step in read the boxes round a leaned body: GBody.LEAN_STEEP); on a deck or in the air, upright. A person
# stands upright; a flyer and a swimmer hold their own attitude.
var _stance: Array = []                    # what its feet stand on (GBody.stance), its frame; []: upright
var _lean := Transform3D.IDENTITY          # the lean its mesh and its bodies take, about its origin (_physics_process)
var _lean_at := Transform3D()              # ...where it stood when that was read, and what it read there
var _lean_read := Transform3D.IDENTITY
var _hc := {}                              # the ground's lattice heights the lean read (GTerrain.height_cached)
var _foot_r := 0.0                         # the round foot it stands on: its mover's radius (GBody.lean_on reads it off a slope)
# ...READ AS IT MOVES, AND PAST ANIM_LOD_DIST AS IT MOVES ON: near the player every tick it has moved (a hoof, a head and a shot
# are read as drawn there), further off once it has gone LEAN_FAR_STEP, turned LEAN_FAR_TURN or come up or down LEAN_ON since
# it was read. Read every moving tick, a chasing creature's tick far off took 50.1 us against 32.5 before the lean — 8-11 us of
# it lean_on's five reads of the ground (step 5c's re-check; desktop).
const LEAN_FAR_STEP := 0.5
const LEAN_FAR_TURN := deg_to_rad(5.0)
# A PERSON STANDS ON THE GROUND IN EVERY CLIP (step 5d): its rig keeps its feet-at-origin convention at rest, and each clip carries
# its own ground — a KayKit skeleton walked 1.1-6.7 cm into flat ground, a smuggler ran 6.2 cm into it at its lowest. `ground` is
# its enemy fit's (GPose's), and what it draws is lifted so the feet its clip draws lowest stand on the ground under them
# (GPose.ground_rise: its walk at the phase the frame draws, every frame; anything else at its lowest moment — a run keeps its
# leap, an attack its lunge), through a crossfade as the mixer weighs the two clips (_ground_lift). Afloat or aloft, as its rest
# stands.
var ground := {}
var _glift := 0.0                          # how far its mesh root is lifted now (its own units) ...
var _gfades: Array = []                    # ... and the clips its mixer fades from as it keeps them (_play): [clip, where it is in it,
                                           # its length, its rate, the weight it has left, its fade's time]
const GRAVITY := 22.0       # match the player (main.gd): pull a chasing enemy DOWN onto the terrain each airborne frame so it can't ratchet up rolling hills and float into the sky
const FLOAT_WADE := 0.6     # water this deep over the seabed -> a land animal floats/swims instead of walking the bottom
const SWIM_MAX := 2.6       # HARD cap on a creature's in-water horizontal speed; player SWIM_SPEED=4.2 (main.gd) -> the player always out-swims every creature regardless of index desync / per-cell speed multiplier
const SWIM_KEEP := 3.5      # in-water stand-off radius: swimmers approach on their OWN bearing and hold >= this far out (no distributed ring) so they TRAIL the swimmer, never encircle/blob onto it
var _aquatic := false       # true -> rides ANY water (shark/croc/serpent); false land animal floats only when forced in
var _floating := false      # currently floating at the water surface (swim), not on the ground
var _submerge := 0.45       # how far below the surface the body rides (0.2 for aquatic so a fin shows)
var _aerial := false        # FLIES/hovers at altitude instead of walking (bat/pterodactyl/bird); no gravity, tracks terrain+hover_alt
var hover_alt := 4.0        # target flight altitude above the terrain below (per-type default; opts "hover" overrides)
var _air_keep := 1.0        # per-flyer stand-off multiplier — a shared radius reads as a formation
var _air_orbit := 0.0       # per-flyer slow orbit drift (rad/s, signed) so the flock rearranges in flight
var _bob_t := 0.0           # hover bob phase (advanced in _physics_process)
var _strike_state := 0      # a flyer's swoop / a swimmer's lunge: 0 trailing, 1 striking, 2 recovering
var _strike_t := 0.0        # seconds in that state
var _stagger := 0           # per-enemy physics-frame offset: its wall checks spread across frames (not all on one)
const AERIAL_BOB := 0.5     # hover bob amplitude
const AERIAL_MAX_CLIMB := 45.0   # how high above the terrain a flyer will climb to chase a flying/high player (plane)
var body_h := 1.8           # the height it is drawn at (GBody.normalise) — the far cull scales with it
var atk_damage := 9.0       # per-hit damage on the player — per-cell "enemy_damage" overrides (boss/creature tiers)
var max_h := MAX_ENEMY_H    # per-cell "enemy_height": over MAX_ENEMY_H it is a BOSS (the minimap's larger mark), drawn exactly that tall

func setup(p: Node3D, model: Node, w: Node, index := 0, total := 1, etype := "skeleton", opts: Dictionary = {}) -> void:
	player = p
	world = w
	kind = etype
	# Per-cell creature tuning (all optional; authored on the cell record):
	#   enemy_hp / enemy_damage / enemy_speed / enemy_range / enemy_height — lets one enemy.gd serve
	#   a raptor (fast, light) and a colossal boss (huge, heavy) from DATA, no subclasses.
	hp = maxf(10.0, float(opts.get("hp", hp)))
	atk_damage = maxf(1.0, float(opts.get("damage", atk_damage)))
	attack_range = maxf(1.0, float(opts.get("range", attack_range)))
	max_h = clampf(float(opts.get("height", MAX_ENEMY_H)), 1.0, 14.0)   # per-cell "height" draws a genuine boss up to this tall (boss_h)
	url = String(opts.get("url", ""))
	# AQUATIC (data flag or inferred from the type's words) rides any water; land animals only float when forced
	# into deep water. Drives the water/swim behavior in _on_safe_velocity.
	_aquatic = bool(opts.get("aquatic", false)) or mode_of(etype) == "swim"
	# whose word it is how it moves: the build's (enemy_aerial / enemy_hover / enemy_aquatic) or the type's own words
	_moves_by = "authored" if (bool(opts.get("aquatic", false)) or bool(opts.get("aerial", false)) or opts.has("hover")) else "words"
	_submerge = 0.2 if _aquatic else 0.45
	# AERIAL (data flag or inferred): flies/hovers at altitude instead of walking, so bats/pterodactyls/
	# birds command the air. "enemy_aerial": true OR "enemy_hover": <altitude> on the cell also enables it.
	_aerial = bool(opts.get("aerial", false)) or opts.has("hover") or mode_of(etype) == "fly"
	if _aerial:
		var def_alt := 6.0 if _has_word(etype, ["ptero", "pterodactyl", "pteranodon", "pteran", "wyvern", "dragon"], []) else 3.5
		hover_alt = clampf(float(opts.get("hover", def_alt)), 1.5, 20.0)
		# DESYNC THE FLOCK. Every flyer started _bob_t at 0, took the same hover_alt and the same zero
		# attack cooldown, so five bats rose together, bobbed together and swooped on the SAME frame —
		# reading as one object with ten wings rather than five creatures. Per-instance phase, altitude
		# and stagger is the whole difference between a flock and a formation.
		_bob_t = randf() * TAU
		hover_alt = clampf(hover_alt + randf_range(-0.9, 0.9), 1.5, 20.0)
		atk_cd = randf() * 0.9
		# A RIGID RING IS STILL A FORMATION. Distinct angles alone only look varied while the player
		# stands still; the instant they move, every flyer chases a slot anchored to them at an
		# IDENTICAL radius and speed, so the whole flock glides along holding its shape. Give each one
		# its own stand-off and a slow orbit drift (own direction and rate) so the group keeps
		# rearranging instead of translating as one body.
		_air_keep = randf_range(0.75, 1.7)
		_air_orbit = randf_range(0.18, 0.5) * (1.0 if randf() < 0.5 else -1.0)
		# A FLYER MUST NOT SNAP TO THE FLOOR. floor_snap_length (set below for walkers, so feet stick to
		# descents) pulls the body down inside every move_and_slide when velocity.y <= 0 — which is
		# always true for a flyer, since aerial motion is horizontal velocity plus a direct y lerp.
		# The altitude code ran correctly the whole time and the snap simply undid it each frame:
		# measured target 3.77, actual y 0.38, forever. Bats walked.
		floor_snap_length = 0.0
	var spd_mul := clampf(float(opts.get("speed", 1.0)), 0.2, 2.5)
	hp_max = hp   # capture spawn pool so the never-one-shot cap tracks any region/tier hp scaling
	# Ask the rule layer ONCE what thresholds matter for this kind, so take_hit stays a cheap compare.
	if is_instance_valid(w) and w.get("director") != null and w.director.get("rules") != null:
		_hp_marks = w.director.rules.hp_marks_for(etype)
	collision_layer = 4   # enemy layer: the MOVER is solid to the player too, so a creature pressed to a wall stays solid from its own side
	collision_mask = 1    # world only; enemies pass through each other (their distinct slots space them)
	floor_max_angle = deg_to_rad(55)   # match the player: climb steep terrain instead of stalling at 45°
	floor_snap_length = 0.0 if _aerial else 0.8   # walkers: feet stick to descents. Flyers: never — the snap cancels the hover lerp.
	_spawn_seq += 1
	slot_angle = fmod(float(_spawn_seq) * 2.399963229728653, TAU)   # golden-angle: globally-distinct approach bearings so index-i enemies in DIFFERENT cells don't share a slot and fight for the same point (blob vibration)
	_stagger = index % WALL_EVERY   # spread the wall checks across frames
	speed = (3.0 + float(index % 4) * 0.3) * spd_mul   # desync so they don't move as one blob
	surround_radius = maxf(surround_radius, attack_range * 0.85)   # a big-reach boss circles wider, not inside the player
	# AN AUTHORED HEIGHT IS DRAWN EXACTLY — within the 1-14 m an enemy_height has always meant (max_h, which the minimap reads
	# too). Drawn as given, a horse given 50 stood 50 m tall and 67 m long and a skeleton given 0.3 a 0.3 m speck with a
	# 0.08 m mover (step 4's review), where a height outside those had always been drawn at their edge.
	var boss_h := max_h if opts.has("height") else 0.0
	var fit_m := {}
	var xf := Transform3D.IDENTITY   # the model in this node's frame: what its fits are read through

	if model:
		mesh_root = Node3D.new()
		add_child(mesh_root)
		mesh_root.add_child(model)
		anim = _find_anim(model)
		if anim == null and model is Node3D:
			# clipless KayKit skeletons: retarget the packed clips (a foreign Meshy rig won't match -> null -> the
			# clipless GPose path in _process animates the legs procedurally).
			anim = AnimRig.attach(model as Node3D, RIG_CLIPS, ["idle", "walk"])
		if model is Node3D:
			var m3 := model as Node3D
			# WHAT IT DRAWS, before it is sized (a fit is the model's own frame): parked and moving, and its attack —
			# the fits the parse-time warm took for this url (AreaBuilder._prewarm_fit, the "enemy" roles), so a lookup.
			fit_m = GBody.fit(m3, "enemy")
			# ITS SIZE, by what it draws (GBody.normalise): a library creature at its natural size, a person by the
			# person's band, under the enemy caps — or exactly an authored height (a boss). Sized by bones and the
			# un-skinned bind box, a T-rex came out 0.96 m, a rat 6.81 m long, a boss authored 8 m tall 2.57-9.59.
			var pol := {"role": "enemy", "url": url}
			if boss_h > 0.0:
				pol["height"] = boss_h
			if bool(fit_m.get("person", false)):
				pol["ch"] = GPose.char_height(m3)
			var s := GBody.normalise(fit_m, pol)
			if absf(s - 1.0) > 1e-4:
				m3.scale *= s
			if bool(fit_m.get("person", false)):
				ground = fit_m.get("ground", {})
			if GPose.skeleton_of(m3) == null:
				# an UNRIGGED model is grounded on what it draws; a rigged one keeps its feet-at-origin convention
				m3.position.y -= GPose.drawn_aabb(m3).position.y
			xf = mesh_root.transform * m3.transform
			body_h = maxf(0.3, (xf * (fit_m.get("rest", AABB()) as AABB)).size.y)
		_resolve_clips()
		# FROM ITS REST POSE: a bone no clip keys holds whatever pose the GLB was exported in until something sets it, and
		# its body was fitted with it at rest (GPose.body_fit: rest + the clip's tracks) — the mounts' rule (Vehicle.
		# _rest_bones). A horse exported with its head and tail off their rests drew 0.32 m inside a parked body fitted to
		# them at rest (the enemy rig's body group).
		for sk in mesh_root.find_children("*", "Skeleton3D", true, false):
			(sk as Skeleton3D).reset_bone_poses()
		# ...AND BACK TO IT WHEN A CLIP LETS GO OF A BONE. A creature's clips key different bones (a horse's idle 14 of its
		# 25, a T-rex's 17 of 28, a mire dragon's 9 of 23), and the GLB's mixer is not deterministic: a bone its idle does not
		# key KEPT whatever its run or its bite last set, so parked after a chase a horse was drawn 0.45 m out of the body it
		# parks in, a cow 0.33, a triceratops 0.27, a T-rex 0.22 — the player walked 0.06 m into a horse's drawn nose (step 4's
		# fix round). Deterministic, a bone no playing clip keys blends back to its rest: what is drawn is rest + the clip's
		# tracks, the pose its body was fitted in (0.002-0.004 m off it after either). A person's body is a capsule whatever
		# it plays, and its rest a T-pose: its mixer is left as it came.
		if anim != null and not bool(fit_m.get("person", false)):
			anim.deterministic = true
		_play(c_idle)   # play the model's OWN clean embedded clips, exactly like the hero (main.gd) does — these
		#                 anims are verified clean (identical structure to hero_jack); the enemy-only anim.active LOD
		#                 toggle that USED to fight them here has been removed (it was the jitter).
		# FAR-DISTANCE CULL: a high-poly Meshy creature is expensive to DRAW on a mobile GPU. Stop drawing one
		# that's beyond the immediate action, so a camp only renders the creatures near the player instead of the
		# whole spread pack. Hard cutoff (no dither). Scaled by body size so a big BOSS stays visible far
		# while small creatures cull near. AI/attack are unaffected (this only gates rendering).
		_set_far_cull(mesh_root, maxf(22.0, body_h * 6.0))
		if model is Node3D and not _aerial and not bool(fit_m.get("person", true)):
			_stance = GBody.stance(model as Node3D, self)   # in its frame, mesh_root's offset included (before it goes top-level)
		# INTERPOLATED-MESH DRIVE (see _mesh_driven doc): detach mesh_root from the body's raw transform and
		# render it on the body's SMOOTH interpolated path every frame, so the animated skin can't defeat
		# interpolation and jump in per-tick steps against the smooth world. Body still does all physics/collision.
		_mesh_local = mesh_root.transform
		mesh_root.top_level = true
		mesh_root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_vis_pos = global_position   # seed the smoothed render position
		mesh_root.global_transform = global_transform * _mesh_local   # seed so frame 0 doesn't streak from origin
		_mesh_driven = true
	else:
		var mi := MeshInstance3D.new()
		var cm := CapsuleMesh.new()
		cm.radius = 0.4
		cm.height = 1.5
		mi.mesh = cm
		mi.position.y = 0.75
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.55, 0.57, 0.6)   # neutral "loading" gray, not a jarring red — the model hot-swaps in when its fetch lands (#9)
		mi.material_override = m
		add_child(mi)
		mesh_root = mi
		print("GOGI_PLACEHOLDER enemy ", kind)   # verify.mjs asset-fail gate: a gray enemy box is visible
	_build_bodies(fit_m, xf, boss_h)


## ITS BODIES AND ITS MOVER (see the header). A PERSON — or a model nothing could measure (the loading placeholder keeps
## the 0.4 x 1.5 m capsule every enemy carried; a boss's grows with its height, as it did) — is one capsule (GBody, role
## "enemy": the crowd's person, its radius capped at GBody.ENEMY_R), and the mover IS that capsule. A CREATURE parks in
## one body and moves in another (the clips it shows in each, _shown, cut nose to tail), each a collider of its
## own on L_ENEMY — the one it stands in live, the other off — and MOVES on a capsule round its origin: as wide as its narrowest
## half-width, never wider than ENEMY_R (a boss: its old capsule, clamp(0.2 x height, 0.4, 2.4) — decision 23), never
## taller than 1.5 m. With no pathfinding a chaser too wide for a gap presses into the wall for ever; at 0.45 every
## regular enemy passes a 1.05 m door and a 2.1 m lintel, as it did. The body's colliders collide with nothing (mask 0).
func _build_bodies(fit_m: Dictionary, xf: Transform3D, boss_h: float) -> void:
	var cap := clampf(0.2 * boss_h, 0.4, 2.4) if boss_h > MAX_ENEMY_H else GBody.ENEMY_R
	if fit_m.is_empty() or not bool(fit_m.get("ok", false)):
		body_move = GBody.round(cap if boss_h > MAX_ENEMY_H else PERSON_R0, maxf(1.5, 0.72 * boss_h)).owned_by(self)
	elif not bool(fit_m["person"]) and fit_m.has("bands"):
		# ITS BODIES ARE THE CLIPS IT SHOWS (_shown), cut from the fit's bands (one set a clip, on one grid)
		body_move = GBody.from_slices(GPose.band_boxes(fit_m["bands"], _shown(fit_m["bands"], true)), "enemy", xf).owned_by(self)
	else:
		# a person: the enemy role's capsule (r_cap ENEMY_R), a boss's grown to its old capsule (`cap`)
		body_move = GBody.from_fit(fit_m, "enemy", xf, cap if boss_h > MAX_ENEMY_H else -1.0).owned_by(self)
	body_idle = body_move
	var mover := CollisionShape3D.new()
	var mc := CapsuleShape3D.new()
	if body_move.kind == GBody.ROUND:
		# the person's body is the mover, built from the body's own numbers (GBody.collider's capsule)
		mc.radius = body_move.r
		mc.height = maxf(body_move.y1 - body_move.y0, body_move.r * 2.0)
		mover.position = Vector3(body_move.c.x, body_move.y0 + mc.height * 0.5, body_move.c.y)
	else:
		if not _aerial and fit_m.has("bands"):
			body_idle = GBody.from_slices(GPose.band_boxes(fit_m["bands"], _shown(fit_m["bands"], false)), "enemy", xf).owned_by(self)
		mc.radius = clampf(minf(body_idle.half.x, body_idle.half.y), 0.2, cap)
		mc.height = clampf(body_idle.y1, mc.radius * 2.0, maxf(1.5, mc.radius * 2.0))
		mover.position = Vector3(0.0, mc.height * 0.5, 0.0)
		for b: GBody in ([body_idle] if body_idle == body_move else [body_idle, body_move]):
			var col := b.collider(4)
			col.collision_layer = 4 if b == body_idle else 0
			add_child(col)
			_cols[b] = col
	mover.shape = mc
	add_child(mover)
	_mover = mover
	_foot_r = mc.radius
	body = body_idle
	# THE FRONT ITS SLOT PUTS IT BY, and how far its attack reaches past it, in this node's frame
	_front = body_idle.c.y + body_idle.r if body_idle.kind == GBody.ROUND else _front_of(body_idle)
	var st: Dictionary = fit_m.get("strike", {})
	if not st.is_empty():
		strike_reach = maxf(0.0, (xf * Vector3(0.0, 0.0, float(st["front"]))).z - _front)
		contact = float(st["phase"]) if float(st["phase"]) >= 0.0 else DEFAULT_CONTACT
	else:
		contact = DEFAULT_CONTACT
	if not fit_m.is_empty():
		_say_body(fit_m, boss_h, mc)


## THE CLIPS IT SHOWS, moving or parked (the fit's band keys; "" its rest pose), as _physics_process and _play leave them:
## a flyer its flight (its walk with none) in both — it never parks; a walker, and a swimmer (on land it walks; afloat it
## shows its swim, or its idle treaded, both in its moving body), parked its idle, moving its idle and gaits (with no walk
## or run, its idle: _move_clip). _play("") plays nothing, so with no idle it parks in the gait it arrived in (its rest
## pose before it first moves; GPose.walk swings a clipless one's legs). Fitted over every clip it could play, a dragon
## that walks stood in its spread wings.
func _shown(bands: Dictionary, moving: bool) -> Array:
	var has: Dictionary = bands.get("by", {})
	var want: Array
	if _aerial:
		want = [c_fly if c_fly != "" else c_walk]
	elif moving or c_idle == "":
		want = [c_idle, c_walk, c_run, c_swim]
	else:
		want = [c_idle]
	var keys: Array = []
	for c in want:
		if c != "" and has.has(c) and not keys.has(c):
			keys.append(c)
	if keys.is_empty() or (not _aerial and c_idle == ""):
		keys.append("")
	return keys


# The furthest a box body reaches ahead of the origin (+z), slices or not.
static func _front_of(b: GBody) -> float:
	var f := b.c.y + b.half.y
	for q: GBody in b.parts:
		f = maxf(f, q.c.y + q.half.y)
	return f


## GOGI_ENEMY_BODY <kind> <url|-> size <given|natural|person|drawn> drawn <h> <w> <l> body <round r | box n> mover <r> <h>
## strike <reach> <contact> moves <walk|fly|swim> <words|authored>: once per kind and model a world spawns — what it is
## drawn at and why, the body it stands in and how it moves and on whose word. verify.mjs holds the size to the enemy
## policy (ENEMY SIZE OUT OF POLICY) and a move the type's words decided to its own reading of them (ENEMY TYPE MISREAD).
static var _said := {}
func _say_body(fit: Dictionary, boss_h: float, mc: CapsuleShape3D) -> void:
	var key := "%s %s %.2f" % [kind, url, boss_h]
	if _said.has(key):
		return
	_said[key] = true
	var src := "drawn"
	if boss_h > 0.0:
		src = "given"
	elif not GBody.natural_of(url).is_empty():
		src = "natural"
	elif bool(fit.get("person", false)):
		src = "person"
	var dsz := Vector3.ZERO
	if mesh_root != null and mesh_root.get_child_count() > 0 and mesh_root.get_child(0) is Node3D:
		dsz = GPose.drawn_aabb(mesh_root.get_child(0) as Node3D).size
	var bs := "round %.2f" % body_move.r if body_move.kind == GBody.ROUND else "box %d" % maxi(1, body_move.parts.size())
	print("GOGI_ENEMY_BODY %s %s size %s drawn %.2f %.2f %.2f body %s mover %.2f %.2f strike %.2f %.2f moves %s %s" % [
		kind.replace(" ", "_"), url.replace(" ", "%20") if url != "" else "-", src, dsz.y, dsz.x, dsz.z, bs, mc.radius,
		mc.height, strike_reach, contact, "fly" if _aerial else ("swim" if _aquatic else "walk"), _moves_by])


## WHO FLIES AND WHO SWIMS: "fly", "swim" or "walk" for the enemy type `etype`, by its WHOLE words (GClip.tokens) — one of
## AERIAL_WORDS or AQUATIC_WORDS, or a word ending in one of their heads (AERIAL_HEADS, AQUATIC_HEADS) that is not one of
## FALSE_HEADS, each or its plural. verify.mjs reads a type the same way (ETYPE).
static func mode_of(etype: String) -> String:
	if _has_word(etype, AERIAL_WORDS, AERIAL_HEADS):
		return "fly"
	if _has_word(etype, AQUATIC_WORDS, AQUATIC_HEADS):
		return "swim"
	return "walk"


static func _has_word(etype: String, words: Array, heads: Array) -> bool:
	for t in GClip.tokens(etype):
		for w in words:
			if t in _plurals(w):
				return true
		if _ends_in(t, FALSE_HEADS, true):
			continue
		if _ends_in(t, heads, false):
			return true
	return false


# Does `t` end in one of `words` — or, `whole`, is it one — each or its plural ("fly": flies)?
static func _ends_in(t: String, words: Array, whole: bool) -> bool:
	for w in words:
		for f in _plurals(w):
			if t == f or (not whole and t.length() > f.length() and t.ends_with(f)):
				return true
	return false


# A word and its plurals: with an -s or an -es, and a -y's -ies (fly: flies).
static func _plurals(w: String) -> Array:
	var out := [w, w + "s", w + "es"]
	if w.ends_with("y"):
		out.append(w.trim_suffix("y") + "ies")
	return out


func _physics_process(delta: float) -> void:
	if dead or not is_instance_valid(player):
		return
	atk_cd = max(0.0, atk_cd - delta)
	flash_t = max(0.0, flash_t - delta)
	hurt_t = max(0.0, hurt_t - delta)
	# ANIM-LOD: freeze the skinned pose of a FAR character (stop the per-frame AnimationMixer skeleton
	# update — the dominant main-thread cost when a dense camp packs dozens of skinned bodies). Guarded
	# on `_cur != ""` so a body that SPAWNED beyond the gate (a 3x3-ring corner reaches ~22-34m) is never
	# frozen in its bind/T-pose before its first clip plays; it re-animates the instant you close in.
	_lod_far = global_position.distance_to(player.global_position) > ANIM_LOD_DIST
	# (anim-LOD anim.active toggle REMOVED — it was the enemy-only manipulation the hero didn't have, and toggling
	# a playing AnimationMixer's `active` was the source of the creature "vibrate". The far-cull already stops
	# DRAWING distant creatures; the animation just plays cleanly like the hero's.)
	if _aerial:
		_bob_t += delta * 3.0
		slot_angle = fmod(slot_angle + _air_orbit * delta, TAU)   # circle the player at our own rate

	var ppos: Vector3 = player.global_position
	var to: Vector3 = ppos - global_position
	to.y = 0.0
	var dist := to.length()
	_report_detection(dist)
	var desired := Vector3.ZERO
	# THE BODY THE PLAYER IS ATTACKED AS (main.player_body): their own on foot, the hull they ride when riding (decision
	# 2), measured to this enemy's own body in clear space, in 3D (GBody.gap_to). To the rider's origin, an enemy bit a
	# horse's rider from 70% of bearings and a dragon's from none; from its own origin, 22 of 71 models bit with the
	# player inside them, a rat from 3.1 m inside its tail; in 2D, it bit a rider on a dragon hovering 20 m up.
	var pb := _player_body()
	_pb = pb
	var gx := global_transform
	var pxf: Transform3D = pb.owner.global_transform if is_instance_valid(pb.owner) else Transform3D()
	if not (gx == _was_xf and pxf == _was_pxf and pb == _was_pb and body == _was_body):
		_reach_memo = -1      # something moved: measure again
		_gap_memo = NAN
	_was_xf = gx
	_was_pxf = pxf
	_was_pb = pb
	_was_body = body

	# THE BITE (on the ground; a flyer swoops and a swimmer lunges, in _on_safe_velocity), INDEPENDENT of movement
	if not _aerial and not _floating:
		_strike(pb, delta)

	# ON LAND: a distinct slot AROUND the player -> enemies encircle, not bunch. IN WATER *or AIR*: hold on
	# our OWN approach bearing at a WIDE stand-off so swimmers/flyers TRAIL the player instead of ringing it.
	var slot: Vector3
	if _floating:
		# SWIMMERS trail on their OWN bearing — deliberate, so they never encircle a swimmer.
		var bear := global_position - ppos
		bear.y = 0.0
		if bear.length() < 0.05:
			bear = Vector3(cos(slot_angle), 0.0, sin(slot_angle))
		slot = _ring(pb, ppos, bear, _keep_gap())
	elif _aerial:
		# FLYERS take their DISTINCT golden-angle slot, exactly as ground enemies do. Sharing the
		# swimmers' own-bearing rule was the clumping: after a swoop every bat came out on nearly the
		# same bearing, and nothing in the loop ever pushed them apart again, so the flock merged into
		# a single point and stayed there.
		slot = _ring(pb, ppos, Vector3(cos(slot_angle), 0.0, sin(slot_angle)), _keep_gap())
	else:
		slot = _ring(pb, ppos, Vector3(cos(slot_angle), 0.0, sin(slot_angle)), _slot_gap())
	# CHASE THE SLOT DIRECTLY — no NavigationAgent path re-solve. ROOT CAUSE of the "all creatures
	# shake back-and-forth while moving": the staggered path re-solve (every 3rd frame) + get_next_path_position()
	# fed a small PERIODIC direction kick into `dir` each time the path rebuilt to the moving target, and the
	# damped velocity carried that as a per-frame wobble. Proven to be MOVEMENT (not the models/rig/anim) because
	# the rig-less STATIC meshes (centipede/scorpion/crab — no skeleton at all) shake identically. The slot is a
	# smooth function of the player position, so aiming straight at it gives a smooth heading. move_and_slide
	# still resolves collision; on the open island, direct chase is fine (a stuck body slides along structures).
	var dir := slot - global_position
	dir.y = 0.0
	# MOVING is HYSTERETIC (0.35 off / 0.7 on): the slot-jostle makes dir chatter across a bare 0.2
	# threshold every frame, which flip-flopped desired/walk/idle = vibration. One latched state gates them all.
	# HOLD once arrived at the assigned encircle slot (not just at the player): a packed melee ring otherwise
	# never latches _moving=false, so each body is shoved off its golden-angle slot every physics frame
	# = the residual cluster buzz interpolation can't cancel. Gating on slot-arrival (any bearing) holds the
	# FULL 360 ring still while attacking; chase resumes only when the (player-anchored) slot pulls away again.
	# ACROSS THE GROUND: the slot stands at the player's height, so measured in 3D a chaser 1.5 m up a slope from them was
	# always 1.5 m off it and never stopped (the enemy rig's slope group).
	# ...and ONLY WHEN THE SLOT MOVES: stopped, it leaves where it stands for its slot again once the slot has moved off where it
	# was when it stopped (the player moved), never because its own step into its bite took it off it. Its slot is 2D and its
	# bite 3D: parked at its slot uphill of a still player, out of its bite's window by height alone, its step in re-latched
	# the chase 0.7 m on, back to the slot — a T-rex on 25-45 deg, a horse, a cow, a triceratops and a mire dragon on 45
	# shuttled 0.41-0.44 m, 11-14 reversals in 5 s, and never bit (step 4's late re-check).
	var slot_d := dir.length()
	if _moving:
		if slot_d < 0.35:
			_moving = false
			_park_slot = slot
	elif slot_d > 0.7 and not (_park_slot.is_finite() and Vector2(slot.x - _park_slot.x, slot.z - _park_slot.z).length() <= 0.35):
		_moving = true
	if _moving:
		desired = dir.normalized() * speed
	# THE BODY IT STANDS IN: parked, its idle's; moving, its gaits' — grown only where that does not come down on the
	# player (_set_body)
	_set_body(body_move if (_moving or _aerial or _floating) else body_idle, pb)
	# PARKED = arrived + holding slot on the ground: once parked we HOLD the transform byte-stable so
	# an idle creature's skin has zero base-transform change (fixes the standing-still buzz, user-confirmed).
	# Rotation is NOT the moving-creature buzz (zero body yaw still buzzed — proven by A/B), so a non-parked
	# creature just faces the player naturally.
	_parked = (not _moving) and _ground_stuck and (not _aerial) and (not _floating)
	# It faces them, parked too: _face holds still inside its deadzone, so a parked body facing a still player is byte-still,
	# and a turn after a player who stepped round it is meant, not noise. Parked at the edge of its bite's cone, a dragon
	# held its wing nearest them, inside its bite's window, and never bit (the enemy rig's turn group).
	var turned := _face(to)
	# INTO ITS BITE: stopped where it cannot bite them, it steps — back from them when its turn is held (it would sweep onto
	# them) or its body is closer than its bite starts (_reach_lo), in toward them while it is further than its bite reaches
	# (_reach_hi: in until 0.1 m inside it) — then parks. Its slot is 2D and its bite 3D: a dragon parked beside the player
	# could neither turn nor bite for good, and one turned to them at its slot stood 1.37 m off, its head over theirs (the
	# enemy rig's turn group).
	var was := _adjust
	_adjust = 0
	if not _moving and not _aerial and not _floating and to.length() > 0.01:
		if is_nan(_gap_memo):
			_gap_memo = body_idle.gap_to(pb)
		var g := _gap_memo
		if not turned or g < _reach_lo() - 0.05:
			_adjust = -1
		elif g > _reach_hi() - (0.1 if was == 1 else 0.0):
			_adjust = 1
	if _adjust != 0:
		desired = to.normalized() * speed * 0.5 * float(_adjust)
		_parked = false
	# A ONE-SHOT THAT HAS PLAYED OUT HANDS BACK: its attack or its flinch over, what it moves or stands in plays again. It
	# never did — _cur stayed the attack, so after its first bite an enemy held the attack's last frame for good (on a
	# horse, its head 0.7 m out of the body it stands in) and every later attack, the same clip asked again, never played.
	if _cur != "" and (_cur == c_attack or _cur == c_hurt) and anim != null and (not anim.is_playing() or String(anim.current_animation) != _cur):
		_cur = ""
		if _floating and c_swim == "":
			GPose.tread(mesh_root, c_idle)   # its idle treaded again, as _enter_float holds it
		elif not _aerial and not _floating and (_move_clip() if _moving else c_idle) == "":
			# ...with nothing to hand back to, its rest pose — the one its body was fitted in. A dragon cast to walk has no
			# ground clip at all: after its first bite it stood in its attack's last frame, 1.34 m out of its body (step 4's
			# fix round).
			anim.stop()
			for sk in mesh_root.find_children("*", "Skeleton3D", true, false):
				(sk as Skeleton3D).reset_bone_poses()
	# anim: aerial holds a flap/fly clip; afloat its swim (or the treaded idle _enter_float set); grounded walk/idle
	if _aerial:
		if _cur != c_attack and hurt_t <= 0.0:
			var fclip := c_fly if c_fly != "" else c_walk
			if fclip != "" and _cur != fclip:
				_play(fclip)
	elif _floating:
		if _cur != c_attack and hurt_t <= 0.0 and c_swim != "" and _cur != c_swim:
			_play(c_swim)
	elif _cur != c_attack and hurt_t <= 0.0:
		_play(_move_clip() if _moving else c_idle)

	# CLIPLESS creature (no embedded clips + a foreign rig -> AnimRig returned null, so `anim` is null): the
	# NOTE: the procedural leg-swing now runs in _process (render rate) — see _process() — so it matches the
	# physics-INTERPOLATED mesh. Driving it here (60Hz physics) lagged the interpolated body = the jitter.

	# drive the move DIRECTLY with the stable desired velocity (damp/hold + gravity + water/aerial + fall-catcher)
	_on_safe_velocity(desired)
	# ...leaned onto the ground where it now stands, its bodies with it, read again only once it has moved (a parked body is held
	# byte-still) — far off, once it has moved on (_lean_due) — and drawn as its bodies hold it (GBody.upright: a lean that moves
	# none of it LEAN_TOL is none), set again only when the read is another (on level ground the same drop of its hover, every
	# tick it chases) ...
	if not _stance.is_empty() and global_transform != _lean_at and (not _lod_far or _lean_due()):
		_lean_at = global_transform
		var cm = world.get("chunk_manager") if is_instance_valid(world) else null
		var t: GTerrain = cm.terrain if cm != null and is_instance_valid(cm) else null
		var l := GBody.lean_on(self, t, _hc, _stance, GBody.LEAN_MAX, _foot_r, true) if not _floating else Transform3D.IDENTITY
		if l != _lean_read:
			_lean_read = l
			body_idle.set_lean(l)
			body_move.set_lean(l)
			_lean = Transform3D.IDENTITY if body_idle.lean == Transform3D.IDENTITY and body_move.lean == Transform3D.IDENTITY else l
	if not _aerial and not _floating:
		_walls()   # ...and where it now stands, what of it reaches through a wall


## Where its mesh root is drawn in its frame: leaned onto its ground, its offset, and lifted onto what its clip stands on.
func _drawn() -> Transform3D:
	return _lean * _mesh_local * Transform3D(Basis(), Vector3(0.0, _glift, 0.0))


## THE LIFT A PERSON IS DRAWN AT THIS FRAME (_process runs before its mixer draws the frame: each clip a frame's step on) — its
## clip's rise (GPose.ground_rise) and, through crossfades, the rises of the clips it fades from, weighed as its mixer weighs
## them: each fading clip keeps the weight it had left when the next play pushed it (the clip then playing's: 1 less theirs) and
## loses a frame's share of its fade each frame, the clip playing has 1 less theirs as the frame starts, and the weights are
## normalised (a person's mixer is not deterministic) — the mixer's own, to 0.001 (read off its skeleton; the enemy rig's (ground)
## holds the lift to them). Lerped from the lift at the play instead, and an attack stood as its rest, a skeleton set into an
## attack on the move drew its feet 4.4-4.5 cm into flat ground and 2.3-3.3 coming out of it (step 5d's review); its older fade
## left out, one cut short by an attack 4.2 (step 5d's fix round). Past ANIM_LOD_DIST its ground is read as level where it stands
## (none of the terrain read: it is out of sight of a few centimetres).
func _ground_lift(delta: float) -> float:
	var m3 := mesh_root.get_child(0) as Node3D if mesh_root.get_child_count() > 0 else null
	if m3 == null or anim == null or _floating or _aerial:
		_gfades.clear()
		return 0.0
	var cm = world.get("chunk_manager") if is_instance_valid(world) and not _lod_far else null
	var t: GTerrain = cm.terrain if cm != null and is_instance_valid(cm) else null
	var par := global_transform * _mesh_local
	var gp := global_position
	var to := GPose.ground_rise(ground, _cur, _cur == c_walk, anim.current_animation_position + delta * anim.get_playing_speed(),
		anim.current_animation_length, par, m3.transform, t, _hc, gp)
	if _gfades.is_empty() or not is_finite(to):
		return to if is_finite(to) else 0.0
	var tw := 1.0
	for fd: Array in _gfades:
		tw -= float(fd[4])
	tw = maxf(tw, 0.0)
	var acc := tw * to
	var step := absf(anim.speed_scale * delta)
	for fd: Array in _gfades:
		fd[4] = maxf(0.0, float(fd[4]) - step / maxf(float(fd[5]), 1e-3))
		fd[1] = float(fd[1]) + delta * float(fd[3])
		var r := GPose.ground_rise(ground, String(fd[0]), String(fd[0]) == c_walk, float(fd[1]), float(fd[2]), par, m3.transform, t, _hc, gp)
		if is_finite(r):
			acc += float(fd[4]) * r
			tw += float(fd[4])
	_gfades = _gfades.filter(func(fd): return float(fd[4]) > 0.0)
	return acc / tw if tw > 1e-6 else to


## Far off: has it moved on since its lean was read — LEAN_FAR_STEP across the ground, LEAN_FAR_TURN round, LEAN_ON up or down?
func _lean_due() -> bool:
	var d := global_position - _lean_at.origin
	return Vector2(d.x, d.z).length() >= LEAN_FAR_STEP or absf(d.y) >= GBody.LEAN_ON \
		or global_basis.z.angle_to(_lean_at.basis.z) >= LEAN_FAR_TURN


## The body the player is attacked as: main.player_body() (their round body on foot, the hull they ride), or — with no
## world to ask (a rig's bare enemy) — a round 0.4 m body on the player's origin, as main's own is.
func _player_body() -> GBody:
	var pb = world.call("player_body") if is_instance_valid(world) and world.has_method("player_body") else null
	if pb is GBody:
		return pb
	if _foot_pb == null or _foot_pb.owner != player:
		_foot_pb = GBody.round(PLAYER_R, 1.6).owned_by(player)
	return _foot_pb


## THE BITE'S WINDOW, in clear space between the two bodies (GBody.gap_to): from strike_reach - 0.05, where its attack as
## drawn just reaches them (closer, it would pass into them: it backs off to its slot first), out to attack_range in its
## old unit (PERSON_R0) or its strike, whichever is further. A person-sized enemy with no strike bites from 2.0 m centre
## to centre, as ever.
func _reach_lo() -> float:
	return strike_reach - 0.05


func _reach_hi() -> float:
	return maxf(strike_reach, attack_range - 2.0 * PERSON_R0)


## Where it parks: surround_radius in its old unit, and never closer than its strike can land from.
func _slot_gap() -> float:
	return maxf(surround_radius - 2.0 * PERSON_R0, strike_reach + 0.05)


## THE STEP THAT NEVER CLOSES ON THE PLAYER AND GOES ROUND THEM: from `cur` toward `nxt`, keeping `keep` of clear space
## between its body and their axis `pp` (or what it has, when less: a step never closes). Clear, it stands. Aimed in at
## them, its inward part becomes going round them — at its full pace, the side its way leans (its slot's side when it
## leans neither way) — and where sliding along a face turned to the slide would still close on them, it steps out from
## them as far as it would. The crowd's rule (GBody.clear_step: the inward part dropped) left a long creature beside the
## player at a crawl or held — its slot beyond them, a cow sat at their flank for 8 s — and a box sliding along a face
## 9 deg off the slide closed 1.3 mm a tick (the enemy rig's never-closer and turn groups).
func _round_step(cur: Vector2, nxt: Vector2, pp: Vector2, keep: float) -> Vector2:
	var yaw := rotation.y
	if body.gap(pp, nxt, yaw) >= keep:
		return nxt
	var out := body.nearest(pp, cur) - pp
	if out.length() < 0.001:
		return nxt                       # dead on top of them: every way out is away
	var n := out.normalized()
	var step := nxt - cur
	var radial := step.dot(n)
	var ok := nxt
	if radial < 0.0:
		var tang := step - n * radial
		if tang.length() < 1e-4:
			tang = Vector2(-n.y, n.x) * (1.0 if fposmod(slot_angle, TAU) < PI else -1.0)
		ok = cur + tang.normalized() * step.length()
	var want := minf(body.gap(pp, cur, yaw), keep)
	for i in 3:
		var g := body.gap(pp, ok, yaw)
		if g >= want - 1e-4:
			break
		ok += n * (want - g)
	return ok


## How far off the player's axis its body keeps as it steps and turns: KEEP_OFF, and while its attack plays its strike
## less 0.05 m too — the bite's own window — so the attack as drawn reaches them and goes no further into them. Still
## chasing its slot as it struck, a snake's lunge went 0.22 m into the player and a T-rex's 0.19 (the enemy rig).
func _keep_off_now() -> float:
	if _cur != "" and _cur == c_attack:
		return maxf(KEEP_OFF, PLAYER_R + strike_reach - 0.05)
	return KEEP_OFF


## A swimmer's or a flyer's stand-off (its own share of it: _air_keep), in clear space.
func _keep_gap() -> float:
	return maxf(SWIM_KEEP, surround_radius) * _air_keep - 2.0 * PERSON_R0


## A GROUND ATTACK: started when its body is in the bite's window of the player's with a line of sight, landing at its
## CONTACT — the moment its attack clip is drawn reaching furthest (GPose.body_fit's strike), not at the clip's first frame —
## and only if they are still in reach and in sight then: a step back dodges it.
func _strike(pb: GBody, delta: float) -> void:
	if _bite_t >= 0.0:
		_bite_t -= delta
		if _bite_t < 0.0 and _in_reach(pb):
			_bite()
		return
	if atk_cd > 0.0:
		return
	if not _in_reach(pb):
		if _reach_memo == 1:
			atk_cd = SIGHT_RETRY   # in its window with a wall in the way: it looks again in a moment, not every tick
		return
	atk_cd = 1.3
	_play(c_attack, false, true)
	_bite_t = _contact_time()
	if _bite_t <= 0.0:
		_bite_t = -1.0
		_bite()


## When its bite lands after the attack starts: its contact, a fraction of the clip — which plays from its start the
## moment it is asked (the blend only fades the last pose out under it).
func _contact_time() -> float:
	if anim != null and c_attack != "" and anim.has_animation(c_attack):
		return contact * anim.get_animation(c_attack).length
	return 0.0


## IN ITS BITE'S WINDOW, FACING THEM AND IN SIGHT — asked as an attack starts and at its contact. The bodies' half is
## measured once while neither moves (_reach_memo); the sight is looked at each time it is asked: memoised with them, a wall
## or a door shut between a parked biter and a still player never stopped its bites — a T-rex, a raptor, a skeleton and a
## smuggler bit 4 times in 5 s through it, no ray cast (step 4's late re-check). Two looks a bite, two lines each.
## A look that says otherwise than the last has the world changed between them — a wall or a door shut or gone — and what of
## its body reaches past a wall is looked at again (_walls), parked too: shut through a parked T-rex's, a horse's or a cow's
## front 0.6 m in, no box of it switched off for good (step 4's late re-check: the wall check's "never again until something
## moves").
func _in_reach(pb: GBody) -> bool:
	if _reach_memo < 0:
		# FAR OFF, NOTHING MEASURED: footprints further apart than its bite reaches however the two bodies lie are no bite —
		# measured instead, every chasing tick laid its body out and took the gap (a T-rex's tick 41-48 us chasing, against
		# 27-29 before the bodies: step 4's late re-check)
		if pb.owner != null and is_instance_valid(pb.owner):
			var apart := Vector2(global_position.x - pb.owner.global_position.x, global_position.z - pb.owner.global_position.z).length()
			if apart - _bound(body_idle) - _bound(pb) > _reach_hi():
				_reach_memo = 0
				return false
		var g := body_idle.gap_to(pb)
		_reach_memo = 1 if g >= _reach_lo() and g <= _reach_hi() and _facing(pb) else 0
	if _reach_memo != 1:
		return false
	var seen := _sees(pb)
	if seen != _seen:
		_seen = seen
		_wall_xf = Transform3D()   # _walls checks again this tick, where it stands
	return seen


## How far from its owner's origin a body reaches across the ground, whichever way it turns: its footprint's centre off the
## origin and its corner (or its radius), at the scale its owner is drawn at (GBody reads every one scaled) — a bound the gap
## between two bodies is never less than, less both.
static func _bound(b: GBody) -> float:
	if b == null:
		return 0.0
	var s := absf(b.owner.scale.x) if b.owner != null and is_instance_valid(b.owner) else 1.0
	if b.kind == GBody.ROUND:
		return (b.c.length() + b.r) * s
	b = b.leaned_bounds()   # leaned (GBody.set_lean), the boxes round it
	if b.parts.is_empty():
		return (b.c.length() + b.half.length()) * s
	var out := 0.0
	for q in b.parts:
		out = maxf(out, q.c.length() + q.half.length())
	return out * s


## ITS ATTACK REACHES FORWARD: what it bites is in front of it — the middle of their body within BITE_CONE of the way it
## faces. Measured from the body alone, a creature bit a player standing at its flank or its tail, its head turned away
## (and a long one, its attack's sweep 0.15 m into them as it slid round them: the enemy rig's turn group).
func _facing(pb: GBody) -> bool:
	var to := pb.centre() - global_position
	var t2 := Vector2(to.x, to.z)
	if t2.length() < 0.01:
		return true
	var f := global_transform.basis.z
	var f2 := Vector2(f.x, f.z)
	return f2.length() < 0.01 or t2.normalized().dot(f2.normalized()) >= cos(deg_to_rad(BITE_CONE))


## A LINE OF SIGHT, FROM ITS OWN SIDE OF EVERY WALL: nothing of the world (L_WORLD) between the middle of its mover — the
## capsule the physics keeps out of every wall (sight_from) — and the nearest point of its body to the middle of the body it
## attacks, nor between that point and theirs (the hull they ride, and everything under it, is theirs — not in the way; the
## ground is no wall: _clear_line). Neither a bite nor a blow (main._blow_sees asks sight_from too) goes through a wall: a
## raptor's body pressed to a 0.3 m wall reached 1.6 m past it and bit through it 1-5 times in 8 s (enemy-bodies review) —
## and measured from that nearest point alone, which a body pressed into a wall holds inside it or past it, a horse, a cow
## and a mire dragon still bit through it 5-6 times in 8 s with the player 0.2-2.0 m behind it, and the player's blow came
## back through it in 54 of 64 runs (step 4's review).
func _sees(pb: GBody) -> bool:
	if not is_inside_tree():
		return true
	var to := pb.centre()
	var from := body.nearest3(to)
	var ex: Array[RID] = []
	if pb.owner is Vehicle:
		ex = GProjectile.rids([pb.owner])
	return _clear_line(sight_from(), from, ex) and _clear_line(from, to, ex)


## The point every line of sight it has leaves from: the middle of the capsule it moves on, which no wall is ever between
## and the rest of it (the physics stands it on its own side of every one). Its origin a metre up with no mover yet.
func sight_from() -> Vector3:
	return _mover.global_position if _mover != null and is_instance_valid(_mover) else global_position + Vector3.UP


## NOTHING OF THE WORLD BETWEEN `a` AND `b` BUT THE GROUND: an L_WORLD ray (`ex` left out), every terrain body it meets passed
## through — on a slope the nearest point of a creature's body is on it or a hair in it, and the ground under two bodies is
## no wall between them (main._step_up_assist leaves it out the same way).
func _clear_line(a: Vector3, b: Vector3, ex: Array[RID]) -> bool:
	if a.distance_squared_to(b) < 1e-6:
		return true
	var q := PhysicsRayQueryParameters3D.create(a, b, 1)
	q.exclude = ex
	var space := get_world_3d().direct_space_state
	for i in 4:
		rays += 1
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return true
		var o = hit.get("collider")
		if not (o is Node and (o as Node).is_in_group("gogi_terrain")):
			return false
		var past := q.exclude
		past.append(hit["rid"])
		q.exclude = past
	return false


func _bite() -> void:
	if player.has_method("take_damage"):
		player.call("take_damage", atk_damage)
	elif is_instance_valid(world) and world.has_method("take_damage"):
		world.call("take_damage", atk_damage)   # the code-built player body carries no script — main owns HP


## THE SLOT `gap` OF CLEAR SPACE OUT FROM THE PLAYER'S BODY on the bearing `bear` (GBody.at_gap), plus its own reach toward
## them (_front): where its ORIGIN goes so its BODY parks that far off theirs — round the hull they ride, that far out from
## the hull. On foot a person-sized enemy's is where it always was, surround_radius from the player's middle; a creature's
## nose parks there, not its origin (a horse's 1.69 m slot had its head in the player).
func _ring(pb, ppos: Vector3, bear: Vector3, gap: float) -> Vector3:
	if pb is GBody:
		var q := (pb as GBody).at_gap(Vector2(bear.x, bear.z), gap + _front)
		return Vector3(q.x, ppos.y, q.y)
	return ppos + bear.normalized() * (PLAYER_R + gap + _front)


# PROCEDURAL WALK at RENDER RATE. For a clipless creature (its noisy embedded clips are frozen -> anim==null),
# swing the legs HERE in _process, not in _physics_process — so the bone poses update at the SAME cadence as the
# physics-INTERPOLATED mesh. Bones stepped at the 60Hz physics tick under a render-rate interpolated body is what
# read as the per-frame skinned "vibrate". Movement/gravity stay in _physics_process; this is render-only cosmetics.
func _process(delta: float) -> void:
	# INTERPOLATED-MESH DRIVE (see _mesh_driven doc): render the skinned mesh on the body's SMOOTH interpolated
	# path every frame, so an active skeleton animation can't make it snap to the raw per-tick physics position
	# and jump against the interpolation-smoothed world = the moving-creature vibrate. Runs for ALL creatures,
	# every state (incl. death) so the mesh never detaches from the body.
	if _mesh_driven and is_instance_valid(mesh_root):
		var _bt := get_global_transform_interpolated()
		# low-pass ONLY the position (rotation follows directly — rotation is not the noise). Frame-rate
		# independent exponential smoothing toward the true body position; the invisible body keeps exact collision.
		var _k := clampf(delta / VIS_SMOOTH_TAU, 0.0, 1.0)
		_vis_pos = _vis_pos.lerp(_bt.origin, _k)
		if not ground.is_empty():
			_glift = _ground_lift(delta)
		mesh_root.global_transform = Transform3D(_bt.basis, _vis_pos) * _drawn()
	if dead or not is_instance_valid(player):
		return
	# CLIPLESS creature (anim == null): swing the legs procedurally at render rate.
	if anim != null or _aerial or _floating:
		return
	if _moving and not _lod_far:
		_walk_phase += delta * (5.0 + speed)
		GPose.walk(self, _walk_phase)
		_gwalk = true
	elif _gwalk:
		GPose.walk_stop(self)
		_gwalk = false


## ITS MOVE THIS TICK (_move), from the move's own state (_vel), and then — VELOCITY IS ITS MOTION, in 3D — its velocity as it
## really went: auto-aim leads it by `velocity` (GProjectile.lead_point). A flyer's dive and climb and its stand-off are
## written to its position (its velocity kept only the horizontal chase, y 0: an arrow led at a stooping bat flew to where it
## was not), and on a slope move_and_slide's velocity ran up to 1.5 m/s off where a raptor went (the enemy rig) — while the
## next tick's move starts from it, so the move keeps its own (set to the motion, a raptor climbed 6.6 m of a 31 deg slope in
## 7 s instead of 12.4).
func _on_safe_velocity(safe: Vector3) -> void:
	if dead:
		return
	var p0 := global_position
	velocity = _vel
	_move(safe)
	_vel = velocity
	velocity = (global_position - p0) / get_physics_process_delta_time()


func _move(safe: Vector3) -> void:
	# GRAVITY + floor-snap so the enemy HUGS the terrain on descents. The old forced
	# y=0 velocity (no gravity) kept the body's height as the ground fell away, and the
	# up-only fall-catcher below never pulls DOWN — so across rolling terrain an enemy
	# RATCHETED upward (climbing every hill via slope-collision, never descending) until
	# it floated. Invisible on foot; glaring from the air — chasing a FLYING player,
	# enemies climb hill after hill and "pop up into the sky". Airborne -> accumulate
	# gravity so move_and_slide lands the body on the next collider BELOW (terrain OR a
	# structure roof, so it's never yanked off an elevated platform — the reason the
	# fall-catcher stayed up-only); on the floor -> flat run.
	var cm = world.get("chunk_manager") if is_instance_valid(world) else null
	if cm != null and not is_instance_valid(cm):
		cm = null
	var adt := get_physics_process_delta_time()
	var p0 := global_position
	var pb := _pb if _pb != null else _player_body()   # asked once a tick (_physics_process)
	# AERIAL: FLY at hover_alt above the terrain, chase horizontally, gently bob, and SWOOP to bite (_fly). No gravity /
	# no fall-catcher (a flyer must never be pulled to the ground).
	if _aerial:
		_fly(safe, cm, pb, adt)
		return
	# WATER: float at the surface (swim) in deep water instead of walking the submerged seabed or sinking
	# out of view. Land animals float only past a wade; aquatic creatures ride any water.
	if cm != null and cm.water_cfg != null:
		var wgy: float = cm._ground_y(global_position.x, global_position.z)
		var st: Dictionary = GWater.float_state(cm.water_level, wgy, global_position.y, (0.0 if _aquatic else FLOAT_WADE), _submerge)
		if bool(st["float"]):
			if not _floating:
				_enter_float()
			_swim(safe, pb, adt)
			global_position.y = float(st["y"])
			return
		elif _floating:
			_exit_float()
	var vy := 0.0 if (is_on_floor() or _ground_stuck) else velocity.y - GRAVITY * adt
	if _moving or _adjust != 0:
		# damp toward the 'safe' chase velocity instead of snapping to it -> a frame-to-frame direction flip
		# (worst in a dense pack) is filtered out while the body still converges on its slot.
		velocity = Vector3(lerpf(velocity.x, safe.x, minf(1.0, 14.0 * adt)), vy, lerpf(velocity.z, safe.z, minf(1.0, 14.0 * adt)))
	else:
		# parked at the slot: Decelerate to a true stop and hold, so a parked creature (incl. the legless snake)
		# sits rock-still instead of being re-steered back and forth = vibrate.
		velocity = Vector3(move_toward(velocity.x, 0.0, speed * 6.0 * adt), vy, move_toward(velocity.z, 0.0, speed * 6.0 * adt))
		# PARK-LOCK: once actually stopped AND grounded, HOLD the transform byte-stable — skip
		# move_and_slide entirely so the per-tick collision/gravity re-solve on uneven terrain can't wobble the
		# base transform that the render-rate skinned anim amplifies into the whole-body buzz (root-caused by the
		# the body-freeze A/B). Position is already at the slot with Y pinned, so holding it is continuous ->
		# no snap when it later un-parks. Any residual/knockback velocity (>0.05) falls through to move_and_slide.
		if _parked and absf(velocity.x) < 0.05 and absf(velocity.z) < 0.05:
			velocity.y = 0.0
			return
	# NEVER CLOSER, AND ROUND THEM: a step that would bring its body within the player's capsule goes round them instead
	# (_round_step) — never carrying them. Chasing through an idle player, a body nothing held off carried them up to
	# 15.3 m (a cow), 9.3 (a T-rex) (enemy-bodies investigation).
	if pb.kind == GBody.ROUND and is_instance_valid(pb.owner):
		var cur := Vector2(p0.x, p0.z)
		var nxt := cur + Vector2(velocity.x, velocity.z) * adt
		var ok := _round_step(cur, nxt, Vector2(pb.owner.global_position.x, pb.owner.global_position.z), _keep_off_now())
		if ok != nxt:
			velocity.x = (ok.x - cur.x) / adt
			velocity.z = (ok.y - cur.y) / adt
	move_and_slide()
	# GROUND-STICK (ports the player's main.gd fix): over a cell whose trimesh collider hasn't streamed in yet,
	# is_on_floor() reads FALSE, so gravity accumulated velocity.y, the body sank, and the OLD up-only catcher
	# snapped Y back but left velocity.y large-negative and is_on_floor() still false -> it sank again next tick
	# -> a per-PHYSICS-TICK vertical sawtooth (interpolation renders it as a smooth constant buzz; FPS-independent;
	# untouched by any render-side lag cut = the exact jitter). Pin to the analytic heightmap AND zero velocity.y
	# AND latch grounded so gravity can't re-fire -> the root Y is constant tick-over-tick -> no buzz. The
	# y <= gy + 0.1 guard preserves "never yank a creature off an elevated structure" (a roof has y >> gy).
	# LATCHED ON THE FLOOR, PINNED ONLY OFF IT: pinned every tick, a round capsule's bottom was pushed 6-12 cm into a
	# 31-45 deg slope and it stalled there (x 6.3 / 3.9 m in 7 s up them; the player, pinned only off the floor, 18.7 /
	# 13.9). The pin is also what latched _ground_stuck, which PARK-LOCK needs: pinned only off the floor, no enemy ever
	# parked (0% against 100%, a parked tick 3-3.7x the cost). Latched on is_on_floor() too: 100% parked, and it climbs
	# x 16.3 / 12.3 (enemy-bodies review).
	_ground_stuck = is_on_floor()
	if not _ground_stuck and cm != null:
		var gy: float = cm._ground_y(global_position.x, global_position.z)
		if velocity.y <= 0.5 and global_position.y <= gy + 0.1:
			global_position.y = gy
			velocity.y = 0.0
			_ground_stuck = true


## A FLYER (D12): it cruises at hover_alt over the ground (homing toward a high player), trails at its stand-off on its own
## slot, and — its attack ready, within ATTACK_ARM of that stand-off and in sight — SWOOPS: it dives at the player's body
## at SWOOP_SPEED, bites on CONTACT (its body within LUNGE_CONTACT of theirs, in 3D), then climbs back to cruise and out to its
## stand-off for RECOVER_TIME; a dive that has not connected in STRIKE_TIME gives up. A dive never closes inside its strike.
## Its stand-off held it 2.6-5.9 m out and its bite reached 2.0 m from its origin: 0 bites in 30 s (investigation).
func _fly(safe: Vector3, cm, pb: GBody, adt: float) -> void:
	var agy: float = cm._ground_y(global_position.x, global_position.z) if cm != null else 0.0
	# CRUISE altitude homes toward the player's height (bounded), so flyers CLIMB to chase a plane / a
	# high player instead of hugging the ground far below. Grounded player -> hovers at hover_alt overhead.
	var cruise := agy + hover_alt
	if is_instance_valid(player):
		cruise = clampf(player.global_position.y, agy + hover_alt, agy + AERIAL_MAX_CLIMB)
	_strike_t += adt
	if _strike_state == 1:
		if _lunge(pb, SWOOP_SPEED, true):
			return
	velocity = Vector3(safe.x, 0.0, safe.z)
	move_and_slide()
	# KEEP-AWAY: hold a stand-off across the ground so flyers don't ring/surround the player in the air — they trail at
	# distance and only dart in on a swoop.
	_keep_off(pb)
	global_position.y = lerpf(global_position.y, cruise + sin(_bob_t) * AERIAL_BOB, minf(1.0, 6.0 * adt))
	_arm(pb)


## A SWIMMER (D12) — aquatic, or a land creature forced into deep water: it trails at its stand-off, LUNGES along the water
## at LUNGE_SPEED (under the player's swim speed: they can always get away) when its attack is ready, bites on contact and
## backs off to its stand-off; as the swoop. A body alone bit a swimmer with its nose 0.38 m inside them, and a floating
## horse from 2.2 m of water (enemy-bodies review).
func _swim(safe: Vector3, pb: GBody, adt: float) -> void:
	_strike_t += adt
	if _strike_state == 1:
		if _lunge(pb, LUNGE_SPEED, false):
			return
	# CAP in-water horizontal speed strictly below the player's SWIM_SPEED (the chase 'safe' otherwise
	# carries the full land speed up to 3.9+), so the player can always out-swim every creature.
	var sv := Vector2(safe.x, safe.z)
	if sv.length() > SWIM_MAX:
		sv = sv.normalized() * SWIM_MAX
	velocity = Vector3(sv.x, 0.0, sv.y)
	move_and_slide()
	# KEEP-AWAY: floating we share the player's surface plane, so the chase steering would pile every swimmer ONTO the
	# player — the "stuck to the character" blob. Hold the stand-off so swimmers RING the player, never overlap.
	_keep_off(pb)
	_arm(pb)


## The strike of a swoop or a lunge under way, one tick: true while it is still striking (the caller moves it no further).
## CONTACT bites (in sight) and recovers — its body within LUNGE_CONTACT of theirs: its attack clip started when the dive
## did and lands where the dive does, so its strike is no reach here (a dragon diving with a 0.7 m strike bit from 0.8 m, its
## jaws drawn 1.7-1.8 m off the player: the enemy rig's air group). STRIKE_TIME without contact recovers. Each step goes at
## the player's body — its middle, across the water for a swimmer — and stops at half that contact.
func _lunge(pb: GBody, spd: float, dive: bool) -> bool:
	var g := body.gap_to(pb)
	if g <= LUNGE_CONTACT:
		if _sees(pb):
			_bite()
		_recover()
		return false
	if _strike_t > STRIKE_TIME:
		_recover()
		return false
	var to := pb.centre() - body.nearest3(pb.centre())
	if not dive:
		to.y = 0.0
	var l := to.length()
	if l < 1e-4:
		_recover()
		return false
	var step := minf(spd * get_physics_process_delta_time(), maxf(0.0, g - LUNGE_CONTACT * 0.5))
	velocity = to / l * (step / get_physics_process_delta_time())
	move_and_slide()
	return true


## Ready to strike (its cooldown spent, within ATTACK_ARM of its stand-off, in sight): a swoop or a lunge begins.
func _arm(pb: GBody) -> void:
	if _strike_state == 2 and _strike_t > RECOVER_TIME:
		_strike_state = 0
	if _strike_state != 0 or atk_cd > 0.0:
		return
	if _hgap(pb) <= _keep_gap() + ATTACK_ARM and _sees(pb):
		_strike_state = 1
		_strike_t = 0.0
		_play(c_attack, false, true)


func _recover() -> void:
	_strike_state = 2
	_strike_t = 0.0
	atk_cd = 1.3 + randf() * 0.6   # desynced, so a flock does not strike as one


## The clear space across the ground between its body's footprint and the player's body (the hull's footprint they ride,
## or their capsule): the stand-off a flyer or a swimmer keeps, whatever height it holds.
func _hgap(pb: GBody) -> float:
	var q := pb.nearest(Vector2(global_position.x, global_position.z))
	return body.gap(q) - (pb.r * absf(pb.owner.scale.x) if pb.kind != GBody.BOX else 0.0)


## Out to the stand-off: pushed straight away from the player's body by what it lacks of _keep_gap.
func _keep_off(pb: GBody) -> void:
	if not is_instance_valid(pb.owner):
		return
	var lack := _keep_gap() - _hgap(pb)
	if lack <= 0.0:
		return
	var me := Vector2(global_position.x, global_position.z)
	var away := me - pb.nearest(me)
	if away.length() < 0.001:
		away = Vector2(cos(slot_angle), sin(slot_angle))
	# out at its own pace, not in one tick: bitten from contact, a bat was put 2.2 m out in a tick (130 m/s)
	away = away.normalized() * minf(lack, KEEP_OFF_PACE * speed * get_physics_process_delta_time())
	global_position.x += away.x
	global_position.z += away.y


## THE BODY IT STANDS IN, swapped at the edge of moving (see `body`). The moving body holds its gaits' sweep, more than it
## draws standing; grown beside the player it would come down on them (a teleported collider depenetrates them: a shove),
## so it grows only where it stays as clear of them as the body it leaves.
func _set_body(b: GBody, pb: GBody) -> void:
	if b == body or b == null or not _cols.has(b) or not _cols.has(body):
		return
	if b.gap_to(pb) < minf(0.0, body.gap_to(pb)):
		return
	(_cols[body] as CollisionObject3D).collision_layer = 0
	(_cols[b] as CollisionObject3D).collision_layer = 4
	body = b   # ...and checked against the walls where it is, this tick (_walls)


## WALL-AWARE: a box of the body it stands in that reaches through a wall stops being met while it does (its shape off);
## the mover, on L_ENEMY too, still stands solid on its own side. One rigid body poked 1.26-1.60 m through a 0.3 m wall,
## blocked the player walking along the far side and was bitten from (enemy-bodies review). A ray across the ground from its
## origin, at each box's middle height, to each far corner of that box — the ground passed through (_clear_line): read as a
## wall, the slope a creature climbed switched its head off, and parked up a 45 deg slope a T-rex, a mire dragon and a cow
## kept 2 of their 5 boxes walk-through and shoot-through (step 4's review). Checked (after its move, every ground tick):
## the moment the body it stands in is another (the one it swaps to was last checked wherever it last stood), every
## WALL_EVERY ticks while it moves or turns, and once where it stops — then, parked, when its look at the player says
## otherwise than the last (a wall shut or gone between them: _in_reach) and every WALL_OFF_EVERY ticks while a box of it is
## off; nothing else until something moves: a parked body holds still, and so does what it reaches (PARK-LOCK). Never again
## until it moved, a wall shut through a parked creature's front left its boxes solid past it, and boxes a wall had switched
## off stayed off once it had gone (step 4's late re-check).
func _walls() -> void:
	var gx := global_transform
	var stopped := gx == _last_xf
	_last_xf = gx
	var col = _cols.get(body)
	if col == null:
		return
	_wall_tick -= 1
	if body == _wall_body and (gx == _wall_xf or (_wall_tick > 0 and not stopped)) and not (_walls_off > 0 and _wall_tick <= -WALL_OFF_EVERY):
		return
	# after its first, a camp spawned together checks on ticks of its own (_stagger): set and never read, it fired all of
	# theirs on one tick
	_wall_tick = WALL_EVERY + (_stagger if _wall_body == null else 0)
	_wall_xf = gx
	_wall_body = body
	var parts: Array = body.parts if not body.parts.is_empty() else [body]
	var shapes := (col as Node).get_children()
	var none: Array[RID] = []
	_walls_off = 0
	for i in mini(parts.size(), shapes.size()):
		var q: GBody = parts[i]
		var midy := (q.y0 + q.y1) * 0.5
		var fz := q.c.y + q.half.y if q.c.y >= 0.0 else q.c.y - q.half.y
		var off := false
		for sx in [-1.0, 1.0]:
			# ...where the box is: leaned with it (GBody.set_lean), as its shape is
			var lx := gx * body.lean
			if not _clear_line(lx * Vector3(0.0, midy, 0.0), lx * Vector3(q.c.x + sx * q.half.x, midy, fz), none):
				off = true
				break
		var cs := shapes[i] as CollisionShape3D
		_walls_off += 1 if off else 0
		if cs != null and cs.disabled != off:
			cs.set_deferred("disabled", off)


func _enter_float() -> void:
	_floating = true
	# At the surface we ride the SAME plane as a swimming player, whose collision_mask includes L_ENEMY —
	# but we don't yield (our mask is world-only) and RVO ignores the player, so that solidity GLUES the
	# swimmer to us, fusing player+creatures into one blob. Drop mutual collision with the player WHILE
	# FLOATING so the swimmer passes freely through/around us; surround_radius still holds our encircle ring.
	if is_instance_valid(player) and player is PhysicsBody3D:
		add_collision_exception_with(player)
		for col in _cols.values():
			(col as PhysicsBody3D).add_collision_exception_with(player)   # ...and its body's colliders: all of it
	if c_swim != "":
		_play(c_swim)
	else:
		# The idle held and leaned (GPose.tread), not GPose.swim over whatever was on the bones: a
		# creature that chases into the water arrives MID-STRIDE, and that frame was frozen for the
		# whole swim. tread() drives the AnimationPlayer itself, so _cur must not claim a clip.
		GPose.tread(mesh_root, c_idle)
		_cur = ""

func _exit_float() -> void:
	_floating = false
	if is_instance_valid(player) and player is PhysicsBody3D:
		remove_collision_exception_with(player)   # solid again on land (on-land encircle/no-pass-through unchanged)
		for col in _cols.values():
			(col as PhysicsBody3D).remove_collision_exception_with(player)
	if c_swim == "":
		GPose.stand(mesh_root)
	_cur = ""


## THE one damage door (Wave-4 contract): melee (main._attack) AND projectiles (a shot whose ray met
## this body, resolved by main._projectile_hit) both land here — nothing else writes hp.
## The param stays FLOAT (not the draft int): rpg.weapon_damage() is float, and an int
## caller (a projectile passing the schema's damage) converts losslessly, so both fit.
func take_hit(d: float) -> void:
	if dead:
		return
	d = minf(d, hp_max * HIT_CAP_FRAC)   # never one-shot: cap a single blow so a kill always takes 2+ hits
	var frac_before := hp / maxf(1.0, hp_max)
	hp -= d
	_report_hp_crossing(frac_before, hp / maxf(1.0, hp_max))
	flash_t = 0.12
	AudioManager.play_sfx("hit")
	if hp <= 0.0:
		_die()
	else:
		hurt_t = 0.3
		_play(c_hurt, false)   # brief flinch (rig-lab/library "hurt"/"Hit_A" clip; "" -> silent no-op)


## HEALTH CROSSING -> the rule layer. Health was always tracked correctly here; nothing ever
## ANNOUNCED it, so a boss rule waiting on `enemy_hp_crossed` sat in the dispatch table forever and
## the playbook's own two-phase example could not work.
##
## The thresholds come FROM the rules (cached at setup), so this stays a report rather than a policy:
## the enemy does not decide what "half health" means, it just says when a line was crossed. Fires
## only on a DOWNWARD crossing — a heal should not re-trigger a phase change.
# DETECTION IS REPORTED, NOT ENFORCED.
#
# These creatures have always chased from any distance — `player` is assigned at spawn and the AI
# never asks how far away it is. Adding a real aggro radius would change how every existing game
# plays, which is not what a "make the event fire" pass is for. So this is purely observational:
# it raises `enemy_detected_player` when the gap closes past DETECT_RANGE and `enemy_lost_player`
# when it opens past DETECT_RANGE * DETECT_HYSTERESIS. Behaviour is identical; the game can now
# hear about it (a stinger, reinforcements, a boss line) instead of being unable to tell.
#
# The hysteresis band is the point: without it, a player pacing the threshold would machine-gun the
# pair of events every frame, and a rule chained to either would fire dozens of times a second.
const DETECT_RANGE := 18.0
const DETECT_HYSTERESIS := 1.6
var _detected := false


func _report_detection(dist: float) -> void:
	if _detected:
		if dist <= DETECT_RANGE * DETECT_HYSTERESIS:
			return
		_detected = false
	else:
		if dist > DETECT_RANGE:
			return
		_detected = true
	# Same back-reference the hp-crossing reporter uses. A get_node("Main") lookup would work today
	# and break the first time the scene root is renamed, with no error — just an event that stopped.
	if not is_instance_valid(world) or world.director == null or not world.director.has_method("fire"):
		return
	world.director.fire("enemy_detected_player" if _detected else "enemy_lost_player",
		{"id": String(get_meta("gogi_id", "")), "kind": String(kind)})


func _report_hp_crossing(before: float, after: float) -> void:
	if _hp_marks.is_empty() or not is_instance_valid(world):
		return
	for m0 in _hp_marks:
		var m := float(m0)
		if before > m and after <= m:
			if world.director != null and world.director.has_method("fire"):
				world.director.fire("enemy_hp_crossed", {"id": kind, "kind": kind, "at": m})


func _die() -> void:
	dead = true
	velocity = Vector3.ZERO
	_vel = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	for col in _cols.values():
		(col as CollisionObject3D).collision_layer = 0   # a dead body is no body: shots and the player pass it
	if is_instance_valid(world) and world.has_method("on_enemy_killed"):
		world.on_enemy_killed(kind)   # -> XP + quest kill progress (authored enemy_type)
	_play(c_die, false)
	var t := create_tween()
	t.tween_interval(1.1)
	t.tween_callback(queue_free)


# ---------------- anim ----------------

func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim(c)
		if r != null:
			return r
	return null


## Every role through the ONE resolver (clip_role.gd). This had its own _pick, which looped CLIPS
## before keys — so on every rig shipping both it took "run" for WALK (alphabetical order), and a
## slowed enemy sprinted on the spot — and matched raw substrings ("soldier" is a death, "swing" is a
## wing). GClip returns "" rather than another action's clip.
func _resolve_clips() -> void:
	c_idle = GClip.resolve(anim, "idle")
	c_walk = GClip.resolve(anim, "walk")
	c_run = GClip.resolve(anim, "run")
	c_attack = GClip.resolve(anim, "attack")
	c_die = GClip.resolve(anim, "death")
	c_hurt = GClip.resolve(anim, "hurt")
	c_swim = GClip.resolve(anim, "swim")
	c_fly = GClip.resolve(anim, "fly")


## WALK OR RUN BY PACE (RUN_PACE). A chaser at the default pace (3.0-3.9 m/s) runs; one a cell
## authors slow (`enemy_speed` 0.5 -> 1.5-1.95 m/s) walks. The old lookup put "run" in the walk slot by
## clip ORDER, which was right for a default chaser by accident and a sprint in slow motion for a slow one.
## With no walk or run clip it moves in its idle: _play("") plays nothing, so it moved in whatever played last — after a
## bite, the attack's last frame (a frog crossed the field frozen mid-lunge: the enemy rig).
func _move_clip() -> String:
	if speed >= RUN_PACE and c_run != "":
		return c_run
	if c_walk != "":
		return c_walk
	return c_run if c_run != "" else c_idle


## BLEND, do not snap. This played every clip with `anim.play(clip)` and no blend time at all, so
## an enemy switching idle->chase->attack CUT between poses on a single frame. On the hero the same
## transition has always crossfaded; enemies are most of what you actually watch move in a fight,
## and the hard cut is what read as puppet-like.
##
## Short into an attack so the swing still lands on the beat the damage window expects, longer back
## into locomotion where a soft settle looks right.
const BLEND_FAST := 0.06
const BLEND_SOFT := 0.14

## `restart`: from its first frame even when it is the clip already playing (an attack is a one-shot: its contact is timed
## from its start, _contact_time).
func _play(clip: String, loop := true, restart := false) -> void:
	if anim == null or clip == "" or (_cur == clip and not restart):
		return
	_cur = clip
	if anim.has_animation(clip):
		var a := anim.get_animation(clip)
		if a:
			a.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
		# the clip it fades from, where it stands in it, with the weight it has left (a person's lift weighs them: _ground_lift;
		# a restart fades from itself, which weighs as itself)
		if not ground.is_empty() and String(anim.assigned_animation) != "" and String(anim.assigned_animation) != clip:
			var left := 1.0
			for fd: Array in _gfades:
				left -= float(fd[4])
			_gfades.append([String(anim.assigned_animation), anim.current_animation_position, anim.current_animation_length,
				anim.get_playing_speed() if anim.is_playing() else 0.0, maxf(left, 0.0), BLEND_FAST if not loop else BLEND_SOFT])
		anim.play(clip, BLEND_FAST if not loop else BLEND_SOFT)
		if restart and anim.current_animation_position > 0.0:
			anim.seek(0.0, true)


func _set_far_cull(n: Node, vis_end: float) -> void:
	if n is GeometryInstance3D:
		var gi := n as GeometryInstance3D
		gi.visibility_range_end = vis_end
		gi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED   # hard cutoff -> no dither shimmer on a moving creature
	for c in n.get_children():
		_set_far_cull(c, vis_end)


## Turns toward `dir`, damped; false when the turn guard held it (it would have swept onto the player).
func _face(dir: Vector3) -> bool:
	if dir.length() < 0.05:
		return true
	# DAMPED: the old per-frame look_at() hard-set yaw from an RVO-noisy position -> a few-degrees swing that a
	# long snake / colossal boss lever-arm-amplifies into visible vibration. atan2(dir.x, dir.z) is the SAME yaw
	# (+Z toward the player, matching the old look_at and wander.gd), but a deadzone + lerp filter the noise.
	var tgt := atan2(dir.x, dir.z)
	if absf(wrapf(tgt - rotation.y, -PI, PI)) < 0.05:
		return true   # ~2.9deg deadzone: already facing -> don't re-snap to sub-degree bearing noise
	var yaw := lerp_angle(rotation.y, tgt, minf(1.0, 12.0 * get_physics_process_delta_time()))
	# THE TURN THAT NEVER SWEEPS ONTO THE PLAYER (the crowd's turn guard, GBody.turn_ok): a long body sweeps when it turns
	# — a 4 m creature turning beside the player shoved them 1.91 m (enemy-bodies investigation) — so a turn that would
	# bring it within KEEP_OFF of them, and closer than it is, waits. A person's capsule too: it is centred on its depth,
	# not its origin (the default skeleton's 0.1 m ahead of it), and the crowd's "a round body always may" turned one parked
	# against the player's capsule (the enemy rig's pack group: a run that could move 0.03 m).
	var pb := _pb if _pb != null else _player_body()
	if body != null and pb.kind == GBody.ROUND and is_instance_valid(pb.owner):
		var at := Vector2(global_position.x, global_position.z)
		var pp := Vector2(pb.owner.global_position.x, pb.owner.global_position.z)
		var g1 := body.gap(pp, at, yaw)
		if g1 < _keep_off_now() and g1 < body.gap(pp, at, rotation.y):
			return false
	rotation.y = yaw
	return true


# Hide the enemy mesh when the CAMERA is pressed against its BODY (fed by main._process): a body
# against the lens reads as a "popup". `cam_dist` is the camera's clear distance to the body it draws (GBody.dist3:
# main measures it), so one threshold serves a rat and a dinosaur: CAM_FADE_GAP is the old CAM_FADE_NEAR measured to
# a person's centre, less their 0.4 m capsule. Measured to one point half its height up, a 4.5 m creature's tail and
# nose filled the lens 3-4.5 m from that point and never faded. The SpringArm masks world-only, so it never pulls in on
# enemies (layer 4). (#6)
func set_camera_near(cam_dist: float) -> void:
	if mesh_root == null or not is_instance_valid(mesh_root):
		return
	# HYSTERESIS band: a body hovering right at the fade threshold (a cluster pressing the lens) used to flip
	# visible/hidden every frame = flicker "glitch". Hide only when strictly inside the threshold; reveal only
	# after clearing it by 35%.
	var near_t := CAM_FADE_GAP
	if _cam_hidden:
		if cam_dist > near_t * 1.35:
			_cam_hidden = false
	elif cam_dist <= near_t:
		_cam_hidden = true
	mesh_root.visible = not _cam_hidden
