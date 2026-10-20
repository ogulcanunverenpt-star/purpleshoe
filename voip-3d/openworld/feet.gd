class_name GFeet extends SkeletonModifier3D
## FEET ON THE GROUND — a mount's legs, solved after its clip has posed them, each foot onto the ground under it.
##
## A ridden animal is one rigid body on four points (Vehicle._wheel_step: the plane through its tyres), and its walk clip
## moves its legs for flat ground under that body. Wherever the ground under the footprint is not one plane every hoof is
## off it by however far the ground there leaves the plane: over a +-16.7 deg crest the horse's hooves sank 0.12 m and
## floated 0.14, the cow's 0.20 / 0.28; over a +-25 deg one 0.22 / 0.38; in a hollow 0.09 / 0.14 (step 5c, as drawn, the
## rock already gone from a mount that walks on its own legs: followups3 hoof-crest's figures with it were 0.10-0.32 / 0.19-
## 0.49); the default dragon's feet hung 0.25 m over a crest and 0.49 in a hollow.
##
## WHAT IT DOES, every rendered frame, in the frame the animal is DRAWN in (physics interpolation draws the mesh between two
## physics ticks: solved in the physics tick's frame a galloping horse's hooves were 6 cm in over a crest, 0.7 cm drawn — the
## hoof-crest review):
##   - each foot is raised or lowered by however far the ground under its soles (GRig.legs: the extremes of its underside,
##     drawn as the skin draws them) is off the body's own ground plane, KEEPING THE CLIP'S LIFT — how high the clip carries
##     it over that plane (a foot the clip draws under its own ground is held on it);
##   - its leg (upper, lower) is solved as two bones onto it, the knee kept in the plane the clip bent it in, the foot in the
##     clip's own orientation — or, where the lower leg carries the foot's skin (a Rig Lab dragon's), the lower leg onto it
##     and the foot riding it;
##   - where a planted foot cannot reach the ground the drawn body CROUCHES (its root bones down along its ground's up) — at
##     CROUCH_RATE, at most CROUCH_MAX of its shortest leg, and never so far its head, belly or tail goes into the ground (the
##     host's keel clearance: what it draws without its legs, Vehicle._keel_clearance). Uncapped, a triceratops crouched its
##     head 0.545 m into a hollow (hoof-crest). The crouch moves only what is drawn: the host rides its rider down it
##     (Vehicle._follow_seat) and lowers its hull's top by it; the body, the camera and what goes over the wire stay where the
##     ground model put them;
##   - OFF in the air and on the water (the host decides: Vehicle._feet_want), its influence eased in and out over 0.2 s:
##     left on, it pulled a flying default dragon's feet 0.50 m off its flap and crouched it 0.39 m (hoof-crest review).
## A SkeletonModifier3D: what it sets is drawn and put back after the skin, so nothing else ever reads its poses (an oracle
## does through a modifier after it).
##
## COST (desktop, GDScript): 48-49 us a frame for the horse, 43-45 for the cow, 25 for the default dragon — prepare and solve:
## the soles skinned, the ground read under each, the legs solved (hoof-crest's prototype took 40-67). Timed wherever each half
## runs: counted in the modifier alone it read 7.8-11 us while the frame took 50-68 (step 5c's review: the host prepares first,
## outside its timer), 35-59 of it the crouch's cap reading the ground under the keel every frame that wanted a crouch, which
## now comes from the ground model's own reads (Vehicle._keel_clearance). The drive rig's footing (f12) counts it: one prepare
## and one solve a frame, every prepare timed, a ground read a sole, none under the keel when ridden. On a phone the GOGI_PERF
## lines say (Vehicle._perf_line).

const LIFT_PLANTED := 0.04   # m: a foot the clip carries less than this over its ground is planted — the crouch serves it
const CROUCH_RATE := 2.0     # m/s the drawn body crouches into what a planted foot cannot reach, or rises back
const CROUCH_MAX := 0.35     # ...at most this share of its shortest leg
const RAMP := 5.0            # 1/s: how fast it comes on and lets go (a landing, a take-off, the water: 0.2 s)

