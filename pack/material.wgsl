// photon's gbuffers + d4_deferred_shading lighting, run forward per terrain fragment

const MAT_SMALL_PLANTS: u32 = 2u;
const MAT_TALL_LOWER: u32 = 3u;
const MAT_TALL_UPPER: u32 = 4u;
const MAT_LEAVES: u32 = 5u;
const MAT_VINES: u32 = 6u;

// photon's sky map (before/cloud_shadows.wgsl) in direction d, with clouds, aurora and fog: rgb, and alpha 0 when
// it has not been drawn (not the Overworld, or the first frame)
fn sky_map_sample(d: vec3<f32>) -> vec4<f32> {
    // texel i of the sky map spans i .. i + 1; a tile's block starts one texel (its border) before the tile's own
    let c = sky_map_coord(d);
    let tile = vec2<i32>(select(0, 1, c.x >= 96.0), select(0, 1, c.y >= 48.0));
    let at = vec2<f32>(sky_map_origin(tile)) + 1.0 + c - vec2<f32>(tile * vec2<i32>(96, 48));
    return textureSampleLevel(cloud_shadow_tex, reflection_sampler, at / 512.0, 0.0);
}

// Photon's ambient_sss from the GTAO (post/vlao.wgsl) of the last frame: the surface point reprojected into
// vlao_tex_previous, whose alpha keeps it in its fraction. -1 where there is none (GTAO off, a disocclusion,
// off screen), which get_diffuse_lighting answers with its constant.
fn gtao_sss_previous(position: vec3<f32>) -> f32 {
    if !gtao_foliage_sss || !gtao || !ssao || ao_intensity <= 0.0 || frame.reset_reasons != 0u || frame.delta_time <= 0.0 {
        return -1.0;
    }
    let p = position + frame.camera_motion;
    let pc = frame.previous_view_projection * vec4<f32>(p, 1.0);
    if pc.w <= 0.0 {
        return -1.0;
    }
    let prev_uv = vec2<f32>(pc.x / pc.w * 0.5 + 0.5, 0.5 - pc.y / pc.w * 0.5);
    if any(prev_uv < vec2<f32>(0.0)) || any(prev_uv > vec2<f32>(1.0)) {
        return -1.0;
    }
    let dims = vec2<i32>(textureDimensions(vlao_tex_previous));
    let hp = prev_uv * vec2<f32>(dims) - 0.5;
    let i = vec2<i32>(floor(hp));
    let f = hp - floor(hp);
    let expected = min(length(p), 65000.0);
    let tolerance = 0.04 * expected + 0.15;
    var acc = 0.0;
    var w_sum = 0.0;
    for (var k = 0; k < 4; k++) {
        let o = vec2<i32>(k & 1, k >> 1u);
        let s = textureLoad(vlao_tex_previous, clamp(i + o, vec2<i32>(0), dims - 1), 0);
        let w = select(1.0 - f.x, f.x, o.x == 1) * select(1.0 - f.y, f.y, o.y == 1);
        if abs(s.g - expected) < tolerance && s.a > 0.0 {
            acc += clamp01((s.a - floor(s.a)) / 0.9) * w;
            w_sum += w;
        }
    }
    return select(-1.0, acc / w_sum, w_sum > 0.05);
}

fn sample_cloud_shadow_mat(scene_pos: vec3<f32>) -> f32 {
    if !cloud_shadows || !clouds_cumulus || !in_overworld() {
        return 1.0;
    }
    let uv = project_cloud_shadow_uv(scene_pos);
    if any(uv < vec2<f32>(0.0)) || any(uv > vec2<f32>(1.0)) {
        return 1.0;
    }
    let cs = textureSampleLevel(cloud_shadow_tex, reflection_sampler, uv, 0.0).r;
    return cloud_shadow_factor(cs, get_cloud_shadow_fade(scene_pos));
}

fn get_ripple_height(coord: vec2<f32>) -> f32 {
    let t = frame.time * 0.1;
    let n0 = textureSampleLevel(noisetex, noisetex_sampler, coord * 0.3 + t * vec2<f32>(0.6, 0.8), 0.0).y;
    let n1 = textureSampleLevel(noisetex, noisetex_sampler, coord * 0.3 + t * vec2<f32>(-0.3846154, -0.9230769), 0.0).y;
    return mix(n0, n1, 0.5);
}

struct MaterialSpec {
    mat: Mat,
    porosity: f32,
    // photon's ssr_multiplier: the surface shows its surroundings (sky, RT or screen-space reflections), not just
    // the sun's highlight
    reflects: bool,
}

