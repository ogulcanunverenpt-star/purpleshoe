class_name GSurf
## SURFACE COOKBOOK — the SURFACE axis of the construction system. Turns bare geometry into a real, themed
## surface: TRIPLANAR materials (so a tiled texture never STRETCHES across a big/scaled box — the #1 "flat wall"
## bug), named civilization surfaces (sandstone/concrete/marble/…), EMISSIVE window/sign facades (so towers light
## up at night instead of going black), DECAL quads (hieroglyphs / road markings / posters / grime stamped onto a
## face), and emissive sign LIGHT-POOLS (a real OmniLight co-located with neon so the city lights ITSELF — the
## single biggest night-look miss). gl_compatibility / WebGL2-safe: no Environment glow (that's faked elsewhere),
## just self-illumination + point lights + procedural normal relief.
##
## Materials are CACHED (one per spec+palette) so a whole district shares coherent, low-overhead materials.
##
## ALBEDO CEILING — the "no near-white albedo" rule: every albedo resolved through surface()/_resolve() is
## clamped to <= 0.85 per RGB channel. Pre-fix, ACES with default tonemap_white 1.0 clipped any albedo
## >= ~0.72 to detail-free flat white at noon; 0.85 + main.gd's env.tonemap_white = 4.0 leaves real headroom
## so pale walls keep N·L shading and hue separation. ALBEDO ONLY — emission/glow colors (emissive(),
## window_facade glow, sign_light) are deliberately near-white and must stay unclamped.

# ---- Mobile VRAM: runtime texture cap for streamed GLB templates (WEB only) ----
# Streamed Meshy GLBs embed 1-2K textures that decode to UNCOMPRESSED RGBA in VRAM — the dominant
# mobile-OOM cost once ~GLB_CACHE_CAP templates are resident (a small index.pck is no longer the
# ceiling; decoded model textures are). On WEB, shrink every material texture in a freshly-parsed GLB
# to at most WEB_TEX_CAP px on its long edge, ONCE per template BEFORE it is cached — all .duplicate()
# instances then share the one shrunk texture, so RENDER_TEXTURE_MEM_USED (the GOGI_VRAM_MB the QA gate
# reads) drops with it. Native / editor is untouched. A shared source texture is resized once (deduped
# by identity); an already-small one is skipped. Called by area_builder (cell templates) and
# main._fetch_glb_scene (vehicles / hero).
const WEB_TEX_CAP := 320   # 512 -> 320. Halves texture memory again on top of the ETC2 re-compression
                           # below. These are stylised low-poly assets on a phone screen, where 320px on
                           # the long edge is past the point of visible difference — and video memory is
                           # the resource that actually fails on-device (iPhone freezes, Mac never does).

# ---- THE MESHY RIGGER'S MATERIAL DEFAULTS, REPAIRED ON LOAD -----------------------------------
#
# Every Meshy-RIGGED character in the library ships the same two defects, and they are the reason
# characters read as painted plastic rather than cloth and leather:
#
#   metallicFactor  ABSENT in the glTF -> the spec default is 1.0, so the character is FULLY METALLIC
#   roughnessFactor ABSENT              -> 1.0
#   emissiveFactor  [1,1,1] with emissiveTexture pointing at THE SAME IMAGE as baseColor
#                                       -> the character self-illuminates at its own albedo
#
# Measured on the shipped Ashford blacksmith and on 15 of the 15 rigged characters in the live
# library. The pre-rig asset's emissive map is pure black, so the RIGGER introduces this; it is not
# something the generation or our pipeline chose.
#
# FIXED HERE, IN THE ENGINE, AND THAT IS THE POINT — but the point is narrower than I first wrote
# it. A pipeline fix only helps characters GENERATED after it, and would leave every existing
# asset needing a re-generation and a re-rig. Doing it on load means no asset is touched: the 15
# rigged characters already in the library are repaired as they are.
#
# WHAT IT DOES NOT DO is fix a game that has already been exported. The engine is not fetched at
# runtime — sync-engine.mjs COPIES it into each game repo and it is baked into that game's export,
# so a published game carries the engine it was born with until its next build. The honest claim
# is: no asset regeneration, one re-export per game.
#
# THE FINGERPRINT IS THE ALIAS, and nothing else would do. A sword is legitimately metallic and a
# lantern is legitimately emissive, so neither of those alone can be the trigger. But an emission
# texture that IS the albedo texture is never something an artist asks for — it is only ever this
# bug. So that one test identifies a rigger output, and having identified it we can also undo the
# metallic/roughness defaults it left behind.
static func fix_rigger_materials(root: Node) -> int:
	if root == null:
		return 0
	return _fix_walk(root, {})

static func _fix_walk(node: Node, seen: Dictionary) -> int:
	var n := 0
	var mi := node as MeshInstance3D
	if mi != null:
		# All four places a material can hang. The first version read surface and
		# surface-override only; a rigger material reached through material_override or
		# material_overlay came back untouched (measured: returned 0, still metallic 1.00).
		# Godot's glTF import never populates those two, so it was latent rather than live —
		# but anything that assigns one later would have silently lost the repair.
		n += _fix_material(mi.material_override, seen)
		n += _fix_material(mi.material_overlay, seen)
		for i in mi.get_surface_override_material_count():
			n += _fix_material(mi.get_surface_override_material(i), seen)
		var mesh := mi.mesh
		if mesh != null:
			for i in mesh.get_surface_count():
				n += _fix_material(mesh.surface_get_material(i), seen)
	for c in node.get_children():
		n += _fix_walk(c, seen)
	return n

