class_name GClip extends RefCounted
## CLIP ROLES — the ONE answer to "which of this rig's clips plays <role>?".
##
## Five places used to carry their own lookup (wander, enemy, interaction, hero_anim, the vehicle
## mount gait) and verify.mjs a sixth copy, and they disagreed in three ways:
##   - raw substrings and token PREFIXES: "soldier" contains "die", "swing" contains "wing",
##     "idle_sitting" contains "idle", "Dragon_Flying" starts with the prop word "drag";
##   - clip-order-first loops that inverted the key priority (enemy walk = "run", alphabetically);
##   - a last resort of clips[0] / the longest clip / idle, which is alphabetical order or clip
##     length leaking into the world: a smuggler that falls in the harbour looped its ATTACK, a pub
##     regular stood and walked in an invisible chair, the Rig Lab serpent ridden as a mount moved
##     in its idle (its longest clip — "slither" was no gait word).
## They guessed because "no clip" used to have no acceptable answer: every rig this stack ships
## rests in a T-pose. GPose now has one (relax / tread / a thigh stride / sit), so this can refuse.
##
## THE RULES
##  1. A clip name is split into WORD TOKENS: everything up to the last | : / is dropped
##     ("Armature|", "mixamorig:"), camelCase and letter/digit runs are split ("Layer0" -> layer 0),
##     -._ and spaces separate. A token names a family when it IS one of the family's words or a
##     regular inflection of one (walk walks walked walking; sit sitting; die dying; fly flies) —
##     whole words, never prefixes: "dragon" is not "drag", "fisher" is not "fish".
##  2. A leading word that EVERY clip on the rig shares is the rig's NAME, not an action, and is
##     dropped ("Velociraptor_Idle", "Snake_Attack") — unless it names what some role is FOR
##     ("Swim_Idle"/"Swim_Fast", "Fly_*", "Sit_Chair_*": a shared action, kept), or it is another
##     action word and what follows names fewer than two roles ("Guard_Idle/Walk/Attack" is a name).
##  3. A clip QUALIFIES for a role when a token names one of the role's own families AND no token
##     names a family the role does not allow. So a clip naming two different actions counts for
##     NEITHER: "idle_sitting" is not a standing idle, "Melee_2H_Idle" is not an ambient idle,
##     "walk_carry" is not a walk, "Sit_Chair_Down" (a transition) is not a seated loop. A role's
##     "allow" list is how it says a word MODIFIES it rather than naming a second action: a swing
##     while running or flying is still the attack ("Run_Attack", "Fly_Attack"), a death or a hit from
##     behind still the death / the hurt ("Death_Back", "Hit_Back") — a walk backwards is not the walk.
##     NEUTRAL words (loop, fwd, rm, inplace, left, a/b/c...) and words this table does not know
##     ride along on any role.
##  4. Among qualifiers: the role's first tier beats its second (walk before run for WALK), a clip
##     that also carries the role's WITH family wins (Sit_Chair_Idle over Sitting), then the word's
##     rank in its family (attack before kick), then a whole-name match before a first-word match
##     before any word, then — when both name a second word of the role's families — that word's rank
##     (attack-melee before attack-kick), then the modifier the role lists first, none before any
##     (Swim_Idle before Swim_Fast, a plain Attack before Run_Attack), then a right-side clip before
##     one naming no side before a left-side one (the weapon is in the right hand), then clip order.
##     CLIP ORDER IS THE ENGINE'S: the names are sorted first, as AnimationPlayer.get_animation_list()
##     returns them, so the answer never depends on the order a list arrives in. The census was read in
##     each GLB's own order while the engine reads its sorted list, and the last tie-break differed on
##     all 18 Kenney characters: the attack the census promised was attack-melee-right, the one the
##     game played attack-kick-left (and emote-no for emote-yes). Deterministic.
##  5. NO FALLBACK TO A CLIP THAT NAMES SOMETHING ELSE. Nothing qualifies -> "" and the caller's
##     procedural GPose path takes over. The one settle: an ANON_OK role on a rig whose SOLE clip
##     names nothing at all ("Take 001", "mixamo.com|Layer0", "Loop") — it cannot contradict a role.
## Two questions that are not roles use the same words:
##  - named(): a clip asked for BY NAME (an emote, "climb", "work") — the word itself or a regular
##    inflection of it, never a prefix; a clip that is only that word before one that adds to it, as
##    in rule 4. NAMED holds what each such request may be spelled as.
##  - needs_seat(): does an authored activity sit its NPC ON A SEAT? CHAIR words do; the rest of the
##    seat family (kneel, lie, sleep, prone) and a sit that names the FLOOR are played on the floor.
##
## verify.mjs carries a JS mirror of this file between its GCLIP markers, and
## functions/scripts/check-clip-vocab.mjs fails a deploy when the two tables differ or when either
## implementation disagrees with the library census (verify/people/clip-census.json).

