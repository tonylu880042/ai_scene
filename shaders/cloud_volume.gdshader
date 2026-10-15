shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled, blend_mix;
// Volumetric sea of clouds, ray-marched inside a slab [base, top] below the runner.
// The mesh is a flat plane at the slab top; each fragment marches the view ray down through 3D fbm density,
// with a short light march toward the sun for self-shadowing (bright sunlit tops, blue-grey undersides),
// stops at the depth buffer (hills poke through softly) and fades to horizon haze far away.
// Expensive by design: it is meant for the offline --hq recordings (still runs real-time at lower step counts).

uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform vec3 sun_dir = vec3(0.3, 0.6, 0.7);      // world space, toward the sun (set by CourseSetup)
uniform vec3 sun_color : source_color = vec3(1.0, 0.97, 0.92);
uniform vec3 ambient_color : source_color = vec3(0.55, 0.64, 0.80);
uniform vec3 haze_color : source_color = vec3(0.78, 0.84, 0.92);
uniform float thickness = 120.0;       // slab depth below the plane (m)
uniform float scale = 0.0035;         // base noise frequency (1/m)
uniform float coverage = 0.55;        // 0..1
uniform float density = 0.06;        // extinction per metre at full density
uniform float wind = 1.5;             // drift (m/s)
uniform int steps = 64;
uniform float max_march = 900.0;      // metres of ray inside the slab
uniform float brightness = 1.25;      // > 1 so lit tops stay white after AgX
uniform float haze_start = 4000.0;
uniform float haze_end = 14000.0;
uniform int debug = 0;

varying vec3 wpos;

float h3(vec3 p) { p = fract(p * 0.3183099 + 0.1); p *= 17.0; return fract(p.x * p.y * p.z * (p.x + p.y + p.z)); }
float noise3(vec3 x) {
	vec3 i = floor(x), f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(h3(i), h3(i + vec3(1, 0, 0)), f.x), mix(h3(i + vec3(0, 1, 0)), h3(i + vec3(1, 1, 0)), f.x), f.y),
	           mix(mix(h3(i + vec3(0, 0, 1)), h3(i + vec3(1, 0, 1)), f.x), mix(h3(i + vec3(0, 1, 1)), h3(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
float fbm3(vec3 p, int oct) {
	float a = 0.5, s = 0.0;
	for (int i = 0; i < oct; i++) { s += a * noise3(p); p = p * 2.02 + vec3(13.1, 7.7, 3.3); a *= 0.5; }
	return s;
}

// depth (m) of the local cloud top below the slab top at horizontal position xz
float top_off(vec2 xz, int oct) {
	vec2 w = (xz + vec2(TIME * wind, 0.0)) * scale;
	vec3 q2 = vec3(w.x, 0.0, w.y);
	float n = 0.0, a = 0.5;
	vec3 r = q2;
	for (int i = 0; i < oct; i++) { n += a * (1.0 - abs(noise3(r) * 2.0 - 1.0)); r = r * 2.07 + vec3(13.1, 0.0, 3.3); a *= 0.5; }
	float bumps = clamp((n - 0.35) * 1.6, 0.0, 1.0);                     // cauliflower billows, 0..1
	float gaps = smoothstep(1.0 - coverage - 0.08, 1.0 - coverage + 0.08, fbm3(q2 * 0.15 + 5.0, 3));
	return thickness * mix(1.0, 0.9 * (1.0 - bumps), gaps);
}

float dens(vec3 p, int oct, float top_y) {
	float below = (top_y - p.y) - top_off(p.xz, oct);                   // > 0 inside the cloud
	return clamp(below / 6.0, 0.0, 1.0);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float top_y = wpos.y;
	vec3 ro = CAMERA_POSITION_WORLD;
	vec3 rd = normalize(wpos - ro);
	float cam_dist = length(wpos - ro);

	// scene depth along the ray (terrain stops the march)
	float depth = texture(depth_tex, SCREEN_UV).x;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	v.xyz /= v.w;
	float scene_dist = length(v.xyz);

	float far = smoothstep(haze_start, haze_end, cam_dist);
	vec3 L = normalize(sun_dir);
	float trans = 1.0;
	vec3 acc = vec3(0.0);
	if (rd.y < -0.0005) {
		float t_end = min(min((thickness) / -rd.y, max_march), scene_dist - cam_dist);
		int n = cam_dist < 3000.0 ? steps : steps / 2;
		int oct = cam_dist < 1500.0 ? 5 : 3;
		float dt = max(t_end, 0.0) / float(n);
		float jitter = fract(sin(dot(FRAGCOORD.xy, vec2(12.9898, 78.233))) * 43758.5453);
		bool hit = false;
		for (int i = 0; i < n; i++) {
			float t = (float(i) + jitter) * dt;
			vec3 p = wpos + rd * t;
			float d = dens(p, oct, top_y);
			if (d > 0.01) {
				if (!hit) {
					hit = true;
					float e = 6.0;
					float t0 = top_off(p.xz, oct);
					vec3 nrm = normalize(vec3(top_off(p.xz + vec2(e, 0.0), oct) - t0, e, top_off(p.xz + vec2(0.0, e), oct) - t0));
					float lam = clamp(dot(nrm, L) * 0.65 + 0.35, 0.0, 1.0);            // wrapped Lambert
					float ao = 1.0 - clamp(t0 / thickness, 0.0, 1.0);                  // deep troughs darker
					float rim = pow(clamp(dot(rd, L), 0.0, 1.0), 8.0) * (1.0 - lam);    // back-lit edges glow
					acc = sun_color * lam * mix(0.55, 1.0, ao) + ambient_color * mix(0.25, 0.45, ao) + sun_color * rim * 0.4;
				}
				trans *= exp(-d * density * dt);
				if (trans < 0.02) break;
			}
		}
		acc *= 1.0 - trans;
	}
	vec3 col = acc / max(1.0 - trans, 1e-4) * brightness;
	float alpha = 1.0 - trans;
	col = mix(col, haze_color * brightness * 0.92, far);
	alpha = mix(alpha, max(alpha, 0.97), far);
	ALBEDO = col;
	if (debug == 1) { vec3 q = (wpos + vec3(TIME * wind, 0.0, 0.0)) * scale; ALBEDO = vec3(fbm3(vec3(q.x, 0.0, q.z), 4)); ALPHA = 1.0; }
	else if (debug == 2) { float te = min(min(thickness / -rd.y, max_march), scene_dist - cam_dist); ALBEDO = vec3(clamp(te / max_march, 0.0, 1.0), 0.0, rd.y < -0.0005 ? 1.0 : 0.0); ALPHA = 1.0; }
	else if (debug == 3) { ALBEDO = vec3(alpha, 1.0 - trans, far); ALPHA = 1.0; }
	else {
	ALPHA = clamp(alpha, 0.0, 1.0) * smoothstep(5.0, 30.0, cam_dist);
	}
}
