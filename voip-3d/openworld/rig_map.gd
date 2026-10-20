class_name GRig extends RefCounted
## THE HUMANOID MAP — which bone is the hips, the spine, the chest, the neck and the head, and on each side the
## clavicle, upper arm, forearm and hand, the thigh, shin, foot and toe. Resolved ONCE per model and read by everything
## that asks what a body is: GPose's person verdict, seat datum and procedural poses (sit, ride, relax, walk, swim),
## GEquip's hand, interaction's seated-hip lift, AnimRig's retarget gate, the populate person test and the person sizing.
##
## WHY ONE MAP. Every consumer used to work the body out again from bone NAMES with a table of its own — a "thigh"
## substring in pose.gd taking the first two matches, an exact-name list in interaction.gd, a right-side score in
## equip.gd, exact KayKit names in anim_rig.gd — each right for the exporters its author had met. A Blender Rigify rig
## broke all of them at once (people rig RIGS): its "deform bones only" export is a FOREST (every limb its own root),
## its pelvis and head are DEF-spine and DEF-spine.006, its limbs are split X / X.001, so it stood as a creature in a
## 1.72 m box, its seat datum read 0 and buried it 0.34 m in a bench, sit folded both halves of ONE leg and relax never
## ran. Character Creator, 3ds Max Biped, VRoid and Daz held a weapon in the LEFT hand; Auto-Rig Pro, MakeHuman and
## anonymous rigs were creatures; the seated-NPC hip lift read 0 on every imported Mixamo rig ("mixamorig_Hips").
##
## HOW, PER SLOT, NAMES FIRST. A bone's name is read once (read_name: exporter prefixes and segment counters dropped,
## its side from side_of) into a slot word, and each limb is assigned along its own chain in order — clavicle before
## upper arm before forearm before hand — so an ambiguous word takes the first slot still open: Mixamo's "LeftShoulder"
## is a clavicle, Synty's "Shoulder_L" after "Clavicle_L" is the upper arm, MakeHuman's "upperarm01" after "shoulder01"
## is a second segment of it. STRUCTURE fills what names cannot and checks what they propose: a leg must reach the
## floor, the hips are where both thighs hang from (Rigify's DEF-spine, Auto-Rig Pro's root.x), the head tops the line
## up from the hips, and arms are found by their place in the hierarchy — the two multi-bone branches off the spine above
## the hips that are neither legs nor the head — never by how far a T-pose holds them out (an I-pose, an A-pose and an
## asymmetric rest keep every arm their names give). A rig that is not an upright two-legged body keeps today's name-token
## verdict exactly (_legacy), and so every creature keeps today's pickers.
##
## A FOREST IS REPAIRED ONCE, AT PARSE (Plan, Rebase): every weighted REAL root but the trunk's is re-parented to the
## bone whose joint it sits on, its rest recomputed so every global rest — and so the skin — is unchanged, and an
## animation's tracks on it rebased into its new parent's space. After that a Rigify forest is one tree and every pose,
## today's or a future one, carries its limbs the way it carries anyone's: nothing downstream needs to know forests
## exist.
##
## ONCE PER MODEL, A PIECE AT A TIME. The map is held by what every duplicate of a cached GLB shares and nothing else
## does — its first skin (a part rig's first mesh), as a Memo in the resource's meta (never a node or its meta) — so it
## goes when the model does: a static table kept every map of every GLB ever parsed (1074 maps of 358 freed models, 4.5 MB,
## step 2's review). Warm takes it when the GLB is parsed — AreaBuilder's drains and main._fetch_glb_scene work it inside
## the frame's budget, a piece at a time (a mesh surface, a join, a clip's key time) — so no NPC, enemy, hero, peer or
## crowd member resolves one where it is placed, and no frame pays a forest's repair whole (an animated Rigify forest took
## 11 ms with one clip and 239 with fifteen in one frame, the legacy face 0.5-11 s). A model nothing warmed (the 3d
## template, a chat edit) is resolved and rebased once, at its first copy's first use; every later copy re-parents its own
## skeleton and takes the clips that first copy rebased (_repair_copy).
##
## RIGID-PART HUMANOIDS ARE PEOPLE TOO. A Kenney blocky character has no Skeleton3D: its body is parts — nodes named
## head, torso, arm-left/right, leg-left/right — on node tracks. of() reads that hierarchy with the same names and the
## same structural checks, and a part stands in for a bone (kind "nodes": slots hold paths under the model).

const META_REPAIRED := "grig_repaired"   # on an Animation: its tracks were rebased into a repaired hierarchy
const META_MAP := "grig_map"             # on a model's first skin (a part rig's first mesh): {model key -> Memo}
const META_REBASED := "grig_rebased"     # on a library a model nothing warmed plays: {model key -> its rebased copy, or true}
const FLOOR_BAND := 0.12        # a foot ends within this fraction of the weighted height above the lowest weighted bone
const PERSON_TILT_DEG := 45.0   # hips -> head within this of vertical = it stands like a person (GPose.body_fit's rule)
const STEEP_DEG := 40.0         # a thigh found by structure points down within this of vertical
const WING_RATIO := 2.0         # "arms" reaching more than this many legs are wings: a flyer, not a person (the library's
                                # dragon 2.96 and bat 3.7; its people 0.4-1.36, bog_lurker the longest-armed)
const WEIGHT_SAMPLES := 4000    # vertices sampled per surface to learn which bones the skin uses
const ARM_MIN := 0.15           # an arm found by structure reaches at least this fraction of the weighted height
const JOIN_TIE := 0.01          # a forest root this close (x the weighted height) to two joints joins the one nearer the trunk
const SIDE_CLEAR := 0.02        # a limb's root joint this far (x the weighted height) across the midline is on that side
const NAMES_CAP := 4096         # read_name's memo starts over past this many raw names (the library's 138 models hold ~600)
# THE LEGS (legs()): a bone's skin within FOOT_TOUCH of the drawn height over the lowest vertex touches the floor; an IK rig's
# lower leg points at its foot within LEG_AIM_DEG (Quaternius: 0.7-4.9 deg at rest, hoof-crest); a leg runs from its top down
# to its foot within LEG_SLANT_DEG of vertical (the spider's splay 43-64) and is at least LEG_MIN of the weighted height long.
const FOOT_TOUCH := 0.06
const LEG_AIM_DEG := 30.0
const LEG_SLANT_DEG := 70.0
const LEG_MIN := 0.2
const NOT_LEGS := ["tail", "fin", "flipper", "wing"]   # a limb that reaches the floor named so is never a leg
# THE SEAT DATUM OF HIPS FOUND BY STRUCTURE (decision D6). A pelvis-named bone's origin is the datum every seat in the
# library was calibrated on, and it stays — the first one over the floor, wherever it hangs, as GPose.hips_height read it
# (Quaternius' platformer Character names "Hips" a bone its thighs do not hang from: seated by structure it moved 0.36 ->
# 0.46 of its units, step 2's review). A rig whose hips no name gives (Rigify's DEF-spine sits at the pelvis BASE,
# Auto-Rig Pro's root.x, an anonymous rig) is seated at its hip joints (the thighs' origins) plus this fraction of their
# height above the floor — the library's realistic people, measured (the Kestrel cast and realistic_characters, 19
# rigs): their Hips origin stands 0.086-0.121 of the hip joints' height above them, median 0.117 (villager_man 0.093 m
# over 0.795) — so a Rigify body sits like its Meshy twin. (KayKit's hips sit 0.23 of it BELOW its joints, the
# Quaternius superheroes' 0.02: a seat datum is a bone-origin convention, and the drawn datum is a later item.)
const HIP_OVER_JOINTS := 0.117
# THE HERO'S HEIGHT: PERSON_H (main.HERO_HEIGHT). The hero is normalised to it (main._normalize_avatar_height: its camera,
# its capsule, a remote peer's hit capsule are built to it), and a person in any other role who is drawn outside a person's
# height stands it too, by the same measure (GPose.char_height) — GBody.normalise, the one size rule: a named Kenney NPC
# stood 2.73 m and a KayKit chibi 2.17-2.66 beside the 1.65 m hero. One drawn as a person is (1.50-1.95 m) keeps its own
# height in every role but the hero's (the user, 2026-10-04): villager_man stands 1.807 m in the street.
const PERSON_H := 1.65

static var measures := 0        # cold resolutions (the people rig reads it: once per model, never per instance)
static var join_evals := 0      # joint measurements the forest repair took (the people rig bounds them: RIGS (g1))
static var interps := 0         # track samples the rebase took (the people rig bounds them a piece: RIGS (k))
static var rebased := 0         # clips rebased: once per model, at its warm or a cold model's first copy (RIGS (f))
static var memo_live := 0       # maps alive, each a Memo its model holds (the people rig counts them: RIGS (l))
static var warm_steps := 0      # Warm.step calls: a frame's slice each (the people rig counts a hero fetch's: RIGS (k))
static var surface_reads := 0   # skinned surfaces the resolve read the bones of: one a piece (the people rig counts them: RIGS (k1b))
static var leg_samples := 0     # skin samples read for a creature's legs (Weighted.sample: none for a person), and the
static var sole_influences := 0 # influences read back for their soles (Weighted.influences) — the people rig's RIGS (c2)
static var _names := {}         # raw bone name -> read_name()
static var _said := {}          # "role what" -> true: GOGI_RIG_UNRESOLVED said once a world (forget_said)

# ------------------------------------------------------------------------------------------------------------- the API

## THE MAP of `model` — its richest skeleton's, or, with none, its rigid parts' — in `model`'s own frame (+Y up, facing +Z).
## {person, pelvis, tilt, source: names|structure|legacy, kind: bones|nodes, hips, spine[], chest, neck, head,
##  arm_l/arm_r {clavicle, upper, fore, hand}, leg_l/leg_r {thigh, shin, foot, toe}, seat_bone (the pelvis-named bone a
##  seat holds, -1 none), floor_limbs, body: person|walker|flyer|glider|unknown, repair, legs (legs())}. A slot nothing fills
##  is -1 (a path "" on a part rig). Empty for a model with no skeleton and no humanoid parts.
static func of(model: Node) -> Dictionary:
	if model == null:
		return {}
	var sk := GPose.skeleton_of(model)
	if sk != null and sk.get_bone_count() > 0:
		return map(sk, model as Node3D)
	return _nodes_map(model as Node3D)


## The map of `skel`, read in `top`'s frame. `top` is REQUIRED — the model root whose meshes say which bones the skin
## uses and whose frame is up: a Meshy armature turns its bones 90 degrees, and the first caller's frame used to decide
## "up" for everyone (review). Held by the model (its first skin: Memo); a copy whose forest nothing repaired is repaired
## here (_repair_copy).
static func map(skel: Skeleton3D, top: Node3D) -> Dictionary:
	if skel == null or top == null:
		return {}
	var kr := _keyed(skel, top)
	var m = _memo_get(kr[1], kr[0])
	if m == null:
		m = _resolve(skel, top)
		_memo_put(kr[1], kr[0], m)
	if not (m["repair"] as Array).is_empty():
		_repair_copy(skel, top, m["repair"], kr[0])
	return m


## Repair `scene`'s forest and take its map, whole and now (a test, a caller with no frames to spread it over): Warm,
## worked to its end. The parse paths work a Warm a piece at a time instead. Returns the map.
static func warm(scene: Node) -> Dictionary:
	var w := Warm.new(scene)
	while not w.step(1 << 62):
		pass
	return w.map


## Is `model` a person (a humanoid rig of bones or of parts)?
static func person(model: Node) -> bool:
	return bool(of(model).get("person", false))


## The hand bone of `side` ("l" / "r") `model`'s weapon is held in, or -1: a person's map's hand — -1 when its arm has none
## (hand_end says where it is then), and for a creature (its claw is GEquip's name scoring).
static func hand(model: Node, side := "r") -> int:
	var m := of(model)
	if not bool(m.get("person", false)) or String(m.get("kind", "")) != "bones":
		return -1
	return int((m.get("arm_" + side, {}) as Dictionary).get("hand", -1))


## WHERE A HAND WITH NO HAND BONE IS: {bone, at} — the end of what a person's forearm draws, in that bone's rest frame,
## for an arm whose map ends at its forearm (Quaternius' monster skeleton names its arms UpperLeg_001 / DownLeg_001 and
## has no hand: the weapon was hung at the forearm bone's ORIGIN, the elbow, 0.78 of its units — 14% of its height —
## from the end of its arm, step 2's review). The end is the rest vertex the forearm and what hangs from it move most
## that lies farthest from the shoulder (the upper arm's origin). {} when the arm has a hand bone (hand()), no forearm,
## or `model` is no person of bones. Once per model: kept in its map.
static func hand_end(model: Node, side := "r") -> Dictionary:
	var m := of(model)
	if not bool(m.get("person", false)) or String(m.get("kind", "")) != "bones":
		return {}
	var arm: Dictionary = m.get("arm_" + side, {})
	var fore := int(arm.get("fore", -1))
	var up := int(arm.get("upper", -1))
	if int(arm.get("hand", -1)) >= 0 or fore < 0 or up < 0:
		return {}
	var k := "hand_end_" + side
	if m.has(k):
		return m[k]
	var sk := GPose.skeleton_of(model)
	var sub := {}
	for b in _subtree(fore, _children(sk)):
		sub[b] = true
	var sp := sk.get_bone_global_rest(up).origin
	var far := sk.get_bone_global_rest(fore).origin
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null or mi.skin == null or mi.skeleton.is_empty() or mi.get_node_or_null(mi.skeleton) != sk:
			continue
		for s in mi.mesh.get_surface_count():
			var arr := GPose.surface_arrays(mi.mesh, s)
			if arr.size() <= Mesh.ARRAY_WEIGHTS or arr[Mesh.ARRAY_BONES] == null or arr[Mesh.ARRAY_WEIGHTS] == null:
				continue
			var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var B: PackedInt32Array = arr[Mesh.ARRAY_BONES]
			var Wt: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
			var kk := int(B.size() / maxi(1, V.size()))
			for i in V.size():
				var dom := -1
				var dw := 0.0
				for j in kk:
					if Wt[i * kk + j] > dw:
						dw = Wt[i * kk + j]
						dom = B[i * kk + j]
				if dom < 0 or dom >= mi.skin.get_bind_count():
					continue
				var bi := mi.skin.get_bind_bone(dom)
				if bi < 0:
					bi = sk.find_bone(String(mi.skin.get_bind_name(dom)))
				if not sub.has(bi):
					continue
				var p := sk.get_bone_global_rest(bi) * mi.skin.get_bind_pose(dom) * V[i]
				if p.distance_to(sp) > far.distance_to(sp):
					far = p
	m[k] = {"bone": fore, "at": sk.get_bone_global_rest(fore).affine_inverse() * far}
	return m[k]


