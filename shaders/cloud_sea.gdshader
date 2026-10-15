shader_type spatial;
render_mode unshaded, depth_draw_opaque, cull_disabled;
// Sea of clouds. The mesh only carries the large, slow swell (so its silhouette undulates on the horizon);
// all billow detail is procedural fbm evaluated per pixel, so no triangle facets show. Lighting is faked:
// sun-facing billow tops are bright, crevices fall to a blue-grey, edges toward the sun get a silver lining,
// and the far field blends into the horizon haze of the HDRI sky. Soft where terrain dips into it.

uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform vec3 sun_dir = vec3(0.3, 0.6, 0.7);       // world space, toward the sun (set by CourseSetup)
uniform vec3 lit_color : source_color = vec3(1.0, 0.99, 0.97);
uniform vec3 shade_color : source_color = vec3(0.58, 0.66, 0.80);
uniform vec3 haze_color : source_color = vec3(0.78, 0.84, 0.92);
uniform float swell = 30.0;          // large-scale vertex swell (m)
uniform float swell_scale = 0.0006;
uniform float billow_scale = 0.0025; // per-pixel billow frequency (1/m)
uniform float billow_depth = 70.0;   // apparent height of the billows used for lighting (m)
uniform float billow_amp = 35.0;     // vertex height of the medium billows (silhouettes)
uniform float brightness = 1.7;      // > 1 so sunlit tops stay white after AgX tonemapping
uniform float wind = 1.2;            // drift (m/s)
uniform float coverage = 0.62;       // 1 = solid deck, lower = more gaps
uniform float opacity = 1.0;
uniform float soft_depth = 10.0;
uniform float haze_start = 4000.0;
uniform float haze_end = 14000.0;
uniform float near_fade = 25.0;

varying vec3 wpos;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p, int oct) {
	float a = 0.5, s = 0.0;
	mat2 r = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	for (int i = 0; i < oct; i++) { s += a * vnoise(p); p = r * p * 2.03 + 17.0; a *= 0.5; }
	return s;
}
// billowy field: inverted ridged noise gives rounded cauliflower tops
float billow(vec2 p, int oct) {
	float a = 0.5, s = 0.0;
	mat2 r = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	for (int i = 0; i < oct; i++) { s += a * (1.0 - abs(vnoise(p) * 2.0 - 1.0)); p = r * p * 2.11 + 31.0; a *= 0.5; }
	return s;
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 q = (w.xz + vec2(TIME * wind, 0.0)) * swell_scale;
	VERTEX.y += (fbm(q, 3) - 0.5) * 2.0 * swell;
	VERTEX.y += (billow((w.xz + vec2(TIME * wind, 0.0)) * billow_scale, 2) - 0.5) * billow_amp;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float dist = length(VERTEX);
	vec2 p = (wpos.xz + vec2(TIME * wind, 0.0)) * billow_scale;
	int oct = dist < 1500.0 ? 6 : 4;
	float h = billow(p, oct);
	float e = 0.15;
	float hx = billow(p + vec2(e, 0.0), oct), hz = billow(p + vec2(0.0, e), oct);
	vec3 n = normalize(vec3(-(hx - h) / e * billow_depth * billow_scale, 1.0, -(hz - h) / e * billow_depth * billow_scale));
	vec3 L = normalize(sun_dir);
	vec3 V = normalize(CAMERA_POSITION_WORLD - wpos);
	float diff = clamp(dot(n, L) * 0.6 + 0.5, 0.0, 1.0);            // wrapped: clouds never go black
	float cavity = smoothstep(0.35, 0.85, h);                          // crevices darker
	vec3 col = mix(shade_color, lit_color, smoothstep(0.15, 0.95, diff * (0.35 + 0.65 * cavity)));
	float rim = pow(clamp(dot(-V, L), 0.0, 1.0), 6.0) * (1.0 - cavity);  // silver lining toward the sun
	col += lit_color * rim * 0.35;
	col *= brightness;
	col = mix(col, haze_color * brightness * 0.9, smoothstep(haze_start, haze_end, dist));

	float cover = smoothstep(1.0 - coverage, 1.0 - coverage + 0.18, fbm(p * 0.13 + 3.0, 4) * 0.6 + h * 0.5);
	float depth = texture(depth_tex, SCREEN_UV).x;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	v.xyz /= v.w;
	float soft = smoothstep(0.0, soft_depth, max(-v.z + VERTEX.z, 0.0));

	ALBEDO = col;
	ALPHA = cover * soft * opacity * smoothstep(6.0, near_fade, dist);
}