static func _fix_material(m: Material, seen: Dictionary) -> int:
	var bm := m as BaseMaterial3D
	if bm == null or seen.has(bm):
		return 0
	seen[bm] = true
	var albedo := bm.get_texture(BaseMaterial3D.TEXTURE_ALBEDO)
	var emis := bm.get_texture(BaseMaterial3D.TEXTURE_EMISSION)
	# The alias — emission is literally the albedo image. Only the rigger does this.
	if not (bm.emission_enabled and albedo != null and emis == albedo):
		return 0
	bm.emission_enabled = false
	bm.set_texture(BaseMaterial3D.TEXTURE_EMISSION, null)
	# Same material, so the metallic/roughness defaults it shipped with are the rigger's too.
	# Only touch them when there is no real map to respect.
	if bm.get_texture(BaseMaterial3D.TEXTURE_METALLIC) == null:
		bm.metallic = 0.0
	if bm.get_texture(BaseMaterial3D.TEXTURE_ROUGHNESS) == null:
		bm.roughness = 0.7    # cloth/leather/skin; a character is not a mirror and not chalk
	return 1


## ---- THE UNTEXTURED-LIBRARY REPAIR ------------------------------------------------------------
##
## A sibling of fix_rigger_materials, and the same argument in a different place.
##
## Measured on the live `vostok_extra` kit — the realistic prop set art.md sends every survival /
## coastal / modern / horror build to: 17 of 17 GLBs sampled ship `textures: 0`, `images: 0`, and
## one material whose baseColorFactor is the glTF DEFAULT [0.8, 0.8, 0.8, 1]. Not dark, not
## flat-lit: no albedo at all. So every table, crate, cabinet, sofa, pallet and mattress in the kit
## renders as the same white plastic, and a player reads it instantly as "the furniture is all
## white". A world dressed from this kit cannot look finished no matter how well it is placed.
##
## THE FINGERPRINT has to be something an artist would never author, exactly as the rigger's
## albedo-as-emission alias is. Neither half qualifies alone — a plain painted colour with no map
## is legitimate, and 0.8 grey is legitimate. Both AT ONCE on a library asset is only ever an
## export that dropped its images: nobody picks 0.800000 grey deliberately and then also ships no
## texture. That conjunction is the trigger, and nothing else is touched.
##
## WHAT REPLACES IT is a real triplanar GSurf surface chosen from the asset's own NAME — the only
## description of the object that survived the export. Scored rather than first-match, because the
## names are compounds and a single keyword lies: "MS_Fence_Wood_Pole" hits `pole` (metal) once and
## `fence`+`wood` (wood) twice, and the answer is wood. A name that scores nothing falls back to
## wood, the commonest material in a prop kit and never worse than white plastic.
##
## Same deal as the rigger repair on reach: done ON LOAD, so no asset needs regenerating, but a
## game already exported carries the engine it was born with until its next build.
const PROP_MATERIAL_HINTS := [
	["glass",   ["glass", "window", "bottle", "jar", "mirror", "pane", "vial"]],
	["fabric",  ["sofa", "couch", "armchair", "mattress", "bed", "cushion", "pillow", "curtain",
				 "rug", "carpet", "cloth", "sack", "blanket", "towel", "sleeping", "hammock"]],
	["canvas",  ["tent", "tarp", "sail", "awning", "banner", "flag", "canopy", "net"]],
	["leather", ["leather", "saddle", "boot", "belt", "satchel", "holster"]],
	["rust",    ["rust", "rusty", "wreck", "wrecked", "scrap", "junk", "derelict", "corroded"]],
	["stone",   ["stone", "rock", "brick", "fireplace", "concrete", "statue", "grave", "monument",
				 "well", "chimney", "boulder", "kerb", "curb"]],
	["plastic", ["plastic", "radio", "tv", "television", "phone", "cooler", "canister", "bin",
				 "helmet", "toy", "keyboard", "monitor"]],
	["metal",   ["metal", "steel", "iron", "barrel", "drum", "tank", "pipe", "rail", "pole",
				 "lamp", "light", "sign", "barrier", "reel", "radiator", "stove", "locker",
				 "anchor", "chain", "grate", "bucket", "kettle", "wire", "cable", "machine",
				 "generator", "engine", "gas", "propane", "antenna", "mast", "girder", "valve"]],
	["wood",    ["wood", "wooden", "timber", "plank", "crate", "pallet", "table", "chair",
				 "cabinet", "shelf", "bench", "door", "box", "log", "fence", "post", "stool",
				 "desk", "cart", "wheel", "ladder", "beam", "stair", "bookcase", "wardrobe",
				 "drawer", "frame", "barrel_wood", "pier", "jetty", "deck", "hut", "cabin"]],
]

## glTF's default baseColorFactor. Compared with a tolerance because the float round-trips.
const GLTF_DEFAULT_ALBEDO := 0.8
const GLTF_DEFAULT_EPS := 0.02


## Repair a freshly-parsed library GLB that shipped with no textures. `url` is the asset it came
## from — the filename is the best name hint there is. Returns the number of materials replaced.
static func fix_untextured_props(root: Node, url := "") -> int:
	if root == null:
		return 0
	# Mason compiles its own geometry and _mason_materials owns its surfaces by spec; repairing it
	# here first would be work thrown away and would guess where the record already knows.
	if url.find("/mason/") >= 0:
		return 0
	var hint := url.get_file().get_basename().to_lower()
	return _untex_walk(root, hint, {})


static func _untex_walk(node: Node, hint: String, seen: Dictionary) -> int:
	var n := 0
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null:
		var local := hint + " " + String(mi.name).to_lower()
		for i in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(i)
			if not _is_stripped(m, seen):
				continue
			var nm := local
			if m != null:
				nm += " " + String((m as Resource).resource_name).to_lower()
			mi.mesh.surface_set_material(i, surface(preset_for_name(nm)))
			n += 1
	for c in node.get_children():
		n += _untex_walk(c, hint, seen)
	return n


