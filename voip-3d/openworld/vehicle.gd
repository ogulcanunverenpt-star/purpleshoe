class_name Vehicle extends CharacterBody3D
## BOARDABLE VEHICLES & MOUNTS (v3 — Wave 3 "motion profiles + mounts") — a world-level "vehicles"
## entry the player can walk up to, BOARD, and DRIVE/RIDE:
##   "vehicles": [{"pos": [x, z], "name": "...", "profile": "car"|"tank"|"boat"|"plane"|"horse"|
##                 "bull"|"dragon" (default "car"), "color": [r, g, b], "model": "<optional>"}]
## main.gd spawns these ONCE at boot onto the PERSISTENT layer (never cell-parented — chunk
## eviction and zone transitions can't touch them). The body is a CharacterBody3D with a box
## collider derived from the composed/scale-normalised AABB, so buildings/walls stop it
## (move_and_slide) while y terrain-follows the rendered surface via GTerrain.height. While
## driving, main.gd feeds its EXISTING input vector here and the player is parked ON the
## boardable every physics tick — so chunk streaming and reach_area quest notifications (both
## read player.global_position) follow the DRIVEN position with no extra wiring.
##
## PROFILES (Wave 3):
##   car    — Wave-2 articulated parametric car, byte-equivalent behavior (door choreography).
##   tank   — turn-in-place tracks; parametric hull/glacis/turret body; door-less Wave-1 style
##            swap-in boarding (hatch choreography is OUT OF SCOPE v1 — the driver is hidden,
##            exactly the Wave-1 fused-GLB idiom).
##   boat   — rides the WATER LEVEL (set_water) with a small bob, not the terrain; a world with
##            NO water degrades to car-on-terrain. Step-in boarding (no door) + GPose.sit.
##   plane  — arcade flight: car-like taxi, lift-off above takeoff speed, pitch/bank in the air,
##            SPEED_MAX 22 / ALT_MAX 32 envelope, lands when terrain-relative height < 0.5.
##            Step-in boarding + GPose.sit. Cosmetic spinning prop disc.
##   horse / bull / dragon — MOUNTS: no parametric body; "model" omitted resolves a LIBRARY
##            DEFAULT (main.gd asks Vehicle.default_model_path). Rider is VISIBLE, parked on a
##            "MountMarker" seated ON the creature's DORSAL SURFACE (mesh-vertex back-line sample
##            at a per-profile seat z — never the AABB top, which is the raised head/crest) and
##            posed astride via GPose.ride. An engine-built parametric saddle marks the seat
##            (spec {"saddle": false} disables; generators ship mounts BARE-BACKED). Gait
##            sync plays the model's EMBEDDED clips (walk/gallop/idle; dragon flap/glide) —
##            clipless creatures still ride, silently un-animated. Dragon shares the plane's
##            flight envelope and walks when landed — on its feet, the way the horse walks.
##            A skinned mount COLLIDES AS THE BODY IT DRAWS (_mount_drawn): its hull is the box its
##            skin fills over the gaits it plays, it stands on what it draws, and USE, the label,
##            boarding, the dismount and an enemy's reach all measure to that hull.
##
## BODY MODES (decided by the SPEC, not by fetch success):
##   - VEHICLE profiles, "model" OMITTED  -> the profile's PARAMETRIC body (GShapes + GSurf).
##   - VEHICLE profiles, "model" PRESENT  -> the Wave-1 fused-GLB swap-in boarding, with a
##     VISIBLE-DRIVER upgrade: setup synthesizes a "SeatMarker" at the CABIN CENTRE at seat
##     height — enter() then seats the driver visibly (GPose.sit). Closed cabs ("cab":"closed")
##     and flyer profiles keep the Wave-1 instant hide. (The old cabin-column PROBE was retired;
##     solidity stopped being the test when it went — see _probe_cabin_seat.) A spec "seat": [x, y, z]
##     (self-local metres) or an authored SaddleMarker/SeatMarker node in the GLB wins outright.
##   - MOUNT profiles -> ALWAYS the model path (library default or spec model) and ALWAYS the
##     mount boarding (visible rider at the MountMarker) — a mount has no cabin to hide in, so
##     the fused-GLB "hide the driver" fallback would strand an invisible rider on its back.
##
## HOT-RELOAD SAFETY: main.gd calls exit() before freeing. exit() mid-ENTER is guarded (no-op),
## exit() mid-FLIGHT is a guarded no-op too (no mid-air dismounts — the chunk movement contract
## has no gravity, a dropped player would float), and _exit_tree() force-restores the driver
## (pose/visibility/collision/position AT TERRAIN HEIGHT) if the node is freed mid-choreography,
## mid-drive or mid-flight, so a chat edit can never strand a hidden, posed or airborne player.

# Per-profile tuning. max_speed/accel/brake/turn_rate are the GROUND (or water) gait; flight
# uses the shared SPEED_MAX/ALT_MAX envelope below. Flags: steer_fixed (turn-in-place, steering
# NOT scaled by speed), steer_floor (min low-speed steering authority, 0..1 — the hull/nose turns
# while spooling up), water (rides the water level), fly (has the flight model, "takeoff" =
# lift-off speed), mount (creature: model path + MountMarker + GPose.ride + gait sync).
const PROFILES := {
	"car": {
		"length": 4.0,       # longest horizontal dim after scale-normalisation (same idiom as traffic)
		"max_speed": 12.0,   # m/s
		"accel": 14.0,       # m/s^2 toward the throttle target
		"brake": 22.0,       # m/s^2 shedding speed (throttle released / reversed)
		"turn_rate": 2.0,    # rad/s at full speed — scaled by speed so a parked car can't pirouette
		"exit_side": 2.0,    # metres to the vehicle's side where the driver steps out
		"board": "door",     # parametric boarding style (model-present always boards instant)
	},
	"tank": {
		"length": 5.2, "max_speed": 7.0, "accel": 6.0, "brake": 14.0,
		"turn_rate": 1.6, "exit_side": 2.4, "board": "instant",
		"steer_fixed": true,   # TURN-IN-PLACE: steering works at zero speed, never speed-scaled
	},
	"boat": {
		"length": 5.5, "max_speed": 9.0, "accel": 7.0, "brake": 6.0,   # brisker spool-up, drifty stop
		"turn_rate": 1.6, "exit_side": 2.2, "board": "step",
		"water": true,       # y = water level (+bob) when the world has water; else terrain (car-like)
		"steer_floor": 0.45, # low-speed helm authority (2.3): the hull answers the stick while spooling up
	},
	"plane": {
		"length": 7.0, "max_speed": 14.0, "accel": 8.0, "brake": 16.0,   # ground TAXI numbers
		"turn_rate": 1.2, "exit_side": 2.8, "board": "step",             # slower taxi turn than a car
		"fly": true, "takeoff": 9.0,   # throttle-held above 9 m/s lifts off (pinned envelope)
		"steer_floor": 0.35, # taxi turns the nose while below rotation speed (2.3)
	},
	"horse": {
		"length": 2.2, "max_speed": 10.0, "accel": 8.0, "brake": 12.0,   # gallop feel
		"turn_rate": 2.4, "exit_side": 1.6, "board": "mount", "mount": true,
	},
	"bull": {
		"length": 2.2, "max_speed": 8.0, "accel": 5.0, "brake": 10.0,    # heavier
		"turn_rate": 1.4, "exit_side": 1.6, "board": "mount", "mount": true,   # slight turn resistance
	},
	"dragon": {
		"length": 4.5, "max_speed": 7.0, "accel": 6.0, "brake": 10.0,    # GROUND walk when landed
		"turn_rate": 1.8, "exit_side": 3.0, "board": "mount", "mount": true,
		"fly": true, "takeoff": 6.0,   # a dragon leaps from a run — its walk gait tops out at 7,
	},                                 # so the plane's 9.0 runway threshold would be unreachable
}
# LIBRARY DEFAULTS for mount models ("model" omitted). main.gd resolves these to absolute URLs
# via its _norm (they are bare library paths like the traffic set); all three exist, rig:true.
const MOUNT_MODELS := {
	"horse": "animals/farm_Horse.glb",
	"bull": "animals/farm_Cow.glb",
	"dragon": "animals/monster_Dragon.glb",
}
const PROMPT_RANGE := 2.8    # metres to the CLOSEST HULL POINT — show the floating DRIVE/RIDE label
const PROMPT_HIDE := 2.85    # ... hide past here (a 0.05 m hysteresis band so an edge-hover can't flicker)
const EXIT_CLEAR := 0.5      # a dismounted rider stands this far outside the hull: the player capsule's 0.4 + air
const EXIT_STEP := 1.2       # ...on the ground, or on anything walkable standing on it up to this high: a pier, a kerb
# A WATER MOUNT (spec "water": true) rides with this fraction of its drawn height under the surface, as a swimming
# creature does (enemy.gd floats its swimmers 0.2-0.45 m down). Grounded on what it draws and floated on its base,
# fish_Dolphin rode wholly ON the water; 0.35 keeps every library fish's back — and the rider on it — above it (the
# seat 0.59-2.85 m over the water across the seven, 2026-10-04).
const WATER_DRAFT := 0.35
const GROUND_LIFT := 0.1     # boats/flyers: ride just above the surface (same cue as TrafficCar's +0.12)
const CLIMB_RATE_MAX := 14.0 # m/s of vertical the drive step may take from the gradient. Caps the
                             # two edge cases sampling one step ahead can hit: a cliff lip (which
                             # would fling the hull upward) and a cell seam mid-stream (a one-frame
                             # spike). Well above any real grade at any real speed.
const SNAP_RATE := 10.0      # boats/flyers: y-lerp rate onto the rest height
const COAST_DECAY := 0.6       # fraction of max_speed shed per second with the stick released (~1.7 s from full)
# Cap on the lean a wheeled body takes from the ground. It carries the WHEELS now (see _wheel_step),
# so a cap below the steepest drivable grade lifts a tyre off it: 0.55 (31 deg) was shallower than the
# 33 deg canyon walls the Kestrel Bay truck spawns between.
const GROUND_TILT_MAX := 0.8

# --- WHEELED GROUND CONTACT (cars, trucks, tanks, walking mounts; not boats on water, not flyers) ---
const TYRE_GAP := 0.02         # tyre clearance over the fitted ground. GROUND_LIFT's 0.1 is a hover you can see
const FALL_GRAVITY := 22.0     # m/s^2, main.gd's GRAVITY: a car leaves a crest and lands the way the player does
const LAUNCH_VY_MAX := 8.0     # m/s cap on the climb a ramp hands the body as it leaves the ground (a 2 m
                               # terrain lattice can make a one-quad cliff at a lip; this keeps that a hop)
const AIR_SPIN_DAMP := 6.0     # 1/s: how fast a body in the air stops tumbling (the tyres' differing fall speeds)
const CONTACT_INSET := 0.75    # a wheelless body (mount, fused GLB) stands this far in from its footprint edge
const KEEL_SLICES := GPose.KEEL_SLICES   # underside profile: slices along the body (see _measure_keel) ...
const KEEL_BANDS := GPose.KEEL_BANDS     # ... and strips across it
# LEGS GRIP THE GROUND A GALLOP RUNS OVER (decision C2): a mount's tyre in the air falls at LEG_GRIP g while the ground under it
# is within its legs' reach (GFeet.CROUCH_MAX of its shortest leg) — at 1 g, as a car's, it left the ground over every crest and
# ledge: a galloping horse 0.75 m over its own gait above a +-16.7 deg crest, 1.30 over a +-25 deg one (step 5c). Past that reach
# it falls at 1 g, and lands off a 3 m ledge no faster than a body dropped from it (11.5 m/s; held to every tyre at 6 g it hit
# 18.7: the hoof-crest review).
const LEG_GRIP := 6.0
const FEET_NEAR := 25.0        # a PARKED mount plants its feet this near the player, on ground its feet do not stand flat on ...
const FEET_UNEVEN := 0.02      # ... off the plane it stands on by more than this under a foot
const PERF_EVERY := 30.0       # s between the GOGI_PERF lines a ridden mount with feet prints (_perf_line)

# --- shared FLIGHT ENVELOPE (plane + dragon) — pinned Wave-3 numbers ---
const SPEED_MAX := 22.0            # m/s airborne top speed (<1.2 cells/s at cell_size 20 — streaming keeps up)
const ALT_MAX := 32.0              # metres above the LOCAL terrain (soft ceiling)
const PITCH_MAX_DEG := 35.0        # visual + kinematic pitch clamp
const ROLL_MAX_DEG := 40.0         # visual bank clamp
const PITCH_RATE := 1.2            # rad/s pitch slew toward the input target
const ROLL_RATE := 3.0             # rad/s visual roll slew
const AIR_TURN := 1.1              # rad/s yaw while banked (not speed-scaled — arcade)
# AIR_ACCEL: m/s^2 toward SPEED_MAX while airborne. Throttle is IMPLICIT (cruise power always
# on): airborne input.y is PITCH, so there is no lever left to map to power — arcade contract.
const AIR_ACCEL := 6.0
const CEIL_BAND := 6.0             # metres below ALT_MAX where the allowed climb fades to zero
const GROUNDED_H := 0.5            # terrain-relative height below which a DESCENDING flyer lands
const TAKEOFF_CLIMB := 2.0         # m/s: the least a flyer climbs while still in the ground it took off from (_leave_ground)
# ticks down its way a flyer leaving the ground looks for that ground rising (_leave_hold), and m/s a tick, at most, that the
# rise ahead adds to its climb or takes off its pace (0.017 m a tick: no jolt). Seeing it sooner, it eases in gentler: at 15
# ticks and 1.5 a mire dragon leaving the ground 5.8 m short of a 63 deg face changed its move 0.063 m in a tick; at 24 and 1.0
# every take-off of the drive rig's (r2), 0.050 m at most (2026-10-05)
const LEAVE_LOOK := 24
const LEAVE_DV := 1.0
const LEVEL_RATE := 1.5            # rad/s: how fast a flyer out of that ground lays its lean down (~1.4 deg a tick)
const DESCENT_GAIN := 2.5          # nose-down sink multiplier: a landing flyer cuts throttle, so its airspeed-driven sink (_speed*sin(pitch)) is feeble — this restores real descent authority WITHOUT touching climb/cruise (only applied when _pitch < 0)
const PROP_SPIN := 30.0            # rad/s cosmetic prop-disc spin while driving

# --- desired-heading steering (CONTRACT A: drive_input_world) ---
# Within this cone of the target heading the steer command tapers to zero, so the body eases onto
# the camera-relative heading instead of oscillating across it. Outside it, full turn authority.
const HEADING_BAND := deg_to_rad(35.0)
# REVERSE: when the pushed heading is more than REVERSE_ENTER off the nose, back UP toward it instead
# of U-turning ("pull back = reverse"); latch out again only below REVERSE_EXIT so the forward/reverse
# choice can't flicker at the boundary. A hard SIDEWAYS push (~90°) stays a forward turn; only a
# clearly-behind push reverses. No reverse in flight.
const REVERSE_ENTER := deg_to_rad(115.0)
const REVERSE_EXIT := deg_to_rad(95.0)

# --- wheel motion (2.2) ---
const WHEEL_RADIUS := 0.32         # parametric wheel radius — rolling spin = (speed / radius) * delta
const WHEEL_STEER_MAX := deg_to_rad(28.0)   # front steer-pivot yaw at full stick
const WHEEL_STEER_SLEW := 5.0      # rad/s the front pivots slew toward the steer target

# --- ride bob (2.4: sells motion when the mount has no move clip of its own — F1: never on top of one) ---
const RIDE_BOB_AMP := 0.05         # rider vertical bounce, metres (added to the MountMarker y)
const RIDE_PITCH_DEG := 3.0        # +/- body rock pitch on the mount while walking
const RIDE_MOVE_MIN := 0.3         # |speed| above which a mount visibly bobs/rocks
# THE RIDER RIDES THE BACK IT DRAWS EVERY RENDERED FRAME (_follow_seat): after the mount's AnimationPlayer (priority 0) has
# posed it — so a ridden vehicle processes after it. In the physics step the pose read was the frame before's (the player
# runs in idle process): on screen the gap swung -2..+16 cm at a raptor's run (seats review, rr_proto_30).
const FOLLOW_PRIORITY := 100

# --- water ride (boat) ---
const BOB_AMP := 0.15              # small bob = 0.15 * sin(time * 1.2) (pinned)
const BOB_HZ := 1.2

# --- mount gait sync ---
const GAIT_MOVE_MIN := 0.5         # |speed| above this plays the move clip
const GAIT_FAST_FRAC := 0.55       # fraction of max_speed above which gallop/run wins over walk

# --- enter/exit state machine (choreographed boards; instant boards jump straight IDLE<->DRIVING) ---
const S_IDLE := 0
const S_ENTERING := 1
const S_DRIVING := 2
const S_EXITING := 3

# --- parametric body tuning ---
const BODY_COLOR_DEFAULT := Color(0.72, 0.16, 0.14)   # warm red (spec "color": [r,g,b] overrides)
const TANK_COLOR_DEFAULT := Color(0.32, 0.36, 0.25)   # olive drab
const BOAT_COLOR_DEFAULT := Color(0.85, 0.87, 0.90)   # white gelcoat
const PLANE_COLOR_DEFAULT := Color(0.78, 0.80, 0.84)  # silver
const DOOR_OPEN_DEG := -70.0   # hinge swing about local +Y; negative = outward on the +X (driver/left) side
const DOOR_TIME := 0.35        # seconds per door swing (open and close)
const WALK_TIME := 0.4         # seconds for the driver's walk-to-seat / step-out position tween
const SEAT_TOP := 0.45         # y of the car cushion top = its "SeatMarker" height (car-local)
# Roof underside of the parametric car (roof slab centre 1.445, 0.09 thick). SEAT_TOP..CAR_ROOF_Y is
# the clear column a seated driver has to fit inside — 0.95 m, which is what a real sedan gives and
# comfortably clears the ~0.86 m sitting height of a 1.65 m humanoid (sitting height runs ~0.52x
# stature). A stylized chibi rig needs ~1.36 m and genuinely cannot sit in a sedan; _seat_driver
# hides those rather than posting a head through the roof. Keep these in sync with the cushion and
# roof slabs in _build_parametric — SCALETEST asserts the resulting column admits one and not the
# other, so a change here that breaks that shows up as a red test rather than a shipped screenshot.
const CAR_ROOF_Y := 1.40
# Fallback hip height as a fraction of standing height, used ONLY when a rig exposes no hip bone.
# Measuring beats this constant every time: it is ~0.52 on a realistic humanoid but 0.178 on a
# KayKit chibi, and seating a chibi by the realistic ratio drops its origin half a metre too far and
# buries it in the floor. See GPose.hips_height.
const HIP_RATIO := 0.52

# --- seat synthesis (mount dorsal scan + modeled-vehicle cabin centre) ---
# Mount seat z, as a fraction of body length FORWARD (+Z) of the AABB centre: horse/bull sit the
# back's dip at the centre; a dragon sits behind the wing roots, forward of centre — the old
# fixed 25%-BACK landed over the rump/tail.
const SEAT_Z_OFF := {"horse": 0.0, "bull": 0.0, "dragon": 0.175}
# Dorsal-height fallback (fraction of AABB height) when the vertex scan finds nothing — the
# back line, NOT ab.end.y (the AABB top is the raised head/crest: horse back ≈ 0.72, dragon 0.55).
const SEAT_FRACTION := {"horse": 0.72, "bull": 0.72, "dragon": 0.55}
const DORSAL_X_BAND := 0.15    # dorsal scan: |x - centreline| window, fraction of body width
const DORSAL_Z_BAND := 0.06    # dorsal scan: |z - seat z| window, fraction of body length
const SCAN_VERT_CAP := 60000   # stride huge Meshy meshes past this many verts (boot-cost cap)
const SCAN_TRI_CAP := 150000   # same cap for the cabin probe's triangle walk
const CABIN_HEADROOM := 1.0    # metres of clear column a seated driver needs above the seat surface
const CABIN_FLOOR_MIN := 0.12  # a cabin floor/deck sits ABOVE this fraction of body height (a
                               # watertight solid body's underside must not read as a "floor")
const CABIN_FLOOR_MAX := 0.75  # ... and BELOW this fraction (a surface at roof height is a roof)
const VEHICLE_SEAT_Z := -0.15  # synthesized vehicle seat: fraction of length BACK of the centre
const SADDLE_COLOR := Color(0.34, 0.21, 0.11)   # leather brown (parametric mount saddle)

# Emitted on enter/exit so main.gd can track the active vehicle (input routing + camera-arm exclusion).
# Choreographed boards emit `true` at sequence START (camera switch + control lockout, Wave-1
# behavior) and `false` at exit-sequence END.
signal drive_state_changed(vehicle: Vehicle, is_driving: bool)

var profile := "car"
var display_name := "Car"
var terrain: GTerrain = null    # set via set_terrain() after the streamer boots; null = flat world (y=0)
var player_ref: Node3D = null   # for the floating DRIVE/RIDE prompt proximity check (set by main at spawn)
var driving := false            # public Wave-1 flag: true from enter-start until exit completes
var water_level := 0.0          # the world's GWater level (set_water) — boats float here

var _state := S_IDLE
var _driver: CharacterBody3D = null
var _speed := 0.0               # signed m/s along -basis.z (negative = reversing)
var _input := Vector2.ZERO      # main.gd's shared input vector (x = steer, y = throttle, screen-up = -y)
var _rev_latch := false         # drive_input_world reverse state (hysteresis, ground/water only)
var _world_drive := false       # true while the on-screen joystick feeds a camera-relative heading via
                                # drive_input_world (point-and-go, speed-independent turn); false = the raw
                                # drive_input(steer,throttle) path used by the verify harness
var _label: Label3D = null
var _height := 1.6              # scaled model height (roof) — the floating label sits above it
var _body_ab := AABB()          # composed body bounds in the vehicle's LOCAL frame — the DRIVE/RIDE
                                # affordance measures to the closest point on THIS, not the origin
var _snapped := false           # first ground snap is instant (no boot-time rise-from-y=0 lerp)
var _has_water := false         # set_water was called (the world HAS a water block)
var _water_rest := false        # this vehicle RESTS on the water surface (boat, or spec "water":true
                                # seaplane) — floors its ground height at water_level when _has_water
var _time := 0.0                # local clock for the boat bob
var _park_t := 0.0              # throttle accumulator for the PARKED per-frame work (see _physics_process)

# --- body/boarding wiring ---
var _parametric := false                  # a parametric VEHICLE body was built (never true for mounts)
var _is_mount := false                    # horse/bull/dragon — model path + MountMarker + GPose.ride
var _board := "door"                      # "door" | "step" | "instant" | "mount"
var _board_local := Vector3(1.45, 0.0, -0.15)   # boarding spot beside the body (self-local, ground level)
var _visual: Node3D = null                # the body subtree that takes the cosmetic flight pitch/roll
# Wheeled ground contact — see _wheel_step. The tyres below are the ONLY writer of a wheeled body's height.
var _tyre_y := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])   # world height of each tyre's contact point
var _tyre_vy := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])  # ... its vertical speed
var _tyre_down: Array[bool] = [true, true, true, true]    # ... on the ground (else falling)
var _tilt := Basis()                      # lean onto the ground, on top of the heading (about the body origin)
var _rock := 0.0                          # a walking mount's gait rock (pitch, rad), composed over _tilt
var _stride := 0.0                        # ...and with no gait of its own, the phase its legs stride at (_stride_on) ...
var _stride_v := 0.0                      # ... the speed it strides at, m/s ...
var _striding := false
var _chained := false                     # ... its legs every one a chain a thigh's swing carries (GRig.legs)
var _vis_rest := Transform3D.IDENTITY     # _visual's transform as BUILT (orient yaw, scale, grounding) — the lean composes over it
var _hull_cs: CollisionShape3D = null     # the hull box: leans with the body so walls meet the car you see
var _hull_rest := Transform3D.IDENTITY
## THE HULL AS A BODY (GBody.box over the hull box's own numbers, owner this vehicle): what a shot that
## meets the hull — or any collider under this vehicle — resolves to. A RIDDEN vehicle is its rider's
## body when attacked (main._projectile_hit routes the hit to whoever sits on it); a parked one is a hull.
var body: GBody = null
var _terrain_ex := {}                     # instance_id -> its release callback: terrain bodies the hull ignores (_except_terrain)
var _contact_c := Vector2.ZERO            # wheel-contact rectangle, body frame: centre (x, z) ...
var _contact_h := Vector2(0.5, 1.0)       # ... half extents (x, z) ...
var _contact_y := 0.0                     # ... and the tyre-bottom height (see _measure_contact)
var _keel := PackedVector3Array()         # the body's own underside, body frame, as it rests now (_keel_now) ...
var _keel_hoof := PackedVector3Array()    # ... at rest, its hooves and all (_measure_keel) ...
var _keel_tab := {}                       # ... and without its legs, a drawn mount's in each pose it plays (its fit's keel):
                                          # clip ("" its rest) -> [a phase each], body frame
var _keel_fit := {}                       # ...as its fit gave it, in the model's frame, until _attach_feet takes it
var _feet: GFeet = null                   # its legs, planted on the ground (feet.gd; null: no legs, no skeleton, not drawn)
var _feet_xz := PackedVector2Array()      # ...each foot at rest, body frame (where a parked mount looks for uneven ground)
var _grip_reach := 0.0                    # m: how far below an airborne tyre the ground may be for its legs to reach it (LEG_GRIP)
var _crouched := 0.0                      # m: the crouch the hull's top was last brought down by (_hull_crouch)
var _clear := INF                         # m: what it rests on over the ground at its lowest (_keel_clearance), read where it
var _clear_xf := Transform3D()            # stood, in the pose it showed (_keel_ix) ...
var _clear_ix := Vector2i(-1, -1)
var _clear_sup := INF                     # ...or as _keel_support rested it (_sup_clear), in the physics tick _support_at
var _sup_clear := INF
var _support_at := -1
var _keel_ix := Vector2i(-1, -1)          # the pose _keel_now last picked: its clip's place in the table and its phase
var _perf_t := 0.0                        # s since the last GOGI_PERF line
var _ex_t := 0.0                          # countdown to the next terrain-exception scan
var _ex_n := -1                           # terrain body count at the last scan
var _wheel_last := Vector3.INF            # where _wheel_step / a settle last left the body (see _wheel_step)
var _settled_key := Vector4(INF, INF, INF, INF)   # xz, yaw, terrain revision of the last parked settle
var _saddle: Node3D = null                # the parametric saddle — rides the lean like the MountMarker
var _hcache := {}                         # terrain lattice-vertex heights (see _ground_h_at)
var _hcache_rev := -1
var _seat_marker: Node3D = null           # "SeatMarker" — cushion/floor point where the seated hips rest
# Clear vertical column above the SeatMarker, metres. INF = open-topped (boat, plane cockpit, any
# mount) — nothing overhead to clip, so the driver is always visible. A finite value is a ROOF, and
# _seat_driver hides a driver too tall to fit under it instead of clipping them through it. Set by
# whichever body builder ran; INF is the safe default because "no roof" only ever costs visibility.
var _cabin_headroom := INF
                                          # (parametric cushion top OR the modeled-cabin probe's find)
var _mount_marker: Node3D = null          # "MountMarker" — dorsal-surface seat point (rider hips)
var _door_pivot: Node3D = null            # "DoorPivot" — hinge at the door opening's FRONT edge (car only)
var _door_shape: CollisionShape3D = null  # the leaf's blocking collider (disabled while open/driving)
var _door_body: StaticBody3D = null
var _prop: Node3D = null                  # "PropDisc"/rotor — cosmetic spinner (parametric plane OR an assembled aircraft's prop/rotor GLB)
var _wheels: Array[Node3D] = []           # spun about their axle by (speed / _wheel_radius)*delta while moving
var _steer_pivots: Array[Node3D] = []     # front "WheelPivot" nodes — slew toward the steer input
var _wheel_axle := Vector3.UP             # local axle for a wheel spin: parametric +Y (rotation.z=PI/2),
                                          # modeled GLB wheels +X (rolling axis for a +Z-facing body)
var _wheel_radius := WHEEL_RADIUS         # rolling radius used for the spin RATE — the 0.32 parametric/mount
                                          # default; an assembled vehicle overrides it per its wheel-GLB size (spec "wheel_r")
var _ride_bob := 0.0                      # per-tick rider bounce (2.4) added to the MountMarker y
var _seq: Tween = null                    # the running enter/exit choreography
var _seated := false                      # GPose.sit/ride succeeded — driver rides the marker, visible
var _seat_off := Vector3.ZERO             # the driver's origin off the marker, in their own (leaned) frame: minus where they sit
var _mount_seat_y := -INF                 # skeleton-derived saddle-line height (self-local, base-0 frame); -INF = no rig, use scan fallback
# --- the seat on the back it draws (_setup_mount, GPose.mount_seat) and the rider riding it (_follow_seat) ---
var _seat := {}                           # GPose.mount_seat's answer the marker stands on ({} = a bone or scan seat: nothing drawn under it)
var _seat_skel: Skeleton3D = null         # the skeleton that draws that back (its anchor's mesh's); null: it never moves
var _seat_kind := "none"                  # drawn | authored | none — the seat-contact line's last word
var _gaited := false                      # it plays a move clip of its own: no fake rock or bounce on top of it (F1)
var _saddle_rest := Vector3.ZERO          # the saddle where it was built, in _visual's frame: it rides the back from there
var _rider_top := -INF                    # the seated rider's drawn top, self frame: the hull rises to it while they ride (_sync_hull)
var _rider_top_air := -INF                # ...aloft: without the rock and bob a mount with no move clip of its own walks them with
var _follow: Array = []                   # [rider, skeleton | null, its root bones, their rest positions | the avatar's]: _follow_seat
var _fit := 0                             # the ride pose the rider takes (GPose.RIDE_FITS: legs fitted to its width, S5)
# --- a skinned mount's body (_mount_drawn): what it DRAWS, measured once ---
var _drawn_rest := AABB()                 # its rest pose, self frame, base at y = 0 (size 0: not a drawn mount)
var _model_xf := Transform3D()            # ...the transform its model was given for it (_drawn_xf): the seat is measured under it
var _drawn_pts := PackedVector3Array()    # ...as points: the underside _measure_keel rests it on (taken before the saddle is hung)
var _seat_box := AABB()                   # its BONE box (true axes, scaled, centred on the origin, base y = 0): the seat and the footprint
var _hull_ground := AABB()                # the hull it walks in ...
var _hull_air := AABB()                   # ... and a flyer's in the air (size 0: not a flyer) — _sync_hull swaps them
var _draft := 0.0                         # a water mount's depth under the surface (WATER_DRAFT of its drawn height)

