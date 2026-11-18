// photon's gbuffers + d4_deferred_shading lighting, run forward per terrain fragment

const MAT_SMALL_PLANTS: u32 = 2u;
const MAT_TALL_LOWER: u32 = 3u;
const MAT_TALL_UPPER: u32 = 4u;
const MAT_LEAVES: u32 = 5u;
const MAT_VINES: u32 = 6u;

fn get_material(input: MaterialInput, albedo: vec3<f32>) -> Mat {
    var m: Mat;
    m.albedo = albedo;
    m.sss_amount = 0.0;
    m.sheen_amount = 0.0;
    m.emission = 0.0;
    m.f0 = 0.02;
    m.roughness = 1.0;
    switch input.material {
        case 2u, 3u, 4u: {
            m.sss_amount = 0.5;
            m.sheen_amount = 1.0;
        }
        case 5u: {
            m.sss_amount = 1.0;
            m.sheen_amount = 0.5;
        }
        case 6u: {
            m.sss_amount = 0.6;
        }
        default: {}
    }
    // light sources: photon masks the bright texels of emissive blocks
    if input.emission > 0.0 {
        let srgb_max = pow(max_of(clamp01v(input.albedo.rgb)), 1.0 / 2.2);
        let mask = select(linear_step(0.5, 0.9, srgb_max), 1.0, input.fluid == 2u);
        m.emission = input.emission * mask * 0.66;
    }
    if block_pbr_maps() {
        let spec = block_specular_map(input.uv);
        if spec.r > 0.0 || spec.g > 0.0 {
            let smoothness = spec.r;
            m.roughness = sqr(1.0 - smoothness);
            m.f0 = select(spec.g, 0.9, spec.g * 255.0 > 229.5);
        }
        if spec.a < 0.999 && spec.a > 0.0 {
            m.emission = max(m.emission, spec.a * 0.5);
        }
        if spec.b * 255.0 > 64.5 {
            m.sss_amount = max(m.sss_amount, (spec.b * 255.0 - 65.0) / 190.0);
        }
    }
    return m;
}

// photon's include/surface/water_normal.glsl
fn gerstner_wave(coord: vec2<f32>, wave_dir: vec2<f32>, t: f32, noise: f32, wavelength: f32) -> f32 {
    let k = tau / wavelength;
    let w = sqrt(9.8 * k);
    let x = w * t - k * (dot(wave_dir, coord) + noise);
    return sqr(sin(x) * 0.5 + 0.5);
}

fn get_water_height(coord: vec2<f32>, flowing: bool, flow_dir: vec2<f32>) -> f32 {
    let t = select(0.5, 0.7, flowing) * frame.time;
    let angle = 30.0 * degree;
    var wave_dir = select(vec2<f32>(cos(angle), sin(angle)), flow_dir, flowing);
    var rot = mat2x2<f32>(vec2<f32>(cos(golden_angle), sin(golden_angle)), vec2<f32>(-sin(golden_angle), cos(golden_angle)));
    if flowing {
        rot = mat2x2<f32>(vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0));
    }
    let persistence = 0.5;
    let norm = (1.0 - persistence) / (1.0 - pow(persistence, 3.0));
    var noise_coord = (coord + vec2<f32>(0.0, 0.25 * t)) * 0.007;
    var height = 0.0;
    var amplitude = 1.0;
    var frequency = 0.7;
    var wavelength = 1.0;
    for (var i = 0; i < 3; i++) {
        let n = textureSampleLevel(noisetex, noisetex_sampler, noise_coord, 0.0).y;
        noise_coord *= 2.5;
        height += gerstner_wave(coord * frequency, wave_dir, t, n * 2.0, wavelength) * amplitude;
        amplitude *= persistence;
        frequency *= 1.7;
        wavelength *= 1.5;
        wave_dir = wave_dir * rot;
    }
    let variation = textureSampleLevel(noisetex, noisetex_sampler, (coord + vec2<f32>(0.0, 0.1 * t)) * 0.001, 0.0).y;
    height *= max(0.4, variation * 2.0 - 0.5);
    return height * norm;
}

fn screen_depth_to_distance(screen: vec2<f32>, depth: f32) -> f32 {
    let clip = vec4<f32>(screen.x * 2.0 - 1.0, 1.0 - screen.y * 2.0, depth, 1.0);
    let view = frame.projection_inverse * clip;
    return length(view.xyz / view.w);
}

