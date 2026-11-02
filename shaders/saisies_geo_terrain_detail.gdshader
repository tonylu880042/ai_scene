shader_type spatial;
render_mode fog_disabled;

// Geographic terrain keeps the orthophoto and the original haze response for
// the whole 24 km DEM.  The detail maps are blended only in the bounded S09
// left-bank mask supplied by SaisiesGeoLandscape.
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec3 haze : source_color = vec3(0.72, 0.80, 0.90);
uniform float haze_dist = 22000.0;
uniform float haze_max = 0.75;
uniform float brightness = 1.15;
uniform float mist = 0.0;

uniform bool detail_enabled = false;
uniform bool detail_force = false;
uniform sampler2D detail_albedo_tex : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D detail_normal_tex : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec2 detail_center_xz = vec2(0.0, 0.0);
uniform vec2 detail_forward_xz = vec2(0.0, -1.0);
uniform vec2 detail_left_xz = vec2(1.0, 0.0);
uniform float detail_side_start_m = 6.0;
uniform float detail_side_full_m = 9.0;
uniform float detail_side_end_m = 100.0;
uniform float detail_side_fade_m = 32.0;
uniform float detail_along_full_m = 72.0;
uniform float detail_along_edge_m = 112.0;
uniform float detail_uv_scale = 0.24;
// Muted olive palette calibrated against the source S09 grass ROI.  The old
// palette's red/blue channels were too low, which made the detail read as a
// neon green wall even after its luminance ramp was fixed.
uniform vec3 detail_shadow_green : source_color = vec3(0.32, 0.35, 0.20);
uniform vec3 detail_sun_green : source_color = vec3(0.54, 0.57, 0.34);
uniform float detail_brightness = 0.93;

varying float dist;
varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	dist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
	// Keep this base path byte-for-byte equivalent in behaviour to
	// real_terrain.gdshader outside the local mask.
	vec3 a = texture(albedo_tex, UV).rgb * brightness;
	float h = max(haze_max * (1.0 - exp(-dist / haze_dist)), mist);
	vec3 base_albedo = a * (1.0 - h);
	float detail_mask = 0.0;
	if (detail_enabled) {
		if (detail_force) {
			detail_mask = 1.0;
		} else {
			vec2 delta_xz = world_position.xz - detail_center_xz;
			vec2 forward_axis = normalize(detail_forward_xz);
			vec2 left_axis = normalize(detail_left_xz);
			float along_m = abs(dot(delta_xz, forward_axis));
			float left_m = dot(delta_xz, left_axis);
			float along_mask = 1.0 - smoothstep(detail_along_full_m, detail_along_edge_m, along_m);
			float side_in = smoothstep(detail_side_start_m, detail_side_full_m, left_m);
			float side_out = 1.0 - smoothstep(detail_side_end_m, detail_side_end_m + detail_side_fade_m, left_m);
			detail_mask = clamp(along_mask * side_in * side_out, 0.0, 1.0);
		}
		if (detail_mask > 0.0001) {
			vec2 detail_uv = world_position.xz * detail_uv_scale;
			vec3 texel = texture(detail_albedo_tex, detail_uv).rgb;
			float luminance = dot(texel, vec3(0.299, 0.587, 0.114));
			// JPEG samples are decoded to linear here.  The old .12.. .82
			// range put nearly half of this grass atlas below the ramp and made
			// the local field read as a dark green blob.
			float value = smoothstep(0.02, 0.35, luminance);
			float broad_patch = 0.965 + 0.045 * sin(world_position.x * 0.021 + world_position.z * 0.017);
			vec3 green = mix(detail_shadow_green, detail_sun_green, value) * broad_patch * detail_brightness;
			// Keep the atlas's fine variation while compressing its high-contrast
			// response so the bank and terrain share one soft grass tone.
			green *= 0.95 + 0.08 * texel.g;
			base_albedo = mix(base_albedo, green * (1.0 - h), detail_mask);
			NORMAL_MAP = mix(vec3(0.5, 0.5, 1.0), texture(detail_normal_tex, detail_uv).rgb, detail_mask);
			NORMAL_MAP_DEPTH = 0.32 * detail_mask;
		}
	}
	ALBEDO = base_albedo;
	EMISSION = haze * h;
	ROUGHNESS = 1.0;
	SPECULAR = 0.15;
}