## THE HEAD of `model` and all it carries — a face, a jaw, horns, a tongue: the subtree of the head bone its map gives (a
## creature's too, from the map's tokens). What no saddle is ever put on (GPose.MountSeatJob, rule (b)): the top of the
## default dragon on its saddle point's line was its head. Empty when the map gives no head.
static func head_bones(model: Node) -> PackedInt32Array:
	var out := PackedInt32Array()
	var hd = of(model).get("head", -1)
	var sk := GPose.skeleton_of(model)
	if sk == null or not (hd is int) or int(hd) < 0 or int(hd) >= sk.get_bone_count():
		return out
	for b in _subtree(int(hd), _children(sk)):
		out.append(int(b))
	return out


## The hips bone of `model` (-1: none, or not a person).
static func hips(model: Node) -> int:
	var m := of(model)
	return int(m.get("hips", -1)) if bool(m.get("person", false)) else -1


## THE LEGS `model` STANDS ON, read once per model with its map (_legs), in the hierarchy its skeleton has at runtime:
## [{foot, lower, upper, chain, soles, on, len}] — `foot` the bone that carries what touches the floor (a Quaternius hoof is
## the IK target hanging from the root at the end of its leg: `chain` false; elsewhere the end of a foot <- lower <- upper
## chain), `soles` up to nine vertices of its underside (the extremes of its lowest quarter eight ways and the one nearest
## the middle of its lowest layer) as the skin draws them (_soles), `on` the bone that carries them most: the foot, or its
## lower leg where the foot carries no skin of its own (the Rig Lab dragon's, the llama's right hind hoof), `len` the leg's
## rest length, upper to lower to foot, in the model's units. What GFeet
## plants on the ground (feet.gd) and what a creature's lean stands on (GBody.stance). Empty: no legs (a snake, a fish, a
## slime), no skeleton.
static func legs(model: Node) -> Array:
	return of(model).get("legs", [])


## THE SEAT DATUM of a person `m` maps, in `node`'s frame from `skel`'s pose `glob` (bone index -> skeleton-space
## global; the rest when empty) — where a seat puts their hips (decision D6): a pelvis-named bone's origin (seat_bone, the
## first over the floor: the bone GPose.hips_height always read), the datum every seat in the library was calibrated on;
## with none, hips found by structure, at the hip joints plus HIP_OVER_JOINTS of their height over the lowest bone. null
## when `m` is no bone person.
static func seat_point(skel: Skeleton3D, node: Node, m: Dictionary, posed := false) -> Variant:
	if not bool(m.get("person", false)) or String(m.get("kind", "")) != "bones":
		return null
	var hips := int(m.get("hips", -1))
	var tl := int((m.get("leg_l", {}) as Dictionary).get("thigh", -1))
	var tr := int((m.get("leg_r", {}) as Dictionary).get("thigh", -1))
	if hips < 0:
		return null
	var sxf := GPose.xf_to(skel, node)
	var at := func(b: int) -> Vector3: return sxf * (skel.get_bone_global_pose(b) if posed else skel.get_bone_global_rest(b)).origin
	var sb := int(m.get("seat_bone", -1))
	if sb >= 0:
		return at.call(sb)
	if tl < 0 or tr < 0:
		return at.call(hips)
	var lo := INF
	for i in skel.get_bone_count():
		lo = minf(lo, (sxf * skel.get_bone_global_rest(i).origin).y)
	var j: Vector3 = (at.call(tl) + at.call(tr)) * 0.5
	# posed: the joints carry the pelvis with them; the offset turns with the hips bone
	var up := Vector3.UP
	if posed:
		var hb := (sxf.basis * skel.get_bone_global_pose(hips).basis).orthonormalized()
		var rb := (sxf.basis * skel.get_bone_global_rest(hips).basis).orthonormalized()
		up = (hb * rb.inverse()) * Vector3.UP
	var jr: Vector3 = ((sxf * skel.get_bone_global_rest(tl).origin) + (sxf * skel.get_bone_global_rest(tr).origin)) * 0.5
	return j + up * (HIP_OVER_JOINTS * (jr.y - lo))


