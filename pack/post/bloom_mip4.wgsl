// Bloom downsample level 4 (1/16 -> bloom_4) via compute pass

fn bloom_tap4(uv: vec2<f32>) -> vec3<f32> {
    return textureSampleLevel(bloom_3, linear_sampler, uv, 0.0).rgb;
}

fn compute(input: ComputeInput) {
    if !input.in_bounds {
        return;
    }
    let texel = vec2<i32>(input.cell.xy);
    if !bloom_on() && !auto_exposure {
        textureStore(bloom_4, texel, vec4<f32>(0.0));
        return;
    }
    let px = 1.0 / vec2<f32>(480.0, 270.0);
    let uv = (vec2<f32>(input.cell.xy) + 0.5) / vec2<f32>(input.size.xy);
    let a = bloom_tap4(uv + px * vec2<f32>(-2.0, -2.0));
    let b = bloom_tap4(uv + px * vec2<f32>(0.0, -2.0));
    let c = bloom_tap4(uv + px * vec2<f32>(2.0, -2.0));
    let d = bloom_tap4(uv + px * vec2<f32>(-1.0, -1.0));
    let e = bloom_tap4(uv + px * vec2<f32>(1.0, -1.0));
    let f = bloom_tap4(uv + px * vec2<f32>(-2.0, 0.0));
    let g = bloom_tap4(uv);
    let h = bloom_tap4(uv + px * vec2<f32>(2.0, 0.0));
    let i = bloom_tap4(uv + px * vec2<f32>(-1.0, 1.0));
    let j = bloom_tap4(uv + px * vec2<f32>(1.0, 1.0));
    let k = bloom_tap4(uv + px * vec2<f32>(-2.0, 2.0));
    let l = bloom_tap4(uv + px * vec2<f32>(0.0, 2.0));
    let m = bloom_tap4(uv + px * vec2<f32>(2.0, 2.0));
    var o = (d + e + i + j) * 0.125;
    o += (a + b + g + f) * 0.03125;
    o += (b + c + h + g) * 0.03125;
    o += (f + g + l + k) * 0.03125;
    o += (g + h + m + l) * 0.03125;
    textureStore(bloom_4, texel, vec4<f32>(o, 1.0));
}