static var frames := 0       # frames it has solved, every GFeet ever (the drive rig's cost group) ...
static var spent_us := 0     # ...what they took, prepare and solve alike ...
static var timed := 0        # ...the prepares whose time is in it (every one) ...
static var reads := 0        # ...the ground read under its soles (one a sole a frame) ...
static var keel_reads := 0   # ...and under what it rests on, for the crouch's cap (Vehicle._keel_clearance)

var host: Vehicle = null
var legs: Array = []         # [{upper, lower, foot, carried, end, soles (GRig's: as the skin draws them), bend}]
var want := false            # the host's: plant the feet (it eases `influence` toward this)
var crouch := 0.0            # m the drawn body is down this frame, along its ground's up (the host rides its rider down it)
var shortest := 0.0          # m: the shortest leg
var us := 0                  # what this one's frames took since the host last read it, prepare and solve, and how many
var n := 0                   # (GOGI_PERF)
var _frame := -1             # the process frame _prepare ran in: its targets serve that frame
var _targets: Array = []     # per leg: [the foot's goal, where the leg's end goes (skeleton space), its lift (m)]
var _down_s := Vector3.ZERO  # the crouch, skeleton space
var _moves: Array = []       # per leg: the move its foot last had off its clip, skeleton space (what it lets go from)
var _r2s := Transform3D()    # the skeleton in the host's rest frame (its unleaned body): what a lift is read in


## Plant `host`'s legs (GRig.legs of the model it draws, under its skeleton `skel`). Empty: nothing to plant.
func attach(v: Vehicle, skel: Skeleton3D, model: Node3D) -> bool:
	host = v
	legs = []
	shortest = INF
	var k := v._vis_rest.basis.get_scale().x   # the model's units (GRig's frame: the model's own) in metres
	for L in GRig.legs(model):
		var up: int = L["upper"]
		var lo: int = L["lower"]
		var ft: int = L["foot"]
		var soles: Dictionary = L["soles"]
		var carried := int(L.get("on", ft)) != ft
		# where the leg ends, as the two bones place it: the ankle — or, where the lower leg carries the foot's skin, the middle
		# of that underside, on the lower leg (its frame)
		var end := Vector3.ZERO
		if carried:
			var rest := drawn(skel, soles, true)
			for p in rest:
				end += p
			end = skel.get_bone_global_rest(lo).affine_inverse() * (end / float(rest.size()))
		var H := skel.get_bone_global_rest(up).origin
		var K := skel.get_bone_global_rest(lo).origin
		var E := skel.get_bone_global_rest(lo) * end if carried else skel.get_bone_global_rest(ft).origin
		var bend := (K - H).cross(E - H)   # the knee's rest normal, held in the upper bone's own frame (it turns with it)
		legs.append({"upper": up, "lower": lo, "foot": ft, "carried": carried, "end": end, "soles": soles,
			"bend": (skel.get_bone_global_rest(up).basis.inverse() * bend).normalized() if bend.length_squared() > 1e-12 else Vector3.RIGHT})
		shortest = minf(shortest, float(L["len"]) * k)
	if legs.is_empty():
		return false
	_r2s = v._vis_rest * GPose.xf_to(skel, model)
	influence = 0.0
	active = false
	return true


## Ease toward what the host wants (its physics tick: the state it flies, swims or walks in).
func ramp(delta: float) -> void:
	influence = move_toward(influence, 1.0 if want else 0.0, RAMP * delta)
	active = influence > 0.0
	if not active:
		crouch = 0.0


## THIS FRAME'S FEET — each one's goal and the crouch — read once a frame: by the host before its rider rides the crouch
## (Vehicle._process), else by the modifier itself. `delta` the frame's.
func prepare(delta: float) -> void:
	var f := Engine.get_process_frames()
	if f == _frame or host == null or not active:
		return
	var t0 := Time.get_ticks_usec()
	_frame = f
	_prepare(delta)
	_spend(Time.get_ticks_usec() - t0)
	timed += 1


