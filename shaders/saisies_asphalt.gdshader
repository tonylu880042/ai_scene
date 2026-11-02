shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// The source asphalt detail has a warm photographic cast.  Keep its value
// variation and normal detail, but map the albedo to a neutral grey road so
// the summer grass and silver guardrails carry the colour of the scene.
uniform sampler2D albedo_tex : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;

void fragment() {
	vec3 texel = texture(albedo_tex, UV).rgb;
	float luminance = dot(texel, vec3(0.299, 0.587, 0.114));
	// Keep the value in a dark linear range; StandardMaterial-style values near
	// 0.8 turn almost white after the scene's summer exposure and sky light.
	float value = clamp(0.06 + luminance * 0.35, 0.05, 0.22);
	ALBEDO = vec3(value) * vec3(0.93, 0.95, 0.96);
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = 0.32;
	ROUGHNESS = 0.88;
	SPECULAR = 0.24;
}