## The CORE SLOTS of a person's map — hips, the spine up to the chest, head, both thighs, shins, upper arms and
## forearms — as bone indices. AnimRig retargets a clip only when it drives every one (a 3-track "root" clip on a
## Quaternius superhero drove none and was played as if it animated the body). Empty when not a person or a slot is
## missing: nothing can be held to drive what the map does not have.
static func core_slots(m: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	if not bool(m.get("person", false)) or String(m.get("kind", "")) != "bones":
		return out
	out.append(int(m.get("hips", -1)))
	out.append(int(m.get("chest", -1)))
	out.append(int(m.get("head", -1)))
	for s in ["l", "r"]:
		var leg: Dictionary = m.get("leg_" + s, {})
		var arm: Dictionary = m.get("arm_" + s, {})
		out.append(int(leg.get("thigh", -1)))
		out.append(int(leg.get("shin", -1)))
		out.append(int(arm.get("upper", -1)))
		out.append(int(arm.get("fore", -1)))
	for b in out:
		if b < 0:
			return PackedInt32Array()
	return out


## A character-role model nothing can animate: not a person, with limbs that reach the floor, none of them named as a
## leg the creature pickers know, and no clip for `role` — it slides across the ground rigid. The spawners print
## GOGI_RIG_UNRESOLVED for it (verify.mjs WARNs). "" = resolved, else why.
static func unresolved(m: Dictionary, ap: AnimationPlayer, role := "walk") -> String:
	if m.is_empty() or bool(m.get("person", false)) or String(m.get("kind", "")) != "bones":
		return ""
	if int(m.get("floor_limbs", 0)) < 1 or bool(m.get("named_legs", false)):
		return ""
	if GClip.resolve(ap, role) != "":
		return ""
	return "%d limb(s) reach the floor, none named as a leg, no \"%s\" clip: neither a person nor a creature anything can move" % [
		int(m.get("floor_limbs", 0)), role]


## Say a rig `unresolved` gave a reason for, ONCE per role and model in a world: GOGI_RIG_UNRESOLVED <role> <what> <why>
## (verify.mjs WARNs it). `why` "" says nothing.
static func say_unresolved(role: String, what: String, why: String) -> void:
	if why == "" or _said.has(role + " " + what):
		return
	_said[role + " " + what] = true
	print("GOGI_RIG_UNRESOLVED %s %s %s" % [role, what.replace(" ", "%20"), why])


## A world is over (its AreaBuilder freed: main._switch_world reloads the scene): the next one says its rigs again — a
## second game in the same process never said a model the first had (step 2's review).
static func forget_said() -> void:
	_said.clear()

# ------------------------------------------------------------------------------------------------------------- names

## A bone (or part) name READ FOR THE MAP: {slot, side ("L" / "R" / ""), core (the slot word as spelled), seg (a split
## limb's segment counter, -1 none), skip (a helper: twist, roll, IK, pole, end marker, slot, control)}. One table for
## every exporter this stack has met: Mixamo / Meshy, KayKit, Rigify (DEF- / ORG- / MCH-, X / X.001), Auto-Rig Pro,
## Unreal, Daz, MakeHuman, Synty, Character Creator, 3ds Max Biped, VRoid, Kenney's parts.
static func read_name(raw: String) -> Dictionary:
	if _names.has(raw):
		return _names[raw]
	var base := raw
	for sep in [":", "|", "/"]:
		var k := base.rfind(sep)
		if k >= 0:
			base = base.substr(k + 1)
	var side := side_of(base)
	var t := base
	var again := true
	while again:
		again = false
		var low := t.to_lower()
		var us := low.find("_")
		if low.begins_with("mixamorig") and us >= 9 and (us == 9 or low.substr(9, us - 9).is_valid_int()):
			t = t.substr(us + 1)
			again = true
			continue
		var sp := low.find(" ")
		if low.begins_with("bip") and sp > 3 and low.substr(3, sp - 3).is_valid_int():
			t = t.substr(sp + 1)
			again = true
			continue
		for p in PREFIXES:
			if low.begins_with(p) and low.length() > String(p).length():
				t = t.substr(String(p).length())
				again = true
				break
	var skip := false
	for p in HELPER_PREFIXES:
		if t.to_lower().begins_with(p):
			skip = true
	var toks := _tokens(t)
	var words := PackedStringArray()
	var seg := -1
	for i in toks.size():
		var w := toks[i]
		if w.is_valid_int():
			seg = int(w)
			continue
		if w in SIDE_WORDS or ((w == "l" or w == "r") and toks.size() > 1):
			continue
		if w in SKIP_WORDS:
			skip = true
			continue
		for s in SKIP_PARTS:
			if String(s) in w:
				skip = true
		words.append(w)
	var core := "".join(words)
	var slots: Array = CORES.get(core, [])
	var out := {"slot": String(slots[0]) if not slots.is_empty() else "", "slots": slots, "side": side, "core": core,
		"seg": seg, "skip": skip}
	if _names.size() >= NAMES_CAP:
		_names.clear()
	_names[raw] = out
	return out


## A side from a bone name, or "": ".L" / "_l" / "-l" / " l" suffixes (Rigify, KayKit, UE, ARP, MakeHuman, Synty),
## "Left" / "Right" (Mixamo, Meshy, Kenney's "arm-left"), "L_" / "l." prefixes (Quaternius), "_L_" / " L " infixes (VRoid,
## CC, 3ds Max Biped) and Daz's camel case ("lThighBend"). A centre bone (".x", "spine_01") has none.
static func side_of(raw: String) -> String:
	var base := raw
	for sep in [":", "|", "/"]:
		var k := base.rfind(sep)
		if k >= 0:
			base = base.substr(k + 1)
	var t := base.to_lower()
	# segment / duplicate counters go first, so "DEF-thigh.L.001" and "upperarm_twist_01_l" read their side
	var again := true
	while again:
		again = false
		for sep in [".", "_", "-"]:
			var k := t.rfind(sep)
			if k > 0 and k < t.length() - 1 and t.substr(k + 1).is_valid_int():
				t = t.substr(0, k)
				again = true
	for s in [["l", "L"], ["r", "R"]]:
		var a: String = s[0]
		for suf in ["." + a, "_" + a, "-" + a, " " + a]:
			if t.ends_with(suf):
				return s[1]
		for inf in ["_" + a + "_", " " + a + " ", "." + a + "."]:
			if inf in t:
				return s[1]
		for pre in [a + "_", a + "."]:
			if t.begins_with(pre):
				return s[1]
	if "left" in t:
		return "L"
	if "right" in t:
		return "R"
	if base.length() > 1 and (base[0] == "l" or base[0] == "r") and base[1] != base[1].to_lower():
		return "L" if base[0] == "l" else "R"
	return ""


# Exporter prefixes a slot word sits behind (read_name drops them, repeatedly: "DEF-" then nothing; "CC_Base_L_").
const PREFIXES := ["def-", "def_", "cc_base_", "j_bip_", "b_", "valvebiped."]
# ...and the prefixes of bones that are never the body: a Rigify control rig's ORG- / MCH- copies, VRoid's secondary
# (hair, skirt) and adjustment bones.
const HELPER_PREFIXES := ["org-", "org_", "mch-", "mch_", "j_sec_", "j_adj_"]
const SIDE_WORDS := ["left", "right", "x", "c"]
# A word that makes a bone a HELPER, never a body slot (an IK target, a twist or roll corrector, an end marker, a slot
# a weapon hangs on, a control) — and the substrings that do ("handslot", "thightwist", "upperarm_twist").
const SKIP_WORDS := ["ik", "pole", "end", "nub", "tip", "null", "target", "ctrl", "con", "helper", "jiggle", "dyn",
	"corrective", "socket", "fk", "mch", "org", "tweak", "parent", "pivot", "root", "ref"]
const SKIP_PARTS := ["twist", "roll", "slot", "ctrl", "control", "corrective"]
# THE SLOT WORDS: a core (a name's words joined, side and counters gone) -> the slots it may be, in the order a limb's
# chain tries them. "shoulder" is Mixamo's clavicle and Synty's upper arm; "leg" Mixamo's shin and Kenney's whole leg;
# "fist" and "claw" the hand GEquip's score always knew (Quaternius' platformer Character grips in Fist.R: without the
# word its weapon went to the forearm bone, the elbow — step 2's review).
const CORES := {
	"hips": ["hips"], "hip": ["hips"], "pelvis": ["hips"],
	"spine": ["spine"], "abdomen": ["spine"], "abdomenlower": ["spine"], "abdomenupper": ["spine"], "torso": ["spine"],
	"waist": ["spine"], "chest": ["chest"], "upperchest": ["chest"], "chestlower": ["chest"], "chestupper": ["chest"],
	"ribcage": ["chest"], "neck": ["neck"], "necklower": ["neck"], "neckupper": ["neck"], "head": ["head"],
	"clavicle": ["clavicle"], "collar": ["clavicle"], "collarbone": ["clavicle"], "shoulder": ["clavicle", "upper"],
	"upperarm": ["upper"], "uparm": ["upper"], "arm": ["upper"], "shldr": ["upper"], "shldrbend": ["upper"],
	"armstretch": ["upper"], "forearm": ["fore"], "lowerarm": ["fore"], "elbow": ["fore"], "forearmbend": ["fore"],
	"forearmstretch": ["fore"], "hand": ["hand"], "wrist": ["hand"], "palm": ["hand"], "fist": ["hand"], "claw": ["hand"],
	"thigh": ["thigh"], "upleg": ["thigh"], "upperleg": ["thigh"], "thighbend": ["thigh"], "thighstretch": ["thigh"],
	"leg": ["thigh", "shin"], "shin": ["shin"], "calf": ["shin"], "lowerleg": ["shin"], "downleg": ["shin"], "knee": ["shin"],
	"shinbend": ["shin"], "legstretch": ["shin"], "foot": ["foot"], "feet": ["foot"], "ankle": ["foot"], "toe": ["toe"], "toes": ["toe"],
	"toebase": ["toe"], "ball": ["toe"],
}
const ARM_SLOTS := ["clavicle", "upper", "fore", "hand"]
const LEG_SLOTS := ["thigh", "shin", "foot", "toe"]


# A name's words: camelCase and letter/digit runs split ("LeftUpLeg" -> left up leg, "Spine1" -> spine 1, "toe1-1" ->
# toe 1 1), lowercased; . _ - and spaces separate.
static func _tokens(s: String) -> PackedStringArray:
	var out := ""
	for i in s.length():
		var ch := s[i]
		if i > 0:
			var pv := s[i - 1]
			var up := ch != ch.to_lower()
			var dig := "0123456789".contains(ch)
			var pdig := "0123456789".contains(pv)
			if (up and pv != pv.to_upper()) or (dig and not pdig and pv != "_" and pv != "." and pv != "-" and pv != " ") \
					or (not dig and pdig and ch != "_" and ch != "." and ch != "-" and ch != " "):
				out += "_"
		out += ch
	return out.to_lower().replace("-", "_").replace(".", "_").replace(" ", "_").split("_", false)


# ----------------------------------------------------------------------------------------------------------- resolve

## THE RESOLVE, A PIECE AT A TIME (step(): one piece; true when `out` is the map): the bones read; the skin's use of them,
## a mesh surface a piece (Weighted); the forest's repair plan, a root's first measure or one join a piece (Plan); then
## the verdict in one (_verdict); and a creature's legs: its skin's samples a surface a piece (Weighted.sample), the map in
## one (_legs). _resolve works it whole; Warm a piece at a time inside a frame's budget — the legacy Rigify face's plan was
## 39 ms in one frame (11 359 joint measurements), beside a 1.9 ms mesh read and a 0.5 ms verdict.
class Resolve extends RefCounted:
	var out := {}
	var n := 0
	var P := PackedVector3Array()     # the bones' rest origins in the model's frame
	var Y := PackedVector3Array()     # ...and their +Y axes
	var R: Array[Transform3D] = []    # ...and their whole rests there (the frame a foot's soles are kept in)
	var par := PackedInt32Array()
	var names := PackedStringArray()
	var SKIN := PackedByteArray()     # the bones the skin uses (Weighted)
	var TOP := PackedFloat32Array()   # ...and how high each one's flesh goes
	var info: Array = []              # read_name of each bone
	var W := PackedByteArray()        # the body's bones: the skin's, and every bone named as a body part that is no helper
	var lo := INF
	var H := 0.0
	var plan: Array = []
	var _wt: GRig.Weighted = null
	var _pl: GRig.Plan = null
	var _stage := 0

	func _init(skel: Skeleton3D, top: Node3D) -> void:
		GRig.measures += 1
		n = skel.get_bone_count()
		var M := GPose.xf_to(skel, top)
		P.resize(n)
		Y.resize(n)
		R.resize(n)
		par.resize(n)
		names.resize(n)
		for i in n:
			var g := skel.get_bone_global_rest(i)
			R[i] = M * g
			P[i] = R[i].origin
			Y[i] = (M.basis * g.basis.y).normalized()
			par[i] = skel.get_bone_parent(i)
			names[i] = skel.get_bone_name(i)
		out = GRig._legacy(names, P)
		out.merge({"kind": "bones", "n": n, "source": "legacy", "repair": [], "body": "unknown", "floor_limbs": 0,
			"named_legs": false, "spine": [], "chest": -1, "neck": -1, "lean": -1, "hips_named": false, "head_named": false,
			"seat_bone": -1, "legs": []})
		if n == 0:
			_stage = 5
			return
		_wt = GRig.Weighted.new(skel, top, M, n)

	func step() -> bool:
		match _stage:
			0:   # the skin, a surface a piece; then the body's bones and their height
				if not _wt.step():
					return false
				SKIN = _wt.used
				TOP = _wt.top
				for i in n:
					TOP[i] = maxf(TOP[i], P[i].y)
				for i in n:
					info.append(GRig.read_name(names[i]))
				# THE BODY'S BONES: what the skin uses, and every bone named as a body part that is no helper. A kit piece
				# skins one part of a whole skeleton (an outfit's legs, its sleeves) and every piece of a character must pose
				# alike, so a hand its sleeve does not cover is still the hand; a control rig's ORG- / MCH- / IK / tweak bones
				# never are.
				W = SKIN.duplicate()
				for i in n:
					var r: Dictionary = info[i]
					if r["slot"] != "" and not r["skip"]:
						W[i] = 1
				var hi := -INF
				for i in n:
					if W[i] == 1:
						lo = minf(lo, P[i].y)
						hi = maxf(hi, P[i].y)
				if not (hi > lo):
					_wt = null
					_stage = 5
					return true
				H = hi - lo
				# ---- THE FOREST: the skin's orphan roots joined where their joint sits (repair; applied to a person only)
				_pl = GRig.Plan.new(names, par, P, Y, SKIN, H)
				_stage = 1
				return false
			1:   # the plan, a measure or a join a piece
				if not _pl.step():
					return false
				plan = _pl.plan
				_pl = null
				_stage = 2
				return false
			2:
				GRig._verdict(self)
				_stage = 3
				if bool(out.get("person", false)):
					# A PERSON HAS NO LEGS TO PLANT: GRig.legs is what a mount's feet stand on (GFeet) and a creature leans
					# on (GBody.stance), and a person stands upright. Read for every rigged model, its skin's samples and
					# their influences took the warm over the rigs' 297 GLBs from 712 to 1677 ms, a hero's surface 2.6 ->
					# 4.8 ms (step 5c's review).
					_wt = null
					_stage = 5
				return false
			3:   # a creature's legs: its skin's samples, a surface a piece ...
				if _wt.sample():
					_stage = 4
				return false
			4:   # ...then the legs it stands on, in the hierarchy the verdict leaves it
				out["legs"] = GRig._legs(self)
				_wt = null
				_stage = 5
		return true


static func _resolve(skel: Skeleton3D, top: Node3D) -> Dictionary:
	var r := Resolve.new(skel, top)
	while not r.step():
		pass
	return r.out


# THE VERDICT on what Resolve read: the repaired hierarchy's floor census, the legs, hips, head, spine and arms — names
# first per slot, structure where they miss — and whether that is a person. Fills rs.out.
static func _verdict(rs: Resolve) -> void:
	var n := rs.n
	var P := rs.P
	var Y := rs.Y
	var par := rs.par
	var names := rs.names
	var TOP := rs.TOP
	var info := rs.info
	var W := rs.W
	var lo := rs.lo
	var H := rs.H
	var plan := rs.plan
	var out := rs.out
	var pr := par.duplicate()
	for e in plan:
		pr[int(e[0])] = int(e[1])
	var kids := {}
	for i in n:
		if pr[i] >= 0:
			if not kids.has(pr[i]):
				kids[pr[i]] = []
			(kids[pr[i]] as Array).append(i)
	var depth := PackedInt32Array()
	depth.resize(n)
	for i in n:
		var d := 0
		var a := pr[i]
		while a >= 0 and d <= n:
			d += 1
			a = pr[a]
		depth[i] = d
	var band := lo + FLOOR_BAND * H
	# ---- creature or person: what reaches the floor (the structural census every verdict reads)
	var feet := _floor_groups(n, W, pr, kids, P, band)
	out["floor_limbs"] = feet.size()
	out["named_legs"] = _legacy_thighs(names)
	# ---- THE LEGS: names first, each side's chain checked to reach the floor
	var legs := {}
	var leg_ok := func(ch: Dictionary) -> bool: return int(ch.get("thigh", -1)) >= 0 and _reaches(int(ch["thigh"]), kids, P, W, band)
	for s in ["L", "R"]:
		var c := _named_chain(s, LEG_SLOTS, info, W, pr, kids, depth, leg_ok)
		if not c.is_empty():
			legs[s] = c
	var legs_by := "names"
	if legs.size() < 2:
		var sl := _structural_legs(feet, n, W, pr, kids, P, Y, H, band)
		if sl.is_empty():
			_creature(out, feet, info, W, pr, kids, P, H)
			return
		legs = sl
		legs_by = "structure"
	var tl: int = legs["L"]["thigh"]
	var tr: int = legs["R"]["thigh"]
	# ---- THE HIPS: a centre pelvis-named bone both thighs hang from (the first, as today's seat datum read it); else
	# where they meet (structure)
	var hips := -1
	for i in n:
		var r: Dictionary = info[i]
		if r["slot"] == "hips" and r["side"] == "" and not r["skip"] and _is_anc(i, tl, pr) and _is_anc(i, tr, pr):
			hips = i
			break
	var hips_named := hips >= 0
	if hips < 0:
		hips = _lca(tl, tr, pr)
	if hips < 0:
		_creature(out, feet, info, W, pr, kids, P, H)
		return
	var legset := {}
	for s in legs:
		for b in _subtree(int(legs[s]["thigh"]), kids):
			legset[b] = true
	# ---- THE HEAD: a centre head-named bone above the hips, outside the legs; else the top of the line up from them
	var head := -1
	var head_named := false
	for i in n:
		var r: Dictionary = info[i]
		if r["slot"] == "head" and r["side"] == "" and not r["skip"] and _is_anc(hips, i, pr) and not legset.has(i) and P[i].y > P[hips].y:
			head = i
			head_named = true
			break
	if head < 0:
		head = _climb(hips, legset, kids, P, TOP, W, H)
	if head < 0 or head == hips:
		_creature(out, feet, info, W, pr, kids, P, H)
		return
	var spine := _path(hips, head, pr)          # hips .. head, both ends included
	var tilt := rad_to_deg(Vector3.UP.angle_to(P[head] - P[hips]))
	# ---- THE ARMS: names first, each checked to hang from the spine above the hips; topology for a side names miss
	var onspine := {}
	for b in spine:
		onspine[b] = true
	var arms := {}
	var arms_by := "names"
	var arm_ok := func(ch: Dictionary) -> bool: return int(ch.get("upper", -1)) >= 0 and _arm_hangs(ch, onspine, legset, pr)
	for s in ["L", "R"]:
		var c := _named_chain(s, ARM_SLOTS, info, W, pr, kids, depth, arm_ok)
		if not c.is_empty():
			arms[s] = c
	var fwd := _facing(legs, P)
	var left := Vector3.UP.cross(fwd).normalized()
	if arms.size() < 2:
		var ta := _topological_arms(spine, hips, head, legset, arms, info, kids, P, left, W, H)
		if ta.size() > arms.size():
			arms_by = "structure"
		arms = ta
	# wings are not arms: an upright two-legged flyer (the library's bat and dragon) has a person's shape
	var legl := (_branch_len(int(legs["L"]["thigh"]), kids, P, W) + _branch_len(int(legs["R"]["thigh"]), kids, P, W)) * 0.5
	var arml := 0.0
	for s in arms:
		arml = maxf(arml, _branch_len(int(arms[s]["chain"][0]), kids, P, W))
	var arm_leg := arml / legl if legl > 1e-6 else 0.0
	var structural := tilt <= PERSON_TILT_DEG and arm_leg <= WING_RATIO
	if not (bool(out["person"]) or structural):
		_creature(out, feet, info, W, pr, kids, P, H)
		return
	# ---- a PERSON. Sides were read off names; geometry says them where names cannot (an anonymous rig's legs)
	if legs_by == "structure":
		_sides(legs, info, P, left, P[hips])
	if not bool(out["person"]):
		out["tilt"] = tilt
	out["person"] = true
	out["repair"] = plan
	out["pelvis"] = true
	out["hips"] = hips
	out["head"] = head
	out["head_named"] = head_named
	out["hips_named"] = hips_named
	out["source"] = "names" if (legs_by == "names" and arms_by == "names" and hips_named and head_named) else "structure"
	out["body"] = "person"
	out["arm_leg"] = arm_leg
	out["spine"] = spine.slice(1, spine.size() - 1)
	out["neck"] = -1
	for b in out["spine"]:
		if (info[int(b)] as Dictionary)["slot"] == "neck":
			out["neck"] = int(b)
			break
	out["chest"] = _chest(spine, arms, pr)
	out["lean"] = _lean_bone(spine, head, arms, tl, tr, pr)
	# the seat datum's bone (decision D6): the first pelvis-named bone over the floor that is of the body — the skin uses
	# it, or both thighs hang from it — wherever it hangs: the bone GPose.hips_height and every seat in the library were
	# calibrated on (Quaternius' platformer "Hips" hangs beside its thighs). A Rigify control rig's "hips" is neither: a
	# control, whose origin seated a full export 25 mm above its Meshy twin. None, and the datum is the structure's.
	var floor_y := INF
	for i in n:
		floor_y = minf(floor_y, P[i].y)
	for i in n:
		if GPose._is_hip_bone(names[i].to_lower()) and P[i].y - floor_y > 0.0 \
				and (rs.SKIN[i] == 1 or (_is_anc(i, tl, pr) and _is_anc(i, tr, pr))):
			out["seat_bone"] = i
			break
	_geo_sides(legs, "thigh", P, left, P[hips], H)
	_geo_sides(arms, "upper", P, left, P[hips], H)
	for s in ["L", "R"]:
		out["leg_" + s.to_lower()] = _slots(legs.get(s, {}), LEG_SLOTS)
		out["arm_" + s.to_lower()] = _slots(arms.get(s, {}), ARM_SLOTS)
	


# Not a person. Today's verdict stands (out already holds it) and the body is read for what a creature is: limbs to the
# floor (a walker), a wing pair (a flyer, rejected by WING_RATIO above), nothing to the floor (a glider: a snake, a fish).
static func _creature(out: Dictionary, feet: Array, info: Array, W: PackedByteArray, pr: PackedInt32Array, kids: Dictionary,
		P: PackedVector3Array, H: float) -> Dictionary:
	out["person"] = bool(out["person"])
	out["body"] = "walker" if feet.size() >= 2 else ("glider" if feet.is_empty() else "unknown")
	if bool(out["person"]):
		out["body"] = "person"     # today's tokens say person and structure found no legs: kept, posed by names
	return out


# today's name-token classifier, unchanged: the first hips/hip/pelvis token is the pelvis, the first "head" the head
static func _legacy(names: PackedStringArray, P: PackedVector3Array) -> Dictionary:
	var pelvis := -1
	var head := -1
	for i in names.size():
		var tok := GPose._bone_token(names[i])
		if pelvis < 0 and (tok == "hips" or tok == "hip" or tok == "pelvis"):
			pelvis = i
		elif head < 0 and tok == "head":
			head = i
	var out := {"person": false, "pelvis": pelvis >= 0, "tilt": -1.0, "hips": pelvis, "head": head,
		"arm_l": {}, "arm_r": {}, "leg_l": {}, "leg_r": {}}
	if pelvis >= 0 and head >= 0:
		var t := rad_to_deg(Vector3.UP.angle_to(P[head] - P[pelvis]))
		out["tilt"] = t
		out["person"] = t <= PERSON_TILT_DEG
	return out


# today's creature pickers find a thigh by name (GPose._is_thigh): the walk has legs to swing
static func _legacy_thighs(names: PackedStringArray) -> bool:
	for nm in names:
		var bn := nm.to_lower()
		if not ("twist" in bn or "roll" in bn) and GPose._is_thigh(bn):
			return true
	return false


# ONE LIMB BY ITS NAMES. The side's bones whose names give `order`'s slots; from the ancestor-most of them down to the
# deepest that descends from it; each named bone along that path takes the first of its slots not yet passed — a second
# bone with the same word is a segment of the first ("DEF-thigh.L.001"), a word with a later slot to take moves on to it
# (Synty's "Shoulder_L" after "Clavicle_L"). Every root tried in depth order until `ok` accepts the chain. {} = none.
static func _named_chain(side: String, order: Array, info: Array, W: PackedByteArray, pr: PackedInt32Array, kids: Dictionary,
		depth: PackedInt32Array, ok: Callable) -> Dictionary:
	var C: Array = []
	for i in info.size():
		var r: Dictionary = info[i]
		if W[i] == 1 and r["side"] == side and not r["skip"] and _any_in(r["slots"], order):
			C.append(i)
	if C.is_empty():
		return {}
	C.sort_custom(func(a, b): return depth[a] < depth[b] or (depth[a] == depth[b] and a < b))
	var tried := {}
	for root in C:
		if tried.has(root):
			continue
		var end := int(root)
		for b in C:
			if _is_anc(int(root), int(b), pr) and depth[b] > depth[end]:
				end = int(b)
		var path := _path(int(root), end, pr)
		for b in path:
			tried[b] = true
		var ch := {"chain": path}
		var cur := -1
		var cur_core := ""
		for b in path:
			var r: Dictionary = info[b]
			if W[b] == 0 or r["skip"] or r["side"] != side or not _any_in(r["slots"], order):
				continue
			var took := false
			for s in r["slots"]:
				var k := order.find(s)
				if k < 0:
					continue
				if k > cur:
					ch[s] = b
					cur = k
					cur_core = r["core"]
					took = true
					break
				if k == cur and r["core"] == cur_core:
					took = true              # a segment of the slot already taken
					break
				if k == cur and s == "hand" and r["core"] == "hand":
					ch["hand"] = b           # KayKit's "hand.l" after its "wrist.l": the bone that IS the hand
					cur_core = r["core"]
					took = true
					break
			if not took and r["core"] != cur_core:
				continue                     # an earlier word after a later slot: not this limb's
		_fix_upper(ch, order, info)
		if ok.call(ch):
			return ch
	return {}


# A limb whose names give a clavicle and a forearm and nothing between them: the "clavicle" is the upper arm (a rig whose
# shoulder bone IS its upper arm, with no collar bone before it).
static func _fix_upper(ch: Dictionary, order: Array, info: Array) -> void:
	if order != ARM_SLOTS or ch.has("upper") or not ch.has("clavicle"):
		return
	ch["upper"] = ch["clavicle"]
	ch.erase("clavicle")


# A leg reaches the floor: some weighted bone under its thigh stands in the floor band (the names may stop short of it:
# Quaternius' "DownLeg" was no word a leg knew).
static func _reaches(b: int, kids: Dictionary, P: PackedVector3Array, W: PackedByteArray, band: float) -> bool:
	if W[b] == 1 and P[b].y <= band:
		return true
	for c in kids.get(b, []):
		if _reaches(int(c), kids, P, W, band):
			return true
	return false


# An arm hangs from the spine above the hips: its root's parent is on the line from the hips to the head (or the hips
# themselves, as Quaternius hangs everything from one unweighted bone), never inside a leg.
static func _arm_hangs(ch: Dictionary, onspine: Dictionary, legset: Dictionary, pr: PackedInt32Array) -> bool:
	var path: Array = ch["chain"]
	if path.is_empty():
		return false
	var r: int = path[0]
	if legset.has(r):
		return false
	var a := pr[r]
	while a >= 0:
		if onspine.has(a):
			return true
		if legset.has(a):
			return false
		a = pr[a]
	return false


# A limb's slots as the map gives them (-1 for a slot it has none of).
static func _slots(ch: Dictionary, order: Array) -> Dictionary:
	var out := {}
	for s in order:
		out[s] = int(ch.get(s, -1))
	return out


# How far a limb reaches: the longest line of weighted bones down from its first one (a bat's "shoulder" is one bone
# its names call an arm, and four wing bones the names do not; the wing is what reaches).
static func _branch_len(b: int, kids: Dictionary, P: PackedVector3Array, W: PackedByteArray) -> float:
	var best := 0.0
	for c in kids.get(b, []):
		if W[c] == 1:
			best = maxf(best, P[b].distance_to(P[c]) + _branch_len(int(c), kids, P, W))
	return best


# ---------------------------------------------------------------------------------------------------- the structure

# Groups of weighted bones in the floor band, adjacent in the (repaired) hierarchy: each is a limb end on the ground.
# Returned as their highest bone (the ankle).
static func _floor_groups(n: int, W: PackedByteArray, pr: PackedInt32Array, kids: Dictionary, P: PackedVector3Array, band: float) -> Array:
	var out: Array = []
	for comp in _floor_sets(n, W, pr, kids, P, band):
		var top_b: int = comp[0]
		for c in comp:
			if P[c].y > P[top_b].y:
				top_b = c
		out.append(top_b)
	return out


# ...each group whole. A ROOT IS NEVER A LIMB END: a Quaternius root is weighted and stands at the floor, and joined the
# hooves that hang from it into one — the T-rex, the raptor, the parasaurolophus and the stegosaurus read one limb on the
# floor, "body unknown", where they stand on two and four (hoof-crest investigation, step 5c).
static func _floor_sets(n: int, W: PackedByteArray, pr: PackedInt32Array, kids: Dictionary, P: PackedVector3Array, band: float) -> Array:
	var inb := PackedByteArray()
	inb.resize(n)
	for i in n:
		inb[i] = 1 if (W[i] == 1 and P[i].y <= band and pr[i] >= 0) else 0
	var seen := PackedByteArray()
	seen.resize(n)
	var out: Array = []
	for i in n:
		if inb[i] == 0 or seen[i] == 1:
			continue
		var comp: Array = [i]
		seen[i] = 1
		var k := 0
		while k < comp.size():
			var x: int = comp[k]
			var nb: Array = (kids.get(x, []) as Array).duplicate()
			if pr[x] >= 0:
				nb.append(pr[x])
			for q in nb:
				if inb[q] == 1 and seen[q] == 0:
					seen[q] = 1
					comp.append(q)
			k += 1
		out.append(comp)
	return out


# ------------------------------------------------------------------------------------------------------------ the legs

## THE LEGS (legs()), read off what Resolve read: the skin's sampled rest vertices (SP, each with the bone that carries it
## most, SD) and the bones, in the hierarchy the skeleton has at runtime — a person's repaired (its plan), a creature's as it
## came: the census's plan joins a Quaternius dinosaur's hooves to its tail, and nothing ever re-parents them.
##   An IK RIG's legs first (Quaternius): a target hanging from the root with its origin in the floor band, at the end of a
##   weighted leaf bone that points at it (LEG_AIM_DEG) — the lower leg, whose parent is the upper. The target carries the
##   hoof, or nothing (the llama's right hind hoof is weighted to its lower leg).
##   Then every floor group of the rest (the census's _floor_sets): its foot is the bone whose own skin reaches lowest, or its
##   parent when that touches the floor too (a toe under its foot), at the end of a chain foot <- lower <- upper.
## A leg runs down from its upper bone to its foot within LEG_SLANT_DEG of vertical and is LEG_MIN of the body long; a limb
## named a tail, a fin, a flipper or a wing is never one (the rat's tail tip and the whale's flippers reach the floor); one
## leg to a lower bone (the frog's duplicate ends keep the nearest foot), and no foot that is another leg's bone. On the
## library (step 5c): 4 on every farm animal, the triceratops, the stegosaurus and the apatosaurus; 2 on the T-rex, the
## raptor and the parasaurolophus; 8 on the spider; 4 chained on the Rig Lab dragon, 2 on the default dragon (its Feet —
## the highest bone of its floor band is its LowerLeg, and a leg solved from there turned its whole body 1.6 m into the
## ground: hoof-crest); none on the snakes, the fish, the slime and the wasp.
static func _legs(rs: Resolve) -> Array:
	var n := rs.n
	var P := rs.P
	var W := rs.W
	var pr := rs.par.duplicate()
	for e in rs.out.get("repair", []):
		pr[int(e[0])] = int(e[1])
	var kids := {}
	for i in n:
		if pr[i] >= 0:
			if not kids.has(pr[i]):
				kids[pr[i]] = []
			(kids[pr[i]] as Array).append(i)
	# each bone's own skin: the samples it carries most (by_bone), the lowest of them, and the floor that skin touches
	var SP := rs._wt.pts
	var SD := rs._wt.dom
	var low := PackedFloat32Array()
	low.resize(n)
	low.fill(INF)
	var by_bone := {}
	var vlo := INF
	var vhi := -INF
	for k in SP.size():
		var y := SP[k].y
		vlo = minf(vlo, y)
		vhi = maxf(vhi, y)
		low[SD[k]] = minf(low[SD[k]], y)
		if not by_bone.has(SD[k]):
			by_bone[SD[k]] = []   # an Array: a packed one read out of a Dictionary is a copy, and appending to it is lost
		(by_bone[SD[k]] as Array).append(k)
	if not (vhi > vlo):
		return []
	var band := rs.lo + FLOOR_BAND * rs.H
	var touch := vlo + FOOT_TOUCH * (vhi - vlo)
	var leaf := W.duplicate()   # a weighted bone with no weighted bone under it
	for i in n:
		if W[i] == 1:
			var a := pr[i]
			while a >= 0:
				leaf[a] = 0
				a = pr[a]
	var cand: Array = []
	var targets := {}
	for t in n:
		if pr[t] < 0 or pr[pr[t]] >= 0 or P[t].y > band:
			continue
		var sub := {}
		for b in _subtree(t, kids):
			sub[b] = true
		var lower := -1
		var near := INF
		for b in n:
			if leaf[b] == 0 or sub.has(b) or pr[b] < 0 or pr[pr[b]] < 0:
				continue
			var to := P[t] - P[b]
			if to.length() > 1e-6 and to.length() < near and rad_to_deg(rs.Y[b].angle_to(to)) <= LEG_AIM_DEG:
				near = to.length()
				lower = b
		if lower >= 0:
			targets[t] = true
			cand.append({"foot": t, "lower": lower, "upper": pr[lower], "chain": false, "gap": near})
	var chained: Array = []
	for comp in _floor_sets(n, W, pr, kids, P, band):
		var f: int = comp[0]
		for c in comp:
			if low[c] < low[f]:
				f = c
		if pr[f] >= 0 and (comp as Array).has(pr[f]) and low[pr[f]] <= touch:
			f = pr[f]
		if not targets.has(f) and pr[f] >= 0 and W[pr[f]] == 1:
			chained.append(f)
	for f in chained:
		var lower := pr[int(f)]
		var shared := false   # a bone two feet hang from is no one leg's knee
		for g in chained:
			shared = shared or (int(g) != int(f) and _is_anc(lower, int(g), pr))
		if not shared:
			cand.append({"foot": int(f), "lower": lower, "upper": pr[lower], "chain": true, "gap": P[lower].distance_to(P[int(f)])})
	var named := func(b: int) -> bool:
		for w in _tokens(rs.names[b]):
			if w in NOT_LEGS:
				return true
		return false
	var by_lower := {}
	for c in cand:
		var f: int = c["foot"]
		var lo: int = c["lower"]
		var up: int = c["upper"]
		if up < 0 or pr[up] < 0 or named.call(f) or named.call(lo) or named.call(up):
			continue
		if not (P[up].y > P[lo].y and P[lo].y > P[f].y) or rad_to_deg(Vector3.DOWN.angle_to(P[f] - P[up])) > LEG_SLANT_DEG:
			continue
		c["len"] = P[up].distance_to(P[lo]) + P[lo].distance_to(P[f])
		if float(c["len"]) < LEG_MIN * rs.H:
			continue
		if not by_lower.has(lo) or float(c["gap"]) < float(by_lower[lo]["gap"]):
			by_lower[lo] = c
	var knees := {}
	for lo in by_lower:
		knees[lo] = true
		knees[int(by_lower[lo]["upper"])] = true
	var out: Array = []
	for lo in by_lower:
		var c: Dictionary = by_lower[lo]
		if knees.has(int(c["foot"])):
			continue
		var so := _soles(rs, int(c["foot"]), int(lo), float(c["len"]), _subtree(int(c["foot"]), kids), low, by_bone)
		out.append({"foot": c["foot"], "lower": lo, "upper": c["upper"], "chain": c["chain"], "len": c["len"],
			"soles": so[0], "on": so[1]})
	return out


# A FOOT'S UNDERSIDE: the skin its subtree carries — none (a target with no weights; a foot bone no vertex follows most, as
# the Rig Lab dragon's: its lower leg carries the foot's skin), what its lower leg carries within a quarter of the leg's drop
# of its own lowest vertex — and of that, the extremes of its lowest quarter eight ways across the ground (its toe, its heel,
# its sides and corners: a single lowest point left a hoof's edge 7.6 cm into a crest, hoof-crest) and the vertex nearest the
# middle of its lowest layer (a crest is highest between the edges). Each kept as the skin draws it (Weighted.influences: its
# bones, their weights, the vertex in each one's frame): a Meshy rig weighs a foot's underside to its body and upper leg too (the
# mire dragon's lowest vertex: lower leg 0.44, foot 0.33, spine 0.14, upper leg 0.10), and held rigid to one bone its
# planted front feet stayed 3 cm in the flat ground GFeet had put that bone's points on (the drive rig's (f3): 0.05 off).
#   {bones (the bones they ride), at (each influence's index there), w (its weight), l (the vertex in that bone's frame),
#   o (where each sole's influences start, and a last end)}; `on`: the bone most of them ride — the foot, or the lower leg
#   where the foot has no skin of its own.
static func _soles(rs: Resolve, f: int, lower: int, ln: float, sub: Array, low: PackedFloat32Array,
		by_bone: Dictionary) -> Array:
	var SP := rs._wt.pts
	var idx := PackedInt32Array()
	for b in sub:
		for k: int in by_bone.get(int(b), []):
			idx.append(k)
	idx.sort()   # in the order the skin was read: the extremes below pick the first of a tie, as a single pass did
	var on := f
	if idx.is_empty():
		on = lower
		var reach := low[lower] + 0.25 * maxf(rs.P[lower].y - rs.P[f].y, 0.0)
		for k: int in by_bone.get(lower, []):
			if SP[k].y <= reach:
				idx.append(k)
	var keep := PackedInt32Array()
	if not idx.is_empty():
		var sy := INF
		var top := -INF
		for k in idx:
			sy = minf(sy, SP[k].y)
			top = maxf(top, SP[k].y)
		var quarter := sy + maxf(0.25 * (top - sy), 0.01 * ln)
		var layer := sy + 0.01 * ln
		for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1), Vector2(1, 1).normalized(), Vector2(1, -1).normalized(),
				Vector2(-1, 1).normalized(), Vector2(-1, -1).normalized()]:
			var best := -1
			var bs := -INF
			for k in idx:
				var p := SP[k]
				if p.y <= quarter and p.x * d.x + p.z * d.y > bs:
					bs = p.x * d.x + p.z * d.y
					best = k
			if best >= 0 and not keep.has(best):
				keep.append(best)
		var mid := Vector3.ZERO
		var nm := 0
		for k in idx:
			if SP[k].y <= layer:
				mid += SP[k]
				nm += 1
		if nm > 0:
			mid /= float(nm)
			var near := -1
			for k in idx:
				if SP[k].y <= layer and (near < 0 or SP[k].distance_squared_to(mid) < SP[near].distance_squared_to(mid)):
					near = k
			if not keep.has(near):
				keep.append(near)
	if keep.is_empty():
		# nothing drawn: the foot's own joint
		return [{"bones": PackedInt32Array([f]), "at": PackedInt32Array([0]), "w": PackedFloat32Array([1.0]),
			"l": PackedVector3Array([Vector3.ZERO]), "o": PackedInt32Array([0, 1])}, f]
	var bo := PackedInt32Array()
	var at := PackedInt32Array()
	var w := PackedFloat32Array()
	var l := PackedVector3Array()
	var o := PackedInt32Array()
	for k in keep:
		o.append(w.size())
		var inf: Array = rs._wt.influences(k)
		for j in (inf[0] as PackedInt32Array).size():
			var x := bo.find(inf[0][j])
			if x < 0:
				x = bo.size()
				bo.append(inf[0][j])
			at.append(x)
			w.append(inf[1][j])
			l.append(inf[2][j])
	o.append(w.size())
	return [{"bones": bo, "at": at, "w": w, "l": l, "o": o}, on]


