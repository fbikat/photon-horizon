// photon's d3_ao + ssrt + land SSR + c0_vl + c1_blend_layers + rainbows + d4 fog

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
    if !rainbows || !in_overworld() || is_night() || frame.wetness <= 0.0
        || frame.downfall <= 0.0 || frame.temperature < 0.15 || frame.precipitation == 2u {
        return fragment_color;
    }
    let rain_amt = smoothstep(0.0, 0.3, frame.wetness) * (1.0 - 0.6 * frame.rain)
        * smoothstep(0.0, 0.10, frame.sun_direction.y) * smoothstep(0.75, 0.45, frame.sun_direction.y);
    if rain_amt < eps {
        return fragment_color;
    }
    let angle = fast_acos(clamp01(-dot(ray_dir, light_dir())));
    let first = draw_single_rainbow(angle, 44.0 * degree, 40.0 * degree);
    let second = draw_single_rainbow(angle, 45.5 * degree, 48.5 * degree);
    let trans_approx = mix(vec3<f32>(1.0, 0.75, 0.5), vec3<f32>(1.0), dampen(max0(ray_dir.y)));
    let rainbow_col = get_light_color() * 0.1 * (3.0 * first + 0.5 * second) * (trans_approx * trans_approx);
    let fade = rain_amt * smoothstep(250.0, 500.0, view_distance) * smoothstep(0.0, 0.05, ray_dir.y);
    return fragment_color + rainbow_col * fade;
}

