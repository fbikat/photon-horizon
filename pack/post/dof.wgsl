// Photon's c2_dof: Vogel-disc Depth of Field around center-screen focus distance (OFF by default)

fn post(input: PostInput) -> vec4<f32> {
    if !dof || dof_intensity <= 0.0 {
        return input.color;
    }
    let depth = input.depth;
    let is_sky = depth <= 0.0;
    let pos = view_position(input.uv, max(depth, 1e-7));
    let dist = select(length(pos), 512.0, is_sky);

    let focus_d = depth_at(vec2<f32>(0.5, 0.5));
    let focus_dist = select(length(view_position(vec2<f32>(0.5, 0.5), focus_d)), 256.0, focus_d <= 0.0);

    let aspect = frame.resolution.x / max(frame.resolution.y, 1.0);
    let coc_scale = min(abs(1.0 / max(dist, 0.35) - 1.0 / max(focus_dist, 0.35)) * 0.03 * dof_intensity, 0.035);
    if coc_scale < 0.25 / max(frame.resolution.y, 1.0) {
        return input.color;
    }
    let coc = coc_scale * vec2<f32>(1.0 / aspect, 1.0);

    let ign = interleaved_gradient_noise(input.pixel);
    let theta = r1(frame.frame_index, ign) * tau;
    let pad = 2.0 / frame.resolution;

    var acc = input.color.rgb * 0.25;
    var w_sum = 0.25;
    let samples = 12;
    for (var i = 0; i < samples; i++) {
        let offset = vogel_disc_sample(i, samples, theta);
        let s_uv = clamp(input.uv + offset * coc, pad, vec2<f32>(1.0) - pad);
        let s_col = textureSampleLevel(previous, linear_sampler, s_uv, 0.0).rgb;
        // Softly reduce background bleed across near in-focus edges
        let s_d = depth_at(s_uv);
        let s_dist = select(length(view_position(s_uv, s_d)), 512.0, s_d <= 0.0);
        let s_coc = min(abs(1.0 / max(s_dist, 0.35) - 1.0 / max(focus_dist, 0.35)) * 0.03 * dof_intensity, 0.035);
        let w = select(1.0, smoothstep(0.0, coc_scale, s_coc + 0.001), s_dist < dist - 0.5);
        acc += s_col * w;
        w_sum += w;
    }
    return vec4<f32>(acc / w_sum, 1.0);
}