## The fingerprint: no albedo map AND the untouched glTF default grey. See the header.
static func _is_stripped(m: Material, seen: Dictionary) -> bool:
	var bm := m as BaseMaterial3D
	if bm == null:
		return false
	if seen.has(bm):
		return bool(seen[bm])
	var a := bm.albedo_color
	var stripped := (bm.get_texture(BaseMaterial3D.TEXTURE_ALBEDO) == null
		and absf(a.r - GLTF_DEFAULT_ALBEDO) < GLTF_DEFAULT_EPS
		and absf(a.g - GLTF_DEFAULT_ALBEDO) < GLTF_DEFAULT_EPS
		and absf(a.b - GLTF_DEFAULT_ALBEDO) < GLTF_DEFAULT_EPS)
	seen[bm] = stripped
	return stripped


## Best-scoring preset for a (lowercased) asset/material/node name. Public so the verifier's
## asset lint and the Interiors specialist can ask the same question the engine will answer.
static func preset_for_name(name_lc: String) -> String:
	var best := "wood"
	var best_score := 0
	for row in PROP_MATERIAL_HINTS:
		var score := 0
		for kw in (row[1] as Array):
			if name_lc.find(String(kw)) >= 0:
				score += 1
		if score > best_score:
			best_score = score
			best = String(row[0])
	return best


static func cap_textures_for_web(root: Node) -> void:
	if root == null or not OS.has_feature("web"):
		return
	_cap_walk(root, {})

static func _cap_walk(node: Node, seen: Dictionary) -> void:
	var mi := node as MeshInstance3D
	if mi != null:
		for i in mi.get_surface_override_material_count():
			_cap_material(mi.get_surface_override_material(i), seen)
		var mesh := mi.mesh
		if mesh != null:
			for i in mesh.get_surface_count():
				_cap_material(mesh.surface_get_material(i), seen)
	for c in node.get_children():
		_cap_walk(c, seen)

static func _cap_material(m: Material, seen: Dictionary) -> void:
	var bm := m as BaseMaterial3D
	if bm == null:
		return
	for slot in [
		BaseMaterial3D.TEXTURE_ALBEDO,
		BaseMaterial3D.TEXTURE_NORMAL,
		BaseMaterial3D.TEXTURE_ROUGHNESS,
		BaseMaterial3D.TEXTURE_METALLIC,
		BaseMaterial3D.TEXTURE_EMISSION,
		BaseMaterial3D.TEXTURE_AMBIENT_OCCLUSION,
	]:
		var tex := bm.get_texture(slot)
		if tex == null:
			continue
		if seen.has(tex):
			bm.set_texture(slot, seen[tex])
			continue
		var shrunk := _shrink_tex(tex)
		if shrunk != null:
			seen[tex] = shrunk
			bm.set_texture(slot, shrunk)
		else:
			seen[tex] = tex   # already small — remember so a shared ref isn't re-checked

static func _shrink_tex(tex: Texture2D) -> ImageTexture:
	var img := tex.get_image()
	if img == null:
		return null
	var mx := maxi(img.get_width(), img.get_height())
	if mx <= WEB_TEX_CAP:
		return null
	if img.is_compressed():
		img.decompress()
	var s := float(WEB_TEX_CAP) / float(mx)
	img.resize(maxi(1, roundi(img.get_width() * s)), maxi(1, roundi(img.get_height() * s)), Image.INTERPOLATE_BILINEAR)
	img.generate_mipmaps()
	# NO RUNTIME RE-COMPRESSION — it does not work in a web export, and trying is worse than useless.
	# Image.compress() needs a compressor the WEB TEMPLATE DOES NOT SHIP (they are editor-side). A
	# call here fails on every texture with `Parameter "_image_compress_etc2_func" is null` — dozens of
	# console errors per cell build, CPU burned on a copy that is then discarded, and the texture stays
	# RGBA8 regardless. It appeared to work when tested against the headless macOS EDITOR binary, which
	# does have the compressor; that test could not have caught this. Verified failing in a live web
	# build. (The project's `import_etc2_astc` setting compresses textures at IMPORT time; it cannot
	# reach GLBs that are downloaded and parsed at runtime.)
	#
	# So on web the only lever for streamed-texture memory is SIZE, which is what WEB_TEX_CAP does.
	# A native export has the compressors and could re-enable this — gate it on OS.has_feature("web")
	# being FALSE if that day comes.
	return ImageTexture.create_from_image(img)


