// photon's d3_ao + c0_vl + c1_blend_layers + d4 fog:
// screen-space ambient occlusion, clouds, air fog with light shafts, border fog, nether/end fog, water/lava fog

fn compute_ssao(uv: vec2<f32>, texel: vec2<i32>, pos: vec3<f32>, dist: f32, dither: f32) -> f32 {
    if !ssao || ao_intensity <= 0.0 || dist > 96.0 {
        return 1.0;
    }
    let surf = surface_at(texel);
    if !surf.present {
        return 1.0;
    }
    let normal = surf.normal;
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

fn vl_visibility(ray_dir: vec3<f32>, dist: f32, dither: f32) -> f32 {
    if !vl || frame.has_shadow == 0u {
        return 1.0;
    }
    let max_dist = min(dist, frame.shadow_distance);
    let steps = 12;
    let step_length = max_dist / f32(steps);
    var lit = 0.0;
    for (var i = 0; i < steps; i++) {
        let p = ray_dir * step_length * (f32(i) + dither);
        let s = shadow_position(p);
        if any(s.xy < vec2<f32>(0.0)) || any(s.xy > vec2<f32>(1.0)) {
            lit += 1.0;
            continue;
        }
        lit += textureSampleCompareLevel(shadow_map, shadow_sampler, s.xy, s.z);
    }
    let visible = lit / f32(steps);
    // past the shadow map the light is unshadowed
    return mix(1.0, visible, max_dist / max(dist, eps));
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

    // screen-space ambient occlusion on solid terrain across all dimensions
    if !is_sky {
        let ao_val = compute_ssao(input.uv, texel, pos, dist, dither);
        let lum_c = dot(color, luminance_weights);
        let ao_weight = 1.0 - smoothstep(1.5, 6.0, lum_c);
        color *= mix(1.0, ao_val, ao_weight);
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
        // overworld: clouds
        if clouds_cumulus || clouds_cirrus {
            let c = textureSampleLevel(clouds_tex, linear_sampler, input.uv, 0.0);
            color = color * c.a + linear_to_rec2020(c.rgb);
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
                let shafts = vl_visibility(ray_dir, dist, dither);
                color = color * fog[1] + fog[0] * mix(1.0, shafts, clamp01(vl_intensity));
            }
        }

        if underwater {
            // photon's water_fog_simple with the underwater coefficients
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
                light *= 0.3 + 0.7 * vl_visibility(ray_dir, d, dither);
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
