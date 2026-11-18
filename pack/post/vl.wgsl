// Half-resolution volumetric light visibility along camera rays (Overworld air & underwater), with cloud shadows

fn post(input: PostInput) -> vec4<f32> {
    if !vl || !in_overworld() || frame.has_shadow == 0u {
        return vec4<f32>(1.0, 0.0, 0.0, 1.0);
    }
    let d = depth_at(input.uv);
    let is_sky = d <= 0.0;
    if is_sky && frame.eye_in != 1u {
        return vec4<f32>(1.0, 1e4, 0.0, 1.0);
    }
    let pos = view_position(input.uv, max(d, 1e-7));
    let ray_dir = normalize(pos);
    let raw_dist = select(length(pos), 1e4, is_sky);
    let dist = select(raw_dist, min(raw_dist, 256.0), frame.eye_in == 1u);
    let max_dist = min(dist, frame.shadow_distance);
    let dither = interleaved_gradient_noise(input.pixel + f32(frame.frame_index % 64u) * 5.588238);
    let steps = 12;
    let step_length = max_dist / f32(steps);
    let use_cs = cloud_shadows && clouds_cumulus && light_dir().y > 0.0;
    var lit = 0.0;
    for (var i = 0; i < steps; i++) {
        let p = ray_dir * step_length * (f32(i) + dither);
        let s = shadow_position(p);
        var step_lit = 1.0;
        if all(s.xy >= vec2<f32>(0.0)) && all(s.xy <= vec2<f32>(1.0)) {
            step_lit = textureSampleCompareLevel(shadow_map, shadow_sampler, s.xy, s.z);
        }
        if use_cs && step_lit > 0.01 {
            let cs_uv = project_cloud_shadow_uv(p);
            if all(cs_uv >= vec2<f32>(0.0)) && all(cs_uv <= vec2<f32>(1.0)) {
                let cs = textureSampleLevel(cloud_shadow_tex, linear_sampler, cs_uv, 0.0).r;
                let fade = get_cloud_shadow_fade(p);
                step_lit *= cs * fade + (1.0 - fade);
            }
        }
        lit += step_lit;
    }
    let visible = lit / f32(steps);
    // Past the shadow map the light is unshadowed
    let shaft = mix(1.0, visible, max_dist / max(dist, eps));
    return vec4<f32>(shaft, min(raw_dist, 65000.0), 0.0, 1.0);
}
