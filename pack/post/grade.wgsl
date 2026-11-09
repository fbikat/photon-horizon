// photon's c19_color_grading: bloom, exposure, vignette, grading, tone mapping, display encoding

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
    let a = 0.5 * pow(2.0 * mix(x, 1.0 - x, s), vec3<f32>(k));
    return mix(a, 1.0 - a, s);
}

fn grade_input(rgb0: vec3<f32>) -> vec3<f32> {
    var rgb = rgb0 * 0.83 * grade_brightness;
    let log_mid = log2(0.18);
    rgb = log2(rgb + eps);
    rgb = grade_contrast * (rgb - log_mid) + log_mid;
    rgb = max(exp2(rgb) - eps, vec3<f32>(0.0));
    let lum = dot(rgb, luminance_weights);
    return max(mix(vec3<f32>(lum), rgb, 0.98 * grade_saturation), vec3<f32>(0.0));
}

fn grade_output(rgb0: vec3<f32>) -> vec3<f32> {
    var rgb = sqrt(rgb0);
    var hsl = rgb_to_hsl(rgb);
    let orange = isolate_hue(hsl, 30.0, 20.0);
    hsl.y *= 1.0 + grade_orange_sat_boost * orange;
    let teal = isolate_hue(hsl, 210.0, 20.0);
    hsl.y *= 1.0 + grade_teal_sat_boost * teal;
    let green = isolate_hue(hsl, 90.0, 44.0);
    hsl.y *= 1.0 + grade_green_sat_boost * green;
    rgb = hsl_to_rgb(hsl);
    rgb = gain(rgb, 1.05);
    return rgb * rgb;
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
    color *= exp2(-manual_exposure);
    if vignette {
        color *= vignette_amount(input.uv);
    }
    color = grade_input(color);
    color = apply_tonemap(color);
    color = clamp01v(color * rec2020_to_rec709);
    color = grade_output(color);
    let dither = interleaved_gradient_noise(input.pixel + f32(frame.frame_index % 64u) * 5.588238);
    let display = clamp01v(srgb_eotf(color) + (dither - 0.5) / 255.0);
    return vec4<f32>(display, input.color.a);
}
