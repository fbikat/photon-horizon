// Half-resolution volumetric light visibility along camera rays (Overworld air & underwater)

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
    // Past the shadow map the light is unshadowed
    let shaft = mix(1.0, visible, max_dist / max(dist, eps));
    return vec4<f32>(shaft, min(raw_dist, 65000.0), 0.0, 1.0);
}
