class_name GPose extends RefCounted
## SEAT/POSE CONTRACT (Wave 2 sit + Wave 3 ride) — pose ANY rigged humanoid, cleanly restore it.
##   GPose.sit(character)   -> true  = a Skeleton3D was found and posed seated (thighs raised
##                                     ~85° forward, knees bent ~85° back, torso upright, arms
##                                     slightly forward toward a wheel — when arm bones resolve)
##                           -> false = NO skeleton / no recognizable leg bones. Silent no-op:
##                                     capsule players degrade to the caller's Wave-1 hide path.
##   GPose.ride(character)  -> the ASTRIDE preset (Wave 3 mounts): thighs flexed ~45° FORWARD
##                             at the hip (they drape forward-down over the flanks — without
##                             this the rider read as standing on the animal) AND spread ~40°
##                             OUTWARD (about the character's forward axis, per-side), knees
##                             bent ~90° back so the shins wrap the barrel, torso upright
##                             (spine untouched), hands gently forward to the reins. Same
##                             true/false contract and the SAME "gpose_state" meta snapshot as
##                             sit — one restore path for both.
##   GPose.stand(character)  -> restores the exact pre-sit/pre-ride bone poses + resumes the
##                             paused AnimationPlayer clip. All calls are idempotent.
##
## HOW: per-bone LOCAL pose overrides via Skeleton3D.set_bone_pose_rotation (cleanly reversible —
## the original pose rotations are snapshotted into a meta dict on the character and written back
## by stand(); a resumed AnimationPlayer then re-stomps them anyway). A playing AnimationPlayer is
## PAUSED first (it would fight the pose every frame) and resumed at the same clip + position.
##
## RIG-AGNOSTIC: bones resolve by NAME SUBSTRING, covering both rig families this stack ships:
##   - KayKit Rig_Medium (verified from models/kk_rig_medium_*.glb): hips / spine / chest /
##     upperleg.l / lowerleg.l / upperarm.l / lowerarm.l / wrist.l / hand.l (+ .r) …
##   - Meshy / Mixamo-style 24-bone humanoids: Hips / LeftUpLeg / LeftLeg / LeftArm /
##     LeftForeArm … (any "mixamorig:" prefix is transparent to substring matching)
## Rotation axes are convention-independent: the bend axis is the CHARACTER's lateral (+X) axis
## (stack convention: characters FACE +Z) transformed into skeleton space, and each bone's new
## LOCAL rotation is derived from a snapshot of the skeleton-space global poses — so armature
## orientation, import scale, and bone roll conventions all cancel out.

const META := "gpose_state"       # meta key on the character holding {skel, bones, player, anim, anim_pos}
const THIGH_DEG := -85.0          # thighs raised forward (about character +X; -Y leg -> ~+Z)
const ARM_DEG := -45.0            # upper arms forward toward a wheel
const FOREARM_DEG := -70.0        # forearm TOTAL world pitch (slight extra elbow bend, hands up)
# --- ride (astride) preset ---
# RIDE_THIGH_DEG: hip FLEXION about the lateral axis (same sign convention as sit's THIGH_DEG:
# negative = forward) — composed onto the spread as a global left-multiply, so the whole leg
# drapes forward-down over the flanks. RIDE_SPREAD_DEG: thighs swung OUTWARD about the
# character's FORWARD (+Z) axis, each to its own side (sign from the thigh's lateral offset).
# RIDE_KNEE_DEG: knees bent BACK about the (delta-carried) lateral axis — POSITIVE where sit's
# THIGH_DEG -85 is forward; 90 with the 45° flexion nets the shin ~45° back of vertical, wrapping
# the barrel (70 was tuned for the old unpitched thigh).
const RIDE_THIGH_DEG := -45.0
const RIDE_SPREAD_DEG := 40.0
const RIDE_KNEE_DEG := 90.0
const RIDE_ARM_DEG := -30.0       # upper arms gently forward (reins) — softer than sit's -45
const RIDE_FOREARM_DEG := -55.0   # forearm TOTAL pitch toward the reins
# --- swim (treading) preset (Wave 2) ---
# SWIM_SPINE_DEG: torso pitched FORWARD about the lateral axis. POSITIVE here (not sit's negative):
# the spine bone points UP, and +θ about the character's +X carries an UP-pointing bone toward +Z
# (FORWARD — stack convention faces +Z), the mirror of sit()'s DOWN-pointing-limb negatives.
const SWIM_SPINE_DEG := 15.0
const WALK_META := "gpose_walk"   # separate meta key from sit/ride/swim's META (a walker isn't seated/riding/swimming)
const WALK_THIGH_DEG := 26.0      # peak fore/aft LEG swing (about the character's lateral axis)
const WALK_ARM_DEG := 15.0        # counter-swing arms (harmless where a rig has no arm bones)
# --- relaxed arms (the procedural stand, see relax) ---
const RELAX_OUT_DEG := 12.0       # a relaxed arm hangs this far out from the body line
const RELAX_MIN_DEG := 30.0       # an arm closer than this to hanging is left as the pose has it


## Pose `character` seated. Returns false (silent no-op) when no skeleton / no leg bones resolve.
static func sit(character: Node3D) -> bool:
	if character == null or not is_instance_valid(character):
		return false
	if character.has_meta(META):
		return true                      # already seated — idempotent
	var skel := _find_skeleton(character)
	if skel == null:
		return false                     # unrigged (capsule) player -> caller's Wave-1 hide fallback
	# ---- resolve bones BEFORE touching anything (a miss must be side-effect free)
	var thighs: Array[int] = []
	var shins: Array[int] = []
	var upperarms: Array[int] = []
	var forearms: Array[int] = []
	var rs := _rig_limbs(character, thighs, shins, upperarms, forearms)
	if rs != null:
		skel = rs
	else:
		_name_limbs(skel, thighs, shins, upperarms, forearms)
	if thighs.is_empty():
		return false                     # not a humanoid we understand -> hide fallback
	# ---- freeze the CURRENT animated pose (see _freeze_anim: play() alone leaves a T-pose)
	var _fz := _freeze_anim(character)
	var ap = _fz["player"]
	var anim: String = _fz["anim"]
	var anim_pos: float = _fz["anim_pos"]
	# ---- bend axis: the CHARACTER's +X (lateral) axis expressed in skeleton space
	var char_b := character.global_transform.basis.orthonormalized()
	var skel_b := skel.global_transform.basis.orthonormalized()
	var axis := (skel_b.inverse() * (char_b * Vector3.RIGHT)).normalized()
	# ---- snapshot EVERY bone's skeleton-space global basis (pure math below; no dirty-state reads)
	var g := {}
	for i in skel.get_bone_count():
		g[i] = skel.get_bone_global_pose(i).basis.orthonormalized()
	var thigh_rot := Basis(axis, deg_to_rad(THIGH_DEG))
	var arm_rot := Basis(axis, deg_to_rad(ARM_DEG))
	var fore_rot := Basis(axis, deg_to_rad(FOREARM_DEG))
	var orig := {}                       # bone idx -> original local pose Quaternion (for stand())
	# thighs: raise ~85° forward about the lateral axis (global left-multiply, converted to local)
	for t in thighs:
		var tp := skel.get_bone_parent(t)
		var tpg: Basis = (g[tp] as Basis) if tp >= 0 else Basis.IDENTITY
		_set_local(skel, t, tpg.inverse() * (thigh_rot * (g[t] as Basis)), orig)
	# shins: keep their ORIGINAL world orientation -> knees bend ~85° back, feet hang down
	for s in shins:
		var sp := skel.get_bone_parent(s)
		if sp < 0 or not _has_ancestor_in(skel, s, thighs):
			continue                     # shin not under a matched thigh: leave it alone
		var spg: Basis = thigh_rot * (g[sp] as Basis)   # parent chain inherited the thigh delta
		_set_local(skel, s, spg.inverse() * (g[s] as Basis), orig)
	# upper arms: slightly forward (toward a wheel)
	for a in upperarms:
		var ap_i := skel.get_bone_parent(a)
		var apg: Basis = (g[ap_i] as Basis) if ap_i >= 0 else Basis.IDENTITY
		_set_local(skel, a, apg.inverse() * (arm_rot * (g[a] as Basis)), orig)
	# forearms: a touch more pitch than the upper arm (elbow bend, hands raised to the wheel)
	for f in forearms:
		var fp := skel.get_bone_parent(f)
		if fp < 0:
			continue
		var fpg: Basis = (g[fp] as Basis)
		if _has_ancestor_in(skel, f, upperarms):
			fpg = arm_rot * fpg          # parent chain inherited the upper-arm delta
		_set_local(skel, f, fpg.inverse() * (fore_rot * (g[f] as Basis)), orig)
	character.set_meta(META, {
		"skel": skel, "bones": orig, "player": ap, "anim": anim, "anim_pos": anim_pos,
	})
	return true


## Pose `character` ASTRIDE a mount (Wave 3): thighs flexed ~45° forward at the hip + spread
## `spread_deg` outward (RIDE_SPREAD_DEG unless the mount fits it to its width: Vehicle._seat_driver)
## + knees bent ~90° back, torso upright (spine untouched), hands gently toward
## the reins. Returns false (silent no-op)
## when no skeleton / no leg bones resolve — the caller's hide fallback. Same bone-resolution
## machinery, snapshot meta and stand() restore path as sit(); idempotent (a second ride — or a
## ride on an already-seated character — is a no-op returning true).
static func ride(character: Node3D, spread_deg := RIDE_SPREAD_DEG, knee_deg := RIDE_KNEE_DEG) -> bool:
	if character == null or not is_instance_valid(character):
		return false
	if character.has_meta(META):
		return true                      # already posed — idempotent
	var skel := _find_skeleton(character)
	if skel == null:
		return false                     # unrigged (capsule) player -> caller's hide fallback
	# ---- resolve bones BEFORE touching anything (a miss must be side-effect free)
	var thighs: Array[int] = []
	var shins: Array[int] = []
	var upperarms: Array[int] = []
	var forearms: Array[int] = []
	var rs := _rig_limbs(character, thighs, shins, upperarms, forearms)
	if rs != null:
		skel = rs
	else:
		_name_limbs(skel, thighs, shins, upperarms, forearms)
	if thighs.is_empty():
		return false                     # not a humanoid we understand -> hide fallback
	# ---- freeze the CURRENT animated pose (see _freeze_anim: play() alone leaves a T-pose): what stand() gives back
	var _fz := _freeze_anim(character)
	var ap = _fz["player"]
	var anim: String = _fz["anim"]
	var anim_pos: float = _fz["anim_pos"]
	# ---- EVERY RIDE STARTS FROM THE IDLE'S FIRST FRAME (the rest pose with no idle), never the frame a walk or a swing was
	# in when the rider got on: a stride frozen under the ride's rotations put one knee 25 deg ahead of the other and moved
	# the drawn seat under the pelvis; and it is the pose the rider's seat is measured in (RiderSeatJob). Held paused; a
	# player that played nothing has every bone it moves kept as it was, and stopped again by stand() — left playing its
	# idle, a stood-up creature's next pose read the idle's every bone as its own (the people rig's census).
	var held := {}
	var idle := GClip.resolve(ap, "idle") if ap != null else ""
	if idle != "" and (ap as AnimationPlayer).has_animation(idle):
		if anim == "":
			for i in skel.get_bone_count():
				held[i] = [skel.get_bone_pose_position(i), skel.get_bone_pose_rotation(i), skel.get_bone_pose_scale(i)]
		(ap as AnimationPlayer).play(idle, 0.0)
		(ap as AnimationPlayer).seek(0.0, true)
		(ap as AnimationPlayer).pause()
	# ---- axes in skeleton space: lateral = the CHARACTER's +X, forward = its +Z (stack
	# convention: characters FACE +Z, so forward is Vector3.BACK, not Godot's -Z FORWARD)
	var char_b := character.global_transform.basis.orthonormalized()
	var skel_b := skel.global_transform.basis.orthonormalized()
	var axis := (skel_b.inverse() * (char_b * Vector3.RIGHT)).normalized()
	var fwd := (skel_b.inverse() * (char_b * Vector3.BACK)).normalized()
	# ---- snapshot EVERY bone's skeleton-space global pose (pure math below; no dirty-state reads)
	var g: Array[Transform3D] = []
	for i in skel.get_bone_count():
		g.append(skel.get_bone_global_pose(i))
	var orig := {}                       # bone idx -> original local pose Quaternion (for stand())
	var rots := _ride_rots(skel, g, axis, fwd, thighs, shins, upperarms, forearms, spread_deg, knee_deg)
	for b in rots:
		_set_local(skel, b, rots[b], orig)
	character.set_meta(META, {
		"skel": skel, "bones": orig, "player": ap, "anim": anim, "anim_pos": anim_pos, "held": held,
	})
	return true


## THE RIDE'S BONES, as math: the local rotation (bone index -> Basis) ride() writes on each limb it poses, from the bones'
## skeleton-space global poses `g` and the character's lateral `axis` and forward `fwd` in skeleton space. One function for
## the pose a rider shows and the pose their seat is measured in (RiderSeatJob), so the two can never part.
static func _ride_rots(skel: Skeleton3D, g: Array[Transform3D], axis: Vector3, fwd: Vector3, thighs: Array[int], shins: Array[int],
		upperarms: Array[int], forearms: Array[int], spread_deg := RIDE_SPREAD_DEG, knee_deg := RIDE_KNEE_DEG) -> Dictionary:
	var out := {}
	var gb := func(i: int) -> Basis: return g[i].basis.orthonormalized() if i >= 0 else Basis.IDENTITY
	var arm_rot := Basis(axis, deg_to_rad(RIDE_ARM_DEG))
	var fore_rot := Basis(axis, deg_to_rad(RIDE_FOREARM_DEG))
	# ---- per-thigh HIP DELTA = forward FLEXION ∘ outward SPREAD (both global left-multiplies;
	# the flexion is left-most so it stays exactly about the character's lateral axis, the sit()
	# convention). Spread: rotating a down-pointing (-Y) leg about +Z_char by +θ swings its tip
	# toward +X_char ((0,-1,0) -> (sinθ, -cosθ, 0)), so a thigh offset to the +X side spreads
	# outward with a POSITIVE angle and the -X side with a NEGATIVE one. Side = the thigh
	# origin's offset along the lateral axis; a rig that centres both thighs (degenerate) falls
	# back to alternating signs so the legs still split.
	var flex := Basis(axis, deg_to_rad(RIDE_THIGH_DEG))
	var hip_delta := {}                  # thigh idx -> that side's combined flexion∘spread Basis
	var flip := 1.0
	for t in thighs:
		var side := g[t].origin.dot(axis)
		var sgn := signf(side)
		if absf(side) < 0.001:
			sgn = flip
			flip = -flip
		hip_delta[t] = flex * Basis(fwd, deg_to_rad(spread_deg) * sgn)
	# thighs: flex forward + spread outward (global left-multiply, converted to local — the
	# sit() conversion)
	for t in thighs:
		out[t] = gb.call(skel.get_bone_parent(t)).inverse() * ((hip_delta[t] as Basis) * gb.call(t))
	# shins: bend the knee ~90° BACK about the knee's POST-DELTA lateral axis (the thigh's
	# lateral axis carried through flexion + spread), on top of the inherited hip delta — feet
	# tuck along the mount's flanks. The combined delta replaces the old spread in ALL THREE
	# spots: knee axis, parent-chain carry, and the left-compose.
	for s in shins:
		var sp := skel.get_bone_parent(s)
		var owner_t := _ancestor_of(skel, s, thighs)
		if sp < 0 or owner_t < 0:
			continue                     # shin not under a matched thigh: leave it alone
		var srot: Basis = hip_delta[owner_t] as Basis
		var knee := Basis((srot * axis).normalized(), deg_to_rad(knee_deg))
		var spg: Basis = srot * gb.call(sp)   # parent chain inherited the hip delta
		out[s] = spg.inverse() * (knee * srot * gb.call(s))
	# torso upright: spine bones untouched (the pinned astride contract). Arms: same machinery
	# as sit, gentler angles — hands drift forward to the reins instead of a wheel.
	for a in upperarms:
		out[a] = gb.call(skel.get_bone_parent(a)).inverse() * (arm_rot * gb.call(a))
	for f in forearms:
		var fp := skel.get_bone_parent(f)
		if fp < 0:
			continue
		var fpg: Basis = gb.call(fp)
		if _has_ancestor_in(skel, f, upperarms):
			fpg = arm_rot * fpg          # parent chain inherited the upper-arm delta
		out[f] = fpg.inverse() * (fore_rot * gb.call(f))
	return out


## Pose `character` treading water (Wave 2 swim): the torso pitched ~15° FORWARD so the head/shoulders
## ride above the surface. MINIMAL by design — ONE reversible spine-bone override; arms/legs keep
## their relaxed idle pose (carried forward by the lean), which is the safe capsule-noop-plus-tilt
## allowance from the swim contract. Same snapshot meta + stand() restore path as sit()/ride(); an
## unrigged (capsule) player returns false (the caller hides / no-ops). Idempotent.
static func swim(character: Node3D) -> bool:
	if character == null or not is_instance_valid(character):
		return false
	if character.has_meta(META):
		return true                      # already posed — idempotent
	var skel := _find_skeleton(character)
	if skel == null:
		return false                     # unrigged (capsule) player -> caller's hide fallback
	# lowest torso bone (closest to the hips) — tilting it leans the WHOLE upper body forward while
	# the legs (parented off the hips, not this bone) keep their relaxed pose. A PERSON's is the map's: the lowest bone
	# that carries the head and both arms and neither leg (GRig — Rigify's DEF-spine is the pelvis and carries the legs,
	# and a lean of it swung them 8 deg; Biped hangs its thighs off "Bip01 Spine"). Anything else: the first torso name.
	var spine := -1
	var rig := GRig.of(character)
	if bool(rig.get("person", false)) and String(rig.get("kind", "")) == "bones" and int(rig.get("lean", -1)) >= 0:
		skel = skeleton_of(character)
		spine = int(rig["lean"])
	else:
		for i in skel.get_bone_count():
			var bn := skel.get_bone_name(i).to_lower()
			if "twist" in bn or "roll" in bn:
				continue
			if "spine" in bn or "chest" in bn or "torso" in bn:
				spine = i
				break
	if spine < 0:
		return false                     # no torso bone we recognise -> hide fallback
	# ---- freeze the CURRENT animated pose (see _freeze_anim: play() alone leaves a T-pose)
	var _fz := _freeze_anim(character)
	var ap = _fz["player"]
	var anim: String = _fz["anim"]
	var anim_pos: float = _fz["anim_pos"]
	# ---- bend axis: the CHARACTER's +X (lateral) axis expressed in skeleton space (sit()'s idiom)
	var char_b := character.global_transform.basis.orthonormalized()
	var skel_b := skel.global_transform.basis.orthonormalized()
	var axis := (skel_b.inverse() * (char_b * Vector3.RIGHT)).normalized()
	# global left-multiply the forward pitch onto the spine's current pose, then convert to local.
	var sp := skel.get_bone_parent(spine)
	var spg: Basis = skel.get_bone_global_pose(sp).basis.orthonormalized() if sp >= 0 else Basis.IDENTITY
	var sg: Basis = skel.get_bone_global_pose(spine).basis.orthonormalized()
	var lean := Basis(axis, deg_to_rad(SWIM_SPINE_DEG))
	var orig := {}
	_set_local(skel, spine, spg.inverse() * (lean * sg), orig)
	character.set_meta(META, {
		"skel": skel, "bones": orig, "player": ap, "anim": anim, "anim_pos": anim_pos,
	})
	return true


## Restore the pre-sit/pre-ride pose + resume the paused animation. No-op if neither ran (idempotent).
static func stand(character: Node3D) -> void:
	if character == null or not is_instance_valid(character):
		return
	if not character.has_meta(META):
		return
	var st: Dictionary = character.get_meta(META)
	character.remove_meta(META)
	var skel = st.get("skel")
	if skel is Skeleton3D and is_instance_valid(skel):
		var bones: Dictionary = st.get("bones", {})
		for idx in bones:
			(skel as Skeleton3D).set_bone_pose_rotation(int(idx), bones[idx])
	var ap = st.get("player")
	var anim := String(st.get("anim", ""))
	if ap is AnimationPlayer and is_instance_valid(ap) and anim != "" and (ap as AnimationPlayer).has_animation(anim):
		(ap as AnimationPlayer).play(anim)
		(ap as AnimationPlayer).seek(float(st.get("anim_pos", 0.0)))
	elif not (st.get("held", {}) as Dictionary).is_empty():
		# ride held its idle's first frame on a player that played nothing: stopped again, every bone as it found it
		if ap is AnimationPlayer and is_instance_valid(ap):
			(ap as AnimationPlayer).stop()
		if skel is Skeleton3D and is_instance_valid(skel):
			var held: Dictionary = st["held"]
			for i in held:
				(skel as Skeleton3D).set_bone_pose_position(int(i), held[i][0])
				(skel as Skeleton3D).set_bone_pose_rotation(int(i), held[i][1])
				(skel as Skeleton3D).set_bone_pose_scale(int(i), held[i][2])


## PROCEDURAL WALK for a CLIPLESS character — a Meshy/Quaternius creature with no embedded clips and a
## foreign rig, so AnimRig could not animate it and it would otherwise SLIDE rigidly across the ground.
## Call EVERY frame while the character moves, advancing `phase` with distance travelled. It alternately
## swings the LEGS (and counter-swings arms) fore/aft about the character's lateral axis — the same
## ride()/sit() bone math proven on these skeletons. Legs/arms are DIRECT children of the pelvis/spine we
## never rotate, so each override is a clean rest-relative rotation (no parent-chain drift). No-op on a rig
## with no leg bones (snake/fish) — a legless glider sliding reads fine. walk_stop() restores the rest pose.
## Cheap (~2-4 bone writes/frame); the caller only drives NEAR characters (far ones freeze via anim-LOD).
static func walk(character: Node3D, phase: float) -> void:
	if character == null or not is_instance_valid(character):
		return
	var st: Dictionary
	if character.has_meta(WALK_META):
		st = character.get_meta(WALK_META)
	else:
		st = _walk_setup(character)
		character.set_meta(WALK_META, st)
	if bool(st.get("none", false)):
		return
	var skel = st.get("skel")
	if not (skel is Skeleton3D) or not is_instance_valid(skel):
		character.remove_meta(WALK_META)
		return
	var sk := skel as Skeleton3D
	var axis: Vector3 = st["axis"]
	var g: Dictionary = st["g"]
	var s := sin(phase)
	for e in st["legs"]:
		var b := int(e["idx"])
		var delta := Basis(axis, deg_to_rad(WALK_THIGH_DEG) * s * float(e["sgn"]))
		var p := sk.get_bone_parent(b)
		var pg: Basis = (g[p] as Basis) if g.has(p) else Basis.IDENTITY
		sk.set_bone_pose_rotation(b, (pg.inverse() * (delta * (g[b] as Basis))).get_rotation_quaternion())
	for e in st["arms"]:
		var b := int(e["idx"])
		var delta := Basis(axis, deg_to_rad(WALK_ARM_DEG) * -s * float(e["sgn"]))   # arms opposite the same-side leg
		var p := sk.get_bone_parent(b)
		var pg: Basis = (g[p] as Basis) if g.has(p) else Basis.IDENTITY
		sk.set_bone_pose_rotation(b, (pg.inverse() * (delta * (g[b] as Basis))).get_rotation_quaternion())


