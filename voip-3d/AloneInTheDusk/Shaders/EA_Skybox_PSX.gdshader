// EmacEArt Stylized Skybox - PSX EDITION for Alone in the Dusk.
// The stylized sky shader with one thing added: the finished sky colour is put through
// the same colour steps as the rest of the frame, and dithered on the pixel grid the
// PSX screen pass uses. Without it the sky is the only surface in the picture with a
// smooth gradient - and a smooth gradient behind chunky geometry is what makes a scene
// read as "modern engine pretending", however heavy the pixelation on the props is.
// Both numbers come from the EA PSX globals, so the sky follows the F2 preset and the
// master switch with everything else.
shader_type sky;

// Globals declared in project.godot under [shader_globals] by the EA PSX addon.
global uniform float psx_colour_levels;   // steps per channel, PS1 = 32

// Ordered 2x2 dither, in steps of one colour level. Zero gives hard banding, one gives
// the console's stippled gradient.
const float psx_sky_dither = 0.6;


const vec4 zenith_color = vec4(0.00116099, 0.00154799, 0.00393594, 1.0);
const vec4 horizon_color = vec4(0.00598106, 0.01002283, 0.03310477, 1.0);
const vec4 ground_color = vec4(0.01002283, 0.00854038, 0.00854038, 1.0);
const float horizon_sharpness = 3.2;
// Shifts the sky gradient only. The ground hemisphere stays at the real horizon so it
// cannot bleed into the upper sky at extreme values.
const float horizon_offset = 0.04;

const vec4 sun_color = vec4(0.29569980, 0.36724647, 0.60382734, 1.0);
const vec4 sun_glow_color = vec4(0.07323896, 0.14731900, 0.42003329, 1.0);
const float sun_size = 0.02;
const float sun_glow_size = 0.42;
const float sun_glow_falloff = 2.6;


const vec4 atmosphere_color = vec4(0.02721178, 0.05497173, 0.17886750, 1.0);
const float atmosphere_strength = 0.44;
const float atmosphere_falloff = 4.5;

const float exposure = 0.66;
const float contrast = 1.1;
const float saturation = 1.0;
const vec4 lift = vec4(0.00000000, 0.00000000, 0.00000000, 1.0);
const vec4 gamma_midtones = vec4(0.21404114, 0.21404114, 0.21404114, 1.0);
const vec4 gain = vec4(1.00000000, 1.00000000, 1.00000000, 1.0);

const bool clouds_enabled = true;
const vec4 cloud_color = vec4(0.02198095, 0.03007410, 0.07323896, 1.0);
const vec4 cloud_shadow_color = vec4(0.00393594, 0.00489631, 0.01341175, 1.0);
const float cloud_coverage = 0.3;
const float cloud_softness = 0.08;
const float cloud_bands = 3.0;
const float cloud_density = 0.85;
const float cloud_stretch = 0.5;
const float cloud_swirl = 0.1;
// 0 = Standard, 1 = Feathered, 2 = Round, 3 = Diagonal, 4 = Cubic
const float cloud_style = 1.0;
const float cloud_scale = 3.0;
const float cloud_height = 0.06;
const float cloud_speed = 0.01;

// Godot hands color uniforms to the shader already converted from sRGB to linear, so mid
// grey in the picker arrives as 0.2140. Dividing by that makes mid grey the neutral point
// of the gamma control.
const float GAMMA_NEUTRAL = 1.0 / 0.21404114;


// -- Helpers -------------------------------------------------------------------
vec3 apply_contrast(vec3 col, float amount) {
	// Clamp: dark colors + high contrast would produce sub-zero values -> pure black
	return max((col - 0.5) * amount + 0.5, vec3(0.0));
}

vec3 apply_saturation(vec3 col, float amount) {
	float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
	// Clamp: amount > 1 on near-black channels produces sub-zero values
	return max(mix(vec3(lum), col, amount), vec3(0.0));
}

// ASC CDL: lift/gamma/gain per channel
vec3 apply_lift_gamma_gain(vec3 col, vec3 l, vec3 g, vec3 gn) {
	col = col * gn + l;
	return sign(col) * pow(abs(col), 1.0 / max(g, vec3(0.001)));
}


