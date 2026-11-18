// Progressive tent-filter bloom upsample (bloom_5 -> bloom_4 -> bloom_3 -> bloom_up)

fn tent9_5(uv: vec2<f32>, px: vec2<f32>) -> vec3<f32> {
    var c = textureSampleLevel(bloom_5, linear_sampler, uv, 0.0).rgb * 0.25;
    c += (textureSampleLevel(bloom_5, linear_sampler, uv + vec2<f32>(px.x, 0.0), 0.0).rgb
        + textureSampleLevel(bloom_5, linear_sampler, uv - vec2<f32>(px.x, 0.0), 0.0).rgb
        + textureSampleLevel(bloom_5, linear_sampler, uv + vec2<f32>(0.0, px.y), 0.0).rgb
        + textureSampleLevel(bloom_5, linear_sampler, uv - vec2<f32>(0.0, px.y), 0.0).rgb) * 0.125;
    c += (textureSampleLevel(bloom_5, linear_sampler, uv + px, 0.0).rgb
        + textureSampleLevel(bloom_5, linear_sampler, uv - px, 0.0).rgb
        + textureSampleLevel(bloom_5, linear_sampler, uv + vec2<f32>(px.x, -px.y), 0.0).rgb
        + textureSampleLevel(bloom_5, linear_sampler, uv + vec2<f32>(-px.x, px.y), 0.0).rgb) * 0.0625;
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
    if !bloom {
        textureStore(bloom_up, texel, vec4<f32>(0.0));
        return;
    }
    let uv = (vec2<f32>(input.cell.xy) + 0.5) / vec2<f32>(input.size.xy);
    let b5 = tent9_5(uv, 1.5 / vec2<f32>(120.0, 68.0));
    let b4 = tent9_4(uv, 1.5 / vec2<f32>(240.0, 135.0));
    let b3 = textureSampleLevel(bloom_3, linear_sampler, uv, 0.0).rgb;
    let combined = mix(mix(b4, b5, 0.50), b3, 0.45);
    textureStore(bloom_up, texel, vec4<f32>(combined, 1.0));
}
