// photon's ssrt + land SSR + c1_blend_layers + rainbows + d4 fog, with the half-res AO and light shafts of
// the vlao pass and the resolved clouds of clouds_resolve

var<private> RAINBOW_LAB: array<vec3<f32>, 9> = array<vec3<f32>, 9>(
    vec3<f32>(0.0, 0.0, 0.0),
    vec3<f32>(1.9204079, 8.6156529, 3.0349932),
    vec3<f32>(5.1505955, 2.0166723, 7.7518017),
    vec3<f32>(8.3748964, -4.5569349, 12.4584607),
    vec3<f32>(6.4603751, -13.1979612, 9.4336169),
    vec3<f32>(2.5902925, 0.6233706, -9.6384645),
    vec3<f32>(0.6521799, 4.5827589, -12.4708986),
    vec3<f32>(2.5725879, 13.1984118, -9.4357577),
    vec3<f32>(0.0, 0.0, 0.0),
);

fn cie_lab_f_inv(t: f32) -> f32 {
    let d = 6.0 / 29.0;
    return select(3.0 * d * d * (t - 4.0 / 29.0), t * t * t, t > d);
}

fn lab_to_xyz(lab: vec3<f32>) -> vec3<f32> {
    let xyz_n = vec3<f32>(95.0489, 100.0, 108.8840);
    let y = lab.x / 116.0 + 16.0 / 116.0;
    return xyz_n * vec3<f32>(
        cie_lab_f_inv(y + lab.y / 500.0),
        cie_lab_f_inv(y),
        cie_lab_f_inv(y - lab.z / 200.0),
    );
}

fn draw_single_rainbow(view_angle: f32, start_angle: f32, end_angle: f32) -> vec3<f32> {
    let prog = (view_angle - start_angle) / (end_angle - start_angle);
    if prog < 0.0 || prog > 1.0 {
        return vec3<f32>(0.0);
    }
    let idx_f = clamp(prog * 8.0 - 0.5, 0.0, 7.999);
    let i0 = u32(floor(idx_f));
    let i1 = min(i0 + 1u, 8u);
    let f = fract(idx_f);
    let lab = mix(RAINBOW_LAB[i0], RAINBOW_LAB[i1], f);
    let col = max(lab_to_xyz(lab) * xyz_to_rec2020, vec3<f32>(0.0));
    let intensity = prog - prog * dampen(prog);
    return col * intensity;
}

fn draw_rainbows(fragment_color: vec3<f32>, ray_dir: vec3<f32>, view_distance: f32) -> vec3<f32> {
    if !rainbows || !in_overworld() || is_night() {
        return fragment_color;
    }
    // photon's get_rainbow_amount (weather/rainbow.glsl): wet ground or a humid sky, gone while it rains
    let rain_amt = max(frame.wetness, 0.5 * linear_step(0.6, 1.0, get_weather().humidity)) * (1.0 - frame.rain);
    if rain_amt < eps {
        return fragment_color;
    }
    let angle = fast_acos(clamp01(-dot(ray_dir, light_dir())));
    let first = draw_single_rainbow(angle, 44.0 * degree, 40.0 * degree);
    let second = draw_single_rainbow(angle, 45.5 * degree, 48.5 * degree);
    let trans_approx = mix(vec3<f32>(1.0, 0.75, 0.5), vec3<f32>(1.0), dampen(max0(ray_dir.y)));
    let rainbow_col = get_light_color() * 0.1 * (3.0 * first + 0.5 * second) * (trans_approx * trans_approx);
    let fade = rain_amt * smoothstep(500.0, 600.0, view_distance) * smoothstep(0.0, 0.05, ray_dir.y);
    return fragment_color + rainbow_col * fade;
}