# Named surface presets: color + roughness + metallic + normal-bump + uv tiling (units per texture repeat).
const SURFACES := {
	"sandstone": {"color": [0.80, 0.68, 0.45], "rough": 0.92, "metal": 0.0, "bump": 0.45, "tile": 4.0, "pat": "ashlar"},
	"limestone": {"color": [0.86, 0.82, 0.72], "rough": 0.88, "metal": 0.0, "bump": 0.35, "tile": 4.0, "pat": "ashlar"},
	"concrete":  {"color": [0.55, 0.55, 0.57], "rough": 0.9,  "metal": 0.0, "bump": 0.25, "tile": 4.0, "pat": "mottle"},
	"stucco":    {"color": [0.86, 0.82, 0.74], "rough": 0.95, "metal": 0.0, "bump": 0.3,  "tile": 3.0, "pat": "mottle"},
	"brick":     {"color": [0.55, 0.30, 0.24], "rough": 0.88, "metal": 0.0, "bump": 0.5,  "tile": 2.0, "pat": "brick"},
	"plaster":   {"color": [0.85, 0.83, 0.79], "rough": 0.93, "metal": 0.0, "bump": 0.2,  "tile": 4.0, "pat": "mottle"},
	"marble":    {"color": [0.86, 0.85, 0.82], "rough": 0.25, "metal": 0.0, "bump": 0.1,  "tile": 5.0, "pat": "mottle"},
	"wood":      {"color": [0.42, 0.28, 0.16], "rough": 0.7,  "metal": 0.0, "bump": 0.35, "tile": 3.0, "pat": "planks"},
	"timber":    {"color": [0.30, 0.20, 0.12], "rough": 0.75, "metal": 0.0, "bump": 0.4,  "tile": 2.5, "pat": "planks"},
	"metal":     {"color": [0.62, 0.64, 0.68], "rough": 0.35, "metal": 0.9, "bump": 0.12, "tile": 4.0, "pat": ""},
	"steel":     {"color": [0.50, 0.52, 0.56], "rough": 0.45, "metal": 0.85,"bump": 0.12, "tile": 4.0, "pat": ""},
	# GLASS IS TRANSPARENT NOW, which it was not. It was an opaque dark blue-grey panel with
	# metallic 0.5 — so a window filled with it read as a slab of dark metal, and the one material
	# whose entire point is that you see through it was the one material you could not. Nothing in
	# the surface path had ever set BaseMaterial3D.transparency (see `alpha` in _resolve/surface).
	# Metallic drops to 0: a metallic alpha surface in Godot goes to near-black.
	"glass":     {"color": [0.56, 0.68, 0.74], "rough": 0.06, "metal": 0.0, "bump": 0.0,  "tile": 6.0, "pat": "", "alpha": 0.26},
	"asphalt":   {"color": [0.12, 0.12, 0.14], "rough": 0.82, "metal": 0.0, "bump": 0.28, "tile": 6.0, "pat": "mottle"},
	"sand":      {"color": [0.80, 0.69, 0.47], "rough": 0.97, "metal": 0.0, "bump": 0.55, "tile": 5.0, "pat": "mottle"},
	"grass":     {"color": [0.30, 0.48, 0.23], "rough": 1.0,  "metal": 0.0, "bump": 0.45, "tile": 6.0, "pat": "mottle"},
	"dirt":      {"color": [0.40, 0.31, 0.22], "rough": 0.98, "metal": 0.0, "bump": 0.5,  "tile": 5.0, "pat": "mottle"},
	"thatch":    {"color": [0.66, 0.52, 0.28], "rough": 0.95, "metal": 0.0, "bump": 0.6,  "tile": 2.0, "pat": "fiber"},
	"roof_tile": {"color": [0.45, 0.22, 0.18], "rough": 0.7,  "metal": 0.0, "bump": 0.4,  "tile": 1.5, "pat": "tiles"},
	# Two names the table was missing and every masonry game reaches for. Mason's palette is
	# stone/plaster/timber/brick/slate/metal, and "stone" and "slate" both fell through to the grey
	# default — so the most common wall and the most common roof in the library were the two that
	# could not be surfaced by name.
	"stone":     {"color": [0.58, 0.56, 0.52], "rough": 0.92, "metal": 0.0, "bump": 0.5,  "tile": 3.0, "pat": "ashlar"},
	"slate":     {"color": [0.27, 0.29, 0.33], "rough": 0.62, "metal": 0.0, "bump": 0.35, "tile": 1.8, "pat": "tiles"},
	# GROUND NAMES EVERY COASTAL / OLD-TOWN WORLD REACHES FOR, and the two that were missing when a
	# cliff-town build authored 170 "rock" cells and 25 "cobble" ones: both fell through to the grey
	# mottle default, so every cliff rendered as smooth white-grey and the whole quay as a flat
	# plane. Nothing said so — see the unresolved-preset warning in _resolve.
	"rock":      {"color": [0.44, 0.43, 0.41], "rough": 0.95, "metal": 0.0, "bump": 0.75, "tile": 3.5, "pat": "mottle"},
	"cobble":    {"color": [0.40, 0.39, 0.38], "rough": 0.86, "metal": 0.0, "bump": 0.65, "tile": 1.1, "pat": "brick"},
	"gravel":    {"color": [0.46, 0.44, 0.41], "rough": 0.98, "metal": 0.0, "bump": 0.7,  "tile": 2.2, "pat": "mottle"},
	# NON-MASONRY PROP MATERIALS. A prop kit is mostly not walls: fix_untextured_props needs a
	# sofa to come back as cloth and a mattress not to come back as oak.
	"fabric":    {"color": [0.42, 0.40, 0.38], "rough": 0.96, "metal": 0.0, "bump": 0.3,  "tile": 1.2, "pat": "fiber"},
	"canvas":    {"color": [0.58, 0.54, 0.44], "rough": 0.94, "metal": 0.0, "bump": 0.35, "tile": 1.6, "pat": "fiber"},
	"leather":   {"color": [0.33, 0.22, 0.15], "rough": 0.72, "metal": 0.0, "bump": 0.25, "tile": 1.4, "pat": "mottle"},
	"plastic":   {"color": [0.38, 0.40, 0.43], "rough": 0.42, "metal": 0.0, "bump": 0.05, "tile": 3.0, "pat": ""},
	"rust":      {"color": [0.42, 0.24, 0.14], "rough": 0.93, "metal": 0.35,"bump": 0.45, "tile": 2.0, "pat": "mottle"},
	# THE SEVEN NAMES THE PLAYBOOK ALREADY TELLS AUTHORS TO USE AND THIS TABLE DID NOT HAVE.
	# world-streaming.md lists fifteen ground presets. AreaBuilder.GROUND_PRESETS — the ZONE path —
	# has all fifteen. SURFACES — the TERRAIN and chunk path, which is what nearly every world
	# actually runs on — had eight, so an author following the documentation to the letter got flat
	# grey for the other seven and nothing said why. That is the same defect as the 195-cell grey
	# coast, still live for `desert`, `dune`, `road`, `sidewalk`, `mud`, `snow` and `water`.
	# Values are the GROUND_PRESETS colours (already tuned and shipped on the zone path) with tile
	# and pattern expressed in THIS table's units, so the two paths finally agree on what a name means.
	"desert":    {"color": [0.75, 0.63, 0.42], "rough": 0.97, "metal": 0.0, "bump": 0.55, "tile": 5.5, "pat": "mottle"},
	"dune":      {"color": [0.80, 0.69, 0.47], "rough": 0.97, "metal": 0.0, "bump": 0.70, "tile": 6.5, "pat": "mottle"},
	"road":      {"color": [0.11, 0.11, 0.13], "rough": 0.80, "metal": 0.0, "bump": 0.28, "tile": 6.0, "pat": "mottle"},
	"sidewalk":  {"color": [0.54, 0.54, 0.57], "rough": 0.90, "metal": 0.0, "bump": 0.22, "tile": 1.6, "pat": "tiles"},
	"mud":       {"color": [0.30, 0.24, 0.17], "rough": 0.70, "metal": 0.0, "bump": 0.45, "tile": 4.5, "pat": "mottle"},
	# Snow sits just under ALBEDO_MAX (0.85) on purpose: at the clamp all three channels flatten to
	# the same value and the cold blue tint that makes snow read as snow is lost.
	"snow":      {"color": [0.82, 0.84, 0.85], "rough": 0.65, "metal": 0.0, "bump": 0.35, "tile": 5.0, "pat": "mottle"},
	# Ground-level water — a shallow, a puddle field, a flooded cell. NOT the animated ocean
	# (water.gd owns that). Now that `alpha` exists it can actually be water rather than blue mud.
	"water":     {"color": [0.16, 0.32, 0.42], "rough": 0.10, "metal": 0.0, "bump": 0.18, "tile": 8.0, "pat": "mottle", "alpha": 0.82},
}

