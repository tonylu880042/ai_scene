shader_type spatial;

uniform vec4 shallow_color : source_color = vec4(0.1, 0.7, 0.7, 1.0);
uniform vec4 deep_color : source_color = vec4(0.0, 0.18, 0.45, 1.0);
uniform float depth_max = 8.0;

uniform sampler2D normal_a : hint_normal, repeat_enable, filter_linear_mipmap;
uniform sampler2D normal_b : hint_normal, repeat_enable, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform float normal_scale = 0.08;     // texture repeats per metre
uniform float flow_speed = 0.02;       // UV scroll speed (two layers run opposite ways)
uniform float normal_strength = 1.0;
uniform float water_roughness : hint_range(0.0, 1.0) = 0.12;
uniform float water_specular : hint_range(0.0, 1.0) = 0.9;

uniform float wave_steepness : hint_range(0.0, 1.0) = 0.04;
uniform float wave_length = 40.0;
uniform float wave_speed = 1.0;

uniform vec3 sun_dir = vec3(0.3, 0.6, 0.7);  // world space, toward the sun (set by CourseSetup)
uniform float sparkle = 9.0;

varying vec3 wpos;

vec3 gerstner(vec2 p, vec2 dir, float len, float steep, float t) {
	float k = TAU / len;
	float c = sqrt(9.8 / k) * wave_speed;
	vec2 d = normalize(dir);
	float f = k * (dot(d, p) - c * t);
	float a = steep / k;
	return vec3(d.x * a * cos(f), a * sin(f), d.y * a * cos(f));
}

void vertex() {
	vec2 p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	VERTEX += gerstner(p, vec2(1.0, 0.3), wave_length, wave_steepness, TIME)
			+ gerstner(p, vec2(-0.4, 1.0), wave_length * 0.6, wave_steepness * 0.7, TIME)
			+ gerstner(p, vec2(0.7, -0.8), wave_length * 0.35, wave_steepness * 0.5, TIME);
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = wpos.xz * normal_scale;
	vec3 n1 = texture(normal_a, uv + TIME * flow_speed * vec2(1.0, 0.3)).rgb;
	vec3 n2 = texture(normal_b, uv * 1.7 - TIME * flow_speed * vec2(0.7, 1.0)).rgb;
	NORMAL_MAP = mix(n1, n2, 0.5);
	NORMAL_MAP_DEPTH = normal_strength;

	// sun sparkle: mirror reflection of the sun off the perturbed (flat-water) normal, sharp so only facets twinkle
	vec3 nm = mix(n1, n2, 0.5) * 2.0 - 1.0;
	vec3 wn = normalize(vec3(nm.x * normal_strength * 2.0, 1.0, nm.y * normal_strength * 2.0));
	vec3 vw = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	float glint = pow(max(dot(reflect(-vw, wn), normalize(sun_dir)), 0.0), 500.0);
	EMISSION = vec3(1.0, 0.96, 0.85) * glint * sparkle;

	float depth = texture(depth_tex, SCREEN_UV).x;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	v.xyz /= v.w;
	float water_depth = max(-v.z + VERTEX.z, 0.0);
	ALBEDO = mix(shallow_color.rgb, deep_color.rgb, smoothstep(0.0, depth_max, water_depth));
	ROUGHNESS = water_roughness;
	SPECULAR = water_specular;
}
