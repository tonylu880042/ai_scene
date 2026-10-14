shader_type spatial;
// Route terrain. Vertex colour: r = sand(0) -> grass(1), g = bare rock (alpine). Steep faces turn to rock too,
// unless vertex alpha is 0 (real mountains: their rock mask comes from an orthophoto, forested slopes stay green).

uniform sampler2D sand_d : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D sand_n : hint_normal, repeat_enable, filter_linear_mipmap;
uniform sampler2D grass_d : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D grass_n : hint_normal, repeat_enable, filter_linear_mipmap;
uniform sampler2D rock_d : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D rock_n : hint_normal, repeat_enable, filter_linear_mipmap;
uniform float dirt_strength = 1.0;
uniform vec3 grass_tint : source_color = vec3(0.55, 0.90, 0.30);
uniform vec3 grass_tint_dry : source_color = vec3(0.78, 0.82, 0.38);  // sun-bleached patches
uniform vec3 rock_tint : source_color = vec3(0.5, 0.5, 0.5);  // neutral grey granite (the source rock is pale and warm)
uniform float uv_scale = 0.2;
uniform float ortho_gain = 1.5;    // real mountains: orthophoto colour (vertex CUSTOM0, alpha = weight) brightened this much
uniform float rock_streaks = 0.0;  // limestone cliffs: dark vertical water streaks, warm stains, two-scale rock (0 = off)

varying vec3 wp;
varying vec4 ortho;

// triplanar colour sample: no stretching on steep faces
vec3 tri(sampler2D t, vec3 p, vec3 n, float sc) {
	vec3 w = pow(abs(n), vec3(4.0));
	w /= w.x + w.y + w.z;
	return texture(t, p.zy * sc).rgb * w.x + texture(t, p.xz * sc).rgb * w.y + texture(t, p.xy * sc).rgb * w.z;
}

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ortho = CUSTOM0;
}

void fragment() {
	vec2 uv = wp.xz * uv_scale;
	vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float rock = max(COLOR.g, smoothstep(0.35, 0.6, 1.0 - wn.y) * COLOR.a);  // alpine altitude or steep slope
	// grass: two scales against visible tiling, plus slow patchy light/dry variation
	float mac = dot(tri(grass_d, wp, wn, uv_scale * 0.11), vec3(0.33));  // large-scale light/dark
	vec3 g = tri(grass_d, wp, wn, uv_scale * 0.75) * (0.55 + mac * 1.7);
	float patch = texture(grass_d, wp.xz * 0.009).g;
	float dry = smoothstep(0.35, 0.65, texture(grass_d, wp.xz * 0.004 + 0.3).r);
	g *= mix(grass_tint, grass_tint_dry, dry * 0.7) * mix(0.8, 1.25, patch);
	vec3 low_d = mix(texture(sand_d, uv).rgb, g, COLOR.r);
	low_d = mix(low_d, texture(sand_d, uv * 1.6).rgb * 0.8, COLOR.b * dirt_strength);  // worn dirt along the trail edge
	vec3 low_n = mix(texture(sand_n, uv).rgb, texture(grass_n, uv * 0.75).rgb, COLOR.r);
	vec3 rk = tri(rock_d, wp, wn, uv_scale * 0.5);
	if (rock_streaks > 0.0) {
		rk = mix(rk, tri(rock_d, wp, wn, uv_scale * 0.13), 0.5);  // second scale: no visible tiling on big faces
		rk *= 0.6 + 0.8 * dot(tri(rock_d, wp, wn, uv_scale * 4.0), vec3(0.33));  // close-up grain (1.25 m repeat)
	}
	rk = vec3(dot(rk, vec3(0.3, 0.59, 0.11))) * rock_tint;  // desaturated: grey granite
	if (rock_streaks > 0.0) {
		float streak = texture(rock_d, vec2((wp.x + wp.z) * 0.015, wp.y * 0.0015)).r;   // stretched down the face
		float stain = smoothstep(0.55, 0.75, texture(rock_d, wp.xz * 0.003 + vec2(wp.y * 0.004, 0.0)).g);
		rk *= mix(1.0, mix(0.55, 1.2, streak), rock_streaks);
		rk = mix(rk, rk * vec3(1.15, 0.95, 0.75), stain * rock_streaks);
	}
	ALBEDO = mix(low_d, rk, rock);
	if (ortho.a > 0.001) {  // real mountains: the photo's colour, the procedural textures only as fine detail
		vec3 oc = ortho.rgb / ortho.a;
		float detail = clamp(dot(ALBEDO, vec3(0.333)) / 0.35, 0.6, 1.4);
		ALBEDO = mix(ALBEDO, oc * ortho_gain * detail, ortho.a);
	}
	// rock normals projected along the face's dominant axis (a top-down projection streaks on cliffs)
	vec2 ruv = abs(wn.y) > 0.7 ? wp.xz : (abs(wn.x) > abs(wn.z) ? wp.zy : wp.xy);
	vec3 rn = texture(rock_n, ruv * uv_scale * 0.5).rgb;
	if (rock_streaks > 0.0) {
		rn = normalize(mix(rn, texture(rock_n, ruv * uv_scale * 4.0).rgb, 0.5) * 2.0 - 1.0) * 0.5 + 0.5;
		NORMAL_MAP_DEPTH = 2.0;
	}
	NORMAL_MAP = mix(low_n, rn, rock);
	ROUGHNESS = 0.95;
}