# Resolve leg/arm bones + snapshot their REST global bases (bind pose, since a clipless character's
# AnimationMixer is null). Returns {"none": true} on a legless/unrecognised rig so walk() no-ops.
#
# THIGHS ONLY, AND EVERY ONE OF THEM. "hip" used to be in the leg test, so the PELVIS matched first on
# every rig this stack ships (Meshy "Hips", KayKit "hips"): the stride rocked the whole body from the
# pelvis (people rig: head swinging 0.074 m) and swung ONE thigh, the left never moved. And it took
# the first two legs it met, so a four-legged rig (farm_Pig: FrontUpLeg_R, BackUpLeg_R first) swung
# its right side while both left legs hung still. Now: every thigh, and along each side the legs
# alternate front to back, so a biped strides left/right and a quadruped trots on its diagonals.
static func _walk_setup(character: Node3D) -> Dictionary:
	var sk := _find_skeleton(character)
	if sk == null:
		return {"none": true}
	var found: Array[int] = []
	var arms: Array[int] = []
	var legs: Array[int] = []
	# A PERSON swings the map's two thighs and two UPPER ARMS. By name the arm pick was "upperarm" or "shoulder", so on
	# every Mixamo / Meshy rig it swung the CLAVICLE ("LeftShoulder"), on Rigify the clavicle roots alone, and an arm
	# whose names it missed not at all; the upper arm is the shoulder joint every rig shares (decision: the clipless
	# stride swings the upper arm).
	var shins: Array[int] = []
	var fores: Array[int] = []
	var rs := _rig_limbs(character, legs, shins, arms, fores)
	if rs != null:
		sk = rs
	else:
		for i in sk.get_bone_count():
			var bn := sk.get_bone_name(i).to_lower()
			if "twist" in bn or "roll" in bn:
				continue
			if _is_thigh(bn):
				found.append(i)
			elif ("upperarm" in bn or "shoulder" in bn) and arms.size() < 2:
				arms.append(i)
		for b in found:
			if _ancestor_of(sk, b, found) < 0:
				legs.append(b)           # a thigh chained under another would swing twice
	if legs.is_empty():
		return {"none": true}   # snake/fish/unknown rig -> slide (reads fine)
	if legs.size() > 2:
		arms.clear()                     # a quadruped's "Shoulders" is its torso, not an arm to swing
	var char_b := character.global_transform.basis.orthonormalized()
	var skel_b := sk.global_transform.basis.orthonormalized()
	var axis := (skel_b.inverse() * (char_b * Vector3.RIGHT)).normalized()
	var fwd := (skel_b.inverse() * (char_b * Vector3.BACK)).normalized()   # characters FACE +Z
	var g := {}
	for pool in [legs, arms]:
		for b in pool:
			g[b] = sk.get_bone_global_pose(b).basis.orthonormalized()
			var p := sk.get_bone_parent(b)
			if p >= 0 and not g.has(p):
				g[p] = sk.get_bone_global_pose(p).basis.orthonormalized()
	var orig := {}
	var leg_e := []
	var flip := 1.0
	var sides := {}                      # side sign -> [[forward offset, bone]] (to alternate along the body)
	for b in legs:
		orig[b] = sk.get_bone_pose_rotation(b)
		var o := sk.get_bone_global_pose(b).origin
		var side := o.dot(axis)
		var sgn := signf(side) if absf(side) > 0.001 else flip
		if absf(side) <= 0.001:
			flip = -flip                 # degenerate (both legs centred): alternate signs so they still split
		var row: Array = sides.get(sgn, [])
		row.append([o.dot(fwd), b])
		sides[sgn] = row
	for sgn in sides:
		var row: Array = sides[sgn]
		row.sort_custom(func(p, q): return float(p[0]) > float(q[0]))
		for k in row.size():
			leg_e.append({"idx": int(row[k][1]), "sgn": float(sgn) * (1.0 if k % 2 == 0 else -1.0)})
	var arm_e := []
	for b in arms:
		orig[b] = sk.get_bone_pose_rotation(b)
		var side := sk.get_bone_global_pose(b).origin.dot(axis)
		arm_e.append({"idx": b, "sgn": signf(side) if absf(side) > 0.001 else 1.0})
	return {"skel": sk, "axis": axis, "g": g, "orig": orig, "legs": leg_e, "arms": arm_e}


## Restore the rest pose captured by walk() and clear its state. Safe when not walking (no-op).
static func walk_stop(character: Node3D) -> void:
	if character == null or not is_instance_valid(character):
		return
	if not character.has_meta(WALK_META):
		return
	var st: Dictionary = character.get_meta(WALK_META)
	character.remove_meta(WALK_META)
	var skel = st.get("skel")
	if skel is Skeleton3D and is_instance_valid(skel):
		for idx in st.get("orig", {}):
			(skel as Skeleton3D).set_bone_pose_rotation(int(idx), st["orig"][idx])


## RELAXED ARMS — part of the procedural stand for a rig with no clip that may play the role. Every
## humanoid this stack ships rests in a T-pose (people rig, nothing playing: shoulder-to-hand 0.000-
## 0.067 m on villager_man, pub_regular, smuggler_melee and kk_Knight), so "no clip" left the arms
## straight out. Swings each upper arm, shortest arc, from where it points to hanging RELAX_OUT_DEG
## off the body line. ONLY an arm more than RELAX_MIN_DEG from hanging (a T- or A-pose), and ONLY on
## a two-legged rig whose arms start well above its thighs: a quadruped's forelegs are named
## UpperArm/ForeArm on some rigs (the library fox) and already hang — posing them splayed them out.
## A no-op on arms that are already down, and any clip that plays afterwards overwrites it.
static func relax(character: Node3D) -> bool:
	if character == null or not is_instance_valid(character):
		return false
	var skel := _find_skeleton(character)
	if skel == null:
		return false
	var thighs: Array[int] = []
	var upperarms: Array[int] = []
	var forearms: Array[int] = []
	# A PERSON's arms are the map's: each upper arm with ITS forearm, however far down the arm the forearm sits (Rigify
	# splits the upper arm, so its forearm's parent is "DEF-upper_arm.L.001" and the parent test below never found it:
	# relax never ran). The map says they are arms, so the forelegs test does not apply — it skipped the Quaternius
	# superheroes, whose arms start 0.485 m over the thighs against a 0.4855 cutoff, and left them in a T-pose.
	var shins: Array[int] = []
	var rs := _rig_limbs(character, thighs, shins, upperarms, forearms)
	var person := rs != null
	if person:
		skel = rs
	else:
		for i in skel.get_bone_count():
			var bn := skel.get_bone_name(i).to_lower()
			if "twist" in bn or "roll" in bn:
				continue
			if _is_thigh(bn):
				thighs.append(i)
			elif ("forearm" in bn or "lowerarm" in bn or "elbow" in bn or ("arm" in bn and "lower" in bn)) and forearms.size() < 2:
				forearms.append(i)
			elif ("upperarm" in bn or ("arm" in bn and "armature" not in bn)) and upperarms.size() < 2:
				upperarms.append(i)      # Mixamo "LeftArm" IS the upper arm (forearm matched first)
	if thighs.size() != 2 or upperarms.is_empty():
		return false                     # not a biped: nothing here is an arm hanging at a side
	var char_b := character.global_transform.basis.orthonormalized()
	var skel_b := skel.global_transform.basis.orthonormalized()
	var down := (skel_b.inverse() * (char_b * Vector3.DOWN)).normalized()
	var lat := (skel_b.inverse() * (char_b * Vector3.RIGHT)).normalized()
	# the leg's length, hip to the lowest bone: arms that start less than half of it above the hips
	# are forelegs, not arms
	var hip_h := -1e9
	var low_h := 1e9
	for t in thighs:
		hip_h = maxf(hip_h, -skel.get_bone_global_pose(t).origin.dot(down))
	for i in skel.get_bone_count():
		low_h = minf(low_h, -skel.get_bone_global_pose(i).origin.dot(down))
	var posed := false
	for a in upperarms:
		var f := -1
		for fi in forearms:
			if skel.get_bone_parent(fi) == a or (person and _has_ancestor_in(skel, fi, [a] as Array[int])):
				f = fi
		if f < 0:
			continue
		var ga := skel.get_bone_global_pose(a)
		if not person and -ga.origin.dot(down) - hip_h < 0.5 * (hip_h - low_h):
			continue
		var d := skel.get_bone_global_pose(f).origin - ga.origin
		if d.length() < 1e-4:
			continue
		d = d.normalized()
		if rad_to_deg(d.angle_to(down)) <= RELAX_MIN_DEG:
			continue                     # already hanging: leave it as the pose has it
		var side := signf(ga.origin.dot(lat))
		var tgt := (down + lat * side * tan(deg_to_rad(RELAX_OUT_DEG))).normalized()
		var p := skel.get_bone_parent(a)
		var pg: Basis = skel.get_bone_global_pose(p).basis.orthonormalized() if p >= 0 else Basis.IDENTITY
		var nb := Basis(Quaternion(d, tgt)) * ga.basis.orthonormalized()
		skel.set_bone_pose_rotation(a, (pg.inverse() * nb).orthonormalized().get_rotation_quaternion())
		posed = true
	return posed


## THE PROCEDURAL STAND — what a rig with no clip for the role shows instead of its T-pose or a frame
## frozen mid-stride: nothing left playing, the skeleton back at rest, the arms down (relax). stop()
## alone leaves the last sampled frame on the bones, so a walk-only rig would stand mid-step.
## Returns false when there is no skeleton to pose (a capsule, a static mesh).
static func stand_relaxed(character: Node3D) -> bool:
	if character == null or not is_instance_valid(character):
		return false
	var ap := _find_anim_player(character)
	if ap != null and ap.is_playing():
		ap.stop()
	walk_stop(character)
	var sks := character.find_children("*", "Skeleton3D", true, false)
	for sk in sks:
		(sk as Skeleton3D).reset_bone_poses()
	relax(character)
	return not sks.is_empty()


## INTO DEEP WATER WITHOUT A SWIM CLIP — the one tread the crowd (wander), enemies and the hero share.
## The body holds its IDLE, restarted with no blend so the held frame is the idle's own and never a
## stride caught mid-step, or (no idle) the procedural stand; swim() then leans it into the tread.
## All three used to freeze whatever was on the bones at that instant — a walk mid-stride, a seated
## clip, the T-pose — or, worse, keep playing a standing clip upright on the water. Same snapshot
## meta and stand() restore as swim(); idempotent.
static func tread(character: Node3D, idle_clip := "") -> bool:
	if character == null or not is_instance_valid(character):
		return false
	if character.has_meta(META):
		return true                      # already posed — idempotent
	walk_stop(character)
	var ap := _find_anim_player(character)
	if ap != null and idle_clip != "" and ap.has_animation(idle_clip):
		ap.play(idle_clip, 0.0)
		ap.seek(0.0, true)
	else:
		stand_relaxed(character)
	return swim(character)


# A thigh bone by name: Mixamo/Meshy "LeftUpLeg", KayKit "upperleg.l", Quaternius "FrontUpLeg_R",
# "*thigh*", and the Rig Lab's "leg_FL_upper". Never "hip" — that is the pelvis on every rig here.
static func _is_thigh(bn: String) -> bool:
	return "upperleg" in bn or "upleg" in bn or "thigh" in bn or ("leg" in bn and "upper" in bn)


# A PERSON's limbs from the humanoid map (GRig.of), one bone per side — the two thighs, and the shins, upper arms and
# forearms it has — and the skeleton they are in (the richest); null when `character` is no person of bones or has no
# two thighs: the caller falls back to _name_limbs. By name, sit and ride took the FIRST TWO matches, and Godot lists
# bones depth-first per root: on Rigify both were segments of ONE leg ("DEF-thigh.L", "DEF-thigh.L.001"), the left
# thigh folded 85 deg twice and the right leg stood (thighs 85/0, shins 85/0, arms 45/0).
static func _rig_limbs(character: Node3D, thighs: Array[int], shins: Array[int], upperarms: Array[int], forearms: Array[int]) -> Skeleton3D:
	var rig := GRig.of(character)
	if not bool(rig.get("person", false)) or String(rig.get("kind", "")) != "bones":
		return null
	var ll: Dictionary = rig.get("leg_l", {})
	var lr: Dictionary = rig.get("leg_r", {})
	if int(ll.get("thigh", -1)) < 0 or int(lr.get("thigh", -1)) < 0:
		return null
	for leg in [ll, lr]:
		thighs.append(int(leg["thigh"]))
		if int(leg.get("shin", -1)) >= 0:
			shins.append(int(leg["shin"]))
	for side in ["l", "r"]:
		var arm: Dictionary = rig.get("arm_" + side, {})
		if int(arm.get("upper", -1)) >= 0:
			upperarms.append(int(arm["upper"]))
		if int(arm.get("fore", -1)) >= 0:
			forearms.append(int(arm["fore"]))
	return skeleton_of(character)


# Today's limbs by name substring, for a rig the map does not call a person (and the first two of each, as always).
static func _name_limbs(skel: Skeleton3D, thighs: Array[int], shins: Array[int], upperarms: Array[int], forearms: Array[int]) -> void:
	for i in skel.get_bone_count():
		var bn := skel.get_bone_name(i).to_lower()
		if "twist" in bn or "roll" in bn:
			continue                     # helper bones would double-rotate a limb
		if ("upperleg" in bn or "upleg" in bn or "thigh" in bn) and thighs.size() < 2:
			thighs.append(i)
		elif ("lowerleg" in bn or "shin" in bn or "calf" in bn or "leg" in bn) and shins.size() < 2:
			shins.append(i)              # Mixamo "LeftLeg" IS the shin (thigh matched above first)
		elif ("forearm" in bn or "lowerarm" in bn or "elbow" in bn) and forearms.size() < 2:
			forearms.append(i)
		elif ("upperarm" in bn or ("arm" in bn and "armature" not in bn)) and upperarms.size() < 2:
			upperarms.append(i)          # Mixamo "LeftArm" IS the upper arm (forearm matched first)


# ---------------- internals ----------------

# Save the original local pose rotation once, then write the new one (orthonormalized -> Quaternion).
static func _set_local(skel: Skeleton3D, idx: int, b: Basis, orig: Dictionary) -> void:
	if not orig.has(idx):
		orig[idx] = skel.get_bone_pose_rotation(idx)
	skel.set_bone_pose_rotation(idx, b.orthonormalized().get_rotation_quaternion())


static func _has_ancestor_in(skel: Skeleton3D, idx: int, pool: Array[int]) -> bool:
	return _ancestor_of(skel, idx, pool) >= 0


# WHICH pool bone is an ancestor of idx (-1 = none) — ride() needs the owning thigh, not just a bool.
static func _ancestor_of(skel: Skeleton3D, idx: int, pool: Array[int]) -> int:
	var p := skel.get_bone_parent(idx)
	while p >= 0:
		if p in pool:
			return p
		p = skel.get_bone_parent(p)
	return -1


static func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n as Skeleton3D
	for c in n.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null


# Capture the character's CURRENT animated pose, then stop the player so it can't re-stomp the pose
# sit/ride/swim are about to write. Returns the state `stand()` needs to resume.
#
# THE advance(0.0) IS THE WHOLE POINT. `AnimationPlayer.play()` only SCHEDULES a clip — the skeleton
# is not actually posed until the animation step runs later in the frame. Freezing in the same frame
# a clip started therefore captured the REST pose, and a rest pose on these rigs is a T-POSE. That is
# what made a player who spawns in deep water float with their arms straight out: the avatar attaches,
# `_play_hero("idle")` calls play(), `_enter_swim()` fires before the animation step, and the T-pose
# gets frozen for the entire swim. Boarding a vehicle or mounting on the first frame did the same.
# advance(0.0) forces the pose to be applied NOW, so what we freeze is what the player was showing.
static func _freeze_anim(character: Node3D) -> Dictionary:
	var ap := _find_anim_player(character)
	if ap == null or not ap.is_playing():
		# Nothing playing: there is no pose to preserve and nothing to stop. Callers still write their
		# own bone edits on top, which is the same behaviour as before.
		return {"player": ap, "anim": "", "anim_pos": 0.0}
	ap.advance(0.0)
	var st := {
		"player": ap,
		"anim": String(ap.current_animation),
		"anim_pos": ap.current_animation_position,
	}
	ap.pause()
	return st


static func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n as AnimationPlayer
	for c in n.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null


# ---------------------------------------------------------------------------
# RIG METROLOGY — one implementation of "how tall is this character, and where
# are its hips". Shared because the answer used to be written out per call site,
# and the copies DRIFTED: enemy.gd's grew the mesh-envelope + full-transform
# fixes while main.gd's stayed bones-only, so the same GLB measured differently
# depending on whether it spawned as the hero or as an enemy. One copy can still
# be wrong; three copies are guaranteed to disagree.
# ---------------------------------------------------------------------------

# TRUE height of a character model, in `node`'s own frame.
#
# BONES ALONE ARE NOT THE ANSWER. A bone-origin span runs from the lowest bone
# origin (the ankle/toe, ABOVE the sole) to the highest (the `head` bone, which
# sits at the NECK — not the top of the skull). On a realistically-proportioned
# rig that under-reads by ~10%, which is survivable. On a stylized kit it is
# catastrophic: KayKit's chibi skull is 1.08m of a 2.27m figure, so the bone span
# reads 1.24 and the caller — dividing a target height by it — scales the model
# UP by 1.33x and renders a 3m player. That is the "characters look too big" bug.
#
# So: union the BONE span with the MESH ENVELOPE and take what the player can
# actually SEE. Full transforms, not a scalar scale.y walk, because a Meshy/
# Blender rig carries a -90deg X conversion (its height axis is local Z) and a
# 0.01-scale Armature over cm-unit bones — a Y-only walk under-measured a rotated
# rig ~3.5x. Richest skeleton wins: a Meshy GLB can ship a 1-bone eye rig beside
# the body rig. Returns 0.0 when there is nothing measurable.
static func char_height(node: Node3D) -> float:
	var lo := 1e9
	var hi := -1e9
	var sks := node.find_children("*", "Skeleton3D", true, false)
	var s: Skeleton3D = null
	for sk in sks:
		if s == null or (sk as Skeleton3D).get_bone_count() > s.get_bone_count():
			s = sk as Skeleton3D
	if s != null and s.get_bone_count() > 0:
		var sxf := xf_to(s, node)
		for i in s.get_bone_count():
			var by := (sxf * s.get_bone_global_rest(i).origin).y
			lo = minf(lo, by)
			hi = maxf(hi, by)
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var mxf := xf_to(m, node)
		var ab := m.get_aabb()
		for fx in [0.0, 1.0]:
			for fy in [0.0, 1.0]:
				for fz in [0.0, 1.0]:
					var wy := (mxf * (ab.position + Vector3(ab.size.x * fx, ab.size.y * fy, ab.size.z * fz))).y
					lo = minf(lo, wy)
					hi = maxf(hi, wy)
	if hi <= lo:
		return 0.0
	return hi - lo


# Height of the character's HIPS above its own origin (the feet), in `node`'s
# frame. This is the seat datum: put the hips on a cushion and the character is
# sitting on it, whatever its proportions.
#
# It replaces a `HIP_RATIO * height` constant. A single ratio cannot serve this
# library: a realistic humanoid's hips sit at ~0.52 of its height, a KayKit chibi's
# at 0.178 — the head eats the difference. Seating a chibi with the realistic
# ratio drops its origin ~0.5m too far and buries it in the floor; the reverse
# leaves a realistic driver hovering. Measuring costs one bone lookup.
#
# Returns 0.0 when no hip bone resolves, which is the caller's cue to fall back to
# its own ratio — an unrigged capsule has no hips to find.
static func hips_height(node: Node3D) -> float:
	var sks := node.find_children("*", "Skeleton3D", true, false)
	var s: Skeleton3D = null
	for sk in sks:
		if s == null or (sk as Skeleton3D).get_bone_count() > s.get_bone_count():
			s = sk as Skeleton3D
	if s == null or s.get_bone_count() == 0:
		return 0.0
	var sxf := xf_to(s, node)
	# The rig's own floor, not the node origin: measure hips RELATIVE to the lowest
	# bone, so a model whose origin sits at the hips (most character GLBs) reports
	# the same hip height as one whose origin sits at the feet.
	var floor_y := 1e9
	for i in s.get_bone_count():
		floor_y = minf(floor_y, (sxf * s.get_bone_global_rest(i).origin).y)
	# A PERSON's datum is the map's (GRig.seat_point): its pelvis-named bone, as before — or, where no name gives the hips
	# (Rigify's DEF-spine, Auto-Rig Pro's root.x), the hip joints plus the library's measured pelvis height over them.
	# By name alone a Rigify villager read 0 here and was seated by the callers' 0.52 x height fallback, 0.34 m into its
	# bench; a Rigify knight 1.11 m.
	var seat = GRig.seat_point(s, node, GRig.of(node))
	if seat != null:
		return maxf(0.0, (seat as Vector3).y - floor_y)
	for i in s.get_bone_count():
		var bn := s.get_bone_name(i).to_lower()
		if not _is_hip_bone(bn):
			continue
		var hy := (sxf * s.get_bone_global_rest(i).origin).y - floor_y
		if hy > 0.0:
			return hy
	return 0.0


# Is this bone the pelvis? Reduce the name to a bare token and compare EXACTLY,
# rather than substring-matching "hip" — which would happily accept a "shipmast"
# or "chip" bone and hand back a seat datum from the wrong part of the model.
static func _is_hip_bone(bn: String) -> bool:
	var t := _bone_token(bn)
	return t == "hips" or t == "hip" or t == "pelvis"


# A bone name reduced to its bare token — the ONE reduction every bone-by-name test in this file
# shares, so the seat datum (_is_hip_bone) and the body plan (body_fit) can never disagree about
# which bone is the pelvis. Covers KayKit/Rigify ("hips"), Blender duplicates ("hips.001"), Rigify's
# generated prefixes ("DEF-hips") and the library animals' "b_Hip_01" (the fox), which the seat test
# used to read as "b_hip" — no pelvis at all. And the humanoid exporters that name every bone after
# the rig: Mixamo ("mixamorig:Hips" — a Skeleton3D bone name can hold no ':', so the glTF importer
# hands it over as "mixamorig_Hips"), Character Creator ("CC_Base_Hip"), 3ds Max Biped ("Bip01
# Pelvis") and VRoid ("J_Bip_C_Hips"). Read as no pelvis and no head, a person on any of them was a
# creature to body_fit and stood in a T-pose-wide box.
static func _bone_token(bn: String) -> String:
	var t := bn.to_lower()
	for sep in [":", "|", "/"]:
		var k: int = t.rfind(sep)
		if k >= 0:
			t = t.substr(k + 1)
	var us := t.find("_")
	if t.begins_with("mixamorig") and us >= 9 and (us == 9 or t.substr(9, us - 9).is_valid_int()):
		t = t.substr(us + 1)             # "mixamorig_hips", "mixamorig1_head"
	var sp := t.find(" ")
	if t.begins_with("bip") and sp > 3 and t.substr(3, sp - 3).is_valid_int():
		t = t.substr(sp + 1)             # "bip01 pelvis", "bip001 head"
	for p in ["def-", "def_", "mch-", "org-", "b_", "cc_base_", "j_bip_c_"]:
		if t.begins_with(p):
			t = t.substr(String(p).length())
	while t.length() > 0 and ("0123456789._- ".find(t[t.length() - 1]) >= 0):
		t = t.substr(0, t.length() - 1)
	return t


# ---------------------------------------------------------------------------
# THE BODY A MODEL DRAWS — measured once per model, read by everything that
# asks how big a character is or where its body ends.
#
# A skinned mesh's get_aabb() is its UN-SKINNED bind geometry, and it lies both
# ways: a Meshy villager reads 0.018 m, the library velociraptor 3.8 m for a
# 12.7 m animal, the T-rex 93 m for a 31 m one. Bones alone lie too — they are
# joints, not flesh (the horse's nose runs 0.36 m past its head bone), and IK
# pole targets are skin-bound bones that sit metres off the mesh (easy_Frog's
# bone span is 5.4 m for a 3.2 m frog). What the renderer draws is every
# vertex pushed through bone pose * bind pose, so that is what is measured:
# CPU skinning of at most FIT_SAMPLES vertices per surface.
# ---------------------------------------------------------------------------
const FIT_SAMPLES := 2000         # vertices skinned per surface for the REST extent
const FIT_POSES := 8              # phases sampled per clip the character plays
const FIT_POSE_SAMPLES := 600     # vertices skinned per surface per sampled phase
const STRIKE_PHASES := 12         # phases of an attack clip read for how far it reaches and when (body_fit's strike)
const PERSON_TILT_DEG := 45.0     # pelvis -> head within this of vertical = it stands like a person
static var _rest_memo := {}       # "mesh/skin" -> AABB: one skinned mesh's drawn rest, in its own frame
static var _fit_memo := {}        # "mesh/skin,...#<phases>[p][/<slices>][@<strike>][!<fast>]|clip,..." -> body_fit's answer, per MODEL
static var _fit_measures := 0     # cold body_fit measurements taken (the people rig reads it: once per model)
static var _pts_memo := {}        # "mesh/skin,...#<cap>" -> drawn_rest_points' answer, per MODEL
static var _pose_memo := {}       # "mesh/skin,...#<tag>/<slices>" -> posed_fit's answer, per MODEL and posture


## What a SKINNED mesh draws in its rest pose, in the mesh instance's own frame — the number
## get_aabb() is taken to mean everywhere else. A mesh with no skin answers get_aabb() itself.
## Memoised per mesh + skin resource (a cache duplicate shares both with its source).
static func drawn_rest(mi: MeshInstance3D) -> AABB:
	if mi == null or mi.mesh == null:
		return AABB()
	var skel := _skin_skeleton(mi)
	if skel == null:
		return mi.get_aabb()
	var key := _mesh_key(mi)
	if _rest_memo.has(key):
		return _rest_memo[key]
	var rest: Array[Transform3D] = []
	for i in skel.get_bone_count():
		rest.append(skel.get_bone_global_rest(i))
	var mats := _bind_mats(mi, skel, rest)
	# THE COMMON CASE IS EXACT AND FREE. When every bind skins with one and the same transform — a rig
	# whose rest IS its bind pose (the horse, the troll, kk_Knight), or a Meshy rig whose scale is baked
	# into every bind alike (the villagers' x100) — skinning is that one transform, and the importer's
	# AABB carried through it is the drawn extent to the vertex. Only a rig whose rest pose has moved off
	# its bind pose (the velociraptor, the T-rex, the rat) is skinned vertex by vertex, and sampled:
	# striding a troll's 14k vertices lost 7 cm of its depth.
	var same := not mats.is_empty()
	for m in mats:
		if not m.is_equal_approx(mats[0]):
			same = false
			break
	var ab := (mats[0] * mi.get_aabb()) if same else _skinned_extent(mi, [mats], FIT_SAMPLES)
	if ab.size == Vector3.ZERO and ab.position == Vector3.ZERO:
		ab = mi.get_aabb()   # nothing skinnable on it: the mesh's own bounds are all there is
	_rest_memo[key] = ab
	return ab


