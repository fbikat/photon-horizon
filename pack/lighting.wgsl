// Shared lighting, PCSS shadows, water caustics, SSS, colored blocklight, and GGX specular helpers for [material] and [entity]

struct Mat {
    albedo: vec3<f32>,
    sss_amount: f32,
    sheen_amount: f32,
    emission: f32,
    f0: f32,
    roughness: f32,
}

// vanilla's face shade is baked into terrain tint; photon shades faces itself
fn vanilla_face_shade(n: vec3<f32>) -> f32 {
    let a = abs(n);
    if a.y > a.x && a.y > a.z {
        return select(0.5, 1.0, n.y > 0.0);
    }
    return select(0.6, 0.8, a.z > a.x);
}

fn get_blocklight_falloff(blocklight: f32, skylight: f32, ao: f32, t: Times) -> f32 {
    var falloff = pow8(blocklight) + 0.18 * sqr(blocklight) + 0.16 * dampen(blocklight);
    falloff *= mix(cube(ao), 1.0, clamp01(falloff));
    falloff *= mix(1.0, ao * dampen(abs(cos(2.0 * frame.time))) * 0.67 + 0.2, frame.darkness);
    falloff *= 1.0 - 0.2 * t.noon * skylight - 0.2 * skylight;
    falloff += min(2.7 * pow12(blocklight), 0.9);
    falloff *= smoothstep(0.0, 0.125, blocklight);
    return falloff;
}

// Animated underwater light caustics pattern projected along light_dir()
fn get_water_caustics(world_pos: vec3<f32>) -> f32 {
    let t = frame.time * 0.25;
    let basis = cloud_shadow_basis(light_dir());
    let cpos = vec2<f32>(dot(world_pos, basis.right), dot(world_pos, basis.fwd));
    let d0 = vec2<f32>(0.8775826, 0.4794255);
    let d1 = vec2<f32>(-0.9899925, 0.1411200);
    let n0 = textureSampleLevel(noisetex, noisetex_sampler, (cpos + d0 * t) * 0.035, 0.0).y;
    let n1 = textureSampleLevel(noisetex, noisetex_sampler, (cpos + d1 * t) * 0.055, 0.0).y;
    let edge0 = 1.0 - abs(n0 * 2.0 - 1.0);
    let edge1 = 1.0 - abs(n1 * 2.0 - 1.0);
    let fil = pow(clamp01(edge0 * edge1 * 1.4), 2.2);
    return 0.55 + fil * 2.15;
}

fn sss_approx(albedo: vec3<f32>, sss_amount: f32, sheen_amount: f32, sss_depth: f32, lov: f32) -> vec3<f32> {
    if sss_amount < eps {
        return vec3<f32>(0.0);
    }
    let sss_density = 14.0;
    let sss_scale = 5.0 * sss_intensity;
    var coeff = albedo / sqrt(dot(albedo, luminance_weights) + eps);
    coeff = 0.75 * clamp01v(coeff);
    coeff = (1.0 - coeff) * sss_density / sss_amount;
    let phase = mix(isotropic_phase, henyey_greenstein_phase(-lov, 0.7), 0.33);
    var sss = sss_scale * phase * exp2(-coeff * sss_depth) * dampen(sss_amount) * pi;
    let sheen = (0.8 * sss_intensity) / (albedo + eps) * exp2(-coeff * sss_depth)
        * henyey_greenstein_phase(-lov, 0.5) * linear_step(-0.8, -0.2, -lov);
    sss += sheen * sheen_amount;
    return sss;
}

// shadows (photon's include/lighting/shadows/pcss.glsl on horizon's map)
fn shadow_uv(clip_xy: vec2<f32>) -> vec2<f32> {
    let d = shadow_distort(clip_xy);
    return vec2<f32>(d.x * 0.5 + 0.5, 0.5 - d.y * 0.5);
}

fn distortion_factor(clip_xy: vec2<f32>) -> f32 {
    let k = frame.shadow_distortion;
    return length(clip_xy) * k + 1.0 - k;
}

struct ShadowResult {
    light: vec3<f32>,
    sss_depth: f32,
    fade: f32,
    under_water: f32,
}