## Families of words. A clip belongs to every family one of its tokens names (whole word or a
## regular inflection — see _forms). Order inside a family is RANK: earlier words win ties.
const FAMILIES := {
	"idle": ["idle", "stand", "breathe", "breath", "wait", "rest", "relax", "talk", "look", "survey"],
	"walk": ["walk", "stroll", "amble", "wander", "move", "patrol", "trot", "canter", "slither"],
	"run": ["run", "sprint", "jog", "gallop", "skitter", "scurry", "ran"],
	"swim": ["swim", "tread", "paddle", "float", "swam", "swum"],
	"fly": ["fly", "flap", "hover", "flutter", "flight", "wing", "flew", "flown"],
	"glide": ["glide", "soar"],
	"air": ["jump", "leap", "hop", "takeoff", "fall", "dive", "airborne", "fell", "fallen"],
	"attack": ["attack", "melee", "strike", "swing", "slash", "stab", "punch", "kick", "bite", "headbutt",
		"claw", "smash", "bash", "scratch", "sting", "lunge", "pounce", "maul", "fight", "combat",
		"struck", "swung", "bitten", "fought"],
	"ranged": ["ranged", "shoot", "fire", "aim", "throw", "reload", "cast", "spell", "spellcast",
		"shot", "threw", "thrown"],
	"defend": ["block", "parry", "guard", "dodge", "dash", "evade", "shield"],
	"hurt": ["hit", "hurt", "flinch", "pain", "damage", "impact", "stagger", "knock", "knockback",
		"recoil"],
	"death": ["death", "die", "dead", "defeat", "collapse", "faint", "perish"],
	"seat": ["sit", "seat", "kneel", "lie", "lay", "sleep", "prone", "sat", "knelt", "slept"],
	"emote": ["emote", "dance", "boogie", "wave", "cheer", "taunt", "roar", "greet", "hello", "clap",
		"salute", "celebrate", "hiss", "threat", "laugh", "point", "victory", "applaud", "nod", "shrug",
		"pray", "flex"],
	"prop": ["lift", "carry", "haul", "pull", "push", "drag", "dig", "hammer", "saw", "mine", "pick",
		"pickaxe", "fishing", "row", "pour", "drink", "eat", "cook", "write", "sweep", "clean", "plant",
		"harvest", "hold", "use", "craft", "repair", "build", "interact", "feed", "groom",
		"lockpick", "consume", "open", "mend", "wash", "held", "dug", "fed", "ate", "built"],
	"action": ["rear", "coil", "constrict", "tail", "climb", "turn", "roll", "curl", "flick", "whip",
		"slide", "crawl", "crouch", "squat", "sneak", "drive", "wheelchair", "hood"],
	"strafe": ["back", "backward", "backwards", "strafe", "sideways", "sidestep", "reverse"],
	"transition": ["down", "getup", "standup", "wakeup", "start", "begin", "end", "stop", "finish",
		"exit", "enter", "spawn", "awaken", "rise", "resurrect", "land", "transition"],
}
## Families matched by the WHOLE TOKEN only, never inflected (a pose name, a function word). A clip that
## says NO is a refusal, not the gesture a role asks for (Kenney's "emote-no" beside "emote-yes").
const EXACT := {
	"negation": ["no", "not"],
	"pose": ["pose", "tpose", "apose", "bind", "bindpose", "reference", "static"],
	"transition": ["to", "into", "from", "up", "ups"],
	"run": ["fast"],
}
## Words that modify a clip without naming an action: they ride along on any role, and a name made
## of nothing else (plus ANON_TOKENS and digits) is anonymous.
const NEUTRAL := ["loop", "looped", "looping", "fwd", "forward", "forwards", "rm", "inplace", "in",
	"place", "cycle", "root", "left", "right", "l", "r", "a", "b", "c", "d", "alt", "var", "variant",
	"v", "full", "short", "long", "slow", "normal", "basic", "simple", "h"]