fn compute_ssao(uv: vec2<f32>, normal: vec3<f32>, pos: vec3<f32>, dist: f32, dither: f32) -> f32 {
    if !ssao || ao_intensity <= 0.0 || dist > 96.0 {
        return 1.0;
    }
    let radius = clamp(dist * 0.10, 0.45, 1.8);
    let proj_scale = vec2<f32>(abs(frame.projection[0][0]), abs(frame.projection[1][1])) * 0.5;
    let uv_radius = clamp(proj_scale * radius / max(dist, 0.5), 2.0 / frame.resolution, vec2<f32>(0.08));

    var occ_sum = 0.0;
    let dirs = 6;
    let steps = 2;
    let base_angle = dither * (tau / f32(dirs));
    for (var i = 0; i < dirs; i++) {
        let ang = base_angle + f32(i) * (tau / f32(dirs));
        let dir2 = vec2<f32>(cos(ang), sin(ang));
        var max_occ = 0.0;
        for (var s = 0; s < steps; s++) {
            let jitter = fract(dither + f32(i * steps + s) * golden_ratio);
            let frac = (f32(s) + 0.35 + 0.5 * jitter) / f32(steps);
            let s_uv = uv + dir2 * uv_radius * frac;
            if all(s_uv >= vec2<f32>(0.0)) && all(s_uv <= vec2<f32>(1.0)) {
                let s_depth = depth_at(s_uv);
                if s_depth > 0.0 {
                    let s_pos = view_position(s_uv, s_depth);
                    let delta = s_pos - pos;
                    let len = sqrt(max(dot(delta, delta), 1e-6));
                    let n_dot_d = dot(normal, delta / len);
                    let falloff = 1.0 - smoothstep(radius * 0.35, radius * 1.35, len);
                    let occ = max0(n_dot_d - 0.06) * falloff;
                    max_occ = max(max_occ, occ);
                }
            }
        }
        occ_sum += max_occ;
    }
    let raw_ao = clamp01(1.0 - (occ_sum / f32(dirs)) * 1.45 * ao_intensity);
    let dist_fade = 1.0 - smoothstep(48.0, 96.0, dist);
    return mix(1.0, raw_ao, dist_fade);
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

fn sample_vl(uv: vec2<f32>, dist: f32) -> f32 {
    if !vl || frame.has_shadow == 0u {
        return 1.0;
    }
    let dim = vec2<i32>(textureDimensions(vl_tex));
    let fcoord = clamp(uv * vec2<f32>(dim) - 0.5, vec2<f32>(0.0), vec2<f32>(dim - 1));
    let p0 = vec2<i32>(fcoord);
    let f = fract(fcoord);
    let ref_d = min(dist, 65000.0);
    var sum_v = 0.0;
    var sum_w = 0.0;
    for (var dy = 0; dy < 2; dy++) {
        for (var dx = 0; dx < 2; dx++) {
            let tx = clamp(p0 + vec2<i32>(dx, dy), vec2<i32>(0), dim - 1);
            let s = textureLoad(vl_tex, tx, 0);
            let wx = select(1.0 - f.x, f.x, dx == 1);
            let wy = select(1.0 - f.y, f.y, dy == 1);
            let depth_w = exp(-abs(s.g - ref_d) / max(ref_d * 0.15, 2.0));
            let w = wx * wy * depth_w;
            sum_v += s.r * w;
            sum_w += w;
        }
    }
    if sum_w > 1e-4 {
        return sum_v / sum_w;
    }
    return textureSampleLevel(vl_tex, linear_sampler, uv, 0.0).r;
}

fn post(input: PostInput) -> vec4<f32> {
    let texel = vec2<i32>(input.pixel);
    var color = linear_to_rec2020(textureLoad(scene_color, texel, 0).rgb);
    let depth = input.depth;
    let is_sky = depth <= 0.0;
    let pos = view_position(input.uv, max(depth, 1e-7));
    let ray_dir = normalize(pos);
    let dist = select(length(pos), 1e4, is_sky);
    let dither = interleaved_gradient_noise(input.pixel + f32(frame.frame_index % 64u) * 5.588238);

    // SSAO + SSRT distant shadows + Land SSR on opaque geometry
    if !is_sky {
        let surf = surface_at(texel);
        if surf.present {
            let ao_val = compute_ssao(input.uv, surf.normal, pos, dist, dither);
            let lum_c = dot(color, luminance_weights);
            let ao_weight = 1.0 - smoothstep(1.5, 6.0, lum_c);
            color *= mix(1.0, ao_val, ao_weight);

            // Unpack sun ratio and puddle/LabPBR SSR weight from surf.data
            let sun_frac = clamp01(floor(surf.data + 1e-4) / 255.0);
            let ssr_w = clamp01(fract(surf.data) / 0.98);

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
            let vanilla_f = smoothstep(frame.fog_start, frame.fog_end, dist);
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
                f = max(f, smoothstep(0.75 * frame.far, frame.far, length(pos.xz)));
            }
            color = mix(color, end_fog_col, f);
        }
    } else if !in_overworld() {
        let fog_col = linear_to_rec2020(frame.fog_color);
        let f = smoothstep(frame.fog_start, frame.fog_end, dist);
        if !is_sky {
            color = mix(color, fog_col * 0.5, f);
        }
    } else {
        var cloud_t = 1.0;
        if clouds_cumulus || clouds_cirrus || aurora != 0u || crepuscular_rays {
            let c = textureSampleLevel(clouds_tex, linear_sampler, input.uv, 0.0);
            color = color * c.a + linear_to_rec2020(c.rgb);
            cloud_t = c.a;
        }

        let underwater = frame.eye_in == 1u;
        let skylight = eye_skylight();

        if !underwater && frame.eye_in == 0u {
            // border fog: terrain fades into the sky at the edge of the render distance
            if border_fog && !is_sky {
                let border = smoothstep(0.75 * frame.far, frame.far, length(pos.xz));
                if border > 0.0 {
                    let sky = atmosphere_scattering_both(normalize(vec3<f32>(ray_dir.x, max(ray_dir.y, 0.0), ray_dir.z)),
                        sun_color(), moon_color());
                    color = mix(color, sky * (1.0 - biome_cave()), border);
                }
            }
            // air fog with the light's share shadowed along the ray
            if !is_sky {
                let fog = air_fog_analytic(dist, ray_dir, skylight);
                let shafts = sample_vl(input.uv, dist);
                color = color * fog[1] + fog[0] * mix(1.0, shafts, clamp01(vl_intensity));
            }
            // Photon's rainbow arc opposite the sun
            let eff_dist = select(dist, mix(1e6, 2500.0, linear_step(1.0, 0.95, cloud_t)), is_sky);
            color = draw_rainbows(color, ray_dir, eff_dist);
        }

        if underwater {
            let absorption = vec3<f32>(0.20, 0.08, 0.04) * water_absorption * rec709_to_rec2020;
            let scattering = vec3<f32>(0.03);
            let ext = absorption + scattering;
            let d = min(dist, 256.0);
            let t = exp(-ext * d);
            let lov = dot(light_dir(), ray_dir);
            let sky_l = frame.eye_light_smooth.y;
            var light = get_light_color() * smoothstep(0.0, 0.25, sky_l) * (0.7 * henyey_greenstein_phase(lov, 0.4) + 0.3 * isotropic_phase);
            light += get_sky_color() * sky_l * isotropic_phase;
            if vl && frame.has_shadow != 0u {
                light *= 0.3 + 0.7 * sample_vl(input.uv, dist);
            }
            let ms = 0.84 * scattering / ext;
            let s = light * (1.0 - t) * scattering / ext * (1.0 + ms / (1.0 - ms));
            color = color * t + s;
        }
    }

    if frame.eye_in == 2u || frame.eye_in == 3u {
        let fog_col = select(vec3<f32>(0.9, 0.95, 1.0), vec3<f32>(4.0, 0.6, 0.1), frame.eye_in == 2u);
        let t = exp(-dist * select(0.5, 1.5, frame.eye_in == 2u));
        color = mix(fog_col, color, t);
    }

    // blindness and darkness
    let dark = max(frame.blindness, frame.darkness * 0.8);
    if dark > 0.0 {
        color *= mix(1.0, exp(-0.2 * dist), dark);
    }
    return vec4<f32>(rec2020_to_linear(color), 1.0);
}