# --- flight state (plane + dragon) ---
var _airborne := false
var _leaving := false           # in the air, still in (or leaned to) the ground it took off from (_leave_ground)
var _leave_ref := INF           # ...the least its hull has reached into that ground since it took off (_leave_hold)
var _leave_vy := 0.0            # ...and the climb the ground ahead has added to its own, eased in (_leave_hold)
var _leave_f := 1.0             # ...and the share of its pace across the ground that ground leaves it, eased (_leave_hold)
var _pitch := 0.0               # radians, POSITIVE = climb (screen-up / W = climb; see _drive_air)
var _roll := 0.0                # radians, visual bank
var _flyer_orient_yaw := 0.0    # yaw baked to turn an X-fuselage aircraft model onto +Z (drive axis); composed UNDER the flight pitch/roll so climbing pitches the nose instead of barrel-rolling. 0 = model already fuselage-forward.
var _flyer_scale := 1.0         # uniform model scale, preserved when the flight code rebuilds _visual.basis
var _air_thr := 1.0             # 0..1 flight throttle target: _speed eases to SPEED_MAX*_air_thr, so
                                # easing off / pulling back the stick actually SLOWS the flyer.
                                # drive_input_world sets it from the stick; raw drive_input leaves cruise 1.0.
var _land_req := false          # a mid-air USE requested a braked descent-then-dismount (see _drive_air/exit)

# --- mount gait sync (embedded clips only; "" = clip absent -> silent degrade) ---
# Resolved by GClip (clip_role.gd), the resolver every character's clips go through.
var _gait_ap: AnimationPlayer = null
var _clip_walk := ""            # GClip walk (walk/trot/canter/slither; a run when that is all it has)
var _clip_fast := ""            # GClip run, a gallop preferred (gallop/run/sprint/skitter)
var _clip_idle := ""            # GClip idle -> rest
var _clip_flap := ""            # GClip fly (fly/flap/hover) -> airborne move
var _clip_glide := ""           # GClip glide (glide/soar) -> airborne level/descending
var _clip_any := ""             # LONGEST ANONYMOUS clip ("Take 001") — the move fallback so a rig whose only
                                # clip is unnamed still rides animated (2.4); never a clip naming another action


# The library-default model for a profile whose spec omits "model" — main.gd calls this from its
# _vehicle_model_url so mounts fetch their creature GLB instead of the default sedan. Returns ""
# for VEHICLE profiles: those build a parametric body and need no fetch at all.
static func default_model_path(profile_name: String) -> String:
	return String(MOUNT_MODELS.get(profile_name, ""))


# THE SKELETON'S BONE BOX, in the MODEL's frame (model.transform excluded): the rest origin of every bone of THE
# skeleton (GPose.skeleton_of, the richest: monster_Dragon ships a 1-bone eye rig beside its body's, and sks[0] read the
# body only because it came first in the file) pushed through the FULL node chain, rotations included. This read the
# skeleton-LOCAL origins times the chain's scales and nothing else. Every Blender/Quaternius armature is Z-up, turned
# -90 deg about X under its root, so its "z" was the animal's HEIGHT: the horse's box read 0.63 x 2.53 x 2.20 for a
# body that draws 0.91 wide, 2.44 tall and 3.27 long, and the seat stood on that swapped box (a lift of 0.06 x the
# LENGTH: +0.42 m on the apatosaurus). AABB() when there is no skeleton.
#
# DELIBERATELY BONES-ONLY, unlike GPose.char_height. This feeds the MOUNT seat, which wants the creature's BACK LINE —
# and a horse's mesh envelope includes its raised head and a dragon's its crest, so unioning the envelope in here would
# move the saddle onto the animal's skull. Height for a HUMANOID DRIVER is a different question with a different answer
# and uses GPose.char_height; the two looked interchangeable, and treating them as such is what put a rider's head
# through a roof.
static func _skel_span(model: Node3D) -> AABB:
	var s := GPose.skeleton_of(model)
	if s == null or s.get_bone_count() == 0:
		return AABB()
	var xf := GPose.xf_to(s, model)
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for i in s.get_bone_count():
		var g := xf * s.get_bone_global_rest(i).origin
		lo = lo.min(g)
		hi = hi.max(g)
	return AABB(lo, hi - lo)


## THE SIZE A MOUNT WITH NO "scale" HAS ALWAYS HAD (decision 17, the user's: no world changes size unless it asks to):
## the profile's length divided by THIS — the skeleton's span along its OWN z axis times the node scales above it, which
## on a Z-up armature is the height of the animal's head bone and on a Y-up Rig Lab rig its bone length. A size contract,
## kept as one, not a measurement: what the body IS, where it ends and what it stands on are read off what it draws and
## off _skel_span. 0 when the skeleton cannot say (its bones share one x): the drawn length stands in.
static func _legacy_len(model: Node3D) -> float:
	var s := GPose.skeleton_of(model)
	if s == null or s.get_bone_count() == 0:
		return 0.0
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for i in s.get_bone_count():
		var g: Vector3 = s.get_bone_global_rest(i).origin
		lo = lo.min(g)
		hi = hi.max(g)
	if hi.x <= lo.x:
		return 0.0
	var cum := Vector3.ONE
	var w: Node = s
	while w != null and w != model and w is Node3D:
		cum *= (w as Node3D).scale
		w = w.get_parent()
	return (hi.z - lo.z) * cum.z


# Skeleton-derived FEET + SADDLE line (self-local metres) of THE skeleton (GPose.skeleton_of), robust for the
# skin-baked-scale Meshy rigs where the un-skinned vertex scan mis-reports. x = lowest bone origin; y = highest
# TORSO bone (spine/chest/back/hips/pelvis/torso/body/saddle, EXCLUDING neck/head/tail/leg/twist/roll) ~= the
# withers/saddle line where a rider's hips rest. Bone rest origins are pushed through the FULL node chain
# INCLUDING model.transform (so scale is honoured) to self-local, letting the caller seat in the frame it grounded
# in. Returns Vector2(-INF,-INF) when no skeleton/torso bone.
func _skel_feet_back(model: Node3D) -> Vector2:
	var s := GPose.skeleton_of(model)
	if s == null or s.get_bone_count() == 0:
		return Vector2(-INF, -INF)
	var t := model.transform * GPose.xf_to(s, model)   # skeleton-local -> self-local (model is a child of self)
	var foot := INF
	var back := -INF
	for i in s.get_bone_count():
		var bp := t * s.get_bone_global_rest(i).origin
		if bp.y < foot:
			foot = bp.y
		var bn := s.get_bone_name(i).to_lower()
		if "twist" in bn or "roll" in bn or "neck" in bn or "head" in bn or "tail" in bn or "leg" in bn:
			continue
		if "spine" in bn or "chest" in bn or "back" in bn or "hips" in bn or "pelvis" in bn or "torso" in bn or "body" in bn or "saddle" in bn:
			if bp.y > back:
				back = bp.y
	if not is_finite(back) or not is_finite(foot):
		return Vector2(-INF, -INF)
	return Vector2(foot, back)


# Public "is this a creature MOUNT (horse/bull/dragon)?" — main.gd stows the weapon visual while
# DRIVING A VEHICLE but keeps it on a mount (firing from the saddle is a Wave-4 feature). Pure
# accessor over the setup-time flag.
func is_mount() -> bool:
	return _is_mount


## How far the parked body reaches from its origin, on any heading: the radius its spawn is cleared by (clear_spawn).
## That was a fixed 2.5 m — a car's; the default dragon's hull reaches 5.69 m, its wings into whatever stood 2.5 m off.
func clear_radius() -> float:
	var h := _hull_ground if _hull_ground.has_volume() else _body_ab
	var r := 0.0
	for x in [h.position.x, h.end.x]:
		for z in [h.position.z, h.end.z]:
			r = maxf(r, Vector2(x, z).length())
	return r


## Move a vehicle authored on top of a structure onto clear ground, by the body it parks (main.gd, once the start ring's
## structures exist): `streamer` is the ChunkManager, whose nudge_out pushes a point clear of every structure footprint.
func clear_spawn(streamer: Object) -> void:
	global_position = streamer.call("nudge_out", global_position, clear_radius())


# Build the body from a world.json vehicle spec + an (optional) model duplicated from the builder
# cache. Called BEFORE the node enters the tree; main positions it afterwards.
func setup(spec: Dictionary, model: Node3D, parts: Dictionary = {}) -> void:
	profile = String(spec.get("profile", "car"))
	if not PROFILES.has(profile):
		profile = "car"
	var p: Dictionary = PROFILES[profile]
	_is_mount = bool(p.get("mount", false))
	# WATER-REST (2.3): boat floats by profile default; any profile becomes a "seaplane" with spec
	# "water": true; a boat opts out with "water": false. Honored in _rest_y/_ground_h once set_water
	# hands over the level (main.gd wires it via _wire_vehicle_terrain when the world has a water block).
	_water_rest = bool(spec.get("water", p.get("water", false)))
	display_name = String(spec.get("name", profile.capitalize() if _is_mount else "Car"))
	# world layer so the player bumps into a parked boardable; world mask so walls/buildings stop it
	collision_layer = 1
	collision_mask = 1
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING   # y is ours (terrain/water/flight) — no floor magic
	# THE SPEC decides the body mode. VEHICLE profiles: no "model"/"url"/"asset" key -> the
	# profile's parametric body; a model key present -> the Wave-1 fused-GLB swap-in path
	# (placeholder box fallback included when the fetch failed). MOUNT profiles ALWAYS take the
	# model path — main resolves the library default (default_model_path) when the spec omits one.
	# ASSEMBLED multi-part vehicles (Phase 3) carry body_url/wheel_url/prop_url (not a single fused
	# model key), so they must NOT be treated as parametric — fold those keys into the model-present test.
	_parametric = (not _is_mount) and not (spec.has("model") or spec.has("url") or spec.has("asset") or spec.has("body_url") or spec.has("wheel_url") or spec.has("prop_url"))
	# Boarding style: mounts always mount-board (visible rider); parametric vehicles use their
	# profile's style ("door" car / "step" boat+plane / "instant" tank); modeled vehicles board
	# instant (Wave-1 swap-in — a fused GLB has no interior to choreograph into).
	if _is_mount:
		_board = "mount"
	elif _parametric:
		_board = String(p.get("board", "door"))
	else:
		_board = "instant"
	var body_ab: AABB
	if _parametric:
		if model != null:
			model.free()   # unused duplicate from main's default-model resolve (never entered the tree)
		match profile:
			"tank":
				body_ab = _build_parametric_tank(spec)
			"boat":
				body_ab = _build_parametric_boat(spec)
			"plane":
				body_ab = _build_parametric_plane(spec)
			_:
				body_ab = _build_parametric(spec)   # the Wave-2 car, unchanged
	elif spec.has("body_url") or spec.has("wheel_url") or spec.has("prop_url"):
		body_ab = _assemble_model(spec, model, parts)   # Phase 3: bespoke body GLB + engine-instanced (or parametric-fallback) wheels/prop that MOVE
	else:
		body_ab = _mount_model(spec, model)
	if _is_mount:
		_setup_mount(spec, _seat_box if _seat_box.has_volume() else body_ab)
	elif not _parametric:
		_setup_vehicle_seat(spec, body_ab)   # visible-driver seat probe (modeled vehicles)
	_height = maxf(0.8, body_ab.size.y)
	# the hull: a box collider over the composed/scaled/drawn bounds (_set_hull)
	_hull_cs = CollisionShape3D.new()
	_hull_cs.shape = BoxShape3D.new()
	add_child(_hull_cs)
	_set_hull(body_ab)
	# THE SEAT IS PART OF THE BODY YOU SEE. A modeled vehicle's SeatMarker and every MountMarker were
	# parented to the body ROOT, which never leans, while the model they sit in did: on a 17 deg grade
	# the seat slid 0.2 m inside the truck and the driver stayed bolt upright in a hull leaning 17 deg —
	# the "character pops out of the car". Moved under _visual (transform preserved, so it is the same
	# point at rest), the seat rides every lean, gait rock and flight attitude the body takes — and so does
	# the parametric saddle, or the rider would lean away off it.
	_vis_rest = _visual.transform if _visual != null else Transform3D.IDENTITY
	if _visual != null:
		for mk in [_seat_marker, _mount_marker, _saddle]:
			if mk != null and (mk as Node3D).get_parent() == self:
				var xf: Transform3D = _vis_rest.affine_inverse() * (mk as Node3D).transform
				remove_child(mk)
				_visual.add_child(mk)
				(mk as Node3D).transform = xf
	if _saddle != null:
		# it rides the back (_follow_seat), written where each rendered frame is drawn: not interpolated, so what it is set to
		# in a frame is what that frame draws (under the body's interpolated transform)
		_saddle_rest = _saddle.position
		_saddle.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_measure_contact()
	_measure_keel()
	_attach_feet()
	# floating DRIVE (RIDE for mounts) prompt over the roof (billboarded, the add_sign idiom),
	# shown only while PARKED near the player — no words while driving. ACTIVATION runs through
	# the interaction system's USE mechanism — this label is the visual affordance only.
	_label = Label3D.new()
	_label.font_size = 48
	_label.pixel_size = 0.012
	_label.modulate = Color(1.0, 1.0, 0.6)
	_label.outline_size = 12
	_label.outline_modulate = Color(0, 0, 0, 0.8)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# FIXED screen size: a perspective-scaled label fills a third of a phone screen when the
	# camera stands next to the hull (giant clipped "DRI…"); fixed_size keeps it a readable cue
	# at every distance and the HUD USE prompt owns the close range anyway.
	_label.fixed_size = true
	_label.pixel_size = 0.0006
	_label.position = Vector3(0.0, _height + 0.8, 0.0)
	_label.visible = false
	add_child(_label)


# A parked mount idles (clip resolution already done in _setup_mount); play() outside the tree is
# deferred by the engine until processing starts, but _ready is the unambiguous place.
func _ready() -> void:
	if _gait_ap != null and _clip_idle != "":
		_play_clip(_clip_idle, 1.0)
	# the render-frame follow runs only while someone rides it (_follow_seat), after the mount's own player has posed it
	process_priority = FOLLOW_PRIORITY
	set_process(not _follow.is_empty())


## THE HULL IS `ab` (self frame): a box collider centred on it (a GLB's origin is rarely dead-centre), the body a shot or
## an enemy meets (GBody.box, built from the same numbers) and the box USE and the label measure to. The lean composes
## over it (_apply_tilt).
func _set_hull(ab: AABB) -> void:
	_body_ab = ab
	var box := _hull_cs.shape as BoxShape3D
	box.size = Vector3(maxf(0.5, ab.size.x), maxf(0.5, ab.size.y), maxf(0.5, ab.size.z))
	_hull_rest = Transform3D(Basis(), ab.position + ab.size * 0.5)
	_hull_cs.transform = Transform3D(_tilt, Vector3.ZERO) * _hull_rest
	body = GBody.box(_hull_rest.origin, box.size).owned_by(self)
	_crouched = 0.0


## THE HULL BY STATE (decision 19): a flyer walks in the box its ground gaits fill and flies in the box its wingbeat
## fills (GBody's mount and mount_air fits). One box over both cost the default dragon 0.44 m of width and 0.78 m of
## height it never shows on the ground, and a parked monster_Bat 6.60 m of air behind its tail. The other box takes over
## only where it FITS (_hull_fits), so a swap never pushes the body out of anything: after take-off it waits for open
## air, after a landing for room to stand.
func _sync_hull() -> void:
	if _hull_cs == null or not _hull_ground.has_volume():
		return
	var air := _airborne and _hull_air.has_volume()
	var want := _hull_air if air else _hull_ground
	if is_finite(_rider_top):
		# ...up to its seated rider's top (_rider_hull), as high as the back they ride lifts them there (GPose.mount_seat's reach
		# over the ground's clips, or the air's: no walking rock or bob up there, _update_ride_motion — with them the bat's hull
		# stood 0.084 m over kk_Knight's head in flight, the drive rig's (aloft))
		var reach: Array = _seat.get("reach_air" if air else "reach", [])
		var top := (_rider_top_air if air else _rider_top) + (maxf(0.0, (_seat_xf().basis * (reach[1] as Vector3)).y) if reach.size() == 2 else 0.0)
		if top > want.end.y:
			want.size.y = top - want.position.y
	if want != _body_ab and _hull_fits(want):
		_set_hull(want)


# Would the hull `ab` overlap anything it collides with, standing where the body stands? On its feet the terrain is no
# such thing (it stands IN the ground's lattice: _wheel_step excepts it); in the air it is.
func _hull_fits(ab: AABB) -> bool:
	if not is_inside_tree():
		return true
	var q := PhysicsShapeQueryParameters3D.new()
	var bx := BoxShape3D.new()
	bx.size = Vector3(maxf(0.5, ab.size.x), maxf(0.5, ab.size.y), maxf(0.5, ab.size.z))
	q.shape = bx
	q.transform = global_transform * Transform3D(_tilt, Vector3.ZERO) * Transform3D(Basis(), ab.position + ab.size * 0.5)
	q.collision_mask = collision_mask
	var ex: Array[RID] = [get_rid()]
	if _driver != null and is_instance_valid(_driver):
		ex.append(_driver.get_rid())
	if not _airborne:
		for n in get_tree().get_nodes_in_group("gogi_terrain"):
			if n is CollisionObject3D:
				ex.append((n as CollisionObject3D).get_rid())
	q.exclude = ex
	return get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


# Mount the model: scale-normalise to the profile length, then ground it on what it draws (base -> origin, lift and
# drop). A SKINNED MOUNT is measured by what it draws, gaits and all (_mount_drawn). Anything else — a static creature
# model, a modeled VEHICLE — draws exactly its mesh bounds at rest (GPose.drawn_aabb): mounts normalise by BODY LENGTH
# (size.z, the stack's forward axis) — a wings-spread dragon must not shrink by its WINGSPAN — and modeled vehicles keep
# the longest-horizontal idiom their profile lengths were tuned for. A spec "scale" (absolute metres, nose-to-tail)
# beats the profile default. Falls back to a simple box body when the GLB isn't in the cache, so the boardable still
# works. Returns the final local AABB the collider is derived from.
func _mount_model(spec: Dictionary, model: Node3D) -> AABB:
	var target_len := float(spec.get("scale", PROFILES[profile]["length"]))
	if model != null and _is_mount and GPose.skeleton_of(model) != null:
		var drawn := _mount_drawn(spec, model)
		if drawn.has_volume():
			return drawn
	if model != null:
		var ab := GPose.drawn_aabb(model)
		# ORIENT ground vehicles whose nose-to-tail LENGTH runs along X: they'd drive CRAB-WISE (body
		# sideways to travel) because forward is Godot -Z and nothing rotated the model onto it. Yaw 90
		# so the length aligns with Z, then re-measure (x/z swapped). EXCLUDE FLYERS: a plane's WINGSPAN
		# (X) is wider than its fuselage LENGTH (Z), so this rule would fire on the wings and spin the
		# aircraft 90 into a sideways attitude — aircraft GLBs are authored fuselage-forward already.
		if not _is_mount:
			if bool(PROFILES.get(profile, {}).get("fly", false)):
				_orient_flyer_fuselage(model)   # aircraft: WINGSPAN confounds the x>z rule, so detect the fuselage by end-heights
				ab = GPose.drawn_aabb(model)
			elif ab.size.x > ab.size.z:
				model.rotation.y += PI * 0.5
				ab = GPose.drawn_aabb(model)
		var dim := ab.size.z if (_is_mount and ab.size.z > 0.001) else maxf(ab.size.x, ab.size.z)
		if dim > 0.001:
			model.scale *= target_len / dim
		_flyer_scale = model.scale.x   # preserved so the flight code can rebuild _visual.basis without dropping scale
		ab = GPose.drawn_aabb(model)
		# base -> origin, LIFT *and* drop. A Meshy vehicle GLB is centred on its origin, so its base
		# sits BELOW y=0 (ab.position.y < 0); the old drop-only `-maxf(0.0, …)` left those unlifted, so
		# the body sat under the terrain once the hull origin snapped to the surface (the "vehicles below
		# ground" bug — and a body embedded in the terrain trimesh can't move_and_slide forward either).
		model.position.y -= ab.position.y
		add_child(model)
		_visual = model
		if not _is_mount:
			_scan_model_wheels(model)   # modeled vehicle: register wheel|tire|tyre subnodes as spinners (2.2)
		return GPose.drawn_aabb(model)
	# placeholder body (model missing) — still boardable, clearly a body-sized box
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(target_len * 0.45, 1.3, target_len)
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.55, 0.57, 0.6)   # neutral "loading" gray, not a jarring red box — a missed model hot-swaps in when its fetch lands (#9)
	mi.material_override = m
	mi.position.y = 0.65
	add_child(mi)
	print("GOGI_PLACEHOLDER vehicle ", profile)   # verify.mjs asset-fail gate: a gray vehicle box is visible
	_visual = mi
	return AABB(Vector3(bm.size.x * -0.5, 0.0, bm.size.z * -0.5), bm.size)


## A SKINNED MOUNT IS THE BODY IT DRAWS — measured once per model (GBody.fit: GPose.body_fit over the gaits it plays,
## warmed where its GLB is parsed: AreaBuilder._prewarm_fit), and everything that asks where the mount is reads it.
## Until 2026-10-04 two proxies stood in for it, and both were wrong: _skel_span read bone joints in the skeleton's own
## axes (length and height swapped on every Z-up armature, every library animal included), and the grounding read the
## un-skinned bind-pose box. Measured through this setup on the real models:
##   size    the drawn nose-to-tail length is what a spec "scale" asks for (decision 17: the documented meaning; a world
##           that sets one on a library animal shrinks 26-60%); with no "scale" the size every world has always had
##           (_legacy_len) — the default horse 3.27 m, cow 4.36, dragon 6.12, unchanged.
##   ground  its drawn rest base at y = 0: the bind box stood the default dragon 2.31 m and a triceratops 2.84 m in the air.
##   hull    the box it draws over the clips it plays — rest, idle, walk, run (a flyer's flap and glide, in the air: the
##           hull by state, _sync_hull) — and the ride's rock sweeping it, where it draws it: the horse's nose stood 0.71 m
##           out of the bone box at rest (0.81 galloping), the cow's 1.46 m, the raptor's tail 2.17 m (2.55), the default
##           dragon's wings 1.47 m a side; ridden into a wall, the horse put 0.86 m of head into it and the cow 1.62 m.
##   keel    its drawn rest points: the underside the ground model rests it on (_measure_keel).
## Returns the ground hull (self frame), or AABB() to fall back to the static path.
func _mount_drawn(spec: Dictionary, model: Node3D) -> AABB:
	_resolve_gait(_find_anim(model))
	var fit := GBody.fit(model, "mount")
	if not bool(fit.get("ok", false)):
		return AABB()
	var rest: AABB = fit["rest"]
	var xf := _drawn_xf(model, rest, spec, profile)
	if xf == Transform3D():
		return AABB()
	model.transform = xf
	_model_xf = xf
	_drawn_rest = xf * rest
	# The ride ROCK (_update_ride_motion: +/- RIDE_PITCH_DEG about the origin while it walks) swings that body too:
	# 0.26 m of the default dragon's head past its box, 0.05-0.07 m of a horse's or cow's. The hull is the volume it
	# sweeps, not one frame of it; and a pose that dips below the feet is ground, not body anything meets. ONLY A MOUNT
	# THAT ROCKS (F1): one with a walk or a run of its own plays it, and the rock on top of it is gone.
	var body := xf * (fit["aabb"] as AABB)
	if not _gaited:
		var rk := deg_to_rad(RIDE_PITCH_DEG)
		body = body.merge(Transform3D(Basis(Vector3.RIGHT, rk), Vector3.ZERO) * body).merge(Transform3D(Basis(Vector3.RIGHT, -rk), Vector3.ZERO) * body)
	var y0 := maxf(body.position.y, 0.0)
	_hull_ground = AABB(Vector3(body.position.x, y0, body.position.z), Vector3(body.size.x, maxf(body.end.y - y0, 0.3), body.size.z))
	if bool(PROFILES[profile].get("fly", false)):
		# IN THE AIR it is the box its wingbeat fills, below its feet too: nothing there is ground.
		var air := GBody.fit(model, "mount_air")
		if bool(air.get("ok", false)):
			_hull_air = xf * (air["aabb"] as AABB)
	var span := _skel_span(model)
	if span.has_volume():
		var ss := (xf * span).size
		_seat_box = AABB(Vector3(-ss.x * 0.5, 0.0, -ss.z * 0.5), ss)
	var fb := _skel_feet_back(model)           # full node chain: right in every exporter's axes, already grounded
	if is_finite(fb.y):
		_mount_seat_y = fb.y
	_drawn_pts = PackedVector3Array()
	for p in GPose.drawn_rest_points(model):
		_drawn_pts.append(xf * p)
	_keel_fit = fit.get("keel", {})
	if _water_rest:
		_draft = WATER_DRAFT * _drawn_rest.size.y
	add_child(model)
	_visual = model
	_flyer_scale = model.scale.x
	print("GOGI_MOUNT_BODY %s %s drawn %.2f %.2f %.2f hull %.2f %.2f %.2f air %.2f %.2f %.2f size %s" % [
		display_name.replace(" ", "_"), profile, _drawn_rest.size.x, _drawn_rest.size.y, _drawn_rest.size.z,
		_hull_ground.size.x, _hull_ground.size.y, _hull_ground.size.z, _hull_air.size.x, _hull_air.size.y, _hull_air.size.z,
		"scale" if spec.has("scale") else "kept"])
	return _hull_ground


## THE TRANSFORM A DRAWN MOUNT'S MODEL IS GIVEN (_mount_drawn; Transform3D() when it draws no length): its size — D7: no
## "scale" keeps the size every world has always had (the profile's length over _legacy_len), an explicit "scale" is its drawn
## nose-to-tail length — and the lowest thing it draws at rest (`rest`, GPose.body_fit's) standing on y = 0. Static, so the
## seat measured where its GLB is parsed (seat_warm) is measured on the model as setup() will draw it.
static func _drawn_xf(model: Node3D, rest: AABB, spec: Dictionary, prof: String) -> Transform3D:
	var rb := model.transform * rest
	if rb.size.z <= 0.001:
		return Transform3D()
	var k: float
	var legacy := _legacy_len(model)
	if spec.has("scale"):
		k = float(spec["scale"]) / rb.size.z
	elif legacy > 0.05:
		k = float(PROFILES[prof]["length"]) / legacy
	else:
		k = float(PROFILES[prof]["length"]) / rb.size.z
	var xf := Transform3D(model.transform.basis.scaled(Vector3(k, k, k)), model.transform.origin)
	rb = xf * rest
	xf.origin.y -= rb.position.y          # the lowest thing it draws at rest stands on y = 0
	return xf


# The mount's gait clips (GClip.gaits — the one lookup, which the body it is fitted over reads too: gait_clips), taken
# from the model before it is measured and again from the rider-facing player in _setup_mount (the same AnimationPlayer:
# the same answers).
func _resolve_gait(ap: AnimationPlayer) -> void:
	_gait_ap = ap
	var g := GClip.gaits(ap)
	_clip_walk = g["walk"]
	_clip_fast = g["fast"]
	_clip_idle = g["idle"]
	_clip_flap = g["flap"]
	_clip_glide = g["glide"]
	_clip_any = g["any"]   # move fallback: an UNNAMED clip beats a frozen ride (2.4)
	_gaited = _clip_walk != "" or _clip_fast != "" or _clip_any != ""   # what _update_gait plays when it moves


## FEET ON THE GROUND (GFeet, feet.gd): a drawn mount with legs (GRig.legs) plants them, solved under its skeleton after its
## clip; while they stand it rests on what it draws without them (its fit's keel: _keel_now), and its legs grip the ground a
## gallop runs over as far as they reach (_grip_reach). Set up after its rest frame (_vis_rest) is known.
func _attach_feet() -> void:
	if not _drawn_rest.has_volume() or _visual == null:
		return
	var sk := GPose.skeleton_of(_visual)
	var ft := GFeet.new()
	ft.name = "GFeet"
	if sk == null or not ft.attach(self, sk, _visual):
		ft.free()
		return
	sk.add_child(ft)
	_feet = ft
	var legs := GRig.legs(_visual)
	_chained = not legs.is_empty() and legs.all(func(L): return bool(L["chain"]))   # (no legs is no chain: all() of none is true)
	_grip_reach = GFeet.CROUCH_MAX * ft.shortest
	for c in _keel_fit:
		var row: Array = []
		for k in (_keel_fit[c] as Array):
			var q := PackedVector3Array()
			for p in (k as PackedVector3Array):
				# ...no lower than its feet stand (y 0): a clip that draws its body under its own ground (the Rig Lab dragon's walk
				# drags its belly 0.13 m, the triceratops's head 0.10) is the clip's fault, held where its feet are — rested on as
				# drawn, the mire dragon rode its belly with its feet 0.13 m in the air, and pitched its hull 0.13 m into the face it
				# took off toward (the drive rig's (r2))
				var b := _model_xf * p
				q.append(Vector3(b.x, maxf(b.y, 0.0), b.z))
			row.append(q)
		_keel_tab[c] = row
	_keel_fit = {}
	var s2b := _vis_rest * GPose.xf_to(sk, _visual)
	for L in ft.legs:
		var f := s2b * sk.get_bone_global_rest(int(L["foot"])).origin
		_feet_xz.append(Vector2(f.x, f.z))


