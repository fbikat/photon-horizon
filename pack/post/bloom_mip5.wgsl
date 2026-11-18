// Bloom downsample level 5 (1/32 -> bloom_5) via compute pass

fn bloom_tap5(uv: vec2<f32>) -> vec3<f32> {
    return textureSampleLevel(bloom_4, linear_sampler, uv, 0.0).rgb;
}

fn compute(input: ComputeInput) {
    if !input.in_bounds {
        return;
    }
    let texel = vec2<i32>(input.cell.xy);
    if !bloom {
        textureStore(bloom_5, texel, vec4<f32>(0.0));
        return;
    }
    let px = 1.0 / vec2<f32>(240.0, 135.0);
    let uv = (vec2<f32>(input.cell.xy) + 0.5) / vec2<f32>(input.size.xy);
    let a = bloom_tap5(uv + px * vec2<f32>(-2.0, -2.0));
    let b = bloom_tap5(uv + px * vec2<f32>(0.0, -2.0));
    let c = bloom_tap5(uv + px * vec2<f32>(2.0, -2.0));
    let d = bloom_tap5(uv + px * vec2<f32>(-1.0, -1.0));
    let e = bloom_tap5(uv + px * vec2<f32>(1.0, -1.0));
    let f = bloom_tap5(uv + px * vec2<f32>(-2.0, 0.0));
    let g = bloom_tap5(uv);
    let h = bloom_tap5(uv + px * vec2<f32>(2.0, 0.0));
    let i = bloom_tap5(uv + px * vec2<f32>(-1.0, 1.0));
    let j = bloom_tap5(uv + px * vec2<f32>(1.0, 1.0));
    let k = bloom_tap5(uv + px * vec2<f32>(-2.0, 2.0));
    let l = bloom_tap5(uv + px * vec2<f32>(0.0, 2.0));
    let m = bloom_tap5(uv + px * vec2<f32>(2.0, 2.0));
    var o = (d + e + i + j) * 0.125;
    o += (a + b + g + f) * 0.03125;
    o += (b + c + h + g) * 0.03125;
    o += (f + g + l + k) * 0.03125;
    o += (g + h + m + l) * 0.03125;
    textureStore(bloom_5, texel, vec4<f32>(o, 1.0));
}