func _prepare(delta: float) -> void:
	var skel := get_skeleton()
	if skel == null:
		return
	var sk_g := skel.get_global_transform_interpolated()           # where the skeleton is drawn this frame
	var ground := host._visual.get_global_transform_interpolated() * host._vis_rest.affine_inverse()
	if host._rock != 0.0:
		ground = ground * Transform3D(Basis(Vector3.RIGHT, -host._rock), Vector3.ZERO)   # the body's ground, unrocked
	var up_w := ground.basis.y.normalized()
	var sk_inv := sk_g.basis.inverse()
	var up_s := sk_inv * up_w
	var gap := Vehicle.TYRE_GAP
	_targets.resize(legs.size())
	var deepest := 0.0       # the most a planted foot's leg is short of its goal, m along the ground's up
	_moves.resize(legs.size())
	for li in legs.size():
		var L: Dictionary = legs[li]
		var fp := skel.get_bone_global_pose(int(L["foot"]))
		var lift := 0.0
		var move: Vector3 = _moves[li] if _moves[li] != null else Vector3.ZERO
		if want:
			lift = INF
			var need := -INF
			for ps in drawn(skel, L["soles"]):
				lift = minf(lift, (_r2s * ps).y)
				var pw := sk_g * ps
				need = maxf(need, host._ground_h_at(pw.x, pw.z) + gap - pw.y)
				reads += 1
			lift = maxf(lift, 0.0)
			need += lift
			# straight up or down onto the ground under it: along the body's up, the triceratops' tilted on Kestrel Bay's wall,
			# a hoof raised 0.12 m went 5 cm across too, onto ground that was not the ground it was raised by (6.5 cm over it, the
			# drive rig's (f2))
			move = sk_inv * (Vector3.UP * need)
			_moves[li] = move
		# ...LETTING GO (a take-off, the water: `influence` easing out), each foot keeps the move it last had off its clip and
		# fades from there: still reaching for the ground as it fell away, a default dragon taking off stretched its legs down
		# after it, 0.133 m a frame (the drive rig's (f9))
		var E := skel.get_bone_global_pose(int(L["lower"])) * (L["end"] as Vector3) if L["carried"] else fp.origin
		_targets[li] = [Transform3D(fp.basis, fp.origin + move), E + move, lift]
		# ...and EVERY foot of a mount striding on its legs (Vehicle._stride_on): its thighs swing a pendulum, the knee as its rest
		# bent it, so a lifted foot goes out along the arc with no bend to spare — with only its planted feet served, the default
		# dragon's swinging foot hung 0.24 m short of its lift over a hollow and 0.06 over a crest's shoulder, and the crouch let
		# go between its plants (one planted foot then 0.07 m over the hollow's floor, 0.15 s easing back down) — the drive rig's
		# footing (f2), (f3)
		if lift < LIFT_PLANTED or host._striding:
			var H := skel.get_bone_global_pose(int(L["upper"])).origin
			var K := skel.get_bone_global_pose(int(L["lower"])).origin
			var over := (E + move - H).length() - ((K - H).length() + (E - K).length()) * 0.995
			if over > 0.0:
				# lowering the hips by x shortens the line from them to the goal by about x times its share of the vertical
				var share := maxf(0.3, absf((E + move - H).normalized().dot(up_s.normalized())))
				deepest = maxf(deepest, over * sk_g.basis.get_scale().x / share)
	var to := minf(deepest, CROUCH_MAX * shortest) if want else 0.0   # letting go (a take-off): it rises back as it fades
	if to > 0.0:
		to = minf(to, maxf(0.0, host._keel_clearance()))
	crouch = move_toward(crouch, to, CROUCH_RATE * delta)
	_down_s = sk_inv * (up_w * -crouch)


func _process_modification_with_delta(delta: float) -> void:
	if host == null or not is_instance_valid(host) or host._visual == null:
		return
	prepare(delta)   # timed on its own (prepare): the host's _process has usually done it this frame already
	var t0 := Time.get_ticks_usec()
	var skel := get_skeleton()
	if skel == null or _targets.size() != legs.size():
		return
	if crouch > 0.0:
		for r in skel.get_parentless_bones():
			skel.set_bone_pose_position(r, skel.get_bone_pose_position(r) + _down_s)
	for li in legs.size():
		_solve(skel, legs[li], _targets[li][0], _targets[li][1])
	_spend(Time.get_ticks_usec() - t0)
	n += 1
	frames += 1