## WHAT A MODEL DRAWS, merged over its whole subtree, in `root`'s PARENT frame (root's own transform
## included): the box every size decision downstream is taken on — populate's normalisation, the far
## stand-ins, a prop's footprint cap, grounding and its collider (AreaBuilder._world_aabb). Each mesh is
## measured by drawn_rest, memoised per mesh + skin; the walk itself is transforms only and is not, because
## what stands between `root` and its meshes is the caller's (a populate wrap, a normalised model).
##
## DETACHMENT-SAFE: accumulates transforms manually. This is almost always called on freshly-duplicated,
## NOT-YET-PARENTED models (grounding + scale normalization) — there `global_transform` returns IDENTITY
## and spams "!is_inside_tree()" errors, silently producing wrong AABBs whenever inner GLB node transforms
## matter (a root cause of the old floating/sunk-prop class of bugs).
static func drawn_aabb(root: Node3D) -> AABB:
	var merged := AABB()
	var first := true
	var stack: Array = [[root, root.transform]]
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
			# WHAT IT DRAWS: a skinned mesh's get_aabb() is its un-skinned bind geometry, which lies
			# both ways (a Meshy villager 0.018 m, the velociraptor 3.8 m for a 12.7 m animal, the
			# T-rex 93 m for 31) — and every size decision downstream (populate's normalisation, the
			# far stand-ins, a prop's footprint cap, grounding and collider) was taken on that lie.
			# drawn_rest skins it (memoised; a mesh with no skin is its get_aabb()).
			var wa: AABB = xf * drawn_rest(n as MeshInstance3D)
			if first:
				merged = wa
				first = false
			else:
				merged = merged.merge(wa)
	return merged


## What a model draws at rest as POINTS, in `node`'s own frame (node.transform excluded, like body_fit):
## every sampled vertex pushed through bone rest * bind — drawn_rest's skinning, point by point — at most
## `cap` per surface; a mesh with no skin gives its own vertices. For what needs the SHAPE of a body rather
## than its box: the underside a mount rests on, the seat a person sits on, the soles they stand on.
## Memoised per MODEL and cap, on the same mesh + skin key as body_fit.
static func drawn_rest_points(node: Node3D, cap := FIT_SAMPLES) -> PackedVector3Array:
	var ids := PackedStringArray()
	for mi: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh != null:
			ids.append(_mesh_key(mi))
	var key := ",".join(ids) + "#%d" % cap
	if ids.size() > 0 and _pts_memo.has(key):
		return _pts_memo[key]
	var out := PackedVector3Array()
	for mi: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		var xf := xf_to(mi, node)
		var skel := _skin_skeleton(mi)
		var mats: Array[Transform3D] = []
		if skel != null:
			var rest: Array[Transform3D] = []
			for i in skel.get_bone_count():
				rest.append(skel.get_bone_global_rest(i))
			mats = _bind_mats(mi, skel, rest)
		for p in _skinned_points(mi, mats, cap):
			out.append(xf * p)
	if ids.size() > 0:
		_pts_memo[key] = out
	return out


## THE BODY A MODEL HAS — {ok, rest: AABB, aabb: AABB, person: bool, pelvis: bool, tilt: deg}, in `node`'s own frame
## (node.transform excluded, like char_height).
##   rest   = its drawn rest extent: the model's SIZE (what populate normalises) and a person's height.
##   aabb   = rest plus `phases` phases (FIT_POSES unless a role asks otherwise) of every clip in `clips` —
##            the poses it will actually show. Rest alone under-covers a swaying tail, a head dipped to
##            graze or a lunge (the raptor's attack reaches 0.15 m past its rest box, the frog's 0.72 m).
##            A person skips this unless `pose_persons`: their capsule is sized from the rest pose
##            (GBody.from_extent), so a townsfolk crowd pays for its rest pose only. (Their idles are
##            gestures — a villager's arms cross 0.62 m out in front — and a slim capsule that lets an
##            arm overlap the player is the policy.) A body that is not a person's capsule — a mount
##            built on a humanoid rig, whose gallop is its whole body — asks for its clips anyway.
##   person = a pelvis bone with the head bone ABOVE it, within PERSON_TILT_DEG of vertical. Measured
##            on 37 GLBs: every humanoid rig 0-24 deg (Meshy, KayKit, troll, heron, bog_lurker), every
##            horizontal-spine animal >= 52 (llama 52, raptor 63, horse 66, fox 74); rigs with no
##            pelvis (Rig Lab archetypes, bats, snakes, fish) are not people. A person's rest WIDTH is
##            a T-pose and lies (1.5-1.9 m of arms), so a person's body is a capsule, not this box.
##   pelvis, tilt = what that judgement read: a pelvis bone found; the head's angle off vertical (-1: no pair).
##   slices = (only when `slices` > 0) the poses' points (the rest pose's only when no clip is posed) cut into that
##            many equal bands along z, nose to tail: one box each (AABB() for a band nothing falls in). One box round a
##            whole creature held too much air: a raptor's tail band is a third of its height, its head band reaches no
##            lower than its neck — an enemy's body (GBody, role "enemy") is these boxes (enemy-bodies review: one box
##            over every clip left a median 38% of the hits on 71 models in the air, five bands 16-22%).
##   bands  = (with slices) the same bands kept SET BY SET on one grid — each clip's poses, and the rest pose's (key ""),
##            {z0, dz, n, by: {key: [[lo, hi] or null] a band}} — so a body of any clips together is band_boxes(bands,
##            keys): an enemy parks in its idle's and moves in its gaits' (enemy.gd _shown).
##   strike = (only when `strike` names a clip) how that clip reaches: {clip, front: the furthest +Z it draws (the
##            model's forward), phase: the fraction of the clip where it reaches it — the CONTACT, when a bite or a blow
##            lands; -1 for an attack that never reaches forward — and len: the clip's length}, over STRIKE_PHASES
##            phases; sampled for a person too (their capsule is their rest pose; when their swing lands is the clip's).
##            {} when nothing could be read.
## `fast`: clips among `clips` sampled at twice `phases` (an enemy's flight: a wingbeat's keys fall between 12).
## Memoised per MODEL (its meshes + skins, the clip list, the phases, pose_persons, the slices, the strike clip, fast): a
## crowd pays once, not per member — the mesh and skin resources are what every duplicate of a cached GLB shares, so the
## key is never a node's (no meta, nothing per instance). The cold cost belongs in area_builder's parse loop (see
## _prewarm_fit there), not in the frame that places it.
static func body_fit(node: Node3D, clips: PackedStringArray = PackedStringArray(), phases := FIT_POSES, pose_persons := false, slices := 0, strike := "", fast := PackedStringArray()) -> Dictionary:
	var job := fit_job(node, clips, phases, pose_persons, slices, strike, fast)
	while not job.step(-1):
		pass
	return job.fit


## The same measurement as a job a caller can work A PIECE AT A TIME (FitJob.step): the parse-time warm's (AreaBuilder.
## _fit_drain), where one creature's fit was 17-143 ms of one frame once its body was cut into slices (desktop, 2026-10-05).
## Already memoised: a job that is done before it starts.
## `dense`: the box over every pose skinned at the slices' sample (FIT_SAMPLES and the rest's bounding vertices), not the
## crowd's FIT_POSE_SAMPLES — a ridden mount's hull is that box with nothing swept round it (F1), and at 600 a surface the
## library stegosaurus drew 0.053 m and the rat 0.026 m past it in their own gaits (2000 + bounding: 0.000; 2026-10-05).
## `keel`: and what it draws WITHOUT ITS LEGS (GRig.legs) in each of those poses and at rest, as the underside it rests on
## (keel_points): fit["keel"] {"": [the rest's], clip: [one a phase]}, in node's frame — a mount's while its feet stand on the
## ground (GFeet; Vehicle._keel_now). Its hooves in it, the body rode on whichever hoof was lowest and the others hung 0.12-
## 0.73 m off a crest; its rest pose for it, a lowered head or a swinging tail went under (hoof-crest).
## `ground`: and for a PERSON, how low each of its clips draws its soles (fit["ground"]: ground_rise reads it).
static func fit_job(node: Node3D, clips: PackedStringArray = PackedStringArray(), phases := FIT_POSES, pose_persons := false, slices := 0, strike := "", fast := PackedStringArray(), dense := false, keel := false, ground := false) -> FitJob:
	return FitJob.new(node, clips, phases, pose_persons, slices, strike, fast, dense, keel, ground)


## A PERSON'S CLIPS STAND ON THE GROUND THEIR REST POSE STANDS ON (step 5d). A person is grounded by its rest pose — the lowest
## thing it draws at rest on its feet (populate, an enemy's feet-at-origin rig, a named NPC) — and each clip carries its own
## ground: walking, a Meshy villager's soles stood 4.6-6.5 cm over flat ground, a fisher's 6.4-7.7, the warden's 6.2-9.1; a
## KayKit skeleton enemy's 1.1-6.7 cm into it, a troll's 5.2-15.7; standing, a smuggler's idle floated 5.5 cm (step 5d, as drawn
## on the real populate and enemy; hoof-crest had 6.5 and 11). So the fit reads, for a person, the soles it draws — every vertex
## within GROUND_BAND of its height over its lowest point at rest, of each bone's those furthest every way (_DIRS26) — and how
## low each of its clips draws them at GROUND_PHASES phases: fit["ground"] = {"rest": the rest's lowest, "low":
## {clip: its lowest, a phase each}, "feet": {clip: each foot's GROUND_K points (_support), a phase each}, "rest_feet": each
## foot's points at rest, "k": GROUND_K, "lowest": {clip: the phase it draws them lowest at}, "reach": the furthest any of them
## stands from its origin across the ground} (node frame; a FOOT is a leg's every bind, else a bind's own) — and its consumers
## stand the model on the ground under those (ground_rise). Read off a sample of 2000 a surface, the soles missed their lowest
## point by up to 5.2 cm (the troll's walk); every vertex, 0-4 mm. At 16 phases a smuggler running down the 17 deg grade went
## 3.2 cm into it between two (24: 2.3, 32: 2.0) and a troll walked 2.2 cm into flat ground (32: 1.6); the fit 43.5 ms -> 49.9.
const GROUND_PHASES := 32
const GROUND_BAND := 0.08


## THE RISE THAT STANDS A PERSON ON THE GROUND UNDER ITS FEET — from its fit's ground table `g`: where its `clip` draws each foot
## lowest, a WALK at its phase (`pos` of `length` s: a walk has a foot down at every phase, so its lowest is on the ground at
## every one) and any other clip at its lowest moment (a run keeps its leap, an idle its weight shifting, an attack its lunge),
## a clip the table does not hold (none) as its rest — the most any foot needs to be on the ground: on flat ground the lowest
## sole on it; on a slope none in it — stood on its planted feet alone, a villager's swinging foot went 0.081 m into a 17 deg
## grade walking up it and 0.053 across it (the people rig's (l2)). In its parent's units along its +Y (`parent`: the model's
## parent in the world, upright; `model`: the model's transform in it, as it would stand with no rise). NAN: no table (no person).
## THE GROUND: the terrain `t`'s where `at` (where it stands) is within GBody.LEAN_ON of it, else level at `at` — on a deck, a
## floor, a bridge the terrain under it is no ground of its (a lean read off it drew an enemy 2.0 m into a 2 m deck: step 5c's
## review) — and READ ONLY WHERE IT TILTS: with no terrain, or every quad its soles reach level at one height (GTerrain.
## level_under, through `cache`: height_cached's), its lowest sole is a number off its table and nothing is read; on a grade,
## the terrain once where it stands and once under each foot (ground_reads counts them). Read under every foot on flat ground,
## a walking person's tick went from 16.3 to 23-29 us and a person enemy's frame from 0.5 to 11.3 (step 5d's review).
static var ground_reads := 0     # heights of the terrain a person's soles were stood against, ever (the rigs count what a tick reads)
static func ground_rise(g: Dictionary, clip: String, phased: bool, pos: float, length: float, parent: Transform3D, model: Transform3D,
		t: GTerrain, cache: Dictionary, at: Vector3) -> float:
	if g.is_empty():
		return NAN
	var M := parent * model
	var sig := maxf(parent.basis.y.length(), 1e-6)
	var lv := at.y
	if t != null:
		var rr := float(g["reach"]) * maxf(M.basis.x.length(), M.basis.z.length())
		lv = t.level_under(Rect2(M.origin.x - rr, M.origin.z - rr, rr * 2.0, rr * 2.0).expand(Vector2(at.x, at.z)), cache)
		if not is_finite(lv):
			ground_reads += 1
			if absf(at.y - t.height_cached(at.x, at.z, cache)) > GBody.LEAN_ON:
				lv = at.y
		elif absf(at.y - lv) > GBody.LEAN_ON:
			lv = at.y
	# its feet as the moment draws them: a walk's lerped between the two phases either side, another clip's at its lowest moment
	# — and on a grade never below what its feet need at the moment it is at (a stride's front foot reaches up a slope its
	# lowest moment does not: a smuggler running up the 17 deg grade on that alone went 10.6 cm into it)
	var feet: Array = (g["feet"] as Dictionary).get(clip, [])
	if feet.is_empty():
		return _rise_at(g["rest_feet"], g["rest_feet"], 0.0, M, sig, lv, t, cache, int(g["k"]))
	var n := feet.size()
	var f := fposmod(pos / length, 1.0) * float(n) if length > 0.0 else 0.0
	var i := floori(f) % n
	if phased and length > 0.0:
		return _rise_at(feet[i], feet[(i + 1) % n], f - floorf(f), M, sig, lv, t, cache, int(g["k"]))
	var low: PackedVector3Array = feet[int((g["lowest"] as Dictionary)[clip])]
	var r := _rise_at(low, low, 0.0, M, sig, lv, t, cache, int(g["k"]))
	if not is_finite(lv) and length > 0.0:
		r = maxf(r, _rise_at(feet[i], feet[(i + 1) % n], f - floorf(f), M, sig, lv, t, cache, int(g["k"])))
	return r


# ground_rise's rise for the feet `a` lerped `fr` of the way to `b` (each foot's GROUND_K points, node frame) under `M` (node to
# world), on level ground at `lv` — upright, its feet's lowest is all it takes — or, `lv` NAN, on the terrain `t`: the plane
# the terrain draws under each foot read once (GTerrain.plane_cached), and every point of the foot stood on it.
static func _rise_at(a: PackedVector3Array, b: PackedVector3Array, fr: float, M: Transform3D, sig: float, lv: float, t: GTerrain,
		cache: Dictionary, K: int) -> float:
	if is_finite(lv) and absf(M.basis.x.y) + absf(M.basis.z.y) <= 1e-4 * M.basis.y.y:
		var lo := INF
		for k in range(0, a.size(), K):
			var ya := a[k].y
			var yb := b[k].y
			lo = minf(lo, ya if not is_finite(yb) else (yb if not is_finite(ya) else lerpf(ya, yb, fr)))
		return (lv - M.origin.y - M.basis.y.y * lo) / sig if is_finite(lo) else NAN
	var best := -INF
	for f0 in range(0, a.size(), K):
		var pl := Vector3(NAN, 0.0, 0.0)
		var pw := Vector3.ZERO
		for k in range(f0, f0 + K):
			var p := a[k] if not b[k].is_finite() else (b[k] if not a[k].is_finite() else a[k].lerp(b[k], fr))
			if not p.is_finite():
				continue
			var w := M * p
			var h := lv
			if not is_finite(lv):
				if not is_finite(pl.x):
					ground_reads += 1
					pl = t.plane_cached(w.x, w.z, cache)
					pw = w
				h = pl.x + pl.y * (w.x - pw.x) + pl.z * (w.z - pw.z)
			best = maxf(best, (h - w.y) / sig)
	return best if is_finite(best) else NAN