# Per-channel albedo ceiling (see header). Applied ONLY where albedo is resolved (_resolve); never to emission.
const ALBEDO_MAX := 0.85

# Cache: spec-key -> Material (shared across a build so a district reuses materials). Static so it persists
# per game run; cleared implicitly when the game reloads.
static var _cache := {}
static var _palette := Color(1, 1, 1)   # uniform tint applied to every surface() so a build reads art-directed


## Set a uniform palette tint (call once per build from the committed art direction). Clears the cache so
## already-built materials pick it up next request.
static func set_palette(tint: Color) -> void:
	_palette = tint
	_cache.clear()


## A TRIPLANAR surface material — the workhorse. World-triplanar so a tiled procedural-normal relief maps
## correctly onto ANY size/scaled box (no stretch). `spec` = a preset NAME ("sandstone"…) or {color,rough,metal,
## bump,tile}. Cached.
static func surface(spec) -> StandardMaterial3D:
	var key := "S:" + var_to_str(spec)
	if _cache.has(key):
		return _cache[key]
	var p := _resolve(spec)
	var m := StandardMaterial3D.new()
	m.roughness = p["rough"]
	m.metallic = p["metal"]
	# world triplanar -> the relief tiles by WORLD size, identical on a 2m and a 40m wall
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	var t: float = maxf(0.5, p["tile"])
	m.uv1_scale = Vector3(1.0 / t, 1.0 / t, 1.0 / t)
	var seed_i := int(t * 13.0) + int((p["color"] as Color).r * 255.0)
	var pat := String(p.get("pat", ""))
	if pat != "":
		# ONE height field drives BOTH channels, which is the whole point: the mortar line you SEE
		# and the mortar groove the light catches are the same pixels. Generic noise relief over a
		# flat colour is what "flat grey blocky stone" actually was.
		var h := _pattern_height(pat, seed_i)
		m.albedo_texture = _tinted(h, p["color"] as Color)
		# The pattern already carries the surface's colour, so albedo_color is pure TINT. Keeping
		# `_palette` out of the baked image matters: the height/tint images are cached by pattern,
		# and baking a palette into them would make a palette change silently reuse the old one.
		m.albedo_color = _palette
		if p["bump"] > 0.001:
			m.normal_enabled = true
			m.normal_texture = _relief(h, pat, p["bump"])
			m.normal_scale = clampf(p["bump"], 0.0, 1.0)
	else:
		m.albedo_color = (p["color"] as Color) * _palette
		if p["bump"] > 0.001:
			m.normal_enabled = true
			m.normal_texture = _noise_normal(seed_i, p["bump"])
			m.normal_scale = clampf(p["bump"], 0.0, 1.0)
	# TRANSPARENCY, applied last so it works on both the patterned and the flat branch (a leaded
	# window is a pattern with alpha; a plain pane is flat). Culling is deliberately left ON:
	# Mason emits a pane as a thin SOLID with both faces, so two-sided rendering would double the
	# fragment cost for nothing. A single-quad user who needs both sides can say so themselves.
	var alpha := float(p.get("alpha", 1.0))
	if alpha < 0.999:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color.a = alpha
	_cache[key] = m
	return m


## A self-illuminated material (windows-as-glow, neon strips, signage fills). Emissive reads as "lit" at night
## even though Environment glow is off; pair with neon.gd's additive halo for a fake bloom. Cached.
static func emissive(color: Color, energy: float = 1.4) -> StandardMaterial3D:
	var key := "E:%s:%.2f" % [str(color), energy]
	if _cache.has(key):
		return _cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	_cache[key] = m
	return m


