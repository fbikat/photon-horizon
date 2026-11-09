// photon's gbuffers + d4_deferred_shading lighting, run forward per terrain fragment

const MAT_SMALL_PLANTS: u32 = 2u;
const MAT_TALL_LOWER: u32 = 3u;
const MAT_TALL_UPPER: u32 = 4u;
const MAT_LEAVES: u32 = 5u;
const MAT_VINES: u32 = 6u;

struct Mat {
    albedo: vec3<f32>,
    sss_amount: f32,
    sheen_amount: f32,
    emission: f32,
    f0: f32,
    roughness: f32,
}

// vanilla's face shade is baked into the tint; photon shades faces itself
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
            let tint = select(from_srgb(c.rgb), vec3<f32>(1.0), c.a >= 0.999);
            color_sum += mix(tint, vec3<f32>(1.0), st);
        }
    }
    let color = select(vec3<f32>(1.0), color_sum * 0.25, colored_shadows);
    let sharpen = 0.4 * max0((min_radius - penumbra) / min_radius);
    let shadow = linear_step(sharpen, 1.0 - sharpen, lit / f32(count));
    r.light = shadow * color;
    return r;
}

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
        let srgb = input.albedo.rgb;
        let mask = select(linear_step(0.5, 0.9, max_of(srgb)), 1.0, input.fluid == 2u);
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

fn get_diffuse_lighting(m: Mat, position: vec3<f32>, normal: vec3<f32>, flat_normal: vec3<f32>,
        light_levels: vec2<f32>, ao: f32, sh: ShadowResult, nol: f32, lov: f32, t: Times) -> vec3<f32> {
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

    // skylight
    var skylight: vec3<f32>;
    if overworld {
        skylight = get_sky_color() * get_skylight_boost() * skylight_i * ao;
        skylight = mix(skylight, 0.5 * skylight, m.sss_amount);
        lighting += skylight * sqr(light_levels.y);
    } else {
        // nether and end: photon's flat ambient tinted by the fog
        let fog = from_srgb(frame.fog_color);
        skylight = 16.0 * directional * mix(fog, vec3<f32>(dot(fog, luminance_weights)), 0.5) * 0.05 * ao;
        lighting += skylight;
    }

    // blocklight
    let blocklight_color = from_srgb(vec3<f32>(blocklight_r, blocklight_g, blocklight_b)) * blocklight_i;
    let falloff = get_blocklight_falloff(light_levels.x, light_levels.y, ao, t);
    lighting += falloff * directional * 6.0 * blocklight_color;
    // horizon's coloured block light and dynamic lights, where a light reaches
    lighting += from_srgb(input_colored_light) * 6.0 * blocklight_i;

    lighting += m.emission * 40.0 * emission_strength;

    if overworld {
        lighting += 0.15 * cave_lighting_i * directional * ao * (1.0 - sqr(light_levels.y)) * (1.0 - 0.7 * frame.darkness);
    }
    lighting += frame.night_vision * 1.5 * directional * ao;
    return max(lighting, vec3<f32>(0.0)) * m.albedo * rcp_pi;
}

var<private> input_colored_light: vec3<f32>;

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
    let f = frame.fog_color;
    let d = frame.sky_color - f;
    let t = clamp01(dot(m - f, d) / max(dot(d, d), 1e-5));
    return distance(m, f + t * d) < 0.04;
}