// -- Cloud noise (simplex + 4-octave FBM) --------------------------------------
// Simplex noise, not value noise. Value noise sits on a square lattice: its slope breaks
// along the cell borders, and once the pattern is stretched or posterized those borders
// show up as straight, axis-aligned edges - rectangular patches in the sky. Simplex uses
// a triangular lattice with continuous gradients, so there is no axis-aligned structure
// to become visible at any stretch setting.
float cloud_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec3 sx_mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec2 sx_mod289(vec2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec3 sx_permute(vec3 x) { return sx_mod289(((x * 34.0) + 1.0) * x); }

// Returns roughly -1..1
float cloud_simplex(vec2 v) {
	const vec4 C = vec4(0.211324865405187, 0.366025403784439,
			-0.577350269189626, 0.024390243902439);
	vec2 i  = floor(v + dot(v, C.yy));
	vec2 x0 = v - i + dot(i, C.xx);
	vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
	vec4 x12 = x0.xyxy + C.xxzz;
	x12.xy -= i1;
	i = sx_mod289(i);
	vec3 p = sx_permute(sx_permute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
	vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
	m = m * m;
	m = m * m;
	vec3 x = 2.0 * fract(p * C.www) - 1.0;
	vec3 h = abs(x) - 0.5;
	vec3 ox = floor(x + 0.5);
	vec3 a0 = x - ox;
	m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
	vec3 g;
	g.x  = a0.x * x0.x + h.x * x0.y;
	g.yz = a0.yz * x12.xz + h.yz * x12.yw;
	return 130.0 * dot(m, g);
}

// 0..1 wrapper. The 0.35 factor keeps the visible cloud size the same as before the
// noise was swapped - simplex cells are smaller than square-lattice cells at the same
// coordinate scale, so without it every material would suddenly look finer grained.
float cloud_noise(vec2 p) {
	return clamp(cloud_simplex(p * 0.35) * 0.5 + 0.5, 0.0, 1.0);
}

// Each octave is rotated by a fraction of a turn, so repeated octaves cannot line up
// into a visible grid.
const mat2 CLOUD_OCTAVE_ROT = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8));

float cloud_fbm(vec2 p) {
	vec2 q = p;
	float v = cloud_noise(q) * 0.5000;
	q = CLOUD_OCTAVE_ROT * q * 2.1 + vec2(5.2, 1.3);
	v += cloud_noise(q) * 0.2500;
	q = CLOUD_OCTAVE_ROT * q * 2.05 + vec2(9.7, 2.8);
	v += cloud_noise(q) * 0.1250;
	q = CLOUD_OCTAVE_ROT * q * 2.02 + vec2(3.1, 7.4);
	v += cloud_noise(q) * 0.0625;
	return v * (1.0 / 0.9375);
}

// Style 1: Feathered - ridged FBM. Inverts the noise around 0.5, so thin ridges appear
// where the noise crosses 0.5 - the cirrus look.
float cloud_fbm_ridged(vec2 p) {
	vec2 q = p;
	float v = (1.0 - abs(cloud_noise(q) * 2.0 - 1.0)) * 0.5000;
	q = CLOUD_OCTAVE_ROT * q * 2.1 + vec2(5.2, 1.3);
	v += (1.0 - abs(cloud_noise(q) * 2.0 - 1.0)) * 0.2500;
	q = CLOUD_OCTAVE_ROT * q * 2.05 + vec2(9.7, 2.8);
	v += (1.0 - abs(cloud_noise(q) * 2.0 - 1.0)) * 0.1250;
	q = CLOUD_OCTAVE_ROT * q * 2.02 + vec2(3.1, 7.4);
	v += (1.0 - abs(cloud_noise(q) * 2.0 - 1.0)) * 0.0625;
	return clamp(v * (1.0 / 0.9375), 0.0, 1.0);
}

// Style 2: Voronoi - round, separated cells
vec2 voronoi_center(vec2 cell) {
	return cell + vec2(cloud_hash(cell), cloud_hash(cell + vec2(5.3, 2.1)));
}

float cloud_voronoi_euclid(vec2 p) {
	vec2 i = floor(p);
	float min_d = 10.0;
	for (int dx = -1; dx <= 1; dx++) {
		for (int dy = -1; dy <= 1; dy++) {
			vec2 c = voronoi_center(i + vec2(float(dx), float(dy)));
			min_d = min(min_d, length(p - c));
		}
	}
	return 1.0 - clamp(min_d * 1.35, 0.0, 1.0);
}