# TWO LEGS BY STRUCTURE, for a rig whose names give none: exactly one mirror pair of floor groups meeting at one bone
# (their common ancestor), every other floor group on the midline (a tail, a cape's hem). Each leg: the thigh is the
# first bone below that junction pointing steeply down, the knee the joint half way to the ankle.
static func _structural_legs(feet: Array, n: int, W: PackedByteArray, pr: PackedInt32Array, kids: Dictionary,
		P: PackedVector3Array, Y: PackedVector3Array, H: float, band: float) -> Dictionary:
	var pairs: Array = []
	for a in feet.size():
		for b in range(a + 1, feet.size()):
			var fa: int = feet[a]
			var fb: int = feet[b]
			var j := _lca(fa, fb, pr)
			if j < 0:
				continue
			var ha := Vector2(P[fa].x - P[j].x, P[fa].z - P[j].z)
			var hb := Vector2(P[fb].x - P[j].x, P[fb].z - P[j].z)
			var w := Vector2(P[fa].x - P[fb].x, P[fa].z - P[fb].z).length()
			if w > 0.05 * H and ha.dot(hb) < 0.0 and absf(ha.length() - hb.length()) + absf(P[fa].y - P[fb].y) < 0.35 * w + 0.03 * H:
				pairs.append([fa, fb, j])
	if pairs.size() != 1:
		return {}
	var fa2: int = pairs[0][0]
	var fb2: int = pairs[0][1]
	var junction: int = pairs[0][2]
	var lat := Vector3(P[fa2].x - P[fb2].x, 0, P[fa2].z - P[fb2].z).normalized()
	for f in feet:
		if f != fa2 and f != fb2 and absf((P[f] - P[junction]).dot(lat)) > 0.06 * H:
			return {}
	var out := {}
	var k := 0
	for f in [fa2, fb2]:
		var path := _path(junction, f, pr)        # junction .. ankle
		var th := -1
		for i in range(1, path.size() - 1):
			var d := P[path[i + 1]] - P[path[i]]
			if d.length() > 1e-6 and rad_to_deg(Vector3.DOWN.angle_to(d)) < STEEP_DEG:
				th = i
				break
		if th < 0:
			th = 1 if path.size() > 2 else 0
		var an := path.size() - 1
		var foot: int = path[an]
		var toe := -1
		var lowest := INF
		for c in kids.get(foot, []):
			if W[c] == 1 and P[c].y < lowest:
				lowest = P[c].y
				toe = c
		var kn := _half_way(path, th, an, P)
		var ch := {"thigh": path[th], "shin": path[kn] if kn >= 0 else -1, "foot": foot, "toe": toe,
			"chain": path.slice(th) + ([toe] if toe >= 0 else [])}
		out["L" if k == 0 else "R"] = ch
		k += 1
	return out