## Exporter boilerplate — names that say nothing about the motion.
const ANON_TOKENS := ["take", "anim", "animation", "anims", "clip", "default", "mixamo", "com",
	"armature", "scene", "baselayer", "layer", "motion", "track", "action", "unnamed", "rig",
	"sequence", "seq", "export", "none"]
## role -> tiers of the families it is FOR (tier 1 beats tier 2), the families that may ride along
## as modifiers ("allow"), and an optional WITH family a qualifier is preferred to carry.
## Anything else named on the clip disqualifies it.
const ROLES := {
	"idle": {"tiers": [["idle"]], "allow": [], "with": ""},
	"walk": {"tiers": [["walk"], ["run"]], "allow": [], "with": ""},
	"run": {"tiers": [["run"], ["walk"]], "allow": [], "with": ""},
	"swim": {"tiers": [["swim"]], "allow": ["idle", "walk", "run"], "with": ""},
	"fly": {"tiers": [["fly"], ["glide"]], "allow": ["idle", "walk", "run"], "with": ""},
	"glide": {"tiers": [["glide"], ["fly"]], "allow": ["idle"], "with": ""},
	"jump": {"tiers": [["air"]], "allow": ["walk", "run"], "with": ""},
	"fall": {"tiers": [["air"]], "allow": ["idle"], "with": ""},
	"attack": {"tiers": [["attack"]], "allow": ["walk", "run", "air", "swim", "fly", "glide"], "with": ""},
	"hurt": {"tiers": [["hurt"]], "allow": ["strafe"], "with": ""},
	"death": {"tiers": [["death"]], "allow": ["strafe"], "with": ""},
	"sit": {"tiers": [["seat"]], "allow": ["idle"], "with": "idle"},
	"emote": {"tiers": [["emote"]], "allow": ["idle", "seat"], "with": ""},
}
## Per-role word subsets where a role is narrower than its family (a jump is not a fall).
const ROLE_KEYS := {
	"jump": ["jump", "leap", "hop", "takeoff"],
	"fall": ["fall", "airborne", "fell", "fallen"],
}
## Roles that may settle for a rig's lone anonymous clip (rule 5).
const ANON_OK := ["idle"]
## The seat-family words that need a SEAT under the character (a chair, a bench, a stool) — and the
## words that put a sit on the floor instead ("Sit_Floor_Idle", "sitting_ground"). See needs_seat.
const CHAIR := ["sit", "seat", "sat"]
const FLOOR := ["floor", "ground"]
## What a request BY NAME may be spelled as (hero_anim's emote kinds, rules `emote`): the kind -> the
## words that answer it, in rank order. A kind not listed answers to its own word. See named().
const NAMED := {
	"dance": ["dance", "boogie"],
	"wave": ["wave", "greet", "hello", "salute"],
	"talk": ["talk", "speak", "conversation", "converse", "chat"],
	"cheer": ["cheer", "celebrate", "celebration", "victory", "applaud", "applause", "clap"],
	"crouch": ["crouch", "crawl", "sneak", "duck"],
	"climb": ["climb", "ladder"],
	"work": ["work", "hammer", "mine", "chop", "craft", "dig"],
}

static var _fam_of := {}     # token -> Array of family names (built once from the tables)
static var _key_of := {}     # token -> Dictionary word -> true (every word this token is a form of)
static var _memo := {}       # pick() answers by (clip list, role, prefer, strict) — see pick
static var resolves := 0     # picks worked out (_pick), not looked up: counted where the work is, so a pick that works its answer
                             # out before it asks the memo counts too (the people rig: a repeat pick is none)


## The clip that plays `role` on `ap`, or "" (the caller's procedural path owns that role).
## `prefer` puts words of the role's own families first (a mount's fast gait is a gallop before a
## run) — it reorders qualifiers, it never admits a clip the role's rules reject. `strict` takes the
## role's first tier only (verify's "the hero has a RUN clip", which a walk must not satisfy).
static func resolve(ap: AnimationPlayer, role: String, prefer: Array = [], strict := false) -> String:
	if ap == null or not is_instance_valid(ap):
		return ""
	return pick(ap.get_animation_list(), role, prefer, strict)