// Style 4: Cotton - the same cell centres as style 2, but joined with a smooth minimum
// instead of a plain minimum. The cell walls disappear and neighbouring cells grow into
// one connected, lobed mass, the way heaped cumulus piles up. A slow noise pushes the
// falloff in and out so the lobes never come out as clean circles - that is what keeps
// this apart from style 2, where every blob stands on its own with a seam around it.
float cloud_cotton(vec2 p) {
	vec2 i = floor(p);
	const float K = 5.5;   // higher = cells stay separate, lower = everything melts
	float acc = 0.0;
	for (int dx = -1; dx <= 1; dx++) {
		for (int dy = -1; dy <= 1; dy++) {
			vec2 c = voronoi_center(i + vec2(float(dx), float(dy)));
			acc += exp(-K * length(p - c));
		}
	}
	// Exponential smooth minimum of the cell distances
	float d_smooth = -log(max(acc, 1e-5)) / K;
	// Break the circles: the edge of the mass wanders with a low-frequency noise
	d_smooth -= (cloud_noise(p * 1.6) - 0.5) * 0.42;
	d_smooth -= (cloud_noise(p * 3.7 + vec2(6.1, 2.4)) - 0.5) * 0.18;
	return 1.0 - clamp(d_smooth * 1.55, 0.0, 1.0);
}