fn get_shadows(position: vec3<f32>, flat_normal: vec3<f32>, nol: f32, sss_amount: f32, skylight: f32, dither: f32) -> ShadowResult {
    var r: ShadowResult;
    r.light = vec3<f32>(1.0);
    r.sss_depth = 0.0;
    r.fade = 1.0;
    r.under_water = 0.0;
    if frame.has_shadow == 0u {
        return r;
    }
    let dist_blocks = frame.shadow_distance;
    let res = frame.shadow_resolution;
    let texel_blocks = max(frame.shadow_center_texel, 1e-4);

    // normal offset bias, larger at grazing light and far from the map's centre
    let clip0 = (frame.shadow_view_proj * vec4<f32>(position, 1.0)).xyz;
    let df0 = distortion_factor(clip0.xy);
    let bias = flat_normal * texel_blocks * df0 * (1.5 + 2.0 * (1.0 - abs(nol)));
    let p = position + bias;
    let clip = (frame.shadow_view_proj * vec4<f32>(p, 1.0)).xyz;
    let edge = max(abs(shadow_distort(clip.xy).x), abs(shadow_distort(clip.xy).y));
    r.fade = linear_step(0.85, 1.0, edge);
    if r.fade >= 1.0 || clip.z >= 1.0 {
        r.fade = 1.0;
        return r;
    }
    let ref_z = clip.z;
    let z_per_block = length(vec3<f32>(frame.shadow_view_proj[0][2], frame.shadow_view_proj[1][2], frame.shadow_view_proj[2][2]));
    let isize = vec2<i32>(i32(res), i32(res));

    // blocker search
    var penumbra = 0.5 / sqrt(2.0) * shadow_penumbra_scale * (1.0 + 7.0 * sss_amount) / res * 2.0;
    if shadow_vps {
        let steps = select(3, 9, sss_amount > eps);
        let radius = 0.5 / dist_blocks * (0.5 + 0.5 * linear_step(0.2, 0.4, light_dir().y));
        var depth_sum = 0.0;
        var weight_sum = 0.0;
        var sss_sum = 0.0;
        for (var i = 0; i < steps; i++) {
            let off = vogel_disc_sample(i, steps, dither * tau) * radius;
            let uv = shadow_uv(clip.xy + off);
            let texel = clamp(vec2<i32>(uv * res), vec2<i32>(0), isize - 1);
            let d = textureLoad(shadow_map, texel, 0);
            let w = step(d, ref_z);
            depth_sum += w * d;
            weight_sum += w;
            sss_sum += max0(ref_z - d);
        }
        r.sss_depth = sss_sum / (z_per_block * f32(steps));
        if nol < 1e-3 {
            r.light = vec3<f32>(0.0);
            return r;
        }
        if weight_sum == 0.0 {
            return r;
        }
        let blocker = depth_sum / weight_sum;
        let blocks_between = (ref_z - blocker) / z_per_block;
        penumbra = min(0.04 * shadow_penumbra_scale * blocks_between, 0.5) / dist_blocks;
    } else if nol < 1e-3 && sss_amount < eps {
        r.light = vec3<f32>(0.0);
        return r;
    }

    // vogel pcf with photon's sharpening
    let min_radius = 2.0 / res * distortion_factor(clip.xy);
    let filter_radius = max(penumbra, min_radius);
    let filter_scale = sqr(filter_radius / min_radius);
    let count = clamp(6 + i32(filter_scale), 4, max(shadow_pcf_steps, 4));
    var lit = 0.0;
    var color_sum = vec3<f32>(0.0);
    var water_sum = 0.0;
    let check_trans = colored_shadows || water_caustics;
    for (var i = 0; i < count; i++) {
        let off = vogel_disc_sample(i, count, dither * tau) * filter_radius;
        let uv = shadow_uv(clip.xy + off);
        let s = textureSampleCompareLevel(shadow_map, shadow_sampler, uv, ref_z);
        lit += s;
        if check_trans && i < 4 {
            let st = textureSampleCompareLevel(shadow_map_translucent, shadow_sampler, uv, ref_z);
            let texel = clamp(vec2<i32>(uv * vec2<f32>(textureDimensions(shadow_color))), vec2<i32>(0), vec2<i32>(textureDimensions(shadow_color)) - 1);
            let c = textureLoad(shadow_color, texel, 0);
            let is_water_occl = c.a >= 0.999;
            if is_water_occl && st < 0.5 && s > 0.5 {
                water_sum += 1.0;
            }
            if colored_shadows {
                let tint = select(linear_to_rec2020(c.rgb), vec3<f32>(1.0), is_water_occl);
                color_sum += mix(tint, vec3<f32>(1.0), st);
            }
        }
    }
    r.under_water = water_sum * 0.25;
    let color = select(vec3<f32>(1.0), color_sum * 0.25, colored_shadows);
    let sharpen = 0.4 * max0((min_radius - penumbra) / min_radius);
    let shadow = linear_step(sharpen, 1.0 - sharpen, lit / f32(count));
    r.light = shadow * color;
    return r;
}