// Distant screen-space shadows (Photon's lighting/shadows/ssrt.glsl) beyond shadow map distance
fn compute_ssrt_shadow(pos: vec3<f32>, normal: vec3<f32>, dist: f32, dither: f32) -> f32 {
    let ld = light_dir();
    if ld.y < 0.01 {
        return 0.0;
    }
    let steps = 12;
    let origin = pos + normal * max(0.08, dist * 0.005);
    var ray_dist = 0.0;
    var step_len = max(0.35, dist * 0.006);
    var hit = 0.0;
    for (var i = 0; i < steps; i++) {
        let p_w = origin + ld * (ray_dist + step_len * dither);
        ray_dist += step_len;
        step_len *= 1.45;
        let clip = frame.projection * (frame.view * vec4<f32>(p_w, 1.0));
        if clip.w <= 0.0 {
            break;
        }
        let ndc = clip.xyz / clip.w;
        let uv_s = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        if any(uv_s < vec2<f32>(0.0)) || any(uv_s > vec2<f32>(1.0)) {
            break;
        }
        let d_s = depth_at(uv_s);
        if d_s <= 0.0 {
            continue;
        }
        let scene_p = view_position(uv_s, d_s);
        let ray_cam_d = length(p_w);
        let scene_cam_d = length(scene_p);
        let thickness = max(2.0, step_len * 2.2 + 0.04 * scene_cam_d);
        let diff = ray_cam_d - scene_cam_d;
        if diff > 0.05 && diff < thickness {
            hit = 1.0;
            break;
        }
    }
    return hit;
}

// Fast screen-space reflections on wet puddles and smooth opaque LabPBR surfaces when HW RT is inactive
fn compute_land_ssr(pos: vec3<f32>, ray_dir: vec3<f32>, normal: vec3<f32>, dither: f32) -> vec4<f32> {
    var refl = reflect(ray_dir, normal);
    if dot(refl, normal) < 0.0 {
        refl = normalize(refl - 2.0 * dot(refl, normal) * normal);
    }
    let steps = 12;
    let size = frame.resolution;
    let isize = vec2<i32>(size);
    var step_pos = pos + normal * 0.06 + refl * (0.20 + dither * 0.45);
    var prev_pos = pos;
    for (var i = 0; i < steps; i++) {
        let step_len = 0.65 + 0.45 * f32(i);
        prev_pos = step_pos;
        step_pos += refl * step_len;
        let clip = frame.projection * (frame.view * vec4<f32>(step_pos, 1.0));
        if clip.w <= 0.0 {
            break;
        }
        let ndc = clip.xyz / clip.w;
        let uv_s = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        if any(uv_s < vec2<f32>(0.0)) || any(uv_s > vec2<f32>(1.0)) {
            break;
        }
        let d_s = depth_at(uv_s);
        if d_s > 0.0 {
            let scene_d = length(view_position(uv_s, d_s));
            let ray_d = length(step_pos);
            let diff = ray_d - scene_d;
            if diff > 0.02 && diff < step_len * 2.4 + 0.6 {
                let mid = 0.5 * (prev_pos + step_pos);
                let mc = frame.projection * (frame.view * vec4<f32>(mid, 1.0));
                var hit_uv = uv_s;
                if mc.w > 0.0 {
                    let muv = vec2<f32>(mc.x / mc.w * 0.5 + 0.5, 0.5 - mc.y / mc.w * 0.5);
                    if all(muv >= vec2<f32>(0.0)) && all(muv <= vec2<f32>(1.0)) {
                        hit_uv = muv;
                    }
                }
                let edge = smoothstep(0.0, 0.14, min(min(hit_uv.x, 1.0 - hit_uv.x), min(hit_uv.y, 1.0 - hit_uv.y)));
                let htx = clamp(vec2<i32>(hit_uv * size), vec2<i32>(0), isize - 1);
                let col = linear_to_rec2020(textureLoad(scene_color, htx, 0).rgb);
                return vec4<f32>(col, edge);
            }
        }
    }
    return vec4<f32>(0.0, 0.0, 0.0, 0.0);
}

// The half-res light shafts (x) and AO (y), upsampled with weights that follow the view distance
fn sample_vlao(uv: vec2<f32>, dist: f32) -> vec2<f32> {
    let dim = vec2<i32>(textureDimensions(vlao_tex));
    // vlao's texel h holds pixel 2h: texel centres sit at pixel 2h + 0.5
    let fcoord = clamp((uv * frame.resolution - 0.5) * 0.5, vec2<f32>(0.0), vec2<f32>(dim - 1));
    let p0 = vec2<i32>(fcoord);
    let f = fract(fcoord);
    let ref_d = min(dist, 65000.0);
    var sum_v = vec2<f32>(0.0);
    var sum_w = 0.0;
    var nearest = vec2<f32>(1.0);
    var nearest_d = 1e9;
    for (var k = 0; k < 4; k++) {
        let o = vec2<i32>(k & 1, k >> 1u);
        let s = textureLoad(vlao_tex, clamp(p0 + o, vec2<i32>(0), dim - 1), 0);
        let wx = select(1.0 - f.x, f.x, o.x == 1);
        let wy = select(1.0 - f.y, f.y, o.y == 1);
        let dd = abs(s.g - ref_d);
        let w = wx * wy * exp(-dd / max(ref_d * 0.08, 0.5));
        sum_v += vec2<f32>(s.r, s.b) * w;
        sum_w += w;
        if dd < nearest_d {
            nearest_d = dd;
            nearest = vec2<f32>(s.r, s.b);
        }
    }
    if sum_w > 1e-4 {
        return sum_v / sum_w;
    }
    // no texel saw this surface (a thin edge at half res): take the closest in distance
    return nearest;
}

