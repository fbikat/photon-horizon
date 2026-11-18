// Photon's c4_taa: camera-reprojected TAA with YCoCg 3x3 variance clipping & Catmull-Rom history (OFF by default)

fn rgb_to_ycocg(rgb: vec3<f32>) -> vec3<f32> {
    let y = 0.25 * rgb.r + 0.5 * rgb.g + 0.25 * rgb.b;
    let co = 0.5 * rgb.r - 0.5 * rgb.b;
    let cg = -0.25 * rgb.r + 0.5 * rgb.g - 0.25 * rgb.b;
    return vec3<f32>(y, co, cg);
}

fn ycocg_to_rgb(ycocg: vec3<f32>) -> vec3<f32> {
    let tmp = ycocg.x - ycocg.z;
    return vec3<f32>(tmp + ycocg.y, ycocg.x + ycocg.z, tmp - ycocg.y);
}

fn reinhard_taa(rgb: vec3<f32>) -> vec3<f32> {
    return rgb / (rgb + vec3<f32>(1.0));
}

fn reinhard_taa_inv(rgb: vec3<f32>) -> vec3<f32> {
    return rgb / max(vec3<f32>(1.0) - rgb, vec3<f32>(1e-4));
}

fn clip_aabb_taa(hist: vec3<f32>, min_c: vec3<f32>, max_c: vec3<f32>) -> vec3<f32> {
    let p_clip = 0.5 * (max_c + min_c);
    let e_clip = max(0.5 * (max_c - min_c), vec3<f32>(1e-3));
    let v_clip = hist - p_clip;
    let a_unit = abs(v_clip / e_clip);
    let ma_unit = max_of(a_unit);
    return select(hist, p_clip + v_clip / ma_unit, ma_unit > 1.0);
}

// Fast 5-tap Catmull-Rom filter (Jimenez / Photon bicubic.glsl)
fn sample_history_catmull_rom(uv: vec2<f32>, res: vec2<f32>) -> vec4<f32> {
    let sample_pos = uv * res;
    let tc1 = floor(sample_pos - 0.5) + 0.5;
    let f = sample_pos - tc1;
    let f2 = f * f;
    let f3 = f2 * f;

    let w0 = f2 - 0.5 * (f3 + f);
    let w1 = 1.5 * f3 - 2.5 * f2 + 1.0;
    let w3 = 0.5 * (f3 - f2);
    let w2 = 1.0 - w0 - w1 - w3;

    let w12 = w1 + w2;
    let tc0 = (tc1 - 1.0) / res;
    let tc3 = (tc1 + 2.0) / res;
    let tc12 = (tc1 + w2 / max(w12, vec2<f32>(1e-5))) / res;

    var res_c = textureSampleLevel(taa_hist_previous, linear_sampler, vec2<f32>(tc12.x, tc0.y), 0.0) * (w12.x * w0.y);
    res_c += textureSampleLevel(taa_hist_previous, linear_sampler, vec2<f32>(tc0.x, tc12.y), 0.0) * (w0.x * w12.y);
    res_c += textureSampleLevel(taa_hist_previous, linear_sampler, vec2<f32>(tc12.x, tc12.y), 0.0) * (w12.x * w12.y);
    res_c += textureSampleLevel(taa_hist_previous, linear_sampler, vec2<f32>(tc3.x, tc12.y), 0.0) * (w3.x * w12.y);
    res_c += textureSampleLevel(taa_hist_previous, linear_sampler, vec2<f32>(tc12.x, tc3.y), 0.0) * (w12.x * w3.y);
    return max(res_c, vec4<f32>(0.0));
}

