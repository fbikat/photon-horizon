// Progressive tent-filter bloom upsample (bloom_5 -> bloom_4 -> bloom_3 -> bloom_up)

// bloom_5 is 121 texels wide: its last column holds the exposure, so its 120 bloom columns are sampled
// with uv squeezed into them and clamped off the spare one
fn tap5(uv: vec2<f32>) -> vec3<f32> {
    let lo = vec2<f32>(0.5 / 121.0, 0.5 / 68.0);
    let hi = vec2<f32>(119.5 / 121.0, 67.5 / 68.0);
    return textureSampleLevel(bloom_5, linear_sampler, clamp(uv, lo, hi), 0.0).rgb;
}

fn tent9_5(uv0: vec2<f32>, px: vec2<f32>) -> vec3<f32> {
    let uv = vec2<f32>(uv0.x * (120.0 / 121.0), uv0.y);
    var c = tap5(uv) * 0.25;
    c += (tap5(uv + vec2<f32>(px.x, 0.0)) + tap5(uv - vec2<f32>(px.x, 0.0))
        + tap5(uv + vec2<f32>(0.0, px.y)) + tap5(uv - vec2<f32>(0.0, px.y))) * 0.125;
    c += (tap5(uv + px) + tap5(uv - px)
        + tap5(uv + vec2<f32>(px.x, -px.y)) + tap5(uv + vec2<f32>(-px.x, px.y))) * 0.0625;
    return c;
}

fn tent9_4(uv: vec2<f32>, px: vec2<f32>) -> vec3<f32> {
    var c = textureSampleLevel(bloom_4, linear_sampler, uv, 0.0).rgb * 0.25;
    c += (textureSampleLevel(bloom_4, linear_sampler, uv + vec2<f32>(px.x, 0.0), 0.0).rgb
        + textureSampleLevel(bloom_4, linear_sampler, uv - vec2<f32>(px.x, 0.0), 0.0).rgb
        + textureSampleLevel(bloom_4, linear_sampler, uv + vec2<f32>(0.0, px.y), 0.0).rgb
        + textureSampleLevel(bloom_4, linear_sampler, uv - vec2<f32>(0.0, px.y), 0.0).rgb) * 0.125;
    c += (textureSampleLevel(bloom_4, linear_sampler, uv + px, 0.0).rgb
        + textureSampleLevel(bloom_4, linear_sampler, uv - px, 0.0).rgb
        + textureSampleLevel(bloom_4, linear_sampler, uv + vec2<f32>(px.x, -px.y), 0.0).rgb
        + textureSampleLevel(bloom_4, linear_sampler, uv + vec2<f32>(-px.x, px.y), 0.0).rgb) * 0.0625;
    return c;
}

fn compute(input: ComputeInput) {
    if !input.in_bounds {
        return;
    }
    let texel = vec2<i32>(input.cell.xy);
    if !bloom_on() {
        textureStore(bloom_up, texel, vec4<f32>(0.0));
        return;
    }
    let uv = (vec2<f32>(input.cell.xy) + 0.5) / vec2<f32>(input.size.xy);
    let b5 = tent9_5(uv, 1.5 / vec2<f32>(121.0, 68.0));
    let b4 = tent9_4(uv, 1.5 / vec2<f32>(240.0, 135.0));
    let b3 = textureSampleLevel(bloom_3, linear_sampler, uv, 0.0).rgb;
    let combined = mix(mix(b4, b5, 0.50), b3, 0.45);
    textureStore(bloom_up, texel, vec4<f32>(combined, 1.0));
}
