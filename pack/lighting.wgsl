// Shared lighting, PCSS shadows, SSS, and GGX specular helpers for [material] and [entity]

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
}

fn get_shadows(position: vec3<f32>, flat_normal: vec3<f32>, nol: f32, sss_amount: f32, skylight: f32, dither: f32) -> ShadowResult {
    var r: ShadowResult;
    r.light = vec3<f32>(1.0);
    r.sss_depth = 0.0;
    r.fade = 1.0;
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
    for (var i = 0; i < count; i++) {
        let off = vogel_disc_sample(i, count, dither * tau) * filter_radius;
        let uv = shadow_uv(clip.xy + off);
        let s = textureSampleCompareLevel(shadow_map, shadow_sampler, uv, ref_z);
        lit += s;
        if colored_shadows && i < 4 {
            let st = textureSampleCompareLevel(shadow_map_translucent, shadow_sampler, uv, ref_z);
            let texel = clamp(vec2<i32>(uv * vec2<f32>(textureDimensions(shadow_color))), vec2<i32>(0), vec2<i32>(textureDimensions(shadow_color)) - 1);
            let c = textureLoad(shadow_color, texel, 0);
            let tint = select(linear_to_rec2020(c.rgb), vec3<f32>(1.0), c.a >= 0.999);
            color_sum += mix(tint, vec3<f32>(1.0), st);
        }
    }
    let color = select(vec3<f32>(1.0), color_sum * 0.25, colored_shadows);
    let sharpen = 0.4 * max0((min_radius - penumbra) / min_radius);
    let shadow = linear_step(sharpen, 1.0 - sharpen, lit / f32(count));
    r.light = shadow * color;
    return r;
}

fn get_diffuse_lighting(m: Mat, position: vec3<f32>, normal: vec3<f32>, flat_normal: vec3<f32>,
        light_levels: vec2<f32>, ao: f32, sh: ShadowResult, nol: f32, lov: f32, t: Times,
        colored_light: vec3<f32>) -> vec3<f32> {
    var lighting = vec3<f32>(0.0);
    let ambient_sss = 0.0;
    let directional = (0.9 + 0.1 * normal.x) * (0.8 + 0.2 * abs(flat_normal.y));
    let sss_blocked = light_levels.y < 0.1;
    let overworld = in_overworld();

    if overworld && frame.has_shadow != 0u {
        let diffuse = vec3<f32>(lift(max0(nol), 0.25 / shading_strength) * (1.0 - 0.5 * m.sss_amount));
        let shadows = sh.light;
        let bounced = 0.033 * (1.0 - shadows) * (1.0 - 0.1 * max0(normal.y))
            * pow1d5(ao + eps) * pow4(light_levels.y) * bounced_light_i;
        var sss = sss_approx(m.albedo, m.sss_amount, m.sheen_amount, mix(sh.sss_depth, 0.0, sh.fade), lov)
            * select(1.0, 0.0, sss_blocked);
        sss *= mix(1.0, (ao + pi * ambient_sss) * (clamp01(nol) * 0.8 + 0.2), clamp01(sh.fade));
        let shadow_mix = mix(shadows, vec3<f32>(sqr(light_levels.y)), sh.fade);
        lighting += diffuse * shadow_mix + bounced + sss;
        lighting *= get_light_color();
    } else if overworld {
        // photon's simple shading for when shadows are disabled
        let sss = 0.08 * 5.0 * sss_intensity * pi
            + 0.5 * m.sheen_amount / (m.albedo + eps) * henyey_greenstein_phase(-lov, 0.5) * linear_step(-0.8, -0.2, -lov);
        let shadows = sqr(light_levels.y);
        var diffuse = vec3<f32>(lift(max0(nol), 0.5 / shading_strength) * 0.6 + 0.4) * (shadows * 0.8 + 0.2);
        diffuse = diffuse + max(sss * lift(m.sss_amount, 5.0), vec3<f32>(0.0));
        diffuse *= directional * ao * pow4(light_levels.y) * (dampen(light_dir().y) * 0.5 + 0.5);
        lighting += diffuse * get_light_color();
    }

    // skylight / dimension ambient
    if overworld {
        var skylight = get_sky_color() * get_skylight_boost() * skylight_i * ao;
        skylight = mix(skylight, 0.5 * skylight, m.sss_amount);
        lighting += skylight * sqr(light_levels.y);
    } else if in_end() {
        let end_light_dir = normalize(vec3<f32>(0.0, 0.6, -0.8));
        let end_nol = max0(dot(normal, end_light_dir)) * 0.65 + 0.35;
        lighting += vec3<f32>(0.36, 0.28, 0.56) * directional * end_nol * ao * 1.15;
    } else if in_nether() {
        let fog = max(linear_to_rec2020(frame.fog_color), vec3<f32>(0.04, 0.015, 0.008));
        let lava_bounce = mix(0.85, 1.2, clamp01(-normal.y * 0.5 + 0.5));
        lighting += 16.0 * directional * lava_bounce * mix(fog, vec3<f32>(dot(fog, luminance_weights)), 0.45) * 0.055 * ao;
    } else {
        let fog = linear_to_rec2020(frame.fog_color);
        lighting += 16.0 * directional * mix(fog, vec3<f32>(dot(fog, luminance_weights)), 0.5) * 0.05 * ao;
    }

    // blocklight
    let blocklight_color = from_srgb(vec3<f32>(blocklight_r, blocklight_g, blocklight_b)) * blocklight_i;
    let falloff = get_blocklight_falloff(light_levels.x, light_levels.y, ao, t);
    lighting += falloff * directional * 6.0 * blocklight_color;
    // horizon's coloured block light and dynamic lights, where a light reaches
    lighting += linear_to_rec2020(colored_light) * 6.0 * blocklight_i;

    lighting += m.emission * 40.0 * emission_strength;

    if overworld {
        lighting += 0.15 * cave_lighting_i * directional * ao * (1.0 - sqr(light_levels.y)) * (1.0 - 0.7 * frame.darkness);
    }
    lighting += frame.night_vision * 1.5 * directional * ao;
    return max(lighting, vec3<f32>(0.0)) * m.albedo * rcp_pi;
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
    let f = pow(1.0 - cos_theta, 5.0);
    return f + f0 * (1.0 - f);
}

fn fresnel_dielectric(cos_theta: f32, n: f32) -> f32 {
    let g_sq = n * n + cos_theta * cos_theta - 1.0;
    if g_sq < 0.0 {
        return 1.0;
    }
    let g = sqrt(g_sq);
    let a = (g - cos_theta) / (g + cos_theta);
    let b = (cos_theta * (g + cos_theta) - 1.0) / (cos_theta * (g - cos_theta) + 1.0);
    return clamp01(0.5 * a * a * (1.0 + b * b));
}

fn specular_highlight(roughness: f32, f0: f32, nol: f32, nov: f32, noh: f32, loh: f32, light: vec3<f32>) -> vec3<f32> {
    if nol <= 0.0 {
        return vec3<f32>(0.0);
    }
    // the sun is a disc, not a point: widen tiny roughness as photon does
    let alpha_sq = max(sqr(roughness), 0.0004);
    let f = fresnel_schlick(loh, f0);
    return light * nol * d_ggx(noh, alpha_sq) * v2_smith_ggx(max(nol, 1e-3), max(nov, 1e-3), alpha_sq) * f;
}