# The head by structure: up from the hips, through the weighted child on the midline whose subtree's flesh reaches
# highest and is no leg, to where that line ends — no child rising above it, or several rising about as high with none
# clearly the line's (a face fanning out of the head: Rigify's forehead, nose and jaw join DEF-spine.006 after the
# repair). At the chest the neck reaches the top of the head and the clavicles only the shoulders: the neck is the line.
# A child off the midline (an ear, a temple, a clavicle) is never the line.
static func _climb(hips: int, legset: Dictionary, kids: Dictionary, P: PackedVector3Array, TOP: PackedFloat32Array,
		W: PackedByteArray, H: float) -> int:
	var reach := {}
	var cur := hips
	var mid := P[hips]
	for _i in 512:
		var rise: Array = []
		for c in kids.get(cur, []):
			if legset.has(c) or W[c] == 0:
				continue
			if absf(P[c].x - mid.x) > 0.03 * H:
				continue
			var r := _reach(int(c), kids, TOP, reach) - TOP[cur]
			if r > 0.01 * H:
				rise.append([r, int(c)])
		if rise.is_empty():
			break
		rise.sort_custom(func(a, b): return float(a[0]) > float(b[0]))
		if rise.size() >= 2 and float(rise[1][0]) > 0.5 * float(rise[0][0]):
			break
		cur = int(rise[0][1])
	return cur if cur != hips else -1


static func _reach(b: int, kids: Dictionary, TOP: PackedFloat32Array, memo: Dictionary) -> float:
	if memo.has(b):
		return memo[b]
	var r := TOP[b]
	for c in kids.get(b, []):
		r = maxf(r, _reach(int(c), kids, TOP, memo))
	memo[b] = r
	return r


# ARMS FROM THE HIERARCHY. The branches off the line from the hips to the head that are neither a leg nor that line,
# two bones or more reaching ARM_MIN of the height (a breast, an ear, a single cape bone are not arms); each side's
# longest. Never by how far out a rest pose holds them: an I-pose's arms hang at its sides and are still arms.
static func _topological_arms(spine: Array, hips: int, head: int, legset: Dictionary, have: Dictionary, info: Array,
		kids: Dictionary, P: PackedVector3Array, left: Vector3, W: PackedByteArray, H: float) -> Dictionary:
	var out := have.duplicate()
	var onspine := {}
	for b in spine:
		onspine[b] = true
	var taken := {}
	for s in out:
		for b in out[s]["chain"]:
			taken[b] = true
	var mid := P[hips]
	var cands: Array = []
	for b in spine:
		if int(b) == head:
			continue
		for c in kids.get(int(b), []):
			if onspine.has(c) or legset.has(c) or taken.has(c) or W[c] == 0:
				continue
			var ch := _longest(int(c), kids, P, W)
			var L := 0.0
			for k in range(1, ch.size()):
				L += P[ch[k]].distance_to(P[ch[k - 1]])
			if ch.size() < 2 or L < ARM_MIN * H:
				continue
			var side := ""
			var votes := 0
			for x in ch:
				var sd: String = (info[x] as Dictionary)["side"]
				votes += 1 if sd == "L" else (-1 if sd == "R" else 0)
			if votes != 0:
				side = "L" if votes > 0 else "R"
			else:
				var o := (P[ch[ch.size() - 1]] - mid).dot(left)
				side = "L" if o > 0.0 else "R"
			cands.append([side, L, ch])
	for s in ["L", "R"]:
		if out.has(s):
			continue
		var best: Array = []
		for c in cands:
			if c[0] == s and (best.is_empty() or float(c[1]) > float(best[1])):
				best = c
		if best.is_empty():
			continue
		out[s] = _arm_slots(best[2], info, kids, P)
	return out


# The slots along an arm chain found by structure: a clavicle when the first bone is short against the rest (or the
# names say so), the hand where names say or the fingers fan out (three or more children), else the chain's end; the
# forearm half way between the upper arm and the hand.
static func _arm_slots(ch: Array, info: Array, kids: Dictionary, P: PackedVector3Array) -> Dictionary:
	var up := 0
	if ch.size() >= 4:
		var rest := 0.0
		for k in range(1, ch.size() - 1):
			rest += P[ch[k]].distance_to(P[ch[k + 1]])
		if (info[ch[0]] as Dictionary)["slot"] == "clavicle" or P[ch[0]].distance_to(P[ch[1]]) < 0.35 * rest:
			up = 1
	var hd := -1
	for k in range(up + 1, ch.size()):
		if (info[ch[k]] as Dictionary)["slot"] == "hand":
			hd = k
			break
	if hd < 0:
		for k in range(up + 1, ch.size()):
			if (kids.get(ch[k], []) as Array).size() >= 3:
				hd = k
				break
	if hd < 0:
		hd = ch.size() - 1
	var el := _half_way(ch, up, hd, P)
	# an arm of two bones ends at its forearm: no hand to name (Quaternius' monster skeleton) — its hand is where the
	# forearm's flesh ends (hand_end), never the forearm bone, whose origin is the elbow
	return {"clavicle": ch[0] if up == 1 else -1, "upper": ch[up], "fore": ch[el] if el >= 0 else -1,
		"hand": ch[hd] if hd != el else -1, "chain": ch}


static func _longest(b: int, kids: Dictionary, P: PackedVector3Array, W: PackedByteArray) -> Array:
	var best: Array = [b]
	for c in kids.get(b, []):
		if W[c] == 0:
			continue
		var sub := _longest(int(c), kids, P, W)
		if sub.size() + 1 > best.size():
			best = [b] + sub
	return best


# Which way the body faces: along its feet (toe - ankle), else +Z (the stack's convention: characters face +Z).
static func _facing(legs: Dictionary, P: PackedVector3Array) -> Vector3:
	var f := Vector3.ZERO
	for s in legs:
		var toe := int(legs[s].get("toe", -1))
		var foot := int(legs[s].get("foot", -1))
		if toe >= 0 and foot >= 0:
			var d := P[toe] - P[foot]
			f += Vector3(d.x, 0, d.z)
	return f.normalized() if f.length() > 1e-4 else Vector3(0, 0, 1)


# A pair found by structure: the side its bones' names give (Quaternius calls the -X leg "L_"), else where the limb's end
# lies (left = +X for a body facing +Z).
static func _sides(pair: Dictionary, info: Array, P: PackedVector3Array, left: Vector3, mid: Vector3) -> void:
	if pair.size() != 2 or not (pair.has("L") and pair.has("R")):
		return
	var a: Array = pair["L"]["chain"]
	var b: Array = pair["R"]["chain"]
	var va := 0
	var vb := 0
	for x in a:
		var sd: String = (info[int(x)] as Dictionary)["side"]
		va += 1 if sd == "L" else (-1 if sd == "R" else 0)
	for x in b:
		var sd: String = (info[int(x)] as Dictionary)["side"]
		vb += 1 if sd == "L" else (-1 if sd == "R" else 0)
	var swap := false
	if va != 0 and signi(va) == -signi(vb):
		swap = va < 0
	else:
		swap = (P[int(a[a.size() - 1])] - mid).dot(left) < (P[int(b[b.size() - 1])] - mid).dot(left)
	if swap:
		var t = pair["L"]
		pair["L"] = pair["R"]
		pair["R"] = t


# NAMES THAT COUNT FROM THE VIEWER. A side is read off a name ("L_", ".R", "Left"), and nearly every exporter means the
# body's own: its left on +X for a body facing +Z (the stack's convention). Quaternius' monster skeleton means the
# viewer's — its "R_" limbs hang on +X, its LEFT (its run and attack clips carry it toward +Z) — so a weapon went in its left
# hand (step 2's review). A pair whose two limbs' root joints both sit clearly across the midline from what their names
# say (SIDE_CLEAR of the height, `left` off the feet, else +Z) is swapped: the body decides. The Quaternius superheroes'
# feet face -Z, and their names are their own sides there. Returns whether it swapped.
static func _geo_sides(pair: Dictionary, root_slot: String, P: PackedVector3Array, left: Vector3, mid: Vector3, H: float) -> bool:
	if not (pair.has("L") and pair.has("R")):
		return false
	var l := int((pair["L"] as Dictionary).get(root_slot, -1))
	var r := int((pair["R"] as Dictionary).get(root_slot, -1))
	if l < 0 or r < 0:
		return false
	if (P[l] - mid).dot(left) < -SIDE_CLEAR * H and (P[r] - mid).dot(left) > SIDE_CLEAR * H:
		var t = pair["L"]
		pair["L"] = pair["R"]
		pair["R"] = t
		return true
	return false


