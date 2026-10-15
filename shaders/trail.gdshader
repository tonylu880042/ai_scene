shader_type spatial;
// Alpine trail surface. The mesh covers the walked path plus a blend band on each side; UV.x = u / half-width
// (|UV.x| <= 1 on the walked surface). A noisy mask turns the band into a ragged worn edge where grass creeps
// in, and the dirt itself is mottled with gravel, darker damp patches and pebbly spots instead of clean
// symmetric bands. The grass side uses the same maths as terrain.gdshader so the seam with the meadow is invisible.

uniform sampler2D dirt_d : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D dirt_n : hint_normal, repeat_enable, filter_linear_mipmap;
uniform sampler2D gravel_d : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D grass_d : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D grass_n : hint_normal, repeat_enable, filter_linear_mipmap;
uniform vec3 dirt_tint : source_color = vec3(0.68, 0.64, 0.60);   // the source trail texture is pinkish
uniform vec3 grass_tint : source_color = vec3(0.55, 0.90, 0.30);
uniform vec3 grass_tint_dry : source_color = vec3(0.78, 0.82, 0.38);
uniform float uv_scale = 0.2;
uniform float edge_noise = 0.7;      // how ragged the edge is
uniform float grass_islands = 0.25;  // tufts of grass surviving inside the trail

varying vec3 wp;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
	float a = 0.5, s = 0.0;
	for (int i = 0; i < 4; i++) { s += a * vnoise(p); p = p * 2.07 + 13.0; a *= 0.5; }
	return s;
}

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = wp.xz * uv_scale;
	// --- grass, identical to terrain.gdshader (flat ground: top projection)
	float mac = dot(texture(grass_d, wp.xz * uv_scale * 0.11).rgb, vec3(0.33));
	vec3 g = texture(grass_d, wp.xz * uv_scale * 0.75).rgb * (0.55 + mac * 1.7);
	float patch = texture(grass_d, wp.xz * 0.009).g;
	float dry = smoothstep(0.35, 0.65, texture(grass_d, wp.xz * 0.004 + 0.3).r);
	g *= mix(grass_tint, grass_tint_dry, dry * 0.7) * mix(0.8, 1.25, patch);

	// --- mottled dirt: base trail texture, gravel patches, damp darker spots, a little colour drift
	vec3 d = texture(dirt_d, uv * 2.2).rgb * dirt_tint;
	float gp = smoothstep(0.55, 0.75, fbm(wp.xz * 0.35 + 7.0));
	d = mix(d, texture(gravel_d, uv * 1.4).rgb * vec3(0.85, 0.82, 0.78), gp * 0.65);
	float damp = smoothstep(0.6, 0.8, fbm(wp.xz * 0.18 + 31.0));
	d *= mix(1.0, 0.72, damp);
	d *= 0.9 + 0.2 * fbm(wp.xz * 0.06);

	// --- ragged edge mask (1 = bare trail) + grass islands inside
	float e = abs(UV.x) + (fbm(wp.xz * 2.4) - 0.5) * edge_noise + (fbm(wp.xz * 0.5 + 5.0) - 0.5) * edge_noise;
	float trail = 1.0 - smoothstep(0.82, 1.08, e);
	float island = smoothstep(0.72, 0.8, fbm(wp.xz * 0.9 + 90.0)) * grass_islands * smoothstep(0.3, 0.8, abs(UV.x));
	trail *= 1.0 - island;

	ALBEDO = mix(g, d, trail);
	NORMAL_MAP = mix(texture(grass_n, uv * 0.75).rgb, texture(dirt_n, uv * 2.2).rgb, trail);
	ROUGHNESS = mix(0.95, 0.9 - damp * 0.15, trail);
}