fn compute(input: ComputeInput) {
    if !input.in_bounds || !taa {
        return;
    }
    let texel = vec2<i32>(input.cell.xy);
    let size_i = vec2<i32>(input.size.xy);
    let res = vec2<f32>(input.size.xy);
    let uv = (vec2<f32>(input.cell.xy) + 0.5) / res;

    let cur_raw = max(textureLoad(previous, texel, 0).rgb, vec3<f32>(0.0));

    // Reversed depth: largest depth in 5x5 cross is closest surface
    var best_uv = uv;
    var best_d = depth_at(uv);
    let px_2 = 2.0 / res;
    let s0_uv = clamp(uv + vec2<f32>(-px_2.x, -px_2.y), vec2<f32>(0.0), vec2<f32>(1.0));
    let s0_d = depth_at(s0_uv);
    if s0_d > best_d { best_d = s0_d; best_uv = s0_uv; }
    let s1_uv = clamp(uv + vec2<f32>(px_2.x, -px_2.y), vec2<f32>(0.0), vec2<f32>(1.0));
    let s1_d = depth_at(s1_uv);
    if s1_d > best_d { best_d = s1_d; best_uv = s1_uv; }
    let s2_uv = clamp(uv + vec2<f32>(-px_2.x, px_2.y), vec2<f32>(0.0), vec2<f32>(1.0));
    let s2_d = depth_at(s2_uv);
    if s2_d > best_d { best_d = s2_d; best_uv = s2_uv; }
    let s3_uv = clamp(uv + vec2<f32>(px_2.x, px_2.y), vec2<f32>(0.0), vec2<f32>(1.0));
    let s3_d = depth_at(s3_uv);
    if s3_d > best_d { best_d = s3_d; best_uv = s3_uv; }

    let closest_pos = view_position(best_uv, max(best_d, 1e-7));
    let world_p = select(closest_pos + frame.camera_motion, normalize(closest_pos) * 1e4, best_d <= 0.0);
    let prev_clip = frame.previous_view_projection * vec4<f32>(world_p, 1.0);
    let prev_uv = vec2<f32>(prev_clip.x / prev_clip.w * 0.5 + 0.5, 0.5 - prev_clip.y / prev_clip.w * 0.5);
    let on_screen = prev_clip.w > 0.0 && all(prev_uv >= vec2<f32>(0.0)) && all(prev_uv <= vec2<f32>(1.0));

    if !on_screen || frame.delta_time <= 0.0 || frame.reset_reasons != 0u {
        textureStore(taa_hist, texel, vec4<f32>(cur_raw, 1.0));
        return;
    }

    let hist_raw = sample_history_catmull_rom(prev_uv, res);
    let prev_age = hist_raw.a;
    if prev_age <= 0.01 {
        textureStore(taa_hist, texel, vec4<f32>(cur_raw, 1.0));
        return;
    }

    // 3x3 neighborhood YCoCg variance clipping
    let n_a = rgb_to_ycocg(reinhard_taa(max(textureLoad(previous, clamp(texel + vec2<i32>(-1, -1), vec2<i32>(0), size_i - 1), 0).rgb, vec3<f32>(0.0))));
    let n_b = rgb_to_ycocg(reinhard_taa(max(textureLoad(previous, clamp(texel + vec2<i32>(0, -1), vec2<i32>(0), size_i - 1), 0).rgb, vec3<f32>(0.0))));
    let n_c = rgb_to_ycocg(reinhard_taa(max(textureLoad(previous, clamp(texel + vec2<i32>(1, -1), vec2<i32>(0), size_i - 1), 0).rgb, vec3<f32>(0.0))));
    let n_d = rgb_to_ycocg(reinhard_taa(max(textureLoad(previous, clamp(texel + vec2<i32>(-1, 0), vec2<i32>(0), size_i - 1), 0).rgb, vec3<f32>(0.0))));
    let n_e = rgb_to_ycocg(reinhard_taa(cur_raw));
    let n_f = rgb_to_ycocg(reinhard_taa(max(textureLoad(previous, clamp(texel + vec2<i32>(1, 0), vec2<i32>(0), size_i - 1), 0).rgb, vec3<f32>(0.0))));
    let n_g = rgb_to_ycocg(reinhard_taa(max(textureLoad(previous, clamp(texel + vec2<i32>(-1, 1), vec2<i32>(0), size_i - 1), 0).rgb, vec3<f32>(0.0))));
    let n_h = rgb_to_ycocg(reinhard_taa(max(textureLoad(previous, clamp(texel + vec2<i32>(0, 1), vec2<i32>(0), size_i - 1), 0).rgb, vec3<f32>(0.0))));
    let n_i = rgb_to_ycocg(reinhard_taa(max(textureLoad(previous, clamp(texel + vec2<i32>(1, 1), vec2<i32>(0), size_i - 1), 0).rgb, vec3<f32>(0.0))));

    var min_c = min(n_b, min(n_d, min(n_e, min(n_f, n_h))));
    min_c = 0.5 * (min_c + min(min_c, min(n_a, min(n_c, min(n_g, n_i)))));
    var max_c = max(n_b, max(n_d, max(n_e, max(n_f, n_h))));
    max_c = 0.5 * (max_c + max(max_c, max(n_a, max(n_c, max(n_g, n_i)))));

    let mu = (n_a + n_b + n_c + n_d + n_e + n_f + n_g + n_h + n_i) * (1.0 / 9.0);
    let m2 = (n_a * n_a + n_b * n_b + n_c * n_c + n_d * n_d + n_e * n_e + n_f * n_f + n_g * n_g + n_h * n_h + n_i * n_i) * (1.0 / 9.0);
    let sigma = sqrt(max(m2 - mu * mu, vec3<f32>(0.0)));
    let dist_f = 1.0 - exp2(-0.025 * length(closest_pos));
    let gamma = mix(0.75, 1.25, linear_step(0.25, 1.0, dist_f));
    min_c = max(min_c, mu - gamma * sigma);
    max_c = min(max_c, mu + gamma * sigma);

    let hist_ycocg = rgb_to_ycocg(reinhard_taa(hist_raw.rgb));
    let clipped_hist = ycocg_to_rgb(clip_aabb_taa(hist_ycocg, min_c, max_c));
    let cur_tm = reinhard_taa(cur_raw);

    let new_age = prev_age + 1.0;
    let blend_w = mix(0.35, 0.10, dist_f);
    var alpha = max(1.0 / new_age, blend_w);

    let px_off = vec2<f32>(1.0) - abs(2.0 * fract(res * prev_uv) - 1.0);
    let offcenter_rej = sqrt(max0(px_off.x * px_off.y)) * 0.25 + 0.75;
    alpha = 1.0 - (1.0 - alpha) * offcenter_rej;

    let blended = reinhard_taa_inv(mix(clipped_hist, cur_tm, alpha));
    textureStore(taa_hist, texel, vec4<f32>(max(blended, vec3<f32>(0.0)), min(new_age * offcenter_rej, 64.0)));
}
