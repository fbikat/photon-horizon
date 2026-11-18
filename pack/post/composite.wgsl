// photon's c0_vl + c1_blend_layers + d4 fog: decode the world to linear hdr, lay the clouds over
// it, then air fog with shadowed light shafts, border fog and water/lava fog

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

    if !in_overworld() {
        // nether and end: vanilla's fog in linear light
        let fog_col = linear_to_rec2020(frame.fog_color);
        let f = smoothstep(frame.fog_start, frame.fog_end, dist);
        if !is_sky {
            color = mix(color, fog_col * 0.5, f);
        }
        return vec4<f32>(rec2020_to_linear(color), 1.0);
    }

    // clouds
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
        // the sky already holds its own atmosphere
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
    } else if frame.eye_in == 2u || frame.eye_in == 3u {
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