# The chest: the line's bone the arms hang from (the highest of them), else the line's last bone below the head.
static func _chest(spine: Array, arms: Dictionary, pr: PackedInt32Array) -> int:
	var best := -1
	for s in arms:
		var r: int = arms[s]["chain"][0]
		var a := pr[r]
		while a >= 0 and not (a in spine):
			a = pr[a]
		if a >= 0 and spine.find(a) > spine.find(best):
			best = a
	if best < 0 and spine.size() >= 3:
		best = spine[spine.size() - 2]
	return best


# THE BONE A LEAN TILTS (swim): the lowest one that carries the head and both arms and neither leg — the torso leans,
# the legs keep their pose, the arms go with it. A rig that hangs its arms from the hips themselves (Quaternius) leans
# the lowest bone that carries the head and no leg; its arms stay, as today.
static func _lean_bone(spine: Array, head: int, arms: Dictionary, tl: int, tr: int, pr: PackedInt32Array) -> int:
	var need: Array = [head]
	for s in arms:
		need.append(int(arms[s]["chain"][0]))
	for k in range(1, spine.size()):
		var b: int = spine[k]
		if _is_anc(b, tl, pr) or _is_anc(b, tr, pr) or b == tl or b == tr:
			continue
		var all := true
		for x in need:
			if x != b and not _is_anc(b, int(x), pr):
				all = false
				break
		if all:
			return b
	for k in range(1, spine.size()):
		var b: int = spine[k]
		if not (_is_anc(b, tl, pr) or _is_anc(b, tr, pr)) and (b == head or _is_anc(b, head, pr)):
			return b
	return -1


# ------------------------------------------------------------------------------------------------------ the forest

# THE FOREST'S REPAIR PLAN, A PIECE AT A TIME: [[bone, new parent], ...] in `plan` once step() returns true. The skin's
# ORPHAN ROOTS — a weighted bone with no weighted ancestor that the skeleton holds by nothing (a REAL root: Rigify's
# DEF-thigh.L, DEF-upper_arm.L, DEF-palm.01.L in a "deform bones only" export) or only by the control rig (a Rigify full
# export hangs DEF-thigh.L from ORG-spine and DEF-upper_arm.L from ORG-shoulder.L, which no pose moves) — each join,
# nearest first (Prim's order from the trunk: the orphan root holding the most weighted bones), the weighted bone whose
# JOINT it sits on: a bone's origin, a point inside its segment to a child (the far end is the child's and counts for the
# child, so a palm at the wrist joins the hand, not the forearm ending there), or for a bone with no child, its own line
# (+Y). Two joints within JOIN_TIE of each other go to the one nearer the trunk (a clavicle at the top of the chest joins
# the chest, not the neck starting there). Never a bone of the other side (the clavicles meet at the sternum). A root held
# by an ordinary bone the skin does not use stays where it is — Quaternius hangs legs, arms and torso from one unweighted
# Hips, and that rig works. Applied to a PERSON only: every creature keeps its skeleton, and today's pickers, exactly.
# A piece is one root's first measure against the trunk, or one join and its new bones measured by every root still
# waiting (the legacy face: 110 roots, 11 359 joint measurements, 39 ms whole — 0.1-0.7 ms a piece).
class Plan extends RefCounted:
	var plan: Array = []
	var _par: PackedInt32Array
	var _P: PackedVector3Array
	var _Y: PackedVector3Array
	var _W: PackedByteArray
	var _dp := PackedInt32Array()     # each weighted bone's nearest weighted ancestor (the skin's own hierarchy)
	var _dk := {}
	var _members := {}
	var _trunk := -1
	var _todo: Array = []
	var _depth := {}
	var _side := {}
	var _best := {}                   # root -> [distance, bone]
	var _tie := 0.0
	var _k := 0                       # roots measured against the trunk so far
	var _done := false

	func _init(names: PackedStringArray, par: PackedInt32Array, P: PackedVector3Array, Y: PackedVector3Array,
			W: PackedByteArray, H: float) -> void:
		_par = par
		_P = P
		_Y = Y
		_W = W
		var n := par.size()
		_dp.resize(n)
		var roots: Array = []
		for i in n:
			_dp[i] = -1
			if W[i] == 0:
				continue
			var a := par[i]
			while a >= 0 and W[a] == 0:
				a = par[a]
			_dp[i] = a
			if a < 0:
				roots.append(i)
		if roots.size() < 2:
			_done = true
			return
		for i in n:
			if _dp[i] >= 0:
				if not _dk.has(_dp[i]):
					_dk[_dp[i]] = []
				(_dk[_dp[i]] as Array).append(i)
		for r in roots:
			_members[r] = GRig._subtree(int(r), _dk)
		for r in roots:
			if _trunk < 0 or (_members[r] as Array).size() > (_members[_trunk] as Array).size():
				_trunk = int(r)
		for r in roots:
			if r != _trunk and (par[r] < 0 or bool(GRig.read_name(names[par[r]])["skip"])):
				_todo.append(int(r))
		# ...and a real root the skin does not use at all, no helper, holding no weighted bone: a deform bone left without
		# weights (a legacy Rigify face exports ~100, some with none) still belongs where it sits — whatever hangs on it, a
		# hat on a BoneAttachment3D, goes with the head
		var rk := {}
		for i in n:
			if par[i] >= 0:
				if not rk.has(par[i]):
					rk[par[i]] = []
				(rk[par[i]] as Array).append(i)
		for i in n:
			if par[i] >= 0 or W[i] == 1 or i == _trunk or bool(GRig.read_name(names[i])["skip"]):
				continue
			var sub := GRig._subtree(i, rk)
			var holds := false
			for b in sub:
				holds = holds or W[b] == 1
			if not holds:
				_members[i] = sub
				_todo.append(i)
		if _todo.is_empty():
			_done = true
			return
		_tie = GRig.JOIN_TIE * H
		for b in _members[_trunk]:
			var d := 0
			var a := _dp[b]
			while a >= 0:
				d += 1
				a = _dp[a]
			_depth[b] = d
		for i in n:
			_side[i] = GRig.side_of(names[i])
		for r in _todo:
			_best[r] = [INF, -1]

	## One piece: a root's first measure, or the next join. true when `plan` is whole.
	func step() -> bool:
		if _done:
			return true
		if _k < _todo.size():
			GRig._closer(int(_todo[_k]), _members[_trunk], _best, _P, _dk, _Y, _depth, _side, _tie, _W)
			_k += 1
			return false
		var pick := -1
		for r in _todo:
			if int(_best[r][1]) >= 0 and (pick < 0 or float(_best[r][0]) < float(_best[pick][0])):
				pick = int(r)
		if pick < 0:
			_done = true
			return true
		var at: int = _best[pick][1]
		plan.append([pick, at])
		_todo.erase(pick)
		var was_leaf := (_dk.get(at, []) as Array).is_empty()
		if not _dk.has(at):
			_dk[at] = []
		(_dk[at] as Array).append(pick)
		var base := int(_depth.get(at, 0)) + 1
		for b in _members[pick]:
			var d := 0
			var a: int = b
			while a != pick and a >= 0:
				d += 1
				a = _dp[a] if _W[a] == 1 else _par[a]
			_depth[b] = base + d
		for r in _todo:
			# `at` just gained a child. Its FIRST turns its line (a ray) into a segment that ends there, and whoever was
			# measured to it is measured again in full; a later one only adds a segment, measured like the new bones
			if was_leaf and int(_best[r][1]) == at:
				_best[r] = [INF, -1]
				GRig._closer(int(r), GRig._grown(_trunk, plan, _members), _best, _P, _dk, _Y, _depth, _side, _tie, _W)
			else:
				GRig._closer(int(r), _members[pick] + [at], _best, _P, _dk, _Y, _depth, _side, _tie, _W)
		_done = _todo.is_empty()
		return _done


# Measure root `r` against `bones` (the weighted ones) and keep the closest joint in best[r] (ties within `tie` to the
# shallower bone).
static func _closer(r: int, bones: Array, best: Dictionary, P: PackedVector3Array, kids: Dictionary, Y: PackedVector3Array,
		depth: Dictionary, side: Dictionary, tie: float, W: PackedByteArray) -> void:
	var e: Array = best[r]
	var sr: String = side[r]
	for b in bones:
		if W[b] == 0:
			continue                     # a root joins the body, never a bone the skin does not use
		var sb: String = side[b]
		if sr != "" and sb != "" and sr != sb:
			continue
		var d := _joint_dist(P[r], int(b), P, kids, Y)
		var bb: int = e[1]
		if d < float(e[0]) - tie or (d < float(e[0]) + tie and bb >= 0 and int(depth.get(b, 0)) < int(depth.get(bb, 0))):
			e[0] = d
			e[1] = int(b)


static func _grown(trunk: int, plan: Array, members: Dictionary) -> Array:
	var out: Array = (members[trunk] as Array).duplicate()
	for e in plan:
		out.append_array(members[int(e[0])])
	return out


# distance from a point to a bone's joints (see Plan)
static func _joint_dist(p: Vector3, b: int, P: PackedVector3Array, kids: Dictionary, Y: PackedVector3Array) -> float:
	join_evals += 1
	var best := p.distance_to(P[b])
	var ks: Array = kids.get(b, [])
	for c in ks:
		var a := P[b]
		var ab := P[int(c)] - a
		var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 0.98)
		best = minf(best, p.distance_to(a + ab * t) + 1e-4)
	if ks.is_empty():
		var t2 := maxf(0.0, (p - P[b]).dot(Y[b]))
		best = minf(best, p.distance_to(P[b] + Y[b] * t2) + 1e-4)
	return best


# Has `skel` been repaired by `plan` already (a duplicate of a warmed source is born repaired)?
static func _repaired(skel: Skeleton3D, plan: Array) -> bool:
	return plan.is_empty() or skel.get_bone_parent(int(plan[0][0])) == int(plan[0][1])


# REPAIR `skel` by the map's plan: each forest root re-parented, its rest recomputed so its global rest (and the skin)
# stays exactly where it was. Returns what the clips' rebase reads: [the old parents, the old local rests].
static func _reparent(skel: Skeleton3D, plan: Array) -> Array:
	var n := skel.get_bone_count()
	var old_par := PackedInt32Array()
	old_par.resize(n)
	var rest: Array = []
	var glob: Array = []
	for i in n:
		old_par[i] = skel.get_bone_parent(i)
		rest.append(skel.get_bone_rest(i))
		glob.append(skel.get_bone_global_rest(i))
	for e in plan:
		var r: int = e[0]
		var a: int = e[1]
		skel.set_bone_parent(r, a)
		skel.set_bone_rest(r, (glob[a] as Transform3D).affine_inverse() * (glob[r] as Transform3D))
	skel.reset_bone_poses()
	return [old_par, rest]


static func _moved(plan: Array) -> Dictionary:
	var mv := {}
	for e in plan:
		mv[int(e[0])] = int(e[1])
	return mv


## A COPY OF A MODEL NOTHING WARMED (the 3d template, a chat edit) is repaired where it is first asked for: its own
## skeleton re-parented (the plan's few bones), and each library its players share with the model swapped for the model's
## rebased copy — rebased by the first copy and kept on the library they share (META_REBASED), so no later copy rebases a
## clip (each paid the whole rebase again: 8-17 ms with one clip, 255-343 ms with fifteen — step 2's review). Idempotent:
## a skeleton already repaired is left alone.
static func _repair_copy(skel: Skeleton3D, top: Node3D, plan: Array, key: String) -> void:
	if _repaired(skel, plan):
		return
	var old := _reparent(skel, plan)
	var mv := _moved(plan)
	for ap: AnimationPlayer in top.find_children("*", "AnimationPlayer", true, false):
		var aroot := ap.get_node_or_null(ap.root_node)
		if aroot == null:
			continue
		for lname in ap.get_animation_library_list():
			var lib := ap.get_animation_library(lname)
			var done: Dictionary = lib.get_meta(META_REBASED, {})
			if not done.has(key):
				done[key] = _rebased_lib(lib, skel, aroot, mv, old)
				lib.set_meta(META_REBASED, done)
			if done[key] is AnimationLibrary:
				ap.remove_animation_library(lname)
				ap.add_animation_library(lname, done[key])


# `lib` with every clip that moves a re-parented root rebased: a new library of rebased copies of those clips and the
# others as they are — or true when no clip of it moves one (nothing to swap; never `lib` itself, which would hold itself).
static func _rebased_lib(lib: AnimationLibrary, skel: Skeleton3D, aroot: Node, mv: Dictionary, old: Array) -> Variant:
	var out := AnimationLibrary.new()
	var changed := false
	for an_name in lib.get_animation_list():
		var an := lib.get_animation(an_name)
		var rb := Rebase.new(an, skel, aroot, mv, old[0], old[1])
		if rb.hits:
			rb.an = an.duplicate(true) as Animation   # the same tracks in the same order: what Rebase read stands
			while not rb.step():
				pass
			rebased += 1
			out.add_animation(an_name, rb.an)
			changed = true
		else:
			out.add_animation(an_name, an)
	return out if changed else true


