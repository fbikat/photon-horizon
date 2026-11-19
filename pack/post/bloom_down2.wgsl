// photon's c5-c10 bloom downsample, second level, from the first

fn bloom_tap(uv: vec2<f32>) -> vec3<f32> {
    return textureSampleLevel(bloom_a, linear_sampler, uv, 0.0).rgb;
}

fn post(input: PostInput) -> vec4<f32> {
    if !bloom_on() && !auto_exposure {
        return vec4<f32>(0.0);
    }
    let px = 2.0 / frame.resolution;
    let uv = input.uv;
    let a = bloom_tap(uv + px * vec2<f32>(-2.0, -2.0));
    let b = bloom_tap(uv + px * vec2<f32>(0.0, -2.0));
    let c = bloom_tap(uv + px * vec2<f32>(2.0, -2.0));
    let d = bloom_tap(uv + px * vec2<f32>(-1.0, -1.0));
    let e = bloom_tap(uv + px * vec2<f32>(1.0, -1.0));
    let f = bloom_tap(uv + px * vec2<f32>(-2.0, 0.0));
    let g = bloom_tap(uv);
    let h = bloom_tap(uv + px * vec2<f32>(2.0, 0.0));
    let i = bloom_tap(uv + px * vec2<f32>(-1.0, 1.0));
    let j = bloom_tap(uv + px * vec2<f32>(1.0, 1.0));
    let k = bloom_tap(uv + px * vec2<f32>(-2.0, 2.0));
    let l = bloom_tap(uv + px * vec2<f32>(0.0, 2.0));
    let m = bloom_tap(uv + px * vec2<f32>(2.0, 2.0));
    var o = (d + e + i + j) * 0.125;
    o += (a + b + g + f) * 0.03125;
    o += (b + c + h + g) * 0.03125;
    o += (f + g + l + k) * 0.03125;
    o += (g + h + m + l) * 0.03125;
    return vec4<f32>(o, 1.0);
}
