// EA PSX - screen pass for Alone in the Dusk.
// The frame is sampled at a sharper retro resolution and stepped down to a limited
// palette with a light ordered dither.
//
// THE SETTINGS OF THIS PACK ARE BAKED IN. Resolution, colour steps and dither strength
// are constants, so the look is the same in every project that opens the scene and
// there is nothing to retune by hand.

shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_nearest, repeat_disable;

// Frame height in console pixels. The width follows the viewport, so the chunky pixel
// stays square whatever the window does.
const int target_height = 1080;

// Steps per colour channel.
const float colour_levels = 128.0;

// How hard the dither pushes a pixel before rounding. 1.0 = half a colour step.
const float dither_strength = 0.18;

// ONE pattern for the whole pack: this 8x8 matrix is the same one the surface and
// terrain shaders carry. Two different matrices stacked on the same frame cancel each
// other into noise - the dots stop lining up and the picture only looks dirty.
// 8x8 gives 64 thresholds, twice the colour steps of the console, so every step gets
// a full pattern instead of half of one.
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

// Threshold in 0..1 - the form used for deciding whether a pixel is on at all.
float ea_bayer01(vec2 px) {
	ivec2 k = ivec2(mod(px, 8.0));
	return (float(BAYER8[k.y * 8 + k.x]) + 0.5) / 64.0;
}

// The same pattern centred on zero, for pushing a colour before it is rounded.
float ea_bayer(vec2 px) {
	return ea_bayer01(px) - 0.5;
}

void fragment() {
	vec2 uv = SCREEN_UV;

	// The grid is built from the REAL viewport size, not from a number pushed in by a
	// script. A value written once goes stale the moment the window is resized or the
	// game goes fullscreen, and every chunky pixel comes out a rectangle instead of a
	// square. SCREEN_PIXEL_SIZE is the size of one real pixel in UV, so its reciprocal
	// is the viewport in pixels - always current.
	vec2 viewport = 1.0 / SCREEN_PIXEL_SIZE;
	float cell_size = viewport.y / float(target_height);   // real pixels per chunky pixel
	vec2 grid = viewport / cell_size;                      // same cell on both axes
	uv = (floor(uv * grid) + 0.5) / grid;

	vec3 col = texture(screen_texture, uv).rgb;

	// One console pixel, counted in real monitor pixels. The dither is laid out on THIS
	// grid: a dot finer than the simulated pixel puts back the detail the downscale just
	// removed, and comes out as card noise instead of dithering.
	vec2 cell = FRAGCOORD.xy / max(cell_size, 1.0);

	// Ordered dithering in its textbook form: the threshold pattern is added in units of
	// ONE colour step just before rounding. At strength 1.0 a pixel moves at most half a
	// step, and neighbouring pixels average out into the shade the palette does not carry.
	float d = ea_bayer(cell) * dither_strength;
	col = floor(col * colour_levels + 0.5 + d) / colour_levels;

	COLOR = vec4(col, 1.0);
}