struct CloudsSample {
    scattering: vec3<f32>,
    transmittance: f32,
    distance: f32,
}

// The resolved half-res clouds, bilinear over the texels that aren't holes, with the nearest of their
// distances (photon's read_clouds_and_aurora)
fn catmull_rom_w(f: f32) -> vec4<f32> {
    let f2 = f * f;
    let f3 = f2 * f;
    return vec4<f32>(-0.5 * f3 + f2 - 0.5 * f, 1.5 * f3 - 2.5 * f2 + 1.0, -1.5 * f3 + 2.0 * f2 + 0.5 * f, 0.5 * f3 - 0.5 * f2);
}

fn sample_clouds(uv: vec2<f32>) -> CloudsSample {
    let dim = vec2<i32>(textureDimensions(clouds_hist));
    let p = uv * vec2<f32>(dim) - 0.5;
    let i = vec2<i32>(floor(p));
    let f = p - floor(p);
    var acc = vec4<f32>(0.0);
    var w_sum = 0.0;
    var d_min = CLOUDS_NO_HIT;
    var min_t = 1.0;
    for (var k = 0; k < 4; k++) {
        let o = vec2<i32>(k & 1, k >> 1u);
        let c = unpack_clouds(textureLoad(clouds_hist, clamp(i + o, vec2<i32>(0), dim - 1), 0));
        if cloud_texel_valid(c) && c.extra > 0u {
            min_t = min(min_t, c.transmittance);
            let w = max(select(1.0 - f.x, f.x, o.x == 1) * select(1.0 - f.y, f.y, o.y == 1), 1e-3);
            acc += vec4<f32>(c.scattering, c.transmittance) * w;
            w_sum += w;
            d_min = min(d_min, c.distance);
        }
    }
    if w_sum <= 0.0 {
        return CloudsSample(vec3<f32>(0.0), 1.0, CLOUDS_NO_HIT);
    }
    let bilinear = CloudsSample(acc.rgb / w_sum, acc.a / w_sum, d_min);
    // the sharper filter only where there are clouds to sharpen: not on clear sky (all four texels clear)
    if clouds_bicubic_upsample && w_sum > 0.999 && min_t < 0.999 {
        // Catmull-Rom over 4x4 texels where all of them hold clouds: the half-res history is sharper than a
        // bilinear fetch makes it (the bilinear one blurs every cloud edge by about a texel); next to holes
        // (terrain edges) it falls through to the bilinear filter over the valid texels below
        let wx = catmull_rom_w(f.x);
        let wy = catmull_rom_w(f.y);
        var cr = vec4<f32>(0.0);
        var all_valid = true;
        var d_near = CLOUDS_NO_HIT;
        for (var k = 0; k < 16; k++) {
            let o = vec2<i32>(k & 3, k >> 2u);
            let c = unpack_clouds(textureLoad(clouds_hist, clamp(i + o - 1, vec2<i32>(0), dim - 1), 0));
            if cloud_texel_valid(c) && c.extra > 0u {
                cr += vec4<f32>(c.scattering, c.transmittance) * (wx[o.x] * wy[o.y]);
                if all(o >= vec2<i32>(1)) && all(o <= vec2<i32>(2)) {
                    d_near = min(d_near, c.distance);
                }
            } else {
                all_valid = false;
            }
        }
        if all_valid {
            return CloudsSample(max(cr.rgb, vec3<f32>(0.0)), clamp01(cr.a), d_near);
        }
    }
    return bilinear;
}