# ONE CLIP REBASED INTO A REPAIRED HIERARCHY, A PIECE AT A TIME: every re-parented root's pose at every key time the clip
# has on the bones it needs — the root's own old chain and its new parent's — becomes local to the new parent: inverse(the
# parent's old global) * the global the root had, so the skeleton draws, key for key, what the clip drew before. Exact at
# the keys; between them each channel interpolates as before (a Blender export bakes a key a frame). A root the export
# left with no track is keyed too when the chain above its new parent moves (its old parent carried it nowhere), and a root
# keyed at fewer times than that chain is keyed at all of them. The old globals are composed ONCE per key time over only
# the bones some root needs (a Rigify forest's ten roots: 19 of its 35 bones), never per root over every bone: whole, a
# forest's fifteen clips took 233 ms, a legacy face's one clip 355 ms and fifteen 11 s (step 2's review). A piece is one
# needed bone's key times read, one key time, or one root's keys written. Computed from the original keys, written after.
class Rebase extends RefCounted:
	var an: Animation
	var hits := false                  # the clip moves a re-parented root: its own tracks, or a bone above its new parent
	var _path := ""                    # the skeleton, from the player's root: a track added on a root that had none
	var _skel: Skeleton3D
	var _moved := {}                   # root -> new parent
	var _old_par: PackedInt32Array
	var _need: Array = []              # the needed bones, each after its old parent
	var _tr := {}                      # needed bone -> [[track, type], ...]
	var _own := {}                     # root -> {type: track}: its own tracks
	var _rest := {}                    # needed bone -> [position, rotation, scale] at its old rest
	var _times := {}                   # the key times (snapped to 1e-5 s), gathered a bone a piece
	var _ts: Array = []
	var _keys := {}                    # root -> [[position], [rotation], [scale]], one each a key time
	var _roots: Array = []
	var _g := 0                        # needed bones whose key times are gathered
	var _k := 0                        # key times done
	var _w := 0                        # roots written

	func _init(a: Animation, skel: Skeleton3D, aroot: Node, moved: Dictionary, old_par: PackedInt32Array, rest: Array) -> void:
		an = a
		_skel = skel
		_moved = moved
		_old_par = old_par
		if an.has_meta(GRig.META_REPAIRED):
			return
		var tracks := GPose._bone_tracks(skel, an, aroot)
		var driven := {}
		for t in tracks:
			driven[int(t[2])] = true
		for r in moved:
			if driven.has(int(r)) or GRig._drives_above(int(moved[r]), driven, old_par):
				hits = true
				break
		if not hits:
			return
		_path = String(aroot.get_path_to(skel))
		var need := {}
		for r in moved:
			for x in [int(r), int(moved[r])]:
				var b: int = x
				while b >= 0 and not need.has(b):
					need[b] = true
					b = old_par[b]
		var dep := {}
		for b in need:
			var d := 0
			var x := old_par[b]
			while x >= 0:
				d += 1
				x = old_par[x]
			dep[b] = d
		_need = need.keys()
		_need.sort_custom(func(p, q): return int(dep[p]) < int(dep[q]) or (int(dep[p]) == int(dep[q]) and int(p) < int(q)))
		for t in tracks:
			var b: int = t[2]
			if need.has(b):
				if not _tr.has(b):
					_tr[b] = []
				(_tr[b] as Array).append([int(t[0]), int(t[1])])
			if moved.has(b):
				if not _own.has(b):
					_own[b] = {}
				(_own[b] as Dictionary)[int(t[1])] = int(t[0])
		for b in _need:
			var rt: Transform3D = rest[b]
			_rest[b] = [rt.origin, rt.basis.get_rotation_quaternion(), rt.basis.get_scale()]
		_roots = moved.keys()
		for r in _roots:
			_keys[r] = [[], [], []]

	## One piece; true when the clip is rebased.
	func step() -> bool:
		if not hits:
			return true
		if _g < _need.size():
			for e in _tr.get(_need[_g], []):
				for k in an.track_get_key_count(int(e[0])):
					_times[snappedf(an.track_get_key_time(int(e[0]), k), 1e-5)] = true
			_g += 1
			if _g == _need.size():
				_ts = _times.keys()
				if _ts.is_empty():
					_ts = [0.0]
				_ts.sort()
			return false
		if _k < _ts.size():
			var t := float(_ts[_k])
			_k += 1
			var g := {}
			for b in _need:
				var r0: Array = _rest[b]
				var pos: Vector3 = r0[0]
				var rot: Quaternion = r0[1]
				var scl: Vector3 = r0[2]
				for e in _tr.get(b, []):
					GRig.interps += 1
					match int(e[1]):
						Animation.TYPE_POSITION_3D:
							pos = an.position_track_interpolate(int(e[0]), t)
						Animation.TYPE_ROTATION_3D:
							rot = an.rotation_track_interpolate(int(e[0]), t)
						_:
							scl = an.scale_track_interpolate(int(e[0]), t)
				var loc := Transform3D(Basis(rot) * Basis.from_scale(scl), pos)
				var p := _old_par[b]
				g[b] = ((g[p] as Transform3D) * loc) if p >= 0 else loc
			for r in _roots:
				var l: Transform3D = (g[_moved[r]] as Transform3D).affine_inverse() * (g[r] as Transform3D)
				var kk: Array = _keys[r]
				(kk[0] as Array).append(l.origin)
				(kk[1] as Array).append(l.basis.get_rotation_quaternion())
				(kk[2] as Array).append(l.basis.get_scale())
			return false
		if _w < _roots.size():
			var r: int = _roots[_w]
			_w += 1
			var kk: Array = _keys[r]
			var path := NodePath(_path + ":" + _skel.get_bone_name(r))
			var own: Dictionary = _own.get(r, {})
			for ty in [Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D, Animation.TYPE_SCALE_3D]:
				var tr := int(own.get(ty, -1))
				if tr < 0:
					if ty == Animation.TYPE_SCALE_3D:
						continue                 # a root that never scaled keeps no scale track
					tr = an.add_track(ty)
					an.track_set_path(tr, path)
				for k in range(an.track_get_key_count(tr) - 1, -1, -1):
					an.track_remove_key(tr, k)
				for k in _ts.size():
					match ty:
						Animation.TYPE_POSITION_3D:
							an.position_track_insert_key(tr, float(_ts[k]), kk[0][k])
						Animation.TYPE_ROTATION_3D:
							an.rotation_track_insert_key(tr, float(_ts[k]), kk[1][k])
						_:
							an.scale_track_insert_key(tr, float(_ts[k]), kk[2][k])
			if _w < _roots.size():
				return false
			an.set_meta(GRig.META_REPAIRED, true)
		return true


# does `driven` (bones a clip has tracks on) hold `a` or any of its old ancestors?
static func _drives_above(a: int, driven: Dictionary, old_par: PackedInt32Array) -> bool:
	var x := a
	while x >= 0:
		if driven.has(x):
			return true
		x = old_par[x]
	return false


## WHICH WAY A MODEL GOES. Every consumer rides, chases and herds a creature facing +Z — the map's frame, a mount's drive axis
## (Vehicle._drawn_xf), an enemy's turn (Enemy._face), a herd's (WanderAgent._face_heading) — and a model authored facing along
## x went square to its way: the library wasp, its head bone 1.26 m along +x from its root and its bones 1.53 m along x and
## 0.77 across, was ridden, chased and herded sideways, its saddle across its back (followups3; step 5d). Read off its bones
## alone, before anything measures it (the warm's first piece): the chain from the head's parent to the head points across —
## FACE_ACROSS times as far across as along, at least FACE_MIN of its bones' height — toward the end of its bones' span it
## heads, and that span is longer across than along; then every node under the scene's root is turned so its head is at +Z,
## and its map, its body, its seat and its clips are all read so. Across only: a chain that points back is no sign of the way a
## body goes (a coiled snake's neck, the realistic alien's hunched one, whose feet and face point +Z). Not where a clip moves a
## node it would turn (an object animation: left as authored). The yaw it turned, or 0: none of the other 30 library animals,
## the Rig Lab's five, nor any person (the head over the neck).
const FACE_ACROSS := 2.0
const FACE_MIN := 0.02
static var faced := 0           # models turned onto +Z, ever (the drive rig's census of the library: the wasp, once a model)
static func face(scene: Node3D) -> float:
	var sk := GPose.skeleton_of(scene) if scene != null else null
	if sk == null or sk.get_bone_count() < 2:
		return 0.0
	var xf := GPose.xf_to(sk, scene)
	var head := -1
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for b in sk.get_bone_count():
		var p := xf * sk.get_bone_global_rest(b).origin
		lo = lo.min(p)
		hi = hi.max(p)
		var r := read_name(sk.get_bone_name(b))
		if head < 0 and String(r["slot"]) == "head" and not bool(r["skip"]):
			head = b
	var par := sk.get_bone_parent(head) if head >= 0 else -1
	if par < 0:
		return 0.0
	var hp := xf * sk.get_bone_global_rest(head).origin
	var d := hp - xf * sk.get_bone_global_rest(par).origin
	var span := hi - lo
	if absf(d.x) < FACE_ACROSS * absf(d.z) or absf(d.x) < FACE_MIN * span.y or span.x <= span.z \
			or signf(hp.x - (lo.x + hi.x) * 0.5) != signf(d.x):
		return 0.0
	var turn: Array[Node3D] = []
	for c in scene.get_children():
		if c is Node3D:
			turn.append(c as Node3D)
	for ap: AnimationPlayer in scene.find_children("*", "AnimationPlayer", true, false):
		var aroot := ap.get_node_or_null(ap.root_node)
		if aroot == null:
			continue
		for ln in ap.get_animation_library_list():
			var lib := ap.get_animation_library(ln)
			for an in lib.get_animation_list():
				var a := lib.get_animation(an)
				for tr in a.get_track_count():
					var path := a.track_get_path(tr)
					if path.get_subname_count() > 0 and a.track_get_type(tr) != Animation.TYPE_VALUE:
						continue   # a bone's track: the skeleton turns with its node
					if turn.has(aroot.get_node_or_null(NodePath(path.get_concatenated_names()))):
						return 0.0
	var yaw := -PI * 0.5 * signf(d.x)   # the head's end of x onto +z
	for c in turn:
		c.transform = Transform3D(Basis(Vector3.UP, yaw), Vector3.ZERO) * c.transform
	faced += 1
	return yaw


## THE WARM, A PIECE AT A TIME — what AreaBuilder's drains and main._fetch_glb_scene work a parsed GLB through inside the
## frame's budget (step(deadline): pieces until Time.get_ticks_usec() passes `deadline`, at least one; true when done): turned
## to face +Z (face), its map resolved (Resolve) and held by the model, its forest re-parented, each clip looked at and the
## ones that move a re-parented root rebased where they are (Rebase) — the source is cached only once it is done, so every
## duplicate of it is born repaired and plays the rebased clips. A piece is a mesh surface, a join, a clip looked at, a key
## time: 0.01-1 ms on a desktop.
class Warm extends RefCounted:
	var scene: Node3D
	var map := {}
	var pieces := 0                    # pieces worked (the people rig bounds what one costs: RIGS (k))
	var _sk: Skeleton3D = null
	var _key := ""
	var _res: Resource = null
	var _rs: GRig.Resolve = null
	var _old: Array = []               # [the old parents, the old local rests] of the skeleton re-parented here
	var _mv := {}                      # root -> new parent
	var _clips: Array = []             # [Animation, its player's root] still to look at
	var _rb: Array = []                # GRig.Rebase still working
	var _stage := 0

	func _init(s: Node) -> void:
		scene = s as Node3D

	func step(deadline: int) -> bool:
		GRig.warm_steps += 1
		var first := true
		while _stage < 5:
			if not first and Time.get_ticks_usec() > deadline:
				return false
			first = false
			pieces += 1
			match _stage:
				0:   # turned to face +Z; the skeleton, or the parts; a map the model already holds is taken as it is
					GRig.face(scene)
					_sk = GPose.skeleton_of(scene) if scene != null else null
					if _sk == null or _sk.get_bone_count() == 0:
						map = GRig._nodes_map(scene)
						_stage = 5
						continue
					var kr := GRig._keyed(_sk, scene)
					_key = kr[0]
					_res = kr[1]
					var held = GRig._memo_get(_res, _key)
					if held != null:
						map = held
						_stage = 2
					else:
						_rs = GRig.Resolve.new(_sk, scene)
						_stage = 1
				1:   # the resolve, a piece at a time
					if _rs.step():
						map = _rs.out
						GRig._memo_put(_res, _key, map)
						_rs = null
						_stage = 2
				2:   # the forest re-parented, and every clip of every player to look at
					var plan: Array = map.get("repair", [])
					if GRig._repaired(_sk, plan):
						_stage = 5
						continue
					_old = GRig._reparent(_sk, plan)
					_mv = GRig._moved(plan)
					for ap: AnimationPlayer in scene.find_children("*", "AnimationPlayer", true, false):
						var aroot := ap.get_node_or_null(ap.root_node)
						if aroot == null:
							continue
						for lname in ap.get_animation_library_list():
							var lib := ap.get_animation_library(lname)
							for an_name in lib.get_animation_list():
								_clips.append([lib.get_animation(an_name), aroot])
					_stage = 3
				3:   # one clip looked at: rebased in place (this source is every later copy's) when it moves a root
					if _clips.is_empty():
						_stage = 4
						continue
					var c: Array = _clips.pop_front()
					var rb := GRig.Rebase.new(c[0], _sk, c[1], _mv, _old[0], _old[1])
					if rb.hits:
						_rb.append(rb)
				4:   # a piece of the first clip still rebasing
					if _rb.is_empty():
						_stage = 5
						continue
					if (_rb[0] as GRig.Rebase).step():
						_rb.pop_front()
						GRig.rebased += 1
		_res = null                    # done: nothing of the model held past its warm (its map lives on its own skin)
		_old = []
		return true


# -------------------------------------------------------------------------------------------------- the part rig