# ── ASSEMBLED MULTI-PART VEHICLE (Phase 3) ──────────────────────────────────────────────────────
# A Meshy-styled BODY GLB (empty wheel wells, no baked prop) + a single WHEEL GLB the engine instances
# at each hub + an optional PROPELLER/ROTOR GLB. The separate parts feed the SAME proven spinner pipeline
# the parametric car/plane use — _update_wheels rolls _wheels about _wheel_axle and slews the front
# _steer_pivots; the _physics_process tick spins _prop about its local +Y — so a Meshy-styled vehicle
# finally gets REAL rolling/steering wheels + a spinning prop with NO doubling (nothing is baked into the
# body). Everything hangs off ONE container that becomes _visual, with the body pre-oriented (nose -> +Z)
# and pre-scaled INSIDE it, then _flyer_orient_yaw/_flyer_scale are reset to 0/1 so the airborne basis
# rebuild (1393/1415) adds ONLY pitch/roll to the container (body + prop + wheels pitch/roll as one unit).
# Returns the BODY-only self-local AABB the box collider is derived from (wheels/prop are visual — no
# collider — so the hull box stays tight, unlike the parametric car whose AABB happens to include wheels).
func _assemble_model(spec: Dictionary, model: Node3D, parts: Dictionary) -> AABB:
	var root := Node3D.new()
	root.name = "AssembledVehicle"
	add_child(root)
	_visual = root
	var body_ab := _assemble_body(spec, root, model)
	# The container holds the final orientation + scale on the body inside it, so the flyer basis-rebuild
	# must add ONLY pitch/roll — never re-apply an orient yaw or a scale (those live on the body child).
	_flyer_orient_yaw = 0.0
	_flyer_scale = 1.0
	# WHEELS / PROP — a bespoke body ALWAYS gets wheels on a car/plane (and a prop on a plane): the
	# supplied wheel/prop GLB when present, else a PARAMETRIC fallback. So a body_url with a MISSING or
	# FAILED wheel_url|prop_url still rolls/spins instead of sliding on a wheelless hull — the graceful
	# degrade for the multi-part salvage path (the agent can drop a failed part's url and still ship a
	# working bespoke ride). Front hubs steer on a car; aircraft gear rolls only.
	_wheels = []
	_steer_pivots = []
	_wheel_axle = Vector3.RIGHT
	var wheel_src := parts.get("wheel", null) as Node3D
	# A car always rolls; a flyer gets wheels ONLY if a wheel GLB was authored. Many planes (especially a
	# seaplane) have no wheels, and forcing parametric wingtip gear onto them just reads as "weird side
	# wheels" — so a wheel-less flyer stays clean, while an authored-wheel plane gets tucked belly gear.
	if wheel_src != null or profile == "car":
		_assemble_wheels(spec, root, body_ab, wheel_src)   # wheel_src null (car) -> parametric fallback wheels
	# PROP / ROTOR — nose (+Z) for a plane, top (+Y) for a helicopter-style rotor; spun about local +Y
	var prop_src := parts.get("prop", null) as Node3D
	if prop_src != null or profile == "plane":
		_assemble_prop(spec, root, body_ab, prop_src)      # prop_src null on a plane -> parametric prop disc
	print("GOGI_ASSEMBLED ", display_name, " profile=", profile, " wheels=", _wheels.size(), " steer=", _steer_pivots.size(), " prop=", ("yes" if _prop != null else "no"), " wheel_r=%.2f" % _wheel_radius)
	return body_ab


# BODY of an assembled vehicle: normalise to the profile length, orient the nose onto +Z (flyers use the
# fuselage detector; ground vehicles yaw 90 when their length runs along X), ground the base to y=0, and
# parent it INTO the container `root`. Returns the body-only AABB in container/self-local frame. Mirrors
# _mount_model's vehicle branch minus the mount/skinned-creature handling. A missing GLB degrades to a
# gray body box so the boardable still works.
func _assemble_body(spec: Dictionary, root: Node3D, model: Node3D) -> AABB:
	var target_len := float(spec.get("scale", PROFILES[profile]["length"]))
	if model != null:
		var ab := GPose.drawn_aabb(model)
		if bool(PROFILES.get(profile, {}).get("fly", false)):
			_orient_flyer_fuselage(model)   # WINGSPAN fools the x>z rule — detect the fuselage by end bulk
			ab = GPose.drawn_aabb(model)
		elif ab.size.x > ab.size.z:
			model.rotation.y += PI * 0.5    # length ran along X -> would drive crab-wise; yaw onto +Z
			ab = GPose.drawn_aabb(model)
		var dim := maxf(ab.size.x, ab.size.z)
		if dim > 0.001:
			model.scale *= target_len / dim
		ab = GPose.drawn_aabb(model)
		model.position.y = -ab.position.y   # base -> y=0 (lift & drop, the _mount_model grounding idiom)
		root.add_child(model)
		return GPose.drawn_aabb(model)
	# GLB missing -> gray "loading" body box, still boardable (mirror _mount_model's placeholder)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(target_len * 0.45, 1.3, target_len)
	mi.mesh = bm
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.55, 0.57, 0.6)
	mi.material_override = pm
	mi.position.y = 0.65
	root.add_child(mi)
	print("GOGI_PLACEHOLDER vehicle ", profile, " (assembled body GLB missing)")
	return AABB(Vector3(bm.size.x * -0.5, 0.0, bm.size.z * -0.5), bm.size)


# Instance the single wheel GLB at each hub. Hubs auto-derive from the body footprint (front/rear axle
# +/- wheelbase/2, left/right +/- track/2, hub y = wheel radius so the tyre bottom kisses y=0) unless the
# spec authors "hubs":[{"pos":[x,y,z],"steer":bool}]. Each wheel is fitted into a holder whose ROLL axis
# is local +X (the modeled convention, _wheel_axle=RIGHT) and scaled to the wheel radius; the HOLDER is
# what spins (and, for a car's front hubs, what a WheelPivot steers). Aircraft gear never steers.
func _assemble_wheels(spec: Dictionary, root: Node3D, body_ab: AABB, wheel_src: Node3D) -> void:
	var is_car := not bool(PROFILES.get(profile, {}).get("fly", false))
	var wheel_r := float(spec.get("wheel_r", clampf(body_ab.size.y * 0.30, 0.22, 0.7)))
	_wheel_radius = maxf(0.05, wheel_r)
	for hub in _wheel_hubs(spec, body_ab, _wheel_radius, is_car):
		var pos: Vector3 = hub[0]
		var steer: bool = hub[1]
		var holder := Node3D.new()
		holder.name = "Wheel"
		var wh: Node3D
		if wheel_src != null:
			wh = wheel_src.duplicate() as Node3D
		else:
			wh = _parametric_wheel(_wheel_radius)   # no wheel_url -> a dark parametric tyre so the bespoke body still rolls
		holder.add_child(wh)
		_fit_part_axis(holder, wh, 0, _wheel_radius)   # roll axis -> +X, radius -> wheel_r, centre at holder origin
		if steer:
			var pivot := Node3D.new()
			pivot.name = "WheelPivot"
			pivot.position = pos
			root.add_child(pivot)
			pivot.add_child(holder)                     # holder sits at the pivot origin; the pivot carries the steer yaw
			_steer_pivots.append(pivot)
		else:
			holder.position = pos
			root.add_child(holder)
		_wheels.append(holder)


# Four hub anchors (self-local) from the body footprint, or the authored spec "hubs". Front hubs (z>0)
# steer on a car. wheelbase/track default to fractions of the body length/width; spec overrides win.
func _wheel_hubs(spec: Dictionary, body_ab: AABB, wheel_r: float, is_car: bool) -> Array:
	var out: Array = []
	var authored = spec.get("hubs", null)
	if authored is Array:
		for h in authored:
			if h is Dictionary and (h.get("pos") is Array) and (h["pos"] as Array).size() >= 3:
				var a: Array = h["pos"]
				out.append([Vector3(float(a[0]), float(a[1]), float(a[2])), bool(h.get("steer", false))])
		if not out.is_empty():
			return out
	var cx := body_ab.position.x + body_ab.size.x * 0.5
	var cz := body_ab.position.z + body_ab.size.z * 0.5
	var half_base := maxf(0.3, float(spec.get("wheelbase", body_ab.size.z * 0.62)) * 0.5)
	# AIRCRAFT gear: a plane's body is nose-onto-+Z, so size.x is the WINGSPAN — deriving the track from
	# it fans the gear out to the wingtips ("wheels on the side"). A flyer tucks a narrow belly gear under
	# the fuselage instead (clamped well inside the wingspan); a car keeps the wide footprint.
	var track_def := body_ab.size.x * 0.82
	if not is_car:
		track_def = clampf(body_ab.size.z * 0.16, wheel_r * 3.0, body_ab.size.x * 0.14)
	var half_track := maxf(0.3, float(spec.get("track", track_def)) * 0.5)
	for sx in [-1.0, 1.0]:
		out.append([Vector3(cx + half_track * sx, wheel_r, cz + half_base), is_car])   # front (steer on a car)
		out.append([Vector3(cx + half_track * sx, wheel_r, cz - half_base), false])    # rear
	return out


# Place the prop/rotor GLB and assign _prop (spun about its local +Y in _physics_process while driving).
# PLANE (default): nose (+Z), holder rotation.x=90 so local +Y -> forward, disc faces ahead — the same
# axis trace as the parametric PropDisc. HELICOPTER-style (spec "prop_mount":"top"): on top, local +Y
# stays up so the blades sweep horizontally. The blade disc is fitted so its normal is holder-local +Y.
func _assemble_prop(spec: Dictionary, root: Node3D, body_ab: AABB, prop_src: Node3D) -> void:
	var holder := Node3D.new()
	holder.name = "PropDisc"
	var pr: Node3D
	if prop_src != null:
		pr = prop_src.duplicate() as Node3D
	else:
		pr = _parametric_prop()   # no prop_url on a plane -> a cosmetic parametric disc so it still spins
	holder.add_child(pr)
	var target_r := clampf(maxf(body_ab.size.x, body_ab.size.y) * 0.45, 0.35, 2.2)
	_fit_part_axis(holder, pr, 1, target_r)   # disc normal -> +Y, radius -> target_r, centre at holder origin
	var cx := body_ab.position.x + body_ab.size.x * 0.5
	if String(spec.get("prop_mount", "nose")) == "top":
		holder.position = Vector3(cx, body_ab.end.y + target_r * 0.12, body_ab.position.z + body_ab.size.z * 0.5)
	else:
		holder.rotation.x = PI * 0.5   # local +Y -> +Z (forward): the disc faces the nose
		holder.position = Vector3(cx, body_ab.position.y + body_ab.size.y * 0.55, body_ab.end.z + target_r * 0.10)
	root.add_child(holder)
	_prop = holder


# Fit a wheel/disc part INTO its holder: rotate the part so its THIN axis (a wheel's roll axis / a prop
# disc's normal) points the holder-local `axis_to` (0 = +X wheel roll, 1 = +Y disc normal), uniform-scale
# it so its radius (across the two thick axes) = target_r, and shift it so the part CENTRE sits at the
# holder origin — so the holder's position IS the hub/mount point and spinning rolls about the centre. A
# wheel/disc is symmetric about its axis, so either sign of the target axis is equivalent.
func _fit_part_axis(holder: Node3D, part: Node3D, axis_to: int, target_r: float) -> void:
	var ab := GPose.drawn_aabb(part)
	if ab.size == Vector3.ZERO:
		return
	var thin := _thin_axis(ab.size)
	if axis_to == 0:                            # want thin on +X (wheel roll axis)
		if thin == 1: part.rotate_z(PI * 0.5)   # +Y -> +X
		elif thin == 2: part.rotate_y(PI * 0.5)  # +Z -> +X
	else:                                        # want thin on +Y (disc normal)
		if thin == 0: part.rotate_z(PI * 0.5)   # +X -> +Y
		elif thin == 2: part.rotate_x(PI * 0.5)  # +Z -> +Y
	var ab2 := GPose.drawn_aabb(part)
	var rad := (maxf(ab2.size.y, ab2.size.z) if axis_to == 0 else maxf(ab2.size.x, ab2.size.z)) * 0.5
	if rad > 0.001:
		part.scale *= target_r / rad
	var ab3 := GPose.drawn_aabb(part)
	part.position -= (ab3.position + ab3.size * 0.5)   # centre the part on the holder origin


# Index (0=x,1=y,2=z) of the smallest extent — a wheel/disc's flat axis (its spin/roll axis).
func _thin_axis(size: Vector3) -> int:
	if size.x <= size.y and size.x <= size.z:
		return 0
	if size.y <= size.x and size.y <= size.z:
		return 1
	return 2


# PARAMETRIC FALLBACK PARTS for an assembled body whose wheel_url / prop_url is missing or failed — so a
# bespoke Meshy body still ROLLS (and a plane still spins a prop) instead of sliding on a wheelless hull.
# Both are built origin-centred with their flat/thin axis on +Y, so _fit_part_axis fits + scales them into
# a Wheel/PropDisc holder exactly like a loaded GLB part (a wheel: thin +Y -> roll +X; a disc: thin +Y).
func _parametric_wheel(r: float) -> MeshInstance3D:
	var tire := GSurf.surface({"color": [0.07, 0.07, 0.08], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 4.0})
	var wh := GShapes.cylinder(r, r, r * 0.55, 18)   # thin axis = height (< radius) = +Y
	GShapes.set_material(wh, tire)
	return wh


func _parametric_prop() -> MeshInstance3D:
	var trim := GSurf.surface({"color": [0.15, 0.15, 0.17], "rough": 0.6, "metal": 0.35, "bump": 0.0, "tile": 6.0})
	var disc := GShapes.cylinder(1.0, 1.0, 0.06, 24)   # flat cosmetic disc, thin axis +Y (matches the parametric plane prop)
	GShapes.set_material(disc, trim)
	return disc


# FLYER FUSELAGE ORIENT. Aircraft GLBs are authored with the nose along an arbitrary horizontal axis AND
# direction, and the ground x>z rule CAN'T tell fuselage from WINGSPAN — a plane's wings make the AABB
# x<z even when the fuselage is sideways, so the old code excluded flyers and left them crab-wise +
# barrel-rolling on climb (pitch is applied about local X; for an X-fuselage that's a ROLL). Two-step:
#   (1) FUSELAGE AXIS = the horizontal axis whose ENDS keep HEIGHT (nose/cockpit/tail-fin are tall) while
#       the WINGSPAN axis tapers to THIN wingtips.
#   (2) NOSE END = the end with the larger OUTER cross-section (the blunt cockpit/engine mass). The TAIL
#       always tapers to a thin boom/fin, so cross-section — not end-HEIGHT — is the reliable nose signal:
#       a propeller/cockpit makes the NOSE the taller end on some models and the tail fin makes the TAIL
#       taller on others (the old "taller = tail" rule flew the Bush Plane/helicopter BACKWARDS).
# Then bake the yaw that turns the nose onto +Z (the drive axis) so climbing PITCHES the nose up.
func _orient_flyer_fuselage(model: Node3D) -> void:
	var pts := PackedVector3Array()
	_collect_mesh_pts(model, Transform3D.IDENTITY, pts, 2400)
	if pts.size() < 24:
		return
	var mn := pts[0]
	var mx := pts[0]
	for p in pts:
		mn = mn.min(p)
		mx = mx.max(p)
	var size := mx - mn
	if size.x < 0.01 or size.z < 0.01:
		return
	# (1) fuselage axis = the horizontal axis with the TALLER ends (nose/cockpit/fin vs thin wingtips)
	var xlo := _yspan_end(pts, 0, mn.x, mn.x + 0.25 * size.x)
	var xhi := _yspan_end(pts, 0, mx.x - 0.25 * size.x, mx.x)
	var zlo := _yspan_end(pts, 2, mn.z, mn.z + 0.25 * size.z)
	var zhi := _yspan_end(pts, 2, mx.z - 0.25 * size.z, mx.z)
	var fax := 0 if maxf(xlo, xhi) >= maxf(zlo, zhi) else 2   # 0 = X fuselage, 2 = Z fuselage
	var pax := 2 if fax == 0 else 0                            # WINGSPAN axis (perpendicular horizontal)
	# (2) nose end = the end with the larger OUTER cross-section (blunt cockpit/engine); tail tapers thin
	var neg_bulk := _end_xsec(pts, fax, pax, mn, size, false)
	var pos_bulk := _end_xsec(pts, fax, pax, mn, size, true)
	var nose_pos := pos_bulk > neg_bulk       # true = nose on the +axis end
	# rotate the nose onto +Z: X-fuselage needs ±90°; Z-fuselage is 0 (already fwd) or 180 (reversed)
	if fax == 0:
		_flyer_orient_yaw = (-PI * 0.5) if nose_pos else (PI * 0.5)
	else:
		_flyer_orient_yaw = 0.0 if nose_pos else PI
	if not is_zero_approx(_flyer_orient_yaw):
		model.rotation.y += _flyer_orient_yaw
	var axn := "X" if fax == 0 else "Z"
	var nosn := ("+" if nose_pos else "-") + axn
	print("GOGI_FLYER_ORIENT %s fuselage=%s nose=%s bulk(-/+)=%.2f/%.2f yaw=%.2f" % [display_name, axn, nosn, neg_bulk, pos_bulk, _flyer_orient_yaw])


# Gather sampled mesh vertices into `out` in the frame of the ROOT passed to the first call (xf = the
# transform from each descendant up to that root). Sampled/capped so a dense hull stays cheap at load.
func _collect_mesh_pts(node: Node, xf: Transform3D, out: PackedVector3Array, cap: int) -> void:
	if out.size() >= cap:
		return
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mesh: Mesh = (node as MeshInstance3D).mesh
		for si in mesh.get_surface_count():
			var arr := GPose.surface_arrays(mesh, si)
			if arr.size() <= Mesh.ARRAY_VERTEX or arr[Mesh.ARRAY_VERTEX] == null:
				continue
			var vs := arr[Mesh.ARRAY_VERTEX] as PackedVector3Array
			var step := maxi(1, int(vs.size() / maxi(1, int(cap / 3))))
			var i := 0
			while i < vs.size() and out.size() < cap:
				out.append(xf * vs[i])
				i += step
	for c in node.get_children():
		if c is Node3D:
			_collect_mesh_pts(c, xf * (c as Node3D).transform, out, cap)


# Vertical extent (max-min y) of the vertices whose X (axis 0) or Z (axis 2) falls in [lo, hi]. 0 if empty.
func _yspan_end(pts: PackedVector3Array, axis: int, lo: float, hi: float) -> float:
	var ymn := INF
	var ymx := -INF
	for p in pts:
		var a: float = p.x if axis == 0 else p.z
		if a >= lo and a <= hi:
			ymn = minf(ymn, p.y)
			ymx = maxf(ymx, p.y)
	return (ymx - ymn) if ymx > ymn else 0.0


# Outer-end cross-section proxy (perp-width * height) over the outer 30% band on one end of the
# fuselage axis. The NOSE (blunt cockpit/engine) has the larger cross-section; the TAIL tapers to a
# thin boom/fin — so the bulkier end is the nose. `positive`=true samples the +axis end, else the -axis.
func _end_xsec(pts: PackedVector3Array, fax: int, pax: int, mn: Vector3, size: Vector3, positive: bool) -> float:
	var lenf: float = size[fax]
	if lenf < 0.001:
		return 0.0
	var lo := 0.70 if positive else 0.0
	var hi := 1.0 if positive else 0.30
	var pmn := INF
	var pmx := -INF
	var ymn := INF
	var ymx := -INF
	for p in pts:
		var t: float = (p[fax] - mn[fax]) / lenf
		if t >= lo and t < hi:
			pmn = minf(pmn, p[pax])
			pmx = maxf(pmx, p[pax])
			ymn = minf(ymn, p.y)
			ymx = maxf(ymx, p.y)
	if pmx <= pmn or ymx <= ymn:
		return 0.0
	return (pmx - pmn) * (ymx - ymn)