fn biome_water_coeff(biome_water_color: vec3<f32>) -> vec3<f32> {
    let base = vec3<f32>(0.39, 0.14, 0.07) * water_absorption * rec709_to_rec2020;
    let forest = -0.15 * log(vec3<f32>(0.1245, 0.1797, 0.7108));
    let biome = -0.15 * log(biome_water_color + eps) - forest;
    return max(base + biome * 0.33, vec3<f32>(0.0));
}

// a texel on the segment between vanilla's fog (horizon) and sky (zenith) colours
fn mirror_is_vanilla_sky(m: vec3<f32>) -> bool {
    if max_of(m) > 1.05 {
        return false;
    }
    let g = vec3<f32>(1.0 / 2.2);
    let mg = pow(clamp01v(m), g);
    let fg = pow(clamp01v(frame.fog_color), g);
    let sg = pow(clamp01v(frame.sky_color), g);
    let d = sg - fg;
    let t = clamp01(dot(mg - fg, d) / max(dot(d, d), 1e-5));
    return distance(mg, fg + t * d) < 0.04;
}

fn sky_reflection_color(refl_dir: vec3<f32>, skylight: f32, unoccluded: bool) -> vec3<f32> {
    if in_overworld() {
        let up_dir = normalize(vec3<f32>(refl_dir.x, max(refl_dir.y, 0.0), refl_dir.z));
        let sky = atmosphere_scattering_both(up_dir, sun_color(), moon_color()) * (1.0 - frame.rain * 0.5);
        return select(sky * sqr(skylight), sky * mix(sqr(skylight), 1.0, 0.75), unoccluded);
    }
    if in_end() {
        return end_sky_color(refl_dir);
    }
    if in_nether() {
        return nether_sky_color(refl_dir);
    }
    return linear_to_rec2020(frame.fog_color) * 0.1;
}

fn shade_ray_hit(hit: RayHit, refl_dir: vec3<f32>, sky_refl: vec3<f32>, t: Times) -> vec3<f32> {
    let hit_shade = pow(vanilla_face_shade(hit.normal), 2.2);
    let hit_unshaded = hit.tint.rgb / max(hit_shade, 1e-4);
    let hit_albedo = linear_to_rec2020(clamp01v(hit.albedo.rgb * hit_unshaded));
    let hit_l = clamp(hit.light, vec2<f32>(0.0), vec2<f32>(1.0));
    let directional = (0.9 + 0.1 * hit.normal.x) * (0.8 + 0.2 * abs(hit.normal.y));
    let l = light_dir();

    var lighting = vec3<f32>(0.0);
    if in_overworld() {
        var hit_shadow = sqr(hit_l.y);
        if frame.has_shadow != 0u {
            let bias_p = hit.position + hit.normal * max(frame.shadow_center_texel * 2.0, 0.04);
            let sp = shadow_position(bias_p);
            let in_map = all(sp.xy >= vec2<f32>(0.0)) && all(sp.xy <= vec2<f32>(1.0)) && sp.z < 1.0;
            let s = textureSampleCompareLevel(shadow_map, shadow_sampler, clamp(sp.xy, vec2<f32>(0.0), vec2<f32>(1.0)), min(sp.z, 1.0));
            let fade = linear_step(0.85, 1.0, max(abs(sp.x * 2.0 - 1.0), abs(sp.y * 2.0 - 1.0)));
            hit_shadow = select(sqr(hit_l.y), mix(s, sqr(hit_l.y), fade), in_map);
        }
        let hit_nol = lift(max0(dot(hit.normal, l)), 0.25 / shading_strength);
        lighting += get_light_color() * hit_nol * hit_shadow;
        lighting += get_sky_color() * get_skylight_boost() * skylight_i * sqr(hit_l.y);
        lighting += 0.15 * cave_lighting_i * directional * (1.0 - sqr(hit_l.y)) * (1.0 - 0.7 * frame.darkness);
    } else if in_end() {
        let end_light_dir = normalize(vec3<f32>(0.0, 0.6, -0.8));
        let end_nol = max0(dot(hit.normal, end_light_dir)) * 0.65 + 0.35;
        lighting += vec3<f32>(0.36, 0.28, 0.56) * directional * end_nol * 1.15;
    } else if in_nether() {
        let fog = max(linear_to_rec2020(frame.fog_color), vec3<f32>(0.04, 0.015, 0.008));
        let lava_bounce = mix(0.85, 1.2, clamp01(-hit.normal.y * 0.5 + 0.5));
        lighting += 16.0 * directional * lava_bounce * mix(fog, vec3<f32>(dot(fog, luminance_weights)), 0.45) * 0.055;
    } else {
        lighting += 16.0 * directional * linear_to_rec2020(frame.fog_color) * 0.05;
    }

    let blocklight_color = from_srgb(vec3<f32>(blocklight_r, blocklight_g, blocklight_b)) * blocklight_i;
    lighting += get_blocklight_falloff(hit_l.x, hit_l.y, 1.0, t) * directional * 6.0 * blocklight_color;

    if hit.emission > 0.0 {
        let srgb_max = pow(max_of(clamp01v(hit.albedo.rgb)), 1.0 / 2.2);
        let mask = select(linear_step(0.5, 0.9, srgb_max), 1.0, hit.fluid == 2u);
        lighting += hit.emission * mask * 0.66 * 40.0 * emission_strength;
    }
    lighting += frame.night_vision * 1.5 * directional;

    var col = max(lighting, vec3<f32>(0.0)) * hit_albedo * rcp_pi;
    if in_overworld() && frame.eye_in == 0u {
        let hit_fog = air_fog_analytic(hit.distance, refl_dir, hit_l.y);
        col = col * hit_fog[1] + hit_fog[0];
    }
    let fade_dist = min(frame.ray_distance, 128.0);
    let rt_fade = linear_step(fade_dist * 0.80, fade_dist, hit.distance);
    return mix(col, sky_refl, rt_fade);
}