// photon's rgb_to_hsl, which is hue, saturation and value (z is the brightest channel)
fn photon_hsv(c: vec3<f32>) -> vec3<f32> {
    let k = vec4<f32>(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    let p = mix(vec4<f32>(c.bg, k.wz), vec4<f32>(c.gb, k.xy), step(c.b, c.g));
    let q = mix(vec4<f32>(p.xyw, c.r), vec4<f32>(c.r, p.yzx), step(p.x, c.r));
    let d = q.x - min(q.w, q.y);
    let e = 1e-6;
    return vec3<f32>(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

// photon's isolate_hue: how near a colour's hue is to `center` degrees, within `width`
fn isolate_hue(hsv: vec3<f32>, center: f32, width: f32) -> f32 {
    if hsv.y < 1e-2 || hsv.z < 1e-2 {
        return 0.0;
    }
    return pulse_periodic(hsv.x * 360.0, center, width, 360.0);
}

// photon's HARDCODED_SPECULAR (include/surface/material.glsl), by its material masks: smoothness from the
// texel's brightness (its sRGB colour's value), and for metals a reflection in their own colour (f0 >= 0.89
// here). Ids 2-4 and 6 (plants, vines) stay rough as there.
fn hardcoded_specular_of(id: u32, srgb: vec3<f32>, m: ptr<function, Mat>) -> bool {
    let hsv = photon_hsv(srgb);
    let v = hsv.z;
    var s = -1.0;
    var f0 = 0.02;
    var rough_min = 0.0;
    var reflects = false;
    switch id {
        case 0u: { s = 0.33 * smoothstep(0.2, 0.6, v); }
        case 5u: { s = 0.5 * smoothstep(0.16, 0.5, v); }
        case 7u: { s = 0.8 * linear_step(0.81, 0.96, v); }
        case 8u: {
            s = pow4(linear_step(0.4, 0.8, v)) * 0.6;
            reflects = true;
        }
        case 81u: {
            // stained and tinted glass, honey and slime (photon's masks 81-97): roughness 0.1, f0 0.04, reflective
            s = 1.0 - sqrt(0.1);
            f0 = 0.04;
            reflects = true;
        }
        case 9u: { s = 0.4 * linear_step(0.61, 0.85, v); }
        case 10u: { s = 0.5 * linear_step(0.4, 0.8, v); }
        case 11u: {
            s = linear_step(0.02, 0.4, v);
            reflects = true;
        }
        case 12u, 18u: {
            s = sqrt(linear_step(0.1, 0.9, v));
            rough_min = 0.04;
            f0 = 0.9;
            reflects = true;
        }
        case 13u: {
            s = sqrt(linear_step(0.1, 0.9, v));
            rough_min = 0.04;
            f0 = 0.25;
            reflects = true;
        }
        case 17u: {
            s = 0.4 * linear_step(0.61, 0.85, v);
            reflects = true;
        }
        case 27u, 28u: {
            // roughness 0.5 (smoothness 1 - sqrt(0.5)); the oxidised, blue-green parts rougher
            let oxidized = max(isolate_hue(hsv, 120.0, 90.0), isolate_hue(hsv, 180.0, 60.0)) > 0.25;
            s = 1.0 - sqrt(select(0.5, 0.7, oxidized));
            f0 = select(0.01, 0.015, oxidized);
            reflects = true;
        }
        case 29u, 30u: {
            s = 0.25 * linear_step(0.4, 0.8, v);
            rough_min = 0.4;
            f0 = 0.03;
        }
        default: {}
    }
    if s >= 0.0 {
        (*m).roughness = max(sqr(1.0 - s), rough_min);
        (*m).f0 = f0;
    }
    return reflects;
}

// `base_rgb`: the texture colour the surface is lit with (the portal's own swirl for the nether portal, else the sprite's)
fn get_material(input: MaterialInput, albedo: vec3<f32>, base_rgb: vec3<f32>) -> MaterialSpec {
    var m: Mat;
    m.albedo = albedo;
    m.sss_amount = 0.0;
    m.sheen_amount = 0.0;
    m.emission = 0.0;
    m.f0 = 0.02;
    m.roughness = 1.0;
    var porosity = 0.15;
    switch input.material {
        case 2u, 3u, 4u: {
            m.sss_amount = 0.5;
            m.sheen_amount = 1.0;
        }
        case 5u: {
            m.sss_amount = 1.0;
            m.sheen_amount = 0.5;
        }
        case 6u, 14u: {
            m.sss_amount = 0.6;
        }
        case 8u: {
            // ice: strong subsurface scattering
            m.sss_amount = 0.75;
        }
        case 15u: {
            m.sss_amount = 0.1;
        }
        case 81u: {
            // stained and tinted glass, honey and slime
            m.sss_amount = 0.5;
        }
        default: {}
    }
    if input.emission > 0.0 {
        let srgb_max = pow(max_of(clamp01v(base_rgb)), 1.0 / 2.2);
        let mask = select(linear_step(0.5, 0.9, srgb_max), 1.0, input.fluid == 2u);
        m.emission = input.emission * mask * 0.66;
    }
    var reflects = false;
    if hardcoded_specular {
        let srgb = pow(clamp01v(input.albedo.rgb * input.tint.rgb), vec3<f32>(1.0 / 2.2));
        reflects = hardcoded_specular_of(input.material, srgb, &m);
    }
    if block_pbr_maps() {
        let spec = block_specular_map(input.uv);
        if spec.r > 0.0 || spec.g > 0.0 {
            let smoothness = spec.r;
            m.roughness = sqr(1.0 - smoothness);
            m.f0 = select(spec.g, 0.9, spec.g * 255.0 > 229.5);
            reflects = true;
        }
        if spec.a < 0.999 && spec.a > 0.0 {
            m.emission = max(m.emission, spec.a * 0.5);
        }
        let b255 = spec.b * 255.0;
        if b255 > 64.5 {
            m.sss_amount = max(m.sss_amount, (b255 - 65.0) / 190.0);
            porosity = 0.0;
        } else if spec.b > 0.0 {
            porosity = b255 / 64.0;
        }
    }
    return MaterialSpec(m, porosity, reflects);
}

fn screen_depth_to_distance(screen: vec2<f32>, depth: f32) -> f32 {
    let clip = vec4<f32>(screen.x * 2.0 - 1.0, 1.0 - screen.y * 2.0, depth, 1.0);
    let view = frame.projection_inverse * clip;
    return length(view.xyz / view.w);
}

// Fast screen-space reflection raymarch against opaque_depth/opaque_color when hardware RT is off
fn trace_water_ssr(pos: vec3<f32>, refl_dir: vec3<f32>, sky_refl: vec3<f32>, dither: f32) -> vec3<f32> {
    let steps = 12;
    let size = frame.resolution;
    let isize = vec2<i32>(size);
    var step_pos = pos + refl_dir * (0.25 + dither * 0.5);
    var hit_uv = vec2<f32>(-1.0);
    var prev_pos = pos;
    for (var i = 0; i < steps; i++) {
        let ray_step = 0.75 + 0.55 * f32(i);
        prev_pos = step_pos;
        step_pos += refl_dir * ray_step;
        let clip = frame.projection * (frame.view * vec4<f32>(step_pos, 1.0));
        if clip.w <= 0.0 {
            break;
        }
        let ndc = clip.xyz / clip.w;
        let uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        if any(uv < vec2<f32>(0.0)) || any(uv > vec2<f32>(1.0)) {
            break;
        }
        let tx = clamp(vec2<i32>(uv * size), vec2<i32>(0), isize - 1);
        let scene_d = textureLoad(opaque_depth, tx, 0);
        if scene_d > 0.0 {
            let scene_dist = screen_depth_to_distance(uv, scene_d);
            let ray_dist = length(step_pos);
            let diff = ray_dist - scene_dist;
            if diff > 0.0 && diff < ray_step * 2.2 + 0.6 {
                var lo = prev_pos;
                var hi = step_pos;
                for (var r = 0; r < 2; r++) {
                    let mid = 0.5 * (lo + hi);
                    let mc = frame.projection * (frame.view * vec4<f32>(mid, 1.0));
                    if mc.w <= 0.0 {
                        break;
                    }
                    let muv = clamp(vec2<f32>(mc.x / mc.w * 0.5 + 0.5, 0.5 - mc.y / mc.w * 0.5), vec2<f32>(0.0), vec2<f32>(1.0));
                    let mtx = clamp(vec2<i32>(muv * size), vec2<i32>(0), isize - 1);
                    let md = textureLoad(opaque_depth, mtx, 0);
                    let mdist = select(1e4, screen_depth_to_distance(muv, md), md > 0.0);
                    if length(mid) > mdist {
                        hi = mid;
                    } else {
                        lo = mid;
                    }
                }
                let hc = frame.projection * (frame.view * vec4<f32>(hi, 1.0));
                if hc.w > 0.0 {
                    hit_uv = vec2<f32>(hc.x / hc.w * 0.5 + 0.5, 0.5 - hc.y / hc.w * 0.5);
                }
                break;
            }
        }
    }
    if all(hit_uv >= vec2<f32>(0.0)) && all(hit_uv <= vec2<f32>(1.0)) {
        let edge_x = min(hit_uv.x, 1.0 - hit_uv.x);
        let edge_y = min(hit_uv.y, 1.0 - hit_uv.y);
        let edge = smoothstep(0.0, 0.12, min(edge_x, edge_y));
        let htx = clamp(vec2<i32>(hit_uv * size), vec2<i32>(0), isize - 1);
        let ssr_col = linear_to_rec2020(textureLoad(opaque_color, htx, 0).rgb);
        return mix(sky_refl, ssr_col, edge);
    }
    return sky_refl;
}

// Without the sky map (sky_map_clouds off): photon reflects its sky map, clouds and all. Here the clouds come
// from last frame's resolved clouds where the reflected direction is on screen (most water seen
// at a shallow angle), fading out toward the screen's edges; elsewhere the reflection is the clear sky.
fn reflected_clouds(sky: vec3<f32>, refl_dir: vec3<f32>) -> vec3<f32> {
    if refl_dir.y <= 0.0 || !(clouds_cumulus || clouds_cirrus || aurora != 0u || crepuscular_rays) {
        return sky;
    }
    let clip = frame.projection * (frame.view * vec4<f32>(refl_dir * 1e4, 1.0));
    if clip.w <= 0.0 {
        return sky;
    }
    let uv = vec2<f32>(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
    let edge = smoothstep(0.0, 0.08, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
    if edge <= 0.0 {
        return sky;
    }
    let dim = vec2<i32>(textureDimensions(clouds_hist_previous));
    let p = uv * vec2<f32>(dim) - 0.5;
    let i = vec2<i32>(floor(p));
    let f = p - floor(p);
    var acc = vec4<f32>(0.0);
    var w_sum = 0.0;
    for (var k = 0; k < 4; k++) {
        let o = vec2<i32>(k & 1, k >> 1u);
        let c = unpack_clouds(textureLoad(clouds_hist_previous, clamp(i + o, vec2<i32>(0), dim - 1), 0));
        if cloud_texel_valid(c) && c.extra > 0u {
            let w = max(select(1.0 - f.x, f.x, o.x == 1) * select(1.0 - f.y, f.y, o.y == 1), 1e-3);
            acc += vec4<f32>(c.scattering, c.transmittance) * w;
            w_sum += w;
        }
    }
    if w_sum <= 0.0 {
        return sky;
    }
    let c = acc / w_sum;
    return sky * mix(1.0, c.a, edge) + c.rgb * edge;
}

fn sky_reflection_color(refl_dir: vec3<f32>, skylight: f32, unoccluded: bool) -> vec3<f32> {
    if in_overworld() {
        let up_dir = normalize(vec3<f32>(refl_dir.x, max(refl_dir.y, 0.0), refl_dir.z));
        var sky = vec3<f32>(0.0);
        let map = sky_map_sample(up_dir);
        if sky_map_clouds && map.a > 0.5 {
            // photon reflects its sky map: the clouds and aurora anywhere in the sky, not only on screen
            sky = map.rgb / map.a;
        } else {
            sky = reflected_clouds(atmosphere_scattering_both(up_dir, sun_color(), moon_color()) * (1.0 - frame.rain * 0.5), refl_dir);
        }
        return select(sky * sqr(skylight), sky * mix(sqr(skylight), 1.0, 0.75), unoccluded);
    }
    if in_end() {
        let bh = draw_end_black_hole(refl_dir);
        return end_sky_color(refl_dir) * (1.0 - bh.a * 0.92) + bh.rgb;
    }
    if in_nether() {
        return nether_sky_color(refl_dir);
    }
    return linear_to_rec2020(frame.fog_color) * 0.1;
}

fn shade_ray_hit(hit: RayHit, refl_dir: vec3<f32>, sky_refl: vec3<f32>, t: Times) -> vec3<f32> {
    // a terrain hit's tint still carries its face's shade (and AO) for now, with hit.shade 1: take the shade
    // out there; where a later Horizon gives the shade apart, hit.shade says so and the tint is used as it is
    let hit_shade = select(1.0, pow(vanilla_face_shade(hit.normal), 2.2), hit.shade >= 0.999);
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
        let hit_cs = sample_cloud_shadow_mat(hit.position);
        let hit_nol = lift(max0(dot(hit.normal, l)), 0.25 / shading_strength);
        lighting += get_light_color() * hit_nol * hit_shadow * hit_cs;
        lighting += get_sky_color() * get_skylight_boost() * skylight_i * sqr(hit_l.y);
        lighting += 0.15 * cave_lighting_i * directional * (1.0 - sqr(hit_l.y)) * (1.0 - 0.7 * frame.darkness);
    } else if in_end() {
        let end_nol = max0(dot(hit.normal, end_light_dir)) * 0.65 + 0.35;
        lighting += vec3<f32>(0.36, 0.28, 0.56) * directional * end_nol * 1.15;
    } else if in_nether() {
        let fog = max(linear_to_rec2020(frame.fog_color), vec3<f32>(0.04, 0.015, 0.008));
        let lava_bounce = mix(0.85, 1.2, clamp01(-hit.normal.y * 0.5 + 0.5));
        lighting += 16.0 * directional * lava_bounce * mix(fog, vec3<f32>(dot(fog, luminance_weights)), 0.45) * 0.055;
    } else {
        lighting += 16.0 * directional * linear_to_rec2020(frame.fog_color) * 0.05;
    }

    let blocklight_col = block_light_tint(hit.position);
    lighting += get_blocklight_falloff(hit_l.x, hit_l.y, 1.0, t) * directional * 6.0 * blocklight_col;

    if hit.emission > 0.0 {
        let srgb_max = pow(max_of(clamp01v(hit.albedo.rgb)), 1.0 / 2.2);
        let mask = select(linear_step(0.5, 0.9, srgb_max), 1.0, hit.fluid == 2u);
        lighting += hit.emission * mask * 0.66 * 40.0 * emission_strength;
    }
    lighting += frame.night_vision * 1.5 * directional;

    var col = max(lighting, vec3<f32>(0.0)) * hit_albedo * rcp_pi;
    if in_overworld() && frame.eye_in == 0u {
        let origin_y = frame.camera_position.y + hit.position.y - refl_dir.y * hit.distance;
        let hit_fog = air_fog_analytic(origin_y, hit.distance, refl_dir, hit_l.y, false);
        col = col * hit_fog.transmittance + hit_fog.direct + hit_fog.ambient;
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
        var coord = input.position.xz + frame.camera_position.xz;
        let flow_dir = normalize(input.normal.xz + vec2<f32>(1e-4));
        // photon's WATER_PARALLAX (get_water_parallax_coord): march the view ray 0.2 blocks into the wave height
        // field in 4 steps, then interpolate to where it crossed; seen from above, on the top surface
        // the 0.2 block shift is a fraction of a pixel past ~32 blocks: it fades out between 16 and 32 and is
        // not marched beyond
        let wave_dist = length(input.position);
        let parallax_fade = 1.0 - smoothstep(16.0, 32.0, wave_dist);
        if water_parallax && parallax_fade > 0.0 && input.normal.y > 0.99 && ray.y < -0.05 {
            let ray_step = ray.xz / -ray.y * (0.2 / 4.0) * parallax_fade;
            var depth_value = get_water_height(coord, flowing, flow_dir);
            var depth_previous = depth_value;
            var depth_march = 0.0;
            for (var i = 0; i < 4 && depth_march < depth_value; i++) {
                coord += ray_step;
                depth_previous = depth_value;
                depth_value = get_water_height(coord, flowing, flow_dir);
                depth_march += 0.25;
            }
            let before = depth_previous - depth_march + 0.25;
            let after = depth_value - depth_march;
            coord = mix(coord, coord - ray_step, clamp01(after / min(after - before, -1e-4)));
        }
        let h = 0.1;
        // all 3 octaves of waves near, the finest left out beyond 48 blocks and the next beyond 128
        let octaves = select(select(1, 2, wave_dist < 128.0), 3, wave_dist < 48.0);
        let w0 = get_water_height_lod(coord, flowing, flow_dir, octaves);
        let w1 = get_water_height_lod(coord + vec2<f32>(h, 0.0), flowing, flow_dir, octaves);
        let w2 = get_water_height_lod(coord + vec2<f32>(0.0, h), flowing, flow_dir, octaves);
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
        rt_hit: RayHit, traced: bool, cloud_shadow: f32, dither: f32, t: Times, spec_aa_kernel: f32) -> vec4<f32> {
    let skylight = input.light.y;
    let nov = clamp01(dot(normal, -ray));
    let underwater = frame.eye_in == 1u;

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

    let biome_color = linear_to_rec2020(input.tint.rgb);
    let absorption = biome_water_coeff(biome_color);
    let scattering_coeff = vec3<f32>(0.01);
    let extinction = scattering_coeff + absorption;
    let albedo_ms = 0.84 * scattering_coeff / extinction;
    let ms_energy = albedo_ms / (1.0 - albedo_ms);
    let skylight_factor = cube(input.light.y);
    let dist = select(max(layer_dist, 2.0 - skylight_factor), 0.0, underwater);
    let light_color = get_light_color() * cloud_shadow;
    let blocklight_color = block_light_tint(input.position);
    let ambient = get_sky_color() * input.light.y + 1.41 * blocklight_color * 6.0 * sqr(input.light.x);
    let transmittance = exp(-extinction * dist);
    // photon's LoV: the light against the direction toward the camera (dot(light_dir, -direction_world))
    let lov = dot(light_dir(), -ray);
    var scatter = light_color * smoothstep(0.0, 0.25, input.light.y);
    scatter *= 0.7 * henyey_greenstein_phase(-lov, 0.4) + 0.3 * isotropic_phase;
    scatter += ambient * isotropic_phase;
    scatter *= (1.0 - transmittance) * scattering_coeff / extinction;
    scatter *= 1.0 + ms_energy;
    let brightness = (1.0 - exp(-0.33 * layer_dist)) * max(input.light.x, input.light.y);
    // what lies under the water only darkens, by the red channel's transmittance: photon blends its water layer
    // over the scene with alpha 1 - transmittance.r (c1_blend_layers), so sand stays sand-coloured and the
    // water's colour comes from its scattering. Dimmed channel by channel, the floor went cyan.
    var color = behind * transmittance.x + scatter * (1.0 + 6.0 * transmittance * transmittance) * brightness;

    var highlight = 0.0;
    if water_texture == 1u {
        let r = input.albedo.r;
        highlight = dampen(0.5 * sqr(linear_step(0.63, 1.0, r)) + 0.03 * r)
            * (1.0 - cube(linear_step(0.0, 0.5, input.light.y)));
        color += clamp01v(0.5 * exp(-2.0 * absorption) * highlight) * (get_sky_color() * input.light.y + 0.1) * rcp_pi;
    } else if water_texture == 2u {
        let vanilla = linear_to_rec2020(input.albedo.rgb * input.tint.rgb);
        color = mix(color, vanilla * (get_sky_color() * sqr(input.light.y) + light_color * 0.2) * rcp_pi, input.albedo.a * 0.5);
    }

    let l = light_dir();
    let nol = dot(normal, l);
    var shadow = vec3<f32>(1.0);
    if frame.has_shadow != 0u {
        shadow = vec3<f32>(get_shadow_cheap(input.position, input.normal, max(nol, 0.01)));
    }

    // photon's WATER_EDGE_HIGHLIGHT: where the water is less than half a block deep its surface turns into a
    // pale, lit layer (alpha 1 there), stronger on the texture's bright streaks
    if water_edge_highlight && !underwater {
        let depth = layer_dist * max(abs(ray.y), eps);
        var edge = cube(max0(1.0 - 2.0 * depth)) * select(1.0, 1.0 + 8.0 * highlight, water_texture == 1u);
        edge *= max0(normal.y) * (1.0 - 0.5 * sqr(input.light.y));
        let albedo = clamp01(0.1 * edge / mix(1.0, max(dot(get_sky_color(), luminance_weights), 0.5), input.light.y));
        let lit = albedo * (light_color * shadow * max0(nol) + get_sky_color() * input.light.y) * rcp_pi;
        color = mix(color, vec3<f32>(lit), clamp01(edge));
    }

    let n_rel = select(1.333, 1.0 / 1.333, underwater);
    let fresnel = fresnel_dielectric(nov, n_rel);
    let sky_refl = sky_reflection_color(refl_dir, skylight, traced && rt_hit.distance < 0.0);
    var reflected = sky_refl;
    if traced && rt_hit.distance >= 0.0 {
        reflected = shade_ray_hit(rt_hit, refl_dir, sky_refl, t);
    } else if !traced && water_reflections && !underwater {
        reflected = trace_water_ssr(input.position, refl_dir, sky_refl, dither);
    }
    color = mix(color, reflected, fresnel);

    let h = normalize(l - ray);
    color += specular_highlight(0.02, 0.02, nol, nov, dot(l, -ray), max0(dot(l, h)), light_color * shadow, spec_aa_kernel) * select(1.0, 0.0, underwater);

    return vec4<f32>(color, 1.0);
}

// The noise that rotates the soft-shadow and subsurface sampling. Photon re-rolls it every pixel and
// frame for its TAA to average; without TAA that showed as grain that crawled over the surface whenever the
// camera or a waving plant moved. Here it is fixed to the texture's own texels (at the mip level drawn), so
// it moves with the surface and reads as texture detail.
fn surface_dither(input: MaterialInput) -> f32 {
    let texels = block_texture_size() / exp2(floor(max(block_texture_lod(), 0.0)));
    return interleaved_gradient_noise(floor(fract(input.uv) * texels) + 0.5);
}

// photon's FANCY_NETHER_PORTAL (gbuffers_all_translucent draw_nether_portal, inspired by Complementary): the
// portal texture read 20 times along the view ray, 0.2 blocks into the portal, nearer layers weighted more, its
// dark parts kept at 0.23, brighter where the portal meets a block. Summed in sRGB as photon's gtexture reads.
fn nether_portal_parallax(input: MaterialInput, ray: vec3<f32>, dither: f32) -> vec4<f32> {
    let t = input.tangent.xyz;
    let b = cross(input.normal, t) * input.tangent.w;
    let ray_t = vec3<f32>(dot(ray, t), dot(ray, b), dot(ray, input.normal));
    if ray_t.z > -1e-3 {
        return input.albedo;
    }
    let depth_step = 1.0 / 20.0;
    let ray_step = ray_t.xy / -ray_t.z * 0.2 * depth_step;
    var p = fract(input.uv) + ray_step * dither;
    var result = vec4<f32>(0.0);
    for (var i = 0; i < 20; i++) {
        let tex = block_texture(fract(p));
        let col = vec4<f32>(pow(clamp01v(tex.rgb), vec3<f32>(1.0 / 2.2)), tex.a);
        var density = linear_step(0.0, 0.6, dot(col.rgb, luminance_weights_rec709));
        density = max(density, 0.23) * (1.0 - depth_step * (f32(i) + dither));
        result += col * density;
        p += ray_step;
    }
    // where the portal meets the block behind it, brighter (layer_dist as the water's)
    let size = vec2<i32>(frame.resolution);
    let texel = clamp(vec2<i32>(input.screen * frame.resolution), vec2<i32>(0), size - 1);
    let behind_depth = textureLoad(opaque_depth, texel, 0);
    let behind_dist = select(screen_depth_to_distance(input.screen, behind_depth), 1e4, behind_depth <= 0.0);
    let layer = max0(behind_dist - length(input.position)) * max_of(abs(ray));
    result *= 1.0 + 2.0 * cube(max0(1.0 - 2.0 * layer));
    let srgb = clamp(result * 4.0 * depth_step, vec4<f32>(0.0), vec4<f32>(1.0));
    return vec4<f32>(pow(srgb.rgb, vec3<f32>(2.2)), srgb.a);
}

fn material(input: MaterialInput) -> Surface {
    let t = get_times();
    let dither = surface_dither(input);
    let ray = normalize(input.position);
    let is_water = input.fluid == 1u;
    let flat_normal = input.normal;
    // the texture colour and alpha the surface is lit with: the portal's own layered swirl in its place
    var base = input.albedo;
    if fancy_nether_portal && input.material == 40u {
        base = nether_portal_parallax(input, ray, dither);
    }

    var water_n = flat_normal;
    if is_water {
        water_n = water_normal(input, ray);
    }

    var ao = 1.0;
    var m: Mat;
    var normal = flat_normal;
    var puddle_amount = 0.0;
    var reflects = false;
    let light_levels = clamp(input.light, vec2<f32>(0.0), vec2<f32>(1.0));

    if !is_water {
        // Shader API 0.2 (final) hands the tint, the face's shade and vanilla's ambient occlusion over apart.
        // Photon shades faces itself, so the shade is left out. Vanilla's AO is taken back to the gamma value
        // photon uses (the API gives it decoded with the 2.2 power) and, as in gbuffers_all_solid.fsh, darkens the
        // albedo (lifted, to leave room for the GTAO) and nothing else; there is none on leaves. The `ao` the light
        // is multiplied by is the GTAO's, which the post pass applies (ambient light and, squared, the sun's).
        let tint_albedo = input.tint.rgb;
        let vanilla_ao = select(pow(clamp(input.ao, 0.0, 1.0), 1.0 / 2.2), 1.0, input.material == MAT_LEAVES);
        let gtao_on = ssao && gtao && ao_intensity > 0.0;
        let vao_strength = select(1.0, 0.9, gtao_on);
        let vao_lift = select(0.0, 0.5, gtao_on);
        let vao_mul = lift(vanilla_ao, vao_lift) * vao_strength + (1.0 - vao_strength);
        let albedo = linear_to_rec2020(clamp01v(base.rgb * tint_albedo)) * vao_mul;
        let spec_res = get_material(input, albedo, base.rgb);
        m = spec_res.mat;
        reflects = spec_res.reflects;

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

        // Photon rain_puddles.glsl: outdoor puddle darkening, raindrop ripples & mirror roughness on solid ground
        if rain_puddles && in_overworld() && frame.wetness > 0.0 && input.material == 0u
            && flat_normal.y > 0.99 && frame.precipitation != 2u && frame.temperature >= 0.15 && frame.downfall > 0.0 {
            let wpos = input.position + frame.camera_position;
            var p = textureSampleLevel(noisetex, noisetex_sampler, wpos.xz * 0.025, 0.0).w;
            p = linear_step(0.45, 0.55, p) * frame.wetness;
            p *= (1.0 - cube(light_levels.x)) * linear_step(14.0 / 15.0, 1.0, light_levels.y);
            if p > eps {
                puddle_amount = p;
                let por = spec_res.porosity;
                m.albedo *= 1.0 - 0.67 * por * p;
                let np = p * (1.0 - por);
                m.albedo *= 1.0 - 0.33 * np;
                m.f0 = max(m.f0, mix(m.f0, 0.02, p));
                m.roughness = mix(m.roughness, 0.002, p);
                if frame.rain > 0.01 {
                    let h = 0.1;
                    let r0 = get_ripple_height(wpos.xz);
                    let r1 = get_ripple_height(wpos.xz + vec2<f32>(h, 0.0));
                    let r2 = get_ripple_height(wpos.xz + vec2<f32>(0.0, h));
                    let slope = 0.05 * frame.rain * smoothstep(0.0, 0.1, abs(dot(flat_normal, ray)));
                    let r_n = normalize(vec3<f32>((r1 - r0) * slope, h, (r2 - r0) * slope));
                    normal = normalize(mix(normal, r_n, p));
                }
            }
        }
    }

    // Geometric specular anti-aliasing (Kaplanyan / Tokuyoshi 2016): where the shading normal changes fast across
    // a pixel (water waves far away, ripples, rough normal maps) the highlight is a sub-pixel speck that shimmers; the
    // variance of the normal across the pixel widens the lobe (alpha^2 += min(2 sigma^2 (|dn/dx|^2 + |dn/dy|^2), 0.18))
    // so it averages out. Calm surfaces have none of it. (Derivatives: here, where control flow is uniform.)
    let spec_n = select(normal, water_n, is_water);
    let dn_dx = dpdx(spec_n);
    let dn_dy = dpdy(spec_n);
    let spec_aa_kernel = select(0.0, min(2.0 * 0.15915494 * (dot(dn_dx, dn_dx) + dot(dn_dy, dn_dy)), 0.18), specular_aa);
    if !is_water {
        m.roughness = sqrt(min(sqr(m.roughness) + spec_aa_kernel, 1.0));
    }

    let refl_surface_n = select(normal, water_n, is_water);
    var refl_dir = reflect(ray, refl_surface_n);
    let into_plane = dot(refl_dir, flat_normal);
    if into_plane < 0.0 {
        refl_dir = normalize(refl_dir - 2.0 * into_plane * flat_normal);
    }

    let want_water_rt = is_water && water_reflections && frame.eye_in != 1u;
    let want_pbr_rt = !is_water && specular_highlights && ((reflects && m.roughness < 0.3) || puddle_amount > 0.05) && m.sss_amount < 0.25;
    let want_rt_refl = frame.has_ray_tracing != 0u && rt_reflections && (want_water_rt || want_pbr_rt);

    // Single trace(...) call site in the material stage to minimize SPIR-V traversal overhead
    var rt_hit: RayHit;
    rt_hit.distance = -1.0;
    if want_rt_refl {
        rt_hit = trace(input.position + flat_normal * 0.03, refl_dir, min(frame.ray_distance, 128.0));
    }

    let cs = sample_cloud_shadow_mat(input.position);

    if is_water {
        let water = shade_water(input, ray, water_n, refl_dir, rt_hit, want_rt_refl, cs, dither, t, spec_aa_kernel);
        return Surface(vec4<f32>(rec2020_to_linear(water.rgb), 1.0));
    }

    let l = light_dir();
    let nol = dot(normal, l);
    let nov = clamp01(dot(normal, -ray));
    // photon's LoV is dot(light_dir, -direction_world): with the sign flipped, leaves and grass glowed with the
    // sun behind the camera and stayed dull against it, the opposite of light through a leaf
    let lov = dot(l, -ray);

    var sh: ShadowResult;
    sh.light = vec3<f32>(1.0);
    sh.sss_depth = 0.0;
    sh.fade = 1.0;
    sh.under_water = 0.0;
    let flat_nol = dot(flat_normal, l);
    if in_overworld() {
        // Plants and leaves look their shadows and light-through up at each texture texel's centre (photon's
        // PIXELATED_SHADOWS, for foliage only): every texel gets one value that moves with the plant as it
        // waves, where a lookup per pixel of the cut-out leaves' and blades' own shadows speckled.
        var shadow_p = input.position;
        if m.sss_amount > eps {
            let texels = block_texture_size() / exp2(floor(max(block_texture_lod(), 0.0)));
            let uv = fract(input.uv);
            let duv = (floor(uv * texels) + 0.5) / texels - uv;
            let bitangent = cross(flat_normal, input.tangent.xyz) * input.tangent.w;
            shadow_p += input.tangent.xyz * duv.x + bitangent * duv.y;
        }
        // and one fixed rotation of the filter for them: a rotation per texel mottled the grass's shadow of
        // itself texel by texel, where a fixed one shades neighbouring texels alike
        let shadow_dither = select(dither, 0.5, m.sss_amount > eps);
        sh = get_shadows(shadow_p, flat_normal, select(flat_nol, max(flat_nol, 0.01), m.sss_amount > eps), m.sss_amount, light_levels.y, shadow_dither, cs);
    }
    // Single trace_any(...) call site in the material stage for crisp near-field contact shadows
    if frame.has_ray_tracing != 0u && rt_contact_shadows && !is_water && in_overworld()
        && frame.has_shadow != 0u && flat_nol > 0.01 && m.sss_amount < 0.25 && length(input.position) < 64.0 {
        // with block entity shadows, the ray also hits entities and the block entities kept in the scene
        let layers = select(RAY_SOLID, RAY_SOLID | RAY_ENTITY, block_entity_shadows);
        if trace_any_layers(input.position + flat_normal * 0.03, l, 16.0, layers) {
            sh.light = vec3<f32>(0.0);
        }
    }

    var gtao_sss = -1.0;
    if m.sss_amount > eps && foliage_ambient_sss {
        gtao_sss = gtao_sss_previous(input.position);
    }
    let lres = get_diffuse_lighting(m, input.position, normal, flat_normal, light_levels, ao, sh, cs, nol, lov, t, input.colored_light, gtao_sss);
    // photon's metal_diffuse_amount: metals keep half their diffuse light (all of it gone fights its SSR)
    let metal = m.f0 >= 0.89;
    var color = lres.total * select(1.0, 0.5, metal);
    var sun_contrib = lres.direct_sun * select(1.0, 0.5, metal);

    if specular_highlights && m.roughness < 0.99 {
        if in_overworld() {
            let h = normalize(l - ray);
            let shadow_mix = mix(sh.light * cs, vec3<f32>(sqr(light_levels.y) * cs), sh.fade);
            let spec_sun = specular_highlight(m.roughness, m.f0, nol, nov, lov, max0(dot(l, h)), get_light_color() * shadow_mix, 0.0);
            color += spec_sun;
            sun_contrib += spec_sun;
        }
        // the surroundings only on what photon gives reflections (ssr_multiplier); the rest just the sun's highlight
        if reflects || puddle_amount > 0.02 {
            let sky_refl = sky_reflection_color(refl_dir, light_levels.y, want_rt_refl && rt_hit.distance < 0.0);
            var env_refl = sky_refl;
            if want_rt_refl && rt_hit.distance >= 0.0 {
                let rt_env = shade_ray_hit(rt_hit, refl_dir, sky_refl, t);
                env_refl = mix(rt_env, sky_refl, smoothstep(0.05, 0.3, m.roughness));
            }
            let metal_tint = mix(vec3<f32>(1.0), m.albedo, select(0.0, 0.85, metal));
            color += env_refl * metal_tint * fresnel_schlick(nov, m.f0) * sqr(1.0 - m.roughness);
        }
    }

    if !input.translucent {
        // Pack sun luminance ratio (0..255, the units) + Land SSR weight (0..0.98, the fraction) into set_surface.data
        let tot_lum = max(dot(color, luminance_weights), 1e-5);
        let sun_ratio = clamp01(dot(sun_contrib, luminance_weights) / tot_lum);
        let sun_q = floor(sun_ratio * 255.0 + 0.5);
        var ssr_w = 0.0;
        if !want_rt_refl && specular_highlights && ((reflects && m.roughness < 0.35) || puddle_amount > 0.02) && m.sss_amount < 0.25 {
            let smooth_w = select(0.0, sqr(1.0 - m.roughness) * 0.65, m.roughness < 0.35);
            ssr_w = clamp(max(puddle_amount, smooth_w), 0.0, 0.98);
        }
        // and above them, times 256, the ambient light's share of the colour (0..255): what the GTAO darkens
        let ambient_ratio = clamp01(dot(lres.ambient, luminance_weights) * select(1.0, 0.5, metal) / tot_lum);
        let ambient_q = floor(ambient_ratio * 255.0 + 0.5);
        set_surface(normal, 1.0 - m.roughness, ambient_q * 256.0 + sun_q + ssr_w * 0.98);
    }

    color = purkinje_shift_apply(color, light_levels);
    // The sky, its clouds and the air fog behind stained glass, tinted glass and ice. The post pass fogs and clouds a
    // pixel by the nearest surface, the glass, so what lies behind it kept neither: a clear sky seen through a
    // window had no clouds, and distant hills no haze past the glass. As shade_water does for what lies behind the
    // water, this reads the picture behind (opaque_color) and adds the difference to what the pass would have made of
    // it: the sky map's clouds and fog where it is sky, the air fog over the span behind the glass where it is terrain.
    // The correction is blended in with the glass's own alpha, so it ends up as (1 - alpha) of the difference.
    if behind_glass_sky && input.translucent && input.material != 40u && frame.eye_in == 0u && in_overworld() && base.a > 0.02 {
        let texel = clamp(vec2<i32>(input.screen * frame.resolution), vec2<i32>(0), vec2<i32>(frame.resolution) - 1);
        let behind_depth = textureLoad(opaque_depth, texel, 0);
        let behind = linear_to_rec2020(textureLoad(opaque_color, texel, 0).rgb);
        var behind_new = behind;
        if behind_depth <= 0.0 {
            let map = sky_map_sample(normalize(vec3<f32>(ray.x, max(ray.y, 0.0), ray.z)));
            if sky_map_clouds && map.a > 0.5 {
                behind_new = map.rgb / map.a;
            }
        } else {
            let surface_dist = length(input.position);
            let span = clamp(screen_depth_to_distance(input.screen, behind_depth) - surface_dist, 0.0, frame.render_distance);
            let fog = air_fog_analytic(frame.camera_position.y + input.position.y, span, ray, eye_skylight(), false);
            behind_new = behind * fog.transmittance + fog.direct + fog.ambient;
        }
        color += (behind_new - behind) * ((1.0 - base.a) / max(base.a, 0.15));
    }
    return Surface(vec4<f32>(rec2020_to_linear(max(color, vec3<f32>(0.0))), base.a));
}
