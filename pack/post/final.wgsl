// photon's final: contrast adaptive sharpening (amd fidelityfx cas)

fn cas_tap(p: vec2<i32>) -> vec3<f32> {
    let size = vec2<i32>(textureDimensions(previous));
    return textureLoad(previous, clamp(p, vec2<i32>(0), size - 1), 0).rgb;
}

fn post(input: PostInput) -> vec4<f32> {
    if cas_intensity <= 0.0 {
        return input.color;
    }
    let src = vec2<f32>(textureDimensions(previous));
    let p = vec2<i32>(input.uv * src);
    let a = cas_tap(p + vec2<i32>(-1, -1));
    let b = cas_tap(p + vec2<i32>(0, -1));
    let c = cas_tap(p + vec2<i32>(1, -1));
    let d = cas_tap(p + vec2<i32>(-1, 0));
    let e = cas_tap(p);
    let f = cas_tap(p + vec2<i32>(1, 0));
    let g = cas_tap(p + vec2<i32>(-1, 1));
    let h = cas_tap(p + vec2<i32>(0, 1));
    let i = cas_tap(p + vec2<i32>(1, 1));
    var mn = min(min(min(d, e), min(f, b)), h);
    let mn2 = min(mn, min(min(a, c), min(g, i)));
    mn += mn2;
    var mx = max(max(max(d, e), max(f, b)), h);
    let mx2 = max(mx, max(max(a, c), max(g, i)));
    mx += mx2;
    let amp = sqrt(clamp01v(min(mn, 2.0 - mx) / max(mx, vec3<f32>(1e-5))));
    let peak = -1.0 / mix(8.0, 5.0, cas_intensity);
    let w = amp * peak;
    let rcp_w = 1.0 / (1.0 + 4.0 * w);
    let o = clamp01v((b * w + d * w + f * w + h * w + e) * rcp_w);
    return vec4<f32>(o, input.color.a);
}
