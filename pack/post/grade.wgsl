// photon's c2_dof + c19_color_grading + c20_motion_blur in one pass (pre-tonemap): depth of field and
// camera motion blur gather the composite's picture, then the 5-level bloom blend, exposure, vignette and
// linear input grading. One pass instead of three: off, DoF and motion blur cost nothing here, where their
// own passes each copied the whole picture.

fn grade_input(rgb0: vec3<f32>) -> vec3<f32> {
    var rgb = rgb0 * 0.83 * grade_brightness;
    let log_mid = log2(0.18);
    rgb = log2(rgb + eps);
    rgb = grade_contrast * (rgb - log_mid) + log_mid;
    rgb = max(exp2(rgb) - eps, vec3<f32>(0.0));
    let lum = dot(rgb, luminance_weights);
    return max(mix(vec3<f32>(lum), rgb, 0.98 * grade_saturation), vec3<f32>(0.0));
}

fn vignette_amount(uv: vec2<f32>) -> f32 {
    let darkness_pulse = 1.0 - dampen(abs(cos(2.0 * frame.time)));
    let v = 16.0 * (uv.x * uv.y - uv.x) * (uv.x * uv.y - uv.y);
    return pow(max(v, 0.0), 0.08 * vignette_intensity + 0.1 * biome_cave() + 0.3 * frame.blindness
        + 0.2 * darkness_pulse * frame.darkness);
}

fn scene_tap(uv: vec2<f32>) -> vec3<f32> {
    return textureSampleLevel(previous, linear_sampler, uv, 0.0).rgb;
}

// the screen-space velocity of the camera at this pixel, photon's c20_motion_blur
fn motion_velocity(input: PostInput) -> vec2<f32> {
    let depth = input.depth;
    let pos = view_position(input.uv, max(depth, 1e-7));
    // the hand is drawn close: leave it sharp
    if length(pos) < 1.0 {
        return vec2<f32>(0.0);
    }
    let p = select(pos, normalize(pos) * 1e4, depth <= 0.0);
    let prev_clip = frame.previous_view_projection * vec4<f32>(p + frame.camera_motion, 1.0);
    let prev_uv = vec2<f32>(prev_clip.x / prev_clip.w * 0.5 + 0.5, 0.5 - prev_clip.y / prev_clip.w * 0.5);
    let velocity = (input.uv - prev_uv) * clamp01(0.033 / frame.delta_time);
    return clamp(velocity, vec2<f32>(-0.05), vec2<f32>(0.05));
}

fn dof_coc(dist: f32, focus_dist: f32) -> f32 {
    return min(abs(1.0 / max(dist, 0.35) - 1.0 / max(focus_dist, 0.35)) * 0.03 * dof_intensity, 0.035);
}

// photon's c2_dof: Vogel-disc bokeh around the centre of the screen's distance, with motion blur's
// streak folded into the same taps when both are on
fn dof_and_motion_blur(input: PostInput, velocity: vec2<f32>, use_dof: bool) -> vec3<f32> {
    let pad = 2.0 / frame.resolution;
    let dither = interleaved_gradient_noise(input.pixel);
    var coc = vec2<f32>(0.0);
    var coc_scale = 0.0;
    var dist = 0.0;
    var focus_dist = 0.0;
    if use_dof {
        let pos = view_position(input.uv, max(input.depth, 1e-7));
        dist = select(length(pos), 512.0, input.depth <= 0.0);
        let focus_d = depth_at(vec2<f32>(0.5, 0.5));
        focus_dist = select(length(view_position(vec2<f32>(0.5, 0.5), focus_d)), 256.0, focus_d <= 0.0);
        let aspect = frame.resolution.x / max(frame.resolution.y, 1.0);
        coc_scale = dof_coc(dist, focus_dist);
        if coc_scale >= 0.25 / max(frame.resolution.y, 1.0) {
            coc = coc_scale * vec2<f32>(1.0 / aspect, 1.0);
        }
    }
    let blur_dof = any(coc > vec2<f32>(0.0));
    if !blur_dof && all(velocity == vec2<f32>(0.0)) {
        return input.color.rgb;
    }
    let theta = r1(frame.frame_index, dither) * tau;
    let samples = 12;
    var acc = vec3<f32>(0.0);
    var w_sum = 0.0;
    if blur_dof {
        acc = input.color.rgb * 0.25;
        w_sum = 0.25;
    }
    for (var i = 0; i < samples; i++) {
        let t = (f32(i) + fract(dither + f32(i) * golden_ratio)) / f32(samples) - 0.5;
        let offset = vogel_disc_sample(i, samples, theta) * coc - velocity * t;
        let s_uv = clamp(input.uv + offset, pad, vec2<f32>(1.0) - pad);
        var w = 1.0;
        if blur_dof {
            // softly reduce background bleed across near in-focus edges
            let s_d = depth_at(s_uv);
            let s_dist = select(length(view_position(s_uv, s_d)), 512.0, s_d <= 0.0);
            w = select(1.0, smoothstep(0.0, coc_scale, dof_coc(s_dist, focus_dist) + 0.001), s_dist < dist - 0.5);
        }
        acc += scene_tap(s_uv) * w;
        w_sum += w;
    }
    return acc / max(w_sum, eps);
}

fn post(input: PostInput) -> vec4<f32> {
    var color = input.color.rgb;
    let use_dof = dof && dof_intensity > 0.0;
    let use_mb = motion_blur && frame.delta_time > 0.0;
    if use_dof || use_mb {
        let velocity = select(vec2<f32>(0.0), motion_velocity(input), use_mb);
        color = dof_and_motion_blur(input, velocity, use_dof);
    }
    if bloom_on() {
        let pad = 6.0 / frame.resolution;
        let uv = clamp(input.uv, pad, 1.0 - pad);
        let px_up = 1.5 / vec2<f32>(480.0, 270.0);
        var wide = textureSampleLevel(bloom_up, linear_sampler, uv, 0.0).rgb * 0.4;
        wide += (textureSampleLevel(bloom_up, linear_sampler, uv + vec2<f32>(px_up.x, 0.0), 0.0).rgb
            + textureSampleLevel(bloom_up, linear_sampler, uv - vec2<f32>(px_up.x, 0.0), 0.0).rgb
            + textureSampleLevel(bloom_up, linear_sampler, uv + vec2<f32>(0.0, px_up.y), 0.0).rgb
            + textureSampleLevel(bloom_up, linear_sampler, uv - vec2<f32>(0.0, px_up.y), 0.0).rgb) * 0.15;
        let b2 = textureSampleLevel(bloom_b, linear_sampler, uv, 0.0).rgb;
        let b1 = textureSampleLevel(bloom_a, linear_sampler, uv, 0.0).rgb;
        let b = wide * 0.45 + b2 * 0.35 + b1 * 0.20;
        color = mix(color, b, 0.12 * bloom_intensity);
    }
    let auto_ev = select(0.0, textureLoad(bloom_5, EXPOSURE_TEXEL, 0).r, auto_exposure);
    color *= exp2(-(manual_exposure + auto_ev));
    if vignette_intensity > 0.0 {
        color *= vignette_amount(input.uv);
    }
    color = rec2020_to_linear(grade_input(linear_to_rec2020(color)));
    return vec4<f32>(color, 1.0);
}
