// One anti-aliasing pass: the Anti-Aliasing choice, SMAA 1x's blending (its first two passes run before this one)
// or FXAA 3.11 (quality), in linear HDR light with perceptual luma for edge detection. (Photon's TAA is not
// ported: Horizon has no projection jitter, so there is nothing for a temporal pass to resolve.)

fn fxaa_luma(c: vec3<f32>) -> f32 {
    let n = max(c, vec3<f32>(0.0));
    let p = sqrt(n / (1.0 + n));
    return dot(p, vec3<f32>(0.299, 0.587, 0.114));
}
fn fxaa_tap(uv: vec2<f32>) -> vec3<f32> { return textureSampleLevel(previous, linear_sampler, uv, 0.0).rgb; }

fn fxaa_filter(input: PostInput) -> vec4<f32> {
    let px = 1.0 / frame.resolution;
    let uv = input.uv;
    let m = fxaa_luma(input.color.rgb);
    let n = fxaa_luma(fxaa_tap(uv + vec2<f32>(0.0, -px.y)));
    let s = fxaa_luma(fxaa_tap(uv + vec2<f32>(0.0, px.y)));
    let e = fxaa_luma(fxaa_tap(uv + vec2<f32>(px.x, 0.0)));
    let w = fxaa_luma(fxaa_tap(uv + vec2<f32>(-px.x, 0.0)));
    let range_max = max(max(n, s), max(max(e, w), m));
    let range_min = min(min(n, s), min(min(e, w), m));
    let range = range_max - range_min;
    if range < max(0.0312, range_max * 0.063) {
        return input.color;
    }
    let nw = fxaa_luma(fxaa_tap(uv + vec2<f32>(-px.x, -px.y)));
    let ne = fxaa_luma(fxaa_tap(uv + vec2<f32>(px.x, -px.y)));
    let sw = fxaa_luma(fxaa_tap(uv + vec2<f32>(-px.x, px.y)));
    let se = fxaa_luma(fxaa_tap(uv + vec2<f32>(px.x, px.y)));
    let edge_h = abs(nw + sw - 2.0 * w) + 2.0 * abs(n + s - 2.0 * m) + abs(ne + se - 2.0 * e);
    let edge_v = abs(nw + ne - 2.0 * n) + 2.0 * abs(w + e - 2.0 * m) + abs(sw + se - 2.0 * s);
    let horizontal = edge_h >= edge_v;
    let l1 = select(w, n, horizontal);
    let l2 = select(e, s, horizontal);
    let g1 = abs(l1 - m);
    let g2 = abs(l2 - m);
    var step_len = select(px.x, px.y, horizontal);
    var local_avg: f32;
    var gradient: f32;
    if g1 >= g2 {
        step_len = -step_len;
        local_avg = 0.5 * (l1 + m);
        gradient = 0.25 * g1;
    } else {
        local_avg = 0.5 * (l2 + m);
        gradient = 0.25 * g2;
    }
    var cur = uv;
    if horizontal {
        cur.y += step_len * 0.5;
    } else {
        cur.x += step_len * 0.5;
    }
    let off = select(vec2<f32>(0.0, px.y), vec2<f32>(px.x, 0.0), horizontal);
    var uv1 = cur - off;
    var uv2 = cur + off;
    var e1 = fxaa_luma(fxaa_tap(uv1)) - local_avg;
    var e2 = fxaa_luma(fxaa_tap(uv2)) - local_avg;
    var done1 = abs(e1) >= gradient;
    var done2 = abs(e2) >= gradient;
    var quality = array<f32, 12>(1.0, 1.0, 1.0, 1.0, 1.0, 1.5, 2.0, 2.0, 2.0, 2.0, 4.0, 8.0);
    for (var i = 0; i < 12; i++) {
        if done1 && done2 {
            break;
        }
        if !done1 {
            uv1 -= off * quality[i];
            e1 = fxaa_luma(fxaa_tap(uv1)) - local_avg;
            done1 = abs(e1) >= gradient;
        }
        if !done2 {
            uv2 += off * quality[i];
            e2 = fxaa_luma(fxaa_tap(uv2)) - local_avg;
            done2 = abs(e2) >= gradient;
        }
    }
    let d1 = select(uv.y - uv1.y, uv.x - uv1.x, horizontal);
    let d2 = select(uv2.y - uv.y, uv2.x - uv.x, horizontal);
    let closer1 = d1 < d2;
    let dmin = min(d1, d2);
    let span = d1 + d2;
    let m_smaller = (m - local_avg) < 0.0;
    let correct = (select(e2, e1, closer1) < 0.0) != m_smaller;
    var final_off = select(0.0, -dmin / span + 0.5, correct);
    let avg = (2.0 * (n + s + e + w) + nw + ne + sw + se) / 12.0;
    let sub1 = clamp01(abs(avg - m) / range);
    let sub2 = (-2.0 * sub1 + 3.0) * sub1 * sub1;
    final_off = max(final_off, sub2 * sub2 * 0.75);
    var fuv = uv;
    if horizontal {
        fuv.y += final_off * step_len;
    } else {
        fuv.x += final_off * step_len;
    }
    return vec4<f32>(fxaa_tap(fuv), 1.0);
}

// SMAA 1x, pass 3 of 3: neighbourhood blending with the weights of smaa_weights. A pixel takes from the
// neighbour across the edge the share of it the revectorized line gives that neighbour's side; of the two
// directions it blends along the stronger, as SMAA does.
fn smaa_blend(input: PostInput) -> vec4<f32> {
    let size = vec2<i32>(textureDimensions(previous));
    let p = vec2<i32>(input.pixel);
    let w_here = textureLoad(smaa_weights, p, 0);
    let w_top = w_here.r;
    let w_left = w_here.b;
    let w_bottom = textureLoad(smaa_weights, min(p + vec2<i32>(0, 1), size - 1), 0).g;
    let w_right = textureLoad(smaa_weights, min(p + vec2<i32>(1, 0), size - 1), 0).a;
    let vertical = max(w_top, w_bottom);
    let horizontal = max(w_left, w_right);
    if max(vertical, horizontal) < 1e-5 {
        return input.color;
    }
    let c = input.color.rgb;
    var o_a = vec2<i32>(0, -1);
    var o_b = vec2<i32>(0, 1);
    var w_a = w_top;
    var w_b = w_bottom;
    if horizontal > vertical {
        o_a = vec2<i32>(-1, 0);
        o_b = vec2<i32>(1, 0);
        w_a = w_left;
        w_b = w_right;
    }
    let ca = textureLoad(previous, clamp(p + o_a, vec2<i32>(0), size - 1), 0).rgb;
    let cb = textureLoad(previous, clamp(p + o_b, vec2<i32>(0), size - 1), 0).rgb;
    return vec4<f32>(c * (1.0 - w_a - w_b) + ca * w_a + cb * w_b, 1.0);
}

fn post(input: PostInput) -> vec4<f32> {
    if anti_aliasing == 1u {
        return fxaa_filter(input);
    }
    if anti_aliasing == 2u {
        return smaa_blend(input);
    }
    return input.color;
}