## The same decision over a bare name list (verify.mjs mirrors exactly this function).
##
## MEMOIZED: the answer depends on these four arguments and nothing else, and one pick costs 40-700 us
## on a native desktop (6 to 43 clips; more on the web) — asked 4-8 times for every crowd agent and
## enemy that streams in, per duplicate of the same GLB, and by hero_anim on every frame of a swim.
static func pick(clips: PackedStringArray, role: String, prefer: Array = [], strict := false) -> String:
	var sorted := clips.duplicate()
	sorted.sort()                         # the engine's order (get_animation_list), whatever order these came in
	var key := "%s\t%s\t%s\t%s" % ["\n".join(sorted), role, str(prefer), strict]
	if _memo.has(key):
		return _memo[key]
	if _memo.size() >= 4096:
		_memo.clear()                     # a bound, not a policy: a real game has tens of rigs
	var got := _pick(sorted, role, prefer, strict)
	_memo[key] = got
	return got


static func _pick(clips: PackedStringArray, role: String, prefer: Array, strict: bool) -> String:
	resolves += 1
	var spec: Dictionary = ROLES.get(role, {})
	if spec.is_empty() or clips.is_empty():
		return ""
	var tiers: Array = spec["tiers"]
	var allowed: Array = []
	for tier in tiers:
		allowed.append_array(tier)
	allowed.append_array(spec["allow"])
	if strict:
		tiers = [tiers[0]]
	var all: Array = []
	for c in clips:
		all.append(tokens(String(c)))
	all = _drop_name(all)
	var best := ""
	var best_score := []
	for ci in clips.size():
		var toks: PackedStringArray = all[ci]
		var fams := families_of(toks)
		var bad := false
		for f in fams:
			if not (f in allowed):
				bad = true
				break
		if bad:
			continue
		for ti in tiers.size():
			var hit := _key_hit(toks, tiers[ti], role, prefer)
			if hit.is_empty():
				continue
			var with_f := String(spec["with"])
			var mod := -1                 # the role's first-listed modifier this clip names (-1: none)
			for f in fams:
				var k: int = (spec["allow"] as Array).find(f)
				if k >= 0 and (mod < 0 or k < mod):
					mod = k
			var side := 1
			if "right" in toks or "r" in toks:
				side = 0
			elif "left" in toks or "l" in toks:
				side = 2
			var score := [ti, 0 if (with_f == "" or with_f in fams) else 1, hit["key"], hit["rank"], hit["next"], mod, side, ci]
			if best_score.is_empty() or _less(score, best_score):
				best_score = score
				best = String(clips[ci])
			break
	if best == "" and role in ANON_OK and clips.size() == 1 and is_anonymous(String(clips[0])):
		return String(clips[0])
	return best


## A clip asked for BY NAME rather than by role — an emote or a named action (rules `emote`,
## hero_anim.action: "dance", "climb", "work"): the first of the kind's NAMED words that some clip
## names, as the word itself or a regular inflection ("Dancing", "Chopping"). Never a prefix:
## "Cheerleader_Jump" is not a cheer and "Minecart_Ride" is not work. No conflict rule — the caller
## asked for exactly that word. "" when no clip names any of them.
static func named(clips: PackedStringArray, kind: String) -> String:
	var sorted := clips.duplicate()
	sorted.sort()
	for w in NAMED.get(kind, [kind]):
		var forms := _forms(String(w), true)
		var best := ""
		var best_rank := 9
		for c in sorted:
			var toks := tokens(String(c))
			for ti in toks.size():
				if toks[ti] in forms:
					var rank := 0 if toks.size() == 1 else (1 if ti == 0 else 2)
					if rank < best_rank:
						best_rank = rank
						best = String(c)
					break
		if best != "":
			return best
	return ""


## A MOUNT'S GAITS — which of a ridden creature's clips it plays in each state: walk (walk / trot / canter /
## slither; a run when that is all it has), fast (a run, a gallop preferred), idle, flap (fly) and glide, and `any`:
## the LONGEST ANONYMOUS clip ("Take 001", "mixamo.com|Layer0"), the move fallback, so a rig whose only clips are
## unnamed still rides animated. A clip that names another action (death, attack, jump, alert...) is never a gait,
## however long: the longest-clip rule rode the Rig Lab serpent in "idle" (slither was no gait word) and handed
## smuggler_melee cast as a horse "death". "" = the state has no clip, and the mount shows its rest pose there.
## ONE lookup for the two that must agree on it (2026-10-04): Vehicle, which plays these (_update_gait), and the
## mount's body, fitted over exactly what it plays (gait_clips: GBody's mount roles, at parse and at setup alike).
static func gaits(ap: AnimationPlayer) -> Dictionary:
	var g := {"walk": "", "fast": "", "idle": "", "flap": "", "glide": "", "any": ""}
	if ap == null or not is_instance_valid(ap):
		return g
	g["walk"] = resolve(ap, "walk")
	g["fast"] = resolve(ap, "run", ["gallop"])
	g["idle"] = resolve(ap, "idle")
	g["flap"] = resolve(ap, "fly")
	g["glide"] = resolve(ap, "glide")
	var best_len := -1.0
	for c in ap.get_animation_list():
		if not is_anonymous(String(c)):
			continue
		var a := ap.get_animation(String(c))
		if a != null and a.length > best_len:
			best_len = a.length
			g["any"] = String(c)
	return g