fn shade_water(input: MaterialInput, dither: f32, t: Times) -> vec4<f32> {
    let ray = normalize(input.position);
    var normal = input.normal;
    let skylight = input.light.y;
    let flowing = input.face != 1u || abs(input.normal.y) < 0.99;
    if water_waves && input.face == 1u {
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
    let behind = decode_hdr(textureLoad(opaque_color, tx, 0).rgb);
    let behind_dist = select(screen_depth_to_distance(input.screen, behind_depth), 1e4, behind_depth <= 0.0);
    let layer_dist = max0(behind_dist - surface_dist);

    // absorption and in-scattering (photon's water_fog_simple)
    let biome_color = srgb_eotf_inv(input.tint.rgb / max(vanilla_face_shade(input.normal), 0.5)) * rec709_to_rec2020;
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
        let vanilla = from_srgb(input.albedo.rgb * input.tint.rgb);
        color = mix(color, vanilla * (get_sky_color() * sqr(input.light.y) + light_color * 0.2) * rcp_pi, input.albedo.a * 0.5);
    }

    // reflections: horizon's mirror, else photon's sky
    let n_rel = select(1.333, 1.0 / 1.333, underwater);
    let fresnel = fresnel_dielectric(nov, n_rel);
    let refl_dir = reflect(ray, normal);
    var reflected: vec3<f32>;
    if frame.has_reflection != 0u && water_reflections && !underwater && input.face == 1u {
        let ruv = clamp(input.screen + normal.xz * 0.02, vec2<f32>(0.0), vec2<f32>(1.0));
        let mirrored = textureSampleLevel(reflection, reflection_sampler, ruv, 0.0).rgb;
        let sky_refl = atmosphere_scattering_both(normalize(vec3<f32>(refl_dir.x, max(refl_dir.y, 0.0), refl_dir.z)), sun_color(), moon_color())
            * sqr(input.light.y) * (1.0 - frame.rain * 0.5);
        // the mirror shows vanilla's sky gradient behind terrain: that is no hdr, use photon's sky there
        reflected = select(decode_hdr(mirrored), sky_refl, mirror_is_vanilla_sky(mirrored));
    } else if in_overworld() {
        reflected = atmosphere_scattering_both(normalize(vec3<f32>(refl_dir.x, max(refl_dir.y, 0.0), refl_dir.z)), sun_color(), moon_color());
        reflected *= sqr(input.light.y) * (1.0 - frame.rain * 0.5);
    } else {
        reflected = from_srgb(frame.fog_color) * 0.1;
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
    input_colored_light = input.colored_light;

    if input.fluid == 1u {
        let water = shade_water(input, dither, t);
        return Surface(vec4<f32>(encode_hdr(water.rgb, dither), 1.0));
    }

    let shade = vanilla_face_shade(input.normal);
    let tint = input.tint.rgb / shade;
    let albedo_srgb = clamp01v(input.albedo.rgb * tint);
    let albedo = srgb_eotf_inv(albedo_srgb) * rec709_to_rec2020;
    var m = get_material(input, max(albedo, vec3<f32>(0.0)));

    let flat_normal = input.normal;
    var normal = flat_normal;
    if block_pbr_maps() {
        let nm = block_normal_map(input.uv);
        if nm.z < 0.999 || abs(nm.x - 0.5) > 0.002 || abs(nm.y - 0.5) > 0.002 {
            var tn = vec3<f32>(nm.xy * 2.0 - 1.0, 0.0);
            tn.z = sqrt(max0(1.0 - dot(tn.xy, tn.xy)));
            let bitangent = cross(flat_normal, input.tangent.xyz) * input.tangent.w;
            normal = normalize(input.tangent.xyz * tn.x + bitangent * tn.y + flat_normal * tn.z);
        }
    }

    let ray = normalize(input.position);
    let l = light_dir();
    let nol = dot(normal, l);
    let nov = clamp01(dot(normal, -ray));
    let lov = dot(l, ray);
    let light_levels = clamp(input.light, vec2<f32>(0.0), vec2<f32>(1.0));
    let ao = 1.0;

    var sh: ShadowResult;
    sh.light = vec3<f32>(1.0);
    sh.sss_depth = 0.0;
    sh.fade = 1.0;
    if in_overworld() {
        let flat_nol = dot(flat_normal, l);
        sh = get_shadows(input.position, flat_normal, select(flat_nol, max(flat_nol, 0.01), m.sss_amount > eps), m.sss_amount, light_levels.y, dither);
    }

    var color = get_diffuse_lighting(m, input.position, normal, flat_normal, light_levels, ao, sh, nol, lov, t);

    if specular_highlights && m.roughness < 0.99 && in_overworld() {
        let h = normalize(l - ray);
        let shadow_mix = mix(sh.light, vec3<f32>(sqr(light_levels.y)), sh.fade);
        color += specular_highlight(m.roughness, m.f0, nol, nov, max0(dot(normal, h)), max0(dot(l, h)), get_light_color() * shadow_mix);
        // sky reflection for smooth surfaces
        let refl = reflect(ray, normal);
        let sky = atmosphere_scattering_both(normalize(vec3<f32>(refl.x, max(refl.y, 0.0), refl.z)), sun_color(), moon_color());
        color += sky * sqr(light_levels.y) * fresnel_schlick(nov, m.f0) * sqr(1.0 - m.roughness);
    }

    color = purkinje_shift_apply(color, light_levels);
    return Surface(vec4<f32>(encode_hdr(color, dither), input.albedo.a));
}
