// EA PSX - surface shader that reproduces PlayStation 1 rasterisation.
// Every effect is driven by global shader parameters, so one slider in the
// PSXController node retunes the whole scene without touching a single texture file.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled;

group_uniforms Surface;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform float alpha_cutoff : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);

group_uniforms Depth;
// METRES TOWARDS THE EYE, for a surface lying FLAT ON ANOTHER - roads, slabs, decals.
// Two surfaces in the same place are a tie, and the depth buffer settles a tie pixel by
// pixel at random - which shows up as flicker. Pixelation makes it worse, because one
// disputed console pixel is a square several times larger on screen.
// The offset is computed in EYE SPACE, not in clip space. Clip space needs the direction
// of the engine's depth axis, and Godot 4 runs it the opposite way to Godot 3: get the
// sign wrong and the fix makes things worse, with nothing to show it but your own eye.
// Zero changes nothing. 0.05 is enough for this scene; more lifts a prop off the ground.
uniform float depth_nudge : hint_range(0.0, 0.5, 0.005) = 0.0;

group_uniforms Local_overrides;
// -1 means "follow the global slider". Any other value overrides it for this material only.
//
// `local_texture_resolution` IS A STARTING POINT, NOT A FREEZE. The simulated texture
// size is counted per MODEL, not per metre, so one number across the pack gives a
// pixel that is a hand's width on a wall and over a metre on a 54 m bridge. Each
// material therefore carries its own figure, worked out from its own texel density,
// so the pixel comes out the same size in the world on everything.
//
// That figure still SCALES with the global slider instead of replacing it - the same
// arrangement the terrain shader uses with `texel_reference_resolution`. Replacing it
// would freeze every material that carries a figure, and the slider would then move
// the ground alone while the props stood still: the one thing the slider exists to
// avoid. The line below is what keeps the whole scene moving together.
uniform float local_texture_resolution = -1.0;
// The global value the figure above was worked out at. Leave it alone unless the pack's
// own figures were measured somewhere else.
uniform float local_reference_resolution = 256.0;
uniform float local_colour_levels = -1.0;

// Globals declared in project.godot under [shader_globals].
global uniform float psx_texture_resolution;   // simulated texture size in pixels
global uniform float psx_colour_levels;        // steps per channel (PS1 = 32)
global uniform float psx_vertex_snap;          // vertex grid, lower = stronger jitter
global uniform float psx_affine_amount;        // 0 = modern mapping, 1 = full PS1 warp
global uniform float psx_dither;
global uniform float psx_screen_height;
// Where the torch stands, where it points, and how wide its cone is.
// The torch colour normalised to sum 1 - how the shader tells its light from the rest.

                // ordered dither strength, 0-1

varying vec2 affine_uv;
varying float affine_w;
varying float fade_depth;


// ONE pattern for the whole pack - the same 8x8 matrix runs in the screen pass and in
// the terrain. Two different matrices over one frame cancel into noise: the dots stop
// landing on each other and the picture just looks dirty. A 4x4 matrix gives 16
// thresholds against 32 colour steps - half a pattern per step, so half the steps have
// nothing to break them up and stay as bands.
const int BAYER8[64] = {
	 0, 32,  8, 40,  2, 34, 10, 42,
	48, 16, 56, 24, 50, 18, 58, 26,
	12, 44,  4, 36, 14, 46,  6, 38,
	60, 28, 52, 20, 62, 30, 54, 22,
	 3, 35, 11, 43,  1, 33,  9, 41,
	51, 19, 59, 27, 49, 17, 57, 25,
	15, 47,  7, 39, 13, 45,  5, 37,
	63, 31, 55, 23, 61, 29, 53, 21
};

float ea_bayer01(vec2 pixel) {
	ivec2 k = ivec2(mod(pixel, 8.0));
	return (float(BAYER8[k.y * 8 + k.x]) + 0.5) / 64.0;
}

float ea_bayer(vec2 pixel) {
	return ea_bayer01(pixel) - 0.5;
}