void sky() {
	vec3 dir = normalize(EYEDIR);
	float up = dir.y + horizon_offset;

	// -- Sky gradient ------------------------------------------------------
	float sky_t = clamp(pow(clamp(up, 0.0, 1.0), 1.0 / horizon_sharpness), 0.0, 1.0);

	// The ground uses raw dir.y - the offset shifts the sky gradient only, not the
	// physical hemisphere boundary.
	float ground_t = clamp(pow(clamp(-dir.y, 0.0, 1.0), 2.0), 0.0, 1.0);

	vec3 sky_col = mix(horizon_color.rgb, zenith_color.rgb, sky_t);
	sky_col = mix(sky_col, ground_color.rgb, ground_t);


	// -- Aerial perspective - atmospheric haze at the horizon --------------
	float horizon_factor = pow(clamp(1.0 - abs(up), 0.0, 1.0), atmosphere_falloff);
	sky_col += atmosphere_color.rgb * horizon_factor * atmosphere_strength * (1.0 - ground_t);

	// -- Sun ---------------------------------------------------------------
	// The disc sits where the scene's light points. One place, nothing to set here.
	vec3 sun_dir = LIGHT0_ENABLED ? normalize(LIGHT0_DIRECTION) : vec3(0.0, 1.0, 0.0);
	float cos_a = dot(dir, sun_dir);

	// Hard disc
	float sun_disc = 1.0 - smoothstep(sun_size - 0.0002, sun_size + 0.0002, 1.0 - cos_a);

	// Glow corona (additive)
	float glow_t = clamp((cos_a - (1.0 - sun_glow_size)) / sun_glow_size, 0.0, 1.0);
	float sun_glow = pow(glow_t, sun_glow_falloff);

	sky_col += sun_glow_color.rgb * sun_glow * (1.0 - ground_t);
	sky_col = mix(sky_col, sun_color.rgb, sun_disc * (1.0 - ground_t));

	// -- Clouds ------------------------------------------------------------
	if (clouds_enabled) {
		// Fade in above the minimum elevation, disappear toward the ground
		float elev_mask = clamp((dir.y - cloud_height) / max(cloud_softness, 0.01), 0.0, 1.0)
				* (1.0 - ground_t);

		// Perspective projection onto a horizontal cloud plane + time scroll
		vec2 cloud_uv = (dir.xz / max(dir.y + 0.1, 0.1)) * cloud_scale;
		cloud_uv.x += TIME * cloud_speed;

		// -- Domain warp -----------------------------------------------
		if (cloud_stretch > 0.01 || cloud_swirl > 0.01) {
			// Stretch - non-linear (squared): slow start, dramatic at high values.
			// Most of the stretching is done by squashing the sampling coordinate, which
			// pulls the pattern into long horizontal streaks without folding the domain
			// back onto itself. Only a small displacement is left on top, to keep the
			// streaks from running perfectly parallel.
			float sa = cloud_stretch * cloud_stretch;
			cloud_uv.x /= 1.0 + sa * 4.0;
			float wx = cloud_noise(cloud_uv * 0.28);
			float wy = cloud_noise(cloud_uv * 0.28 + vec2(4.7, 2.1));
			cloud_uv.x += (wx - 0.5) * sa * 2.2;
			cloud_uv.y += (wy - 0.5) * sa * 0.6;

			// Swirl - second-level domain warp with a perpendicular component.
			// vec2(-d.y, d.x) = 90-degree rotation of d -> organic swirling.
			if (cloud_swirl > 0.01) {
				float sx = cloud_noise(cloud_uv * 0.32 + vec2(1.7, 9.2));
				float sy = cloud_noise(cloud_uv * 0.32 + vec2(8.3, 2.8));
				vec2 d = vec2(sx - 0.5, sy - 0.5);
				cloud_uv += d * cloud_swirl * 3.2               // linear component
						+ vec2(-d.y, d.x) * cloud_swirl * 2.4;  // perpendicular = rotation
			}
		}

		// -- Pattern style selector ------------------------------------
		int c_style = int(round(cloud_style));
		float n;
		if (c_style == 1) {
			n = cloud_fbm_ridged(cloud_uv);              // feathered / cirrus
		} else if (c_style == 2) {
			n = cloud_voronoi_euclid(cloud_uv);          // round blobs
		} else if (c_style == 3) {                       // diagonal 45 deg
			vec2 r_uv = vec2(cloud_uv.x * 0.7071 - cloud_uv.y * 0.7071,
					cloud_uv.x * 0.7071 + cloud_uv.y * 0.7071);
			n = cloud_fbm(r_uv);
		} else if (c_style == 4) {
			n = cloud_cotton(cloud_uv);                  // merged, lobed masses
		} else {
			n = cloud_fbm(cloud_uv);                     // standard
		}

		// -- Posterization: bands > 1 -> cel-shaded stepped look --------
		float bands = max(cloud_bands, 1.0);
		float n_q = bands > 1.5 ? ceil(n * bands) / bands : n;

		// How far this pixel is past the coverage threshold. Continuous in coverage, so
		// dragging the slider creeps the cloud edge outward instead of making it jump.
		float d = n - (1.0 - cloud_coverage);
		// The steps are put on THIS distance, not on the raw noise. Quantizing the noise
		// (the earlier version) tied the steps to fixed noise levels, so the coverage
		// slider did nothing until it crossed one and then a whole band appeared at once.
		// Quantizing the distance keeps the first step glued to the threshold: the pixel
		// just inside the cloud jumps straight to a full step, which is what gives the
		// hard cut-out edge, while the edge itself still moves smoothly with coverage.
		float d_q = bands > 1.5 ? ceil(d * bands) / bands : d;

		float t = clamp(d_q / max(cloud_softness, 0.005), 0.0, 1.0);
		float cloud_alpha = t * t * (3.0 - 2.0 * t) * elev_mask * cloud_density;

		// Color driven by band level: low band = shadow, high band = lit
		float band_level = clamp((n_q - (1.0 - cloud_coverage)) * bands, 0.0, 1.0);
		vec3 cloud_col = mix(cloud_shadow_color.rgb, cloud_color.rgb, band_level);

		sky_col = mix(sky_col, cloud_col, cloud_alpha);
	}

	// -- Color grading -----------------------------------------------------
	sky_col *= exposure;
	sky_col = apply_contrast(sky_col, contrast);
	sky_col = apply_saturation(sky_col, saturation);
	sky_col = apply_lift_gamma_gain(
			sky_col,
			lift.rgb,
			max(gamma_midtones.rgb * GAMMA_NEUTRAL, vec3(0.001)),
			gain.rgb);

	sky_col = max(sky_col, vec3(0.0));

	// The sky sits at infinity, so the depth colour takes it whole. Without this the
	// far scene turns purple while the sky right behind it keeps its own colour, and the
	// whole thing looks as though the effect were not working.

	COLOR = sky_col;
}