## An EMISSIVE WINDOW-GRID facade material — a procedurally generated tile of lit window cells on a dark wall,
## applied to a tower/building face so it reads as a populated, night-lit facade (the "tower glows at night, not
## a black block" fix). `cols`/`rows` = windows per tile; `wall` = the wall color; `glow` = window emission color;
## `lit` = emission energy (raise at night). Tiled by the caller's uv1_scale = (floors, bays). Cached by params.
static func window_facade(wall: Color, glow: Color, lit: float = 1.2, cols: int = 4, rows: int = 4) -> StandardMaterial3D:
	var key := "W:%s:%s:%.2f:%d:%d" % [str(wall), str(glow), lit, cols, rows]
	if _cache.has(key):
		return _cache[key]
	var tex := _window_tex(wall * _palette, glow, cols, rows)
	# Emission uses a WINDOW-ONLY mask (black wall texels). Reusing the albedo
	# texture made the WALL emit at `lit` too — light-walled towers rendered as
	# self-glowing white slabs in daylight (the "buildings wash to white in
	# bright sun" bug). Now only window texels glow, day and night.
	var etex := _window_tex(Color(0, 0, 0), glow, cols, rows)
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.emission_enabled = true
	m.emission_texture = etex
	m.emission_energy_multiplier = lit
	m.roughness = 0.7
	m.uv1_scale = Vector3(cols, rows, 1.0)   # caller overrides per building via material duplicate if needed
	_cache[key] = m
	return m


## A DECAL quad — a thin textured/colored plane stamped onto a wall or floor for surface detail the geometry
## can't carry: hieroglyph panels, road markings, posters, crosswalks, signage, grime. `size` in metres, faces
## +Z by default (rotate the returned node to lie on the target face); transparent where `tex` is transparent.
## NOTE: a real Decal node is Forward+-only; this alpha-quad is the gl_compatibility-safe equivalent.
static func decal_quad(tex: Texture2D, size: Vector2, emissive_energy: float = 0.0) -> MeshInstance3D:
	var q := QuadMesh.new()
	q.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = q
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	if emissive_energy > 0.0:
		m.emission_enabled = true
		m.emission_texture = tex
		m.emission_energy_multiplier = emissive_energy
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## An emissive sign LIGHT-POOL — a real OmniLight3D color-matched to a neon sign so the sign actually CASTS its
## color onto the wall, street, and people beside it (the single biggest "neon Vegas at night" miss). Budget it:
## the caller caps the count + distance-culls to ~6-8 in the resident ring. Add as a child of the sign/prop.
static func sign_light(color: Color, energy: float = 2.0, light_range: float = 7.0) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_color = color
	l.light_energy = energy
	l.omni_range = light_range
	l.shadow_enabled = false                 # cheap fill light, no shadow map
	l.light_specular = 0.3
	return l


# ─────────────────────────────── internals ───────────────────────────────

## Names already reported as unresolved, so a 170-cell world logs each miss once rather than 170 times.
static var _unknown_logged := {}

## SAY WHEN A PRESET NAME DOES NOT EXIST.
##
## An unknown name fell through to the grey mottle default in silence, which is the worst possible
## behaviour: the world looks built, the author sees flat grey and assumes it is the lighting, and
## nothing in any log connects the two. One coastal build shipped 195 cells of ground this way —
## "rock" and "cobble", neither of which was in the table. verify.mjs now FAILS on an unresolved
## preset; this line is how it, and a human reading the console, finds out.
static func _note_unknown(nm: String) -> void:
	if nm == "" or _unknown_logged.has(nm):
		return
	_unknown_logged[nm] = true
	push_warning("GOGI_SURFACE_UNKNOWN \"%s\" is not a surface preset — falling back to flat grey. " % nm
		+ "Use a name from GSurf.SURFACES, or a dict spec {color, rough, metal, bump, tile, pat}.")
	print("GOGI_SURFACE_UNKNOWN ", nm)


## The resolved base COLOUR of a surface spec, with the albedo ceiling applied — i.e. what a wall
## made of this will actually give back to a light. Public because lighting has to know: the same
## omni is twice the picture on plaster as on timber, and a light that ignores the difference blows
## one room out while leaving the other dim. See build_structure._room_light.
static func albedo_of(spec) -> Color:
	return _resolve(spec)["color"]


static func _resolve(spec) -> Dictionary:
	var out := {"color": Color(0.6, 0.6, 0.62), "rough": 0.85, "metal": 0.0, "bump": 0.25, "tile": 4.0, "pat": "mottle", "alpha": 1.0}
	if typeof(spec) == TYPE_STRING and not SURFACES.has(String(spec).to_lower()):
		_note_unknown(String(spec).to_lower())
	if typeof(spec) == TYPE_STRING and SURFACES.has(String(spec).to_lower()):
		var pr: Dictionary = SURFACES[String(spec).to_lower()]
		out["color"] = Color(pr["color"][0], pr["color"][1], pr["color"][2])
		out["rough"] = pr["rough"]; out["metal"] = pr["metal"]; out["bump"] = pr["bump"]; out["tile"] = pr["tile"]
		out["pat"] = pr.get("pat", "")
		out["alpha"] = pr.get("alpha", 1.0)
	elif typeof(spec) == TYPE_DICTIONARY:
		var d: Dictionary = spec
		var nm := String(d.get("preset", d.get("material", ""))).to_lower()
		# A dict that names a preset AND overrides everything is fine; one that names a preset
		# nobody has heard of and relies on it is the silent-grey case above.
		if nm != "" and not SURFACES.has(nm) and not d.has("color"):
			_note_unknown(nm)
		if SURFACES.has(nm):
			var pr2: Dictionary = SURFACES[nm]
			out["color"] = Color(pr2["color"][0], pr2["color"][1], pr2["color"][2])
			out["rough"] = pr2["rough"]; out["metal"] = pr2["metal"]; out["bump"] = pr2["bump"]; out["tile"] = pr2["tile"]
			out["pat"] = pr2.get("pat", "")
			out["alpha"] = pr2.get("alpha", 1.0)
		if d.has("color"):
			var c = d["color"]
			out["color"] = Color(c[0], c[1], c[2])
		for k in ["rough", "metal", "bump", "tile"]:
			if d.has(k):
				out[k] = float(d[k])
		# ALPHA — the key the dict spec never had. Below 1.0 the material becomes alpha-blended,
		# which is what makes glass, water-in-a-trough, a tent skin, an ice wall or a scrim
		# expressible at all. It is NOT clamped by ALBEDO_MAX: that ceiling exists to stop albedo
		# blowing out in daylight and has nothing to say about opacity.
		if d.has("alpha"):
			out["alpha"] = clampf(float(d["alpha"]), 0.0, 1.0)
		# An explicit pattern (or "" for a flat colour) overrides the preset's family.
		if d.has("pat"):
			out["pat"] = String(d["pat"])
	# ALBEDO CEILING — near-white albedo can't survive daylight (see header). Albedo only; emission
	# colors (emissive()/window glow/sign_light) never pass through _resolve and stay unclamped.
	var c: Color = out["color"]
	out["color"] = Color(minf(c.r, ALBEDO_MAX), minf(c.g, ALBEDO_MAX), minf(c.b, ALBEDO_MAX), c.a)
	return out


