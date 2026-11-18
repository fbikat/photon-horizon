// photon's c19_color_grading (pre-tonemap): 5-level bloom blend, exposure, vignette, and linear input grading

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

fn post(input: PostInput) -> vec4<f32> {
    var color = input.color.rgb;
    if taa {
        color = textureLoad(taa_hist, vec2<i32>(input.pixel), 0).rgb;
    }
    if bloom {
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
    let auto_ev = select(0.0, textureLoad(exposure_tex, vec2<i32>(0, 0), 0).r, auto_exposure);
    color *= exp2(-(manual_exposure + auto_ev));
    if vignette_intensity > 0.0 {
        color *= vignette_amount(input.uv);
    }
    color = rec2020_to_linear(grade_input(linear_to_rec2020(color)));
    return vec4<f32>(color, 1.0);
}