# Modeled-vehicle wheel discovery (2.2): register the TOP-MOST descendant Node3D whose name
# contains wheel/tire/tyre as a spinner (skip its children so a rim+tire pair isn't double-spun).
# A +Z-facing body rolls its wheels about local +X, so _wheel_axle flips to +X here. No match ->
# _wheels stays empty (static wheels, per the fused-GLB contract) — we never fabricate wheels the
# model doesn't have, and never steer-pivot a modeled vehicle (no reliable steer axis).
func _scan_model_wheels(model: Node3D) -> void:
	_wheels = []
	_steer_pivots = []
	_wheel_axle = Vector3.RIGHT
	var stack: Array = [model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var matched := false
		if n is Node3D:
			var nm := String(n.name).to_lower()
			if "wheel" in nm or "tire" in nm or "tyre" in nm:
				_wheels.append(n as Node3D)
				matched = true
		if not matched:
			for c in n.get_children():
				stack.append(c)
	# Fused single-mesh vehicle GLBs (typical of Meshy text/image-to-3D output) have their wheels
	# BAKED INTO the body mesh — no separable wheel nodes to spin. We do NOT fabricate parametric
	# wheels here: a model that already shows baked wheels would then render doubled. Instead emit a
	# build-visible line so verify/QA can flag it — the world author should use a PARAMETRIC profile
	# (wheels spin) or a model with separable wheel/tire nodes when rolling wheels matter.
	if _wheels.is_empty():
		print("GOGI_WHEELS fused-static ", display_name, " (modeled vehicle has no separable wheel nodes — wheels won't spin)")


# Mount extras, computed at setup from the FINAL (scaled, grounded) box `ab` the saddle point is read off (a drawn mount's
# bone box, _seat_box: the hull is the body, _mount_drawn):
#   - "MountMarker": where the rider's DRAWN SEAT rests — the saddle's top, SADDLE_T over the back the mount draws under its
#     saddle point ({"saddle": false}: on it). That back is measured (GPose.mount_seat): the top of what it draws standing
#     (its idle at 0) on the vertical line through the profile's point and the most it rises under the rider's footprint —
#     moved along the body to the nearest back a seat wide and clear when what tops that line is a head, a fin or a plate
#     (rule (b), S1).
#     The bone guess it replaces (the highest torso-named bone + 6% of the bone box) put the default horse's saddle 0.19 m
#     inside it and the triceratops's 0.41 m over its back. An authored seat (spec "seat" / a SaddleMarker node) is where
#     the saddle sits, verbatim; no line near the point meeting the body (a Rig Lab proxy's cubes): the bone seat as before.
#   - one GOGI_SEAT_CONTACT line: <name, spaces as _> <the saddle's base over the back drawn under the rider's seat, signed:
#     negative = inside> <drawn|authored|none>. A drawn seat prints 0.000 BY CONSTRUCTION — it is that back — so verify's
#     MOUNT TOO HIGH and MOUNT SEAT INSIDE catch an authored seat, and "none" a mount with no back under its saddle; where
#     riders really sit is the drive rig's to guard (seats.gd).
#   - parametric saddle on the back (spec {"saddle": false} disables).
#   - boarding spot: on the ground beside the creature's flank at the saddle's z (a saddle rule (b) moved, it moves with).
#   - gait AnimationPlayer + clip resolution through GClip.gaits (clip_role.gd: walk, run with a gallop
#     preferred, idle, fly, glide). Library animals and rig-lab outputs both carry EMBEDDED clips; a
#     rig whose only clips are UNNAMED ("Take 001") still rides on the longest of them (_clip_any)
#     instead of freezing. A clip that names another action is never a gait: the longest-clip rule
#     rode the Rig Lab serpent in "idle" (slither was no gait word) and handed smuggler_melee cast
#     as a horse "death" as its move fallback.
func _setup_mount(spec: Dictionary, ab: AABB) -> void:
	var centre := ab.position + ab.size * 0.5
	var seat_z := centre.z + float(SEAT_Z_OFF.get(profile, 0.0)) * ab.size.z
	var saddle := bool(spec.get("saddle", true))
	var gap := 0.0
	var base := _authored_seat(spec)   # the saddle's base, self frame
	_seat_kind = "authored" if base.is_finite() else "none"
	if _visual != null:
		# the back it draws: under an authored seat exactly (its contact, and what it rides), else under the saddle point
		var m := _measure_seat(base if base.is_finite() else Vector3(centre.x, 0.0, seat_z), base.is_finite())
		if bool(m.get("ok", false)):
			_seat = m
			var back := _seat_xf() * Vector3(float(m["x"]), float(m["y"]) + float(m["relief"]), float(m["z"]))
			if base.is_finite():
				gap = base.y - back.y
			else:
				base = back
				_seat_kind = "drawn"
			var mis := GPose._seat_meshes(_visual)
			var ai := int((m["anchor"] as Dictionary)["mesh"])
			_seat_skel = GPose._skin_skeleton(mis[ai]) if ai < mis.size() else null
	if not base.is_finite():
		if is_finite(_mount_seat_y):
			# NO BACK UNDER THE SADDLE (no line near the point meets what it draws): the skeleton's saddle line (highest
			# torso bone), cached by _mount_drawn in the SAME grounded, base-0 frame as `ab`, a hair over it.
			base = Vector3(centre.x, _mount_seat_y + 0.06 * ab.size.y, seat_z)
		else:
			# No skeleton (parametric/placeholder mount): degrade to the prior mesh-scan + fraction heuristic.
			var frac_y := ab.position.y + float(SEAT_FRACTION.get(profile, 0.6)) * ab.size.y
			var dy := _dorsal_y(centre.x, seat_z, ab)
			var lo := ab.position.y + 0.60 * ab.size.y
			var hi := ab.position.y + 0.72 * ab.size.y
			if is_finite(dy) and dy >= lo and dy <= hi:
				base = Vector3(centre.x, dy, seat_z)   # scan landed on the back
			else:
				base = Vector3(centre.x, frac_y, seat_z)   # bogus/absent scan -> back-line fraction
	_mount_marker = Node3D.new()
	_mount_marker.name = "MountMarker"
	_mount_marker.position = base + Vector3(0.0, GPose.SADDLE_T if saddle else 0.0, 0.0)
	add_child(_mount_marker)
	print("GOGI_SEAT_CONTACT %s %.3f %s" % [_contact_name(spec), gap, _seat_kind])
	if saddle:
		_build_saddle(base)
	# boarding walks up beside the saddle: the flank of the bone box it stands on, under a dragon's wing (3.35 m out, as it
	# always was). The hull's flank is the wingtip: boarding there (4.71 m) walked the rider out past everything the wing
	# spans and snapped them 5.3 m onto the saddle (behaviour review).
	_board_local = Vector3(ab.end.x + 0.5, 0.0, _mount_marker.position.z)
	_resolve_gait(_find_anim(self))


# A boardable's name as the seat-contact line writes it: one word (its spaces as _), so verify reads the gap after it — "Horse 2
# 0.500" read as a gap of 2 (seats review).
func _contact_name(spec: Dictionary) -> String:
	var nm := String(spec.get("name", String(spec.get("profile", profile)))).strip_edges().replace(" ", "_").replace("\t", "_")
	return nm if nm != "" else profile


# The model's transform the seat is measured under: the one setup gave a drawn mount (_drawn_xf, kept: the transform read
# back off the node can differ in its last bits, and the seat warmed where the GLB was parsed is keyed on these numbers).
func _seat_xf() -> Transform3D:
	return _model_xf if _drawn_rest.has_volume() else _visual.transform


# The seat on the back it draws (GPose.mount_seat, in the model's frame at the scale it is drawn), under `at` (self frame) —
# exactly there (`fixed`: an authored seat), else the nearest back along the body rule (b) finds.
func _measure_seat(at: Vector3, fixed: bool) -> Dictionary:
	var xf := _seat_xf()
	var p := xf.affine_inverse() * at
	return GPose.mount_seat(_visual, xf.basis.get_scale().x, p.x, p.z, 0.0 if fixed else GPose.SEAT_SEARCH)


## THE SEAT A MOUNT WILL BE SET UP ON, measured where its GLB is parsed (main._mark_vehicle_fits hands AreaBuilder this, worked
## a piece at a time after the model's mount fit): the same model, scale and saddle point setup() measures — an authored seat
## (spec "seat", a SaddleMarker in the model) exactly where it is, as setup() measures its contact — so setup() reads it
## memoised and pays nothing in the frame that spawns it — measured there, the seat cost 3-22 ms a model (desktop: the mire
## dragon's 14.7k vertices 21, a horse 8). `scene` is the parsed source every copy is duplicated from. null when there is
## nothing to warm: not a mount, no skeleton (a static model is sized where it is set up: its seat is measured there), a size
## it cannot draw.
static func seat_warm(scene: Node, spec: Dictionary) -> RefCounted:
	var prof := String(spec.get("profile", "car"))
	if not (scene is Node3D) or not PROFILES.has(prof) or not bool(PROFILES[prof].get("mount", false)):
		return null
	var model := scene as Node3D
	if GPose.skeleton_of(model) == null:
		return null
	var fit := GBody.fit(model, "mount")
	if not bool(fit.get("ok", false)):
		return null
	var xf := _drawn_xf(model, fit["rest"], spec, prof)
	var span := _skel_span(model)
	if xf == Transform3D() or not span.has_volume():
		return null
	var at := _authored_at(spec, model, xf)
	if at.is_finite():
		var q := xf.affine_inverse() * at
		return GPose.MountSeatJob.new(model, xf.basis.get_scale().x, q.x, q.z, 0.0)
	var p := xf.affine_inverse() * Vector3(0.0, 0.0, float(SEAT_Z_OFF.get(prof, 0.0)) * (xf * span).size.z)
	return GPose.MountSeatJob.new(model, xf.basis.get_scale().x, p.x, p.z, GPose.SEAT_SEARCH)


# Synthesized seat for MODELED vehicles (the empty-jeep fix): an authored seat wins outright;
# otherwise seat at the CABIN CENTRE at half body height and put a "SeatMarker" there (the
# in-body comment at the retired _probe_cabin_seat says why the column probe went). enter()'s
# instant board then seats the driver VISIBLY (GPose.sit through _seat_driver, _seated=true —
# _park_driver/_track_driver's existing visible-seated path drives it). Closed cabs and flyers
# keep the Wave-1 hide, unchanged.
func _setup_vehicle_seat(spec: Dictionary, ab: AABB) -> void:
	if String(spec.get("cab", "")) == "closed":
		# authored closed cab (helicopter / jet glider): the dorsal probe lands the driver ON the
		# hull exterior of a closed-canopy aircraft (QA P1-A) — keep the hidden-driver swap-in.
		return
	var seat := _authored_seat(spec)
	if not seat.is_finite():
		# AIRCRAFT (fly profile, no authored seat): an aircraft's AABB height is inflated by the tall
		# tail fin + landing gear, so the centre-of-AABB seat below lands at/above the cabin roof and
		# the seated pilot POPS OUT the top (QA: Bush Plane). A fused-GLB cockpit interior is unreliable
		# to probe, so hide the driver (the Wave-1 swap-in) for every flyer — same as the closed-cab
		# helicopter/glider. An explicit spec "seat" still wins above; this only replaces the fallback.
		if bool(PROFILES.get(profile, {}).get("fly", false)):
			print("GOGI_SEAT_CONTACT ", _contact_name(spec), " hidden-flyer")
			return
		# Seat the driver at the CABIN CENTRE at seat height. This replaces the fragile per-model floor
		# probe, which HID the driver entirely on fused/open hulls (the INVISIBLE roadster) and picked
		# the wrong row on others (the driver riding in the truck BED). A centre-of-cabin seat is ALWAYS
		# visible, seated INSIDE the hull, and never popping — consistent across every AI-generated model.
		var centre := ab.position + ab.size * 0.5
		seat = Vector3(centre.x, ab.position.y + 0.5 * ab.size.y, centre.z)
	_seat_marker = Node3D.new()
	_seat_marker.name = "SeatMarker"
	_seat_marker.position = seat + Vector3(0.0, 0.05, 0.0)   # hips just above the found surface
	add_child(_seat_marker)
	# Same telemetry contract as _setup_mount (verify greps one line per boardable): the seat
	# sits directly on the probed cabin surface, so the marker-to-surface gap is the 0.05 lift.
	print("GOGI_SEAT_CONTACT ", _contact_name(spec), " 0.050")


# An authored seat beats every heuristic: spec "seat": [x, y, z] (self-local metres) verbatim, or
# a marker node inside the model ("SaddleMarker"/"saddle"/"SeatMarker"/"seat_hint" — rig-lab and
# builders can pin the exact point). Vector3.INF = nothing authored. The node lookup accumulates
# transforms manually (GPose.drawn_aabb's idiom): setup() runs before tree entry, where global_position
# would error.
func _authored_seat(spec: Dictionary) -> Vector3:
	return _authored_at(spec, _visual, _visual.transform if _visual != null else Transform3D())


# _authored_seat's walk for a model `root` given the transform `root_xf` (seat_warm: before any vehicle is set up on it).
static func _authored_at(spec: Dictionary, root: Node3D, root_xf: Transform3D) -> Vector3:
	var s = spec.get("seat", null)
	if s is Array and (s as Array).size() >= 3:
		return Vector3(float(s[0]), float(s[1]), float(s[2]))
	if root == null:
		return Vector3.INF
	var stack: Array = [[root, root_xf]]
	while not stack.is_empty():
		var pair: Array = stack.pop_back()
		var n: Node = pair[0]
		var xf: Transform3D = pair[1]
		if n is Node3D:
			var nm := String(n.name).to_lower()
			if "saddlemarker" in nm or "seatmarker" in nm or nm == "saddle" or nm == "seat_hint":
				return xf.origin
		for c in n.get_children():
			var cx := xf
			if c is Node3D:
				cx = xf * (c as Node3D).transform
			stack.append([c, cx])
	return Vector3.INF


# Max mesh-vertex height (self-local) in a column around (sx, sz) — the DORSAL-SURFACE sample.
# Rest-pose vertex reads (the scan runs at setup, before any idle clip plays), transform-
# accumulating walk mirroring GPose.drawn_aabb's (detachment-safe). Huge Meshy meshes are STRIDED —
# a surface dense enough to trip the cap stays well-sampled through the stride. Returns -INF
# when no vertex lands in the window (caller falls back to SEAT_FRACTION).
func _dorsal_y(sx: float, sz: float, ab: AABB) -> float:
	var best := -INF
	if _visual == null:
		return best
	var rx := maxf(0.05, DORSAL_X_BAND * ab.size.x)
	var rz := maxf(0.05, DORSAL_Z_BAND * ab.size.z)
	var stack: Array = [[_visual, _visual.transform]]
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
			var mesh: Mesh = (n as MeshInstance3D).mesh
			for s in mesh.get_surface_count():
				var arrays := GPose.surface_arrays(mesh, s)
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var step := 1
				if verts.size() > SCAN_VERT_CAP:
					step = int(ceilf(float(verts.size()) / float(SCAN_VERT_CAP)))
				var i := 0
				while i < verts.size():
					var v := xf * verts[i]
					if absf(v.x - sx) <= rx and absf(v.z - sz) <= rz and v.y > best:
						best = v.y
					i += step
	return best


# RETIRED — _setup_vehicle_seat seats at the CABIN CENTRE instead. Kept for reference only:
# as of the 2026-08-21 rpg->3d engine re-sync this has ZERO callers in EITHER template
# (3d/vehicle.gd used to call it and is now a verbatim copy of this file). Do not wire it
# back up without re-reading why the probe was retired.
# CABIN PROBE: collect every y where the vertical line at (sx, sz) pierces body geometry, then
# walk the crossings TOP-DOWN for a floor/deck/cushion surface with CABIN_HEADROOM of clear
# column above it (open sky counts). The floor band guards both false-opens: a watertight solid
# body's underside (below CABIN_FLOOR_MIN of the height) and its roof read from outside (above
# CABIN_FLOOR_MAX) are rejected, so a fused sedan blob stays on the hide path. Vector3.INF = no
# viable seat.
func _probe_cabin_seat(sx: float, sz: float, ab: AABB) -> Vector3:
	var ys := _column_hits(sx, sz)
	if ys.is_empty():
		return Vector3.INF
	var floor_min := ab.position.y + CABIN_FLOOR_MIN * ab.size.y
	var floor_max := ab.position.y + CABIN_FLOOR_MAX * ab.size.y
	for i in range(ys.size() - 1, -1, -1):
		var fy := ys[i]
		if fy > floor_max or fy < floor_min:
			continue
		var head := (ys[i + 1] - fy) if i + 1 < ys.size() else INF
		if head >= CABIN_HEADROOM:
			# The probe already knows the exact clear column it accepted — keep it, so _seat_driver
			# can ask "does THIS driver fit" instead of assuming CABIN_HEADROOM suits every rig. A
			# cab with 1.0 m of room takes a realistic humanoid and not a chibi, and only the
			# measured value can tell those apart.
			_cabin_headroom = head
			return Vector3(sx, fy, sz)
	return Vector3.INF


# All self-local y crossings of the vertical line at (sx, sz) with the body's triangles, sorted
# ascending. Deindexed via Mesh.get_faces(); a cheap xz reject keeps the per-triangle cost tiny
# and SCAN_TRI_CAP strides truly huge meshes (dense enough to survive the stride).
func _column_hits(sx: float, sz: float) -> PackedFloat32Array:
	var ys := PackedFloat32Array()
	if _visual == null:
		return ys
	var stack: Array = [[_visual, _visual.transform]]
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
			var faces := GPose.faces((n as MeshInstance3D).mesh)
			var tri_count := int(faces.size() / 3.0)
			var step := 3
			if tri_count > SCAN_TRI_CAP:
				step = 3 * int(ceilf(float(tri_count) / float(SCAN_TRI_CAP)))
			var i := 0
			while i + 2 < faces.size():
				var a := xf * faces[i]
				var b := xf * faces[i + 1]
				var c3 := xf * faces[i + 2]
				i += step
				# cheap xz reject before the barycentric test
				if (a.x < sx and b.x < sx and c3.x < sx) or (a.x > sx and b.x > sx and c3.x > sx):
					continue
				if (a.z < sz and b.z < sz and c3.z < sz) or (a.z > sz and b.z > sz and c3.z > sz):
					continue
				var y := _tri_line_y(a, b, c3, sx, sz)
				if not is_nan(y):
					ys.append(y)
	ys.sort()
	return ys


# y where the vertical line at (sx, sz) pierces triangle (a, b, c) — NAN on a miss (2D
# barycentric containment in the xz plane, then the plane equation solved along the line;
# vertical wall faces have no y pierce).
func _tri_line_y(a: Vector3, b: Vector3, c: Vector3, sx: float, sz: float) -> float:
	var v0 := Vector2(c.x - a.x, c.z - a.z)
	var v1 := Vector2(b.x - a.x, b.z - a.z)
	var v2 := Vector2(sx - a.x, sz - a.z)
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d02 := v0.dot(v2)
	var d11 := v1.dot(v1)
	var d12 := v1.dot(v2)
	var den := d00 * d11 - d01 * d01
	if absf(den) < 1e-12:
		return NAN
	var u := (d11 * d02 - d01 * d12) / den
	var w := (d00 * d12 - d01 * d02) / den
	if u < -0.0001 or w < -0.0001 or u + w > 1.0001:
		return NAN
	var nrm := (b - a).cross(c - a)
	if absf(nrm.y) < 1e-12:
		return NAN
	return a.y - (nrm.x * (sx - a.x) + nrm.z * (sz - a.z)) / nrm.y


# Parametric SADDLE at the mount's seat point (spec {"saddle": false} disables): a low flattened
# leather pad + rear lip + two strap/stirrup hints, ~0.5m — the rider's visual anchor. Generators
# ship mounts BARE-BACKED (playbook rule), so the engine owns the tack. Attached to the BODY (not
# _visual): it stays level with the parked rider, exactly like the MountMarker. Purely cosmetic —
# built after the collider AABB is measured, so it never fattens the box.
func _build_saddle(at: Vector3) -> void:
	var leather := GSurf.surface({"color": [SADDLE_COLOR.r, SADDLE_COLOR.g, SADDLE_COLOR.b], "rough": 0.85, "metal": 0.0, "bump": 0.0, "tile": 3.0})
	var root := Node3D.new()
	root.name = "Saddle"
	root.position = at
	add_child(root)
	_saddle = root
	# the pad IS the seat's lift: its base on the back drawn under it, its top where the rider's drawn seat rests (GPose.SADDLE_T,
	# the one number the seat and the saddle both read — two literals let a thicker pad bury the rider in it)
	var pad := GShapes.box(Vector3(0.42, GPose.SADDLE_T, 0.52))
	GShapes.set_material(pad, leather)
	pad.position = Vector3(0.0, GPose.SADDLE_T * 0.5, 0.0)
	root.add_child(pad)
	var cantle := GShapes.box(Vector3(0.34, 0.09, 0.08))
	GShapes.set_material(cantle, leather)
	cantle.position = Vector3(0.0, 0.09, -0.24)   # low rear lip
	root.add_child(cantle)
	for sx in [-1.0, 1.0]:
		var strap := GShapes.box(Vector3(0.03, 0.30, 0.06))
		GShapes.set_material(strap, leather)
		strap.position = Vector3(0.24 * sx, -0.15, 0.05)
		root.add_child(strap)
		var stirrup := GShapes.box(Vector3(0.05, 0.05, 0.14))
		GShapes.set_material(stirrup, leather)
		stirrup.position = Vector3(0.24 * sx, -0.31, 0.05)
		root.add_child(stirrup)


# ---------------- parametric bodies (VEHICLE profiles, spec "model" omitted) ----------------

# The articulated default car (Wave 2, unchanged): GShapes boxes/cylinders + GSurf triplanar
# materials. Grounded (base y=0), forward +Z (Wave-1 convention), so the LEFT/driver side is +X —
# which is exactly where Wave-1's exit_side (+basis.x) already steps the driver out. Cabin is a
# composed CAVITY (floor/walls/dash/roof panels, open where the door is) with two seats, a dash,
# a steering wheel, and a "SeatMarker" Node3D on the cushion top. The driver-side DOOR LEAF
# hinges at its FRONT edge ("DoorPivot"), carries its own StaticBody3D collider (collision-
# excepted from this body, disabled while open or driving), and is NOT in the "gogi_door" group —
# building-door consumers must never discover a car door. Returns the composed local AABB
# (door closed).
func _build_parametric(spec: Dictionary) -> AABB:
	var body_col := _spec_color(spec, BODY_COLOR_DEFAULT)
	var paint := GSurf.surface({"color": [body_col.r, body_col.g, body_col.b], "rough": 0.35, "metal": 0.25, "bump": 0.0, "tile": 6.0})
	var trim := GSurf.surface({"color": [0.15, 0.15, 0.17], "rough": 0.6, "metal": 0.35, "bump": 0.0, "tile": 6.0})
	var tire := GSurf.surface({"color": [0.07, 0.07, 0.08], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 4.0})
	var cloth := GSurf.surface({"color": [0.24, 0.20, 0.17], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 3.0})
	var glass := _glass_mat()
	var root := Node3D.new()
	root.name = "CarBody"
	add_child(root)
	_visual = root
	# shell — hood/trunk/bumpers around an open cabin (z -1.225 .. 0.95, belt line y 1.05)
	_part(root, Vector3(1.5, 0.30, 0.18), Vector3(0.0, 0.45, 1.93), trim)     # front bumper
	_part(root, Vector3(1.5, 0.30, 0.18), Vector3(0.0, 0.45, -1.93), trim)    # rear bumper
	_part(root, Vector3(1.5, 0.42, 1.0), Vector3(0.0, 0.55, 1.45), paint)     # hood
	_part(root, Vector3(1.5, 0.55, 0.75), Vector3(0.0, 0.62, -1.60), paint)   # trunk
	# SUNKEN CABIN. The floor/cushion used to sit at 0.35/0.50, leaving 0.675 m between the cushion
	# top and the roof underside (1.255). A seated 1.65 m humanoid needs ~0.79 m from hips to the top
	# of its head — so NOBODY fit, and every driver either clipped through the roof or got hidden by
	# the fallback, which made the visible-driver feature dead code on the most common vehicle in the
	# library. Dropping the floor 0.13 m buys 0.825 m of headroom and changes no exterior line: the
	# roof, glass, pillars, bumpers, hood, trunk and wheels are all exactly where they were.
	_part(root, Vector3(1.5, 0.10, 2.4), Vector3(0.0, 0.22, -0.15), trim)     # cabin floor
	# Walls run from the new floor to the belt line — extended DOWN by the same 0.13, not moved, or a
	# gap opens along the sill and you can see through the car's side into the cabin.
	_part(root, Vector3(0.07, 0.78, 2.1), Vector3(-0.765, 0.66, -0.15), paint)    # right wall (solid)
	_part(root, Vector3(0.07, 0.78, 0.48), Vector3(0.765, 0.66, -0.99), paint)    # left wall behind the door
	_part(root, Vector3(0.07, 0.78, 0.40), Vector3(0.765, 0.66, 0.75), paint)     # left wall ahead of the door
	for sx in [-1.0, 1.0]:   # window-band pillars: belt line (1.05) up to the raised roof (1.40)
		_part(root, Vector3(0.07, 0.35, 0.14), Vector3(0.765 * sx, 1.225, -1.15), trim)
		_part(root, Vector3(0.07, 0.35, 0.14), Vector3(0.765 * sx, 1.225, 0.88), trim)
	# Roof raised 0.145 to 1.445 (underside CAR_ROOF_Y = 1.40). With the sunken cushion at 0.45 that
	# is 0.95 m of headroom — a real sedan's figure, against the ~0.86 m sitting height of a 1.65 m
	# humanoid (sitting height is ~0.52x stature; the 0.79 m this was first sized to was simply
	# wrong, and SCALETEST failed it). Overall height 1.49 m on a 4 m body is a normal sedan.
	_part(root, Vector3(1.6, 0.09, 2.2), Vector3(0.0, 1.445, -0.15), paint)   # roof
	# Glass follows the roof: same sill, same rake, re-cut so the top edge still meets the roofline.
	var shield := _part(root, Vector3(1.44, 0.762, 0.05), Vector3(0.0, 1.064, 1.02), glass)
	shield.name = "Windshield"
	shield.rotation.x = deg_to_rad(-28.0)   # raked back toward the roof
	var rear_glass := _part(root, Vector3(1.44, 0.689, 0.05), Vector3(0.0, 1.102, -1.24), glass)
	rear_glass.rotation.x = deg_to_rad(30.0)
	# interior — dash, steering wheel, two seats, the SeatMarker
	# Dash + wheel drop with the floor, or the driver's knees sit inside the dash block.
	_part(root, Vector3(1.40, 0.22, 0.35), Vector3(0.0, 0.73, 0.72), trim)    # dash block
	var wheel := GShapes.cylinder(0.17, 0.17, 0.05, 20)
	GShapes.set_material(wheel, tire)
	wheel.position = Vector3(0.38, 0.82, 0.50)
	wheel.rotation.x = deg_to_rad(65.0)   # tilted toward the driver
	root.add_child(wheel)
	for sx in [-1.0, 1.0]:
		# 0.18 thick, centred 0.36: spans the floor top (0.27) to SEAT_TOP (0.45) exactly. Thickened
		# rather than re-centred so it rests ON the sunken floor — at the old 0.16 it hovered 2 cm
		# above it, which reads as a floating seat from the open door.
		_part(root, Vector3(0.60, 0.18, 0.55), Vector3(0.38 * sx, 0.36, -0.15), cloth)          # cushion (top = SEAT_TOP)
		var back := _part(root, Vector3(0.60, 0.55, 0.12), Vector3(0.38 * sx, 0.69, -0.47), cloth)
		back.rotation.x = deg_to_rad(-8.0)                                                       # recline
	_seat_marker = Node3D.new()
	_seat_marker.name = "SeatMarker"
	_seat_marker.position = Vector3(0.38, SEAT_TOP, -0.15)   # driver cushion top — hips rest here
	_cabin_headroom = CAR_ROOF_Y - SEAT_TOP                  # the sedan HAS a roof: 0.805 m of column
	root.add_child(_seat_marker)
	# lights (emissive fills, NOT OmniLights — no light budget spent on cars)
	var head_mat := GSurf.emissive(Color(1.0, 0.95, 0.75), 1.4)
	var tail_mat := GSurf.emissive(Color(0.9, 0.10, 0.08), 1.4)
	for sx in [-1.0, 1.0]:
		_part(root, Vector3(0.28, 0.12, 0.06), Vector3(0.48 * sx, 0.62, 1.96), head_mat)
		_part(root, Vector3(0.25, 0.10, 0.06), Vector3(0.52 * sx, 0.72, -1.99), tail_mat)
	# wheels — cylinders lying on their sides (rotation.z=PI/2 -> local +Y is the axle). The 2 FRONT
	# wheels (z = +1.25) ride under a "WheelPivot" Node3D that carries the steer yaw; all 4 are kept
	# in _wheels and spun about their axle in the physics tick (2.2). WHEEL_RADIUS mirrors the 0.32 r.
	_wheels = []
	_steer_pivots = []
	_wheel_axle = Vector3.UP
	for wp in [Vector3(0.78, 0.32, 1.25), Vector3(-0.78, 0.32, 1.25), Vector3(0.78, 0.32, -1.25), Vector3(-0.78, 0.32, -1.25)]:
		var wh := GShapes.cylinder(WHEEL_RADIUS, WHEEL_RADIUS, 0.24, 18)
		GShapes.set_material(wh, tire)
		wh.rotation.z = PI * 0.5
		if wp.z > 0.0:   # front axle -> steerable pivot; the wheel sits at pivot-local origin
			var pivot := Node3D.new()
			pivot.name = "WheelPivot"
			pivot.position = wp
			root.add_child(pivot)
			wh.position = Vector3.ZERO   # overwrite cylinder()'s base lift; the pivot holds the spot
			pivot.add_child(wh)
			_steer_pivots.append(pivot)
		else:
			wh.position = wp
			root.add_child(wh)
		_wheels.append(wh)
	# the driver-side DOOR — hinge pivot at the opening's FRONT edge, leaf swings outward (+X)
	_door_pivot = Node3D.new()
	_door_pivot.name = "DoorPivot"
	# Hinges at the sill, which moved down with the floor — the leaf spans the same 0.27..1.05 as the
	# walls it sits flush with, so an open door still fills its opening.
	_door_pivot.position = Vector3(0.795, 0.27, 0.55)
	root.add_child(_door_pivot)
	var leaf := Node3D.new()
	leaf.name = "DoorLeaf"
	_door_pivot.add_child(leaf)
	var leaf_mi := GShapes.box(Vector3(0.07, 0.78, 1.30))
	GShapes.set_material(leaf_mi, paint)
	leaf_mi.position = Vector3(0.0, 0.39, -0.65)
	leaf.add_child(leaf_mi)
	var handle := GShapes.box(Vector3(0.04, 0.05, 0.16))
	GShapes.set_material(handle, trim)
	handle.position = Vector3(0.06, 0.63, -1.05)
	leaf.add_child(handle)
	_door_body = StaticBody3D.new()
	_door_body.name = "DoorBody"
	_door_body.collision_layer = 1
	var dcs := CollisionShape3D.new()
	var dbs := BoxShape3D.new()
	dbs.size = Vector3(0.07, 0.78, 1.30)     # matches the leaf mesh above — collider and paint agree
	dcs.shape = dbs
	dcs.position = Vector3(0.0, 0.39, -0.65)
	_door_body.add_child(dcs)
	leaf.add_child(_door_body)
	_door_shape = dcs
	add_collision_exception_with(_door_body)   # the car must never move_and_slide against its own door
	_board_local = Vector3(1.45, 0.0, -0.15)   # on the ground just outside the open door
	return GPose.drawn_aabb(root)


# The parametric TANK: hull box + sloped glacis (ramp wedge) + dark track skirts low on the
# sides + a rotating-look turret group (ring cylinder + box) + a thin long barrel forward +Z.
# The turret is grouped under one "Turret" Node3D so a later wave can aim it — v1 is COSMETIC
# (no aiming). No door, no SeatMarker: tank boarding is the Wave-1 swap-in (driver hidden);
# hatch choreography is OUT OF SCOPE v1. Grounded (base y=0), forward +Z.
func _build_parametric_tank(spec: Dictionary) -> AABB:
	var body_col := _spec_color(spec, TANK_COLOR_DEFAULT)
	var paint := GSurf.surface({"color": [body_col.r, body_col.g, body_col.b], "rough": 0.7, "metal": 0.3, "bump": 0.0, "tile": 5.0})
	var track := GSurf.surface({"color": [0.09, 0.09, 0.10], "rough": 0.95, "metal": 0.1, "bump": 0.0, "tile": 4.0})
	var root := Node3D.new()
	root.name = "TankBody"
	add_child(root)
	_visual = root
	# track skirts — dark boxes LOW on the sides (they read as the running gear)
	for sx in [-1.0, 1.0]:
		_part(root, Vector3(0.60, 0.55, 5.0), Vector3(0.95 * sx, 0.35, 0.0), track)
	# hull slab between/above the tracks (top at y 1.15)
	_part(root, Vector3(1.9, 0.60, 4.4), Vector3(0.0, 0.85, -0.20), paint)
	# sloped GLACIS: GShapes.ramp rises along +X; rotation.y = +90° maps +X -> -Z (basis rotation:
	# x' = (cos90, 0, -sin90) = -Z), so the slope rises toward -Z = up toward the hull top, with
	# the low edge at +Z = the nose. Width (pre-rotation Z) becomes the X span.
	var glacis := GShapes.ramp(0.9, 0.55, 1.9)
	GShapes.set_material(glacis, paint)
	glacis.position = Vector3(0.0, 0.875, 2.30)   # centre: y 0.6..1.15, z 1.85..2.75
	glacis.rotation.y = PI * 0.5
	root.add_child(glacis)
	# rear plate
	_part(root, Vector3(1.9, 0.35, 0.30), Vector3(0.0, 0.70, -2.35), paint)
	# TURRET group — ring cylinder + turret box + barrel, one pivot for future aiming
	var turret := Node3D.new()
	turret.name = "Turret"
	turret.position = Vector3(0.0, 1.15, -0.30)   # sits on the hull top
	root.add_child(turret)
	var ring := GShapes.cylinder(0.85, 0.75, 0.22, 20)
	GShapes.set_material(ring, paint)
	ring.position = Vector3(0.0, 0.11, 0.0)   # centre-positioned (overwrites base-lift; _part idiom)
	turret.add_child(ring)
	var tbox := GShapes.box(Vector3(1.35, 0.50, 1.70))
	GShapes.set_material(tbox, paint)
	tbox.position = Vector3(0.0, 0.47, -0.05)
	turret.add_child(tbox)
	# barrel — thin long cylinder FORWARD +Z: rotation.x = +90° maps the cylinder's +Y axis to +Z
	# ((0,1,0) -> (0, cos90, sin90) = (0,0,1)), so its length lies along the heading.
	var barrel := GShapes.cylinder(0.07, 0.06, 2.3, 12)
	GShapes.set_material(barrel, track)
	barrel.position = Vector3(0.0, 0.42, 1.85)   # turret-local: from the turret face out past the nose
	barrel.rotation.x = PI * 0.5
	turret.add_child(barrel)
	return GPose.drawn_aabb(root)


# The parametric BOAT: box hull with a V-keel wedge + raked bow ramp + deck + small fore cabin +
# raked windshield + open cockpit seat with a "SeatMarker". No door — boarding is the step-in
# choreography. Grounded at base y=0 (the WATER ride puts the waterline partway up the keel).
func _build_parametric_boat(spec: Dictionary) -> AABB:
	var body_col := _spec_color(spec, BOAT_COLOR_DEFAULT)
	var paint := GSurf.surface({"color": [body_col.r, body_col.g, body_col.b], "rough": 0.3, "metal": 0.1, "bump": 0.0, "tile": 5.0})
	var deck_mat := GSurf.surface({"color": [0.55, 0.42, 0.28], "rough": 0.8, "metal": 0.0, "bump": 0.0, "tile": 4.0})
	var trim := GSurf.surface({"color": [0.15, 0.15, 0.17], "rough": 0.6, "metal": 0.35, "bump": 0.0, "tile": 6.0})
	var cloth := GSurf.surface({"color": [0.24, 0.20, 0.17], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 3.0})
	var glass := _glass_mat()
	var root := Node3D.new()
	root.name = "BoatBody"
	add_child(root)
	_visual = root
	# hull slab (freeboard) + V-KEEL: a wedge flipped upside down (rotation.z = PI turns the
	# gable peak downward), so the ridge line runs along Z at y=0 — the keel.
	_part(root, Vector3(1.9, 0.65, 4.4), Vector3(0.0, 0.50, -0.30), paint)
	var keel := GShapes.wedge(Vector3(1.9, 0.35, 4.4))
	GShapes.set_material(keel, paint)
	keel.position = Vector3(0.0, 0.18, -0.30)   # centre: peak (keel) at ~y 0, merging into the hull
	keel.rotation.z = PI
	root.add_child(keel)
	# raked BOW: same ramp-rotation trace as the tank glacis (rotation.y = +90° -> rises toward -Z),
	# so the low edge points forward at +Z — the nose — and the top meets the deck.
	var bow := GShapes.ramp(1.3, 0.60, 1.9)
	GShapes.set_material(bow, paint)
	bow.position = Vector3(0.0, 0.55, 2.20)
	bow.rotation.y = PI * 0.5
	root.add_child(bow)
	# deck + gunwale rails
	_part(root, Vector3(1.7, 0.10, 4.2), Vector3(0.0, 0.88, -0.35), deck_mat)
	for sx in [-1.0, 1.0]:
		_part(root, Vector3(0.08, 0.25, 4.2), Vector3(0.88 * sx, 1.00, -0.35), paint)
	# small FORE cabin (cuddy) + windshield raked back toward the cockpit
	_part(root, Vector3(1.5, 0.70, 1.5), Vector3(0.0, 1.25, 1.00), paint)
	var shield := _part(root, Vector3(1.3, 0.50, 0.05), Vector3(0.0, 1.62, 0.15), glass)
	shield.name = "Windshield"
	shield.rotation.x = deg_to_rad(-22.0)
	# helm console + cockpit seat + SeatMarker
	_part(root, Vector3(0.9, 0.45, 0.35), Vector3(0.0, 1.10, 0.28), trim)
	_part(root, Vector3(0.60, 0.16, 0.55), Vector3(0.0, 1.00, -0.60), cloth)          # cushion
	var back := _part(root, Vector3(0.60, 0.50, 0.12), Vector3(0.0, 1.30, -0.92), cloth)
	back.rotation.x = deg_to_rad(-8.0)
	_seat_marker = Node3D.new()
	_seat_marker.name = "SeatMarker"
	_seat_marker.position = Vector3(0.0, 1.08, -0.60)   # cushion top — hips rest here
	root.add_child(_seat_marker)
	_board_local = Vector3(1.35, 0.0, -0.60)   # step in beside the cockpit
	return GPose.drawn_aabb(root)


# The parametric PLANE: tapered cylinder fuselage (capsule-ish, fat nose / thin tail after the
# +90° X rotation maps the cylinder's +Y to +Z), thin wide straight wings, tailplane + fin, a
# cosmetic "PropDisc" nose spinner (spins while driving), fixed landing gear, and an open
# cockpit seat with a "SeatMarker". No door — step-in boarding. Grounded (wheels at y=0).
func _build_parametric_plane(spec: Dictionary) -> AABB:
	var body_col := _spec_color(spec, PLANE_COLOR_DEFAULT)
	var paint := GSurf.surface({"color": [body_col.r, body_col.g, body_col.b], "rough": 0.35, "metal": 0.45, "bump": 0.0, "tile": 5.0})
	var trim := GSurf.surface({"color": [0.15, 0.15, 0.17], "rough": 0.6, "metal": 0.35, "bump": 0.0, "tile": 6.0})
	var tire := GSurf.surface({"color": [0.07, 0.07, 0.08], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 4.0})
	var cloth := GSurf.surface({"color": [0.24, 0.20, 0.17], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 3.0})
	var glass := _glass_mat()
	var root := Node3D.new()
	root.name = "PlaneBody"
	add_child(root)
	_visual = root
	# fuselage — cylinder axis +Y; rotation.x = +90° maps +Y -> +Z, so top_r (0.5) becomes the
	# NOSE radius at +Z and bottom_r (0.25) the tapering tail at -Z.
	var fus := GShapes.cylinder(0.25, 0.50, 6.2, 16)
	GShapes.set_material(fus, paint)
	fus.position = Vector3(0.0, 1.10, -0.10)   # centre: z -3.2 .. 3.0
	fus.rotation.x = PI * 0.5
	root.add_child(fus)
	# cosmetic PROP DISC on the nose (same axis trace as the fuselage) — spun in _physics_process
	# about its LOCAL +Y (the cylinder axis, = world +Z after the rotation).
	_prop = GShapes.cylinder(0.95, 0.95, 0.06, 24)
	GShapes.set_material(_prop, trim)
	_prop.name = "PropDisc"
	_prop.position = Vector3(0.0, 1.10, 3.10)
	_prop.rotation.x = PI * 0.5
	root.add_child(_prop)
	# straight wings + tailplane + fin (thin boxes)
	_part(root, Vector3(7.4, 0.12, 1.5), Vector3(0.0, 1.28, 0.50), paint)     # main wings
	_part(root, Vector3(2.8, 0.10, 0.9), Vector3(0.0, 1.35, -2.90), paint)    # tailplane
	_part(root, Vector3(0.12, 1.05, 1.0), Vector3(0.0, 1.90, -3.00), paint)   # vertical fin
	# open cockpit — windshield, seat, SeatMarker
	var shield := _part(root, Vector3(0.9, 0.40, 0.05), Vector3(0.0, 1.85, 1.35), glass)
	shield.name = "Windshield"
	shield.rotation.x = deg_to_rad(-30.0)
	_part(root, Vector3(0.55, 0.14, 0.50), Vector3(0.0, 1.55, 0.90), cloth)   # cushion
	_part(root, Vector3(0.55, 0.45, 0.10), Vector3(0.0, 1.80, 0.60), cloth)   # seat back
	_seat_marker = Node3D.new()
	_seat_marker.name = "SeatMarker"
	_seat_marker.position = Vector3(0.0, 1.62, 0.90)
	root.add_child(_seat_marker)
	# fixed landing gear — two main struts + wheels under the wing, one tail wheel. Wheel
	# cylinders lie on their sides (rotation.z = 90° -> local +Y is the axle), bottoms at y=0.
	# Registered in _wheels so they roll while taxiing (2.2); no steer pivots (rudder-steered plane).
	_wheels = []
	_steer_pivots = []
	_wheel_axle = Vector3.UP
	for sx in [-1.0, 1.0]:
		_part(root, Vector3(0.08, 0.50, 0.08), Vector3(0.90 * sx, 0.42, 0.90), trim)
		var wh := GShapes.cylinder(0.22, 0.22, 0.15, 14)
		GShapes.set_material(wh, tire)
		wh.position = Vector3(0.90 * sx, 0.22, 0.90)
		wh.rotation.z = PI * 0.5
		root.add_child(wh)
		_wheels.append(wh)
	var tw := GShapes.cylinder(0.14, 0.14, 0.12, 12)
	GShapes.set_material(tw, tire)
	tw.position = Vector3(0.0, 0.15, -2.90)
	tw.rotation.z = PI * 0.5
	root.add_child(tw)
	_wheels.append(tw)
	_board_local = Vector3(1.30, 0.0, 0.90)   # step in beside the cockpit, inside the wing span
	return GPose.drawn_aabb(root)


# One placed box part: GShapes.box + GSurf material, positioned by its CENTRE (BoxMesh is
# origin-centred; overwriting .position discards box()'s base-at-y=0 lift on purpose).
func _part(parent: Node3D, size: Vector3, center: Vector3, mat: Material) -> MeshInstance3D:
	var mi := GShapes.box(size)
	mi.position = center
	GShapes.set_material(mi, mat)
	parent.add_child(mi)
	return mi


func _spec_color(spec: Dictionary, fallback: Color) -> Color:
	var c = spec.get("color", null)
	if c is Array and (c as Array).size() >= 3:
		return Color(float(c[0]), float(c[1]), float(c[2]))
	return fallback


func _glass_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.55, 0.75, 0.85, 0.32)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.05
	m.metallic = 0.4
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