# A tiling, seamless procedural NORMAL map (FastNoiseLite -> NoiseTexture2D as_normal_map). Runtime-generated:
# no asset dependency, works offline / on any build. Shared with the ground system's approach.
# ---- PATTERNED SURFACES: one height field, both channels -------------------------------------
#
# Until now `surface()` set albedo_COLOR and nothing else — there was not one albedo image anywhere
# in this template. A Mason building therefore COULD NOT display a texture: chunk_manager's Mason
# pass overrides every labelled part with `GSurf.surface(name)`, so even a GLB that shipped with
# real baked ashlar maps rendered as flat grey with a generic noise bump over it. That is exactly
# what "flat grey blocky stone" and "flat brown planks" were, and no amount of work in the compiler
# or in a game repo could fix it from the outside.
#
# These are GENERATED, not shipped. The engine pack rides inside the iOS app, so a set of PNGs is
# the one cost that is never worth paying here; `_noise_normal` and `_window_tex` already
# established that a procedural tile is the house answer. Total added weight: zero bytes.
#
# ONE HEIGHT FIELD FEEDS BOTH CHANNELS. `_pattern_height` returns a greyscale tile; `_tinted`
# colours it for albedo and `_relief` converts the SAME pixels to a normal map. So the mortar line
# you see and the groove the light catches are the same mortar line. That agreement is most of what
# separates "a picture of bricks" from a wall.
#
# EVERY FAMILY TILES EXACTLY. The materials are world-triplanar and repeat every `tile` metres, so
# a seam would print across every wall in the game. Block counts divide _PAT_PX, alternating
# courses offset by exactly half a block, and the mottle is a sum of INTEGER-frequency sines rather
# than FastNoiseLite — which has no seamless mode at this call site and would band visibly.
const _PAT_PX := 256          # 256 is where mortar joints stop being mushy at the tiling rates here
static var _pat_cache := {}   # "family:seed" -> Image (the height field, shared by both channels)
static var _tex_cache := {}   # derived ImageTexture cache, so two presets sharing a family share VRAM

