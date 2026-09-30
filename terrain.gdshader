shader_type spatial;
// Route terrain. Vertex colour: r = sand(0) -> grass(1), g = bare rock (alpine). Steep faces turn to rock too.

uniform sampler2D sand_d : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D sand_n : hint_normal, repeat_enable, filter_linear_mipmap;
uniform sampler2D grass_d : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D grass_n : hint_normal, repeat_enable, filter_linear_mipmap;
uniform sampler2D rock_d : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D rock_n : hint_normal, repeat_enable, filter_linear_mipmap;
uniform vec3 grass_tint : source_color = vec3(0.55, 0.90, 0.30);
uniform vec3 grass_tint_dry : source_color = vec3(0.78, 0.82, 0.38);  // sun-bleached patches
uniform vec3 rock_tint : source_color = vec3(0.5, 0.5, 0.5);  // neutral grey granite (the source rock is pale and warm)
uniform float uv_scale = 0.2;

varying vec3 wp;

// triplanar colour sample: no stretching on steep faces
vec3 tri(sampler2D t, vec3 p, vec3 n, float sc) {
	vec3 w = pow(abs(n), vec3(4.0));
	w /= w.x + w.y + w.z;
	return texture(t, p.zy * sc).rgb * w.x + texture(t, p.xz * sc).rgb * w.y + texture(t, p.xy * sc).rgb * w.z;
}

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = wp.xz * uv_scale;
	vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float rock = max(COLOR.g, smoothstep(0.35, 0.6, 1.0 - wn.y));  // alpine altitude or steep slope
	// grass: two scales against visible tiling, plus slow patchy light/dry variation
	float mac = dot(tri(grass_d, wp, wn, uv_scale * 0.11), vec3(0.33));  // large-scale light/dark
	vec3 g = tri(grass_d, wp, wn, uv_scale * 0.75) * (0.55 + mac * 1.7);
	float patch = texture(grass_d, wp.xz * 0.009).g;
	float dry = smoothstep(0.35, 0.65, texture(grass_d, wp.xz * 0.004 + 0.3).r);
	g *= mix(grass_tint, grass_tint_dry, dry * 0.7) * mix(0.8, 1.25, patch);
	vec3 low_d = mix(texture(sand_d, uv).rgb, g, COLOR.r);
	vec3 low_n = mix(texture(sand_n, uv).rgb, texture(grass_n, uv * 0.75).rgb, COLOR.r);
	vec3 rk = tri(rock_d, wp, wn, uv_scale * 0.5);
	rk = vec3(dot(rk, vec3(0.3, 0.59, 0.11))) * rock_tint;  // desaturated: grey granite
	ALBEDO = mix(low_d, rk, rock);
	NORMAL_MAP = mix(low_n, texture(rock_n, uv * 0.5).rgb, rock);
	ROUGHNESS = 0.95;
}