## BODY_FIT IN PIECES: its rest; with slices or a strike, each mesh's vertices read for the ones that bound it SCAN_VERTS at
## a time and its sample taken; one pose of one clip of one mesh, or one phase of its attack, or its rest; and with slices,
## one pose's points (and triangles) cut into the bands — each piece a few milliseconds at most, in the order the answer
## is built in. step(deadline) works until Time.get_ticks_usec() passes `deadline` (at least one piece; -1: to the end)
## and says whether it is done; done, `fit` is the answer, memoised under body_fit's key. Cut into bands in one piece, a
## T-rex's last piece was 83 ms and a horse's 34 of a 6 ms frame budget, and a 15k-vertex Meshy model's bounding scan 13
## (desktop, 2026-10-05).
class FitJob extends RefCounted:
	var node: Node3D
	var clips: PackedStringArray
	var phases := FIT_POSES
	var pose_persons := false
	var slices := 0
	var strike := ""
	var fast := PackedStringArray()
	var dense := false
	var keel := false
	var key := ""
	var keyed := false
	var done := false
	var fit := {}
	var _begun := false
	var _units: Array = []            # [kind, mesh, clip|surface, phase|first vertex]: "rest", "scan", "samp", "pose",
	#                                   "strike", "cut", "band"
	var _ui := 0
	var _mis: Array = []              # the meshes, in find_children order
	var _prep := {}                   # mesh index -> what its poses start from (prepared at its first piece)
	var _first := true
	var _rest := AABB()
	var _mbox := {}                   # mesh index -> [lo, hi] of its posed extent, in ITS frame (the crowd's and a mount's)
	var _plo := Vector3.INF           # every posed clip's points' extent, node frame (the aabb)
	var _phi := -Vector3.INF
	var _sets: Array = []             # [key ("" the rest pose), mesh index, its points in node's frame], one a pose cut
	var _keys: Array = []             # the keys of _sets, in order
	var _zlo := INF                   # ...and how far along z they all reach: the bands' grid
	var _zhi := -INF
	var _blo := {}                    # key -> each band's lo (the bands, cut a pose at a time)
	var _bhi := {}
	var _fronts := PackedFloat32Array()
	var _person := false
	var _pelvis := false
	var _tilt := -1.0
	var _ap: AnimationPlayer = null
	var _aroot: Node = null
	var _san: Animation = null
	var _posed := false
	var _legs := {}                   # the bones of its legs (GRig.legs: the keel leaves them out) ...
	var _keels := {}                  # ... and its keel, "" -> [the rest's], clip -> [a phase each]
	var ground := false
	var _gsf := {}                    # "mesh/surface" -> its arrays and its soles' candidates (gsel), until they are cut (gcut)
	var _gparts: Array = []           # a body of parts: [a leg's mesh, its furthest points in its own frame] (pcut)
	var _ggrp := {}                   # mesh index -> the foot each of its soles is (a leg of it: one id a vertex, its sample's order)
	var _gleg := {}                   # a leg's thigh bone -> its foot's id (every bind under it one foot)
	var _gn := 0                      # ... how many feet
	var _grf := PackedVector3Array()  # each foot's GROUND_K points at rest (node frame) ...
	var _grs := PackedFloat32Array()  # ... how far each reaches its way
	var _gfeet := {}                  # clip -> each foot's GROUND_K points, a phase each
	var _gs := {}                     # mesh index -> its soles (a person's: ground), as _sample keeps a sample ...
	var _glow := {}                   # clip -> its soles' lowest, a phase each (node frame)
	var _gy0 := INF                   # ... and the rest's

	func _init(n: Node3D, c: PackedStringArray, ph: int, pp: bool, sl: int, st: String, fa: PackedStringArray, de := false, ke := false, gr := false) -> void:
		node = n
		clips = c
		phases = ph
		pose_persons = pp
		slices = sl
		strike = st
		fast = fa
		dense = de
		keel = ke
		ground = gr
		var ids := PackedStringArray()
		for mi: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
			if mi.mesh != null:
				ids.append(GPose._mesh_key(mi))
		keyed = ids.size() > 0
		key = ",".join(ids) + "#%d%s%s%s%s" % [phases, "p" if pose_persons else "", "d" if dense else "", "k" if keel else "", "g" if ground else ""] + ("/%d" % slices if slices > 0 else "") \
			+ ("@" + strike if strike != "" else "") + ("!" + ",".join(fast) if not fast.is_empty() else "") + "|" + ",".join(clips)
		if keyed and GPose._fit_memo.has(key):
			fit = GPose._fit_memo[key]
			done = true

	func step(deadline: int) -> bool:
		if done:
			return true
		if not _begun:
			_begin()
			if done:
				return true
		while _ui < _units.size():
			_unit(_units[_ui])
			_ui += 1
			if deadline >= 0 and Time.get_ticks_usec() > deadline:
				break
		if _ui < _units.size():
			return false
		_finish()
		return true

	# WHO FIRST: the body plan decides whether the clip poses are worth sampling at all.
	# The verdict is the humanoid map's (GRig): today's pelvis and head tokens within PERSON_TILT_DEG for every rig that
	# had them, and an upright two-legged body with a head on top for one whose names do not (Rigify, Auto-Rig Pro,
	# MakeHuman, an anonymous rig — creatures in a T-pose-wide box until 2026-10-04), or a body of parts (Kenney).
	func _begin() -> void:
		_begun = true
		GPose._fit_measures += 1
		var rig := GRig.of(node)
		_person = bool(rig.get("person", false))
		_pelvis = bool(rig.get("pelvis", false))
		_tilt = float(rig.get("tilt", -1.0))   # head over pelvis, degrees off vertical; -1 = not both found
		for mi: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
			if mi.mesh != null:
				_mis.append(mi)
		if _mis.is_empty():
			fit = {"ok": false, "rest": AABB(), "aabb": AABB(), "person": _person, "pelvis": _pelvis, "tilt": _tilt}
			_end()
			return
		_ap = GPose._find_anim_player(node)
		_aroot = _ap.get_node_or_null(_ap.root_node) if _ap != null else null
		_posed = (pose_persons or not _person) and _ap != null and not clips.is_empty()
		_san = _ap.get_animation(strike) if _ap != null and strike != "" and _ap.has_animation(strike) else null
		if _san != null:
			_fronts.resize(STRIKE_PHASES)
			_fronts.fill(-INF)
		for i in _mis.size():
			_units.append(["rest", i, "", 0])
		# THE SAMPLE THE SLICES, THE STRIKE, A DENSE BOX AND A KEEL ARE SKINNED AT (_sample's, bounding vertices and all), its
		# scan in pieces
		var cut := slices > 0 or _san != null or dense or keel
		if cut:
			for i in _mis.size():
				var mesh: Mesh = (_mis[i] as MeshInstance3D).mesh
				for sf in mesh.get_surface_count():
					var nv: int = mesh.surface_get_array_len(sf)
					if nv > GPose.FIT_SAMPLES:   # skinned whole within it: nothing to bound (every vertex is in)
						for v0 in range(0, nv, GPose.SCAN_VERTS):
							_units.append(["scan", i, sf, v0])
				_units.append(["samp", i, "", 0])
		var sets := 0
		for i in _mis.size():
			if GPose._skin_skeleton(_mis[i]) == null:
				continue
			if _posed:
				for c in clips:
					if c == "" or not _ap.has_animation(c):
						continue
					var n := phases * (2 if fast.has(c) else 1)
					for ph in n:
						_units.append(["pose", i, c, ph, n])
						sets += 1 if slices > 0 else 0
			if _san != null:
				for ph in STRIKE_PHASES:
					_units.append(["strike", i, "", ph])
		# THE KEEL: what it draws without its legs, at rest and in every pose of every clip — one piece a pose, every mesh of
		# it (the slices' sample, read above)
		if keel:
			var sk := GPose.skeleton_of(node)
			for L in GRig.legs(node):
				for top in [int(L["upper"]), int(L["foot"])]:
					var st: Array = [top]
					while not st.is_empty():
						var b: int = st.pop_back()
						_legs[b] = true
						st.append_array(sk.get_bone_children(b))
			if not _legs.is_empty():
				_units.append(["keel", -1, "", 0, 1])
				if _posed:
					for c in clips:
						if c != "" and _ap.has_animation(c):
							for ph in phases:
								_units.append(["keel", -1, c, ph, phases])
		# A PERSON'S SOLES, AND HOW EACH CLIP STANDS ON THEM (`ground`): every vertex where its rest draws it, SCAN_VERTS a piece,
		# the soles kept; then a phase of a clip a piece (not its swim: afloat it stands on nothing)
		# A BODY OF PARTS (Kenney's) stands on its legs' parts: their furthest points, moved by the clip's node tracks.
		if ground and _person and _ap != null and not clips.is_empty():
			var parts := String(rig.get("kind", "")) == "nodes"
			if parts:
				_units.append(["pcut", -1, "", 0])
			else:
				for side in ["leg_l", "leg_r"]:
					var th := int((rig.get(side, {}) as Dictionary).get("thigh", -1))
					if th >= 0 and not _gleg.has(th):
						_gleg[th] = _gnew()
				for i in _mis.size():
					if GPose._skin_skeleton(_mis[i]) == null:
						continue
					var mesh: Mesh = (_mis[i] as MeshInstance3D).mesh
					for sf in mesh.get_surface_count():
						for v0 in range(0, mesh.surface_get_array_len(sf), GPose.SCAN_VERTS):
							_units.append(["gsel", i, sf, v0])
				_units.append(["gcut", -1, "", 0])
			var swim := GClip.resolve(_ap, "swim")
			var gclips := Array(clips)
			if strike != "" and not gclips.has(strike):
				gclips.append(strike)   # an enemy's attack too (stood as its rest, a skeleton swung its feet 2.4 cm into flat ground)
			for c in gclips:
				if c != "" and c != swim and _ap.has_animation(c):
					for ph in GPose.GROUND_PHASES:
						_units.append(["pground" if parts else "ground", -1, c, ph, GPose.GROUND_PHASES])
		# THE BANDS' POINTS: every sampled vertex of each clip's poses, in node's frame, and the rest pose's as a set of its
		# own: a rest pose is no pose a creature holds while it plays a clip (the bind's wings or tail splayed), and held in
		# its body it is a wall where nothing is drawn — but it is what a creature with no clip for a state draws in it.
		if slices > 0:
			for i in _mis.size():
				_units.append(["cut", i, "", 0])
				sets += 1
			for k in sets:
				_units.append(["band", k, "", 0])

	# What every pose of mesh `i` starts from: its skeleton's rests decomposed (each phase starts from them), its bones parents
	# first, its frame in the node, and its vertices sampled for the extent (every FIT_POSE_SAMPLES-th: the crowd's and a
	# mount's box, as always) and for the slices and the strike (the rest's FIT_SAMPLES and the bounding vertices: the
	# "scan" and "samp" pieces, _sample's answer).
	func _prepped(i: int) -> Dictionary:
		if _prep.has(i):
			return _prep[i]
		var mi: MeshInstance3D = _mis[i]
		var d := {"xf": GPose.xf_to(mi, node), "skel": GPose._skin_skeleton(mi)}
		var skel: Skeleton3D = d["skel"]
		if skel != null:
			var rp := PackedVector3Array()
			var rr: Array[Quaternion] = []
			var rs := PackedVector3Array()
			for b in skel.get_bone_count():
				var r := skel.get_bone_rest(b)
				rp.append(r.origin)
				rr.append(r.basis.get_rotation_quaternion())
				rs.append(r.basis.get_scale())
			d["rp"] = rp
			d["rr"] = rr
			d["rs"] = rs
			d["order"] = GPose._bone_order(skel)
		_prep[i] = d
		return d

	func _samples(i: int, slice: bool) -> Array:
		var d := _prepped(i)
		var k := "cut" if slice else "ext"
		if not d.has(k):
			d[k] = GPose._sample(_mis[i], GPose.FIT_SAMPLES if slice else GPose.FIT_POSE_SAMPLES, slice)
		return d[k]

	func _mats_at(i: int, an: Animation, t: float) -> Array[Transform3D]:
		var d := _prepped(i)
		var tk := "tracks|" + String(an.resource_name) + "|%d" % an.get_instance_id()
		if not d.has(tk):
			d[tk] = GPose._bone_tracks(d["skel"], an, _aroot)   # once per clip, not once per phase
		return GPose._bind_mats(_mis[i], d["skel"], GPose._pose_at(d["skel"], an, d[tk], d["rp"], d["rr"], d["rs"], d["order"], t))

	# A new foot of a person's soles (ground): its id, its points at rest none yet.
	func _gnew() -> int:
		for k in GPose.GROUND_K:
			_grf.append(Vector3.INF)
			_grs.append(-INF)
		_gn += 1
		return _gn - 1

	# A phase of a clip's soles' lowest, and each foot's points, into its rows.
	func _ground_row(c: String, ph: int, n: int, lo: float, ft: PackedVector3Array) -> void:
		if not _glow.has(c):
			var row := PackedFloat32Array()
			row.resize(n)
			row.fill(INF)
			_glow[c] = row
			var fr: Array = []
			fr.resize(n)
			_gfeet[c] = fr
		var r: PackedFloat32Array = _glow[c]
		r[ph] = lo
		_glow[c] = r
		(_gfeet[c] as Array)[ph] = ft

	# A surface's arrays for its soles (gsel), read once: its vertices, its influences, and — where every bind's rest times its
	# bind pose is one transform (a rig bound at rest) — that transform into node's frame.
	func _gsurf(i: int, sf: int) -> Dictionary:
		var k := "%d/%d" % [i, sf]
		if _gsf.has(k):
			return _gsf[k]
		var mi: MeshInstance3D = _mis[i]
		var arr := GPose.surface_arrays(mi.mesh, sf)
		var skel := GPose._skin_skeleton(mi)
		var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX] if arr.size() > Mesh.ARRAY_VERTEX and arr[Mesh.ARRAY_VERTEX] != null else PackedVector3Array()
		var B = arr[Mesh.ARRAY_BONES] if arr.size() > Mesh.ARRAY_BONES else null
		var W = arr[Mesh.ARRAY_WEIGHTS] if arr.size() > Mesh.ARRAY_WEIGHTS else null
		var d := {"mesh": i, "skel": skel, "V": V, "B": B if B != null else PackedInt32Array(), "W": W if W != null else PackedFloat32Array(),
			"k": int((B as PackedInt32Array).size() / maxi(1, V.size())) if B != null else 0, "T": null,
			"ids": PackedInt32Array(), "ys": PackedFloat32Array()}
		var ms := GPose._bind_mats(mi, skel, GPose._rest_globals(skel))
		var one := not ms.is_empty()
		var tol := 1e-4 * maxf(ms[0].basis.get_scale().length(), 1e-6) if one else 0.0
		for m in ms:
			var dm := m.basis.x - ms[0].basis.x
			if dm.length() + (m.basis.y - ms[0].basis.y).length() + (m.basis.z - ms[0].basis.z).length() > tol \
					or m.origin.distance_to(ms[0].origin) > tol * 10.0:
				one = false
				break
		if one:
			d["T"] = (_prepped(i)["xf"] as Transform3D) * ms[0]
		_gsf[k] = d
		return d

	func _unit(u: Array) -> void:
		var i: int = u[1]
		match String(u[0]):
			"rest":
				var mi: MeshInstance3D = _mis[i]
				var ab := GPose.xf_to(mi, node) * GPose.drawn_rest(mi)
				_rest = ab if _first else _rest.merge(ab)
				_first = false
			"scan":
				# SCAN_VERTS of one surface read for the vertices that bound it (_sample_ids' scan, a piece of it)
				var d := _prepped(i)
				var scans: Dictionary = d.get("scans", {})
				var sf: int = u[2]
				if not scans.has(sf):
					scans[sf] = GPose._scan_begin((_mis[i] as MeshInstance3D).mesh, sf)
					d["scans"] = scans
				GPose._scan(scans[sf], int(u[3]))
			"samp":
				var d := _prepped(i)
				d["cut"] = GPose._sample(_mis[i], GPose.FIT_SAMPLES, true, d.get("scans", {}))
				d.erase("scans")
			"pose":
				var an := _ap.get_animation(String(u[2]))
				var ms := _mats_at(i, an, an.length * float(u[3]) / float(u[4]))
				if slices > 0:
					# point by point, so the bands can be cut from them, in the node's frame — at the rest's sample, its bounding
					# vertices among them (at 600 a horse's 1052-vertex body was strided, and its neck drew 0.07 m over its slice)
					_add_cut(i, GPose._skin(_samples(i, true), ms), String(u[2]))
				else:
					var e := GPose._skin_box(_samples(i, dense), ms)
					if e.size() == 2:
						var bx: Array = _mbox.get(i, [Vector3(INF, INF, INF), -Vector3(INF, INF, INF)])
						_mbox[i] = [(bx[0] as Vector3).min(e[0]), (bx[1] as Vector3).max(e[1])]
			"strike":
				# at the slices' sample, its bounding vertices among them: a snout's tip, a claw's
				var ps := GPose._skin(_samples(i, true), _mats_at(i, _san, _san.length * float(u[3]) / float(STRIKE_PHASES)))
				var xf: Transform3D = _prepped(i)["xf"]
				for p in ps:
					_fronts[int(u[3])] = maxf(_fronts[int(u[3])], (xf * p).z)
			"cut":
				var skel := GPose._skin_skeleton(_mis[i])
				var rmats: Array[Transform3D] = []
				if skel != null:
					var rr: Array[Transform3D] = []
					for b in skel.get_bone_count():
						rr.append(skel.get_bone_global_rest(b))
					rmats = GPose._bind_mats(_mis[i], skel, rr)
				_add_cut(i, GPose._skin(_samples(i, true), rmats), "")
			"keel":
				# one pose (a clip's phase; "" the rest) of every skinned mesh, its legs left out, into its underside
				var pts := PackedVector3Array()
				var thesk := GPose.skeleton_of(node)
				for mi_i in _mis.size():
					var skel := GPose._skin_skeleton(_mis[mi_i])
					if skel == null:
						continue
					var ms: Array[Transform3D] = []
					if String(u[2]) == "":
						var rr: Array[Transform3D] = []
						for b in skel.get_bone_count():
							rr.append(skel.get_bone_global_rest(b))
						ms = GPose._bind_mats(_mis[mi_i], skel, rr)
					else:
						var an := _ap.get_animation(String(u[2]))
						ms = _mats_at(mi_i, an, an.length * float(u[3]) / float(u[4]))
					var skip := {}
					if skel == thesk:
						var bones := GPose._bind_bones(_mis[mi_i], skel)
						for bi in bones.size():
							if _legs.has(bones[bi]):
								skip[bi] = true
					var xf: Transform3D = _prepped(mi_i)["xf"]
					for p in GPose._skin_without(_samples(mi_i, true), ms, skip):
						pts.append(xf * p)
				var kp := GPose.keel_points(pts, _rest, GPose.KEEL_BANDS, GPose.KEEL_SLICES, GPose.KEEL_LAYER * _rest.size.y)
				var c := String(u[2])
				if not _keels.has(c):
					var row: Array = []
					row.resize(int(u[4]))
					_keels[c] = row
				(_keels[c] as Array)[int(u[3])] = kp
			"gsel":
				# SCAN_VERTS of a surface where its rest draws them, node frame — one transform where its rests and its binds agree
				# (they do on every rig bound at rest), else each one skinned — and the ones within GROUND_BAND of its height over
				# the lowest so far kept: the soles' candidates (gcut keeps those within it of the lowest of all)
				var d := _gsurf(i, int(u[2]))
				var V: PackedVector3Array = d["V"]
				var v0: int = u[3]
				var v1 := mini(v0 + GPose.SCAN_VERTS, V.size())
				var P := PackedVector3Array()
				if d["T"] is Transform3D:
					P = (d["T"] as Transform3D) * V.slice(v0, v1)
				else:
					var ms := GPose._bind_mats(_mis[i], d["skel"], GPose._rest_globals(d["skel"]))
					var xf: Transform3D = _prepped(i)["xf"]
					for v in range(v0, v1):
						P.append(xf * GPose._skin_one(d, v, ms))
				var band := GPose.GROUND_BAND * _rest.size.y
				var ids: PackedInt32Array = d["ids"]
				var ys: PackedFloat32Array = d["ys"]
				for j in P.size():
					var y := P[j].y
					_gy0 = minf(_gy0, y)
					if y <= _gy0 + band:
						ids.append(v0 + j)
						ys.append(y)
				d["ids"] = ids
				d["ys"] = ys
			"gcut":
				# the candidates within GROUND_BAND of the lowest at rest — each carried by the bone that carries it most, and of a
				# bone's those furthest every way in its frame (_DIRS26: in any pose a rigid foot's lowest point is one of them) —
				# kept, each skinned whole a pose (ground): a sample a mesh
				var lim := _gy0 + GPose.GROUND_BAND * _rest.size.y
				for sk in _gsf:
					var d: Dictionary = _gsf[sk]
					var mi_i: int = d["mesh"]
					var skin := (_mis[mi_i] as MeshInstance3D).skin
					var V: PackedVector3Array = d["V"]
					var ids: PackedInt32Array = d["ids"]
					var ys: PackedFloat32Array = d["ys"]
					var keep := {}   # bind -> [the furthest each way, which]
					for j in ids.size():
						if ys[j] > lim:
							continue
						var v := ids[j]
						var dom := GPose._dominant_bind(d, v)
						if dom < 0 or dom >= skin.get_bind_count():
							continue
						var local := skin.get_bind_pose(dom) * V[v]   # in the frame of the bone that carries it
						var bd: PackedFloat32Array
						var bi: PackedInt32Array
						if keep.has(dom):
							bd = keep[dom][0]
							bi = keep[dom][1]
						else:
							bd.resize(GPose._DIRS26.size())
							bd.fill(-INF)
							bi.resize(GPose._DIRS26.size())
						for q in GPose._DIRS26.size():
							var dot: float = local.dot(GPose._DIRS26[q])
							if dot > bd[q]:
								bd[q] = dot
								bi[q] = v
						keep[dom] = [bd, bi]
					var kept := {}
					var foot := {}   # bind -> its foot's id: the leg its bone hangs from (every bind of a leg one foot), else its own
					var skel: Skeleton3D = d["skel"]
					for dom in keep:
						var leg := -1
						var bb := skin.get_bind_bone(dom)
						if bb < 0 and skel != null:
							bb = skel.find_bone(String(skin.get_bind_name(dom)))
						while bb >= 0 and skel != null and leg < 0:
							leg = int(_gleg.get(bb, -1))
							bb = skel.get_bone_parent(bb)
						foot[dom] = leg if leg >= 0 else _gnew()
						for v in (keep[dom][1] as PackedInt32Array):
							kept[v] = dom
					var ids_k: Array = kept.keys()
					var grp := PackedInt32Array()
					var ms := GPose._bind_mats(_mis[mi_i], d["skel"], GPose._rest_globals(d["skel"]))
					var xf: Transform3D = _prepped(mi_i)["xf"]
					for v: int in ids_k:
						var f: int = foot[kept[v]]
						grp.append(f)
						GPose._support(_grf, _grs, f, xf * GPose._skin_one(d, v, ms))
					var smp: Array = _gs.get(mi_i, [[]])
					(smp[0] as Array).append(GPose._surface_sample(d, ids_k))
					_gs[mi_i] = smp
					var gl: Array = _ggrp.get(mi_i, [])
					gl.append(grp)
					_ggrp[mi_i] = gl
				_gsf.clear()
			"pcut":
				# a body of parts: what its legs' parts draw furthest every way (_DIRS26), each in its own frame, and the lowest at rest
				var rm := GRig.of(node)
				for side in ["leg_l", "leg_r"]:
					var lg := GRig.part(node, String((rm.get(side, {}) as Dictionary).get("thigh", "")))
					if lg == null:
						continue
					var ms: Array = lg.find_children("*", "MeshInstance3D", true, false)
					if lg is MeshInstance3D:
						ms.push_front(lg)
					for mi: MeshInstance3D in ms:
						if mi.mesh == null:
							continue
						var best := PackedVector3Array()
						best.resize(GPose._DIRS26.size())
						var bd := PackedFloat32Array()
						bd.resize(GPose._DIRS26.size())
						bd.fill(-INF)
						for sf in mi.mesh.get_surface_count():
							var arr := GPose.surface_arrays(mi.mesh, sf)
							for v: Vector3 in (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array):
								for q in GPose._DIRS26.size():
									var dot: float = v.dot(GPose._DIRS26[q])
									if dot > bd[q]:
										bd[q] = dot
										best[q] = v
						_gparts.append([mi, best])
						var f := _gnew()
						var xf := GPose.xf_to(mi, node)
						for p in best:
							_gy0 = minf(_gy0, (xf * p).y)
							GPose._support(_grf, _grs, f, xf * p)
			"pground":
				# one phase of a clip on a body of parts: its legs' furthest points carried by every node the clip moves
				var an := _ap.get_animation(String(u[2]))
				var lo := INF
				var loc := GPose._node_pose(an, _aroot, an.length * float(u[3]) / float(u[4]))
				var ft := PackedVector3Array()
				ft.resize(_gn * GPose.GROUND_K)
				ft.fill(Vector3.INF)
				var sd := PackedFloat32Array()
				sd.resize(ft.size())
				sd.fill(-INF)
				for f in _gparts.size():
					var e: Array = _gparts[f]
					var xf := Transform3D.IDENTITY
					var w: Node = e[0]
					while w != null and w != node and w is Node3D:
						xf = (loc.get(w, (w as Node3D).transform) as Transform3D) * xf
						w = w.get_parent()
					for p in (e[1] as PackedVector3Array):
						var q := xf * p
						lo = minf(lo, q.y)
						GPose._support(ft, sd, f, q)
				_ground_row(String(u[2]), int(u[3]), int(u[4]), lo, ft)
			"ground":
				# one phase of a clip: its soles' lowest, node frame
				var an := _ap.get_animation(String(u[2]))
				var lo := INF
				var ft := PackedVector3Array()
				ft.resize(_gn * GPose.GROUND_K)
				ft.fill(Vector3.INF)
				var sd := PackedFloat32Array()
				sd.resize(ft.size())
				sd.fill(-INF)
				for k in _gs:
					var xf: Transform3D = _prepped(k)["xf"]
					var pts := GPose._skin(_gs[k], _mats_at(k, an, an.length * float(u[3]) / float(u[4])))
					var grp := PackedInt32Array()
					for g: PackedInt32Array in (_ggrp[k] as Array):
						grp.append_array(g)
					for j in pts.size():
						var q := xf * pts[j]
						lo = minf(lo, q.y)
						GPose._support(ft, sd, grp[j], q)
				_ground_row(String(u[2]), int(u[3]), int(u[4]), lo, ft)
			"band":
				# one pose's points into its set's bands (GPose._bands, a set at a time)
				var st: Array = _sets[i]
				var k: String = st[0]
				var dz := (_zhi - _zlo) / float(slices)
				if not _blo.has(k):
					var lo: Array = []
					var hi: Array = []
					for b in slices:
						lo.append(Vector3.INF)
						hi.append(-Vector3.INF)
					_blo[k] = lo
					_bhi[k] = hi
				GPose._band_points(_blo[k], _bhi[k], st[2], _zlo, dz, slices)

	# One pose's points of mesh `i` (its frame) into its set's (`key`: its clip, "" the rest pose).
	func _add_cut(i: int, ps: PackedVector3Array, key: String) -> void:
		var xf: Transform3D = _prepped(i)["xf"]
		var box := PackedVector3Array()
		box.resize(ps.size())
		for k in ps.size():
			var p := xf * ps[k]
			box[k] = p
			_zlo = minf(_zlo, p.z)
			_zhi = maxf(_zhi, p.z)
			if key != "":
				_plo = _plo.min(p)
				_phi = _phi.max(p)
		_sets.append([key, i, box])
		if not _keys.has(key):
			_keys.append(key)

	func _finish() -> void:
		var all := _rest
		for i in _mbox:
			var bx: Array = _mbox[i]
			all = all.merge(_prepped(i)["xf"] * AABB(bx[0], bx[1] - bx[0]))
		if _phi.x >= _plo.x and _units.any(func(u): return u[0] == "pose"):
			all = all.merge(AABB(_plo, _phi - _plo))
		fit = {"ok": true, "rest": _rest, "aabb": all, "person": _person, "pelvis": _pelvis, "tilt": _tilt}
		if not _keels.is_empty():
			fit["keel"] = _keels
		if not _glow.is_empty() and is_finite(_gy0):
			var lowest := {}
			var reach := 0.0
			for p in _grf:
				if p.is_finite():
					reach = maxf(reach, Vector2(p.x, p.z).length())
			for c in _glow:
				var row: PackedFloat32Array = _glow[c]
				var at := 0
				for k in row.size():
					row[k] = row[k] if is_finite(row[k]) else _gy0
					if row[k] < row[at]:
						at = k
				_glow[c] = row
				lowest[c] = at
				for ft: PackedVector3Array in (_gfeet[c] as Array):
					for p in ft:
						if p.is_finite():
							reach = maxf(reach, Vector2(p.x, p.z).length())
			fit["ground"] = {"rest": _gy0, "low": _glow.duplicate(), "feet": _gfeet.duplicate(), "rest_feet": _grf, "lowest": lowest,
				"reach": reach, "k": GPose.GROUND_K}
		if slices > 0:
			var some := _zhi >= _zlo
			var bands := {"z0": _zlo if some else 0.0, "dz": (_zhi - _zlo) / float(slices) if some else 0.0, "n": slices, "by": {}}
			for k in _blo:
				bands["by"][k] = GPose._band_rows(_blo[k], _bhi[k], slices)
			fit["bands"] = bands
			var posed_keys := _keys.filter(func(k): return k != "")
			# every clip it is fitted over together (its rest pose when it has none); a caller that shows them a state at a
			# time cuts its own from the bands (enemy.gd: parked, moving)
			fit["slices"] = GPose.band_boxes(bands, posed_keys if not posed_keys.is_empty() else [""])
		if _san != null:
			# THE CONTACT: the phase where the attack reaches furthest forward — when a bite or a blow lands (damage at the
			# clip's start bit before the lunge left: a frog's tongue was still curled when the player lost the health).
			# An attack that never reaches forward (a tail whip, a slime's squash: its front moves less than 1% of the body's
			# length) has no such moment to read: its phase is -1, and the caller lands it where it lands any it cannot read.
			var best := -1
			var lo := INF
			for ph in STRIKE_PHASES:
				if is_finite(_fronts[ph]):
					lo = minf(lo, _fronts[ph])
					if best < 0 or _fronts[ph] > _fronts[best]:
						best = ph
			var still := best >= 0 and _fronts[best] - lo < 0.01 * _rest.size.z
			fit["strike"] = {} if best < 0 else {"clip": strike, "front": _fronts[best], "len": _san.length,
				"phase": -1.0 if still else float(best) / float(STRIKE_PHASES)}
		_end()

	func _end() -> void:
		done = true
		if keyed:
			GPose._fit_memo[key] = fit
		_prep.clear()
		_sets.clear()
		_blo.clear()
		_bhi.clear()
		_legs.clear()
		_gsf.clear()
		_gs.clear()
		_glow.clear()
		_gparts.clear()
		_ggrp.clear()
		_gleg.clear()
		_gfeet = {}


## THE BODY A MODEL DRAWS IN ONE POSTURE, and none other — a seated NPC's: what it draws while it holds that posture,
## not its rest pose. With a skeleton and `clip` a clip its AnimationPlayer has, that clip at FIT_POSES phases (a seated
## idle and its breathing); otherwise the pose the model holds NOW — GPose.sit's bones, which no clip carries, or a body
## of parts on node tracks the caller has posed (a Kenney figure's "sit"). {ok, aabb, slices: `slices` z-bands as
## body_fit cuts them}, in `node`'s own frame (node.transform excluded). Memoised per MODEL and `tag`, the posture the
## caller names ("sit|<clip>"): every copy of a model seated alike is one measurement. The 0.45 x 1.35 m capsule a
## seated NPC stood in was the constant body this replaced: villager_man drew 10% of its vertices outside it, a Kenney
## figure 42%, and a shot at the Kenney's head flew through the air over the capsule into nothing (step 2's census).
static func posed_fit(node: Node3D, clip: String, slices: int, tag: String, layered := false) -> Dictionary:
	var ids := PackedStringArray()
	for mi: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh != null:
			ids.append(_mesh_key(mi))
	var key := ",".join(ids) + "#" + tag + "/%d" % slices + ("y" if layered else "")
	if ids.size() > 0 and _pose_memo.has(key):
		return _pose_memo[key]
	var pts := PackedVector3Array()
	var ap := _find_anim_player(node)
	var an: Animation = ap.get_animation(clip) if ap != null and clip != "" and ap.has_animation(clip) else null
	var aroot := ap.get_node_or_null(ap.root_node) if ap != null else null
	var unskinned: Array[Transform3D] = []
	for mi: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		var xf := xf_to(mi, node)
		var skel := _skin_skeleton(mi)
		var sets: Array = []
		if skel != null:
			var tracks := _bone_tracks(skel, an, aroot) if an != null else []
			if an != null and not tracks.is_empty():
				var rp := PackedVector3Array()
				var rr: Array[Quaternion] = []
				var rs := PackedVector3Array()
				for i in skel.get_bone_count():
					var r := skel.get_bone_rest(i)
					rp.append(r.origin)
					rr.append(r.basis.get_rotation_quaternion())
					rs.append(r.basis.get_scale())
				var order := _bone_order(skel)
				for ph in FIT_POSES:
					sets.append(_bind_mats(mi, skel, _pose_at(skel, an, tracks, rp, rr, rs, order, an.length * float(ph) / float(FIT_POSES))))
			else:
				var now: Array[Transform3D] = []
				for i in skel.get_bone_count():
					now.append(skel.get_bone_global_pose(i))
				sets.append(_bind_mats(mi, skel, now))
		for ps: PackedVector3Array in (_skinned_sets(mi, sets, FIT_POSE_SAMPLES) if skel != null else [_skinned_points(mi, unskinned, FIT_POSE_SAMPLES)]):
			for p in ps:
				pts.append(xf * p)
	var fit := {"ok": not pts.is_empty(), "aabb": _points_box(pts), "slices": _slice_boxes(pts, slices, layered)}
	if ids.size() > 0:
		_pose_memo[key] = fit
	return fit