static func _pattern_height(kind: String, seed_i: int) -> Image:
	# "mottle" is pure integer-frequency sines and never touches the rng, so every preset using it
	# — concrete, stucco, plaster, marble, asphalt, sand, grass, dirt — produces a byte-identical
	# image. Keyed on the seed it is built eight times (27 ms each, the slowest family, because it
	# is the one that is genuinely per-pixel). Normalise the seed away so it is built once.
	var key := "%s:%d" % [kind, 0 if kind == "mottle" else seed_i]
	if _pat_cache.has(key):
		return _pat_cache[key]
	var px := _PAT_PX
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	var g := func(v: float) -> Color: return Color(v, v, v, 1.0)
	match kind:
		"ashlar", "brick":
			# Courses of blocks in running bond: wide and shallow for ashlar, small for brick.
			var cols := 4 if kind == "ashlar" else 8
			var rows := 8 if kind == "ashlar" else 16
			var joint := 3 if kind == "ashlar" else 2
			img.fill(g.call(0.72))                      # mortar sits recessed and darker
			var bw := px / cols
			var bh := px / rows
			for r in rows:
				var off := (bw / 2) if (r % 2 == 1) else 0
				for c in cols:
					var v := 1.0 + rng.randf_range(-0.07, 0.07)   # per-block value, the anti-repeat cue
					var x0 := (c * bw + off) % px
					var y0 := r * bh
					# A block straddling the right edge is drawn in two halves so the tile still wraps.
					var w1: int = mini(bw - joint, px - x0)
					img.fill_rect(Rect2i(x0, y0, w1, bh - joint), g.call(v))
					if w1 < bw - joint:
						img.fill_rect(Rect2i(0, y0, (bw - joint) - w1, bh - joint), g.call(v))
		"tiles":
			# Overlapping courses (slate / roof tile): each course casts a shadow line on the one below.
			var trows := 8
			var tcols := 8
			img.fill(g.call(0.62))
			var tw := px / tcols
			var th := px / trows
			for r in trows:
				var off2 := (tw / 2) if (r % 2 == 1) else 0
				for c in tcols:
					var v2 := 1.0 + rng.randf_range(-0.05, 0.05)
					var x0b := (c * tw + off2) % px
					var y0b := r * th
					var w2: int = mini(tw - 1, px - x0b)
					# the lower ~70% of each tile is the exposed face; the top is under the course above
					img.fill_rect(Rect2i(x0b, y0b + int(th * 0.3), w2, int(th * 0.7)), g.call(v2))
					if w2 < tw - 1:
						img.fill_rect(Rect2i(0, y0b + int(th * 0.3), (tw - 1) - w2, int(th * 0.7)), g.call(v2))
		"planks":
			# Boards with a dark seam and lengthwise grain — the grain is what stops a plank reading
			# as a painted stripe.
			var n := 4
			var pw := px / n
			img.fill(g.call(0.68))
			for i in n:
				var base := 1.0 + rng.randf_range(-0.06, 0.06)
				img.fill_rect(Rect2i(i * pw, 0, pw - 2, px), g.call(base))
				for _s in 3:
					var gx := i * pw + rng.randi_range(2, maxi(3, pw - 4))
					var amp := rng.randf_range(-0.05, -0.02)
					for y in px:
						# a slow wander, integer-periodic so the streak meets itself at the seam
						var wob := int(round(sin(TAU * float(y) / float(px)) * 2.0))
						var x := gx + wob
						if x >= i * pw and x < i * pw + pw - 2:
							img.set_pixel(x, y, g.call(clampf(base + amp, 0.0, 1.0)))
		"fiber":
			# Thatch / straw: dense vertical streaks, no block structure at all.
			img.fill(g.call(0.80))
			for _i in 220:
				var fx := rng.randi_range(0, px - 1)
				var fy := rng.randi_range(0, px - 1)
				var fl := rng.randi_range(px / 8, px / 3)
				var fv := clampf(1.0 + rng.randf_range(-0.18, 0.14), 0.0, 1.0)
				for k in fl:
					img.set_pixel(fx, (fy + k) % px, g.call(fv))
		_:
			# "mottle" and anything unknown: soft value variation, no structure. Built from
			# integer-frequency sine products precisely so it tiles; FastNoiseLite does not here.
			for y in px:
				var fy2 := TAU * float(y) / float(px)
				for x in px:
					var fx2 := TAU * float(x) / float(px)
					var v3 := 1.0 \
						+ 0.045 * sin(fx2 * 3.0 + 0.7) * sin(fy2 * 2.0 + 1.9) \
						+ 0.030 * sin(fx2 * 7.0 + 2.3) * sin(fy2 * 5.0 + 0.4) \
						+ 0.018 * sin(fx2 * 13.0) * sin(fy2 * 11.0 + 1.1)
					img.set_pixel(x, y, g.call(clampf(v3, 0.0, 1.0)))
	_pat_cache[key] = img
	return img


## Colour a height field for the albedo slot. The ALBEDO CEILING still applies per channel — a
## block highlighted above its base must not be the thing that reintroduces detail-free white.
static func _tinted(h: Image, col: Color) -> ImageTexture:
	var key := "T:%d:%s" % [h.get_instance_id(), str(col)]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var px := h.get_width()
	var out := Image.create(px, px, true, Image.FORMAT_RGBA8)
	for y in px:
		for x in px:
			var v := h.get_pixel(x, y).r
			out.set_pixel(x, y, Color(
				minf(col.r * v, ALBEDO_MAX), minf(col.g * v, ALBEDO_MAX), minf(col.b * v, ALBEDO_MAX), 1.0))
	out.generate_mipmaps()
	var t := ImageTexture.create_from_image(out)
	_tex_cache[key] = t
	return t


## The SAME height field as a normal map, so relief and colour describe one surface.
static func _relief(h: Image, kind: String, bump: float) -> ImageTexture:
	var key := "N:%d:%.3f" % [h.get_instance_id(), bump]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var b := h.duplicate() as Image
	b.bump_map_to_normal_map(maxf(0.5, bump * 6.0))
	b.generate_mipmaps()
	var t := ImageTexture.create_from_image(b)
	_tex_cache[key] = t
	return t


static func _noise_normal(seed_i: int, bump: float) -> NoiseTexture2D:
	var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fn.frequency = 0.05
	fn.seed = seed_i
	fn.fractal_octaves = 3
	var nt := NoiseTexture2D.new()
	nt.width = 256
	nt.height = 256
	nt.seamless = true
	nt.as_normal_map = true
	nt.bump_strength = maxf(0.6, bump * 16.0)
	nt.noise = fn
	return nt


# Generate a window-grid tile: `wall`-colored background with a grid of brighter window cells (mullion gaps).
# Called twice per facade: once with the real wall color (albedo) and once with a BLACK background
# (emission mask) so windows glow and the wall genuinely does not.
static func _window_tex(wall: Color, glow: Color, cols: int, rows: int) -> ImageTexture:
	var px := 128
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	img.fill(Color(wall.r, wall.g, wall.b, 1.0))
	var cw := float(px) / float(maxi(1, cols))
	var rh := float(px) / float(maxi(1, rows))
	var margin := 0.22   # fraction of a cell that is wall (mullion/frame) around each window
	for cy in rows:
		for cx in cols:
			# slight per-window variation so not every window is identical brightness
			var on := 0.55 + 0.45 * float((cx * 7 + cy * 13) % 5) / 4.0
			var wcol := Color(glow.r * on, glow.g * on, glow.b * on, 1.0)
			var x0 := int((float(cx) + margin) * cw)
			var x1 := int((float(cx) + 1.0 - margin) * cw)
			var y0 := int((float(cy) + margin) * rh)
			var y1 := int((float(cy) + 1.0 - margin) * rh)
			for y in range(y0, y1):
				for x in range(x0, x1):
					img.set_pixel(x, y, wcol)
	return ImageTexture.create_from_image(img)