fn water_normal(input: MaterialInput, ray: vec3<f32>) -> vec3<f32> {
    var normal = input.normal;
    let skylight = input.light.y;
    let flowing = input.face != 1u || abs(input.normal.y) < 0.99;
    if water_wave_strength > 0.0 && input.face == 1u {
        let coord = input.position.xz + frame.camera_position.xz;
        let flow_dir = normalize(input.normal.xz + vec2<f32>(1e-4));
        let h = 0.1;
        let w0 = get_water_height(coord, flowing, flow_dir);
        let w1 = get_water_height(coord + vec2<f32>(h, 0.0), flowing, flow_dir);
        let w2 = get_water_height(coord + vec2<f32>(0.0, h), flowing, flow_dir);
        var influence = select(mix(0.01, 0.04 + 0.15 * frame.rain, dampen(skylight)), 0.1, flowing);
        influence *= smoothstep(0.0, 0.15, abs(dot(input.normal, ray))) * water_wave_strength;
        normal = normalize(vec3<f32>(-(w1 - w0) * influence, h, -(w2 - w0) * influence));
        if input.normal.y < 0.0 {
            normal.y = -normal.y;
        }
    }
    return normal;
}

fn shade_water(input: MaterialInput, ray: vec3<f32>, normal: vec3<f32>, refl_dir: vec3<f32>,
        rt_hit: RayHit, traced: bool, dither: f32, t: Times) -> vec4<f32> {
    let skylight = input.light.y;
    let nov = clamp01(dot(normal, -ray));
    let underwater = frame.eye_in == 1u;

    // what lies behind, bent by the waves
    let size = frame.resolution;
    let refract_uv = clamp(input.screen + normal.xz * 0.03 * (1.0 - nov), vec2<f32>(0.0), vec2<f32>(1.0));
    let texel = clamp(vec2<i32>(refract_uv * size), vec2<i32>(0), vec2<i32>(size) - 1);
    let texel_straight = clamp(vec2<i32>(input.screen * size), vec2<i32>(0), vec2<i32>(size) - 1);
    var behind_depth = textureLoad(opaque_depth, texel, 0);
    var tx = texel;
    let surface_dist = length(input.position);
    if screen_depth_to_distance(refract_uv, behind_depth) < surface_dist {
        tx = texel_straight;
        behind_depth = textureLoad(opaque_depth, tx, 0);
    }
    let behind = linear_to_rec2020(textureLoad(opaque_color, tx, 0).rgb);
    let behind_dist = select(screen_depth_to_distance(input.screen, behind_depth), 1e4, behind_depth <= 0.0);
    let layer_dist = max0(behind_dist - surface_dist);

    // absorption and in-scattering (photon's water_fog_simple)
    let shade = pow(vanilla_face_shade(input.normal), 2.2);
    let biome_color = linear_to_rec2020(input.tint.rgb / max(shade, 1e-4));
    let absorption = biome_water_coeff(biome_color);
    let scattering_coeff = vec3<f32>(0.01);
    let extinction = scattering_coeff + absorption;
    let albedo_ms = 0.84 * scattering_coeff / extinction;
    let ms_energy = albedo_ms / (1.0 - albedo_ms);
    let skylight_factor = cube(input.light.y);
    let dist = select(max(layer_dist, 2.0 - skylight_factor), 0.0, underwater);
    let light_color = get_light_color();
    let blocklight_color = from_srgb(vec3<f32>(blocklight_r, blocklight_g, blocklight_b)) * blocklight_i;
    let ambient = get_sky_color() * input.light.y + 1.41 * blocklight_color * 6.0 * sqr(input.light.x);
    let transmittance = exp(-extinction * dist);
    let lov = dot(light_dir(), ray);
    var scatter = light_color * smoothstep(0.0, 0.25, input.light.y);
    scatter *= 0.7 * henyey_greenstein_phase(-lov, 0.4) + 0.3 * isotropic_phase;
    scatter += ambient * isotropic_phase;
    scatter *= (1.0 - transmittance) * scattering_coeff / extinction;
    scatter *= 1.0 + ms_energy;
    let brightness = (1.0 - exp(-0.33 * layer_dist)) * max(input.light.x, input.light.y);
    var color = behind * transmittance + scatter * (1.0 + 6.0 * transmittance * transmittance) * brightness;

    // water texture highlight
    if water_texture == 1u {
        let r = input.albedo.r;
        let highlight = dampen(0.5 * sqr(linear_step(0.63, 1.0, r)) + 0.03 * r)
            * (1.0 - cube(linear_step(0.0, 0.5, input.light.y)));
        color += clamp01v(0.5 * exp(-2.0 * absorption) * highlight) * (get_sky_color() * input.light.y + 0.1) * rcp_pi;
    } else if water_texture == 2u {
        let vanilla = linear_to_rec2020(input.albedo.rgb * input.tint.rgb);
        color = mix(color, vanilla * (get_sky_color() * sqr(input.light.y) + light_color * 0.2) * rcp_pi, input.albedo.a * 0.5);
    }

    // reflections: hardware RT -> mirror fallback -> photon sky
    let n_rel = select(1.333, 1.0 / 1.333, underwater);
    let fresnel = fresnel_dielectric(nov, n_rel);
    let sky_refl = sky_reflection_color(refl_dir, skylight, traced && rt_hit.distance < 0.0);
    var reflected = sky_refl;
    if traced && rt_hit.distance >= 0.0 {
        reflected = shade_ray_hit(rt_hit, refl_dir, sky_refl, t);
    } else if !traced && frame.has_reflection != 0u && water_reflections && !underwater && input.face == 1u {
        let ruv = clamp(input.screen + normal.xz * 0.02, vec2<f32>(0.0), vec2<f32>(1.0));
        let mirrored = textureSampleLevel(reflection, reflection_sampler, ruv, 0.0).rgb;
        reflected = select(linear_to_rec2020(mirrored), sky_refl, mirror_is_vanilla_sky(mirrored));
    }
    color = mix(color, reflected, fresnel);

    // sun glint
    let l = light_dir();
    let h = normalize(l - ray);
    let nol = dot(normal, l);
    var shadow = vec3<f32>(1.0);
    if frame.has_shadow != 0u {
        shadow = get_shadows(input.position, input.normal, max(nol, 0.01), 0.0, skylight, dither).light;
    }
    color += specular_highlight(0.02, 0.02, nol, nov, max0(dot(normal, h)), max0(dot(l, h)), light_color * shadow) * select(1.0, 0.0, underwater);

    return vec4<f32>(color, 1.0);
}