const KEEL_SLICES := 16           # a body's underside is read in this many slices along it (keel_points) ...
const KEEL_BANDS := 3             # ... and strips across it: two edges and the middle
const KEEL_LAYER := 0.0125        # a pose's underside layer, x its rest height (the ground model's 0.03 m on a 2.4 m horse)


## A BODY'S UNDERSIDE (`pts`, its frame) as the ground model rests it (Vehicle._keel_support): binned into `bands` strips across
## `box` and `slices` slices along it, each bin keeping the lowest height it holds, placed at its most EXPOSED point within
## `layer` of that height — the outermost across the body in the edge strips (a sideways lean drives the edge into the ground
## first), the outermost along it in the end slices (a grade meets the tip of an overhang first). A flat-bottomed body has its
## whole belly at one height, so "the lowest vertex" alone lands wherever the mesh puts it — on the Kestrel truck, the
## centreline, missing both. Runs of EMPTY slices (a low-poly flat panel has vertices only at its ends) are filled by
## interpolating between their populated neighbours. Populated slices are never smoothed over: a straight "lower outline"
## would join a fused model's baked tyre bottoms (or a mount's hooves) into a skid plate at ground level under a belly that is
## really 0.3 m up, and every crest would then lift all four wheels off it. A vehicle's at rest (Vehicle._measure_keel), and a
## mount's in every pose it plays without its legs (FitJob's "keel").
static func keel_points(pts: PackedVector3Array, box: AABB, bands: int, slices: int, layer: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var x0 := box.position.x
	var z0 := box.position.z
	var dx := maxf(0.01, box.size.x / float(bands))
	var dz := maxf(0.01, box.size.z / float(slices))
	var cx := box.position.x + box.size.x * 0.5
	var cz := box.position.z + box.size.z * 0.5
	var nb := bands * slices
	var ymin := PackedFloat32Array()
	ymin.resize(nb)
	ymin.fill(INF)
	var rep := PackedVector3Array()
	rep.resize(nb)
	rep.fill(Vector3(0.0, INF, 0.0))
	for q in pts:
		var bi := clampi(int((q.x - x0) / dx), 0, bands - 1) * slices + clampi(int((q.z - z0) / dz), 0, slices - 1)
		ymin[bi] = minf(ymin[bi], q.y)
	for q in pts:
		var band := clampi(int((q.x - x0) / dx), 0, bands - 1)
		var sl := clampi(int((q.z - z0) / dz), 0, slices - 1)
		var bi := band * slices + sl
		if q.y > ymin[bi] + layer:
			continue
		var cur := rep[bi]
		if not is_finite(cur.y):
			rep[bi] = Vector3(q.x, ymin[bi], q.z)
			continue
		# exposure: outward across the body in the edge strips, outward along it in the end slices
		var edge := band == 0 or band == bands - 1
		var endz := sl < 2 or sl >= slices - 2
		var gain := (absf(q.x - cx) - absf(cur.x - cx) if edge else 0.0) + (absf(q.z - cz) - absf(cur.z - cz) if endz else 0.0)
		if gain > 0.0:
			rep[bi] = Vector3(q.x, ymin[bi], q.z)
	for band in bands:
		var prev := Vector3(0.0, INF, 0.0)
		var gap := 0
		for sl in slices:
			var q := rep[band * slices + sl]
			if not is_finite(q.y):
				gap += 1
				continue
			if gap > 0 and is_finite(prev.y):
				for c in gap:
					out.append(prev.lerp(q, float(c + 1) / float(gap + 1)))
			out.append(q)
			prev = q
			gap = 0
	return out


# The box round `pts` (AABB() for none).
static func _points_box(pts: PackedVector3Array) -> AABB:
	if pts.is_empty():
		return AABB()
	var lo := pts[0]
	var hi := pts[0]
	for p in pts:
		lo = lo.min(p)
		hi = hi.max(p)
	return AABB(lo, hi - lo)


# `pts` cut into `n` equal bands along z, nose to tail: one box per band, each as long as its band (the boxes meet: no
# gap a sparse sample left between two of them — mire_dragon's tail fell between its first two, 0.08 m outside both) and
# as wide and as tall as what falls in it; a band nothing falls in takes its neighbours' width and height. `layered`: cut
# along y instead, floor to head — a SITTER is a body that rises from a seat, not one that runs nose to tail: cut along z,
# his back's box held his shoulders' reach behind the backrest from his belly up, and a shot from behind at his belly met
# that air through the pew's wood (people rig, seated_shots: 7 lines on a chapel_pew).
static func _slice_boxes(pts: PackedVector3Array, n: int, layered := false) -> Array:
	if not layered:
		return band_boxes(_bands({"": pts}, n), [""])
	var sw := PackedVector3Array()
	sw.resize(pts.size())
	for i in pts.size():
		sw[i] = Vector3(pts[i].x, pts[i].z, pts[i].y)
	var out: Array = []
	for a: AABB in band_boxes(_bands({"": sw}, n), [""]):
		out.append(AABB() if a.size == Vector3.ZERO and a.position == Vector3.ZERO else \
			AABB(Vector3(a.position.x, a.position.z, a.position.y), Vector3(a.size.x, a.size.z, a.size.y)))
	return out


## THE BANDS EACH POSE SET DRAWS, on one grid: `by` {key: pts} — the points of each set of poses (a clip's, the rest's) —
## cut into `n` equal bands along z over all of them, nose to tail. {z0, dz, n, by: {key: [[lo, hi] or null, ...] a band}}.
## One grid for every set, so a body of any of them together is a band-by-band union (band_boxes): the clips an enemy shows
## parked, moving or in the water. (FitJob cuts its own a pose at a time, with the same pieces: _band_points, _band_rows.)
## Points, not triangles: what a triangle draws across a band's line beyond its corners was cut there too until the enemy
## rig measured it (at FIT_SAMPLES and the bounding vertices: at most 0.018 m, the bat's — under its 0.06 m hold — for
## 40-60% of the fit's cost).
static func _bands(by: Dictionary, n: int) -> Dictionary:
	var whole := AABB()
	var first := true
	for key in by:
		var pb := _points_box(by[key])
		if pb.size == Vector3.ZERO and pb.position == Vector3.ZERO and (by[key] as PackedVector3Array).is_empty():
			continue
		whole = pb if first else whole.merge(pb)
		first = false
	var out := {"z0": whole.position.z, "dz": whole.size.z / float(maxi(n, 1)), "n": n, "by": {}}
	if n <= 0 or first:
		return out
	var dz: float = out["dz"]
	for key in by:
		var lo: Array = []
		var hi: Array = []
		for i in n:
			lo.append(Vector3.INF)
			hi.append(-Vector3.INF)
		_band_points(lo, hi, by[key], whole.position.z, dz, n)
		out["by"][key] = _band_rows(lo, hi, n)
	return out


# Points into the bands of a grid (z0, dz, n): each band's lo and hi.
static func _band_points(lo: Array, hi: Array, P: PackedVector3Array, z0: float, dz: float, n: int) -> void:
	for p in P:
		var k := clampi(int((p.z - z0) / dz), 0, n - 1) if dz > 1e-6 else 0
		lo[k] = (lo[k] as Vector3).min(p)
		hi[k] = (hi[k] as Vector3).max(p)


static func _band_rows(lo: Array, hi: Array, n: int) -> Array:
	var rows: Array = []
	for i in n:
		rows.append([lo[i], hi[i]] if (hi[i] as Vector3).x >= (lo[i] as Vector3).x else null)
	return rows


## The boxes of the sets `keys` drawn together (body_fit's bands): band by band their union, each as long as its band and
## no longer than they reach — the grid is every set's, and a parked horse's idle stops 1.14 m (bind units) short of the
## tail its gallop throws: a box to the grid's end stood 0.38 m past its idle (the enemy rig). A band inside their reach
## that none of them draws in takes its neighbours' width and height (a sparse tail); one past their reach, and every
## band when they draw in none, is AABB().
static func band_boxes(bands: Dictionary, keys: Array) -> Array:
	var out: Array = []
	var n := int(bands.get("n", 0))
	var lo: Array = []
	var hi: Array = []
	var zlo := INF
	var zhi := -INF
	for i in n:
		lo.append(Vector3.INF)
		hi.append(-Vector3.INF)
		for key in keys:
			var rows = bands["by"].get(key, null)
			if rows is Array and rows[i] != null:
				lo[i] = (lo[i] as Vector3).min(rows[i][0])
				hi[i] = (hi[i] as Vector3).max(rows[i][1])
		if (hi[i] as Vector3).x >= (lo[i] as Vector3).x:
			zlo = minf(zlo, (lo[i] as Vector3).z)
			zhi = maxf(zhi, (hi[i] as Vector3).z)
	for i in n:
		var z0: float = float(bands["z0"]) + float(bands["dz"]) * float(i)
		var z1: float = z0 + float(bands["dz"])
		var a: Vector3 = lo[i]
		var b: Vector3 = hi[i]
		if b.x < a.x and z0 < zhi and z1 > zlo:
			for j in [i - 1, i + 1]:
				if j >= 0 and j < n and (hi[j] as Vector3).x >= (lo[j] as Vector3).x:
					a = a.min(lo[j])
					b = b.max(hi[j])
		if b.x < a.x:
			out.append(AABB())
			continue
		z0 = maxf(z0, zlo)
		z1 = minf(z1, zhi)
		out.append(AABB(Vector3(a.x, a.y, z0), Vector3(b.x - a.x, b.y - a.y, maxf(z1 - z0, 0.0))))
	return out


# Which vertices a pose is skinned at: every `stride`-th, AND the ones that bound the mesh — the farthest along each of
# 14 directions (the axes and the diagonals) as it is bound. A tail tip or a claw is a few vertices of thousands, and a
# stride skips them: mire_dragon's idle reached 0.63 m past the slices a 600-vertex sample cut from it (drawn at 4.5 m).
# Its bounding vertices are where a pose reaches furthest, so every pose takes them along. `scan`: that surface's bounding
# scan already read (_scan_begin + _scan: FitJob reads it SCAN_VERTS at a time); none, it is read here whole.
const SCAN_VERTS := 2048          # vertices one piece of a bounding scan reads (FitJob "scan": ~1 ms desktop)
const _BOUND_DIRS := [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, -1, 0), Vector3(0, 0, -1),
	Vector3(0, 0, 1), Vector3(-1, -1, -1), Vector3(-1, -1, 1), Vector3(-1, 1, -1), Vector3(-1, 1, 1), Vector3(1, -1, -1),
	Vector3(1, -1, 1), Vector3(1, 1, -1), Vector3(1, 1, 1)]
static func _sample_ids(V: PackedVector3Array, stride: int, scan = null) -> PackedInt32Array:
	var ids := PackedInt32Array()
	for i in range(0, V.size(), stride):
		ids.append(i)
	if stride <= 1:
		return ids
	var sc: Dictionary = scan if scan is Dictionary else {}
	if sc.is_empty():
		sc = _scan_state(V)
		for v0 in range(0, V.size(), SCAN_VERTS):
			_scan(sc, v0)
	for i in (sc["best"] as PackedInt32Array):
		if not ids.has(i):
			ids.append(i)
	return ids


# A surface's bounding scan, begun: {V, best, bd} (_sample_ids' state), its vertices read from the mesh.
static func _scan_begin(mesh: Mesh, sf: int) -> Dictionary:
	var arr := surface_arrays(mesh, sf)
	var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX] if arr.size() > Mesh.ARRAY_VERTEX and arr[Mesh.ARRAY_VERTEX] != null else PackedVector3Array()
	return _scan_state(V)


# A scan's state before its first vertex (packed arrays are values: built, then stored).
static func _scan_state(V: PackedVector3Array) -> Dictionary:
	var best := PackedInt32Array()
	best.resize(_BOUND_DIRS.size())
	var bd := PackedFloat32Array()
	bd.resize(_BOUND_DIRS.size())
	bd.fill(-INF)
	return {"V": V, "best": best, "bd": bd}


static var scanned := 0           # vertices bounding scans have read, ever (the enemy rig counts what a piece reads)


# SCAN_VERTS of the scan from vertex `v0`: the farthest along each direction so far (ties: the first).
static func _scan(sc: Dictionary, v0: int) -> void:
	var V: PackedVector3Array = sc["V"]
	var best: PackedInt32Array = sc["best"]
	var bd: PackedFloat32Array = sc["bd"]
	scanned += maxi(0, mini(v0 + SCAN_VERTS, V.size()) - v0)
	for i in range(v0, mini(v0 + SCAN_VERTS, V.size())):
		var p := V[i]
		for d in _BOUND_DIRS.size():
			var v := p.dot(_BOUND_DIRS[d])
			if v > bd[d]:
				bd[d] = v
				best[d] = i
	sc["best"] = best
	sc["bd"] = bd


# _skinned_extent's skinning, keeping the points: one PackedVector3Array per set of matrices, in the mesh instance's
# frame (_sample's every ceil(n / cap)-th vertex). Not the bounding ones: their scan reads every vertex of the mesh in one
# call, and a seated NPC is measured where the cell that seats him is built — 11-21 ms on a Meshy person (hero_fisher's
# 23k vertices 20.7, villager_man 11.5: step 4's fix round), where the stride alone is the drawn rest's own sample.
static func _skinned_sets(mi: MeshInstance3D, sets: Array, cap: int) -> Array:
	var smp := _sample(mi, cap, false)
	var out: Array = []
	for ms: Array[Transform3D] in sets:
		out.append(_skin(smp, ms))
	return out


## A mesh's vertices sampled for skinning, each one's influences read ONCE for every pose it is skinned in: [surfaces].
## surfaces: [the vertices, how many bones move each (0 = none: drawn where it is), which, with what weight] per surface, in
## order — every ceil(n / cap)-th vertex and, `bound`, the ones that bound it (_sample_ids: a surface's from `scans` when
## its scan was read already).
static func _sample(mi: MeshInstance3D, cap: int, bound: bool, scans: Dictionary = {}) -> Array:
	var surfs: Array = []
	for s in mi.mesh.get_surface_count():
		var arr := surface_arrays(mi.mesh, s)
		if arr.size() <= Mesh.ARRAY_WEIGHTS or arr[Mesh.ARRAY_VERTEX] == null:
			continue
		var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		if V.is_empty():
			continue
		var B = arr[Mesh.ARRAY_BONES]
		var W = arr[Mesh.ARRAY_WEIGHTS]
		var k := 0
		if B != null and W != null:
			k = int((B as PackedInt32Array).size() / V.size())
		var stride := maxi(1, ceili(float(V.size()) / float(cap)))
		var pv := PackedVector3Array()
		var pn := PackedInt32Array()
		var pb := PackedInt32Array()
		var pw := PackedFloat32Array()
		for i in (_sample_ids(V, stride, scans.get(s, null)) if bound else range(0, V.size(), stride)):
			pv.append(V[i])
			var n := 0
			for j in k:
				var w: float = W[i * k + j]
				if w > 0.0:
					pb.append(B[i * k + j])
					pw.append(w)
					n += 1
			pn.append(n)
		surfs.append([pv, pn, pb, pw])
	return [surfs]


# The local transforms the node tracks of `anim` give at time `t` (a body of parts' clip: position, rotation, scale tracks on its
# nodes, from `aroot`), over each node's own transform: {node: Transform3D}.
static func _node_pose(anim: Animation, aroot: Node, t: float) -> Dictionary:
	var parts := {}
	if aroot == null:
		return parts
	for tr in anim.get_track_count():
		var ty := anim.track_get_type(tr)
		if ty != Animation.TYPE_POSITION_3D and ty != Animation.TYPE_ROTATION_3D and ty != Animation.TYPE_SCALE_3D:
			continue
		var path := anim.track_get_path(tr)
		if path.get_subname_count() > 0:
			continue
		var n := aroot.get_node_or_null(NodePath(path.get_concatenated_names())) as Node3D
		if n == null:
			continue
		var cur: Array = parts.get(n, [n.position, n.quaternion, n.scale])
		match ty:
			Animation.TYPE_POSITION_3D:
				cur[0] = anim.position_track_interpolate(tr, t)
			Animation.TYPE_ROTATION_3D:
				cur[1] = anim.rotation_track_interpolate(tr, t)
			_:
				cur[2] = anim.scale_track_interpolate(tr, t)
		parts[n] = cur
	var out := {}
	for n in parts:
		var c: Array = parts[n]
		out[n] = Transform3D(Basis(c[1] as Quaternion) * Basis.from_scale(c[2] as Vector3), c[0] as Vector3)
	return out


# A FOOT IS STOOD ON THE GROUND BY THESE OF ITS POINTS (GPose's ground: each foot's, a pose each, node frame): its lowest, and its
# furthest down each diagonal — the corner a slope tilted any way meets first. Kept its lowest alone, a Kenney figure walking down
# a 17 deg grade put its heel 7.4 cm into it and a troll 9.0 (step 5d's fix round: the point kept was its toe).
const GROUND_K := 5
const GROUND_DIRS := [Vector3(0, -1, 0), Vector3(0.5774, -0.5774, 0.5774), Vector3(0.5774, -0.5774, -0.5774),
	Vector3(-0.5774, -0.5774, 0.5774), Vector3(-0.5774, -0.5774, -0.5774)]


# Keep `q` among foot `f`'s GROUND_K points in `ft` where it reaches further its way than the one kept (`sd`: how far each does).
static func _support(ft: PackedVector3Array, sd: PackedFloat32Array, f: int, q: Vector3) -> void:
	for k in GROUND_K:
		var d: float = q.dot(GROUND_DIRS[k])
		if d > sd[f * GROUND_K + k]:
			sd[f * GROUND_K + k] = d
			ft[f * GROUND_K + k] = q


# Every way out of a point, the axes and the diagonals: of what a rigid part draws, its point furthest along one of these is
# where it touches a plane it is turned onto in any pose (GPose's ground keeps a foot's).
const _DIRS26 := [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1),
	Vector3(0.7071, 0.7071, 0), Vector3(0.7071, -0.7071, 0), Vector3(-0.7071, 0.7071, 0), Vector3(-0.7071, -0.7071, 0),
	Vector3(0.7071, 0, 0.7071), Vector3(0.7071, 0, -0.7071), Vector3(-0.7071, 0, 0.7071), Vector3(-0.7071, 0, -0.7071),
	Vector3(0, 0.7071, 0.7071), Vector3(0, 0.7071, -0.7071), Vector3(0, -0.7071, 0.7071), Vector3(0, -0.7071, -0.7071),
	Vector3(0.5774, 0.5774, 0.5774), Vector3(0.5774, 0.5774, -0.5774), Vector3(0.5774, -0.5774, 0.5774), Vector3(0.5774, -0.5774, -0.5774),
	Vector3(-0.5774, 0.5774, 0.5774), Vector3(-0.5774, 0.5774, -0.5774), Vector3(-0.5774, -0.5774, 0.5774), Vector3(-0.5774, -0.5774, -0.5774)]


# One vertex `v` of a surface's arrays (FitJob._gsurf's {V, B, W, k}) skinned under `ms`, in the mesh instance's frame.
static func _skin_one(d: Dictionary, v: int, ms: Array[Transform3D]) -> Vector3:
	var V: PackedVector3Array = d["V"]
	var B: PackedInt32Array = d["B"]
	var W: PackedFloat32Array = d["W"]
	var k: int = d["k"]
	var acc := Vector3.ZERO
	var ws := 0.0
	for j in k:
		var w := W[v * k + j]
		if w > 0.0 and B[v * k + j] < ms.size():
			acc += (ms[B[v * k + j]] * V[v]) * w
			ws += w
	return acc / ws if ws > 0.0 else V[v]


# The skin bind that carries vertex `v` most (-1: none).
static func _dominant_bind(d: Dictionary, v: int) -> int:
	var B: PackedInt32Array = d["B"]
	var W: PackedFloat32Array = d["W"]
	var k: int = d["k"]
	var best := -1
	var bw := 0.0
	for j in k:
		if W[v * k + j] > bw:
			bw = W[v * k + j]
			best = B[v * k + j]
	return best


# The vertices `ids` of a surface's arrays as one surface of a _sample ([vertices, how many bones move each, which, how much]).
static func _surface_sample(d: Dictionary, ids: Array) -> Array:
	var V: PackedVector3Array = d["V"]
	var B: PackedInt32Array = d["B"]
	var W: PackedFloat32Array = d["W"]
	var k: int = d["k"]
	var pv := PackedVector3Array()
	var pn := PackedInt32Array()
	var pb := PackedInt32Array()
	var pw := PackedFloat32Array()
	for v: int in ids:
		pv.append(V[v])
		var n := 0
		for j in k:
			if W[v * k + j] > 0.0:
				pb.append(B[v * k + j])
				pw.append(W[v * k + j])
				n += 1
		pn.append(n)
	return [pv, pn, pb, pw]


## _sample's vertices skinned under one set of matrices (bone pose * bind), in the mesh instance's frame, every surface's in
## order.
static func _skin(smp: Array, ms: Array[Transform3D]) -> PackedVector3Array:
	var out := PackedVector3Array()
	for sf: Array in smp[0]:
		var pv: PackedVector3Array = sf[0]
		var pn: PackedInt32Array = sf[1]
		var pb: PackedInt32Array = sf[2]
		var pw: PackedFloat32Array = sf[3]
		var o := 0
		for vi in pv.size():
			var n := pn[vi]
			var p := pv[vi]
			var acc := Vector3.ZERO
			var ws := 0.0
			for j in n:
				var bj := pb[o + j]
				if bj < ms.size():
					acc += (ms[bj] * p) * pw[o + j]
					ws += pw[o + j]
			o += n
			out.append(acc / ws if ws > 0.0 else p)
	return out


## _skin, the vertices carried most by a bind of `skip` left out (a mount's legs, for its keel).
static func _skin_without(smp: Array, ms: Array[Transform3D], skip: Dictionary) -> PackedVector3Array:
	if skip.is_empty():
		return _skin(smp, ms)
	var out := PackedVector3Array()
	for sf: Array in smp[0]:
		var pv: PackedVector3Array = sf[0]
		var pn: PackedInt32Array = sf[1]
		var pb: PackedInt32Array = sf[2]
		var pw: PackedFloat32Array = sf[3]
		var o := 0
		for vi in pv.size():
			var n := pn[vi]
			var dom := -1
			var dw := 0.0
			var acc := Vector3.ZERO
			var ws := 0.0
			for j in n:
				var bj := pb[o + j]
				if pw[o + j] > dw:
					dw = pw[o + j]
					dom = bj
				if bj < ms.size():
					acc += (ms[bj] * pv[vi]) * pw[o + j]
					ws += pw[o + j]
			o += n
			if not skip.has(dom):
				out.append(acc / ws if ws > 0.0 else pv[vi])
	return out


## The extent _sample's vertices draw under one set of matrices, [lo, hi] in the mesh instance's frame ([] for none) —
## _skinned_extent's own arithmetic, so a fit worked a piece at a time is the fit worked in one call, to the bit.
static func _skin_box(smp: Array, ms: Array[Transform3D]) -> Array:
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for sf: Array in smp[0]:
		var pv: PackedVector3Array = sf[0]
		var pn: PackedInt32Array = sf[1]
		var pb: PackedInt32Array = sf[2]
		var pw: PackedFloat32Array = sf[3]
		var o := 0
		for vi in pv.size():
			var n := pn[vi]
			var p := pv[vi]
			if n == 1:
				if pb[o] < ms.size():
					p = ms[pb[o]] * p
			elif n > 1:
				var acc := Vector3.ZERO
				var ws := 0.0
				for j in n:
					var bj := pb[o + j]
					if bj < ms.size():
						acc += (ms[bj] * p) * pw[o + j]
						ws += pw[o + j]
				if ws > 0.0:
					p = acc / ws
			o += n
			lo = lo.min(p)
			hi = hi.max(p)
	return [lo, hi] if hi.x >= lo.x else []


# The Skeleton3D a mesh instance is skinned to, or null (no skin, no skeleton path, unresolvable).
static func _skin_skeleton(mi: MeshInstance3D) -> Skeleton3D:
	if mi == null or mi.skin == null or mi.skeleton.is_empty():
		return null
	return mi.get_node_or_null(mi.skeleton) as Skeleton3D


static func _mesh_key(mi: MeshInstance3D) -> String:
	return "%d/%d" % [mi.mesh.get_instance_id(), mi.skin.get_instance_id() if mi.skin != null else 0]