// photon's include/surface/edge_highlight.glsl (MC Dungeons-like): a point on a face that is one block pixel
// (1/16) from a convex edge, found in screen space. Each check steps that far along the face (or off it): an
// edge there shows as the scene suddenly farther away, or as a face turned toward the step (the block's side).
fn has_edge_highlight(n: vec3<f32>) -> bool {
    // faces along an axis: blocks, not slopes or plants
    return abs(dot(abs(n), vec3<f32>(1.0)) - 1.0) < 0.1;
}

fn edge_highlight_check(offset: vec3<f32>, center: vec3<f32>, center_n: vec3<f32>, center_dist: f32, rcp_nov: f32) -> f32 {
    let p = center + offset;
    let clip = frame.projection * vec4<f32>((frame.view * vec4<f32>(p, 0.0)).xyz, 1.0);
    if clip.w <= 0.0 {
        return 0.0;
    }
    let uv = vec2<f32>(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
    if any(uv < vec2<f32>(0.0)) || any(uv > vec2<f32>(1.0)) {
        return 0.0;
    }
    let t = min(vec2<i32>(uv * frame.resolution), vec2<i32>(frame.resolution) - 1);
    let d = textureLoad(scene_depth, t, 0);
    let sample_dist = select(length(view_position(uv, d)), 1e6, d <= 0.0);
    let expected = length(p);
    let depth_edge = abs(sample_dist - expected) > 0.25 * rcp_nov && expected < sample_dist;
    let s = surface_at(t);
    let normal_edge = s.present && abs(dot(center_n, s.normal)) < 0.99 && dot(s.normal, normalize(offset)) > 0.01;
    let counts = (s.present && has_edge_highlight(s.normal)) || center_dist < sample_dist;
    return (f32(depth_edge) + f32(normal_edge)) * f32(counts);
}

fn get_edge_highlight(pos: vec3<f32>, n: vec3<f32>, dist: f32) -> f32 {
    if !has_edge_highlight(n) || dist > 160.0 {
        return 0.0;
    }
    let tangent = select(normalize(cross(vec3<f32>(0.0, 1.0, 0.0), n)), vec3<f32>(1.0, 0.0, 0.0), abs(n.y) > 0.99);
    let bitangent = normalize(cross(tangent, n));
    let k = 1.0 / 16.0;
    let rcp_nov = abs(1.0 / dot(normalize(pos), n));
    var h = edge_highlight_check(tangent * k, pos, n, dist, rcp_nov);
    h += edge_highlight_check(-tangent * k, pos, n, dist, rcp_nov);
    h += edge_highlight_check(bitangent * k, pos, n, dist, rcp_nov);
    h += edge_highlight_check(-bitangent * k, pos, n, dist, rcp_nov);
    h += edge_highlight_check(n * k, pos, n, dist, rcp_nov);
    return clamp01(h);
}

// photon's END_GLOW (include/fog/end_fog_vl.glsl): glowing wisps in the End's fog, from its 3-d swirly worley
// noise (the worley texture's .g, 64^3 baked as 8x8 tiles of 66x66)
fn swirl3d(p: vec3<f32>) -> f32 {
    let z = fract(p.z) * 64.0 - 0.5;
    let zf = floor(z);
    let z0 = u32(i32(zf) & 63);
    let z1 = (z0 + 1u) & 63u;
    let a = (vec2<f32>(f32(z0 % 8u), f32(z0 / 8u)) * 66.0 + 1.0 + fract(p.xy) * 64.0) / 528.0;
    let b = (vec2<f32>(f32(z1 % 8u), f32(z1 / 8u)) * 66.0 + 1.0 + fract(p.xy) * 64.0) / 528.0;
    return mix(textureSampleLevel(worley, worley_sampler, a, 0.0).g, textureSampleLevel(worley, worley_sampler, b, 0.0).g, z - zf);
}

fn end_fog_emission(wp: vec3<f32>) -> vec3<f32> {
    let main_col = from_srgb(vec3<f32>(0.75, 0.33, 1.0)) * 0.75;
    let alt_col = 0.5 * vec3<f32>(0.25, 1.0, 0.5);
    let base = swirl3d(0.02 * wp + vec3<f32>(1.0, 0.1, 0.5) * 0.01 * frame.time);
    let detail = swirl3d(0.04 * wp + vec3<f32>(-0.7, -0.1, -0.1) * 0.05 * frame.time) * 0.8 - 0.4;
    let tint = swirl3d(0.02 * wp + 0.2);
    let density = max0(linear_step(0.6, 0.9, base) + detail);
    let view_dist = distance(wp, frame.camera_position);
    let fade = (1.0 - exp2(-0.1 * view_dist)) * exp2(-0.05 * view_dist)
        * exp2(-0.05 * max0(frame.camera_position.y - 120.0)) * linear_step(0.0, 64.0, wp.y);
    return mix(main_col, alt_col, linear_step(0.5, 0.7, tint)) * (density * fade);
}

// photon marches the fog volume (y 0 to 256) and adds 4 x emission per block, dimmed by the fog in front, times
// its scattering coefficient (0.01). The glow fades out past ~100 blocks, so 12 steps over at most 128 do.
fn end_glow_along(ray_dir: vec3<f32>, dist: f32, dither: f32) -> vec3<f32> {
    let y = frame.camera_position.y;
    let to_top = (256.0 - y) / ray_dir.y;
    let to_bottom = (0.0 - y) / ray_dir.y;
    var start = 0.0;
    var end = dist;
    if y > 256.0 {
        start = select(1e9, to_top, ray_dir.y < 0.0);
    } else if y < 0.0 {
        start = select(1e9, to_bottom, ray_dir.y > 0.0);
    }
    end = min(end, select(to_bottom, to_top, ray_dir.y > 0.0));
    end = min(end, start + 128.0);
    if end <= start {
        return vec3<f32>(0.0);
    }
    let steps = 12;
    let step_len = (end - start) / f32(steps);
    var glow = vec3<f32>(0.0);
    var transmittance = 1.0;
    let step_t = exp(-0.0075 * max(air_fog_density, 0.25) * step_len);
    for (var i = 0; i < steps; i++) {
        let wp = frame.camera_position + ray_dir * (start + (f32(i) + dither) * step_len);
        glow += 4.0 * end_fog_emission(wp) * step_len * transmittance;
        transmittance *= step_t;
    }
    return glow * 0.01;
}

// photon's border_fog (simple_fog.glsl), as the share of the colour left: exp2(-8 (cubic_length / far)^8), thinner
// looking up, and gone more than `far` below the camera. `pos` is the scene position (camera relative).
fn border_fog_t(pos: vec3<f32>, ray_dir: vec3<f32>) -> f32 {
    let cubic_len = pow(cube(abs(pos.x)) + cube(abs(pos.z)), 1.0 / 3.0);
    var t = exp2(-8.0 * pow8(cubic_len / frame.render_distance));
    t = mix(t, 1.0, 0.75 * dampen(linear_step(0.0, 0.2, ray_dir.y)));
    return t * linear_step(-frame.render_distance, 16.0 - frame.render_distance, pos.y);
}

// the sky map (clouds and fog in it) as radiance in direction d, by four texel loads; zero where it has not been drawn
fn sky_map_radiance_at(d: vec3<f32>) -> vec4<f32> {
    let k = sky_map_taps(d);
    let s = textureLoad(cloud_shadow_tex, k.t00, 0) * k.w.x + textureLoad(cloud_shadow_tex, k.t10, 0) * k.w.y
        + textureLoad(cloud_shadow_tex, k.t01, 0) * k.w.z + textureLoad(cloud_shadow_tex, k.t11, 0) * k.w.w;
    return s;
}

fn post(input: PostInput) -> vec4<f32> {
    let texel = vec2<i32>(input.pixel);
    var color = linear_to_rec2020(textureLoad(scene_color, texel, 0).rgb);
    let depth = input.depth;
    let is_sky = depth <= 0.0;
    let pos = view_position(input.uv, max(depth, 1e-7));
    let ray_dir = normalize(pos);
    let dist = select(length(pos), 1e4, is_sky);
    // nothing accumulates the SSRT and SSR rays here: keep their dither still
    let dither = interleaved_gradient_noise(input.pixel + temporal_noise_offset());
    // half-res light shafts and AO, already accumulated over frames
    let vlao = sample_vlao(input.uv, dist);

    // SSAO + SSRT distant shadows + Land SSR on opaque geometry
    if !is_sky {
        let surf = surface_at(texel);
        if surf.present {
            if edge_highlight {
                color *= 1.0 + edge_highlight_strength * get_edge_highlight(pos, surf.normal, dist);
            }
            let ao_val = vlao.y;
            // the surface data: the ambient light's share of the colour (x256), the sun's (units) and the
            // reflection weight (fraction), packed by the material stage
            let data_int = floor(surf.data + 1e-4);
            let ambient_q = floor(data_int / 256.0);
            let sun_frac = clamp01((data_int - ambient_q * 256.0) / 255.0);
            let ssr_w = clamp01(fract(surf.data) / 0.98);
            if gtao {
                // photon's GTAO darkens the skylight (ao), the sun's diffuse light (sqr(ao), AO_IN_SUNLIGHT) and
                // nothing else: block light and emission it does not touch
                color *= max(1.0 - clamp01(ambient_q / 255.0) * (1.0 - ao_val) - sun_frac * (1.0 - ao_val * ao_val), 0.0);
            } else {
                let lum_c = dot(color, luminance_weights);
                let ao_weight = 1.0 - smoothstep(1.5, 6.0, lum_c);
                color *= mix(1.0, ao_val, ao_weight);
            }

            if ssrt_shadows && in_overworld() && sun_frac > 0.005 {
                let ssrt_fade = select(smoothstep(frame.shadow_distance * 0.72, frame.shadow_distance * 0.95, dist), 1.0, frame.has_shadow == 0u);
                if ssrt_fade > 0.01 {
                    let hit = compute_ssrt_shadow(pos, surf.normal, dist, dither);
                    if hit > 0.0 {
                        color *= 1.0 - sun_frac * hit * 0.90 * ssrt_fade;
                    }
                }
            }

            if ssr_w > 0.02 && dist < 128.0 {
                let ssr = compute_land_ssr(pos, ray_dir, surf.normal, dither);
                if ssr.a > 0.0 {
                    let nov = clamp01(dot(surf.normal, -ray_dir));
                    let f = 0.035 + 0.965 * pow(1.0 - nov, 5.0);
                    color = mix(color, ssr.rgb, clamp01(ssr_w * f * ssr.a));
                }
            }
        }
    }

    if in_nether() {
        if frame.eye_in == 0u && !is_sky {
            let world_y = frame.camera_position.y + pos.y;
            let fog_col = max(linear_to_rec2020(frame.fog_color), vec3<f32>(0.025, 0.008, 0.004));
            let lava_haze = smoothstep(54.0, 22.0, world_y) * vec3<f32>(0.16, 0.032, 0.006);
            let scatter_col = fog_col * 0.65 + lava_haze * (0.55 + 0.45 * smoothstep(0.3, -0.4, ray_dir.y));
            let n = textureSampleLevel(noisetex, noisetex_sampler,
                vec2<f32>(atan2(ray_dir.z, ray_dir.x) * rcp_pi + frame.time * 0.003, ray_dir.y * 0.5), 0.0).x;
            let density = mix(0.009, 0.020, smoothstep(70.0, 26.0, world_y)) * (0.85 + 0.3 * n) * max(air_fog_density, 0.25);
            let vanilla_f = smoothstep(frame.fog_environment.x, frame.fog_environment.y, dist);
            let f = clamp01(max(1.0 - exp(-dist * density), vanilla_f));
            color = mix(color, scatter_col, f);
        }
    } else if in_end() {
        if frame.eye_in == 0u && !is_sky {
            let end_fog_col = end_sky_color(ray_dir);
            let world_y = frame.camera_position.y + pos.y;
            let dist_fog = 1.0 - exp(-dist * 0.0075 * max(air_fog_density, 0.25));
            let void_mist = smoothstep(56.0, 10.0, world_y) * (1.0 - exp(-dist * 0.024)) * 0.65;
            var f = clamp01(max(dist_fog, void_mist));
            if border_fog {
                // photon's border_fog, as in the Overworld
                f = max(f, 1.0 - border_fog_t(pos, ray_dir));
            }
            color = mix(color, end_fog_col, f);
        }
        if end_glow && frame.eye_in == 0u {
            color += end_glow_along(ray_dir, select(dist, 1e4, is_sky), dither);
        }
    } else if !in_overworld() {
        let fog_col = linear_to_rec2020(frame.fog_color);
        let f = smoothstep(frame.fog_environment.x, frame.fog_environment.y, dist);
        if !is_sky {
            color = mix(color, fog_col * 0.5, f);
        }
    } else {
        var cloud_t = 1.0;
        if clouds_cumulus || clouds_cirrus || aurora != 0u || crepuscular_rays {
            // photon's d4/c1: the clouds go over terrain only where they are nearer than it, so a leaf or a
            // mountain edge next to the sky never picks up the sky's clouds
            let c = sample_clouds(input.uv);
            if is_sky || c.distance < dist {
                color = color * c.transmittance + c.scattering;
                cloud_t = c.transmittance;
                // photon's lightning flash: 4x its clouds' ambient scattering, taken here as half their opacity
                let flash = textureLoad(cloud_shadow_tex, LIGHTNING_TEXEL, 0).y;
                if lightning_flash && flash > 0.01 {
                    color += vec3<f32>(flash * 4.0 * 0.5 * (1.0 - c.transmittance));
                }
            }
        }

        let underwater = frame.eye_in == 1u;
        let skylight = eye_skylight();

        if !underwater && frame.eye_in == 0u {
            // border fog: terrain fades into the sky at the edge of the render distance (photon's `far`;
            // horizon's frame.far is the far plane, four times it, where no terrain reaches)
            if border_fog && !is_sky {
                let border = 1.0 - border_fog_t(pos, ray_dir);
                if border > 0.0 {
                    var sky = atmosphere_scattering_both(normalize(vec3<f32>(ray_dir.x, max(ray_dir.y, 0.0), ray_dir.z)),
                        sun_color(), moon_color());
                    // photon's d4: the atmosphere mixed with the sky map's colour at the horizon below (clouds and
                    // all) by sqr(horizon_factor): at sunrise and sunset, in rain and looking down at the horizon
                    var horizon_factor = linear_step(0.1, 1.0, exp(-75.0 * sqr(frame.sun_direction.y + 0.0496)));
                    horizon_factor = clamp01(horizon_factor + step(0.01, frame.rain));
                    horizon_factor = max(horizon_factor, dampen(linear_step(0.15, 0.05, ray_dir.y)));
                    if horizon_factor > 0.0 {
                        let hd = normalize(vec3<f32>(ray_dir.x, min(ray_dir.y, -0.1), ray_dir.z));
                        let map = sky_map_radiance_at(hd);
                        if map.a > 0.5 {
                            sky = mix(sky, map.rgb / map.a, sqr(horizon_factor));
                        }
                    }
                    color = mix(color, sky * (1.0 - biome_cave()), border);
                }
            }
            // photon's CAVE_FOG (include/fog/simple_fog.glsl): underground, a dim grey that thickens with distance
            if cave_fog && !is_sky {
                let cave = exp2(-0.0033 * biome_cave() * max0(dist - 1.0));
                color = color * cave + vec3<f32>(0.033) * (1.0 - cave);
            }
            // air fog, over the sky too out to the render distance as photon's: distant terrain then fades into
            // a sky fogged as much as it is, where a fogged hill against a clear sky stood out pale. The
            // light shafts shadow the sun's share of the fog, not the sky's.
            let fog_length = select(dist, frame.render_distance, is_sky);
            // the biome's fog colour and density, eased between biomes by the cloud shadow pass
            let biomes = Biomes(textureLoad(cloud_shadow_tex, BIOME_TEXEL_0, 0), textureLoad(cloud_shadow_tex, BIOME_TEXEL_1, 0));
            let fog = air_fog_analytic_lit(frame.camera_position.y, fog_length, ray_dir, skylight, is_sky,
                textureLoad(cloud_shadow_tex, FRAME_LIGHT_TEXEL, 0).rgb, textureLoad(cloud_shadow_tex, FRAME_SKY_TEXEL, 0).rgb,
                biome_rayleigh(biomes));
            var shafts = select(mix(1.0, vlao.x, clamp01(vl_intensity)), 1.0, is_sky && !vl_weighted_shafts);
            // dawn and dusk (`vl_twilight`, 1 = photon): while the sun is low (about 3 to 15 degrees, fading out by
            // 27), the shadowed share of the fog's sunlight is `k` times as deep and the sunlit air a little
            // brighter, so the shafts read as clearly as in Java, where photon's 35-degree sun path tucks the low
            // sun behind the treeline. The average haze barely changes where nothing shadows it.
            var twilight = 1.0;
            if vl && vl_weighted_shafts && frame.has_shadow != 0u && frame.eye_in == 0u {
                let s_y = frame.sun_direction.y;
                let low_sun = linear_step(0.0, 0.05, s_y) * (1.0 - linear_step(0.25, 0.45, s_y));
                let k = max(1.0 + (vl_twilight - 1.0) * low_sun, 0.0);
                shafts = clamp01(1.0 - (1.0 - shafts) * k);
                twilight = 1.0 + 0.25 * max(k - 1.0, 0.0);
            }
            color = color * fog.transmittance + fog.direct * shafts * twilight + fog.ambient;
            // Photon's rainbow arc opposite the sun
            let eff_dist = select(dist, mix(1e6, 2500.0, linear_step(1.0, 0.95, cloud_t)), is_sky);
            color = draw_rainbows(color, ray_dir, eff_dist);
            // photon's d4: purkinje shift on the sky after its clouds and fog (light levels (0, 1))
            if is_sky {
                color = purkinje_shift_apply(color, vec2<f32>(0.0, 1.0));
            }
        }

        if underwater {
            let absorption = vec3<f32>(0.20, 0.08, 0.04) * water_absorption * rec709_to_rec2020;
            let scattering = vec3<f32>(0.03);
            let ext = absorption + scattering;
            // photon's raymarch_water_fog (include/fog/water_fog_vl.glsl): the ray is at most 50 blocks (the sky's is
            // exactly 50, so far terrain is only dimmed as much), sunlight and skylight reach each step through the
            // water above it (sun along the light, sky straight up, to the surface), four orders of multiple
            // scattering, and the transmittance is raised to 0.75. The light shafts stand in for its shadow lookup.
            let ray_len = select(min(dist, 50.0), 50.0, is_sky);
            let steps = 8;
            let step_len = ray_len / f32(steps);
            let step_t = exp(-ext * step_len);
            let lov = dot(light_dir(), ray_dir);
            let sky_l = frame.eye_light_smooth.y;
            let sun_col = get_light_color() * smoothstep(0.0, 0.25, sky_l);
            let amb_col = get_sky_color() * sky_l;
            let shaft = select(1.0, vlao.x, vl && frame.has_shadow != 0u);
            let light_y = max(light_dir().y, 0.25);
            var trans = vec3<f32>(1.0);
            var scat = vec3<f32>(0.0);
            for (var i = 0; i < steps; i++) {
                let y_step = frame.camera_position.y + ray_dir.y * step_len * (f32(i) + dither);
                // water above the step: down to the camera's own depth below the surface, which skylight tells
                let thick = max(15.0 - 15.0 * sky_l + max0(frame.camera_position.y - y_step), 0.0);
                var sun_t = exp(-ext * thick / light_y) * shaft;
                var sky_t = exp(-ext * thick);
                var aniso = 1.0;
                var amount = 1.0;
                for (var o = 0; o < 4; o++) {
                    let mie = 0.7 * henyey_greenstein_phase(lov, 0.5 * aniso) + 0.3 * isotropic_phase;
                    scat += (sun_col * mie * sun_t + amb_col * isotropic_phase * sky_t) * trans * amount;
                    aniso *= 0.5;
                    amount *= 0.5;
                    sun_t = sqrt(sun_t);
                    sky_t = sqrt(sky_t);
                }
                trans *= step_t;
            }
            scat *= (1.0 - step_t) * scattering / ext;
            color = color * pow(trans, vec3<f32>(0.75)) + scat;
        }
    }

    if frame.eye_in == 2u || frame.eye_in == 3u {
        // photon's common_fog: lava fog from_srgb(0.839, 0.373, 0.075) * 2 from 0.33 blocks, powder snow fog
        // from_srgb(0.957, 0.988, 0.988) * 0.3 from 0.5, both exp2(-(distance - start))
        let fog_col = select(from_srgb(vec3<f32>(0.957, 0.988, 0.988)) * 0.3, from_srgb(vec3<f32>(0.839, 0.373, 0.075)) * 2.0, frame.eye_in == 2u);
        let t = exp2(-max0(dist - select(0.5, 0.33, frame.eye_in == 2u)));
        color = mix(fog_col, color, t);
    }

    // blindness and darkness
    let dark = max(frame.blindness, frame.darkness * 0.8);
    if dark > 0.0 {
        color *= mix(1.0, exp(-0.2 * dist), dark);
    }
    return vec4<f32>(rec2020_to_linear(color), 1.0);
}