# ---------------- per-tick ----------------

# A persistent wild MOUNT renders at ANY range (no streaming cull, unlike the cell-streamed populate
# crowd), so a far grazing animal shows as a speck against the sky/horizon once the player is up in a
# plane ("animals in the sky"). Cull TIGHT while the player flies so far mounts can't dot the horizon;
# stay GENEROUS on the ground so exploring still shows wildlife around you. It reappears as you near it
# (taming still works) and the crowd right around you is unchanged either way.
const MOUNT_CULL_GROUND := 150.0            # on foot / ground vehicle: show wildlife around you
const MOUNT_AIR_MAX := 75.0                 # while flying: never show a mount beyond this
const MOUNT_AIR_MIN_DROP := 0.40            # ...nor one less than ~22° BELOW the player's horizon (that band = "in the sky")
var _cull_t := 0.0                          # throttle for the cull check (visibility is cheap)


func _physics_process(delta: float) -> void:
	_time += delta
	if _state == S_DRIVING:
		_drive(delta)
		_sync_hull()
		if _prop != null:
			_prop.rotate_object_local(Vector3.UP, PROP_SPIN * delta)   # cosmetic — local +Y = the disc axis
		_update_gait()
		_update_label()
		_update_mount_cull(delta)
		if _feet != null:
			_feet.want = _feet_wanted()
			_feet.ramp(delta)
			_perf_t += delta
			if _perf_t >= PERF_EVERY:
				_perf_line()
		return
	# PARKED: a world can leave several rides standing around (a car, a plane, a couple of boats is
	# typical) and EVERY one of them used to run the full per-frame body below while
	# nobody was aboard — measured as 5 of the 11 nodes ticking each frame, on a single-threaded web
	# build where script time is the framerate ceiling. Nothing here is time-critical when parked: the
	# ground snap only matters as terrain streams in under the vehicle, and the label/gait/cull are
	# cosmetic. Run them ~10x/second instead of ~60x. Driving is untouched — it takes the branch above
	# at full rate, so handling and feel are identical.
	# A NETWORK peer is riding this. netsync places it every frame from their transform, so the
	# parked path below — whose ground snap would drag it back down to the terrain — must not run.
	# Same reasoning as peer_body's mask-0 AnimatableBody3D: network-driven, never world-pushed.
	if _remote_rider != null and is_instance_valid(_remote_rider):
		_remote_gait(delta)
		if _feet != null:
			_feet.want = _feet_wanted()
			_feet.ramp(delta)
			_hull_follow()
		return
	_park_t += delta
	if _park_t < 0.1:
		return
	if _feet != null:
		var was := _feet.want
		_feet.want = _feet_wanted()
		if _feet.want != was:
			# ...and it rests again on what it now stands on (_keel_now): settled on what it draws without its legs while they
			# stood, then left by the player, nothing re-seated it on its hooves — a horse's went 0.07-0.12 m into a crest, a
			# cow's 0.09-0.16, ridden there and dismounted 0.04-0.13 (step 5c's review)
			_settled_key = Vector4(INF, INF, INF, INF)
		_feet.ramp(_park_t)
	_snap_to_ground(_park_t)   # pass the ACCUMULATED delta so the snap moves the same distance per second
	_sync_hull()
	_hull_follow()
	_update_gait()
	_update_label()
	_update_mount_cull(_park_t)
	if _follow.is_empty() and visible:
		_follow_seat()   # an empty saddle rides its mount's idle too, at the parked rate (an idle's back moves slowly)
	_park_t = 0.0


## ITS FEET STAND ON THE GROUND (GFeet.want) — ridden (by the player or a peer), or parked within FEET_NEAR of the player on
## ground the plane it stands on leaves by FEET_UNEVEN under a foot — and never in the air or on the water (_wheel_ground). Every
## parked mount solving its legs would cost what a ridden one does; one on flat ground or a plain slope has nothing to solve.
func _feet_wanted() -> bool:
	if _feet == null or not _wheel_ground():
		return false
	if driving or (_remote_rider != null and is_instance_valid(_remote_rider)):
		return true
	if player_ref == null or not is_instance_valid(player_ref) or global_position.distance_to(player_ref.global_position) > FEET_NEAR:
		return false
	var b := global_transform.basis
	var pose := Vector3(global_position.y, 0.0, 0.0)
	var lim := tan(GROUND_TILT_MAX)
	var up := (_tilt * Vector3.UP)
	pose.y = clampf(-up.x / maxf(up.y, 1e-3), -lim, lim)
	pose.z = clampf(-up.z / maxf(up.y, 1e-3), -lim, lim)
	for f in _feet_xz:
		var w := global_position + b * Vector3(f.x, 0.0, f.y)
		if absf(_ground_h_at(w.x, w.z) + TYRE_GAP - (pose.x + _contact_y + pose.y * f.x + pose.z * f.y)) > FEET_UNEVEN:
			return true
	return false


## WHAT ITS FEET COST, for the phone's own test (the user reads it on a device; nothing gates on it): every PERF_EVERY s ridden
## and at the dismount — `GOGI_PERF feet <name> <us a frame> <frames> <legs>`, a frame's whole work (GFeet: prepare and solve).
## 48-49 us a frame on the desktop for the horse, 43-45 for the cow, 25 for the default dragon (the drive rig's footing (f12));
## herds and enemies get feet once a phone's figure is known.
func _perf_line() -> void:
	_perf_t = 0.0
	if _feet == null or _feet.n == 0:
		return
	print("GOGI_PERF feet %s %.1f %d %d" % [display_name.replace(" ", "_"), float(_feet.us) / float(_feet.n), _feet.n, _feet.legs.size()])
	_feet.us = 0
	_feet.n = 0


# Hide a distant wild mount so it can't dot the sky/horizon while the player flies. Only mounts
# (creatures) are culled — cars/planes/boats stay visible so a parked airfield reads normally. A
# RIDDEN mount is never hidden. Distance is the cheap hull-xz measure; the check runs ~4x/second.
func _update_mount_cull(delta: float) -> void:
	if not _is_mount or driving:
		if not visible:
			visible = true
		return
	if player_ref == null or not is_instance_valid(player_ref):
		return
	_cull_t -= delta
	if _cull_t > 0.0:
		return
	_cull_t = 0.25
	var pg := player_ref.global_position
	var palt := pg.y - (terrain.height(pg.x, pg.z) if terrain != null else 0.0)
	var horiz := _hull_xz_distance(pg)
	if palt <= 5.0:
		# on the ground / ground vehicle: generous radius so exploring shows wildlife around you
		visible = horiz <= MOUNT_CULL_GROUND
		return
	# AIRBORNE: show a mount ONLY when it sits well BELOW the player's horizon (inside the ground-view
	# cone) and is close — never one near/at the horizon line, which is exactly what reads as an "animal
	# in the sky". drop = how far the mount is below the player; the ratio is its angle under the horizon.
	var drop := pg.y - global_position.y
	visible = horiz <= MOUNT_AIR_MAX and drop >= horiz * MOUNT_AIR_MIN_DROP


# Integrate one drive tick from the shared input vector main.gd feeds via drive_input().
func _drive(delta: float) -> void:
	var p: Dictionary = PROFILES[profile]
	if _airborne:
		_drive_air(delta)
	else:
		_drive_ground(delta, p)
	_update_wheels(delta)       # roll/steer parametric or modeled wheels (2.2)
	_update_ride_motion(delta)  # rider bob + body rock while a mount walks (2.4)
	# keep the driver ATTACHED: chunk streaming (_player_cell) and quest reach_area notifications
	# all read player.global_position, so parking the player on the boardable keeps the whole
	# ring/quest pipeline fed while driving. A SEATED/RIDING driver rides its marker (visible);
	# the Wave-1 hidden fallback rides the body origin — identical streaming semantics either way.
	_track_driver()


# Ground gait — cars/tanks/boats/taxiing planes/walking mounts. Boats replace the terrain target
# with the water level inside _rest_y (via _snap_to_ground); flyers hand off to _drive_air once
# past takeoff speed with the throttle held.
## VERTICAL VELOCITY FROM THE GRADIENT — how a vehicle gets up a hill.
##
## `velocity.y` was hard-zeroed here and the height corrected AFTERWARDS by _snap_to_ground's lerp.
## That ordering is the whole bug: move_and_slide runs first, with the hull still at the height it
## had at the bottom of the rise, so its box collider drives straight into the slope face and the
## solver reports a wall. The vehicle stops, and nothing about engine power changes it — accel,
## max_speed and brake are all irrelevant when the blocker is collision rather than torque.
## Measured on a 30-57% switchback: stalled on the first steep leg, every attempt, in a truck whose
## profile says 12 m/s.
##
## Sampling the ground one step ahead and putting that rise into the velocity means the hull climbs
## and advances in the SAME move. _snap_to_ground still runs after, and now only has to settle the
## last few centimetres instead of fighting a metre of error per frame.
##
## BOATS AND TAXIING FLYERS ONLY since the wheeled rewrite (_wheel_step). Both sides of `rise` are a
## single point for them, so it is consistent there. For the wheeled bodies it was not: _ground_h()
## was the HIGHEST hull corner, so "ahead of the centre minus the highest corner" read as a drop on
## every grade and pushed the hull down at the full 14 m/s cap each frame.
func _climb_rate(delta: float) -> float:
	if _airborne or delta <= 0.0:
		return 0.0
	var step := Vector3(velocity.x, 0.0, velocity.z) * delta
	if step.length_squared() < 1e-8:
		return 0.0
	var ahead := global_position + step
	var rise := _ground_h_at(ahead.x, ahead.z) - _ground_h()
	return clampf(rise / delta, -CLIMB_RATE_MAX, CLIMB_RATE_MAX)


func _drive_ground(delta: float, p: Dictionary) -> void:
	var max_speed := float(p["max_speed"])
	# POINT-AND-GO (the on-screen joystick, via drive_input_world): turn the body TOWARD the commanded
	# heading at a snappy, SPEED-INDEPENDENT rate, then drive along the nose. The legacy path below
	# scales steering by speed, so a car/mount had almost no turn authority at low speed and felt
	# "locked into a direction" (the #1 driving complaint). _input.x here is the signed heading error
	# from drive_input_world; driving it toward zero points the body where the stick points, at any speed.
	if _world_drive:
		var wtarget := -_input.y * max_speed
		var wrate := float(p["accel"]) if absf(wtarget) > absf(_speed) else float(p["brake"])
		_speed = move_toward(_speed, wtarget, wrate * delta)
		var wturn := float(p["turn_rate"]) * (1.0 if bool(p.get("steer_fixed", false)) else 1.7)
		rotation.y += -_input.x * wturn * delta
		_move_on_ground(delta)
		if bool(p.get("fly", false)) and _speed > float(p.get("takeoff", 9.0)) and -_input.y > 0.4:
			_take_off()
		return
	var target := -_input.y * max_speed   # screen-up / W = forward (same sign as _keyboard_vec)
	var rate := float(p["accel"]) if absf(target) > absf(_speed) else float(p["brake"])
	_speed = move_toward(_speed, target, rate * delta)
	# steering: scaled by speed (no pirouette when parked, flips in reverse — like a real car)
	# EXCEPT steer_fixed profiles (tank): tracks TURN IN PLACE, full authority at zero speed.
	# steer_floor (boat/plane, 2.3): keep a minimum turn authority while spooling up so the stick
	# answers below top speed — the magnitude is floored, the reverse sign flip preserved.
	var sf := 1.0
	if not bool(p.get("steer_fixed", false)):
		var frac := clampf(_speed / max_speed, -1.0, 1.0)
		var mag := maxf(absf(frac), float(p.get("steer_floor", 0.0)))
		sf = mag if _speed >= 0.0 else -mag
	rotation.y += -_input.x * float(p["turn_rate"]) * sf * delta
	# forward = +basis.z: library/Meshy models FACE +Z in this stack (TrafficCar's atan2(dir.x,
	# dir.z) and the player's look_at(pos - dir) both point +Z along the heading).
	_move_on_ground(delta)
	# TAKEOFF (plane + dragon): past takeoff speed with the throttle still held, pitch up and fly.
	# The initial +10° pitch clears the GROUNDED_H band before the landing check can re-trigger
	# (landing requires DESCENDING: _pitch <= 0).
	if bool(p.get("fly", false)) and _speed > float(p.get("takeoff", 9.0)) and -_input.y > 0.4:
		_take_off()


# One ground tick along the nose. Wheeled bodies rest on the fitted ground (_wheel_step); a boat ON
# water and a taxiing flyer rest on one point and keep the climb-rate + lerp path, which is consistent
# for them.
func _move_on_ground(delta: float) -> void:
	velocity = global_transform.basis.z * _speed
	if _wheel_ground():
		_wheel_step(delta)
		return
	velocity.y = _climb_rate(delta)
	move_and_slide()              # buildings/walls (layer 1) stop it; slides along them
	_snap_to_ground(delta)


# Anything that rests on the terrain on its wheels/feet: cars, trucks, tanks, walking mounts, a LANDED flyer — a
# taxiing plane, a dragon on its feet (decision 21) — and a boat in a world with no water (the car-on-terrain
# degrade). Not a boat on water, not a flyer in the air. On the flyer's old ground path (one point under its origin,
# its hull colliding with the slope) both real dragons stalled at x 11.1 after 6 s up a 17 deg grade, 616 hull-terrain
# contacts, and with its wings in its hull the default dragon could not land across an 8 deg slope (it skated 100 m on
# its hull) nor walk across an 11 deg one (1.1 m in 4 s, 5.6 m slid downhill) — mount-hulls review.
func _wheel_ground() -> bool:
	return not (_has_water and _water_rest) and not (_airborne and bool(PROFILES.get(profile, {}).get("fly", false)))


# TAKE-OFF: into the air, nose up — and the ground under it becomes something it can hit again, once it is out of it.
# On its feet a flyer ignores the terrain it stands on, as every wheeled body does (_wheel_step), and leans to it; in the
# air the hull meets the terrain, which is how it lands (_drive_air). In between it is LEAVING the ground (_leave_ground).
func _take_off() -> void:
	_airborne = true
	_pitch = deg_to_rad(10.0)
	_rock = 0.0
	_leaving = true
	_leave_ref = INF
	_leave_vy = 0.0
	_leave_f = 1.0
	_sync_hull()


## LEAVING THE GROUND. A flyer that takes off from a slope stands in it: its hull leans with the slope it walked on, and the
## same hull held level reaches into it uphill — the default dragon's wing 1.28 m into a 17 deg one. Handing the terrain
## back at the take-off tick with the lean dropped had move_and_slide push the whole body out of the hill in one tick:
## 1.28 m up and 0.65 m aside, the lean 17 -> 0 deg (the parametric plane 1.09 m; 0.56 m at 8 deg — behaviour review). So it
## keeps the terrain excepted, and the lean it stood with, climbing at least TAKEOFF_CLIMB (_drive_air), until its hull is
## clear of the ground both as it leans and level; then the terrain is solid to it again and the lean lays down at
## LEVEL_RATE (on a planar slope every lean between the slope's and level is clear once both are). And it climbs to the
## floor it flies over (GROUND_LIFT) from the TYRE_GAP it stood on, rather than being clamped up 0.08 m in a tick — on the
## flat too, where the rest is over at the first tick in the air.
func _leave_ground(delta: float) -> void:
	if not _terrain_ex.is_empty():
		var tn := get_tree().get_node_count_in_group("gogi_terrain")
		if tn != _ex_n:
			_ex_n = tn
			_except_terrain()   # a cell streamed in under it while it is still in the ground
		if _in_terrain(_tilt) or _in_terrain(Basis()):
			return
		_unexcept_terrain()
	var q := _tilt.get_rotation_quaternion()
	var a := q.get_angle()
	if a <= LEVEL_RATE * delta:
		_tilt = Basis()
		# ...and it is still leaving while the rise ahead holds its climb or its pace (_leave_hold): let go of the hold
		# mid-climb, and the climb it added stopped in a tick and it met the face it was rising past (0.11 m/tick)
		_leaving = global_position.y - _ground_h() < GROUND_LIFT or _leave_vy > 0.05 or _leave_f < 0.99
	else:
		_tilt = Basis(q.slerp(Quaternion.IDENTITY, LEVEL_RATE * delta / a))
	_hull_cs.transform = Transform3D(_tilt, Vector3.ZERO) * _hull_rest


## THE HILL AHEAD WHILE IT LEAVES. With the terrain excepted nothing else stops the hull (_leave_ground), so it is held out
## of the ground by measure: never deeper than the least its leaned hull has stood in since it took off (_leave_ref,
## _leave_depth). It looks LEAVE_LOOK ticks down the way it is going: the pace across the ground it can keep and still climb
## clear (at LAUNCH_VY_MAX) and the climb that pace needs, each eased in at LEAVE_DV a tick (no jolt) — on a face steeper
## than it can climb it slows before the face and rises up it, never into it. Held to TAKEOFF_CLIMB alone (2 m/s, its
## pitch at most 35 deg), both real dragons and the plane taking off up Kestrel Bay's 44 deg mountain flank went 0.55-2.17
## m into the hill, the terrain excepted for 100-230 ticks, and on a 17 deg slope with a 45 deg face 5.8 m ahead climbed 30 m
## of the face 2.1-2.2 m inside it (step 3's re-check).
func _leave_hold(v: Vector3, delta: float) -> Vector3:
	_leave_ref = minf(_leave_ref, maxf(_leave_depth(global_position), 0.0))
	var allow := _leave_ref + 0.005
	var vh := Vector3(v.x, 0.0, v.z)
	var vy_max := maxf(LAUNCH_VY_MAX, v.y)
	# the share of its way forward it can keep and still climb clear of everything down that way, at its best climb
	var f := 1.0
	if not _clear_ahead(vh, vy_max, allow, delta):
		var lo := 0.0
		var hi := 1.0
		for i in 6:
			var m := (lo + hi) * 0.5
			if _clear_ahead(vh * m, vy_max, allow, delta):
				lo = m
			else:
				hi = m
		f = lo
	_leave_f = move_toward(_leave_f, f, LEAVE_DV / maxf(vh.length(), 1.0))
	vh *= _leave_f
	# ...and the climb the way ahead needs at that pace, eased in
	var need := 0.0
	for k in [1, 2, 4, 8, LEAVE_LOOK]:
		var t := float(k) * delta
		need = maxf(need, (_leave_depth(global_position + (vh + Vector3.UP * v.y) * t) - allow) / t)
	_leave_vy = move_toward(_leave_vy, clampf(need, 0.0, vy_max - v.y), LEAVE_DV)
	var out := vh + Vector3.UP * (v.y + _leave_vy)
	# what the easing has not caught up with, this tick: the largest share of the way forward that sinks it no deeper
	if _leave_depth(global_position + out * delta) <= allow:
		return out
	var lo2 := 0.0
	var hi2 := 1.0
	for i in 8:
		var m2 := (lo2 + hi2) * 0.5
		if _leave_depth(global_position + Vector3(out.x * m2, out.y, out.z * m2) * delta) <= allow:
			lo2 = m2
		else:
			hi2 = m2
	return Vector3(out.x * lo2, out.y, out.z * lo2)


# Can it go `vh` across the ground and climb at `vy` and stay out of the ground down that way (LEAVE_LOOK ticks)?
func _clear_ahead(vh: Vector3, vy: float, allow: float, delta: float) -> bool:
	for k in [1, 2, 4, 8, LEAVE_LOOK]:
		var t := float(k) * delta
		if _leave_depth(global_position + (vh + Vector3.UP * vy) * t) > allow:
			return false
	return true


## How deep the hull, leaned as it stands (_tilt), reaches into the terrain with the body's origin at `at`: the most any point
## of a 5 x 5 lattice over its underside sits below the ground under it (negative: clear of it).
func _leave_depth(at: Vector3) -> float:
	var bx := _hull_cs.shape as BoxShape3D
	if bx == null:
		return -INF
	var xf := Transform3D(global_transform.basis, at) * Transform3D(_tilt, Vector3.ZERO) * _hull_rest
	var h := bx.size * 0.5
	var deep := -INF
	for i in 5:
		for j in 5:
			var p := xf * Vector3(h.x * (i / 2.0 - 1.0), -h.y, h.z * (j / 2.0 - 1.0))
			deep = maxf(deep, _ground_h_at(p.x, p.z) - p.y)
	return deep


# Does the hull, leaned by `b` about the origin, stand in the terrain where the body is?
func _in_terrain(b: Basis) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _hull_cs.shape
	q.transform = global_transform * Transform3D(b, Vector3.ZERO) * _hull_rest
	q.collision_mask = 1
	var ex: Array[RID] = [get_rid()]
	if _driver != null and is_instance_valid(_driver):
		ex.append(_driver.get_rid())
	q.exclude = ex
	for r in get_world_3d().direct_space_state.intersect_shape(q, 16):
		var o = r.get("collider")
		if o is Node and (o as Node).is_in_group("gogi_terrain"):
			return true
	return false


## WHEELS ON THE GROUND — why the truck floated, slid and stalled, and what replaced it.
##
## Measured headless on the real terrain collider, the Kestrel Bay truck (5.5 m), before this:
##   every tyre 0.84 m off a 17 deg slope and ~1.4 m off the canyon walls it spawns between, parked too;
##   28 m of sideways slide driving ACROSS a 17 deg slope; 7 m of progress in 6 s up the canyon wall;
##   230-540 hull-vs-terrain contacts per run on every grade, zero on the flat.
## Three rules were fighting over one number:
##   1. _rest_y put the ORIGIN at the HIGHEST of the four hull corners (+0.1), so no corner could be
##      underground. On a grade that corner is uphill: the middle of the hull hangs half a hull-length
##      times the slope above the ground, and the cosmetic tilt then pivoted the model about that raised
##      origin — which lifts EVERY tyre, uphill and downhill, to about the origin's height.
##   2. _climb_rate compared the ground ahead of the CENTRE with the ground under that HIGHEST corner,
##      so on any grade it asked for "down", clamped at 14 m/s, every frame, going up or down.
##   3. _snap_to_ground lerped y back up. Between 2 and 3 the level box ground into the terrain trimesh
##      every frame, and move_and_slide resolved each contact by pushing the hull out along the slope
##      face — sideways and downhill. That is the wiggle, the slide and the stall.
##
## Now ONE rule owns y, and it lives in the TYRES. Each of the four tyres follows the rendered ground
## under it — or, when that ground drops away faster than FALL_GRAVITY can pull it down (a crest at
## speed, a drop), falls on its own. The body is the plane through its four tyres: it leans to them —
## model, seat and hull box together — and rests so no tyre is below its own height. On any planar
## grade, and through any straight dip or over any straight crest, all four tyres touch. Going over an
## edge the front tyres fall first and the body pivots on the rear ones; it lands tyre by tyre. The
## terrain trimesh is no longer a collider for the hull at all: GTerrain.height IS that surface by
## construction, and two answers for one surface is exactly what the solver was arbitrating sideways.
## Buildings, walls, props and other vehicles still stop it.
func _wheel_step(delta: float) -> void:
	if delta <= 0.0:
		return
	# The tyre state describes the ground where WE left the body. If anything else has moved it since —
	# a rule's teleport_player, a respawn, the network putting it under a remote rider — that state
	# belongs to another place: predicting from it swept the body back up to its old altitude (a 20 m
	# teleport down replayed as a 20 m fall) or launched it into a hop. Re-seed on the ground here.
	if not _snapped or not _wheel_last.is_finite() \
			or global_position.distance_to(_wheel_last) > 0.25:
		_settle_on_wheels()
		_snapped = true
	# Terrain bodies to ignore: rescan on boarding (enter() zeroes the timer), when the resident count
	# changes, when an excepted body leaves (_release_terrain zeroes it — a rebuilt cell's new body must
	# not scrape the hull for a single tick), and once a second as a backstop.
	_ex_t -= delta
	var tn := get_tree().get_node_count_in_group("gogi_terrain")
	if _ex_t <= 0.0 or tn != _ex_n:
		_ex_t = 1.0
		_ex_n = tn
		_except_terrain()
	var o := global_position
	var hv := Vector3(velocity.x, 0.0, velocity.z)
	var nxt := o + hv * delta
	var pred := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	for i in 4:
		var b := _tyre_xz(i, nxt)
		var g1 := _ground_h_at(b.x, b.y) + TYRE_GAP
		if _tyre_down[i]:
			var gvy := (g1 - _tyre_y[i]) / delta   # how fast the ground under it rises (its height IS last tick's ground)
			if gvy >= _tyre_vy[i] - FALL_GRAVITY * delta:
				_tyre_vy[i] = gvy
				pred[i] = g1
				continue
			_tyre_down[i] = false          # it drops away faster than the tyre can fall: airborne
			_tyre_vy[i] = minf(_tyre_vy[i], LAUNCH_VY_MAX)
		# ...and a leg reaches down after it while the ground is within its reach (LEG_GRIP)
		var reach := _grip_reach > 0.0 and _tyre_y[i] - g1 <= _grip_reach
		_tyre_vy[i] -= FALL_GRAVITY * (LEG_GRIP if reach else 1.0) * delta
		pred[i] = maxf(_tyre_y[i] + _tyre_vy[i] * delta, g1)
	# Sweep toward where this tick should end, so move_and_slide meets anything on that path.
	velocity = hv + Vector3.UP * ((_plane_through(pred).x - o.y) / delta)
	move_and_slide()              # buildings/walls (layer 1) stop it; the terrain is excepted
	# Settle every tyre where the body ACTUALLY is: a wall can have turned the slide off the line.
	var p := global_position
	var air := 0
	var air_vy := 0.0
	for i in 4:
		var q := _tyre_xz(i, p)
		var g := _ground_h_at(q.x, q.y) + TYRE_GAP
		if not _tyre_down[i]:
			_tyre_y[i] += _tyre_vy[i] * delta
			if _tyre_y[i] > g:
				air += 1
				air_vy += _tyre_vy[i]
				continue
			_tyre_down[i] = true           # touchdown; keeps its landing speed for the lift-off test
		_tyre_y[i] = g
	# Tyres falling at different speeds ARE the body's spin. Bleed it, or a car that tips off a ledge
	# keeps rotating the whole way down and lands on its nose.
	if air > 1:
		air_vy /= float(air)
		var k := minf(1.0, AIR_SPIN_DAMP * delta)
		for i in 4:
			if not _tyre_down[i]:
				_tyre_vy[i] = lerpf(_tyre_vy[i], air_vy, k)
	_pose_from_tyres()
	_wheel_last = global_position