## EVERY READ OF A MESH'S ARRAYS GOES THROUGH THESE TWO, COUNTED (mesh_reads): a surface's arrays, or the triangles of
## every surface. An ArrayMesh keeps its arrays in the RenderingServer and each read copies them back out
## (mesh_get_surface, FUNC2RC: 0.01-0.35 ms a surface on a desktop; a model's first faces 1-4 ms, Godot builds its
## TriangleMesh) — the cost each memo here (a body's fit, a seat's fit and height, a hull, a skeleton's map) exists to pay
## once a model. The people rig holds a memo hit to no read at all (a warm body_fit lookup; a seat placed with its fit
## remembered) and the work that fills one to some, BY THIS COUNT: held to a clock until 2026-10-05, a lookup that read
## its mesh every time (0.011 -> 0.387 ms a villager) stayed under the bound, and a loaded sweep could go red without
## one. check-mesh-reads.mjs refuses a read made anywhere else. Every caller is on the main thread (a worker's read waits
## on the server thread, the main one: step 1b's freeze).
static var mesh_reads := 0


static func surface_arrays(mesh: Mesh, s: int) -> Array:
	mesh_reads += 1
	return mesh.surface_get_arrays(s)


static func faces(mesh: Mesh) -> PackedVector3Array:
	mesh_reads += 1
	return mesh.get_faces()


## THE model's skeleton: the one with the most bones. A rig can carry more than one (a prop's two-bone
## armature beside the body's), and whatever reads a model's bones reads this one.
static func skeleton_of(node: Node) -> Skeleton3D:
	var s: Skeleton3D = null
	for sk in node.find_children("*", "Skeleton3D", true, false):
		if s == null or (sk as Skeleton3D).get_bone_count() > s.get_bone_count():
			s = sk as Skeleton3D
	return s


# One skinning matrix per skin bind: the bone's skeleton-space pose (from `glob`) * its bind pose.
static func _bind_mats(mi: MeshInstance3D, skel: Skeleton3D, glob: Array[Transform3D]) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for b in mi.skin.get_bind_count():
		var bi := mi.skin.get_bind_bone(b)
		if bi < 0:
			bi = skel.find_bone(String(mi.skin.get_bind_name(b)))
		out.append((glob[bi] if bi >= 0 and bi < glob.size() else Transform3D.IDENTITY) * mi.skin.get_bind_pose(b))
	return out


# The extent the mesh draws under each set of skinning matrices, in the mesh instance's frame (the
# renderer's convention: bone pose * bind pose * vertex, placed by the MeshInstance3D itself). At most
# `cap` vertices per surface per set. Each sampled vertex's influences are read ONCE, not once per
# set: most are bound to one bone, and that one is a single transform.
static func _skinned_extent(mi: MeshInstance3D, sets: Array, cap: int) -> AABB:
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for s in mi.mesh.get_surface_count():
		var arr := surface_arrays(mi.mesh, s)
		if arr.size() <= Mesh.ARRAY_WEIGHTS or arr[Mesh.ARRAY_VERTEX] == null:
			continue
		var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		if V.is_empty():
			continue
		var B = arr[Mesh.ARRAY_BONES]
		var W = arr[Mesh.ARRAY_WEIGHTS]
		var k := 0
		if B != null and W != null:
			k = int((B as PackedInt32Array).size() / V.size())
		var stride := maxi(1, ceili(float(V.size()) / float(cap)))
		var pv := PackedVector3Array()   # the sampled vertices
		var pn := PackedInt32Array()     # ...how many bones move each (0 = none: drawn where it is)
		var pb := PackedInt32Array()     # ...and which, with what weight, in order
		var pw := PackedFloat32Array()
		for i in range(0, V.size(), stride):
			pv.append(V[i])
			var n := 0
			for j in k:
				var w: float = W[i * k + j]
				if w > 0.0:
					pb.append(B[i * k + j])
					pw.append(w)
					n += 1
			pn.append(n)
		for ms: Array[Transform3D] in sets:
			var o := 0
			for vi in pv.size():
				var n := pn[vi]
				var p := pv[vi]
				if n == 1:
					if pb[o] < ms.size():
						p = ms[pb[o]] * p
				elif n > 1:
					var acc := Vector3.ZERO
					var ws := 0.0
					for j in n:
						var bj := pb[o + j]
						if bj < ms.size():
							acc += (ms[bj] * p) * pw[o + j]
							ws += pw[o + j]
					if ws > 0.0:
						p = acc / ws
				o += n
				lo = lo.min(p)
				hi = hi.max(p)
	if not (hi.x >= lo.x):
		return AABB()
	return AABB(lo, hi - lo)