fn material(input: MaterialInput) -> Surface {
    let t = get_times();
    let dither = interleaved_gradient_noise(input.screen * frame.resolution + f32(frame.frame_index % 64u) * 5.588238);
    let ray = normalize(input.position);
    let is_water = input.fluid == 1u;
    let flat_normal = input.normal;

    var water_n = flat_normal;
    if is_water {
        water_n = water_normal(input, ray);
    }

    var ao = 1.0;
    var m: Mat;
    var normal = flat_normal;
    if !is_water {
        // Separate vanilla vertex AO from untinted blocks while leaving biome-tinted blocks un-doubled
        let shade = pow(vanilla_face_shade(flat_normal), 2.2);
        let unshaded_tint = input.tint.rgb / max(shade, 1e-4);
        let tint_gamma = pow(max(unshaded_tint, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2));
        let is_untinted = (max_of(tint_gamma) - min_of(tint_gamma)) < 0.02;
        ao = select(1.0, clamp(max_of(tint_gamma), 0.15, 1.0), is_untinted);
        let tint_albedo = select(unshaded_tint, vec3<f32>(1.0), is_untinted);
        let albedo = linear_to_rec2020(clamp01v(input.albedo.rgb * tint_albedo));
        m = get_material(input, albedo);

        if block_pbr_maps() {
            let nm = block_normal_map(input.uv);
            ao *= clamp01(nm.b);
            if nm.z < 0.999 || abs(nm.x - 0.5) > 0.002 || abs(nm.y - 0.5) > 0.002 {
                var tn = vec3<f32>(nm.xy * 2.0 - 1.0, 0.0);
                tn.z = sqrt(max0(1.0 - dot(tn.xy, tn.xy)));
                let bitangent = cross(flat_normal, input.tangent.xyz) * input.tangent.w;
                normal = normalize(input.tangent.xyz * tn.x + bitangent * tn.y + flat_normal * tn.z);
            }
        }
    }

    let refl_surface_n = select(normal, water_n, is_water);
    var refl_dir = reflect(ray, refl_surface_n);
    let into_plane = dot(refl_dir, flat_normal);
    if into_plane < 0.0 {
        refl_dir = normalize(refl_dir - 2.0 * into_plane * flat_normal);
    }

    let want_water_rt = is_water && water_reflections && frame.eye_in != 1u;
    let want_pbr_rt = !is_water && specular_highlights && m.roughness < 0.3 && m.sss_amount < 0.25;
    let want_rt_refl = frame.has_ray_tracing != 0u && rt_reflections && (want_water_rt || want_pbr_rt);

    // Single trace(...) call site in the material stage to minimize SPIR-V traversal overhead
    var rt_hit: RayHit;
    rt_hit.distance = -1.0;
    if want_rt_refl {
        rt_hit = trace(input.position + flat_normal * 0.03, refl_dir, min(frame.ray_distance, 128.0));
    }

    if is_water {
        let water = shade_water(input, ray, water_n, refl_dir, rt_hit, want_rt_refl, dither, t);
        return Surface(vec4<f32>(rec2020_to_linear(water.rgb), 1.0));
    }

    if !input.translucent {
        set_surface(normal, 1.0 - m.roughness, m.sss_amount);
    }

    let l = light_dir();
    let nol = dot(normal, l);
    let nov = clamp01(dot(normal, -ray));
    let lov = dot(l, ray);
    let light_levels = clamp(input.light, vec2<f32>(0.0), vec2<f32>(1.0));

    var sh: ShadowResult;
    sh.light = vec3<f32>(1.0);
    sh.sss_depth = 0.0;
    sh.fade = 1.0;
    let flat_nol = dot(flat_normal, l);
    if in_overworld() {
        sh = get_shadows(input.position, flat_normal, select(flat_nol, max(flat_nol, 0.01), m.sss_amount > eps), m.sss_amount, light_levels.y, dither);
    }
    // Single trace_any(...) call site in the material stage for crisp near-field contact shadows
    if frame.has_ray_tracing != 0u && rt_contact_shadows && !is_water && in_overworld()
        && frame.has_shadow != 0u && flat_nol > 0.01 && m.sss_amount < 0.25 && length(input.position) < 64.0 {
        if trace_any(input.position + flat_normal * 0.03, l, 16.0) {
            sh.light = vec3<f32>(0.0);
        }
    }

    var color = get_diffuse_lighting(m, input.position, normal, flat_normal, light_levels, ao, sh, nol, lov, t, input.colored_light);

    if specular_highlights && m.roughness < 0.99 {
        if in_overworld() {
            let h = normalize(l - ray);
            let shadow_mix = mix(sh.light, vec3<f32>(sqr(light_levels.y)), sh.fade);
            color += specular_highlight(m.roughness, m.f0, nol, nov, max0(dot(normal, h)), max0(dot(l, h)), get_light_color() * shadow_mix);
        }
        let sky_refl = sky_reflection_color(refl_dir, light_levels.y, want_rt_refl && rt_hit.distance < 0.0);
        var env_refl = sky_refl;
        if want_rt_refl && rt_hit.distance >= 0.0 {
            let rt_env = shade_ray_hit(rt_hit, refl_dir, sky_refl, t);
            env_refl = mix(rt_env, sky_refl, smoothstep(0.05, 0.3, m.roughness));
        }
        let metal_tint = mix(vec3<f32>(1.0), m.albedo, select(0.0, 0.85, m.f0 >= 0.89));
        color += env_refl * metal_tint * fresnel_schlick(nov, m.f0) * sqr(1.0 - m.roughness);
    }

    color = purkinje_shift_apply(color, light_levels);
    return Surface(vec4<f32>(rec2020_to_linear(color), input.albedo.a));
}
