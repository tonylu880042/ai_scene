shader_type sky;
// Procedural alpine sky: blue gradient, drifting cumulus layer, sun disc that clouds can cover.

uniform sampler2D cloud_tex : repeat_enable, filter_linear_mipmap;
uniform vec3 top_color : source_color = vec3(0.10, 0.36, 0.86);
uniform vec3 horizon_color : source_color = vec3(0.62, 0.78, 0.95);
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.5;
uniform float cloud_speed = 0.003;

void sky() {
	vec3 d = EYEDIR;
	float h = clamp(d.y, 0.0, 1.0);
	vec3 col = mix(horizon_color, top_color, pow(h, 0.5));
	float c = 0.0;
	if (d.y > -0.05) {
		vec2 uv = d.xz / (max(d.y, 0.0) + 0.3) * 0.32 + vec2(TIME * cloud_speed, 0.0);  // low frequency = big cumulus
		float n = texture(cloud_tex, uv).r * 0.55 + texture(cloud_tex, uv * 2.1 + 0.37).r * 0.3 + texture(cloud_tex, uv * 4.7).r * 0.15;
		c = smoothstep(1.0 - cloud_cover, 1.0 - cloud_cover + 0.22, n) * smoothstep(-0.02, 0.22, d.y);
		vec3 ccol = mix(vec3(0.72, 0.78, 0.88), vec3(1.0), clamp(n * 1.3, 0.0, 1.0));
		col = mix(col, ccol, c * 0.92);
	}
	float s = max(dot(d, LIGHT0_DIRECTION), 0.0);
	col += LIGHT0_COLOR * (pow(s, 900.0) * 6.0 + pow(s, 12.0) * 0.18) * (1.0 - c * 0.85);
	COLOR = col;
}