# _skinned_extent's skinning for ONE set of matrices, keeping the points instead of their box (an empty
# `ms`: an unskinned mesh, its vertices as they are). At most `cap` vertices per surface.
static func _skinned_points(mi: MeshInstance3D, ms: Array[Transform3D], cap: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for s in mi.mesh.get_surface_count():
		var arr := surface_arrays(mi.mesh, s)
		if arr.size() <= Mesh.ARRAY_WEIGHTS or arr[Mesh.ARRAY_VERTEX] == null:
			continue
		var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		if V.is_empty():
			continue
		var B = arr[Mesh.ARRAY_BONES]
		var W = arr[Mesh.ARRAY_WEIGHTS]
		var k := 0
		if not ms.is_empty() and B != null and W != null:
			k = int((B as PackedInt32Array).size() / V.size())
		var stride := maxi(1, ceili(float(V.size()) / float(cap)))
		for i in range(0, V.size(), stride):
			var p := V[i]
			var acc := Vector3.ZERO
			var ws := 0.0
			for j in k:
				var w: float = W[i * k + j]
				var bj: int = B[i * k + j]
				if w > 0.0 and bj < ms.size():
					acc += (ms[bj] * p) * w
					ws += w
			out.append(acc / ws if ws > 0.0 else p)
	return out


# Bones parents-first, so a pose's globals compose in one pass whatever order the rig lists them in.
static func _bone_order(skel: Skeleton3D) -> PackedInt32Array:
	var order := PackedInt32Array()
	var todo := skel.get_parentless_bones()
	while not todo.is_empty():
		var b := todo[todo.size() - 1]
		todo.remove_at(todo.size() - 1)
		order.append(b)
		todo.append_array(skel.get_bone_children(b))
	return order


# A clip's bone tracks resolved ONCE: [track, type, bone] for every position/rotation/scale track that
# drives this skeleton. The AnimationPlayer's own root is where its track paths start.
static func _bone_tracks(skel: Skeleton3D, anim: Animation, aroot: Node) -> Array:
	var out: Array = []
	if aroot == null:
		return out
	for tr in anim.get_track_count():
		var ty := anim.track_get_type(tr)
		if ty != Animation.TYPE_POSITION_3D and ty != Animation.TYPE_ROTATION_3D and ty != Animation.TYPE_SCALE_3D:
			continue
		var path := anim.track_get_path(tr)
		if aroot.get_node_or_null(NodePath(path.get_concatenated_names())) != skel:
			continue
		var bi := skel.find_bone(String(path.get_concatenated_subnames()))
		if bi >= 0:
			out.append([tr, ty, bi])
	return out


# Bone GLOBAL poses (skeleton space) of `anim` at time `t`, sampled straight off its tracks — no
# AnimationPlayer, no tree: the populate cache source never enters the tree. Composed the way
# Skeleton3D composes a bone pose (position, rotation * scale), over the bones' rests (rp/rr/rs).
static func _pose_at(skel: Skeleton3D, anim: Animation, tracks: Array, rp: PackedVector3Array, rr: Array[Quaternion], rs: PackedVector3Array, order: PackedInt32Array, t: float) -> Array[Transform3D]:
	var loc := _pose_locals(anim, tracks, rp, rr, rs, t)
	return _compose(skel, order, loc[0], loc[1], loc[2])


# The bones' LOCAL poses of `anim` at time `t` over their rests: [positions, rotations, scales] (_pose_at's first half;
# null `anim`: the rests).
static func _pose_locals(anim: Animation, tracks: Array, rp: PackedVector3Array, rr: Array[Quaternion], rs: PackedVector3Array, t: float) -> Array:
	var pos := rp.duplicate()
	var rot: Array[Quaternion] = rr.duplicate()
	var scl := rs.duplicate()
	if anim != null:
		for e in tracks:
			var bi: int = e[2]
			match int(e[1]):
				Animation.TYPE_POSITION_3D:
					pos[bi] = anim.position_track_interpolate(e[0], t)
				Animation.TYPE_ROTATION_3D:
					rot[bi] = anim.rotation_track_interpolate(e[0], t)
				_:
					scl[bi] = anim.scale_track_interpolate(e[0], t)
	return [pos, rot, scl]


# Local poses composed into skeleton-space globals, parents first (_pose_at's second half).
static func _compose(skel: Skeleton3D, order: PackedInt32Array, pos: PackedVector3Array, rot: Array[Quaternion], scl: PackedVector3Array) -> Array[Transform3D]:
	var glob: Array[Transform3D] = []
	glob.resize(skel.get_bone_count())
	for i in order:
		var loc := Transform3D(Basis(rot[i]) * Basis.from_scale(scl[i]), pos[i])
		var par := skel.get_bone_parent(i)
		glob[i] = (glob[par] * loc) if par >= 0 else loc
	return glob


# Accumulated transform from a descendant node up to (but excluding) `top`.
static func xf_to(from: Node, top: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var w: Node = from
	while w != null and w != top and w is Node3D:
		xf = (w as Node3D).transform * xf
		w = w.get_parent()
	return xf


# ---------------------------------------------------------------------------
# A RIDER ON THE BACK IT DRAWS (step 5b) — where a mount's seat is and where a rider sits on it, both measured on what is
# drawn, once per model: never a bone and a constant. The seat was the highest torso-named bone plus 6% of the bone box and
# the rider was placed by its resting pelvis plus 12 cm, so on 11 real heroes x 33 real mounts 20 mounts sank every rider
# (the default horse 6-28 cm, its saddle hidden inside it; the cow 32-55 cm; the default dragon 2.1-2.4 m, only the hands
# showing through its belly; fish 0.4-6.5 m), 9 floated every rider (17-84 cm over a triceratops, a T-rex, the hydra) and
# heroes sat 22 cm apart on one horse (followups3, seats).
#   mount_seat  the top of the mount's drawn back under its saddle point, and the triangle it lies on (anchor_now: that
#               surface point as the body draws it in any pose, 3 vertices re-skinned).
#   rider_seat  the rider's drawn seat in the ride pose, held in their hips bone's frame (seat_point: where it is now).
# Each answer is held by the model it measures — its first skin (its first mesh with none) — as GRig holds its map: every
# duplicate of a cached GLB shares it, and it goes when the model does.
# ---------------------------------------------------------------------------
const SADDLE_T := 0.06            # the saddle pad, metres: its base on the drawn back, the rider's seat on its top
const SEAT_FOOT := Vector2(0.04, 0.08)   # half the rider's seat, metres (x across, z along): what of the back is under it
const SEAT_GRID := 0.04           # the back is read on vertical lines this far apart, metres (SEAT_FOOT's own spacing)
const SEAT_WIDE := 4              # a seat is this many lines (0.16 m) wide each side of its middle line ...
const SEAT_DROP := 0.15           # ... the back there no more than this below its middle, metres (a fin or a neck is narrower)
const SEAT_CLEAR := 0.05          # nothing of the back under the rider's seat more than this above its middle (a plate, a crest)
const SEAT_SEARCH := 0.35         # how far along the body (x its drawn length) a saddle looks from its profile's point
const BODY_STEP := 0.05           # the body round a seat is read on vertical lines this far apart, metres ...
const BODY_REACH := 1.3           # ... this far from it each way across and along (where a rider's legs can reach)
const RIDER_REACH := 0.5          # the rider's seat is looked for this far below their hip joints, metres
const THIGH_ROOT := 0.15          # ... and a thigh root is the flesh a thigh carries this near its joint, metres
const PATCH_R := 0.35             # ... in the triangles with a corner this near them across (any pose's crotch lies within)
const META_SEAT := "gpose_seat"   # on a model's first skin (its first mesh with none): {key -> the seat answer}
static var seat_measures := 0     # cold seat measurements, a mount's or a rider's (the drive rig: once per model, never a spawn)
static var anchor_reads := 0      # surface points re-skinned by anchor_now (the drive rig: one a ridden mount's rendered frame)
static var seat_reads := 0        # what a seat job's pieces read — a vertex skinned or sorted, a triangle cut, a bone posed: no
                                  # piece more than SCAN_VERTS (the drive rig counts them a piece at a time)


## The resource a model's seat answers are held on and the model's key: [key, its first skin (first mesh with none)].
static func _seat_holder(node: Node3D) -> Array:
	var ids := PackedStringArray()
	var res: Resource = null
	for mi: MeshInstance3D in _seat_meshes(node):
		if mi.mesh == null:
			continue
		ids.append(_mesh_key(mi))
		if res == null:
			res = mi.skin if mi.skin != null else mi.mesh
	return [",".join(ids), res]


static func _seat_get(res: Resource, key: String) -> Variant:
	if res == null or key == "":
		return null
	return (res.get_meta(META_SEAT, {}) as Dictionary).get(key)


static func _seat_put(res: Resource, key: String, v: Dictionary) -> void:
	if res == null or key == "":
		return
	var d: Dictionary = res.get_meta(META_SEAT, {})
	d[key] = v
	res.set_meta(META_SEAT, d)


## What a model draws its seat with: every mesh under it — the node itself too when it is one (a mount whose model never
## loaded is a grey box, its own MeshInstance3D).
static func _seat_meshes(node: Node3D) -> Array:
	var out: Array = [node] if node is MeshInstance3D else []
	out.append_array(node.find_children("*", "MeshInstance3D", true, false))
	return out


# How many vertices surface `s` of `mesh` has: an ArrayMesh says (a GLB's); a primitive (a BoxMesh: a mount that never loaded
# is a grey box) has none to say, so its arrays are read.
static func _vert_count(mesh: Mesh, s: int) -> int:
	if mesh is ArrayMesh:
		return (mesh as ArrayMesh).surface_get_array_len(s)
	var arr := surface_arrays(mesh, s)
	return (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() if arr.size() > Mesh.ARRAY_VERTEX and arr[Mesh.ARRAY_VERTEX] != null else 0


# Each skin bind's bone in `skel` (-1: none it can name).
static func _bind_bones(mi: MeshInstance3D, skel: Skeleton3D) -> PackedInt32Array:
	var out := PackedInt32Array()
	for b in mi.skin.get_bind_count():
		var bi := mi.skin.get_bind_bone(b)
		if bi < 0:
			bi = skel.find_bone(String(mi.skin.get_bind_name(b)))
		out.append(bi)
	return out


## Barycentric (l1, l2, l3) of (x, z) in a triangle's xz projection — any < 0: outside it; Vector3.INF: it stands on edge.
static func _bary_xz(a: Vector3, b: Vector3, c: Vector3, x: float, z: float) -> Vector3:
	var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(d) < 1e-14:
		return Vector3.INF
	var l1 := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / d
	var l2 := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / d
	return Vector3(l1, l2, 1.0 - l1 - l2)


## A mesh surface read for a seat measurement, its vertices skinned under `glob` (bone -> skeleton-space global; empty: as
## they are) and placed in `node`'s frame: {P, V, I (triangles, in order when the surface has no index), B, W, nk (bones
## a vertex), bones (each bind's bone), binds (each bind's pose), xf (the mesh in node's frame), skel}. Skinned `first`..
## `first + count` (the rest is filled by later calls: _seat_skin).
static func _seat_surface(mi: MeshInstance3D, s: int, node: Node3D, skel: Skeleton3D) -> Dictionary:
	var arr := surface_arrays(mi.mesh, s)
	var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX] if arr.size() > Mesh.ARRAY_VERTEX and arr[Mesh.ARRAY_VERTEX] != null else PackedVector3Array()
	var I = arr[Mesh.ARRAY_INDEX] if arr.size() > Mesh.ARRAY_INDEX else null
	var B = arr[Mesh.ARRAY_BONES] if arr.size() > Mesh.ARRAY_BONES else null
	var W = arr[Mesh.ARRAY_WEIGHTS] if arr.size() > Mesh.ARRAY_WEIGHTS else null
	var tri := PackedInt32Array(I) if I != null else PackedInt32Array()
	if tri.is_empty():
		for v in V.size():
			tri.append(v)
	var bones := PackedInt32Array()
	var binds: Array[Transform3D] = []
	var nk := 0
	if skel != null and mi.skin != null:
		bones = _bind_bones(mi, skel)
		for b in mi.skin.get_bind_count():
			binds.append(mi.skin.get_bind_pose(b))
		if B != null and W != null and not V.is_empty():
			nk = int((B as PackedInt32Array).size() / V.size())
	var P := PackedVector3Array()
	P.resize(V.size())
	return {"P": P, "V": V, "I": tri, "B": B, "W": W, "nk": nk, "bones": bones, "binds": binds, "xf": xf_to(mi, node), "skel": skel}


## Vertices `v0` .. `v0 + count` of a _seat_surface skinned under the globals `glob` (empty: unskinned), into its P; returns
## their extent [lo, hi] in node's frame.
static func _seat_skin(d: Dictionary, glob: Array[Transform3D], v0: int, count: int) -> Array:
	var V: PackedVector3Array = d["V"]
	var P: PackedVector3Array = d["P"]
	var nk: int = d["nk"]
	var B = d["B"]
	var W = d["W"]
	var bones: PackedInt32Array = d["bones"]
	var binds: Array[Transform3D] = d["binds"]
	var xf: Transform3D = d["xf"]
	var mats: Array[Transform3D] = []
	if nk > 0:
		for b in bones.size():
			mats.append((glob[bones[b]] if bones[b] >= 0 and bones[b] < glob.size() else Transform3D.IDENTITY) * binds[b])
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for vi in range(v0, mini(v0 + count, V.size())):
		var p := V[vi]
		if nk > 0:
			var acc := Vector3.ZERO
			var ws := 0.0
			for j in nk:
				var w: float = W[vi * nk + j]
				var bj: int = B[vi * nk + j]
				if w > 0.0 and bj < mats.size():
					acc += (mats[bj] * p) * w
					ws += w
			if ws > 0.0:
				p = acc / ws
		p = xf * p
		P[vi] = p
		lo = lo.min(p)
		hi = hi.max(p)
	d["P"] = P   # packed arrays are values: written back
	return [lo, hi]


## The vertices `ids` of a _seat_surface skinned under `glob` and placed in node's frame: {vertex: position} (its P untouched).
static func _seat_skin_ids(d: Dictionary, glob: Array, ids: Array) -> Dictionary:
	var V: PackedVector3Array = d["V"]
	var nk: int = d["nk"]
	var B = d["B"]
	var W = d["W"]
	var bones: PackedInt32Array = d["bones"]
	var binds: Array[Transform3D] = d["binds"]
	var xf: Transform3D = d["xf"]
	var mats: Array[Transform3D] = []
	if nk > 0:
		for b in bones.size():
			mats.append((glob[bones[b]] if bones[b] >= 0 and bones[b] < glob.size() else Transform3D.IDENTITY) * binds[b])
	var out := {}
	for vi in ids:
		var p := V[vi]
		if nk > 0:
			var acc := Vector3.ZERO
			var ws := 0.0
			for j in nk:
				var w: float = W[vi * nk + j]
				var bj: int = B[vi * nk + j]
				if w > 0.0 and bj < mats.size():
					acc += (mats[bj] * p) * w
					ws += w
			if ws > 0.0:
				p = acc / ws
		out[vi] = xf * p
	return out


# The skeleton-space globals of `skel` at rest.
static func _rest_globals(skel: Skeleton3D) -> Array[Transform3D]:
	var g: Array[Transform3D] = []
	for i in skel.get_bone_count():
		g.append(skel.get_bone_global_rest(i))
	return g


# The bones' local rests split as _pose_locals takes them: [positions, rotations, scales].
static func _rest_parts(skel: Skeleton3D) -> Array:
	var rp := PackedVector3Array()
	var rr: Array[Quaternion] = []
	var rs := PackedVector3Array()
	for b in skel.get_bone_count():
		var r := skel.get_bone_rest(b)
		rp.append(r.origin)
		rr.append(r.basis.get_rotation_quaternion())
		rs.append(r.basis.get_scale())
	return [rp, rr, rs]


# The skeleton-space globals of `skel` as its model stands drawn: `ap`'s idle at 0 (the pose a parked mount shows as a rider
# boards it), else rest. A rest pose is never drawn: measured at rest, a mount's saddle stood off the back it draws parked —
# a frog's 0.095 m, a T-rex's 0.069, a rat's 0.056, a fox's 0.037 — and the mire dragon's went 0.12 m further back along it
# (rule (b) read another row as its back). The back under the saddle point itself is the same on every library mount.
static func _idle_globals(skel: Skeleton3D, ap: AnimationPlayer) -> Array[Transform3D]:
	var idle := GClip.resolve(ap, "idle") if ap != null else ""
	if idle == "" or not ap.has_animation(idle):
		return _rest_globals(skel)
	var an := ap.get_animation(idle)
	var r := _rest_parts(skel)
	return _pose_at(skel, an, _bone_tracks(skel, an, ap.get_node_or_null(ap.root_node)), r[0], r[1], r[2], _bone_order(skel), 0.0)


## THE SEAT ON A MOUNT'S DRAWN BACK, whole (MountSeatJob, worked to its end). Memoised per model, scale and point.
static func mount_seat(node: Node3D, k: float, x0: float, z0: float, search := SEAT_SEARCH) -> Dictionary:
	var job := MountSeatJob.new(node, k, x0, z0, search)
	while not job.step(-1):
		pass
	return job.seat


## THE SEAT ON A MOUNT'S DRAWN BACK, A PIECE AT A TIME (step(deadline): pieces until Time.get_ticks_usec() passes it, at least
## one; true when `seat` is the answer). `node` is the mount's model in its own frame (node.transform excluded), drawn at
## `k` metres a unit (the rider's footprint and a seat's width are metres); (x0, z0) its profile's saddle point there.
## What it draws standing (its idle at 0: _idle_globals) is cut by vertical lines SEAT_GRID apart — nine across the saddle point's line and rows along the
## body within SEAT_SEARCH of it — keeping the top each line meets. THE SADDLE GOES ON A BACK (S1, rule (b)): the line through
## the saddle point if what tops it there is a seat, else the nearest along the body that is — not the head the map gives
## (GRig.head_bones), SEAT_WIDE lines wide each side within SEAT_DROP below its middle, and nothing under the rider's footprint
## more than SEAT_CLEAR above it — else the top on the point's own line. The default dragon is an upright wyvern: the top on
## its saddle point's line was its head, 4.62 m up (its rider sat on its skull); the shark's its dorsal fin.
## seat: {ok, kind: "drawn"|"none", x, z, y: the back's top on the line, relief: the most the back draws under the footprint
## over y (>= 0), rule: "point"|"moved"|"top", anchor: the surface point (anchor_now)} in node's frame and units. "none": no
## line near the point meets the body (a Rig Lab proxy's cubes). No piece reads more than SCAN_VERTS (GPose.seat_reads).
class MountSeatJob extends RefCounted:
	var node: Node3D
	var k := 1.0
	var x0 := 0.0
	var z0 := 0.0
	var search := 0.0
	var key := ""
	var done := false
	var seat := {}
	var _res: Resource = null
	var _units: Array = []            # [kind, mesh | first, surface, first vertex | first index]: "pose", "skin", "grid", "cut", "pick",
	                                  # "range", "body", "seal"
	var _ui := 0
	var _mis: Array = []
	var _sf := {}                     # "mesh/surface" -> _seat_surface
	var _lo := Vector3(INF, INF, INF)
	var _hi := -Vector3(INF, INF, INF)
	var _step := 1.0
	var _r0 := 0                      # the rows: r at z0 + r * _step, _r0 .. _r1
	var _r1 := -1
	var _top := PackedFloat32Array()  # (r - _r0) * 9 + (column + 4) -> the top that line meets (-INF: none)
	var _ref := {}                    # row -> [mesh, surface, a, b, c, bary]: the triangle the middle line's top lies on
	var _bn := 0                      # the body round the seat: lines -_bn.._bn each way, _bstep apart, round (x0, _bz) ...
	var _bstep := 1.0
	var _bz := 0.0
	var _bys: Array = []              # ... every height each meets the surface at ((r + _bn) * (2 * _bn + 1) + i + _bn)
	var _glob := {}                   # skeleton id -> its bones' globals as measured (_globals)
	var _rg := {}                     # what the reach's pieces pose the back with (_range_units)

	func _init(n: Node3D, scale_k: float, sx: float, sz: float, how_far := GPose.SEAT_SEARCH) -> void:
		node = n
		k = maxf(scale_k, 1e-6)
		x0 = sx
		z0 = sz
		search = how_far
		var h := GPose._seat_holder(n)
		_res = h[1]
		key = "mount:%s@%.5f|%.4f,%.4f/%.2f" % [h[0], k, sx, sz, search]
		var held = GPose._seat_get(_res, key)
		if held != null:
			seat = held
			done = true
			return
		GPose.seat_measures += 1
		for mi: MeshInstance3D in GPose._seat_meshes(n):
			if mi.mesh != null:
				_mis.append(mi)
		_units.append(["pose", 0, 0, 0])
		for i in _mis.size():
			var mesh: Mesh = (_mis[i] as MeshInstance3D).mesh
			for s in mesh.get_surface_count():
				for v0 in range(0, GPose._vert_count(mesh, s), GPose.SCAN_VERTS):
					_units.append(["skin", i, s, v0])
		_units.append(["grid", 0, 0, 0])

	func step(deadline: int) -> bool:
		if done:
			return true
		while _ui < _units.size():
			_unit(_units[_ui])
			_ui += 1
			if deadline >= 0 and Time.get_ticks_usec() > deadline:
				break
		if _ui < _units.size():
			return false
		done = true
		GPose._seat_put(_res, key, seat)
		_sf.clear()
		return true

	func _surface(i: int, s: int) -> Dictionary:
		var kk := "%d/%d" % [i, s]
		if not _sf.has(kk):
			var mi: MeshInstance3D = _mis[i]
			_sf[kk] = GPose._seat_surface(mi, s, node, GPose._skin_skeleton(mi))
		return _sf[kk]

	# What the model draws is measured as it stands parked (GPose._idle_globals), once per skeleton.
	func _globals(skel: Skeleton3D) -> Array[Transform3D]:
		var id := skel.get_instance_id()
		if not _glob.has(id):
			_glob[id] = GPose._idle_globals(skel, GPose._find_anim_player(node))
			GPose.seat_reads += skel.get_bone_count()
		return _glob[id]

	func _unit(u: Array) -> void:
		match String(u[0]):
			"pose":
				# what each skeleton draws standing, a piece of its own
				for mi in _mis:
					var sk := GPose._skin_skeleton(mi)
					if sk != null:
						_globals(sk)
			"skin":
				var d := _surface(u[1], u[2])
				var skel: Skeleton3D = d["skel"]
				var e := GPose._seat_skin(d, _globals(skel) if skel != null else ([] as Array[Transform3D]), u[3], GPose.SCAN_VERTS)
				GPose.seat_reads += mini(GPose.SCAN_VERTS, (d["V"] as PackedVector3Array).size() - int(u[3]))
				_lo = _lo.min(e[0])
				_hi = _hi.max(e[1])
			"grid":
				# the rows along the body the saddle may move over (and the footprint's two beyond them), then the cuts
				if not (_hi.z >= _lo.z):
					seat = {"ok": false, "kind": "none"}   # it draws nothing
					return
				_step = GPose.SEAT_GRID / k
				var R := ceili(search * maxf(_hi.z - _lo.z, _step) / _step)
				_r0 = maxi(-R - 2, floori((_lo.z - z0) / _step))
				_r1 = mini(R + 2, ceili((_hi.z - z0) / _step))
				if _r1 >= _r0:
					_top.resize(9 * (_r1 - _r0 + 1))
					_top.fill(-INF)
				for kk in _sf:
					var nt: int = (_sf[kk]["I"] as PackedInt32Array).size()
					var ms: PackedStringArray = String(kk).split("/")
					for t0 in range(0, nt, 3 * GPose.SCAN_VERTS):
						_units.append(["cut", int(ms[0]), int(ms[1]), t0])
				_units.append(["pick", 0, 0, 0])
			"cut":
				_cut(_surface(u[1], u[2]), u[1], u[2], u[3])
				GPose.seat_reads += mini(GPose.SCAN_VERTS, ((_surface(u[1], u[2])["I"] as PackedInt32Array).size() - int(u[3])) / 3)
			"pick":
				_pick()
				GPose.seat_reads += 9 * maxi(0, _r1 - _r0 + 1)
				if bool(seat.get("ok", false)):
					_range_units()
					# ...then the body round it, where a rider's legs go (Vehicle._fit_legs reads it)
					_bn = roundi(GPose.BODY_REACH / GPose.BODY_STEP)
					_bstep = GPose.BODY_STEP / k
					_bz = float(seat["z"])
					_bys.resize((2 * _bn + 1) * (2 * _bn + 1))
					for q in _bys.size():
						_bys[q] = PackedFloat32Array()
					for kk in _sf:
						var nt: int = (_sf[kk]["I"] as PackedInt32Array).size()
						var ms: PackedStringArray = String(kk).split("/")
						for t0 in range(0, nt, 3 * GPose.SCAN_VERTS):
							_units.append(["body", int(ms[0]), int(ms[1]), t0])
					for q0 in range(0, _bys.size(), GPose.SCAN_VERTS):
						_units.append(["seal", q0, 0, 0])
			"range":
				_range(u)
			"body":
				_body(_surface(u[1], u[2]), u[3])
				GPose.seat_reads += mini(GPose.SCAN_VERTS, ((_surface(u[1], u[2])["I"] as PackedInt32Array).size() - int(u[3])) / 3)
			"seal":
				for q in range(int(u[1]), mini(int(u[1]) + GPose.SCAN_VERTS, _bys.size())):
					var ys: PackedFloat32Array = _bys[q]
					ys.sort()
					_bys[q] = ys
					GPose.seat_reads += 1
				seat["body"] = {"x": x0, "z": _bz, "step": _bstep, "n": _bn, "ys": _bys}

	# Triangles t0 .. t0 + 3 * SCAN_VERTS of a surface against the lines their footprint covers: the top each line meets.
	func _cut(d: Dictionary, i: int, s: int, t0: int) -> void:
		if _r1 < _r0:
			return
		var P: PackedVector3Array = d["P"]
		var I: PackedInt32Array = d["I"]
		for t in range(t0, mini(t0 + 3 * GPose.SCAN_VERTS, I.size() - 2), 3):
			var a := P[I[t]]
			var b := P[I[t + 1]]
			var c := P[I[t + 2]]
			var c0 := maxi(-4, ceili((minf(a.x, minf(b.x, c.x)) - x0) / _step - 1e-6))
			var c1 := mini(4, floori((maxf(a.x, maxf(b.x, c.x)) - x0) / _step + 1e-6))
			if c0 > c1:
				continue
			var q0 := maxi(_r0, ceili((minf(a.z, minf(b.z, c.z)) - z0) / _step - 1e-6))
			var q1 := mini(_r1, floori((maxf(a.z, maxf(b.z, c.z)) - z0) / _step + 1e-6))
			for r in range(q0, q1 + 1):
				var z := z0 + float(r) * _step
				for col in range(c0, c1 + 1):
					var l := GPose._bary_xz(a, b, c, x0 + float(col) * _step, z)
					if not l.is_finite() or l.x < -1e-6 or l.y < -1e-6 or l.z < -1e-6:
						continue
					var y := l.x * a.y + l.y * b.y + l.z * c.y
					var gi := (r - _r0) * 9 + col + 4
					if y > _top[gi]:
						_top[gi] = y
						if col == 0:
							_ref[r] = [i, s, I[t], I[t + 1], I[t + 2], l]

	# Triangles t0 .. of a surface against the body's lines round the seat: every crossing each line meets.
	func _body(d: Dictionary, t0: int) -> void:
		var P: PackedVector3Array = d["P"]
		var I: PackedInt32Array = d["I"]
		var w := 2 * _bn + 1
		for t in range(t0, mini(t0 + 3 * GPose.SCAN_VERTS, I.size() - 2), 3):
			var a := P[I[t]]
			var b := P[I[t + 1]]
			var c := P[I[t + 2]]
			var c0 := maxi(-_bn, ceili((minf(a.x, minf(b.x, c.x)) - x0) / _bstep - 1e-6))
			var c1 := mini(_bn, floori((maxf(a.x, maxf(b.x, c.x)) - x0) / _bstep + 1e-6))
			if c0 > c1:
				continue
			var q0 := maxi(-_bn, ceili((minf(a.z, minf(b.z, c.z)) - _bz) / _bstep - 1e-6))
			var q1 := mini(_bn, floori((maxf(a.z, maxf(b.z, c.z)) - _bz) / _bstep + 1e-6))
			for r in range(q0, q1 + 1):
				for col in range(c0, c1 + 1):
					var l := GPose._bary_xz(a, b, c, x0 + float(col) * _bstep, _bz + float(r) * _bstep)
					if not l.is_finite() or l.x < -1e-6 or l.y < -1e-6 or l.z < -1e-6:
						continue
					var gi := (r + _bn) * w + col + _bn
					var ys: PackedFloat32Array = _bys[gi]
					ys.append(l.x * a.y + l.y * b.y + l.z * c.y)
					_bys[gi] = ys

	func _at(r: int, col: int) -> float:
		if r < _r0 or r > _r1:
			return -INF
		return _top[(r - _r0) * 9 + col + 4]

	# Is the top of row r's middle line a seat: no head, a seat wide, clear of anything rising under the rider?
	func _is_seat(r: int, head: Dictionary) -> bool:
		var c := _at(r, 0)
		if not is_finite(c) or not _ref.has(r):
			return false
		if not head.is_empty() and head.has(_dominant(_ref[r])):
			return false
		var drop := GPose.SEAT_DROP / k
		for col in [-GPose.SEAT_WIDE, GPose.SEAT_WIDE]:
			if not (_at(r, col) >= c - drop):
				return false
		var rise := GPose.SEAT_CLEAR / k
		var fz := roundi(GPose.SEAT_FOOT.y / GPose.SEAT_GRID)
		for rr in range(r - fz, r + fz + 1):
			for col in [-1, 0, 1]:
				if not (_at(rr, col) <= c + rise):
					return false
		return true

	# The bone that carries most of a triangle's top point (its vertices' weights by how near the point is to each).
	func _dominant(ref: Array) -> int:
		var d := _surface(ref[0], ref[1])
		var nk: int = d["nk"]
		if nk <= 0:
			return -1
		var acc := {}
		var l: Vector3 = ref[5]
		for q in 3:
			var vi: int = ref[2 + q]
			for j in nk:
				var bj: int = d["B"][vi * nk + j]
				if bj < (d["bones"] as PackedInt32Array).size():
					var b: int = d["bones"][bj]
					acc[b] = float(acc.get(b, 0.0)) + float(d["W"][vi * nk + j]) * l[q]
		var best := -1
		var bw := -1.0
		for b in acc:
			if float(acc[b]) > bw:
				bw = acc[b]
				best = b
		return best

	func _pick() -> void:
		var head := {}
		var sk := GPose.skeleton_of(node)
		for b in GRig.head_bones(node):
			head[b] = true
		var R := maxi(absi(_r0), absi(_r1))
		var row := INF
		var rule := "point"
		for dr in R + 1:
			for r in ([0] if dr == 0 else [dr, -dr]):
				if is_finite(row):
					break
				if _is_seat(r, head if (sk != null and _skel_of_ref(r) == sk) else {}):
					row = r
					rule = "point" if r == 0 else "moved"
		if not is_finite(row):
			# no seat near it: the top on the saddle point's own line (rule (a)) — or, meeting nothing, the nearest line that
			# meets the body; none, no back under the saddle at all
			rule = "top"
			for dr in R + 1:
				for r in ([0] if dr == 0 else [dr, -dr]):
					if not is_finite(row) and is_finite(_at(r, 0)) and _ref.has(r):
						row = r
		if not is_finite(row):
			seat = {"ok": false, "kind": "none"}
			return
		var r := int(row)
		var c := _at(r, 0)
		var relief := 0.0
		var fz := roundi(GPose.SEAT_FOOT.y / GPose.SEAT_GRID)
		for rr in range(r - fz, r + fz + 1):
			for col in [-1, 0, 1]:
				var t := _at(rr, col)
				if is_finite(t):
					relief = maxf(relief, t - c)
		seat = {"ok": true, "kind": "drawn", "x": x0, "z": z0 + float(r) * _step, "y": c, "relief": relief, "rule": rule,
			"anchor": _anchor(_ref[r])}

	# HOW FAR THE BACK UNDER THE SADDLE MOVES: the anchored point over every clip the mount shows ridden (GClip.gait_clips) at
	# FIT_POSES x 1.5 phases each, off its rest — [lowest, highest] in node's frame: "reach" over the ground's clips, "reach_air"
	# over the air's (a flyer's flap and glide), as the hull is one box on the ground and another in the air. A rider rides it
	# (Vehicle._follow_seat), so the hull that holds their top holds that too: a walking raptor's back rose 0.20 m. Posed a few
	# phases a piece (SCAN_VERTS bones posed): a clip's whole sweep was one piece of the pick (the mire dragon's four clips).
	func _range_units() -> void:
		seat["reach"] = [Vector3.ZERO, Vector3.ZERO]
		seat["reach_air"] = [Vector3.ZERO, Vector3.ZERO]
		var skel := _skel_of_ref(int(roundi((float(seat["z"]) - z0) / _step)))
		var ap := GPose._find_anim_player(node)
		if skel == null or ap == null or skel.get_bone_count() == 0:
			return
		var rest := GPose._rest_parts(skel)
		_rg = {"skel": skel, "ap": ap, "rp": rest[0], "rr": rest[1], "rs": rest[2], "order": GPose._bone_order(skel),
			"aroot": ap.get_node_or_null(ap.root_node), "tracks": {}}
		var n := int(GPose.FIT_POSES * 1.5)
		var per := maxi(1, GPose.SCAN_VERTS / skel.get_bone_count())
		for air in [false, true]:
			for c in GClip.gait_clips(ap, air):
				if ap.get_animation(c) == null:
					continue
				for ph0 in range(0, n, per):
					_units.append(["range", c, ph0, mini(per, n - ph0), "reach_air" if air else "reach"])

	# One piece of _range_units: phases ph0 .. ph0 + count of clip u[1], into seat[u[4]].
	func _range(u: Array) -> void:
		var a: Dictionary = seat["anchor"]
		var skel: Skeleton3D = _rg["skel"]
		var an := (_rg["ap"] as AnimationPlayer).get_animation(String(u[1]))
		var tr: Dictionary = _rg["tracks"]
		if not tr.has(u[1]):
			tr[u[1]] = GPose._bone_tracks(skel, an, _rg["aroot"])
		var n := int(GPose.FIT_POSES * 1.5)
		var r: Array = seat[u[4]]
		for ph in range(int(u[2]), int(u[2]) + int(u[3])):
			var dp := GPose.anchor_at(GPose._pose_at(skel, an, tr[u[1]], _rg["rp"], _rg["rr"], _rg["rs"], _rg["order"], an.length * float(ph) / float(n)), a) - (a["rest"] as Vector3)
			r[0] = (r[0] as Vector3).min(dp)
			r[1] = (r[1] as Vector3).max(dp)
			GPose.seat_reads += skel.get_bone_count()

	func _skel_of_ref(r: int) -> Skeleton3D:
		return _surface(_ref[r][0], _ref[r][1])["skel"] if _ref.has(r) else null

	# The triangle's point as anchor_now re-skins it: each vertex as stored and the bones and binds that move it; "rest": the
	# point as measured (the idle at 0), what a ridden mount's follow moves the rider by the difference from.
	func _anchor(ref: Array) -> Dictionary:
		var d := _surface(ref[0], ref[1])
		var nk: int = d["nk"]
		var verts: Array = []
		var rest := Vector3.ZERO
		var l: Vector3 = ref[5]
		for q in 3:
			var vi: int = ref[2 + q]
			var inf: Array = []
			for j in nk:
				var w: float = d["W"][vi * nk + j]
				var bj: int = d["B"][vi * nk + j]
				if w > 0.0 and bj < (d["bones"] as PackedInt32Array).size() and int(d["bones"][bj]) >= 0:
					inf.append([int(d["bones"][bj]), (d["binds"] as Array)[bj], w])
			verts.append([(d["V"] as PackedVector3Array)[vi], inf])
			rest += (d["P"] as PackedVector3Array)[vi] * l[q]
		return {"mesh": ref[0], "xf": d["xf"], "verts": verts, "bary": l, "rest": rest}


## That surface point under the bone globals `glob` (skeleton space, every bone), in the model's frame (MountSeatJob's range).
static func anchor_at(glob: Array, a: Dictionary) -> Vector3:
	var l: Vector3 = a["bary"]
	var xf: Transform3D = a["xf"]
	var out := Vector3.ZERO
	var q := 0
	for e in a["verts"]:
		var v: Vector3 = e[0]
		var p := v
		var inf: Array = e[1]
		if not inf.is_empty():
			var acc := Vector3.ZERO
			var ws := 0.0
			for f in inf:
				acc += ((glob[int(f[0])] as Transform3D) * (f[1] as Transform3D) * v) * float(f[2])
				ws += float(f[2])
			if ws > 0.0:
				p = acc / ws
		out += (xf * p) * l[q]
		q += 1
	return out


## THAT SURFACE POINT AS THE BODY DRAWS IT NOW, in the model's frame: the anchor's three vertices skinned by `skel`'s current
## bone poses (the mesh `mesh`'s skeleton), placed as the mesh is placed. Three vertices a call: the cost of a seat that rides
## the back through every gait (anchor_reads counts them).
static func anchor_now(skel: Skeleton3D, a: Dictionary) -> Vector3:
	anchor_reads += 1
	var l: Vector3 = a["bary"]
	var xf: Transform3D = a["xf"]
	var out := Vector3.ZERO
	var q := 0
	for e in a["verts"]:
		var v: Vector3 = e[0]
		var p := v
		var inf: Array = e[1]
		if skel != null and not inf.is_empty():
			var acc := Vector3.ZERO
			var ws := 0.0
			for f in inf:
				acc += (skel.get_bone_global_pose(int(f[0])) * (f[1] as Transform3D) * v) * float(f[2])
				ws += float(f[2])
			if ws > 0.0:
				p = acc / ws
		out += (xf * p) * l[q]
		q += 1
	return out


## THE RIDER'S SEAT, whole (RiderSeatJob worked to its end). Memoised per model.
static func rider_seat(node: Node3D) -> Dictionary:
	var job := RiderSeatJob.new(node)
	while not job.step(-1):
		pass
	return job.seat


## WHERE `character`'s DRAWN SEAT IS NOW, in its own frame (its transform excluded): their seat in the ride pose `fit`
## (RIDE_FITS: how far their legs are spread and bent) carried by their hips bone as it is posed now — the pose ride() put
## them in, and wherever a follow has moved them. Vector3.INF: no person of bones (a perch stands on the saddle; a body of
## parts sits by its own clip: Vehicle._seat_driver).
static func seat_point(character: Node3D, fit := 0) -> Vector3:
	var sk := skeleton_of(character)
	if sk == null:
		return Vector3.INF
	var m := rider_seat(character)
	if not bool(m.get("ok", false)):
		return Vector3.INF
	var at: Array = m["at"]
	return xf_to(sk, character) * (sk.get_bone_global_pose(int(m["hips"])) * (at[clampi(fit, 0, at.size() - 1)] as Vector3))


## THE RIDE POSES A RIDER'S LEGS MAY TAKE (decision S5: fitted to the mount's width): (thigh spread, knee bend) in degrees, in
## the order a mount tries them — the ride's own first, then wider and straighter. 40 / 90 on a wide back put 23-71% of a
## rider's leg inside it, up to 0.40 m deep (the default cow, a pig, a T-rex: the knee met the barrel and the shin and the
## foot went into it); spread wider with the knee still bent at 90 the feet tuck back into the belly, so the knee opens as
## the spread grows (followups3 step 5b, legs1: 70 / 45 left nothing of either leg in the cow or the T-rex).
const RIDE_FITS := [Vector2(40, 90), Vector2(45, 85), Vector2(50, 80), Vector2(55, 72), Vector2(60, 65), Vector2(65, 58),
	Vector2(70, 50), Vector2(75, 40), Vector2(80, 30), Vector2(85, 15)]
const LEG_SAMPLES := 300          # leg points kept a ride pose (and every one that bounds a leg): what the fit tests
const LEG_FLESH := 0.15           # ...flesh: within this of its bone (to the next joint down the leg), metres — a coat's hem the
                                  # thighs carry hangs 0.2-0.4 m off them and lies over the back (S3), no leg to fit
const FOOT_REACH := 0.3           # ...and a bone with no joint below it (a toe), within this of its own joint


## WHERE A PERSON SITS ASTRIDE, A PIECE AT A TIME (step(deadline) as MountSeatJob's). In each ride pose of RIDE_FITS — ride()'s
## own rotations on their idle's first frame, the pose ride() puts them in (it starts every ride from that frame) — the lowest
## point their body draws between their legs, but never below the undersides of their thigh roots (the flesh each thigh
## carries within THIGH_ROOT of its joint): what hangs lower between the legs is cloth, a coat's hem, which lies over the
## back, not under the rider (decision S3). Measured on the eleven heroes at 40 / 90: the lowest crossing between the legs
## 0.093-0.350 m under the hip joints (the warden's coat 0.350, the wanderer's 0.251), the thigh roots' undersides 0.123-0.149
## on every one; the higher of the two 0.093-0.149 — consistent, and blind to a coat (followups3, dt.log). The pelvis bone and
## a constant put the same people 0.09-0.27 m off what they draw. A wider spread lifts the thigh roots: at 80 degrees a
## hero placed by the 40-degree seat sat 3.3 cm high, so every pose has its own.
## seat: {ok, id: its key, hips: the hips bone, at: [the seat in the hips bone's frame, a pose of RIDE_FITS each], legs: [what
## each pose's legs draw, LEG_SAMPLES points, skeleton space, from its seat], boxes: [what they draw in each pose, skeleton
## space: the body no leg bone carries — the same in every pose — and that pose's legs]}; {ok: false} for no person of bones.
## Held in the hips' frame, the seat goes where the pelvis goes in the pose the rider really shows (seat_point). Read on the
## meshes skinned to the person's skeleton (the body: never a held weapon, the player's placeholder capsule), at the size the
## hero is drawn (PERSON_H).
## NO PIECE READS MORE THAN SCAN_VERTS (GPose.seat_reads): a pose posed, a piece of a surface skinned and weighed, a piece of
## its triangles or vertices picked over, a piece of one pose's wanted vertices skinned or cut. Its pick read every vertex and
## triangle of a hero in one piece and each pose weighed every vertex again: hero_fisher's 23.5k vertices were one 52.8 ms
## piece, and main's fetch (the hero, and every peer's avatar as it comes into range) spent 13 of its 14 frames over the 6 ms
## budget, 57.7 ms the worst (step 5b's review, pfetch).
class RiderSeatJob extends RefCounted:
	var node: Node3D
	var key := ""
	var done := false
	var seat := {}
	var _res: Resource = null
	var _units: Array = []            # ["pose"], ["ride", pose], ["skin", mesh, surface, first vertex], ["segs"], ["tris" | "verts", mesh,
	                                  # surface, first index | vertex], ["seal", mesh, surface], ["plan"], ["fit", pose, mesh, surface,
	                                  # first wanted], ["cut", pose, mesh, surface, first patch triangle], ["legs", pose, mesh, surface, first
	                                  # root | leg point], ["end"]
	var _ui := 0
	var _skel: Skeleton3D = null
	var _G: Array = []                # each ride pose's skeleton-space globals (Array[Transform3D] a pose)
	var _g0: Array[Transform3D] = []  # the idle's first frame, skeleton space (what each ride pose bends) ...
	var _loc: Array = []              # ... and its local poses [positions, rotations, scales]
	var _order := PackedInt32Array()
	var _limbs: Array = []            # [thighs, shins, upper arms, forearms]: the bones ride() bends
	var _axis := Vector3.RIGHT        # the character's lateral and forward axes, skeleton space
	var _fwd := Vector3.BACK
	var _mis: Array = []
	var _sf := {}
	var _hips := -1
	var _tl := -1
	var _tr := -1
	var _legset := {}                 # every bone a leg carries
	var _jl := Vector3.ZERO           # the hip joints, node's frame (no ride pose moves them)
	var _jr := Vector3.ZERO
	var _u := 1.0                     # node's units a metre, at the hero's size
	var _nleg := 0                    # vertices a leg bone moves most (an over-count of the flesh: the stride only thins a little more)
	var _segs := {}                   # each leg bone's segment in the first pose, node's frame: its joint to the next down the leg
	var _stride := 1
	var _seen := 0                    # leg flesh met so far, every surface in order (the stride counts it)
	var _patch := {}                  # "mesh/surface" -> [triangle starts round the joints, thigh-root vertices, leg samples, what all three read]
	var _want := {}                   # "mesh/surface" -> {vertex: true}: what the poses skin of it (_patch's fourth, as it is picked)
	var _ext := {}                    # "mesh/surface" -> the leg vertices that bound it: lowest, outermost, foremost, hindmost
	var _at := {}                     # the wanted vertices of the surface being read, in the pose being read: {vertex: where}
	var _under: Array = []            # each pose's lowest crossing between the legs
	var _thigh: Array = []            # each pose's thigh-root underside
	var _legs: Array = []             # each pose's leg points, node's frame
	var _blo := Vector3(INF, INF, INF)    # what the body draws (no leg bone carries it), node's frame
	var _bhi := -Vector3(INF, INF, INF)
	var _llo: Array = []              # ... and each pose's legs
	var _lhi: Array = []

	func _init(n: Node3D) -> void:
		node = n
		_skel = GPose.skeleton_of(n)
		if _skel == null:
			seat = {"ok": false}
			done = true
			return
		var kr := GRig._keyed(_skel, n)
		_res = kr[1]
		key = "rider:" + String(kr[0])
		var held = GPose._seat_get(_res, key)
		if held != null:
			seat = held
			done = true
			return
		GPose.seat_measures += 1
		_units.append(["pose"])

	func step(deadline: int) -> bool:
		if done:
			return true
		while _ui < _units.size():
			_unit(_units[_ui])
			_ui += 1
			if deadline >= 0 and Time.get_ticks_usec() > deadline:
				break
		if _ui < _units.size():
			return false
		done = true
		GPose._seat_put(_res, key, seat)
		_sf.clear()
		_patch.clear()
		_want.clear()
		_ext.clear()
		_at.clear()
		return true

	# A surface as _seat_surface reads it, and the bone that moves each of its vertices most ("dom": filled as it is skinned).
	func _surface(i: int, s: int) -> Dictionary:
		var kk := "%d/%d" % [i, s]
		if not _sf.has(kk):
			var d := GPose._seat_surface(_mis[i], s, node, _skel)
			var dom := PackedInt32Array()
			dom.resize((d["V"] as PackedVector3Array).size())
			dom.fill(-1)
			d["dom"] = dom
			_sf[kk] = d
		return _sf[kk]

	func _unit(u: Array) -> void:
		if not (seat.is_empty() or bool(seat.get("ok", false))):
			return   # no person of bones: nothing left to read
		match String(u[0]):
			"pose":
				_pose()
			"ride":
				_ride(int(u[1]))
			"skin":
				_skin(_surface(u[1], u[2]), int(u[3]))
			"segs":
				_segs_units()
			"tris":
				_tris("%d/%d" % [u[1], u[2]], _surface(u[1], u[2]), int(u[3]))
			"verts":
				_verts("%d/%d" % [u[1], u[2]], _surface(u[1], u[2]), int(u[3]))
			"seal":
				_seal("%d/%d" % [u[1], u[2]])
			"plan":
				_plan()
			"fit":
				_fit(int(u[1]), "%d/%d" % [u[2], u[3]], _surface(u[2], u[3]), int(u[4]))
			"cut":
				_cut(int(u[1]), "%d/%d" % [u[2], u[3]], _surface(u[2], u[3]), int(u[4]))
			"legs":
				_pose_legs(int(u[1]), "%d/%d" % [u[2], u[3]], _surface(u[2], u[3]), int(u[4]))
			"end":
				_end()

	# The map, the idle's first frame, the hero's size and the meshes — then a piece per ride pose and per piece of a surface.
	func _pose() -> void:
		var m := GRig.of(node)
		_hips = int(m.get("hips", -1))
		_tl = int((m.get("leg_l", {}) as Dictionary).get("thigh", -1))
		_tr = int((m.get("leg_r", {}) as Dictionary).get("thigh", -1))
		if not bool(m.get("person", false)) or String(m.get("kind", "")) != "bones" or _hips < 0 or _tl < 0 or _tr < 0:
			seat = {"ok": false}
			return
		var thighs: Array[int] = []
		var shins: Array[int] = []
		var uppers: Array[int] = []
		var fores: Array[int] = []
		for leg in [m["leg_l"], m["leg_r"]]:
			thighs.append(int(leg["thigh"]))
			if int(leg.get("shin", -1)) >= 0:
				shins.append(int(leg["shin"]))
		for side in ["l", "r"]:
			var arm: Dictionary = m.get("arm_" + side, {})
			if int(arm.get("upper", -1)) >= 0:
				uppers.append(int(arm["upper"]))
			if int(arm.get("fore", -1)) >= 0:
				fores.append(int(arm["fore"]))
		_limbs = [thighs, shins, uppers, fores]
		var kids := GRig._children(_skel)
		for t in thighs:
			for b in GRig._subtree(t, kids):
				_legset[int(b)] = true
		var rp := PackedVector3Array()
		var rr: Array[Quaternion] = []
		var rs := PackedVector3Array()
		for b in _skel.get_bone_count():
			var r := _skel.get_bone_rest(b)
			rp.append(r.origin)
			rr.append(r.basis.get_rotation_quaternion())
			rs.append(r.basis.get_scale())
		var ap := GPose._find_anim_player(node)
		var idle := GClip.resolve(ap, "idle") if ap != null else ""
		var an: Animation = ap.get_animation(idle) if idle != "" and ap.has_animation(idle) else null
		var tracks := GPose._bone_tracks(_skel, an, ap.get_node_or_null(ap.root_node)) if an != null else []
		_loc = GPose._pose_locals(an, tracks, rp, rr, rs, 0.0)
		_order = GPose._bone_order(_skel)
		_g0 = GPose._compose(_skel, _order, _loc[0], _loc[1], _loc[2])
		var sx := GPose.xf_to(_skel, node)
		var sb := sx.basis.orthonormalized()
		_axis = (sb.inverse() * Vector3.RIGHT).normalized()
		_fwd = (sb.inverse() * Vector3.BACK).normalized()
		# no ride pose moves the hip joints: they are where the idle's first frame has them
		_jl = sx * _g0[_tl].origin
		_jr = sx * _g0[_tr].origin
		# the size the hero is drawn at: PERSON_H tall as main._normalize_avatar_height measures it (GPose.char_height: the
		# bones and the meshes' boxes) — on this skeleton's own, so a held weapon or the player's placeholder capsule is not it
		var lo := INF
		var hi := -INF
		for b in _skel.get_bone_count():
			var by := (sx * _skel.get_bone_global_rest(b).origin).y
			lo = minf(lo, by)
			hi = maxf(hi, by)
		for mi: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
			if mi.mesh != null and GPose._skin_skeleton(mi) == _skel:
				_mis.append(mi)
				var mxf := GPose.xf_to(mi, node)
				var ab := mi.get_aabb()
				for c in 8:
					var cy := (mxf * (ab.position + ab.size * Vector3(c & 1, (c >> 1) & 1, (c >> 2) & 1))).y
					lo = minf(lo, cy)
					hi = maxf(hi, cy)
		GPose.seat_reads += 2 * _skel.get_bone_count()
		if _mis.is_empty() or hi <= lo:
			seat = {"ok": false}
			return
		_u = (hi - lo) / GRig.PERSON_H
		for f in GPose.RIDE_FITS.size():
			_units.append(["ride", f])
			_under.append(INF)
			_thigh.append(INF)
			_legs.append(PackedVector3Array())
			_llo.append(Vector3(INF, INF, INF))
			_lhi.append(-Vector3(INF, INF, INF))
		for i in _mis.size():
			var mesh: Mesh = (_mis[i] as MeshInstance3D).mesh
			for s in mesh.get_surface_count():
				for v0 in range(0, GPose._vert_count(mesh, s), GPose.SCAN_VERTS):
					_units.append(["skin", i, s, v0])
		_units.append(["segs"])

	# Ride pose `f`: ride()'s rotations (GPose._ride_rots, the same function) on the idle's first frame, composed.
	func _ride(f: int) -> void:
		var fv: Vector2 = GPose.RIDE_FITS[f]
		var rots := GPose._ride_rots(_skel, _g0, _axis, _fwd, _limbs[0], _limbs[1], _limbs[2], _limbs[3], fv.x, fv.y)
		var rot: Array[Quaternion] = (_loc[1] as Array).duplicate()
		for b in rots:
			rot[b] = (rots[b] as Basis).orthonormalized().get_rotation_quaternion()
		_G.append(GPose._compose(_skel, _order, _loc[0], rot, _loc[2]))
		GPose.seat_reads += _skel.get_bone_count()

	# Vertices v0 .. v0 + SCAN_VERTS of a surface in the first pose, and the bone that moves each most: what the body draws
	# (no leg bone moves it) and how many a leg moves.
	func _skin(d: Dictionary, v0: int) -> void:
		var V: PackedVector3Array = d["V"]
		var v1 := mini(v0 + GPose.SCAN_VERTS, V.size())
		GPose._seat_skin(d, _G[0], v0, GPose.SCAN_VERTS)
		var P: PackedVector3Array = d["P"]
		var dom: PackedInt32Array = d["dom"]
		var nk: int = d["nk"]
		var bones: PackedInt32Array = d["bones"]
		for vi in range(v0, v1):
			var bw := 0.0
			for q in nk:
				var w: float = d["W"][vi * nk + q]
				var bj: int = d["B"][vi * nk + q]
				if w > bw and bj < bones.size():
					bw = w
					dom[vi] = bones[bj]
			if _legset.has(dom[vi]):
				_nleg += 1
			else:
				_blo = _blo.min(P[vi])
				_bhi = _bhi.max(P[vi])
		d["dom"] = dom   # packed arrays are values: written back
		GPose.seat_reads += v1 - v0

	# Each leg bone's segment in the first pose and the samples' stride — then each surface's patch, picked a piece at a time.
	func _segs_units() -> void:
		var sx := GPose.xf_to(_skel, node)
		for b in _legset:
			var a: Vector3 = sx * (_G[0][b] as Transform3D).origin
			var e := Vector3.INF
			for c in _skel.get_bone_children(b):
				if _legset.has(c):
					e = sx * (_G[0][c] as Transform3D).origin
					break
			_segs[b] = [a, e]
		GPose.seat_reads += _legset.size()
		_stride = maxi(1, ceili(float(_nleg) / float(GPose.LEG_SAMPLES)))
		for kk in _sf:
			var d: Dictionary = _sf[kk]
			var ms: PackedStringArray = String(kk).split("/")
			_patch[kk] = [PackedInt32Array(), PackedInt32Array(), PackedInt32Array(), PackedInt32Array()]
			_want[kk] = {}
			_ext[kk] = {}
			for t0 in range(0, (d["I"] as PackedInt32Array).size(), 3 * GPose.SCAN_VERTS):
				_units.append(["tris", int(ms[0]), int(ms[1]), t0])
			for v0 in range(0, (d["V"] as PackedVector3Array).size(), GPose.SCAN_VERTS):
				_units.append(["verts", int(ms[0]), int(ms[1]), v0])
			_units.append(["seal", int(ms[0]), int(ms[1])])
		_units.append(["plan"])

	# Triangles t0 .. t0 + 3 * SCAN_VERTS of a surface: the ones round the hip joints, where a seat can be (a corner within
	# PATCH_R across, between RIDER_REACH under them and THIGH_ROOT over).
	func _tris(kk: String, d: Dictionary, t0: int) -> void:
		var j := (_jl + _jr) * 0.5
		var near := GPose.PATCH_R * _u
		var reach := GPose.RIDER_REACH * _u
		var root := GPose.THIGH_ROOT * _u
		var P: PackedVector3Array = d["P"]
		var I: PackedInt32Array = d["I"]
		var pa: Array = _patch[kk]
		var tris: PackedInt32Array = pa[0]
		var want: Dictionary = _want[kk]
		var t1 := mini(t0 + 3 * GPose.SCAN_VERTS, I.size() - 2)
		for t in range(t0, t1, 3):
			for q in 3:
				var p := P[I[t + q]]
				if Vector2(p.x - j.x, p.z - j.z).length() <= near and p.y <= j.y + root and p.y >= j.y - reach:
					tris.append(t)
					for c in 3:
						want[I[t + c]] = true
					break
		pa[0] = tris
		GPose.seat_reads += maxi(0, (t1 - t0 + 2) / 3)

	# Vertices v0 .. v0 + SCAN_VERTS of a surface: its thigh roots and the leg points the fit tests (every n-th leg vertex of
	# flesh, every surface in order, and the ones that bound each leg).
	func _verts(kk: String, d: Dictionary, v0: int) -> void:
		var j := (_jl + _jr) * 0.5
		var root := GPose.THIGH_ROOT * _u
		var flesh := GPose.LEG_FLESH * _u
		var toe := GPose.FOOT_REACH * _u
		var P: PackedVector3Array = d["P"]
		var dom: PackedInt32Array = d["dom"]
		var pa: Array = _patch[kk]
		var roots: PackedInt32Array = pa[1]
		var legs: PackedInt32Array = pa[2]
		var want: Dictionary = _want[kk]
		var ext: Dictionary = _ext[kk]
		var v1 := mini(v0 + GPose.SCAN_VERTS, P.size())
		for vi in range(v0, v1):
			var b := dom[vi]
			# a thigh root is read in each pose (_pose_legs): what the thigh carries within THIGH_ROOT of its joint THERE — the
			# flesh blended into the pelvis stretches as the thigh turns, and its nearness at the first pose said nothing of the
			# others' (a coat-wearer's seat 6 cm off at the widest)
			if (b == _tl and P[vi].distance_to(_jl) <= 2.0 * root) or (b == _tr and P[vi].distance_to(_jr) <= 2.0 * root):
				roots.append(vi)
				want[vi] = true
			if _legset.has(b) and _flesh(P[vi], _segs[b], flesh, toe):
				if _seen % _stride == 0:
					legs.append(vi)
					want[vi] = true
				_seen += 1
				var p := P[vi]
				for e in [["lo", -p.y], ["out", absf(p.x - j.x)], ["fore", p.z], ["hind", -p.z]]:
					if not ext.has(e[0]) or float(e[1]) > float(ext[e[0]][1]):
						ext[e[0]] = [vi, e[1]]
		pa[1] = roots
		pa[2] = legs
		GPose.seat_reads += v1 - v0

	# A surface picked: the leg vertices that bound it join its samples, and what the poses skin of it is listed.
	func _seal(kk: String) -> void:
		var pa: Array = _patch[kk]
		var legs: PackedInt32Array = pa[2]
		var want: Dictionary = _want[kk]
		for e in (_ext[kk] as Dictionary).values():
			if not legs.has(int(e[0])):
				legs.append(int(e[0]))
				want[int(e[0])] = true
		pa[2] = legs
		pa[3] = PackedInt32Array(want.keys())
		GPose.seat_reads += (_ext[kk] as Dictionary).size()

	# Every surface picked: a piece per pose and surface — its wanted vertices skinned, its patch cut, its roots and legs read.
	func _plan() -> void:
		for f in GPose.RIDE_FITS.size():
			for kk in _patch:
				var pa: Array = _patch[kk]
				var ms: PackedStringArray = String(kk).split("/")
				var i := int(ms[0])
				var s := int(ms[1])
				for k0 in range(0, (pa[3] as PackedInt32Array).size(), GPose.SCAN_VERTS):
					_units.append(["fit", f, i, s, k0])
				for t0 in range(0, (pa[0] as PackedInt32Array).size(), GPose.SCAN_VERTS):
					_units.append(["cut", f, i, s, t0])
				for r0 in range(0, (pa[1] as PackedInt32Array).size() + (pa[2] as PackedInt32Array).size(), GPose.SCAN_VERTS):
					_units.append(["legs", f, i, s, r0])
		_units.append(["end"])

	# Is `p` leg flesh: within `flesh` of its bone's segment `seg` ([joint, next joint down or INF]), or within `toe` of the
	# joint of a bone with nothing below it?
	func _flesh(p: Vector3, seg: Array, flesh: float, toe: float) -> bool:
		var a: Vector3 = seg[0]
		var e: Vector3 = seg[1]
		if not e.is_finite():
			return p.distance_to(a) <= toe
		var ab := e - a
		var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-12), 0.0, 1.0)
		return p.distance_to(a + ab * t) <= flesh

	# Wanted vertices k0 .. k0 + SCAN_VERTS of a surface skinned in pose f (its first piece starts the surface afresh).
	func _fit(f: int, kk: String, d: Dictionary, k0: int) -> void:
		if k0 == 0:
			_at = {}
		var want: PackedInt32Array = (_patch[kk] as Array)[3]
		var ids := want.slice(k0, k0 + GPose.SCAN_VERTS)
		_at.merge(GPose._seat_skin_ids(d, _G[f], Array(ids)))
		GPose.seat_reads += ids.size()

	# Patch triangles t0 .. t0 + SCAN_VERTS of a surface in pose f, cut by the seat's lines: the lowest crossing between the legs.
	func _cut(f: int, kk: String, d: Dictionary, t0: int) -> void:
		var tris: PackedInt32Array = (_patch[kk] as Array)[0]
		var I: PackedInt32Array = d["I"]
		var j := (_jl + _jr) * 0.5
		var gx := GPose.SEAT_FOOT.x * _u
		var gz := GPose.SEAT_FOOT.y * _u
		var low := j.y - GPose.RIDER_REACH * _u
		var k1 := mini(t0 + GPose.SCAN_VERTS, tris.size())
		for k in range(t0, k1):
			var t := tris[k]
			var a: Vector3 = _at[I[t]]
			var b: Vector3 = _at[I[t + 1]]
			var c: Vector3 = _at[I[t + 2]]
			if maxf(a.x, maxf(b.x, c.x)) < j.x - gx or minf(a.x, minf(b.x, c.x)) > j.x + gx:
				continue
			if maxf(a.z, maxf(b.z, c.z)) < j.z - gz or minf(a.z, minf(b.z, c.z)) > j.z + gz:
				continue
			for dx in [-1, 0, 1]:
				for dz in [-2, -1, 0, 1, 2]:
					var l := GPose._bary_xz(a, b, c, j.x + float(dx) * gx, j.z + float(dz) * gz * 0.5)
					if not l.is_finite() or l.x < -1e-6 or l.y < -1e-6 or l.z < -1e-6:
						continue
					var y := l.x * a.y + l.y * b.y + l.z * c.y
					if y <= j.y and y >= low:
						_under[f] = minf(float(_under[f]), y)
		GPose.seat_reads += k1 - t0

	# A surface's thigh roots and leg points r0 .. r0 + SCAN_VERTS (the roots, then the legs) in pose f: the roots' underside,
	# the leg points (and what those legs draw).
	func _pose_legs(f: int, kk: String, d: Dictionary, r0: int) -> void:
		var pa: Array = _patch[kk]
		var roots: PackedInt32Array = pa[1]
		var lv: PackedInt32Array = pa[2]
		var dom: PackedInt32Array = d["dom"]
		var root := GPose.THIGH_ROOT * _u
		var legs: PackedVector3Array = _legs[f]
		var r1 := mini(r0 + GPose.SCAN_VERTS, roots.size() + lv.size())
		for k in range(r0, r1):
			if k < roots.size():
				var q: Vector3 = _at[roots[k]]
				if q.distance_to(_jl if dom[roots[k]] == _tl else _jr) <= root:
					_thigh[f] = minf(float(_thigh[f]), q.y)
			else:
				var q: Vector3 = _at[lv[k - roots.size()]]
				legs.append(q)
				_llo[f] = (_llo[f] as Vector3).min(q)
				_lhi[f] = (_lhi[f] as Vector3).max(q)
		_legs[f] = legs
		GPose.seat_reads += r1 - r0

	func _end() -> void:
		var sx := GPose.xf_to(_skel, node).affine_inverse()
		var j := (_jl + _jr) * 0.5
		var ats: Array = []
		var legs: Array = []
		var boxes: Array = []
		for f in GPose.RIDE_FITS.size():
			var un: float = _under[f]
			var th: float = _thigh[f]
			var y := maxf(un, th) if is_finite(un) and is_finite(th) else (un if is_finite(un) else th)
			if not is_finite(y):
				seat = {"ok": false}
				return
			var sp := sx * Vector3(j.x, y, j.z)
			ats.append(((_G[f] as Array)[_hips] as Transform3D).affine_inverse() * sp)
			var lp := PackedVector3Array()
			for p in (_legs[f] as PackedVector3Array):
				lp.append(sx * p - sp)
			legs.append(lp)
			var lo: Vector3 = _blo.min(_llo[f])
			var hi: Vector3 = _bhi.max(_lhi[f])
			boxes.append(sx * AABB(lo, hi - lo))
		seat = {"ok": true, "id": key, "hips": _hips, "at": ats, "legs": legs, "boxes": boxes}


