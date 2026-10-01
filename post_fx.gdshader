shader_type canvas_item;
// Camera look applied after 3D: gentle vignette + fine film grain (action-cam style, not a game screenshot).

uniform sampler2D screen : hint_screen_texture, filter_linear;
uniform float vignette = 0.28;
uniform float grain = 0.025;

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void fragment() {
	vec3 c = texture(screen, SCREEN_UV).rgb;
	vec2 q = SCREEN_UV - 0.5;
	c *= 1.0 - vignette * smoothstep(0.25, 0.85, length(q * vec2(1.3, 1.0)));
	c += (hash(SCREEN_UV * 1000.0 + fract(TIME * 7.13)) - 0.5) * grain;
	COLOR = vec4(c, 1.0);
}