## The clips a mount SHOWS in one locomotion state, as Vehicle._update_gait plays them: on the ground its idle, walk
## and fast (`any` when it has neither move clip), in the air its flap and glide (`any` when it has neither). What its
## body in that state is fitted over — a flyer's wingbeat is no part of the body it walks in (a parked monster_Bat's
## box held 6.60 m of air behind its tail when one box covered both, mount-hulls review).
static func gait_clips(ap: AnimationPlayer, air: bool) -> PackedStringArray:
	var g := gaits(ap)
	var out := PackedStringArray()
	var keys := ["flap", "glide"] if air else ["idle", "walk", "fast"]
	for k in keys:
		if g[k] != "" and not out.has(g[k]):
			out.append(g[k])
	var moves := ["flap", "glide"] if air else ["walk", "fast"]
	if g[moves[0]] == "" and g[moves[1]] == "" and g["any"] != "" and not out.has(g["any"]):
		out.append(g["any"])
	return out


## Does this name — an authored `activity` — sit the character ON A SEAT? A CHAIR word ("sit",
## "sitting", "seated", "sat") and no FLOOR word. The seat family's other words are postures on the
## floor ("kneel", "lie", "sleep", "prone"), and so is "Sit_Floor_Idle": interaction.gd looks for a
## seat for these only, and verify.mjs's casting gate asks the same question.
static func needs_seat(name: String) -> bool:
	_index()
	var chair := false
	for t in tokens(name):
		if t in FLOOR:
			return false
		for w in CHAIR:
			if (_key_of.get(t, {}) as Dictionary).has(w):
				chair = true
	return chair


## "Take 001", "mixamo.com|Layer0", "Loop" — a name that says nothing about what the clip does.
static func is_anonymous(clip: String) -> bool:
	for t in tokens(clip):
		if not (t in ANON_TOKENS or t in NEUTRAL or t.is_valid_int()):
			return false
	return true


## Word tokens of a clip name: prefix path dropped, camelCase and letter/digit runs split, lowercased.
static func tokens(clip: String) -> PackedStringArray:
	var s := clip
	for sep in ["|", ":", "/"]:
		var k := s.rfind(sep)
		if k >= 0:
			s = s.substr(k + 1)
	var out := ""
	for i in s.length():
		var ch := s[i]
		if i > 0:
			var pv := s[i - 1]
			var nx := s[i + 1] if i + 1 < s.length() else ""
			var split := false
			if _up(ch) and (_low(pv) or _dig(pv)):
				split = true                              # walkFast, 2Hand
			elif _up(ch) and _up(pv) and nx != "" and _low(nx):
				split = true                              # TPose -> T Pose, HTTPServer -> HTTP Server
			elif _dig(ch) and (_low(pv) or _up(pv)):
				split = true                              # Layer0 -> Layer 0
			elif _low(ch) and _dig(pv):
				split = true                              # 1m -> 1 m
			if split:
				out += "_"
		out += ch
	out = out.to_lower().replace("-", "_").replace(".", "_").replace(" ", "_")
	return out.split("_", false)


## Every family any of `toks` names.
static func families_of(toks: PackedStringArray) -> Array:
	_index()
	var out: Array = []
	for t in toks:
		for f in _fam_of.get(t, []):
			if not (f in out):
				out.append(f)
	return out