## A BODY OF PARTS SITS ASTRIDE BY ITS OWN SIT (decision S4): a person of parts — a Kenney figure, no skeleton for ride() to
## bend — plays its own "sit" clip, held on its first frame (the pose its artist made for a seat), and sits where that pose
## draws its seat (parts_seat). It stood on the saddle before, its feet 0.19 m inside the default horse's back. Same snapshot
## meta and stand() restore as ride(): stand() plays again what was playing (its idle, when nothing was). false: no person of
## parts, or no sit clip.
static func sit_parts(character: Node3D) -> bool:
	if character == null or not is_instance_valid(character):
		return false
	if character.has_meta(META):
		return true
	var m := GRig.of(character)
	var ap := _find_anim_player(character)
	if String(m.get("kind", "")) != "nodes" or not bool(m.get("person", false)) or ap == null:
		return false
	var clip := GClip.pick(ap.get_animation_list(), "sit")
	if clip == "":
		return false
	var was := String(ap.current_animation) if ap.is_playing() else GClip.resolve(ap, "idle")
	var pos := ap.current_animation_position if ap.is_playing() else 0.0
	ap.play(clip, 0.0)
	ap.seek(0.0, true)
	ap.pause()
	character.set_meta(META, {"skel": null, "bones": {}, "player": ap, "anim": was, "anim_pos": pos})
	return true


## WHERE A BODY OF PARTS SITS, in `character`'s frame (its transform excluded), in the pose it holds now (sit_parts'): measured
## as a person of bones is (RiderSeatJob) — the lowest point it draws between its legs within RIDER_REACH under their pivots,
## never below what its legs draw within THIGH_ROOT of them — at the hero's size. A Kenney figure sits on its legs' undersides,
## 0.12 m under their pivots. Once per model and clip, held by its first mesh. Vector3.INF: no person of parts.
static func parts_seat(character: Node3D) -> Vector3:
	var m := GRig.of(character)
	var ap := _find_anim_player(character)
	if String(m.get("kind", "")) != "nodes" or not bool(m.get("person", false)) or ap == null:
		return Vector3.INF
	var model := ap.get_node_or_null(ap.root_node) as Node3D
	if model == null:
		model = character
	var h := _seat_holder(model)
	# assigned_animation, not current_animation: sit_parts holds its clip paused, and a paused player's current_animation
	# reads "" — every held clip would share one entry.
	var key := "parts:%s|%s" % [h[0], String(ap.assigned_animation)]
	var held = _seat_get(h[1], key)
	if held == null:
		held = {"at": _parts_seat_now(model, m)}
		_seat_put(h[1], key, held)
	var at: Vector3 = held["at"]
	return xf_to(model, character) * at if at.is_finite() else Vector3.INF


static func _parts_seat_now(model: Node3D, m: Dictionary) -> Vector3:
	seat_measures += 1
	var legs: Array[Node3D] = []
	for side in ["leg_l", "leg_r"]:
		var lg := GRig.part(model, String((m.get(side, {}) as Dictionary).get("thigh", "")))
		if lg != null:
			legs.append(lg)
	if legs.size() < 2:
		return Vector3.INF
	var u := char_height(model) / GRig.PERSON_H
	var piv: Array[Vector3] = []
	for lg in legs:
		piv.append(xf_to(lg, model).origin)
	var j := (piv[0] + piv[1]) * 0.5
	var under := INF
	var thigh := INF
	for mi: MeshInstance3D in ([model] if model is MeshInstance3D else []) + model.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		var xf := xf_to(mi, model)
		var leg := -1
		for q in legs.size():
			if mi == legs[q] or legs[q].is_ancestor_of(mi):
				leg = q
		for s in mi.mesh.get_surface_count():
			var arr := surface_arrays(mi.mesh, s)
			var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var I = arr[Mesh.ARRAY_INDEX]
			var P := PackedVector3Array()
			for v in V:
				P.append(xf * v)
				if leg >= 0 and (xf * v).distance_to(piv[leg]) <= THIGH_ROOT * u:
					thigh = minf(thigh, (xf * v).y)
			var tri := PackedInt32Array(I) if I != null else PackedInt32Array(range(V.size()))
			for t in range(0, tri.size() - 2, 3):
				for dx in [-1, 0, 1]:
					for dz in [-2, -1, 0, 1, 2]:
						var l := _bary_xz(P[tri[t]], P[tri[t + 1]], P[tri[t + 2]], j.x + float(dx) * SEAT_FOOT.x * u, j.z + float(dz) * SEAT_FOOT.y * u * 0.5)
						if not l.is_finite() or l.x < -1e-6 or l.y < -1e-6 or l.z < -1e-6:
							continue
						var y := l.x * P[tri[t]].y + l.y * P[tri[t + 1]].y + l.z * P[tri[t + 2]].y
						if y <= j.y and y >= j.y - RIDER_REACH * u:
							under = minf(under, y)
	var y := maxf(under, thigh) if is_finite(under) and is_finite(thigh) else (under if is_finite(under) else thigh)
	return Vector3(j.x, y, j.z) if is_finite(y) else Vector3.INF