# Put the body on the plane through its tyres, then hold the airborne tyres to that plane: the chassis
# is rigid, so a tyre in the air is wherever the body carries it (this is also what stops the lean
# running past GROUND_TILT_MAX while falling).
func _pose_from_tyres() -> void:
	_keel = _keel_now()
	var pose := _keel_support(_plane_through(_tyre_y), global_position)
	_clear_sup = _sup_clear   # ...and how far what it rests on is over the ground now, read as it was rested (_keel_clearance)
	_support_at = Engine.get_physics_frames()
	global_position.y = pose.x
	for i in 4:
		if not _tyre_down[i]:
			_tyre_y[i] = _plane_at(pose, i)
	_tilt = _fit_basis(pose)
	_apply_tilt()


# Park / spawn / hand-over: every tyre on the ground NOW, at rest.
func _settle_on_wheels() -> void:
	for i in 4:
		var q := _tyre_xz(i, global_position)
		_tyre_y[i] = _ground_h_at(q.x, q.y) + TYRE_GAP
		_tyre_vy[i] = 0.0
		_tyre_down[i] = true
	_rock = 0.0
	_pose_from_tyres()
	_wheel_last = global_position


# World xz of tyre i (0..3 = (-x,-z), (-x,+z), (+x,-z), (+x,+z) on the contact rectangle) for a body
# origin at `o` on the current heading. Sampled unleaned: on a planar grade a leaned tyre still lands
# on the same plane, and the difference on curved ground is second-order.
func _tyre_xz(i: int, o: Vector3) -> Vector2:
	var w := global_transform.basis * Vector3(_contact_c.x + _contact_h.x * (-1.0 if i < 2 else 1.0), 0.0,
		_contact_c.y + _contact_h.y * (-1.0 if i % 2 == 0 else 1.0))
	return Vector2(o.x + w.x, o.z + w.z)


## The plane a RIGID chassis rests on, given four tyre heights (tyre order as _tyre_xz). Returns
## Vector3(the body ORIGIN's height, slope along the body's +x, slope along its +z).
##
## A rigid rectangle on four points stands on its HIGHER DIAGONAL: the plane through that pair, at the
## height of their midpoint (it can't go lower without a tyre entering the ground). What is left is one
## freedom, rotation about that diagonal, bounded by the other two tyres (neither may end up below its
## height). Within that bound the body takes the FLATTEST attitude — a heavy chassis doesn't lean
## further than its supports make it. On any planar grade the bound is a single point, the grade itself;
## with one tyre over an edge the body stays level on the other three and that tyre hangs. It varies
## continuously with the heights, so a twisting surface never makes the body pop between poses.
## (Least squares instead split the difference: with one tyre over a crater rim it leaned the chassis
## toward the hole, drove the far sill into the ground, and the underside support then lifted all four
## tyres off it — 17-31 deg of lean and up to 2.4 m of hover, where the old code sat level on three.)
##
## The rule is GBody.rest_plane's — the same one a creature stands by on its feet (GBody.lean_on): here, the plane's height at the
## contact rectangle's centre carried to the body's origin.
func _plane_through(y: PackedFloat32Array) -> Vector3:
	var pl := GBody.rest_plane(y, _contact_h, tan(GROUND_TILT_MAX))
	return Vector3(pl.x - pl.y * _contact_c.x - pl.z * _contact_c.y - _contact_y, pl.y, pl.z)


# Height of the body's tyre plane at tyre i, for a pose from _plane_through.
func _plane_at(pose: Vector3, i: int) -> float:
	return pose.x + _contact_y + pose.y * (_contact_c.x + _contact_h.x * (-1.0 if i < 2 else 1.0)) \
		+ pose.z * (_contact_c.y + _contact_h.y * (-1.0 if i % 2 == 0 else 1.0))


# The pose the body would take with all four tyres on the ground at origin `o` (no state touched).
func _ground_fit(o: Vector3) -> Vector3:
	_keel = _keel_now()
	var y := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	for i in 4:
		var q := _tyre_xz(i, o)
		y[i] = _ground_h_at(q.x, q.y) + TYRE_GAP
	return _keel_support(_plane_through(y), o)


## THE UNDERSIDE IS A CONTACT TOO. Tyres alone let the body pass through the ground wherever it bends
## sharper than the body's approach angle: measured on the real Kestrel truck mesh, its front overhang
## went 0.22 m into a 17 deg grade as it met it, 0.48 m into a 31 deg one, and 0.08 m into the canyon
## wall it spawns beside. A real bumper does not do that — it touches and the truck rides up on it,
## pivoting about the far axle. So: any underside point below the ground ahead of the front axle pitches
## the body up about the rear axle, one behind the rear axle pitches it about the front axle, a sill
## between the axles rolls it about the far track, and only the middle of the belly (high-centred on a
## crest) lifts it bodily. Three passes, as each correction moves
## the points the other measured. The tyres keep following the ground underneath; the body just stands
## on whichever parts of it actually touch.
func _keel_support(pose: Vector3, o: Vector3) -> Vector3:
	if _keel.is_empty():
		return pose
	var b := global_transform.basis
	var zf := _contact_c.y + _contact_h.y       # front axle line (body z)
	var zr := _contact_c.y - _contact_h.y       # rear axle line
	var xr := _contact_c.x + _contact_h.x       # +x track line
	var xl := _contact_c.x - _contact_h.x       # -x track line
	var side := _contact_h.x * 0.5              # further than this off the centreline = a sill, not the belly
	var lim := tan(GROUND_TILT_MAX)
	_sup_clear = INF
	for _pass in 3:
		var t := _fit_basis(pose)
		var up_f := 0.0
		var up_r := 0.0
		var up_p := 0.0
		var up_m := 0.0
		var lift := 0.0
		_sup_clear = INF
		for k in _keel:
			var q := b * (t * k)
			var pen := _ground_h_at(o.x + q.x, o.z + q.z) + TYRE_GAP - (pose.x + q.y)
			_sup_clear = minf(_sup_clear, -pen)
			if pen <= 0.0:
				continue
			if k.z > zf:
				up_f = maxf(up_f, pen / maxf(0.3, k.z - zr))
			elif k.z < zr:
				up_r = maxf(up_r, pen / maxf(0.3, zf - k.z))
			elif k.x > _contact_c.x + side:
				up_p = maxf(up_p, pen / maxf(0.3, k.x - xl))
			elif k.x < _contact_c.x - side:
				up_m = maxf(up_m, pen / maxf(0.3, xr - k.x))
			else:
				lift = maxf(lift, pen)
		if up_f == 0.0 and up_r == 0.0 and up_p == 0.0 and up_m == 0.0 and lift == 0.0:
			break
		# plane + up_f*(z - zr) pivots about the rear axle, + up_r*(zf - z) about the front axle,
		# + up_p*(x - xl) rolls about the -x track, + up_m*(xr - x) about the +x track; evaluated at the origin
		pose = Vector3(pose.x - up_f * zr + up_r * zf - up_p * xl + up_m * xr + lift,
			clampf(pose.y + up_p - up_m, -lim, lim), clampf(pose.z + up_f - up_r, -lim, lim))
		_sup_clear = 0.0   # lifted onto what it met: it rests on it
	return pose


# The body's underside, in its own frame at rest: the mesh (wheels excluded — they are the tyres) binned into KEEL_BANDS
# strips across the body and KEEL_SLICES slices along it, each bin's lowest point where it is most exposed (GPose.keel_points
# says how, and why). A drawn mount's is its hooves' and all (_keel_hoof): what it rests on standing with its feet as its clip
# draws them; while its feet stand on the ground (GFeet) it rests on what it draws without its legs instead (_keel_now).
func _measure_keel() -> void:
	_keel = PackedVector3Array()
	_keel_hoof = _keel
	if _visual == null:
		return
	var skip := {}
	for w in _wheels:
		if w != null:
			skip[w.get_instance_id()] = true
	for sp in _steer_pivots:
		if sp != null:
			skip[sp.get_instance_id()] = true
	var pts := PackedVector3Array()
	var stack: Array = [[_visual, _vis_rest]]
	if not _drawn_pts.is_empty():
		# A SKINNED mount's mesh arrays are its BIND pose, which sits wherever the rig left it (the default dragon's 2.3 m
		# above what it draws, the triceratops's keel spanning x -2.24..0.44 under a body drawn -0.75..0.75): its underside
		# is what it draws (_mount_drawn), taken before the engine hung its saddle on it. On the bind vertices a wheeled
		# triceratops hovered 0.96 m over a 17 deg grade once it was grounded on what it draws.
		pts = _drawn_pts
		stack = []
	while not stack.is_empty() and pts.size() < SCAN_VERT_CAP:
		var it: Array = stack.pop_back()
		var n: Node = it[0]
		if skip.has(n.get_instance_id()):
			continue
		var xf: Transform3D = it[1]
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mesh: Mesh = (n as MeshInstance3D).mesh
			for si in mesh.get_surface_count():
				var arr := GPose.surface_arrays(mesh, si)
				if arr.size() <= Mesh.ARRAY_VERTEX or arr[Mesh.ARRAY_VERTEX] == null:
					continue
				var vs := arr[Mesh.ARRAY_VERTEX] as PackedVector3Array
				var step := maxi(1, vs.size() / 4000)
				for i in range(0, vs.size(), step):
					pts.append(xf * vs[i])
		for c in n.get_children():
			if c is Node3D:
				stack.append([c, xf * (c as Node3D).transform])
	if pts.is_empty():
		return
	_keel = GPose.keel_points(pts, _body_ab, KEEL_BANDS, KEEL_SLICES, 0.03)
	_keel_hoof = _keel


## THE UNDERSIDE IT RESTS ON NOW (_keel_support's): while its feet stand on the ground (GFeet), what it draws without its legs
## in the pose its clip shows (its fit's keel, the nearest of its phases; its rest's with no clip playing) — resting on its
## hooves too, the body rode on whichever was lowest and the others hung off a crest, and rested on its rest pose, a lowered
## head or a swinging tail went into the ground (hoof-crest). Otherwise its hooves and all at rest (_keel_hoof): a parked mount
## its feet do not stand for is held up on a crest by its hooves, as it always was.
func _keel_now() -> PackedVector3Array:
	_keel_ix = Vector2i(-1, -1)
	if _feet == null or not _feet.want or _keel_tab.is_empty():
		return _keel_hoof
	var ap := _gait_ap
	var c := String(ap.current_animation) if ap != null and ap.is_playing() else ""
	var row: Array = _keel_tab.get(c, [])
	if row.is_empty():
		c = ""
		row = _keel_tab.get("", [])
	if row.is_empty():
		return _keel_hoof
	var i := 0
	if row.size() > 1:
		i = roundi(ap.current_animation_position / maxf(ap.current_animation_length, 1e-6) * float(row.size())) % row.size()
	_keel_ix = Vector2i(c.hash(), i)
	return row[i]


## How far what it rests on now (_keel_now: without its legs while they stand) is over the ground at its lowest — as far as its
## feet's crouch may take it (GFeet.prepare): uncapped, a triceratops's crouch put its head 0.545 m into a hollow (hoof-crest).
## Read where it was rested this physics tick (_keel_support reads the ground under every point of it already), else once
## for where it stands and the pose it shows (a parked or a peer's mount) — read a ground read a point every rendered frame
## that wanted a crouch, it was 35-59 us of the 50-68 a frame a ridden horse's or cow's feet took (step 5c's review).
func _keel_clearance() -> float:
	if _support_at == Engine.get_physics_frames():
		return _clear_sup
	var g := global_transform * Transform3D(_tilt, Vector3.ZERO)
	var keel := _keel_now()
	if g == _clear_xf and _keel_ix == _clear_ix:
		return _clear
	_clear_xf = g
	_clear_ix = _keel_ix
	var clr := INF
	for k in keel:
		var w := g * k
		clr = minf(clr, w.y - _ground_h_at(w.x, w.z) - TYRE_GAP)
	GFeet.keel_reads += keel.size()
	_clear = clr
	return clr


# The rectangle the body stands on, in its own frame, measured once at the end of setup (at rest):
# the wheel HUBS when there are wheels whose placement is known, else the footprint inset to where
# wheels or hooves sit. Fitting the body's own corners instead left the tyres hovering wherever the
# grade changes under the wheelbase — the line between two bumpers is not where the wheels are.
func _measure_contact() -> void:
	# A drawn mount's hull runs nose to tail, so its corners are under the head and the tail, not the hooves: it stands
	# on its bone box (_seat_box, base y = 0), inset. Measured against the drawn feet as the rectangle instead: no gain
	# (the same deepest point on a 17 deg grade, the cow 4 cm deeper over a +-16.7 deg crest).
	var cab := _seat_box if _seat_box.has_volume() else _body_ab
	var c := cab.position + cab.size * 0.5
	_contact_c = Vector2(c.x, c.z)
	_contact_h = Vector2(maxf(0.25, cab.size.x * 0.5 * CONTACT_INSET),
		maxf(0.25, cab.size.z * 0.5 * CONTACT_INSET))
	_contact_y = cab.position.y   # every body is grounded base-to-y=0, tyre bottoms included
	if _wheels.size() < 4:
		return
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for w in _wheels:
		if w == null or not is_instance_valid(w):
			continue
		var xf := Transform3D.IDENTITY
		var n: Node = w
		while n != null and n != self:
			if n is Node3D:
				xf = (n as Node3D).transform * xf
			n = n.get_parent()
		lo = lo.min(xf.origin)
		hi = hi.max(xf.origin)
	var sx := (hi.x - lo.x) * 0.5
	var sz := (hi.z - lo.z) * 0.5
	# Trust the hubs only when they span a real footprint: a wheel scanned out of a fused GLB by NAME
	# carries whatever origin its author gave the node, which can be anywhere.
	if sx >= _body_ab.size.x * 0.2 and sz >= _body_ab.size.z * 0.25:
		_contact_c = Vector2((lo.x + hi.x) * 0.5, (lo.z + hi.z) * 0.5)
		_contact_h = Vector2(sx, sz)


# The lean that lays the footprint flat on a _ground_fit plane: +z runs up the fall line, +y is the
# plane's normal, and +x = y × z lies in the plane too, so all four corners land on it.
func _fit_basis(fit: Vector3) -> Basis:
	var lim := tan(GROUND_TILT_MAX)
	return GBody.rest_lean(clampf(fit.y, -lim, lim), clampf(fit.z, -lim, lim))


# Lean the model (plus a mount's gait rock) and the hull box together, about the body origin.
#
# APPLIED TO `_visual` AND THE HULL SHAPE, NEVER TO THE BODY BASIS: `global_transform.basis.z` is the
# drive heading and `.x` is the dismount side, so leaning the body itself would steer it into the
# hillside and throw the player out sideways into the air. Composed over _vis_rest — the transform the
# model was BUILT with — because a fused GLB carries its own orient yaw, scale and grounding offset.
# (The old cosmetic tilt rebuilt the basis from _flyer_orient_yaw, which only flyers set: a fused car
# whose length ran along X was turned 90 deg at build and silently turned back on its first grounded tick.)
func _apply_tilt() -> void:
	var lean := _tilt * Basis(Vector3.RIGHT, _rock) if _rock != 0.0 else _tilt
	if _visual != null:
		_visual.transform = Transform3D(lean, Vector3.ZERO) * _vis_rest
	if _hull_cs != null:
		_hull_crouch()
		_hull_cs.transform = Transform3D(_tilt, Vector3.ZERO) * _hull_rest


## THE HULL FOLLOWS ITS FEET'S CROUCH (GFeet): what it draws comes down by it, its feet stay on the ground — so its top comes down
## and its base stays, the box and the body a shot or an enemy meets (GBody) alike: the hull is the body it draws. Cut again only
## once the crouch has moved 5 mm (the body is built anew each time); set back by _set_hull (a swap, a rider) and cut from there.
## True when it was cut.
func _hull_crouch() -> bool:
	var c := _feet.crouch * _feet.influence if _feet != null else 0.0
	if absf(c - _crouched) < 0.005 and (c > 0.0 or _crouched == 0.0):
		return false
	_crouched = c
	var ab := _body_ab
	ab.size.y = maxf(ab.size.y - c, 0.0)
	var box := _hull_cs.shape as BoxShape3D
	box.size = Vector3(maxf(0.5, ab.size.x), maxf(0.5, ab.size.y), maxf(0.5, ab.size.z))
	_hull_rest = Transform3D(Basis(), ab.position + ab.size * 0.5)
	body = GBody.box(_hull_rest.origin, box.size).owned_by(self)
	return true


## ...PARKED AND UNDER ANOTHER PLAYER TOO, where nothing re-tilts it (_apply_tilt runs as it is driven, or re-settled): its
## feet crouch it there every frame, and its hull's top stood that far over what it drew — the default dragon's 0.21-0.33 m
## astride a step, in a hollow (step 5c's review).
func _hull_follow() -> void:
	if _hull_cs != null and _hull_crouch():
		_hull_cs.transform = Transform3D(_tilt, Vector3.ZERO) * _hull_rest


# How far the model is leaned off its built attitude — ground lean, gait rock or flight attitude alike.
# The seated driver takes this on top of the heading so they lean WITH the body instead of standing
# bolt upright through its roof.
func _lean() -> Basis:
	if _visual == null:
		return Basis()
	return (_visual.transform.basis * _vis_rest.basis.inverse()).orthonormalized()


## The hull never collides with the terrain it rests on (see _wheel_step). Cells stream in and out, so
## each terrain body is excepted when it appears (group "gogi_terrain" — the trimesh GTerrain builds; the
## invisible world-border walls are NOT in it and still stop the vehicle) and released as it leaves.
func _except_terrain() -> void:
	for n in get_tree().get_nodes_in_group("gogi_terrain"):
		var id := n.get_instance_id()
		if _terrain_ex.has(id) or not (n is PhysicsBody3D):
			continue
		add_collision_exception_with(n)
		var cb := _release_terrain.bind(n)
		_terrain_ex[id] = cb
		n.tree_exiting.connect(cb, CONNECT_ONE_SHOT)


# ...and given back, every one, when a flyer leaves the ground (_take_off): its release callbacks too, or the next
# landing could not connect them again.
func _unexcept_terrain() -> void:
	for id in _terrain_ex.keys():
		var n := instance_from_id(id)
		if n != null and n is PhysicsBody3D:
			remove_collision_exception_with(n)
			var cb: Callable = _terrain_ex[id]
			if (n as Node).tree_exiting.is_connected(cb):
				(n as Node).tree_exiting.disconnect(cb)
	_terrain_ex.clear()
	_ex_n = -1


func _release_terrain(n: Node) -> void:
	_terrain_ex.erase(n.get_instance_id())
	_ex_t = 0.0   # a cell is going: its rebuild (if any) gets excepted on the very next tick
	if is_instance_valid(n) and n is PhysicsBody3D:
		remove_collision_exception_with(n)


# Arcade FLIGHT (plane + dragon, shared envelope): input.y = pitch, input.x = bank+yaw, speed
# runs toward SPEED_MAX on implicit cruise throttle. Soft ceiling at ALT_MAX above the LOCAL
# terrain; descending into the GROUNDED_H band lands (back to ground steering).
func _drive_air(delta: float) -> void:
	# LAND REQUEST (USE pressed mid-air): override the stick to a steady braked descent, then dismount
	# on touchdown below — a mid-air USE can no longer strand the rider up in the sky.
	if _land_req:
		_input = Vector2(0.0, 0.9)   # +y -> nose DOWN -> come down; no yaw
		_air_thr = 0.35
	# THROTTLE: ease speed toward SPEED_MAX * _air_thr (drive_input_world sets _air_thr from the stick),
	# so backing off / pulling the stick back genuinely SLOWS the flyer. A 0.2 floor keeps minimum
	# airspeed so it can't stall and drop. The raw drive_input path leaves _air_thr at cruise 1.0.
	_speed = move_toward(_speed, SPEED_MAX * clampf(_air_thr, 0.2, 1.0), AIR_ACCEL * delta)
	if _leaving:
		_leave_ground(delta)
	var gy := _ground_h()
	var rel := global_position.y - gy
	# PITCH sign: screen-up / W gives _input.y = -1 (the _keyboard_vec convention), and
	# -(-1) * PITCH_MAX = +35° = CLIMB — so holding W through takeoff keeps climbing.
	var tp := -_input.y * deg_to_rad(PITCH_MAX_DEG)
	# soft ceiling: inside the CEIL_BAND below ALT_MAX the allowed climb fades to 0, and ABOVE
	# ALT_MAX it goes negative — pitch is forced down approaching/at the lid.
	var allowed := clampf((ALT_MAX - rel) / CEIL_BAND, -1.0, 1.0) * deg_to_rad(PITCH_MAX_DEG)
	tp = minf(tp, allowed)
	_pitch = move_toward(_pitch, tp, PITCH_RATE * delta)
	# BANKED TURN: same steer sign as the ground path (A / x=-1 -> +yaw); not speed-scaled.
	rotation.y += -_input.x * AIR_TURN * delta
	# visual ROLL sign: rotation about local +Z by -θ dips the +X side ((1,0,0) -> (cosθ, -sinθ, 0));
	# steering toward +X (input.x = -1, yaw+) should dip +X, so roll target = input.x * ROLL_MAX
	# (input.x = -1 -> -40° -> +X wing down = banking INTO the turn).
	_roll = move_toward(_roll, _input.x * deg_to_rad(ROLL_MAX_DEG), ROLL_RATE * delta)
	if _visual != null:
		# Attitude = pitch(about X)/roll(about Z) COMPOSED OVER the fuselage orient, so a model whose
		# nose was authored along X (orient yaw != 0) climbs by PITCHING, not barrel-rolling. Rebuild the
		# whole basis (preserving scale) rather than set rotation.x/z, so the orient is applied UNDER the
		# attitude. Nose is +Z after orient; +θ about X pitches +Z down, so climb (+_pitch) needs -_pitch.
		# Over the lean a flyer leaving a slope still has (_leave_ground; identity once it is out of the ground).
		var att := (Basis.from_euler(Vector3(-_pitch, 0.0, _roll)) * Basis(Vector3.UP, _flyer_orient_yaw)).scaled(Vector3.ONE * _flyer_scale)
		_visual.transform = Transform3D(_tilt * att, _tilt * _vis_rest.origin)
	# kinematics: forward along the yaw heading, vertical from the pitch angle
	var _vy := _speed * sin(_pitch)
	if _pitch < 0.0:
		_vy *= DESCENT_GAIN   # DESCENDING (nose down): sink faster than the low braked landing airspeed alone allows. Guarded by _pitch<0 so level flight, climb, ceiling hold and takeoff (+10°) are byte-for-byte unchanged.
	if _leaving and not _land_req and (not _terrain_ex.is_empty() or global_position.y - gy < GROUND_LIFT):
		_vy = maxf(_vy, TAKEOFF_CLIMB)   # out of the ground it took off from, up to its floor, before it flies level
	velocity = global_transform.basis.z * (_speed * cos(_pitch)) + Vector3.UP * _vy
	if _leaving:
		velocity = _leave_hold(velocity, delta)
	move_and_slide()   # buildings still stop a low flyer; slides along them
	# A DESCENDING flyer whose hull meets the ground has landed, wherever its origin is: on a slope the origin stays far
	# above the ground under it while a wing or a foot touches down (the default dragon could land across a slope only
	# below atan(0.5 / its half-span), 6.3 deg once its wings were in its hull — mount-hulls review).
	var touch := false
	for i in get_slide_collision_count():
		var o = get_slide_collision(i).get_collider()
		if o is Node and (o as Node).is_in_group("gogi_terrain"):
			touch = true
	# hard envelope clamp (the soft ceiling handles the approach; this catches terrain rising fast) — a flyer leaving the
	# ground climbs to its GROUND_LIFT floor (_leave_ground)
	global_position.y = clampf(global_position.y, gy + (0.0 if _leaving else GROUND_LIFT), gy + ALT_MAX)
	rel = global_position.y - _ground_h()
	if (rel < GROUNDED_H or touch) and _pitch <= 0.0:
		_land()
		if _land_req:
			_land_req = false
			exit()   # now grounded -> the airborne guard passes and the dismount completes


func _land() -> void:
	_airborne = false
	_leaving = false
	_pitch = 0.0
	_roll = 0.0
	if _visual != null:
		# level attitude, fuselage orient kept (over the lean of a hop that never left the slope it took off from)
		_visual.transform = Transform3D(_tilt * Basis(Vector3.UP, _flyer_orient_yaw).scaled(Vector3.ONE * _flyer_scale), _tilt * _vis_rest.origin)
	# ON ITS FEET from here (_wheel_ground): its tyres start where its feet are and FALL onto the ground under them (a
	# wingtip that met a slope first has landed it a metre or more up), and the terrain under it is excepted before the
	# hull moves again. A seaplane on water keeps the snap's lerp onto the surface.
	if _wheel_ground():
		for i in 4:
			_tyre_y[i] = global_position.y + _contact_y
			_tyre_vy[i] = minf(velocity.y, 0.0)
			_tyre_down[i] = false
		_wheel_last = global_position
		_snapped = true
	_ex_t = 0.0
	_sync_hull()


# WHEELS THAT MOVE (2.2): spin each registered wheel about its axle by rolling distance / radius,
# and slew the front steer pivots toward the current steer input. Parametric wheels spin about
# local +Y (rotation.z=PI/2 laid them on their side); modeled GLB wheels about local +X. Empty
# lists (mounts, wheelless fused GLBs) -> no-op.
func _update_wheels(delta: float) -> void:
	if not _wheels.is_empty():
		var spin := (_speed / _wheel_radius) * delta   # signed: reverses when backing up
		for w in _wheels:
			if w != null and is_instance_valid(w):
				w.rotate_object_local(_wheel_axle, spin)
	if not _steer_pivots.is_empty():
		# _input.x is the steer (A/x=-1 turns the body +yaw); match the front wheels to it.
		var target := -clampf(_input.x, -1.0, 1.0) * WHEEL_STEER_MAX
		for sp in _steer_pivots:
			if sp != null and is_instance_valid(sp):
				sp.rotation.y = move_toward(sp.rotation.y, target, WHEEL_STEER_SLEW * delta)


# RIDE-BOB (2.4): while a MOUNT walks, add a subtle rider bounce (fed to _track_driver via _ride_bob,
# so GPose.ride is never disturbed) plus a +/- body rock so a subtle/absent gait clip still reads as
# motion. Airborne (dragon) leaves _visual.rotation.x to the flight path; a stopped mount settles
# level. Non-mounts and vehicles are untouched (_ride_bob stays 0). ONLY A MOUNT WITH NO MOVE CLIP OF ITS OWN (F1): one
# that walks or runs moves its own back, and the rider rides that (_follow_seat) — the fake rock on top of it dipped its
# hooves 5-7 cm into flat ground in rhythm and swung a long head and tail 14 cm (followups3, hooves).
func _update_ride_motion(delta: float) -> void:
	_ride_bob = 0.0
	if not _is_mount or _airborne or _gaited:
		_stride_on(0.0, false)
		return
	# A WHEELED (walking) mount leans onto the ground in _apply_tilt, so its rock is composed there:
	# writing _visual.rotation.x directly would overwrite the lean with the rock every tick.
	var wheeled := _wheel_ground()
	if _state == S_DRIVING and absf(_speed) > RIDE_MOVE_MIN:
		var phase := _time * (1.0 + 0.30 * absf(_speed)) * TAU   # ~1 Hz walk .. ~4 Hz gallop
		_ride_bob = RIDE_BOB_AMP * absf(sin(phase))              # rider bounce (always >= 0)
		_stride_on(absf(_speed), wheeled)
		if _striding:
			# ...nor one striding on its legs (step 5d): its legs are its motion, and a rock out of step with them held a lifted
			# foot 4.9 cm off what its stride drew (GFeet keeps a foot's lift over the body unrocked: the drive rig's (f3))
			_rock = move_toward(_rock, 0.0, 4.0 * delta)
		elif wheeled:
			_rock = deg_to_rad(RIDE_PITCH_DEG) * sin(phase)       # +/- body rock
		elif _visual != null:
			_visual.rotation.x = deg_to_rad(RIDE_PITCH_DEG) * sin(phase)
	else:
		_stride_on(0.0, false)
		if wheeled:
			_rock = move_toward(_rock, 0.0, 4.0 * delta)             # settle level when idle
		elif _visual != null and not is_zero_approx(_visual.rotation.x):
			_visual.rotation.x = move_toward(_visual.rotation.x, 0.0, 4.0 * delta)
	if wheeled:
		_apply_tilt()


## A MOUNT WITH LEGS AND NO GAIT OF ITS OWN STRIDES (step 5d). With no walk or run clip the library's default dragon went across
## the ground in its rest pose, its feet carried at its own speed (1.5-2.7 m/s riding at 2.0: it glided), where a herd or an
## enemy with no clip strides (GPose.walk). On its feet (GFeet) it strides as they do: its thighs swung, at the rate that carries
## a foot under its hip back as fast as the body goes over it (a swing of WALK_THIGH_DEG on its shortest leg) — GFeet puts each
## foot on the ground under it, and a foot the swing lifts stays lifted. ONLY LEGS THAT ARE CHAINS: a Quaternius hoof is an IK
## target hanging from the root (GRig.legs' chain false), which no thigh swung moves — the pig's, the sheep's, the pug's, the
## llama's and the frog's stay as they were (their walks have to be drawn). Off the ground, stopped, or on a clip of its own,
## its legs are given back. `speed`: m/s along its way (its physics tick's). DRAWN A RENDERED FRAME AT A TIME (_process, on
## while it strides, ridden or not), where a clip poses it, its phase on by the ground it covers in that frame: a bone written
## in a physics tick sets its skeleton to work its modifiers out again — GFeet solved 2.3 times a frame, 18.6 us of it (the
## drive rig's footing (f12)) — and stepped a physics tick at a time, a 45 fps frame swung its legs one tick's step or two's
## ((f13)).
func _stride_on(speed: float, on: bool) -> void:
	if on and _feet != null and _visual != null and speed > 0.0 and _chained:
		_stride_v = speed
		if not _striding:
			set_process(true)
		_striding = true
	elif _striding:
		if _visual != null:
			GPose.walk_stop(_visual)
		_striding = false
		_stride_v = 0.0
		set_process(not _follow.is_empty())


