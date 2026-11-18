// photon's final: contrast adaptive sharpening (amd fidelityfx cas) in linear HDR light

fn cas_tap(p: vec2<i32>) -> vec3<f32> {
    let size = vec2<i32>(textureDimensions(previous));
    return max(textureLoad(previous, clamp(p, vec2<i32>(0), size - 1), 0).rgb, vec3<f32>(0.0));
}

fn cas_perceptual(c: vec3<f32>) -> vec3<f32> {
    return sqrt(c / (1.0 + c));
}

fn post(input: PostInput) -> vec4<f32> {
    if cas_intensity <= 0.0 {
        return vec4<f32>(input.color.rgb, 1.0);
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

    let ap = cas_perceptual(a);
    let bp = cas_perceptual(b);
    let cp = cas_perceptual(c);
    let dp = cas_perceptual(d);
    let ep = cas_perceptual(e);
    let fp = cas_perceptual(f);
    let gp = cas_perceptual(g);
    let hp = cas_perceptual(h);
    let ip = cas_perceptual(i);

    var mn = min(min(min(dp, ep), min(fp, bp)), hp);
    let mn2 = min(mn, min(min(ap, cp), min(gp, ip)));
    mn += mn2;
    var mx = max(max(max(dp, ep), max(fp, bp)), hp);
    let mx2 = max(mx, max(max(ap, cp), max(gp, ip)));
    mx += mx2;

    let amp = sqrt(clamp01v(min(mn, 2.0 - mx) / max(mx, vec3<f32>(1e-5))));
    let peak = -1.0 / mix(8.0, 5.0, cas_intensity);
    let w = amp * peak;
    let rcp_w = 1.0 / (1.0 + 4.0 * w);

    let mn_lin = min(min(min(d, e), min(f, b)), h);
    let mx_lin = max(max(max(d, e), max(f, b)), h);
    let o = clamp((b * w + d * w + f * w + h * w + e) * rcp_w, mn_lin, mx_lin);
    return vec4<f32>(max(o, vec3<f32>(0.0)), 1.0);
}
