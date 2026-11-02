shader_type spatial;

// The periwinkle photograph is used as an atlas source for small cards.  Its
// JPEG has a black background, so derive coverage from brightness and let the
// alpha scissor remove that background without modifying the source image.
render_mode cull_disabled, depth_prepass_alpha, diffuse_burley, specular_disabled;

uniform sampler2D atlas_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D normal_atlas : hint_normal, filter_linear_mipmap, repeat_disable;
uniform float alpha_cutoff : hint_range(0.0, 1.0) = 0.035;
uniform float alpha_softness : hint_range(0.001, 0.2) = 0.018;

void fragment() {
	vec4 source = texture(atlas_texture, UV);
	float brightness = dot(source.rgb, vec3(0.299, 0.587, 0.114));
	float coverage = smoothstep(alpha_cutoff, alpha_cutoff + alpha_softness, brightness);
	ALBEDO = source.rgb;
	NORMAL_MAP = texture(normal_atlas, UV).rgb;
	NORMAL_MAP_DEPTH = 0.35;
	ROUGHNESS = 0.88;
	ALPHA = coverage;
	ALPHA_SCISSOR_THRESHOLD = alpha_cutoff;
}
