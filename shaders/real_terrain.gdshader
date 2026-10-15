shader_type spatial;
render_mode fog_disabled;
// Real terrain backdrop: orthophoto albedo, own aerial perspective (the scene's distance fog would erase
// mountains kilometres away), and a mist fade driven by real_terrain.gd during white-outs.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec3 haze : source_color = vec3(0.72, 0.80, 0.90);
uniform float haze_dist = 22000.0;   // e-folding distance of the haze (m)
uniform float haze_max = 0.75;
uniform float brightness = 1.15;
uniform float mist = 0.0;            // 0..1 white-out amount

varying float dist;

void vertex() {
	dist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
	vec3 a = texture(albedo_tex, UV).rgb * brightness;
	float h = max(haze_max * (1.0 - exp(-dist / haze_dist)), mist);
	ALBEDO = a * (1.0 - h);
	EMISSION = haze * h;
	ROUGHNESS = 1.0;
	SPECULAR = 0.15;
}
