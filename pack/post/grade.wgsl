// photon's c19_color_grading (pre-tonemap): bloom, exposure, vignette, and linear input grading

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
    if bloom {
        let pad = 6.0 / frame.resolution;
        let uv = clamp(input.uv, pad, 1.0 - pad);
        // photon's gaussian passes over the smallest tile, folded into a wide 9-tap tent here
        let px = 6.0 / frame.resolution;
        var wide = textureSampleLevel(bloom_b, linear_sampler, uv, 0.0).rgb * 0.25;
        for (var i = 0; i < 8; i++) {
            let a = f32(i) * 0.7853982;
            let w = select(0.125, 0.0625, (i & 1) == 1);
            let r = select(1.0, 1.4142, (i & 1) == 1);
            wide += textureSampleLevel(bloom_b, linear_sampler, uv + vec2<f32>(cos(a), sin(a)) * r * px, 0.0).rgb * w;
        }
        let near = textureSampleLevel(bloom_a, linear_sampler, uv, 0.0).rgb;
        let b = mix(wide, near, 0.3);
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
