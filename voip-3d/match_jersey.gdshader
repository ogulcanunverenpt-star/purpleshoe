shader_type spatial;

uniform sampler2D skin_texture : source_color;
uniform vec4 jersey_color : source_color;
varying float jersey_mask;

void vertex() {
	jersey_mask = COLOR.a;
}

void fragment() {
	ALBEDO = mix(texture(skin_texture, UV).rgb, jersey_color.rgb, jersey_mask);
	ROUGHNESS = 0.85;
}
