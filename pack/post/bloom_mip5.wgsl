// Bloom downsample level 5 (1/32 -> bloom_5 columns 0..119) via compute pass, and the auto exposure,
// metered over every texel of bloom_4 by one workgroup and kept in bloom_5's spare texel EXPOSURE_TEXEL.
//
// The exposure used to meter 25 bilinear taps of the 1/4-res bloom: a torch flame or a lit window crossing
// one of them moved the whole picture's brightness. All 32400 texels of bloom_4, centre-weighted, don't.

var<workgroup> meter_log: array<f32, 64>;
var<workgroup> meter_w: array<f32, 64>;

fn bloom_tap5(uv: vec2<f32>) -> vec3<f32> {
    return textureSampleLevel(bloom_4, linear_sampler, uv, 0.0).rgb;
}

fn bloom_level5(cell: vec2<u32>) -> vec4<f32> {
    if !bloom_on() && !auto_exposure {
        return vec4<f32>(0.0);
    }
    let px = 1.0 / vec2<f32>(240.0, 135.0);
    let uv = (vec2<f32>(cell) + 0.5) / vec2<f32>(120.0, 68.0);
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
    return vec4<f32>(o, 1.0);
}

fn compute(input: ComputeInput) {
    let cell = input.cell.xy;
    if input.in_bounds && cell.x < 120u && cell.y < 68u {
        textureStore(bloom_5, vec2<i32>(cell), bloom_level5(cell));
    }

    // the workgroup of cells 120..127 x 0..7 meters the exposure; every invocation reaches the barrier
    let meters = input.in_bounds && cell.x >= 120u && cell.y < 8u;
    var sum_log = 0.0;
    var sum_w = 0.0;
    if meters && auto_exposure {
        let dims = vec2<u32>(textureDimensions(bloom_4));
        let count = dims.x * dims.y;
        for (var n = input.local; n < count; n += 64u) {
            let t = vec2<u32>(n % dims.x, n / dims.x);
            let uv = (vec2<f32>(t) + 0.5) / vec2<f32>(dims);
            let d = uv - vec2<f32>(0.5);
            let w = exp(-4.0 * dot(d, d));
            let c = textureLoad(bloom_4, vec2<i32>(t), 0).rgb;
            let lum = clamp(dot(linear_to_rec2020(c), luminance_weights), 0.002, 16.0);
            sum_log += w * log2(lum);
            sum_w += w;
        }
    }
    meter_log[input.local % 64u] = sum_log;
    meter_w[input.local % 64u] = sum_w;
    workgroupBarrier();
    if meters && input.local == 0u {
        var ev = 0.0;
        if auto_exposure {
            var total_log = 0.0;
            var total_w = 0.0;
            for (var n = 0u; n < 64u; n++) {
                total_log += meter_log[n];
                total_w += meter_w[n];
            }
            let avg_lum = exp2(total_log / max(total_w, eps));
            let target_ev = clamp(log2(avg_lum / 0.35), -1.1, 2.0);
            ev = target_ev;
            if frame.delta_time > 0.0 && frame.reset_reasons == 0u {
                let prev_ev = textureLoad(bloom_5_previous, EXPOSURE_TEXEL, 0).r;
                // photon's AUTO_EXPOSURE_RATE_DIM_TO_BRIGHT 2.0 and _BRIGHT_TO_DIM 1.0
                let rate = select(1.0, 2.0, target_ev > prev_ev);
                ev = mix(prev_ev, target_ev, clamp01(1.0 - exp(-frame.delta_time * rate)));
            }
        }
        textureStore(bloom_5, EXPOSURE_TEXEL, vec4<f32>(ev, 0.0, 0.0, 1.0));
    }
}
