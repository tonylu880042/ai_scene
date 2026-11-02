shader_type spatial;
render_mode diffuse_lambert_wrap, specular_schlick_ggx;

// The supplied aerial_grass_rock texture is a useful detail map but its baked
// exposure leans ochre under a strong sun.  Map its luminance into a controlled
// summer alpine green so meadow banks stay close to the reference film.
uniform sampler2D albedo_tex : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec3 shadow_green : source_color = vec3(0.10, 0.20, 0.04);
uniform vec3 sun_green : source_color = vec3(0.37, 0.58, 0.13);
uniform float brightness = 0.88;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 texel = texture(albedo_tex, UV).rgb;
	float luminance = dot(texel, vec3(0.299, 0.587, 0.114));
	float value = smoothstep(0.12, 0.82, luminance);
	float broad_patch = 0.92 + 0.10 * sin(world_position.x * 0.021 + world_position.z * 0.017);
	vec3 green = mix(shadow_green, sun_green, value) * broad_patch * brightness;
	// Preserve a small amount of the original texture's local contrast without
	// allowing its warm channel to turn the whole slope yellow.
	green *= 0.90 + 0.18 * texel.g;
	ALBEDO = green;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = 0.32;
	ROUGHNESS = 0.94;
}
