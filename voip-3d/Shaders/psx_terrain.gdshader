// EA PSX - splat-mapped ground that follows the same PSX globals as psx_material.
// Layer weights come from one alphamap: R, G, B, A carry layers 0..3. A layer the
// terrain never paints has weight 0 everywhere and costs nothing on screen.
// Tiling is given in metres, so `tile_metres = 5.0` repeats a texture every five
// metres of ground no matter how large the terrain is - the same number the source
// terrain layers carry, with no conversion to guess at.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled;

group_uniforms Depth;
// THE GROUND STEPS BACK FROM THE EYE BY THIS MANY METRES, and this is the right place
// for the fix. Props stand ON the ground, so the ground is the surface that should lose
// every tie. Nudging each prop forward one by one risks pushing it through its neighbour;
// stepping the ONE ground back settles every pair at once and can break nothing else,
// because nothing stands underneath it.
// Measured on this scene: 35 rays out of 4400 hit a prop closer than 8 cm above terrain.
// The offset is computed in EYE SPACE, not in clip space - the direction of the depth
// axis depends on the engine version, metres from the camera depend on nothing.
uniform float depth_push : hint_range(0.0, 0.5, 0.005) = 0.06;

group_uniforms Splatmap;
uniform sampler2D splat : source_color, filter_linear, repeat_disable;

group_uniforms Layers;
uniform sampler2D albedo_r : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_g : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_b : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_a : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 ground_tint : source_color = vec4(1.0);

group_uniforms Tiling;
// Size of the whole terrain in metres, and how often a layer repeats across it.
uniform float terrain_metres = 500.0;
uniform float tile_metres : hint_range(0.5, 64.0, 0.5) = 5.0;

group_uniforms Pixel_size;
// How many METRES of ground one simulated texel covers, at the reference
// resolution below. The ground is the one surface whose texel size cannot be
// inferred from the global slider: a prop maps its whole texture across itself,
// while the ground repeats a tile a hundred times, so the same slider gives the
// ground texels several times smaller and the two stop matching on screen.
// Measured on this pack at psx_texture_resolution 128: the 79 props have a median
// of 0.182 m per texel, while the ground was showing 0.039 m - 4.7x finer. Hence
// the default below. Raise it for a coarser ground, lower it for a finer one.
uniform float ground_texel_metres : hint_range(0.01, 2.0, 0.005) = 0.182;
// The resolution the number above was measured at. The texel grows and shrinks
// with the global slider from here, so F3 and F4 still move the ground.
uniform float texel_reference_resolution = 128.0;

// Globals declared in project.godot under [shader_globals] - the same six the
// surface shader reads, so one PSXController slider moves ground and props together.
global uniform float psx_texture_resolution;
global uniform float psx_colour_levels;
global uniform float psx_vertex_snap;
global uniform float psx_dither;
global uniform float psx_screen_height;
// Where the torch stands, where it points, and how wide its cone is.
// The torch colour normalised to sum 1 - how the shader tells its light from the rest.



varying float fade_depth;
// Fragment position in eye space - `light()` has no built-in of its own for it.
varying vec3 view_pos;


// ONE pattern for the whole pack - the same 8x8 matrix runs in the screen pass and in
// the surface shader. The ground fills half the frame, so it is where a mismatch shows
// first: if the terrain dithers on a different pattern from the props standing on it,
// the dots miss each other and the join reads as dirt rather than as one picture.
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
	// The camera looks along -Z, so subtracting from Z pushes the ground away from it.
	vec3 view_vertex = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	view_vertex.z -= depth_push;
	vec4 clip = PROJECTION_MATRIX * vec4(view_vertex, 1.0);
	view_pos = view_vertex;
	// The grid follows the aspect ratio, same as the surface shader - a square
	// grid in clip space is a stretched grid on screen, and the ground is where
	// an uneven wobble shows first.
	if (psx_vertex_snap > 0.0) {
		float aspect = VIEWPORT_SIZE.x / max(VIEWPORT_SIZE.y, 1.0);
		vec2 grid = vec2(psx_vertex_snap * aspect, psx_vertex_snap);
		vec2 ndc = clip.xy / clip.w;
		clip.xy = round(ndc * grid) / grid * clip.w;
	}
	fade_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
	POSITION = clip;
}

void fragment() {
	// The ground is one huge surface, so affine mapping is left out here on
	// purpose: on a 500 m plane it warps the whole horizon instead of a face.
	float tile = max(tile_metres, 0.001);
	float res = psx_texture_resolution;

	// THE SNAP IS WORKED OUT FIRST, because the MIX between ground layers has to ride
	// on it as well. Snapping happens in METRES OF GROUND, not in texture repeats:
	// snapping the tiled UV would tie the texel to how often a layer repeats, so
	// halving the tiling would halve the pixel size - two settings fighting over one
	// look. In metres the ground keeps its pixel whatever the tiling is, and it lands
	// on the same size as the props.
	vec2 snapped_uv = UV;
	float metres_per_texel = 0.0;
	if (res > 0.0) {
		metres_per_texel = ground_texel_metres
				* (texel_reference_resolution / max(res, 1.0));
		vec2 ground = UV * terrain_metres;
		ground = (floor(ground / metres_per_texel) + 0.5) * metres_per_texel;
		snapped_uv = ground / terrain_metres;
	}

	// THE SPLAT MAP READS ON THE SNAPPED COORDINATE, NOT THE RAW ONE. Read raw, the
	// three ground layers stay in squares but the BLEND between them slides smoothly
	// from screen pixel to screen pixel - and on a splatted terrain most of the surface
	// is a blend of two layers, so the squares dissolve into a soft gradient. Measured
	// 2026-10-02 against the scene: props came out in clean 5 cm blocks while the
	// ground they stood on looked like a photograph, although both were snapped to the
	// same number. The mix is part of the colour, so it has to be stepped with it.
	vec4 w = texture(splat, snapped_uv);
	float total = w.r + w.g + w.b + w.a;
	float inv = total > 0.0001 ? 1.0 / total : 0.0;
	vec4 weight = total > 0.0001 ? w * inv : vec4(1.0, 0.0, 0.0, 0.0);

	vec2 uv = snapped_uv * (terrain_metres / tile);

	// A simulated low-res texture has to be READ from a low-res mip, not
	// point-sampled sparsely out of the full-size one. Taking one texel in every
	// thirty of a 1024 map does not look like a 34 px texture - it looks like
	// static, because each sample is an unrelated speck of the original detail.
	// The console did not do that: its textures really were small.
	float lod = 0.0;
	if (res > 0.0) {
		lod = max(log2(float(textureSize(albedo_r, 0).x) * metres_per_texel / tile), 0.0);
	}

	vec3 col = weight.r * textureLod(albedo_r, uv, lod).rgb
	         + weight.g * textureLod(albedo_g, uv, lod).rgb
	         + weight.b * textureLod(albedo_b, uv, lod).rgb
	         + weight.a * textureLod(albedo_a, uv, lod).rgb;
	col *= ground_tint.rgb;

	if (psx_colour_levels > 1.0) {
		col = floor(col * psx_colour_levels + 0.5 + ea_bayer(FRAGCOORD.xy / max(VIEWPORT_SIZE.y / max(psx_screen_height, 1.0), 1.0)) * psx_dither) / psx_colour_levels;
	}

	// Colour of the ground. Without this line the terrain renders pure white.
	ALBEDO = col;

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
