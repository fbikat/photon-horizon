// photon's c20_motion_blur: blur along the camera's motion since last frame

fn post(input: PostInput) -> vec4<f32> {
    if !motion_blur || frame.delta_time <= 0.0 {
        return input.color;
    }
    let depth = input.depth;
    let pos = view_position(input.uv, max(depth, 1e-7));
    // the hand is drawn close: leave it sharp
    if length(pos) < 1.0 {
        return input.color;
    }
    let p = select(pos, normalize(pos) * 1e4, depth <= 0.0);
    let prev_clip = frame.previous_view_projection * vec4<f32>(p + frame.camera_motion, 1.0);
    let prev_uv = vec2<f32>(prev_clip.x / prev_clip.w * 0.5 + 0.5, 0.5 - prev_clip.y / prev_clip.w * 0.5);
    var velocity = (input.uv - prev_uv) * clamp01(0.033 / frame.delta_time);
    velocity = clamp(velocity, vec2<f32>(-0.05), vec2<f32>(0.05));
    let samples = 8;
    let dither = interleaved_gradient_noise(input.pixel + f32(frame.frame_index % 64u) * 5.588238);
    var sum = vec3<f32>(0.0);
    for (var i = 0; i < samples; i++) {
        let t = (f32(i) + dither) / f32(samples) - 0.5;
        sum += textureSampleLevel(previous, linear_sampler, input.uv - velocity * t, 0.0).rgb;
    }
    return vec4<f32>(sum / f32(samples), 1.0);
}
