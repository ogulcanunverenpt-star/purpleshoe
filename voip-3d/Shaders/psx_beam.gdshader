// EA PSX - retro torch beam: a flat card turned edge-on to the camera, the way a console
// drew a shaft of light. Not a volume, not a cone.
// A CONE DOES NOT WORK IN FIRST PERSON. The player stands at its apex, so its walls
// cover the whole screen and an additive pass over every pixel turns the night into milk.
// Measured 2026-09-21 on this pack: with a 46 m cone the frame lifted to a flat grey and
// the beam itself was invisible.
// What a console did instead: one card, kept along the beam axis and spun around it to
// face the camera. Look straight down the beam and the card turns edge-on and disappears
// - which is correct, because looking along a beam you see the lit ground, not the shaft.
// Turn the torch across the view and the card shows its full width.
shader_type spatial;
// cull_front, not cull_disabled: the player stands INSIDE the cone, so the near wall
// covers the whole frame and adds its colour to every pixel - the picture turns milky
// and the beam disappears. Only the far wall is drawn, which is what you see looking
// down the beam.
render_mode blend_add, cull_front, depth_draw_never, unshaded, shadows_disabled, fog_disabled;

group_uniforms Shape;
// 1: the card spins around the beam to face the camera. Looking straight down the beam it
// then turns edge-on and vanishes, which is right for a shot from the side but leaves the
// first person with no shaft at all.
// 0: the card keeps its own orientation. Two cards crossed at ninety degrees - the way
// every console game drew a shaft - are then visible from any angle, including down the axis.
uniform float billboard : hint_range(0.0, 1.0, 1.0) = 0.0;
// 1: the beam is built from a camera-facing card (first person). 0: the NODE MESH is
// used instead - a cone under a lamp, seen from outside. From outside a cone works,
// because the viewer is not standing at its apex; in first person that same cone
// covers the whole frame.
uniform float use_mesh : hint_range(0.0, 1.0, 1.0) = 0.0;
// Metres of beam drawn and how wide it opens at the far end.
uniform float beam_length : hint_range(2.0, 120.0, 1.0) = 42.0;
uniform float beam_width : hint_range(0.2, 40.0, 0.1) = 13.0;

group_uniforms Look;
uniform vec4 beam_color : source_color = vec4(1.0, 0.94, 0.78, 1.0);
uniform float brightness : hint_range(0.0, 3.0, 0.01) = 0.34;
// Steps across the cone. Two or three read as cut paper; eight is a modern shaft.
uniform float bands : hint_range(1.0, 8.0, 1.0) = 3.0;
// How quickly the light gives up along the cone. 1 is linear, higher dies sooner.
uniform float falloff : hint_range(0.5, 6.0, 0.1) = 2.2;

group_uniforms Motion;
uniform float steps_per_second : hint_range(1.0, 30.0, 1.0) = 8.0;
// Amount the whole beam breathes. Small: it is a torch, not a fire.
uniform float flicker : hint_range(0.0, 0.6, 0.01) = 0.12;

global uniform float psx_colour_levels;

varying float along;   // 0 at the lens, 1 at the far end
varying float across;   // -1 to 1 across the card


// Transparency THROUGH DITHERING, not through blending - that is how the hardware did
// it: a pixel is either there or it is not, and half transparency comes out of a dot
// pattern. A 4x4 Bayer pattern, the same one the screen pass and the surfaces use.
float ea_bayer01(vec2 px) {
	int x = int(mod(px.x, 4.0));
	int y = int(mod(px.y, 4.0));
	int[16] pattern = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};
	return (float(pattern[y * 4 + x]) + 0.5) / 16.0;
}

void vertex() {
	// `return` is not allowed inside `vertex()` - the shader fails to compile, Godot
	// swaps the material for a white one and the cone shows up in frame like a tent.
	// The whole mesh branch therefore lives in an if/else, not in an early exit.
	if (use_mesh > 0.5) {
		// The cone stands on its own Y axis: apex at the top, mouth at the bottom.
		along = clamp(0.5 - VERTEX.y, 0.0, 1.0);
		across = 0.0;
	} else {
	// QuadMesh: local x is width, local y is length, both from -0.5 to 0.5.
	along = clamp(VERTEX.y + 0.5, 0.0, 1.0);
	across = clamp(VERTEX.x * 2.0, -1.0, 1.0);

	vec3 source = (VIEW_MATRIX * MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	// The torch points along the node's -Z; in view space that is the beam axis.
	vec3 axis = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(0.0, 0.0, -1.0, 0.0)).xyz);
	// Perpendicular to the axis AND to the direction the camera looks: that is the widest
	// the card can be from here. Looking down the beam this goes to zero on its own.
	vec3 side_dir;
	if (billboard > 0.5) {
		side_dir = cross(axis, normalize(source));
		float side_length = length(side_dir);
		side_dir = side_length > 0.0001 ? side_dir / side_length : vec3(0.0);
	} else {
		side_dir = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz);
	}

	if (billboard > 0.5) {
		vec3 point = source + axis * (along * beam_length)
				+ side_dir * (across * 0.5 * beam_width * along);
		VERTEX = point;
		POSITION = PROJECTION_MATRIX * vec4(point, 1.0);
	} else {
		// Cone mode: seen FROM THE APEX only the FAR wall is visible, a disc of light
		// ahead of you. The near wall is culled (cull_front), otherwise it would add its
		// colour to every pixel and turn the night milky. Brightness grows with distance
		// from the eye, so right at the lens the beam does not exist.
		vec3 point = source + axis * (along * beam_length)
				+ side_dir * (across * 0.5 * beam_width * along);
		VERTEX = point;
		POSITION = PROJECTION_MATRIX * vec4(point, 1.0);
	}
	}
}

void fragment() {
	float t = floor(TIME * steps_per_second) / max(steps_per_second, 0.001);

	// Across the card the light is strongest in the middle; the steps put a hard rim on it.
	// In mesh mode the brightness comes from the rim of the cone, since there is no card.
	float across_falloff = use_mesh > 0.5
			? clamp(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0)
			: 1.0 - abs(across);
	float a = pow(1.0 - along, falloff) * across_falloff * smoothstep(0.05, 0.45, along);
	a = ceil(clamp(a, 0.0, 1.0) * bands) / bands;
	if (a <= 0.01) {
		discard;
	}

	float flicker_amount = 1.0 - flicker * fract(sin(t * 12.9898) * 43758.5453);
	vec3 colour = beam_color.rgb * brightness * a * flicker_amount;
	if (psx_colour_levels > 1.0) {
		vec3 gamma_col = pow(max(colour, vec3(0.0)), vec3(1.0 / 2.2));
		gamma_col = floor(gamma_col * psx_colour_levels + 0.5) / psx_colour_levels;
		colour = pow(max(gamma_col, vec3(0.0)), vec3(2.2));
	}
	if (a <= ea_bayer01(FRAGCOORD.xy / 3.0)) {
		discard;
	}
	ALBEDO = colour;
	ALPHA = 1.0;
}
