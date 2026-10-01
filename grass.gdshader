shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_schlick_ggx;
// Meadow grass blades (MultiMesh). UV.y = height along the blade (0 root .. 1 tip).
// Wind: two travelling sine gusts bend the blade, more at the tip; per-instance hue / dryness variation;
// light passing through the blade (backlight) so sun-facing slopes glow instead of looking like plastic.

uniform vec3 root_color : source_color = vec3(0.05, 0.13, 0.03);
uniform vec3 tip_green : source_color = vec3(0.30, 0.50, 0.10);
uniform vec3 tip_dry : source_color = vec3(0.58, 0.55, 0.22);
uniform float dryness = 0.25;          // share of instances leaning to straw colour
uniform float wind_strength = 0.12;    // tip displacement (m) at gust peak
uniform float wind_speed = 1.6;
uniform vec2 wind_dir = vec2(0.8, 0.6);

varying float tipness;
varying vec3 tint;

float hash11(float n) { return fract(sin(n * 12.9898) * 43758.5453); }

void vertex() {
	tipness = UV.y;
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 dir = normalize(wind_dir);
	float phase = dot(wp.xz, dir) * 0.35 - TIME * wind_speed;
	float gust = sin(phase) * 0.6 + sin(phase * 2.7 + 1.3) * 0.25 + 0.35;
	float bend = wind_strength * gust * tipness * tipness;
	// displace in world space, then back to model space
	vec3 disp_world = vec3(dir.x, -0.25 * abs(gust) * tipness, dir.y) * bend;
	VERTEX += (inverse(MODEL_MATRIX) * vec4(disp_world, 0.0)).xyz;
	float h = hash11(float(INSTANCE_ID) + 0.5);
	float dry = smoothstep(1.0 - dryness, 1.0, h);
	tint = mix(tip_green * (0.75 + 0.5 * hash11(float(INSTANCE_ID) * 1.7)), tip_dry, dry);
}

void fragment() {
	vec3 c = mix(root_color, tint, smoothstep(0.0, 0.85, tipness));
	ALBEDO = c;
	ROUGHNESS = 0.75;
	SPECULAR = 0.25;
	BACKLIGHT = c * 0.6;                 // translucency
	AO = mix(0.35, 1.0, tipness);        // self-shadowed base of the clump
	AO_LIGHT_AFFECT = 0.6;
}
