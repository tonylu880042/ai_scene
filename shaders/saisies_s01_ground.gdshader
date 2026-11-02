shader_type spatial;
// S01-only diagnostic: the sampled overlay is a local triangle surface and
// must remain visible while front-face winding is checked in the native pass.
// No shared terrain/asphalt shader uses this cull mode.
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// A deliberately small S01-only ground overlay.  It is placed on top of
// sampled R14 terrain patches, so it can add the two green slope openings
// without recolouring the full geographic terrain material.
uniform vec3 grass_shadow : source_color = vec3(0.12, 0.20, 0.055);
uniform vec3 grass_sun : source_color = vec3(0.30, 0.43, 0.12);
uniform float variation_scale = 0.08;
uniform float slope_darkening = 0.18;

varying vec3 world_position;

float hash12(vec2 value) {
	vec3 p3 = fract(vec3(value.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float broad = hash12(floor(world_position.xz * variation_scale));
	float fine = hash12(floor(world_position.xz * 0.31));
	float mix_amount = clamp(0.28 + broad * 0.42 + fine * 0.18, 0.0, 1.0);
	vec3 colour = mix(grass_shadow, grass_sun, mix_amount);
	float slope = clamp(NORMAL.y, 0.0, 1.0);
	colour *= mix(1.0 - slope_darkening, 1.0, slope);
	ALBEDO = colour;
	ROUGHNESS = 0.96;
	SPECULAR = 0.06;
}