# Park the driver on the boardable for this tick: its marker (posed, visible — SeatMarker for
# seats, MountMarker for mounts) or the origin (hidden fallback).
# ── REMOTE RIDER (multiplayer) ────────────────────────────────────────────────────────────────
## A NETWORK peer riding this vehicle ON OUR SCREEN.
##
## Deliberately NOT enter(): that runs the drive state machine, emits drive_state_changed — which
## swings the LOCAL camera and rebinds input — and plays the boarding SFX. This client is a
## SPECTATOR of somebody else's ride and must do none of those. What it DOES share is the seating
## math below, so a peer sits exactly where the local driver would.
var _remote_rider: Node3D = null
var _remote_seated := false
var _remote_seat_off := Vector3.ZERO      # _seat_off's peer twin: minus where the rider sits, in the frame netsync places them in
var _remote_was := Vector3.ZERO           # where netsync had it at the last rendered frame, and how fast it has gone (_remote_speed)
var _remote_v := Vector3.ZERO
const REMOTE_GAIT_TAU := 0.15             # s: the copy's speed, smoothed
const REMOTE_JUMP := 4.0                  # m in a frame: a teleport or a rejoin, not motion (a flyer's top speed is 0.37 m a tick)


func set_remote_rider(rider: Node3D) -> void:
	if _remote_rider == rider:
		return
	clear_remote_rider()
	_remote_rider = rider
	_remote_was = global_position
	_remote_v = Vector3.ZERO
	if rider != null and is_instance_valid(rider):
		_seat_remote_rider()


func clear_remote_rider() -> void:
	var r := _remote_rider
	_unfollow(r)   # their hips back where the follow found them, before the pose is given back
	_remote_rider = null
	_remote_seated = false
	_remote_seat_off = Vector3.ZERO
	_stride_on(0.0, false)
	if _airborne and _driver == null:
		# a peer's flyer left in the air (they logged off mid-flight): parked from here, on its ground hull, settled where it is
		_airborne = false
		_sync_hull()
		_snapped = false
	if r != null and is_instance_valid(r):
		GPose.stand(r)   # undo the astride/seated pose or they walk around folded
		r.visible = true


## Mirror of _seat_driver for a rider we do not simulate. Same measurements, same thresholds, same
## closed-cab clearance rule and the same always-visible contract for mounts — a peer must not sit
## differently from the way the local player sits on the identical vehicle.
func _seat_remote_rider() -> void:
	var d := _remote_rider
	if d == null or not is_instance_valid(d):
		return
	var dh := GPose.char_height(d)
	if dh < 0.5:
		dh = GPose.drawn_aabb(d).size.y
	if dh < 0.5:
		dh = 1.7
	var hips := GPose.hips_height(d)
	if hips <= 0.0:
		hips = HIP_RATIO * dh
	if _is_mount:
		# the same seat as the local rider's, in the frame netsync places — the peer's body, the avatar hanging from it at its
		# own normalising scale and foot offset (hips_height(avatar) left both out: a peer's horse floated 5-16 cm)
		_fit = _fit_legs(d, d.transform)
		_remote_seated = _pose_rider(d, _fit)
		_remote_seat_off = _rider_off(d, d.transform, hips) if _remote_seated else Vector3.ZERO
	else:
		_remote_seat_off = Vector3(0.0, 0.06 - hips, 0.0)
		_remote_seated = GPose.sit(d)
		if _remote_seated and _cabin_headroom < INF and (dh - hips) > _cabin_headroom:
			_remote_seated = false
			GPose.stand(d)
	if not _remote_seated:
		if _is_mount:
			_remote_seat_off = Vector3.ZERO   # a mount's rider is ALWAYS visible — perch instead
		else:
			d.visible = false
			_remote_seat_off = Vector3.ZERO
	if _is_mount:
		_follow_start(d, false)


## Park this vehicle UNDER a rider netsync has already placed. The INVERSE of _track_driver: there
## the vehicle is authoritative and moves the driver; here the rider came off the wire, so the
## vehicle moves under them. Only one of the two is ever authoritative, so they cannot fight.
func place_under_remote_rider(rider_pos: Vector3, yaw: float) -> void:
	rotation.y = yaw
	var marker := _mount_marker if _is_mount else _seat_marker
	var seated := marker != null and is_instance_valid(marker) and (_remote_seated or _is_mount)
	# A FLYER IS IN THE AIR OR ON ITS FEET as its own flight decides it (_drive_air lands it under GROUNDED_H): by where its
	# origin goes, unleaned, over the ground there. The wire carries where the rider is, not how they fly, and a copy never
	# marked airborne was leaned to the slope under it every frame (_wheel_ground): a peer's dragon or plane banked 17 deg
	# 30 m over a 17 deg hillside, on every other screen (behaviour review). In the air it is level, on its air hull.
	if bool(PROFILES.get(profile, {}).get("fly", false)):
		var lp := (_vis_rest * marker.position) if seated else Vector3.ZERO
		var o := rider_pos - global_basis * lp - global_basis * (_remote_seat_off if seated else Vector3.ZERO)
		_airborne = o.y - _ground_h_at(o.x, o.z) >= GROUNDED_H
	# The seat rides the lean (it lives under _visual), so lean FIRST — netsync is the only thing moving us, the parked
	# tick that would otherwise re-lean is skipped: to the ground under the rider on its wheels or feet, level in the air
	# or on the water. A hidden driver's body too (they stand at its origin), which kept whatever lean it last parked with.
	if _wheel_ground():
		_tilt = _fit_basis(_ground_fit(rider_pos))
		_apply_tilt()
	else:
		_drop_lean()
	if not seated:
		global_position = rider_pos
	else:
		# The marker's offset from our origin is rigid. Read it AFTER the yaw and lean are set, so it is
		# already in world space, then subtract it and the hip drop (along the leaned up, as _track_driver
		# applies it on the rider's own screen) from where the rider stands.
		var off := marker.global_position - global_position
		global_position = rider_pos - off - (global_basis * _lean()) * _remote_seat_off
	_sync_hull()   # where it now is: the air hull once there is room for it, the ground hull back on its feet


func _track_driver() -> void:
	if _driver == null or not is_instance_valid(_driver):
		return
	var marker := _mount_marker if _is_mount else _seat_marker
	# Mounts park the rider on the marker even when the pose failed (visible
	# perch); cabin vehicles only when actually seated (else hidden at origin).
	if marker != null and (_seated or _is_mount):
		# Face where the body faces AND lean with it: the marker is under _visual, so it already sits
		# where the leaned seat is; an upright driver there would put a head through a leaned roof.
		var b := global_basis * _lean()
		_driver.global_rotation = b.get_euler()
		# Their drawn seat on the marker (_seat_off, along the driver's own axes as they sit). _ride_bob (2.4) is a small
		# bounce added while a mount with no move clip of its own walks — it moves the rider off the MARKER, never the pose,
		# so GPose.ride stays astride (0.0 for vehicles, a parked/idle mount and every mount that walks on its own legs).
		_driver.global_position = marker.global_position + b * _seat_off + b.y * _ride_bob
	else:
		_driver.global_position = global_position
	_driver.velocity = Vector3.ZERO


# A driver leaving the seat stands upright again, keeping only the heading they had.
func _upright(d: Node3D) -> void:
	if d != null and is_instance_valid(d):
		d.global_rotation = Vector3(0.0, d.global_rotation.y, 0.0)


# DEBUG (web console): window.gogiRotVeh(deg) sets the active vehicle model's yaw so I can find the
# correct forward-alignment offset empirically for the AI-generated meshes, then bake it.
func debug_yaw_model(deg: float) -> void:
	if _visual != null and is_instance_valid(_visual):
		_visual.rotation.y = deg_to_rad(deg)
		print("GOGI_VEH_YAW=%.0f profile=%s ax=%.2f az=%.2f" % [deg, profile, _body_ab.size.x, _body_ab.size.z])


# Rest-height target for the ground snap. Ground profiles: GTerrain.height(x, z) — the RENDERED-
# SURFACE height (mesh-accurate by contract), so the body hugs the visible ground; flat worlds
# (terrain == null) ride the y=0 slab. WATER profiles (boat) in a world WITH water: the GWater
# level + the pinned bob — maxed with the terrain so a boat driven over ground above the
# waterline beaches on it instead of sinking in; NO water block -> plain terrain (car-like).
func _rest_y() -> float:
	if _has_water and _water_rest:
		# A SEAPLANE (water_rest AND a flyer) can be DITCHED on high land, so it rests on the higher of
		# water/terrain. Without this the idle snap drags a plane dismounted over the island DOWN to sea
		# level, sinking it UNDER the ground it landed on — "the plane vanishes when I get off". A pure
		# BOAT keeps water_level only: maxing with the seabed would let the hull climb the beach as the
		# bottom rises toward shore (it can't drive on land — that stays a wall it stops against).
		# A WATER MOUNT rides _draft deep, its back above the surface (0 for anything built to float on its base).
		if bool(PROFILES.get(profile, {}).get("fly", false)):
			var gyf := terrain.height(global_position.x, global_position.z) if terrain != null else 0.0
			return maxf(water_level - _draft, gyf) + BOB_AMP * sin(_time * BOB_HZ)
		return water_level - _draft + BOB_AMP * sin(_time * BOB_HZ)
	if _wheel_ground():
		return _ground_fit(global_position).x
	return _ground_h() + GROUND_LIFT


# The rest surface under the body origin — for the bodies that rest on ONE point: a boat on the
# water and a flyer. Wheeled bodies rest on their footprint instead (_ground_fit).
#
# This used to take the MAX over the four hull corners for wheeled bodies too — the switchback fix:
# a LEVEL box resting on one centre sample buried its nose in the slope, and move_and_slide pushed it
# out downhill. Maxing the corners stopped the burying by lifting the whole hull to its highest corner,
# which is the float and the downhill slide measured in _wheel_step's header. Leaning the hull onto
# the fitted plane and taking the terrain out of the hull's collisions is what actually fixes both.
func _ground_h() -> float:
	return _ground_h_at(global_position.x, global_position.z)


## _ground_h for an arbitrary point — the drive step samples one frame AHEAD of the hull so it can
## climb into the rise instead of colliding with it. Same water/flyer rules as the in-place version.
func _ground_h_at(wx: float, wz: float) -> float:
	var gy := 0.0
	if terrain != null:
		# The wheeled model samples ~20 points a tick over the same few quads: memoise the quad corners
		# (GTerrain.height_cached). Main thread only, and ours alone, so nothing else can race it.
		if _hcache_rev != terrain.revision or _hcache.size() > 4096:
			_hcache.clear()
			_hcache_rev = terrain.revision
		gy = terrain.height_cached(wx, wz, _hcache)
	# WATER-REST vehicles (boat / spec-"water" seaplane) treat the water surface as their floor, so
	# a hull/seaplane over open water rides and LANDS on it instead of the seabed far below (2.3).
	# On the water the floor IS water_level (never the rising seabed, so the boat can't climb the
	# beach). A flying seaplane still references the higher of terrain/water so it clears real ground.
	# Non-water vehicles, and worlds with no water block (_has_water false), are unaffected.
	if _has_water and _water_rest:
		return maxf(gy, water_level) if _airborne else water_level
	# FLYER over water: a plane/dragon (fly profile) that isn't a water-rest craft still treats the water
	# SURFACE as its floor, so a mid-air dismount ditches it ON the water (visible, parked) instead of
	# diving to the seabed far below and vanishing. Over land maxf(gy,water_level)=gy, so it's a no-op.
	if _has_water and bool(PROFILES.get(profile, {}).get("fly", false)):
		return maxf(gy, water_level)
	return gy


# Surface a DISMOUNTED driver stands on at this XZ — MUST mirror the vehicle's own rest surface
# (_ground_h) so a flyer ditched on water (or a boat) drops its pilot onto the WATER next to the parked
# body, never the seabed/gorge-floor far below (which yanks the follow-camera off the plane so it reads
# as "vanished"). Cars/tanks/mounts on land keep raw terrain (water/fly conds false) — slopes unchanged.
func _exit_ground_y(x: float, z: float) -> float:
	var gy := terrain.height(x, z) if terrain != null else 0.0
	if _has_water and (_water_rest or bool(PROFILES.get(profile, {}).get("fly", false))):
		return maxf(gy, water_level)
	return gy


# Parked / first-snap ground. A wheeled body sits straight onto its fitted ground (it only ever parks
# ON the ground, and a lerp is a hover with a delay); boats and flyers ease onto their rest height.
func _snap_to_ground(delta: float) -> void:
	if _wheel_ground():
		# A parked body on the analytic ground only needs re-seating when it moved, turned, or the
		# terrain was re-set; the ground under it can't change otherwise. Skipping the re-fit keeps a
		# lot full of parked vehicles free on single-threaded web.
		var key := Vector4(global_position.x, global_position.z, rotation.y,
			float(terrain.revision) if terrain != null else -1.0)
		if not _snapped or key != _settled_key or not _wheel_last.is_finite() \
				or global_position.distance_to(_wheel_last) > 0.001:
			_settle_on_wheels()
			_settled_key = key
		_snapped = true
		return
	_drop_lean()
	var gy := _rest_y()
	if _snapped:
		global_position.y = lerpf(global_position.y, gy, minf(1.0, SNAP_RATE * delta))
	else:
		global_position.y = gy
		_snapped = true


# Put the body on its rest surface immediately (pause-safe: not gated on a physics tick).
func _ground_now() -> void:
	if _wheel_ground():
		_settle_on_wheels()
	else:
		_drop_lean()
		global_position.y = _rest_y()


# A body that is no longer wheeled — a boat once set_water hands it the water — must not keep the lean
# it took from the ground. main wires set_terrain BEFORE set_water, so every boat was first seated on
# the SEABED, leaned to its slope, and nothing on the water path ever straightened it again: model, seat
# and hull box stayed listed for good. _tilt is identity for anything that was never wheeled (flyers own
# _visual in the air), so this never touches a flight attitude.
func _drop_lean() -> void:
	if _tilt.is_equal_approx(Basis()) and _rock == 0.0:
		return
	_tilt = Basis()
	_rock = 0.0
	_apply_tilt()


# Wire (or re-wire) the terrain AFTER the streamer boots — vehicles spawn before ChunkManager
# builds GTerrain. Re-snaps instantly so a parked body doesn't visibly ride up to the new surface.
func set_terrain(t: GTerrain) -> void:
	terrain = t
	_hcache.clear()
	# Ground NOW, not on the next _physics_process. Vehicles spawn at y = 0.0 (main.gd) and are
	# lifted onto the surface only by _snap_to_ground inside _physics_process. A game that opens on
	# a title screen holds the world still behind it -> the vehicle's physics tick
	# never runs, so a body left at y = 0.0 sits UNDER any terrain column above 0 for the whole
	# title screen. Setting global_position is not gated by pause, so snap at hand-over; leave
	# _snapped = false so the first LIVE tick re-snaps after nudge_out / set_water refine it.
	if is_inside_tree() and t != null:
		_ground_now()
	_snapped = false


# Wire the world's water level (ChunkManager's `water_level`, read from world.json "water".level —
# the same number GWater.body renders the surface at). Only called for worlds WITH a water block;
# without it boats keep the terrain (car-on-terrain degrade, per the Wave-3 contract).
func set_water(level: float) -> void:
	_has_water = true
	water_level = level
	# Re-ground onto the water surface immediately for the same reason as set_terrain: set_water is
	# wired AFTER set_terrain, so a boat first grounds to the seabed then must lift to water_level.
	# Do it now (pause-safe) instead of waiting for a physics tick the frozen title screen suppresses.
	if is_inside_tree():
		_ground_now()
	_snapped = false


# ---------------- enter / exit (discrete API; choreographed boards wrap them in tweens) ----------------

# USE dispatch from the interaction system: walk up -> board; while driving -> exit.
# Mid-choreography USE is a no-op (this is the exit-mid-enter guard for the player path;
# the hot-reload free path is covered by _exit_tree's force-restore).
func use(driver: CharacterBody3D) -> bool:
	if _state == S_ENTERING or _state == S_EXITING:
		return false   # mid-choreography — the caller may retry shortly (a swallowed press reads as a dead button)
	if driving:
		exit()
	else:
		enter(driver)
	return true


# Swap the player IN. Instant boards (fused-GLB vehicles + the parametric tank): the Wave-1
# swap-in, hide + attach. Choreographed boards (car door / boat+plane step-in / mount): start the
# sequence with the camera switch + input routing (drive_state_changed) at sequence START,
# Wave-1 style; drive_input is ignored until the state machine reaches DRIVING.
func enter(driver: CharacterBody3D) -> void:
	if _state != S_IDLE or driver == null:
		return
	if _remote_rider != null and is_instance_valid(_remote_rider):
		return   # a peer is already riding this one
	driving = true
	_driver = driver
	_speed = 0.0
	_input = Vector2.ZERO
	_world_drive = false
	_air_thr = 1.0
	_land_req = false
	_wheel_last = Vector3.INF   # first driving tick re-seeds the tyres where the body actually stands ...
	_ex_t = 0.0                 # ... and re-excepts the terrain before the hull moves at all
	driver.velocity = Vector3.ZERO
	_set_body_collision(driver, true)   # the capsule must not fight the body's box from inside
	if _board == "instant":
		_state = S_DRIVING
		if _seat_marker != null:
			# modeled vehicle with a probed/authored seat (open or hollow cabin): board VISIBLE
			# and seated — _seat_driver poses (GPose.sit) and parks on the marker; a capsule rig
			# degrades to the hide inside it.
			_seat_driver()
		else:
			driver.visible = false      # hidden driver (tank: hatch choreography out of scope v1)
			driver.global_position = global_position
		AudioManager.play_sfx("door")
		drive_state_changed.emit(self, true)
		return
	_state = S_ENTERING
	drive_state_changed.emit(self, true)   # controls locked out from here: main routes input to the
	_set_door_blocking(false)              # body, and drive_input is ignored until _state == S_DRIVING
	_begin_enter_choreo()


# Swap the player OUT. Instant boards: the Wave-1 swap-out. Choreographed boards (while DRIVING):
# stop + run the exit choreography, releasing control (emit false) only when the driver is fully
# restored. Mid-ENTER exits are ignored (guard). AIRBORNE exits are ignored too — the chunk
# movement contract has no gravity, so a mid-air dismount would strand a floating player: land
# first (descend until terrain-relative height < 0.5), then exit. The hot-reload free path is
# restored by _exit_tree (which drops the driver at TERRAIN height, so even a freed-mid-flight
# session leaves them safely grounded).
func exit() -> void:
	if _state != S_DRIVING:
		return
	_perf_line()
	if _airborne:
		# IMMEDIATE dismount: a mid-air DISMOUNT/USE drops straight down to the surface below and gets off
		# right away. The old braked fly-down could take many seconds over deep gorges/open water (or never
		# reach a touchdown surface), reading as "the plane won't let me off." Snap the flyer just above the
		# ground/water beneath it, level it, then fall through to the normal grounded dismount so the driver
		# is placed safely (over water the swim system floats them to the surface next frame).
		global_position.y = _ground_h() + GROUND_LIFT
		_land()
		_land_req = false
	_speed = 0.0
	_input = Vector2.ZERO
	velocity = Vector3.ZERO
	_stride_on(0.0, false)   # its legs given back as it stops (a stride left mid-swing stood that way parked)
	if _board == "instant":
		driving = false
		_state = S_IDLE
		_seated = false
		var driver := _driver
		_driver = null
		_unfollow(driver)
		if driver != null and is_instance_valid(driver):
			GPose.stand(driver)   # reverses a visible-seated instant board (no-op if never posed)
			_upright(driver)
			var spot := _exit_spot()
			_set_body_collision(driver, false)
			driver.global_position = spot
			driver.velocity = Vector3.ZERO
			driver.visible = true
		AudioManager.play_sfx("door")
		drive_state_changed.emit(self, false)
		return
	_state = S_EXITING
	_begin_exit_choreo()


# Fed by main._physics_process while this vehicle is active — the SAME input vector that walks the
# player (no second input path). Ground: x = steer, y = throttle (screen-up negative, like
# _keyboard_vec). Airborne: x = bank+yaw, y = pitch. Ignored (stored but never integrated)
# unless the state machine has reached DRIVING.
func drive_input(v: Vector2) -> void:
	_world_drive = false
	_input = v.normalized() if v.length() > 1.0 else v


# CONTRACT A (camera-relative desired-heading): main.gd feeds a WORLD XZ vector — the direction the
# player wants to go (forward = +Z), length = throttle 0..1. We turn the body toward that heading
# and drive forward, translating it into the SAME internal `_input` (steer, throttle) that
# drive_input feeds — so the ground/air integrators run UNCHANGED and the raw drive_input path (the
# verify harness) is untouched. Ground/water: steer toward atan2(x, z) at the profile turn rate
# (steer_fixed tanks rotate in place — sf=1 there), throttle = length. Airborne: bank+yaw toward the
# heading, hold level (a 2D world vector carries no climb). Near-zero -> COAST (hold heading + speed,
# no reverse, no snap-stop).
func drive_input_world(world_dir: Vector2) -> void:
	_world_drive = true
	var thr := clampf(world_dir.length(), 0.0, 1.0)
	if thr < 0.05:
		if _airborne:
			_air_thr = 0.4          # ease off the stick -> bleed toward a slow cruise (releasing SLOWS you)
			_input = Vector2.ZERO   # wings level
		else:
			# COAST DOWN, DO NOT HOLD SPEED. This used to set the target EQUAL to the current
			# speed, which on a phone joystick means "let go of the stick and keep going forever":
			# QA released at ~7 m/s and the truck coasted 385 m across the town and the moor to the
			# world corner, and in another run reversed off the quay and drove the SEA BED at
			# y -9.7 for 130 m before climbing back out. Release has to mean slow down.
			#
			# Decay toward zero rather than a hard brake, so momentum still reads as momentum:
			# COAST_DECAY of max_speed per second, which stops a car from full speed in ~1.7 s.
			var ms := float(PROFILES[profile]["max_speed"])
			var tgt := _speed - signf(_speed) * ms * COAST_DECAY * get_physics_process_delta_time()
			if signf(tgt) != signf(_speed):
				tgt = 0.0                       # crossed zero -> stop, never creep backwards
			_input = Vector2(0.0, -clampf(tgt / ms, -1.0, 1.0))
		return
	var want := atan2(world_dir.x, world_dir.y)          # +Z forward -> yaw = atan2(x, z)
	var err := wrapf(want - rotation.y, -PI, PI)
	if _airborne:
		# FLIGHT (no reverse): bank+yaw toward the heading; the SAME 2D stick also works throttle +
		# a gentle climb/descend, so the flyer can be sped up, slowed, and brought down without a
		# second input axis. rotation.y += -_input.x * rate, so a POSITIVE heading error needs _input.x < 0.
		var yaw_cmd := -clampf(err / HEADING_BAND, -1.0, 1.0)
		if absf(err) > REVERSE_ENTER:
			# stick pulled BEHIND the nose ("pull back / down") = SLOW DOWN + descend (arcade brake).
			_air_thr = 0.25
			_input = Vector2(yaw_cmd, 0.9)    # +y -> nose down -> lose altitude (steeper: pull-back now truly points the nose down instead of a shallow ~19°)
		else:
			# stick toward the nose = throttle up; a hard push also climbs a little.
			_air_thr = clampf(0.45 + thr * 0.55, 0.0, 1.0)
			_input = Vector2(yaw_cmd, -clampf((thr - 0.55) * 2.0, 0.0, 1.0) * 0.5)
		return
	# REVERSE vs forward (all ground/water rides + grounded mounts). Latch with hysteresis so the
	# choice can't chatter at the threshold. _drive_ground already integrates a negative _speed and
	# flips the steer sign in reverse for a real-car feel, so here we only pick throttle direction +
	# the steer TARGET (nose-onto-heading when forward, rear-onto-heading when reversing).
	if _rev_latch:
		if absf(err) < REVERSE_EXIT:
			_rev_latch = false
	elif absf(err) > REVERSE_ENTER:
		_rev_latch = true
	if _rev_latch:
		# BACK UP toward `want`: while reversing the nose points AWAY from travel, so the desired
		# facing is want - PI. Steer the nose onto that; +_input.y drives _speed negative = backward.
		var rev_err := wrapf(err - PI, -PI, PI)
		var rsteer := clampf(rev_err / HEADING_BAND, -1.0, 1.0)
		if bool(PROFILES[profile].get("steer_fixed", false)):
			rsteer = -rsteer   # tank turns in place (no reverse sf-flip) — use the forward-frame sign
		_input = Vector2(rsteer, thr)          # "turn and reverse" (rev_err!=0) or "just reverse" (~0)
	else:
		_input = Vector2(-clampf(err / HEADING_BAND, -1.0, 1.0), -thr)   # steer toward heading, forward


# Interaction-registry prompt text, re-read each query. Parked: "Ride <name>" / "Drive <name>".
# While driving (boarding included): "" — NO exit/dismount words anywhere; the USE button still
# exits because interaction routes by kind, not label, and interaction.gd renders no prompt for
# an empty label.
func prompt_label() -> String:
	if driving:
		return ""
	return ("Ride " if _is_mount else "Drive ") + display_name


# ---------------- enter/exit choreography (door / step-in / mount boards) ----------------

# Generalised Wave-2 sequence. Door segments only exist on the car (its _door_pivot); door-less
# boards (boat/plane step-in, mounts) run walk -> pose directly with a single boarding sfx.
func _begin_enter_choreo() -> void:
	_kill_seq()
	var d := _driver
	var beside := to_global(_board_local)   # on the ground beside the opening/cockpit/flank
	_seq = create_tween()
	# 1) door swings open (car only)
	if _door_pivot != null:
		_seq.tween_callback(func() -> void:
			AudioManager.play_sfx("door"))
		_seq.tween_property(_door_pivot, "rotation:y", deg_to_rad(DOOR_OPEN_DEG), DOOR_TIME).set_trans(Tween.TRANS_SINE)
	else:
		_seq.tween_callback(func() -> void:
			AudioManager.play_sfx("door"))   # one boarding thunk for door-less boards
	# 2) the driver visibly walks to beside the seat / saddle
	_seq.tween_property(d, "global_position", beside, WALK_TIME).set_trans(Tween.TRANS_SINE)
	# 3) aboard: snap onto the marker + GPose.sit / GPose.ride (or the Wave-1 hide fallback)
	_seq.tween_callback(_seat_driver)
	# 4) door swings closed (car only) -> driving enabled
	if _door_pivot != null:
		_seq.tween_callback(func() -> void:
			AudioManager.play_sfx("door"))
		_seq.tween_property(_door_pivot, "rotation:y", 0.0, DOOR_TIME).set_trans(Tween.TRANS_SINE)
	_seq.tween_callback(func() -> void:
		_state = S_DRIVING)


func _begin_exit_choreo() -> void:
	_kill_seq()
	var d := _driver
	var spot := _exit_spot()
	_seq = create_tween()
	# 1) door swings open (car only)
	if _door_pivot != null:
		_seq.tween_callback(func() -> void:
			AudioManager.play_sfx("door"))
		_seq.tween_property(_door_pivot, "rotation:y", deg_to_rad(DOOR_OPEN_DEG), DOOR_TIME).set_trans(Tween.TRANS_SINE)
	# 2) the driver stands (pose restored / unhidden — GPose.stand reverses sit AND ride, same
	#    meta) and visibly steps out/off to exit_side
	_seq.tween_callback(func() -> void:
		_seated = false
		_unfollow(d)
		_rider_hull(null)
		if d != null and is_instance_valid(d):
			GPose.stand(d)
			_upright(d)
			d.visible = true)
	if d != null and is_instance_valid(d):
		_seq.tween_property(d, "global_position", spot, WALK_TIME).set_trans(Tween.TRANS_SINE)
	# 3) door swings closed (car only) -> driver fully restored, control released
	if _door_pivot != null:
		_seq.tween_callback(func() -> void:
			AudioManager.play_sfx("door"))
		_seq.tween_property(_door_pivot, "rotation:y", 0.0, DOOR_TIME).set_trans(Tween.TRANS_SINE)
	_seq.tween_callback(func() -> void:
		_finish_exit(spot))


# Put the driver aboard: measure the rig's standing height FIRST (the pose changes the AABB),
# drop the character origin so the hips land on the marker, then pose. Seats use GPose.sit
# (hips sink slightly into the cushion); mounts use GPose.ride (astride) and set the rider's DRAWN
# SEAT on the marker — the saddle's top (_rider_off) — and the rider then rides the back the mount
# draws (_follow_start). A false return (capsule / unrecognized rig): cabin vehicles hide the driver
# (Wave-1 fallback); MOUNTS keep the rider VISIBLE, perched on the MountMarker (rider-always-visible
# contract).
func _seat_driver() -> void:
	var d := _driver
	if d == null or not is_instance_valid(d):
		return
	# Measure the driver the same way main.gd sized it — bones UNIONED WITH THE MESH ENVELOPE. The old
	# bone-span-only read was the same mistake main.gd made: it stops at the head BONE (the neck), so
	# a stylized rig under-read by nearly half and every derived offset below was computed from a
	# height the character does not have. Fall back to the mesh AABB for an unrigged capsule, then to
	# 1.7 as a last resort.
	var dh := GPose.char_height(d)
	if dh < 0.5:
		dh = GPose.drawn_aabb(d).size.y
	if dh < 0.5:
		dh = 1.7
	# Where this rig's hips actually are, not a ratio of its height. One constant cannot fit both a
	# realistic humanoid (hips at ~0.52 of height) and a KayKit chibi (0.178) — using the realistic
	# figure on a chibi drops it half a metre through the cabin floor.
	var hips := GPose.hips_height(d)
	if hips <= 0.0:
		hips = HIP_RATIO * dh
	if _is_mount:
		_fit = _fit_legs(d, Transform3D.IDENTITY)
		_seated = _pose_rider(d, _fit)
		_seat_off = _rider_off(d, Transform3D.IDENTITY, hips) if _seated else Vector3.ZERO
	else:
		_seat_off = Vector3(0.0, 0.06 - hips, 0.0)   # seated: hips just above the cushion (+0.06 sink)
		_seated = GPose.sit(d)
		# CLOSED-CAB CLEARANCE. Posing succeeded, but posing does not make the driver FIT: what has
		# to clear the roof is the span from the hips to the crown, and on a chibi rig that is 1.36 m
		# against a sedan's 0.95 m. Rather than post a head through the roof — the shipped bug —
		# take the same hidden-driver path an unposeable rig takes. Cabin vehicles have somewhere to
		# hide; mounts do not, which is why this is in the else branch only.
		if _seated and _cabin_headroom < INF and (dh - hips) > _cabin_headroom:
			_seated = false
			GPose.stand(d)   # undo the seated pose we just applied, or it rides hidden AND folded
	if not _seated:
		if _is_mount:
			# CONTRACT: a mount's rider is ALWAYS visible — there is no cabin
			# to hide in, and an invisible rider reads as a riderless horse.
			# Capsule/unposeable rigs PERCH visibly on the MountMarker instead
			# (same graceful degrade as the furniture seat).
			_seat_off = Vector3.ZERO
		else:
			d.visible = false
			_seat_off = Vector3.ZERO
	_track_driver()   # snap onto the marker (or origin) immediately; _drive re-parks every tick
	if _is_mount:
		_follow_start(d, true)
		_rider_hull(d)


