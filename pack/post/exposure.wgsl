// Auto-exposure metering from downsampled bloom/scene luminance with temporal adaptation

fn post(input: PostInput) -> vec4<f32> {
    if !auto_exposure {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    var sum_log = 0.0;
    var sum_w = 0.0;
    for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 5; x++) {
            let uv = vec2<f32>(0.15 + f32(x) * 0.175, 0.15 + f32(y) * 0.175);
            let d = uv - vec2<f32>(0.5);
            let w = exp(-4.0 * dot(d, d));
            var c: vec3<f32>;
            if bloom {
                c = textureSampleLevel(bloom_b, linear_sampler, uv, 0.0).rgb;
            } else if taa {
                c = textureSampleLevel(taa_hist, linear_sampler, uv, 0.0).rgb;
            } else {
                c = textureSampleLevel(previous, linear_sampler, uv, 0.0).rgb;
            }
            let lum = clamp(dot(linear_to_rec2020(c), luminance_weights), 0.002, 16.0);
            sum_log += w * log2(lum);
            sum_w += w;
        }
    }
    let avg_lum = exp2(sum_log / max(sum_w, eps));
    let target_ev = clamp(log2(avg_lum / 0.35), -1.1, 2.0);
    if frame.delta_time <= 0.0 || frame.reset_reasons != 0u {
        return vec4<f32>(target_ev, 0.0, 0.0, 1.0);
    }
    let prev_ev = textureLoad(exposure_tex_previous, vec2<i32>(0, 0), 0).r;
    let rate = select(1.6, 3.0, target_ev > prev_ev);
    let alpha = 1.0 - exp(-frame.delta_time * rate);
    let adapted = mix(prev_ev, target_ev, clamp01(alpha));
    return vec4<f32>(adapted, 0.0, 0.0, 1.0);
}