struct LightingResult {
    total: vec3<f32>,
    direct_sun: vec3<f32>,
}

fn get_diffuse_lighting(
    m: Mat,
    position: vec3<f32>,
    normal: vec3<f32>,
    flat_normal: vec3<f32>,
    light_levels: vec2<f32>,
    ao: f32,
    sh: ShadowResult,
    cloud_shadow: f32,
    nol: f32,
    lov: f32,
    t: Times,
    colored_light: vec3<f32>,
) -> LightingResult {
    var lighting = vec3<f32>(0.0);
    var sun_part = vec3<f32>(0.0);
    let ambient_sss = 0.0;
    let directional = (0.9 + 0.1 * normal.x) * (0.8 + 0.2 * abs(flat_normal.y));
    let sss_blocked = light_levels.y < 0.1;
    let overworld = in_overworld();

    var caustic_mul = 1.0;
    if water_caustics && overworld {
        let distant_water = select(0.0, sh.fade * smoothstep(0.25, 0.75, light_levels.y), frame.eye_in == 1u);
        let c_mask = max(sh.under_water, distant_water);
        if c_mask > 0.01 {
            caustic_mul = mix(1.0, get_water_caustics(position + frame.camera_position), c_mask);
        }
    }

    if overworld && frame.has_shadow != 0u {
        let diffuse = vec3<f32>(lift(max0(nol), 0.25 / shading_strength) * (1.0 - 0.5 * m.sss_amount));
        let shadows = sh.light * cloud_shadow;
        let bounced = 0.033 * (1.0 - shadows) * (1.0 - 0.1 * max0(normal.y))
            * pow1d5(ao + eps) * pow4(light_levels.y) * bounced_light_i;
        var sss = sss_approx(m.albedo, m.sss_amount, m.sheen_amount, mix(sh.sss_depth, 0.0, sh.fade), lov)
            * select(1.0, 0.0, sss_blocked) * cloud_shadow;
        sss *= mix(1.0, (ao + pi * ambient_sss) * (clamp01(nol) * 0.8 + 0.2), clamp01(sh.fade));
        let shadow_mix = mix(shadows, vec3<f32>(sqr(light_levels.y) * cloud_shadow), sh.fade);
        let lc = get_light_color() * caustic_mul;
        sun_part = (diffuse * shadow_mix + sss) * lc;
        lighting += sun_part + bounced * get_light_color();
    } else if overworld {
        let sss = 0.08 * 5.0 * sss_intensity * pi
            + 0.5 * m.sheen_amount / (m.albedo + eps) * henyey_greenstein_phase(-lov, 0.5) * linear_step(-0.8, -0.2, -lov);
        let shadows = sqr(light_levels.y);
        var diffuse = vec3<f32>(lift(max0(nol), 0.5 / shading_strength) * 0.6 + 0.4) * (shadows * 0.8 + 0.2);
        diffuse = diffuse + max(sss * lift(m.sss_amount, 5.0), vec3<f32>(0.0));
        diffuse *= directional * ao * pow4(light_levels.y) * (dampen(light_dir().y) * 0.5 + 0.5) * cloud_shadow;
        sun_part = diffuse * get_light_color() * caustic_mul;
        lighting += sun_part;
    }

    // skylight / dimension ambient
    if overworld {
        var skylight = get_sky_color() * get_skylight_boost() * skylight_i * ao;
        skylight = mix(skylight, 0.5 * skylight, m.sss_amount);
        lighting += skylight * sqr(light_levels.y);
    } else if in_end() {
        let end_ld = normalize(vec3<f32>(0.0, 0.5299989, -0.8479983));
        let end_nol = max0(dot(normal, end_ld)) * 0.65 + 0.35;
        lighting += vec3<f32>(0.36, 0.28, 0.56) * directional * end_nol * ao * 1.15;
    } else if in_nether() {
        let fog = max(linear_to_rec2020(frame.fog_color), vec3<f32>(0.04, 0.015, 0.008));
        let lava_bounce = mix(0.85, 1.2, clamp01(-normal.y * 0.5 + 0.5));
        lighting += 16.0 * directional * lava_bounce * mix(fog, vec3<f32>(dot(fog, luminance_weights)), 0.45) * 0.055 * ao;
    } else {
        let fog = linear_to_rec2020(frame.fog_color);
        lighting += 16.0 * directional * mix(fog, vec3<f32>(dot(fog, luminance_weights)), 0.5) * 0.05 * ao;
    }

    // colored block light (from [[lights]] grid blended cleanly with warm torch default) + dynamic/particle lights
    let grid_c = block_light_color(position);
    let blocklight_col = mix(get_blocklight_color(), linear_to_rec2020(grid_c.rgb), clamp01(grid_c.a * 1.6)) * blocklight_i;
    let falloff = get_blocklight_falloff(light_levels.x, light_levels.y, ao, t);
    lighting += falloff * directional * 6.0 * blocklight_col;
    lighting += linear_to_rec2020(colored_light) * 6.0 * blocklight_i;

    lighting += m.emission * 40.0 * emission_strength;

    if overworld {
        lighting += 0.15 * cave_lighting_i * directional * ao * (1.0 - sqr(light_levels.y)) * (1.0 - 0.7 * frame.darkness);
    }
    lighting += frame.night_vision * 1.5 * directional * ao;
    let inv_pi = m.albedo * rcp_pi;
    return LightingResult(max(lighting, vec3<f32>(0.0)) * inv_pi, max(sun_part, vec3<f32>(0.0)) * inv_pi);
}