# A HUMANOID MADE OF PARTS (Kenney's blocky characters): no Skeleton3D, a node per body part, animated by node tracks.
# The same names (read_name) and the same checks: a head above a torso, two legs to the floor on opposite sides, arms
# beside the torso. Slots are the parts' NAMES ("" for none) — found under whatever holds the model (part()), because the
# map is shared by every copy and a hero's model sits under the player.
static func _nodes_map(model: Node3D) -> Dictionary:
	if model == null:
		return {}
	var ids := PackedStringArray()
	var res: Resource = null
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh != null:
			ids.append(str(mi.mesh.get_instance_id()))
			if res == null:
				res = mi.mesh
	if ids.is_empty():
		return {}
	var key := "nodes:" + ",".join(ids)
	var held = _memo_get(res, key)
	if held != null:
		return held
	var parts: Array = []
	for n in model.find_children("*", "Node3D", true, false):
		var r := read_name(String(n.name))
		if r["slot"] != "" and not r["skip"]:
			parts.append(n)
	if parts.size() < 4:
		_memo_put(res, key, {})   # a prop: held by its own mesh, gone with it — populate places one with no name read
		return {}
	measures += 1
	var out := {"kind": "nodes", "person": false, "pelvis": false, "tilt": -1.0, "source": "names", "repair": [],
		"body": "unknown", "hips": "", "head": "", "spine": [], "chest": "", "neck": "",
		"arm_l": {}, "arm_r": {}, "leg_l": {}, "leg_r": {}}
	var box := {}
	var lo := INF
	var hi := -INF
	for p in parts:
		var ab := _part_box(p as Node3D, model)
		box[p] = ab
		lo = minf(lo, ab.position.y)
		hi = maxf(hi, ab.end.y)
	var H := hi - lo
	var pick := func(slot: String, side: String) -> Node3D:
		for p in parts:
			var r := read_name(String((p as Node).name))
			if (slot in (r["slots"] as Array)) and r["side"] == side:
				return p
		return null
	var head: Node3D = pick.call("head", "")
	var torso: Node3D = pick.call("spine", "")
	if torso == null:
		torso = pick.call("chest", "")
	var legs := {}
	var arms := {}
	for s in ["L", "R"]:
		var lg: Node3D = pick.call("thigh", s)
		if lg != null and (box[lg] as AABB).position.y <= lo + FLOOR_BAND * H:
			legs[s] = lg
		var am: Node3D = pick.call("upper", s)
		if am != null:
			arms[s] = am
	if head == null or torso == null or legs.size() < 2 or H <= 0.0:
		_memo_put(res, key, out)
		return out
	var hb: AABB = box[head]
	var tb: AABB = box[torso]
	if hb.get_center().y <= tb.get_center().y:
		_memo_put(res, key, out)
		return out
	var lc := ((box[legs["L"]] as AABB).get_center() + (box[legs["R"]] as AABB).get_center()) * 0.5
	var tilt := rad_to_deg(Vector3.UP.angle_to(hb.get_center() - Vector3(lc.x, tb.position.y, lc.z)))
	if tilt > PERSON_TILT_DEG:
		_memo_put(res, key, out)
		return out
	out["person"] = true
	out["tilt"] = tilt
	out["body"] = "person"
	out["head"] = String(head.name)
	out["spine"] = [String(torso.name)]
	out["chest"] = String(torso.name)
	for s in ["L", "R"]:
		out["leg_" + s.to_lower()] = {"thigh": String((legs[s] as Node).name), "shin": "", "foot": "", "toe": ""}
		if arms.has(s):
			out["arm_" + s.to_lower()] = {"clavicle": "", "upper": String((arms[s] as Node).name), "fore": "", "hand": ""}
	_memo_put(res, key, out)
	return out


## The part `name` a part rig's map gives, under `model` (null: none).
static func part(model: Node, name: String) -> Node3D:
	if model == null or name == "":
		return null
	return model.find_child(name, true, false) as Node3D


## Where a part rig's hand is: the end of the arm part's drawn extent farthest from where it hangs (its node's origin,
## the shoulder), in the arm part's own frame. A blocky arm hangs straight down, so this is its bottom face's centre.
static func part_hand(arm: Node3D) -> Vector3:
	var ab := AABB()
	var first := true
	var meshes: Array = arm.find_children("*", "MeshInstance3D", true, false)
	if arm is MeshInstance3D:
		meshes.push_front(arm)
	for mi in meshes:
		if (mi as MeshInstance3D).mesh == null:
			continue
		var b: AABB = GPose.xf_to(mi as Node, arm) * (mi as MeshInstance3D).get_aabb()
		ab = b if first else ab.merge(b)
		first = false
	if first:
		return Vector3.ZERO
	var ax := 0
	for k in 3:
		if ab.size[k] > ab.size[ax]:
			ax = k
	var c := ab.get_center()
	var a := ab.position[ax]
	var b2 := ab.end[ax]
	c[ax] = a if absf(a) > absf(b2) else b2
	return c


static func _part_box(p: Node3D, top: Node3D) -> AABB:
	var ab := AABB()
	var first := true
	var xf := GPose.xf_to(p, top)
	if p is MeshInstance3D and (p as MeshInstance3D).mesh != null:
		ab = xf * (p as MeshInstance3D).get_aabb()
		first = false
	if first:
		ab = AABB(xf.origin, Vector3.ZERO)
	return ab


# ---------------------------------------------------------------------------------------------------------- helpers

# The model's key — the meshes and skins skinned to `skel` under `top` (what every duplicate of a cached GLB shares) and
# the bone count — and the resource that holds its map, the first of those skins: [key, Resource]. ["", null] when no
# mesh binds it: a bare skeleton is resolved where it is asked for.
static func _keyed(skel: Skeleton3D, top: Node3D) -> Array:
	var ids := PackedStringArray()
	var res: Resource = null
	for mi: MeshInstance3D in top.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh != null and mi.skin != null and not mi.skeleton.is_empty() and mi.get_node_or_null(mi.skeleton) == skel:
			ids.append(GPose._mesh_key(mi))
			if res == null:
				res = mi.skin
	if ids.is_empty():
		return ["", null]
	return [",".join(ids) + "#%d" % skel.get_bone_count(), res]


## A MAP HELD BY THE MODEL IT MAPS: a Memo in the meta of a resource every duplicate of the model shares and nothing else
## does (its first skin; a part rig's first mesh), so the map lives exactly as long as the model — its cached source, its
## placed copies, a hero, a peer — and needs no table to forget it. memo_live counts the ones alive.
class Memo extends RefCounted:
	var map := {}

	func _init(m: Dictionary) -> void:
		map = m
		GRig.memo_live += 1

	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE:
			GRig.memo_live -= 1


static func _memo_get(res: Resource, key: String) -> Variant:
	if res == null or key == "":
		return null
	var held = (res.get_meta(META_MAP, {}) as Dictionary).get(key)
	return (held as Memo).map if held is Memo else null


static func _memo_put(res: Resource, key: String, m: Dictionary) -> void:
	if res == null or key == "":
		return
	var d: Dictionary = res.get_meta(META_MAP, {})
	d[key] = Memo.new(m)
	res.set_meta(META_MAP, d)


# THE BONES THE SKIN USES, A SURFACE A PIECE — weighted over 0.01 by a sampled vertex of a mesh skinned to the skeleton (all
# of them when no mesh is: an IK target, an "_end" marker, a control, a root at the floor carry no flesh and are no body
# part) — and how high each one's flesh goes (`top`): the top of the rest vertices it moves most (a KayKit skull is 1 m of
# head on a 2 cm neck joint, and a bone's origin says nothing of it). step(): one surface; true when both are read.
class Weighted extends RefCounted:
	var used := PackedByteArray()
	var top := PackedFloat32Array()
	var pts := PackedVector3Array()  # A CREATURE'S LEGS (sample(): after the verdict, a person's never) — its sampled rest
	var dom := PackedInt32Array()    # vertices skinned in the model frame, the bone that carries each most, and where each is
	var at := PackedInt32Array()     # (its surface in _arrs, its vertex: two a sample), so a sole's influences are read back
	                                 # for it alone (influences)
	var _units: Array = []      # [MeshInstance3D, surface, bone of each bind, each bind's rest matrix in the model frame, its bind]
	var _arrs: Array = []       # each surface read: [V, B, Wt, influences a vertex, its unit] — the arrays held, not copied
	var _k := 0
	var _s := 0                 # the next surface sample() reads

	func _init(skel: Skeleton3D, topn: Node3D, M: Transform3D, n: int) -> void:
		used.resize(n)
		top.resize(n)
		top.fill(-INF)
		for mi: MeshInstance3D in topn.find_children("*", "MeshInstance3D", true, false):
			if mi.mesh == null or mi.skin == null or mi.skeleton.is_empty() or mi.get_node_or_null(mi.skeleton) != skel:
				continue
			var b2b := PackedInt32Array()
			var mats: Array[Transform3D] = []
			var binds: Array[Transform3D] = []
			for b in mi.skin.get_bind_count():
				var bi := mi.skin.get_bind_bone(b)
				if bi < 0:
					bi = skel.find_bone(String(mi.skin.get_bind_name(b)))
				b2b.append(bi)
				binds.append(mi.skin.get_bind_pose(b))
				mats.append(M * (skel.get_bone_global_rest(bi) if bi >= 0 else Transform3D.IDENTITY) * binds[b])
			for s in mi.mesh.get_surface_count():
				_units.append([mi, s, b2b, mats, binds])
			if mi.mesh.get_surface_count() == 0:
				_units.append([mi, -1, b2b, mats, binds])
		if _units.is_empty():
			used.fill(1)

	func step() -> bool:
		if _k >= _units.size():
			return true
		var u: Array = _units[_k]
		_k += 1
		var mi: MeshInstance3D = u[0]
		var b2b: PackedInt32Array = u[2]
		var mats: Array[Transform3D] = u[3]
		if int(u[1]) < 0:
			return _k >= _units.size()
		var arr := GPose.surface_arrays(mi.mesh, int(u[1]))
		GRig.surface_reads += 1
		if arr.size() <= Mesh.ARRAY_WEIGHTS or arr[Mesh.ARRAY_BONES] == null or arr[Mesh.ARRAY_WEIGHTS] == null:
			return _k >= _units.size()
		var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		if V.is_empty():
			return _k >= _units.size()
		var B: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var Wt: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var k := int(B.size() / V.size())
		_arrs.append([V, B, Wt, k, u])
		var stride := maxi(1, ceili(float(V.size()) / float(GRig.WEIGHT_SAMPLES)))
		for i in range(0, V.size(), stride):
			var dom := -1
			var dw := 0.01
			for j in k:
				var w := Wt[i * k + j]
				if w > 0.01:
					var bb := B[i * k + j]
					if bb < b2b.size() and b2b[bb] >= 0:
						used[b2b[bb]] = 1
						if w > dw:
							dw = w
							dom = bb
			if dom >= 0:
				var y := (mats[dom] * V[i]).y
				if y > top[b2b[dom]]:
					top[b2b[dom]] = y
		return _k >= _units.size()

	## A CREATURE'S SAMPLES, one surface a call (the legs': Resolve's third stage, never a person's) — the same vertices step()
	## read, each skinned at rest over the influences it has (a weight over 0.01), true when every surface is read.
	func sample() -> bool:
		if _s >= _arrs.size():
			return true
		var a: Array = _arrs[_s]
		var si := _s
		_s += 1
		var V: PackedVector3Array = a[0]
		var B: PackedInt32Array = a[1]
		var Wt: PackedFloat32Array = a[2]
		var k: int = a[3]
		var b2b: PackedInt32Array = a[4][2]
		var mats: Array[Transform3D] = a[4][3]
		var stride := maxi(1, ceili(float(V.size()) / float(GRig.WEIGHT_SAMPLES)))
		var before := pts.size()
		for i in range(0, V.size(), stride):
			var dm := -1
			var dw := 0.01
			var acc := Vector3.ZERO
			var ws := 0.0
			for j in k:
				var w := Wt[i * k + j]
				if w > 0.01:
					var bb := B[i * k + j]
					if bb < b2b.size() and b2b[bb] >= 0:
						acc += (mats[bb] * V[i]) * w
						ws += w
						if w > dw:
							dw = w
							dm = bb
			if dm >= 0:
				pts.append(acc / ws)
				dom.append(b2b[dm])
				at.append(si)
				at.append(i)
		GRig.leg_samples += pts.size() - before
		return _s >= _arrs.size()

	## What draws sample `x` (pts' index): [its bones, their weights (summing to 1), the vertex in each one's frame (bind *
	## vertex)] — read back from its surface for a foot's sole alone (GRig._soles).
	func influences(x: int) -> Array:
		var a: Array = _arrs[at[x * 2]]
		var i := at[x * 2 + 1]
		var V: PackedVector3Array = a[0]
		var B: PackedInt32Array = a[1]
		var Wt: PackedFloat32Array = a[2]
		var k: int = a[3]
		var b2b: PackedInt32Array = a[4][2]
		var binds: Array[Transform3D] = a[4][4]
		var bo := PackedInt32Array()
		var w := PackedFloat32Array()
		var l := PackedVector3Array()
		var ws := 0.0
		for j in k:
			var wj := Wt[i * k + j]
			if wj > 0.01:
				var bb := B[i * k + j]
				if bb < b2b.size() and b2b[bb] >= 0:
					bo.append(b2b[bb])
					w.append(wj)
					l.append(binds[bb] * V[i])
					ws += wj
		for j in w.size():
			w[j] /= ws
		GRig.sole_influences += w.size()
		return [bo, w, l]


# each bone's children in `sk`'s own hierarchy
static func _children(sk: Skeleton3D) -> Dictionary:
	var kids := {}
	for i in sk.get_bone_count():
		var p := sk.get_bone_parent(i)
		if p >= 0:
			if not kids.has(p):
				kids[p] = []
			(kids[p] as Array).append(i)
	return kids


static func _any_in(a: Array, b: Array) -> bool:
	for x in a:
		if x in b:
			return true
	return false


static func _subtree(r: int, kids: Dictionary) -> Array:
	var out: Array = [r]
	var k := 0
	while k < out.size():
		for c in kids.get(out[k], []):
			out.append(int(c))
		k += 1
	return out


# is `a` a strict ancestor of `b`?
static func _is_anc(a: int, b: int, pr: PackedInt32Array) -> bool:
	if a < 0 or b < 0:
		return false
	var x := pr[b]
	while x >= 0:
		if x == a:
			return true
		x = pr[x]
	return false


static func _lca(a: int, b: int, pr: PackedInt32Array) -> int:
	var seen := {}
	var x := a
	while x >= 0:
		seen[x] = true
		x = pr[x]
	x = b
	while x >= 0:
		if seen.has(x):
			return x
		x = pr[x]
	return -1


# the bones from `a` down to its descendant `b`, both included ([] when b is not under a)
static func _path(a: int, b: int, pr: PackedInt32Array) -> Array:
	var out: Array = []
	var x := b
	while x >= 0 and x != a:
		out.push_front(x)
		x = pr[x]
	if x != a:
		return []
	out.push_front(a)
	return out


# the path index strictly between i0 and i1 nearest half way along its length; the bone after i0 when nothing lies
# between; -1 when i1 is i0
static func _half_way(path: Array, i0: int, i1: int, P: PackedVector3Array) -> int:
	if i1 <= i0:
		return -1
	if i1 == i0 + 1:
		return i1
	var cum := [0.0]
	for k in range(i0 + 1, i1 + 1):
		cum.append(float(cum[cum.size() - 1]) + P[path[k]].distance_to(P[path[k - 1]]))
	var half: float = float(cum[cum.size() - 1]) * 0.5
	var best := -1
	var bd := INF
	for k in range(i0 + 1, i1):
		var d := absf(float(cum[k - i0]) - half)
		if d < bd:
			bd = d
			best = k
	return best