void vertex() {
	// Point in eye space: the camera looks along -Z, so adding to Z pulls the surface
	// towards the eye by as many metres as the slider says.
	vec3 view_vertex = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	view_vertex.z += depth_nudge;
	vec4 clip = PROJECTION_MATRIX * vec4(view_vertex, 1.0);

	// Vertex snapping: PS1 had no sub-pixel precision, so screen positions
	// jumped to a fixed grid. This is what makes the geometry wobble.
	// The grid has to follow the aspect ratio. A square grid in clip space is
	// a stretched grid on screen, so on a wide monitor the vertical wobble shows
	// while the horizontal one is spread too thin to notice - which reads as
	// "the wobble does not work" rather than "the wobble is uneven".
	// psx_vertex_snap counts steps across the screen HEIGHT; the width gets the
	// same step size, just more of them.
	if (psx_vertex_snap > 0.0) {
		float aspect = VIEWPORT_SIZE.x / max(VIEWPORT_SIZE.y, 1.0);
		vec2 grid = vec2(psx_vertex_snap * aspect, psx_vertex_snap);
		vec2 ndc = clip.xy / clip.w;
		clip.xy = round(ndc * grid) / grid * clip.w;
	}

	// Affine texture mapping: the hardware interpolates varyings with perspective
	// correction. Pre-multiplying by w and dividing again in fragment cancels that
	// correction out, which is exactly the texture swim seen on the console.
	affine_w = mix(1.0, clip.w, clamp(psx_affine_amount, 0.0, 1.0));
	affine_uv = (UV * uv_scale + uv_offset) * affine_w;

	fade_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
	POSITION = clip;
}

void fragment() {
	vec2 uv = affine_uv / affine_w;

	// Simulated texture resolution. The file on disk stays untouched - the lookup
	// is snapped to the centre of a coarse texel grid, so a 2048 map can read as 64.
	float res = psx_texture_resolution;
	if (local_texture_resolution > 0.0) {
		res = local_texture_resolution
				* (psx_texture_resolution / max(local_reference_resolution, 1.0));
	}
	if (res > 0.0) {
		vec2 texel = vec2(res);
		uv = (floor(uv * texel) + 0.5) / texel;
	}

	// Same rule as the ground: read the mip that matches the simulated texel,
	// otherwise a 1024 map sampled on a 128 grid sparkles instead of looking
	// like a 128 px texture.
	float lod = 0.0;
	if (res > 0.0) {
		lod = max(log2(float(textureSize(albedo_texture, 0).x) / res), 0.0);
	}
	vec4 tex = textureLod(albedo_texture, uv, lod) * albedo_tint;

	if (alpha_cutoff > 0.0 && tex.a < alpha_cutoff) {
		discard;
	}

	// Colour quantisation. The console stored 5 bits per channel, giving 32 steps.
	float levels = local_colour_levels > 0.0 ? local_colour_levels : psx_colour_levels;
	if (levels > 1.0) {
		// The dot pattern is laid out on the CONSOLE GRID, not on monitor pixels. On
		// monitor pixels it comes out as fine noise that reads as a graphics fault
		// rather than dithering - a dot has to be the size of a picture pixel.
		float cell = max(VIEWPORT_SIZE.y / max(psx_screen_height, 1.0), 1.0);
		float spread = ea_bayer(FRAGCOORD.xy / cell) * psx_dither;
		tex.rgb = floor(tex.rgb * levels + 0.5 + spread) / levels;
	}


	// ALPHA is deliberately NOT written here. Assigning it moves the material into
	// the transparent pass, where it stops writing depth - a solid prop then shows its
	// own far faces through the near ones and looks like a mesh full of holes. Measured
	// 2026-09-21 on Alone in the Dusk: the prop atlas carries alpha below 250 on 19% of
	// its pixels (the covered bridge 0.6%, the road atlas 5.9%) while the source materials
	// these were built from are all Opaque and ignore that channel.
	// Cut-out foliage still works: raise alpha_cutoff and the discard above handles it,
	// which keeps the surface in the opaque pass where it belongs.
	// Colour of the surface. Without this line every surface renders pure white:
	// ALBEDO keeps its default and the textures never reach the frame.
	ALBEDO = tex.rgb;

	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	METALLIC = 0.0;
}

// STEPPED POINT LIGHT - this is the LOOK of the pack, not a setting. Point lights
// step the SHAPE of the lighting, never its power: ATTENUATION carries the distance
// falloff, and rounding that together with the shape switches the light off entirely.
// DIVIDING BY PI IS NOT DECORATION. LIGHT_COLOR arrives multiplied by energy AND by
// PI - exactly what the engine divides out in its own lambert. Without that division
// every light in the scene burns over three times too strong and the night scene
// comes out as daylight.
const float psx_light_levels = 3.0;

void light() {
	float n_l = clamp(dot(normalize(NORMAL), normalize(LIGHT)), 0.0, 1.0);
	float shape = n_l;
	if (!LIGHT_IS_DIRECTIONAL) {
		shape = clamp(floor(n_l * psx_light_levels + 0.5) / psx_light_levels, 0.0, 1.0);
	}
	DIFFUSE_LIGHT += shape * ATTENUATION * LIGHT_COLOR / PI;
}