## Pose a rider astride (GPose.ride) in the ride pose `fit` of GPose.RIDE_FITS — or a body of parts (a Kenney figure) in its
## own sit (GPose.sit_parts, decision S4) — true when posed.
func _pose_rider(d: Node3D, fit: int) -> bool:
	var f: Vector2 = GPose.RIDE_FITS[clampi(fit, 0, GPose.RIDE_FITS.size() - 1)]
	return GPose.ride(d, f.x, f.y) or GPose.sit_parts(d)


const LEG_IN := 0.03   # metres of a rider's leg a fitted ride pose may hold inside the mount (a calf pressed to a flank)
static var leg_fits := 0   # ride poses fitted to a mount's back (_fit_legs): once per rider and mount model, never per boarding


## THE RIDER'S LEGS OUTSIDE THE MOUNT'S BODY (decision S5): the first ride pose of GPose.RIDE_FITS — the ride's own, then wider
## and straighter — whose legs, as the rider draws them in it (GPose.rider_seat's leg points, from their seat on the marker),
## lie outside what the mount draws round its saddle (GPose.mount_seat's body), none deeper in than LEG_IN. The ride's own
## 40 deg spread and 90 deg knee put 23-71% of a rider's leg into the default cow, a pig or a T-rex, up to 0.40 m deep. WITH
## NONE, the pose with the fewest leg points deeper in than LEG_IN (then the least deep): by the deepest point alone the
## stegosaurus took the ride's own pose, 35% of kk_Knight's leg flesh 0.38 m into it, over one with 14% (step 5b's review,
## legs2 — a single sampled point said 0.175 m there). `xf` maps the rider's own frame into the frame they ride in (the driver's:
## identity; a peer's avatar: its transform under the body netsync moves). 0 (the ride's own) for a rider with no seat measured
## or a mount with no body read round its saddle. ONCE per rider model and size and mount model, size and saddle: held on the
## mount's seat answer, which every copy of it shares — fitted at every boarding it was 0.4-2.4 ms of that frame (desktop,
## 7.9 the worst), on every client for every peer who got on (step 5b's review, pcost2).
func _fit_legs(d: Node3D, xf: Transform3D) -> int:
	var m := GPose.rider_seat(d)
	var sk := GPose.skeleton_of(d)
	if not bool(m.get("ok", false)) or sk == null or not _seat.has("body") or _mount_marker == null:
		return 0
	var body: Dictionary = _seat["body"]
	var xs := (xf * GPose.xf_to(sk, d)).basis
	var mx := _seat_xf()
	var inv := mx.affine_inverse()
	var k := mx.basis.get_scale().x
	var at := _vis_rest * _mount_marker.position   # where their seat rests, self frame
	var memo: Dictionary = _seat.get("fits", {})
	var key := str([m.get("id", ""), xs, at, mx])
	if memo.has(key):
		return int(memo[key])
	leg_fits += 1
	var best := 0
	var least := [INF, INF]   # [its leg points deeper in than LEG_IN, its deepest]
	for f in GPose.RIDE_FITS.size():
		var deep := 0.0
		var n_in := 0
		for v in (m["legs"][f] as PackedVector3Array):
			var dd := _body_depth(body, inv * (at + xs * v)) * k
			deep = maxf(deep, dd)
			n_in += 1 if dd > LEG_IN else 0
		if deep <= LEG_IN:
			best = f
			break
		if n_in < least[0] or (n_in == least[0] and deep < least[1]):
			least = [n_in, deep]
			best = f
	memo[key] = best
	_seat["fits"] = memo
	return best


# How deep in the body round the seat (GPose.mount_seat's) a point of the model's frame is: 0 outside it, else to the nearer
# surface on the line through it. Inside = an odd number of its surfaces on that line above the point AND below it: a closed
# body is crossed an odd number of times each way from a point in it, and a sheet drawn as one surface (a wing, a fin) on one
# side only is never called body. (On the library's mounts and four riders, above-only parity picked the same pose
# everywhere — step 5b's review, RT05 — so this is the rule's own reason, not a measured repair.)
static func _body_depth(body: Dictionary, p: Vector3) -> float:
	var n := int(body["n"])
	var st := float(body["step"])
	var i := roundi((p.x - float(body["x"])) / st)
	var r := roundi((p.z - float(body["z"])) / st)
	if absi(i) > n or absi(r) > n:
		return 0.0
	var ys: PackedFloat32Array = (body["ys"] as Array)[(r + n) * (2 * n + 1) + i + n]
	var above := 0
	var below := 0
	var up := INF
	var down := INF
	for y in ys:
		if y > p.y:
			above += 1
			up = minf(up, y - p.y)
		else:
			below += 1
			down = minf(down, p.y - y)
	return minf(up, down) if above % 2 == 1 and below % 2 == 1 else 0.0


## WHERE A POSED RIDER'S ORIGIN GOES OFF THE MARKER, in the frame `xf` maps their own into (identity: the driver's own; an
## avatar's transform: the peer body netsync moves): minus their drawn seat (GPose.seat_point), so that seat — not their pelvis
## bone, and not a coat's hem — rests on the saddle. The pelvis bone and a constant (0.12 m) sat the eleven heroes 0.09-0.27 m
## off what they draw, 0.34 m apart on one marker. A rig with no seat to measure (posed by its bone names alone): its hips
## 0.12 m over the marker, as before.
func _rider_off(d: Node3D, xf: Transform3D, hips: float) -> Vector3:
	var sp := GPose.seat_point(d, _fit)
	if not sp.is_finite():
		sp = GPose.parts_seat(d)   # a body of parts in its own sit
	if sp.is_finite():
		return -(xf * sp)
	return Vector3(0.0, 0.12 - hips, 0.0)


# ── THE RIDER RIDES THE BACK IT DRAWS (C'', decision S2) ─────────────────────────────────────────────────────────────────
# The rider's BODY stays still on the seat as measured: the wire, the camera, streaming, shots and the hull read the body.
# What is DRAWN moves: every rendered frame, after the mount's own AnimationPlayer has posed it (FOLLOW_PRIORITY), the
# anchored point of its back (GPose.anchor_now: three vertices re-skinned) moved off its rest moves the rider's root bones
# by as much — and the saddle. Skeleton poses are drawn as set, never interpolated, so the rider lands in the frame the back
# does: the gap flat at 6-8 cm through the horse's, cow's, raptor's and T-rex's gaits, the camera within 3 mm, a peer's copy
# of the mount on the ground (seats review, rr_r_30). The body moved instead, in the physics step, read the frame before's
# pose: the gap swung -2..+16 cm at a raptor's run, the camera heaved 22 cm and peers' copies sank 28 cm into the ground.
# A rider with no skeleton (a body of parts) is moved as a node, uninterpolated while it rides: a node set in a frame is
# drawn in it (Godot 4.7's interpolation re-reads what moved during a frame at its end).

## Start following for `who` (`body`: the local driver — a CharacterBody3D whose visuals hang under it; else a peer's avatar).
func _follow_start(who: Node3D, body: bool) -> void:
	_unfollow(who)
	if _seat.is_empty() or who == null or not is_instance_valid(who):
		return
	var e := {"rider": who, "skel": null}
	var sk := GPose.skeleton_of(who)
	if sk != null:
		var roots := sk.get_parentless_bones()
		var rest := PackedVector3Array()
		for r in roots:
			rest.append(sk.get_bone_pose_position(r))
		e["skel"] = sk
		e["roots"] = roots
		e["rest"] = rest
	else:
		var nodes: Array = []
		for c in (who.get_children() if body else [who]):
			if c is Node3D and not (c is CollisionShape3D):
				nodes.append(c)
		var npos := PackedVector3Array()
		var modes: Array = []
		for n in nodes:
			npos.append((n as Node3D).position)
			modes.append((n as Node).physics_interpolation_mode)
			(n as Node).physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		e["nodes"] = nodes
		e["npos"] = npos
		e["modes"] = modes
	_follow.append(e)
	set_process(true)


## Stop following `who` (null: everyone): what the follow moved goes back where it found it — the root bones before the pose
## is given back (GPose.stand restores rotations only, and a clip without root tracks left the rider moved for good).
func _unfollow(who: Variant) -> void:
	for i in range(_follow.size() - 1, -1, -1):
		var e: Dictionary = _follow[i]
		if who != null and e["rider"] != who:
			continue
		var sk = e.get("skel")
		if sk != null and is_instance_valid(sk) and sk is Skeleton3D:
			var roots: PackedInt32Array = e["roots"]
			for j in roots.size():
				(sk as Skeleton3D).set_bone_pose_position(roots[j], (e["rest"] as PackedVector3Array)[j])
		for j in (e.get("nodes", []) as Array).size():
			var n = e["nodes"][j]
			if n != null and is_instance_valid(n) and n is Node3D:
				(n as Node3D).position = (e["npos"] as PackedVector3Array)[j]
				(n as Node).physics_interpolation_mode = e["modes"][j]
				(n as Node3D).reset_physics_interpolation()
		_follow.remove_at(i)
	if _follow.is_empty():
		set_process(false)
		if _saddle != null and is_instance_valid(_saddle):
			_saddle.position = _saddle_rest


func _process(delta: float) -> void:
	if _remote_rider != null and is_instance_valid(_remote_rider):
		_remote_speed(delta)
	if _striding and _feet != null:
		# this frame's stride (_stride_on): on by the ground it covers in the frame, drawn before its feet are worked out on it
		_stride += delta * _stride_v / maxf(deg_to_rad(GPose.WALK_THIGH_DEG) * _feet.shortest, 0.1)
		GPose.walk(_visual, _stride)
	if _feet != null:
		_feet.prepare(delta)   # this frame's crouch, before the rider rides it
	_follow_seat()


## ONE RENDERED FRAME OF THE FOLLOW: the anchored back's move off its rest, onto the saddle and every rider (_follow).
func _follow_seat() -> void:
	if _seat.is_empty() or _visual == null:
		return
	var a: Dictionary = _seat["anchor"]
	var dm := GPose.anchor_now(_seat_skel, a) - (a["rest"] as Vector3)   # the model's frame
	if _feet != null and _feet.crouch > 0.0:
		# ...and down its feet's crouch, which moves only what it draws (GFeet): its rider and saddle ride it down
		dm += _vis_rest.basis.inverse() * Vector3(0.0, -_feet.crouch * _feet.influence, 0.0)
	if _saddle != null and is_instance_valid(_saddle) and _saddle.get_parent() == _visual:
		_saddle.position = _saddle_rest + dm
	if _follow.is_empty():
		return
	var dw := get_global_transform_interpolated().basis * (_visual.transform.basis * dm)   # as the world draws it
	for e in _follow:
		var who = e["rider"]
		if who == null or not is_instance_valid(who):
			continue
		var sk = e.get("skel")
		if sk != null:
			if is_instance_valid(sk):
				var dsk: Vector3 = (sk as Skeleton3D).get_global_transform_interpolated().basis.inverse() * dw
				var roots: PackedInt32Array = e["roots"]
				for j in roots.size():
					(sk as Skeleton3D).set_bone_pose_position(roots[j], (e["rest"] as PackedVector3Array)[j] + dsk)
		else:
			var nodes: Array = e["nodes"]
			for j in nodes.size():
				var n = nodes[j]
				if n != null and is_instance_valid(n) and (n as Node).get_parent() is Node3D:
					var pb := ((n as Node).get_parent() as Node3D).get_global_transform_interpolated().basis
					(n as Node3D).position = (e["npos"] as PackedVector3Array)[j] + pb.inverse() * dw


## THE RIDER'S TOP IS THE HULL'S WHILE THEY RIDE (a ridden mount is its rider's body when attacked: their own colliders are off
## aboard, _set_body_collision): the hull rises to the top of what they draw in the pose they ride in (_sync_hull: and as high
## as the back they ride lifts them) — on the default cow 55% of a rider sat above the hull, and a shot at their head met
## nothing (seats review). ONLY ITS TOP: across and along it stays the mount's own, so a ridden mount passes where it passes
## riderless. Grown to the rider's whole box (the legs of every ride pose, the gait's reach every way) a ridden horse was
## 1.94-2.10 m wide against its own 1.04, 0.18-0.41 m a side past anything horse or rider drew, and stopped at gaps 1.3-2.0 m
## wide both fit through (step 5b's review, pgap: 10 of 24 rides). `d` gone: the hull is the mount's again.
func _rider_hull(d: Node3D) -> void:
	_rider_top = -INF
	_rider_top_air = -INF
	if d != null and is_instance_valid(d) and _mount_marker != null and _seated:
		var box := AABB()
		var m := GPose.rider_seat(d)
		var sk := GPose.skeleton_of(d)
		if bool(m.get("ok", false)) and sk != null:
			var boxes: Array = m["boxes"]
			box = GPose.xf_to(sk, d) * (boxes[clampi(_fit, 0, boxes.size() - 1)] as AABB)   # the pose they ride in
		else:
			for c in d.get_children():   # a body of parts: what its visible parts draw in its sit
				if c is Node3D and (c as Node3D).visible and not (c is CollisionShape3D):
					var b := GPose.drawn_aabb(c as Node3D)
					box = b if box.size == Vector3.ZERO else box.merge(b)
		if box.size != Vector3.ZERO:
			box.position += _vis_rest * _mount_marker.position + _seat_off   # their origin sits _seat_off off the marker
			_rider_top = box.end.y
			_rider_top_air = _rider_top
			if not _gaited:
				# ...and a mount with no move clip of its own rocks them RIDE_PITCH_DEG about its origin and bobs them RIDE_BOB_AMP
				# up as it walks (_update_ride_motion, F1)
				for a in [-1.0, 1.0]:
					_rider_top = maxf(_rider_top, (Transform3D(Basis(Vector3.RIGHT, a * deg_to_rad(RIDE_PITCH_DEG)), Vector3.ZERO) * box).end.y)
				_rider_top += RIDE_BOB_AMP
	_sync_hull()


## WHERE A RIDER STEPS OFF: beside the body, EXIT_CLEAR outside the hull (never nearer than the profile's exit_side),
## on a side with room for them — a player's capsule there overlapping nothing solid, and no wall between the hull and
## it (_clear_to_stand). The +x side first (the driver's door, where every rider has always stepped off), then -x, the
## nose and the tail; none clear: the +x side, as it always was. exit_side alone put the default dragon's rider 0.25 m
## inside its own hull, and stepped anyone off a mount parked beside a wall into the wall.
func _exit_spot() -> Vector3:
	var first := Vector3.INF
	for dl in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		# how far the hull reaches from the origin that way
		var ext: float = (_body_ab.end.x if dl.x > 0.0 else -_body_ab.position.x) if dl.x != 0.0 \
			else (_body_ab.end.z if dl.z > 0.0 else -_body_ab.position.z)
		var spot: Vector3 = global_position + (global_transform.basis * dl).normalized() \
			* maxf(float(PROFILES[profile]["exit_side"]), ext + EXIT_CLEAR)
		spot.y = _exit_floor_y(spot.x, spot.z)
		if not first.is_finite():
			first = spot
		if _clear_to_stand(spot):
			return spot
	return first


# THE FLOOR A RIDER STEPS OFF ONTO at x, z (+ 0.1): the ground (_exit_ground_y — the terrain, or the water a boat or a
# ditched flyer floats on), or anything walkable standing on it within EXIT_STEP — a pier's deck, a kerb, a stair. Taken
# from the ground alone, a rider getting off a boat moored 0.3 m off a pier was set down in the water beside it, the
# capsule there overlapping the pier, which _clear_to_stand reads as a wall: the boat's far side, into the water (y -0.93;
# e03f847 had them pushed up onto the deck, y 0.79), and a car's, a tank's or a horse's beside a 0.25 m kerb or a 0.6 m
# step likewise on the far side (behaviour review). A ray down from EXIT_STEP over the ground: a face it meets turned up
# (normal y > 0.7) is the floor. A wall's top higher than that — or the spot inside a wall, which a ray starting in a body
# does not report — leaves the ground, and the capsule then finds the wall.
func _exit_floor_y(x: float, z: float) -> float:
	var gy := _exit_ground_y(x, z)
	if not is_inside_tree():
		return gy + 0.1
	var ray := PhysicsRayQueryParameters3D.create(Vector3(x, gy + EXIT_STEP, z), Vector3(x, gy - 0.05, z), 1, _stand_exclude())
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if not hit.is_empty() and (hit["normal"] as Vector3).y > 0.7:
		return maxf(gy, (hit["position"] as Vector3).y) + 0.1
	return gy + 0.1


# What a rider stepping off is never stopped by: this body, the rider, the car's door leaf and the terrain (the ground
# they stand on is _exit_ground_y's).
func _stand_exclude() -> Array[RID]:
	var ex: Array[RID] = [get_rid()]
	if _driver != null and is_instance_valid(_driver):
		ex.append(_driver.get_rid())
	if _door_body != null and is_instance_valid(_door_body):
		ex.append(_door_body.get_rid())
	for n in get_tree().get_nodes_in_group("gogi_terrain"):
		if n is CollisionObject3D:
			ex.append((n as CollisionObject3D).get_rid())
	return ex


# Can a person stand with their feet at `spot` and step there off the hull? main.gd's player capsule (r 0.4, 1.6 m,
# centred 0.85 m up) overlapping nothing on the world layer — walls, props, another vehicle; never the terrain they stand
# on — and nothing on the line from the hull's middle to them at hip height (a wall the spot is clear beyond).
func _clear_to_stand(spot: Vector3) -> bool:
	if not is_inside_tree():
		return true
	var space := get_world_3d().direct_space_state
	var ex := _stand_exclude()
	var q := PhysicsShapeQueryParameters3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.6
	q.shape = cap
	q.transform = Transform3D(Basis(), spot + Vector3(0.0, 0.85, 0.0))
	q.collision_mask = 1
	q.exclude = ex
	if not space.intersect_shape(q, 1).is_empty():
		return false
	var c := _body_ab.get_center()
	var hip := Vector3(0.0, 1.0, 0.0)
	var ray := PhysicsRayQueryParameters3D.create(global_transform * Vector3(c.x, 0.0, c.z) + hip, spot + hip, 1, ex)
	return space.intersect_ray(ray).is_empty()


# Final exit bookkeeping — the driver is standing at `spot`, solid, visible; the body is parked.
func _finish_exit(spot: Vector3) -> void:
	var d := _driver
	_driver = null
	_seated = false
	if d != null and is_instance_valid(d):
		_set_body_collision(d, false)
		d.global_position = spot
		d.velocity = Vector3.ZERO
		d.visible = true
	_set_door_blocking(true)   # parked + closed -> the leaf blocks again (no-op without a door)
	driving = false
	_state = S_IDLE
	drive_state_changed.emit(self, false)


# HOT-RELOAD SAFETY NET: main.gd calls exit() then frees rebuilt vehicles — if the free lands
# mid-choreography (exit() mid-ENTER is a guarded no-op), mid-drive, or MID-FLIGHT (exit() while
# airborne is a guarded no-op too), the vehicle-bound tweens die with this node. Restore the
# DRIVER synchronously — pose, visibility, collision, and a position at TERRAIN height — so a
# chat edit can never strand a hidden, posed, collision-less or floating player. (Also covers
# any future non-exit() free path.)
func _exit_tree() -> void:
	_unfollow(null)   # every rider's drawn body back where the follow found it (a peer's too: this mount is going)
	if _state == S_IDLE:
		return
	_kill_seq()
	var d := _driver
	_driver = null
	_state = S_IDLE
	driving = false
	_seated = false
	_airborne = false
	_leaving = false
	_land_req = false
	if d != null and is_instance_valid(d):
		GPose.stand(d)
		_upright(d)
		_set_body_collision(d, false)
		d.global_position = _exit_spot()
		d.velocity = Vector3.ZERO
		d.visible = true
	drive_state_changed.emit(self, false)


func _kill_seq() -> void:
	if _seq != null and _seq.is_valid():
		_seq.kill()
	_seq = null


# The car door leaf's blocking collider: solid ONLY when parked with the door closed. Disabled
# while open (walk through the opening) and while entering/driving/exiting (the body's own box
# collider already covers the closed door, and a live child StaticBody would jam the camera
# SpringArm). No-op for door-less bodies.
func _set_door_blocking(on: bool) -> void:
	if _door_shape != null:
		_door_shape.disabled = not on


# ---------------- mount gait sync (embedded clips only) ----------------

# Drive the mount's own AnimationPlayer from the motion state. Ground: move clip while
# |speed| > 0.5 with speed_scale = clamp(speed/6, 0.6, 2.2) (gallop/run above 55% of max when
# the model carries one, else walk), idle when stopped/parked. Airborne (dragon): FLAP while
# climbing/accelerating, GLIDE when level/descending. Any missing clip is "" -> _play_clip
# no-ops -> a clipless creature rides silently (pinned degrade).
func _update_gait() -> void:
	if _state == S_DRIVING:
		_play_gait(_speed, _airborne, _pitch > deg_to_rad(3.0) or _speed < SPEED_MAX * 0.6)
	else:
		_play_gait(0.0, false, false)


# The clip a ridden mount shows going `speed` m/s along its heading — in the air (`air`) flapping while it `climbs`, gliding
# when not — and its rate: its own rider's (_update_gait) and a peer's copy of it (_remote_gait) alike.
func _play_gait(speed: float, air: bool, climbs: bool) -> void:
	if _gait_ap == null:
		return
	if air:
		var air_clip := _clip_flap if climbs else _clip_glide
		if air_clip == "":
			air_clip = _clip_flap if _clip_flap != "" else _clip_glide   # whichever exists
		if air_clip == "":
			air_clip = _clip_any   # no named air clip -> longest available beats a frozen flight (2.4)
		_play_clip(air_clip, 1.0)
		return
	if absf(speed) > GAIT_MOVE_MIN:
		var mv := _clip_walk
		if _clip_fast != "" and absf(speed) > float(PROFILES[profile]["max_speed"]) * GAIT_FAST_FRAC:
			mv = _clip_fast
		if mv == "":
			mv = _clip_fast   # only a gallop/run clip shipped — better than freezing
		if mv == "":
			mv = _clip_any    # nothing name-matched -> longest rigged clip, never a frozen walk (2.4)
		_play_clip(mv, clampf(absf(speed) / 6.0, 0.6, 2.2))
		return
	_play_clip(_clip_idle, 1.0)


## A PEER'S MOUNT WALKS AS THEY RIDE IT. On their own screen it plays the gait their speed asks for (_update_gait); on every
## other screen netsync only places it under them (place_under_remote_rider), and the parked tick that plays a mount's clips
## does not run for it — so a peer's horse slid across the ground in its idle at a gallop. The copy plays the same gait at the
## speed netsync moves it (_remote_speed), in the air flapping while it climbs (as its rider's own: pitched up past 3 deg, or
## under 60% of top speed).
func _remote_gait(_delta: float) -> void:
	var sp := Vector2(_remote_v.x, _remote_v.z).length()
	_play_gait(sp, _airborne, _remote_v.y > sp * sin(deg_to_rad(3.0)) or sp < SPEED_MAX * 0.6)
	_stride_on(sp if sp > RIDE_MOVE_MIN and not _gaited else 0.0, _wheel_ground())


## How fast netsync moves a peer's mount: where it put it this rendered frame against the last (its _process places it, before
## this one's: FOLLOW_PRIORITY), smoothed over REMOTE_GAIT_TAU (a frame that placed it twice or not at all is no stop and no
## leap) — and a teleport or a rejoin (REMOTE_JUMP in a frame) is no motion: the frame goes as far as it was seen going (read
## as motion, a 20 m teleport went into the smoothing at 600-1200 m/s and the copy galloped for 0.6 s after a respawn: step 5d's
## review). Read a physics tick at a time, a frame that ran two ticks read one with all its motion and one with none: the copy
## strode 6% slower than the owner, 15% after a teleport (step 5d's fix round).
func _remote_speed(delta: float) -> void:
	var p := global_position
	var d := p - _remote_was
	_remote_was = p
	if delta > 0.0:
		if d.length() > REMOTE_JUMP:
			d = _remote_v * delta
		_remote_v = _remote_v.lerp(d / delta, 1.0 - exp(-delta / REMOTE_GAIT_TAU))


# Play a clip if it isn't already playing (the WanderAgent._play idiom: force looping so gaits
# cycle) and set the playback rate. No player -> silent no-op. EVERY CLIP SHOWS OVER THE REST POSE,
# the pose its hull was fitted from (the hull is rest + the clips of the state, each from rest:
# _sync_hull) — never over what the last clip left on the bones it does not key: mire_dragon's idle
# after a walk held a foot 0.115 m under its feet, into the ground it parked on. "" — the state has
# no clip — is the rest pose itself, not whatever the last state left looping: a monster_Dragon kept
# beating its wings on the ground after a flight, wider and taller than the box it walks in.
func _play_clip(clip: String, rate: float) -> void:
	if _gait_ap == null:
		return
	if clip == "":
		if _gait_ap.is_playing():
			_gait_ap.stop()
			_rest_bones()
		return
	_gait_ap.speed_scale = rate
	if _gait_ap.current_animation != clip:
		var a := _gait_ap.get_animation(clip)
		if a != null:
			a.loop_mode = Animation.LOOP_LINEAR
		_rest_bones()
		_gait_ap.play(clip)


func _rest_bones() -> void:
	for sk in (_visual if _visual != null else _gait_ap.get_parent()).find_children("*", "Skeleton3D", true, false):
		(sk as Skeleton3D).reset_bone_poses()


func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n as AnimationPlayer
	for c in n.get_children():
		var r := _find_anim(c)
		if r != null:
			return r
	return null


# ---------------- internals ----------------

# Silence the rider's colliders while aboard and make the two bodies mutually PASS THROUGH each
# other, so the physics solver can never depenetrate a seated rider back out of the hull ("character
# pops out of the vehicle"). Two-part fix: (1) disable every CollisionShape3D on the rider
# RECURSIVELY — a rigged avatar nests its shape under the model, not as a direct child, so the old
# direct-children-only loop missed it and left the rider solid; (2) a mutual collision exception
# (mirrors the door safeguard at enter/exit). Paired: off=true on board (disable + add exception),
# off=false on exit (re-enable + drop exception). Every caller passes the DRIVER.
func _set_body_collision(rider: Node, off: bool) -> void:
	_disable_shapes_recursive(rider, off)
	if rider is CollisionObject3D:
		var co := rider as CollisionObject3D
		if off:
			add_collision_exception_with(co)
			co.add_collision_exception_with(self)
		else:
			remove_collision_exception_with(co)
			co.remove_collision_exception_with(self)


func _disable_shapes_recursive(n: Node, off: bool) -> void:
	if n is CollisionShape3D:
		(n as CollisionShape3D).disabled = off
	for c in n.get_children():
		_disable_shapes_recursive(c, off)


# Floating prompt: DRIVE/RIDE when the player is within reach of the PARKED body; hidden while
# driving/riding (no floating EXIT/DISMOUNT words over the ride — USE is the exit control) and
# during the enter/exit choreography (USE is a no-op then anyway).
func _update_label() -> void:
	if _label == null:
		return
	if _state == S_ENTERING or _state == S_EXITING:
		_label.visible = false
		return
	if driving:
		_label.visible = false
		return
	_label.text = "RIDE" if _is_mount else "DRIVE"
	if player_ref == null or not is_instance_valid(player_ref):
		_label.visible = false
		return
	# Measure to the CLOSEST POINT on the body hull, not the node origin: on a 4 m body a player
	# touching the bumper is > PROMPT_RANGE from the origin but inches from the hull. The distance USE
	# measures (interaction._nearest), so the cue never shows where USE does nothing. Hysteresis
	# (show < PROMPT_RANGE / hide > PROMPT_HIDE) keeps an edge-hover from flickering the cue.
	var d := hull_distance(player_ref.global_position)
	if _label.visible:
		_label.visible = d < PROMPT_HIDE
	else:
		_label.visible = d < PROMPT_RANGE


## THE POINT OF THE HULL CLOSEST TO `world_pos` — what the RIDE/DRIVE label and USE both measure to, for every vehicle
## (decision 20; USE: interaction._nearest). USE measured from the ORIGIN less half the profile length: a car's reached
## 4.38 m out of its side, 0.70 m past where its label went out, and stopped 0.42 m short of its nose with the label still
## up; a drawn cow's failed 1.0 m off its nose and the default dragon's 1.0 m off its flank with RIDE showing (mount-hulls
## investigation, through the real _nearest). The box is stored in the vehicle's LOCAL frame: the query point comes into
## it, is clamped per axis, and goes back out — a cheap analytic closest point, no physics query, exact because the body
## root is yaw-only (flight pitch/roll ride _visual).
func closest_hull_point(world_pos: Vector3) -> Vector3:
	var local := global_transform.affine_inverse() * world_pos
	var clamped := Vector3(
		clampf(local.x, _body_ab.position.x, _body_ab.end.x),
		clampf(local.y, _body_ab.position.y, _body_ab.end.y),
		clampf(local.z, _body_ab.position.z, _body_ab.end.z))
	return global_transform * clamped


## How far `world_pos` is from the hull (0 inside it): the label's distance and USE's.
func hull_distance(world_pos: Vector3) -> float:
	return world_pos.distance_to(closest_hull_point(world_pos))


# The horizontal (xz) distance from a world point to the hull: the mount cull's (a ground-level measure of how far
# away a creature stands, whatever height the player looks from).
func _hull_xz_distance(world_pos: Vector3) -> float:
	var closest := closest_hull_point(world_pos)
	return Vector2(world_pos.x - closest.x, world_pos.z - closest.z).length()
