shader_type spatial;
render_mode unshaded, depth_draw_opaque;
// Sea of clouds: a billowing layer (vertex displacement from two noise scales), shaded from the noise
// slope against the sun so the tops look puffy, soft where hillsides dip into it, with a few gaps.

uniform sampler2D big_tex : repeat_enable, filter_linear_mipmap;
uniform sampler2D detail_tex : repeat_enable, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform vec3 sun_dir = vec3(0.3, 0.6, 0.7);   // world space, toward the sun (set by CourseSetup)
uniform vec3 lit_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 shadow_color : source_color = vec3(0.46, 0.57, 0.77);
uniform float amplitude = 55.0;       // billow height (m)
uniform float big_scale = 0.00045;
uniform float detail_scale = 0.0028;
uniform float hole_level = 0.30;      // noise below this becomes a gap in the clouds
uniform float soft_depth = 6.0;       // fade where terrain pokes through
uniform float opacity = 1.0;
uniform float near_fade = 40.0;       // fade out within this distance so the camera never sits inside a hard sheet

varying vec3 wpos;

float cloud_h(vec2 w, float lod) {
	float b = textureLod(big_tex, w * big_scale, lod).r;
	float d = textureLod(detail_tex, w * detail_scale, lod).r;
	return b * 0.66 + d * 0.34;
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += (cloud_h(w.xz, 0.0) - 0.5) * amplitude;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float e = 7.0;
	float h = cloud_h(wpos.xz, 0.0);
	float dx = cloud_h(wpos.xz + vec2(e, 0.0), 0.0) - cloud_h(wpos.xz - vec2(e, 0.0), 0.0);
	float dz = cloud_h(wpos.xz + vec2(0.0, e), 0.0) - cloud_h(wpos.xz - vec2(0.0, e), 0.0);
	vec3 n = normalize(vec3(-dx * amplitude * 0.9, 2.0 * e * 0.5, -dz * amplitude * 0.9));
	float lit = clamp(dot(n, normalize(sun_dir)) * 0.5 + 0.55, 0.0, 1.0);
	float billow = smoothstep(0.35, 0.75, h);            // higher = whiter, thicker tops
	vec3 col = mix(shadow_color, lit_color, lit * (0.55 + 0.45 * billow));
	col = mix(col, shadow_color * 0.85, (1.0 - billow) * 0.35);  // thin, greyer cloud in the dips

	float depth = texture(depth_tex, SCREEN_UV).x;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	v.xyz /= v.w;
	float behind = max(-v.z + VERTEX.z, 0.0);
	float soft = smoothstep(0.0, soft_depth, behind);

	ALBEDO = col;
	ALPHA = smoothstep(hole_level, hole_level + 0.08, h) * soft * opacity * smoothstep(6.0, near_fade, length(VERTEX));
}