## The word forms that count as `w`: the word, and — for FAMILIES words — its regular inflections.
## Over-generation is harmless ("walkes" is no clip name); under-generation is what rule 1 fixes.
static func _forms(w: String, inflect: bool) -> PackedStringArray:
	var out := PackedStringArray([w])
	if not inflect:
		return out
	for suf in ["s", "es", "d", "ed", "ing"]:
		out.append(w + suf)
	var last := w.substr(w.length() - 1)
	if w.ends_with("ie"):
		out.append(w.substr(0, w.length() - 2) + "ying")          # die -> dying, lie -> lying
	if w.ends_with("e"):
		out.append(w.substr(0, w.length() - 1) + "ing")           # glide -> gliding, strike -> striking
	if w.ends_with("y"):
		out.append(w.substr(0, w.length() - 1) + "ies")           # fly -> flies
		out.append(w.substr(0, w.length() - 1) + "ied")
	if "bcdfghjklmnpqrstvz".contains(last):
		out.append(w + last + "ing")                              # run -> running, sit -> sitting
		out.append(w + last + "ed")                               # drag -> dragged
	return out


static func _index() -> void:
	if not _fam_of.is_empty():
		return
	for table in [FAMILIES, EXACT]:
		for f in table:
			for w in table[f]:
				for form in _forms(String(w), table == FAMILIES):
					var fl: Array = _fam_of.get(form, [])
					if not (f in fl):
						fl.append(f)
					_fam_of[form] = fl
					var kd: Dictionary = _key_of.get(form, {})
					kd[String(w)] = true
					_key_of[form] = kd


# Rule 2: drop a leading word every clip shares when it is the rig's name. Needs 2+ clips, each with
# a word after it. A word some role is FOR always stays (dropping "Swim" from [Swim_Idle, Swim_Fast]
# left an idle and a run and no swim); another action word stays unless what follows names two or
# more roles' families.
static func _drop_name(all: Array) -> Array:
	if all.size() < 2:
		return all
	var lead := ""
	for toks in all:
		if (toks as PackedStringArray).size() < 2:
			return all
		if lead == "":
			lead = String(toks[0])
		elif String(toks[0]) != lead:
			return all
	var lead_fams := families_of(PackedStringArray([lead]))
	for f in lead_fams:
		if _role_family(f):
			return all
	if not lead_fams.is_empty():
		var roles_named := {}
		for toks in all:
			for f in families_of((toks as PackedStringArray).slice(1)):
				if _role_family(f):
					roles_named[f] = true
		if roles_named.size() < 2:
			return all
	var out: Array = []
	for toks in all:
		out.append((toks as PackedStringArray).slice(1))
	return out


# A family some role is FOR (a tier family), as opposed to one that only disqualifies.
static func _role_family(f: String) -> bool:
	for r in ROLES:
		for tier in ROLES[r]["tiers"]:
			if f in tier:
				return true
	return false


# Best way `toks` hits a word of `fams` for `role`: key = the word's rank in the role's word list
# (prefer first), rank 0 = the whole name is that word, 1 = the first token, 2 = a later one, next = the
# second-best word's rank (-1: it names one). {} = none.
static func _key_hit(toks: PackedStringArray, fams: Array, role: String, prefer: Array) -> Dictionary:
	_index()
	var keys: Array = prefer.duplicate()
	if ROLE_KEYS.has(role):
		keys.append_array(ROLE_KEYS[role])
	else:
		for f in fams:
			keys.append_array(FAMILIES.get(f, []))
			keys.append_array(EXACT.get(f, []))
	var best := {}
	var hits: Array = []
	for ti in toks.size():
		var kd: Dictionary = _key_of.get(String(toks[ti]), {})
		if kd.is_empty():
			continue
		for ki in keys.size():
			if not kd.has(String(keys[ki])):
				continue
			var rank := 0 if toks.size() == 1 else (1 if ti == 0 else 2)
			if best.is_empty() or ki < int(best["key"]) or (ki == int(best["key"]) and rank < int(best["rank"])):
				best = {"key": ki, "rank": rank}
			hits.append(ki)
			break
	if not best.is_empty():
		hits.sort()
		best["next"] = hits[1] if hits.size() > 1 else -1
	return best


# Score order; the second word (index 4) counts only when both clips name one.
static func _less(a: Array, b: Array) -> bool:
	for i in a.size():
		if i == 4 and (int(a[i]) < 0 or int(b[i]) < 0):
			continue
		if a[i] != b[i]:
			return a[i] < b[i]
	return false


static func _up(ch: String) -> bool:
	return ch != ch.to_lower()


static func _low(ch: String) -> bool:
	return ch != ch.to_upper()


static func _dig(ch: String) -> bool:
	return "0123456789".contains(ch)