// ggx sun highlight (photon's include/lighting/specular_lighting.glsl get_specular_highlight)
fn d_ggx(noh: f32, alpha_sq: f32) -> f32 {
    let f = (noh * alpha_sq - noh) * noh + 1.0;
    return alpha_sq / (pi * f * f);
}

fn v2_smith_ggx(nol: f32, nov: f32, alpha_sq: f32) -> f32 {
    let ggxl = nov * sqrt((-nol * alpha_sq + nol) * nol + alpha_sq);
    let ggxv = nol * sqrt((-nov * alpha_sq + nov) * nov + alpha_sq);
    return 0.5 / max(ggxl + ggxv, eps);
}

fn fresnel_schlick(cos_theta: f32, f0: f32) -> f32 {
    let f = 1.0 - clamp01(cos_theta);
    let f2 = f * f;
    return clamp(f0 + (1.0 - f0) * (f2 * f2 * f), 0.0, 1.0);
}

fn fresnel_dielectric(cos_theta: f32, n: f32) -> f32 {
    let c = clamp(cos_theta, 0.0, 1.0);
    let g2 = max(n * n + c * c - 1.0, 0.0);
    let g = sqrt(g2);
    let a = (g - c) / max(g + c, eps);
    let b = (c * (g + c) - 1.0) / max(c * (g - c) + 1.0, eps);
    return clamp(0.5 * a * a * (1.0 + b * b), 0.0, 1.0);
}

fn specular_highlight(roughness: f32, f0: f32, nol: f32, nov: f32, noh: f32, loh: f32, light_color: vec3<f32>) -> vec3<f32> {
    if nol <= 0.0 || nov <= 0.0 {
        return vec3<f32>(0.0);
    }
    let alpha = max(roughness, 0.002);
    let alpha_sq = alpha * alpha;
    let d = d_ggx(noh, alpha_sq);
    let g2 = v2_smith_ggx(nol, nov, alpha_sq);
    let f = fresnel_schlick(loh, f0);
    return light_color * (d * g2 * f * nol);
}
