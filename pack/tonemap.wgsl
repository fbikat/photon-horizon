// photon's tone mapping and output colour grading for SDR and HDR displays

fn rgb_to_hsl(c: vec3<f32>) -> vec3<f32> {
    let k = vec4<f32>(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    let p = mix(vec4<f32>(c.b, c.g, k.w, k.z), vec4<f32>(c.g, c.b, k.x, k.y), step(c.b, c.g));
    let q = mix(vec4<f32>(p.x, p.y, p.w, c.r), vec4<f32>(c.r, p.y, p.z, p.x), step(p.x, c.r));
    let d = q.x - min(q.w, q.y);
    let e = 1e-6;
    return vec3<f32>(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

fn hsl_to_rgb(c0: vec3<f32>) -> vec3<f32> {
    let k = vec4<f32>(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    let c = vec3<f32>(c0.x, clamp01(c0.y), clamp01(c0.z));
    let p = abs(fract(c.xxx + k.xyz) * 6.0 - k.www);
    return c.z * mix(k.xxx, clamp01v(p - k.xxx), c.y);
}

fn isolate_hue(hsl: vec3<f32>, center: f32, width: f32) -> f32 {
    if hsl.y < 1e-2 || hsl.z < 1e-2 {
        return 0.0;
    }
    return pulse_periodic(hsl.x * 360.0, center, width, 360.0);
}

fn gain(x: vec3<f32>, k: f32) -> vec3<f32> {
    let s = step(vec3<f32>(0.5), x);
    let a = 0.5 * pow(max(2.0 * mix(x, 1.0 - x, s), vec3<f32>(0.0)), vec3<f32>(k));
    return mix(a, 1.0 - a, s);
}

fn grade_output(rgb0: vec3<f32>) -> vec3<f32> {
    var rgb = sqrt(max(rgb0, vec3<f32>(0.0)));
    var hsl = rgb_to_hsl(rgb);
    let orange = isolate_hue(hsl, 30.0, 20.0);
    hsl.y *= 1.0 + grade_vibrance * 0.6 * orange;
    let teal = isolate_hue(hsl, 210.0, 20.0);
    hsl.y *= 1.0 + (0.1 + grade_vibrance) * teal;
    let green = isolate_hue(hsl, 90.0, 44.0);
    hsl.y *= 1.0 + grade_vibrance * 0.6 * green;
    rgb = hsl_to_rgb(hsl);
    rgb = gain(rgb, 1.05);
    return rgb * rgb;
}

fn tonemap(input: TonemapInput) -> vec3<f32> {
    let c = linear_to_rec2020(input.color);
    var mapped = apply_tonemap(c);
    if frame.hdr == 1u && frame.headroom > 1.0 {
        let peak_in = max_of(c);
        let peak_sdr = max_of(mapped);
        let excess = max(peak_in - 0.8, 0.0);
        if excess > 0.0 && peak_sdr > 1e-5 {
            let target_peak = peak_sdr + (frame.headroom - peak_sdr) * (excess / (excess + 4.0));
            mapped *= target_peak / peak_sdr;
        }
    }
    let linear_709 = rec2020_to_linear(mapped);
    let peak = max(max_of(linear_709), 1.0);
    let graded = grade_output(linear_709 / peak) * peak;
    return clamp(graded, vec3<f32>(0.0), vec3<f32>(frame.headroom));
}
