shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, fog_disabled, blend_mix, depth_draw_never;

// This shader is a material-only S03 correction.  It is used on the small
// S01 grass overlays and on SaisiesGeoTerrain with the original orthophoto
// bound as terrain_albedo_tex.  No vertex is moved here.
uniform bool terrain_mode = false;
uniform sampler2D terrain_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float terrain_brightness = 1.05;
uniform vec3 terrain_haze : source_color = vec3(0.72, 0.80, 0.90);
uniform float terrain_haze_dist = 22000.0;
uniform float terrain_haze_max = 0.72;
uniform float terrain_mist = 0.0;

uniform vec3 grass_shadow : source_color = vec3(0.10, 0.15, 0.065);
uniform vec3 grass_mid : source_color = vec3(0.22, 0.29, 0.135);
uniform vec3 grass_sun : source_color = vec3(0.32, 0.39, 0.20);
uniform float variation_scale = 0.008;
uniform float fine_scale = 0.040;
uniform float slope_darkening = 0.08;

// The mask is an oriented, soft ellipse in the S03 route frame.  It is also
// camera bounded so the accepted S01 views retain their original materials.
uniform bool mask_enabled = true;
uniform vec2 region_center_xz = vec2(0.0, 0.0);
uniform vec2 region_forward_xz = vec2(0.0, -1.0);
uniform vec2 region_left_xz = vec2(1.0, 0.0);
uniform float region_along_m = 900.0;
uniform float region_side_m = 700.0;
uniform float region_fade_m = 140.0;
uniform vec3 camera_center_world = vec3(0.0);
uniform float camera_radius_m = 340.0;
uniform float camera_fade_m = 100.0;
uniform float height_full_m = 300.0;
uniform float height_fade_m = 450.0;
uniform bool overlay_pass = true;
uniform float overlay_strength = 0.95;
uniform float ground_emission_strength = 0.12;

varying vec3 world_position;
varying float view_distance;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float smooth_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 local = fract(p);
	local = local * local * (3.0 - 2.0 * local);
	float a = hash12(cell);
	float b = hash12(cell + vec2(1.0, 0.0));
	float c = hash12(cell + vec2(0.0, 1.0));
	float d = hash12(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, local.x), mix(c, d, local.x), local.y);
}

float ground_mask(float camera_distance) {
	if (!mask_enabled) {
		return 1.0;
	}
	vec2 delta = world_position.xz - region_center_xz;
	vec2 forward_axis = normalize(region_forward_xz);
	vec2 left_axis = normalize(region_left_xz);
	float along = abs(dot(delta, forward_axis));
	float side = abs(dot(delta, left_axis));
	float along_fade = max(region_fade_m, 0.001);
	float side_fade = max(region_fade_m, 0.001);
	float along_mask = 1.0 - smoothstep(region_along_m, region_along_m + along_fade, along);
	float side_mask = 1.0 - smoothstep(region_side_m, region_side_m + side_fade, side);
	float ellipse = length(vec2(along / max(region_along_m, 0.001), side / max(region_side_m, 0.001)));
	float ellipse_mask = 1.0 - smoothstep(0.92, 1.12, ellipse);
	// A low-frequency perturbation prevents an artificial straight color seam
	// at the edge while keeping the whole visible junction inside the mask.
	float edge_mottle = 0.90 + 0.10 * smooth_noise(world_position.xz * 0.014 + vec2(7.0, -3.0));
	float camera_mask = 1.0 - smoothstep(camera_radius_m, camera_radius_m + camera_fade_m, camera_distance);
	float upward_height = max(world_position.y - camera_center_world.y, 0.0);
	float height_mask = 1.0 - smoothstep(height_full_m, height_fade_m, upward_height);
	return clamp(min(along_mask * side_mask, ellipse_mask) * edge_mottle * camera_mask * height_mask, 0.0, 1.0);
}

vec3 grass_colour(vec3 world_normal) {
	float broad = smooth_noise(world_position.xz * variation_scale);
	float mid = smooth_noise(world_position.xz * (variation_scale * 2.25) + vec2(19.0, 11.0));
	float fine = smooth_noise(world_position.xz * fine_scale + vec2(-13.0, 5.0));
	float mix_amount = clamp(0.13 + broad * 0.46 + mid * 0.20 + fine * 0.17, 0.0, 1.0);
	vec3 colour = mix(grass_shadow, grass_mid, smoothstep(0.05, 0.62, mix_amount));
	colour = mix(colour, grass_sun, smoothstep(0.58, 0.96, mix_amount));
	float world_up = clamp(dot(normalize(world_normal), vec3(0.0, 1.0, 0.0)), 0.0, 1.0);
	colour *= mix(1.0 - slope_darkening, 1.0, world_up);
	return colour;
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	view_distance = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
	// NORMAL is view-space in a spatial fragment shader.  Converting it through
	// INV_VIEW_MATRIX keeps slope response correct for the fixed review camera.
	vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float camera_distance = distance((INV_VIEW_MATRIX[3]).xyz, camera_center_world);
	float mask = ground_mask(camera_distance);
	vec3 grass = grass_colour(world_normal);
	if (overlay_pass) {
		// This pass is attached as Material.next_pass to the accepted material.
		// The original orthophoto or S01 ground shader therefore remains intact
		// outside the soft mask, including all distant S01/S02 views.
		ALBEDO = grass;
		ALPHA = mask * overlay_strength;
		EMISSION = grass * (ground_emission_strength * mask);
		ROUGHNESS = 0.96;
		SPECULAR = 0.06;
	} else {
		vec3 base_albedo = grass;
		float haze = 0.0;
		if (terrain_mode) {
			base_albedo = texture(terrain_albedo_tex, UV).rgb * terrain_brightness;
			haze = max(terrain_haze_max * (1.0 - exp(-view_distance / max(terrain_haze_dist, 0.001))), terrain_mist);
			base_albedo = mix(base_albedo, grass, mask);
		} else {
			// Overlay meshes are already bounded to their sampled S01 triangles.
			base_albedo = mix(vec3(0.0), base_albedo, mask);
		}
		ALBEDO = base_albedo * (1.0 - haze);
		if (terrain_mode) {
			EMISSION = terrain_haze * haze;
		}
		ROUGHNESS = 0.96;
		SPECULAR = 0.06;
	}
}
