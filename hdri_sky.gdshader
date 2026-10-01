shader_type sky;
// Equirectangular HDRI sky with a yaw so the photographed sun can be lined up with the DirectionalLight
// (course_setup.gd sets `yaw` every frame from the sun direction).

uniform sampler2D pano : source_color, filter_linear, repeat_enable;
uniform float yaw = 0.0;          // radians added to the world azimuth before sampling
uniform float energy = 1.0;
uniform float horizon_fill = 0.0;  // mix toward a flat haze colour below the horizon (pure-sky HDRIs are blank there)
uniform vec3 haze : source_color = vec3(0.78, 0.84, 0.92);

void sky() {
	vec3 d = normalize(EYEDIR);
	float az = atan(d.x, -d.z) + yaw;
	vec2 uv = vec2(fract(az / TAU + 0.5), acos(clamp(d.y, -1.0, 1.0)) / PI);
	vec3 c = texture(pano, uv).rgb * energy;
	c = mix(c, haze * energy, horizon_fill * smoothstep(0.02, -0.15, d.y));
	COLOR = c;
}