# Time a half of a frame's feet took, into this one's (GOGI_PERF) and every one's (the drive rig).
func _spend(dt: int) -> void:
	us += dt
	spent_us += dt


## One leg onto its goal: upper and lower turned in the plane the clip bent the knee in (its rest bend when the clip holds it
## straight), so the line from the hip to the leg's end (`to`: the ankle, or the underside its lower leg carries) is the goal's,
## within the leg's reach; the foot set on the goal in its clip's orientation — or, carried by the lower leg, left riding it.
func _solve(skel: Skeleton3D, L: Dictionary, goal: Transform3D, to: Vector3) -> void:
	var up: int = L["upper"]
	var lo: int = L["lower"]
	var ft: int = L["foot"]
	var carried: bool = L["carried"]
	var ug := skel.get_bone_global_pose(up)
	var lg := skel.get_bone_global_pose(lo)
	var E := lg * (L["end"] as Vector3) if carried else skel.get_bone_global_pose(ft).origin
	if to.distance_squared_to(E) < 1e-14:
		return
	var H := ug.origin
	var K := lg.origin
	var a := (K - H).length()
	var b := (E - K).length()
	var to_t := to - H
	var dist := to_t.length()
	var d := clampf(dist, absf(a - b) + 1e-4 * (a + b), (a + b) * 0.9999)
	var u := to_t / maxf(dist, 1e-9)
	var nrm := (K - H).cross(E - H)
	if nrm.length_squared() < 1e-14:
		nrm = ug.basis * (L["bend"] as Vector3)
	nrm = nrm.normalized()
	# the knee's side of the hip-to-goal line in that plane: the side the normal says, whichever way the goal turned the line
	# (picked as the side the old knee lay on, a near-straight leg's goal swung past its knee bent it backwards: the walking
	# cow's knees 180 deg off their clip's over a crest, every galloping leg's — the drive rig's (f3))
	var v := u.cross(nrm).normalized()
	var ca := clampf((a * a + d * d - b * b) / (2.0 * a * d), -1.0, 1.0)
	var K2 := H + u * (a * ca) + v * (a * sqrt(maxf(0.0, 1.0 - ca * ca)))
	var T2 := H + u * d
	var r1 := Basis(Quaternion((K - H).normalized(), (K2 - H).normalized()))
	var r2 := Basis(Quaternion((r1 * (E - K)).normalized(), (T2 - K2).normalized()))
	_set_global(skel, up, Transform3D(r1 * ug.basis, H))
	_set_global(skel, lo, Transform3D(r2 * r1 * lg.basis, K2))
	if not carried:
		_set_global(skel, ft, Transform3D(goal.basis, T2))


## A foot's soles (GRig.legs) as the skin draws them from `skel`'s poses — its rests with `rest` — skeleton space.
static func drawn(skel: Skeleton3D, soles: Dictionary, rest := false) -> PackedVector3Array:
	var bones: PackedInt32Array = soles["bones"]
	var at: PackedInt32Array = soles["at"]
	var w: PackedFloat32Array = soles["w"]
	var l: PackedVector3Array = soles["l"]
	var o: PackedInt32Array = soles["o"]
	var m: Array[Transform3D] = []
	for b in bones:
		m.append(skel.get_bone_global_rest(b) if rest else skel.get_bone_global_pose(b))
	var out := PackedVector3Array()
	for s in o.size() - 1:
		var p := Vector3.ZERO
		for j in range(o[s], o[s + 1]):
			p += (m[at[j]] * l[j]) * w[j]
		out.append(p)
	return out


func _set_global(skel: Skeleton3D, b: int, g: Transform3D) -> void:
	var par := skel.get_bone_parent(b)
	skel.set_bone_pose(b, g if par < 0 else skel.get_bone_global_pose(par).affine_inverse() * g)
