// Half-res volumetric light (light shafts through the shadow map and cloud shadows, Overworld air and
// underwater) and GTAO (photon's d3_ao, include/lighting/ao/gtao.glsl; the older SSAO below stays behind the
// `gtao` switch), accumulated over frames by reprojection so their per-frame dither averages out instead of
// crawling: r light shafts, g view distance (for the composite's bilateral upsample and the history check),
// b AO, a the frames accumulated (integer part, 1..13) and photon's ambient_sss (the skylight a leaf lets
// through) times 0.9 in its fraction. The material stage reads the last frame's alpha for the foliage's
// ambient_sss.

const VLAO_FRAME_LIMIT: f32 = 12.0;

fn compute_vl(ray_dir: vec3<f32>, raw_dist: f32, dither: f32) -> f32 {
    let dist = select(raw_dist, min(raw_dist, 256.0), frame.eye_in == 1u);
    let max_dist = min(dist, frame.shadow_distance);
    let steps = 12;
    let step_length = max_dist / f32(steps);
    let use_cs = cloud_shadows && clouds_cumulus && light_dir().y > 0.0;
    var lit = 0.0;
    for (var i = 0; i < steps; i++) {
        let p = ray_dir * step_length * (f32(i) + dither);
        let s = shadow_position(p);
        var step_lit = 1.0;
        if all(s.xy >= vec2<f32>(0.0)) && all(s.xy <= vec2<f32>(1.0)) {
            step_lit = textureSampleCompareLevel(shadow_map, shadow_sampler, s.xy, s.z);
        }
        if use_cs && step_lit > 0.01 {
            let cs_uv = project_cloud_shadow_uv(p);
            if all(cs_uv >= vec2<f32>(0.0)) && all(cs_uv <= vec2<f32>(1.0)) {
                let cs = textureSampleLevel(cloud_shadow_tex, linear_sampler, cs_uv, 0.0).r;
                step_lit *= cloud_shadow_factor(cs, get_cloud_shadow_fade(p));
            }
        }
        lit += step_lit;
    }
    let visible = lit / f32(steps);
    // past the shadow map the light is unshadowed
    return mix(1.0, visible, max_dist / max(dist, eps));
}

// Photon's light shafts in the air (c0_vl.fsh, raymarch_air_fog): the fog is raymarched and its sunlit part is weighed by
// a shadow lookup per step, so the shafts are the shadowed share of the fog's direct light, weighted by how much fog
// each stretch of the ray holds and how much of the light gets through the fog before it. This returns that share
// (what the composite multiplies the analytic fog's direct light by). Each of 12 steps over the shadow map's reach
// takes the airmass of its stretch from the analytic fog's closed form (the same height falloff, so the shafts
// weigh what the fog draws), the sky included (a ray to the render distance, as the analytic fog's), and the
// stretch past the shadow map counts as lit.
fn compute_vl_air(ray_dir: vec3<f32>, total_len: f32, dither: f32, is_sky: bool) -> f32 {
    let w = get_weather();
    let t = get_times();
    let rain = select(0.0, frame.rain, frame.precipitation == 1u);
    let snow = select(0.0, frame.rain, frame.precipitation == 2u);
    // the fog's coefficients (the analytic fog's, common.wgsl): rayleigh by its luminance, mie by its density
    let biomes = Biomes(textureLoad(cloud_shadow_tex, BIOME_TEXEL_0, 0), textureLoad(cloud_shadow_tex, BIOME_TEXEL_1, 0));
    let rayleigh_rain = from_srgb(vec3<f32>(0.31, 0.67, 1.0)) * 0.0005;
    let rayleigh_c = mix(biome_rayleigh(biomes) * (1.0 + w.humidity * w.temperature), rayleigh_rain, rain);
    let sig_r = dot(rayleigh_c, luminance_weights);
    let s_y = frame.sun_direction.y;
    let blue_hour = linear_step(0.05, 1.0, exp(-190.0 * sqr(s_y + 0.07283)));
    var mie = 0.0070 * t.sunrise + 0.0001 * t.noon + 0.0050 * t.sunset + 0.0050 * t.midnight + 0.0020 * blue_hour;
    mie = mix(mie + 8.0 * 0.0001 * sqr(clamp01(w.humidity / 0.8)), 0.030, rain);
    mie = mix(mie, 0.015, snow);
    let sig_m = mie * mix(0.9, 0.5, rain);
    let lov = dot(ray_dir, light_dir());
    let mie_phase = 0.7 * henyey_greenstein_phase(lov, 0.5) + 0.3 * henyey_greenstein_phase(lov, -0.2);

    let y0 = frame.camera_position.y;
    let near = min(total_len, frame.shadow_distance);
    // the sky has no surface to place the steps against: half as many, the history averages them
    let steps = select(12, 6, is_sky);
    let use_cs = cloud_shadows && clouds_cumulus && light_dir().y > 0.0;
    var am_prev = vec2<f32>(0.0);
    var lit_w = 0.0;
    var all_w = 0.0;
    for (var i = 0; i < steps; i++) {
        let am1 = air_fog_vl_airmass(y0, ray_dir, near * f32(i + 1) / f32(steps));
        let d = max(am1 - am_prev, vec2<f32>(0.0));
        let seen = exp(-(sig_r * am_prev.x + mie * am_prev.y));
        let weight = (sig_r * isotropic_phase * d.x + sig_m * mie_phase * d.y) * seen;
        am_prev = am1;
        let p = ray_dir * near * (f32(i) + dither) / f32(steps);
        let s = shadow_position(p);
        var step_lit = 1.0;
        if all(s.xy >= vec2<f32>(0.0)) && all(s.xy <= vec2<f32>(1.0)) {
            step_lit = textureSampleCompareLevel(shadow_map, shadow_sampler, s.xy, s.z);
        }
        if use_cs && step_lit > 0.01 {
            let cs_uv = project_cloud_shadow_uv(p);
            if all(cs_uv >= vec2<f32>(0.0)) && all(cs_uv <= vec2<f32>(1.0)) {
                let cs = textureSampleLevel(cloud_shadow_tex, linear_sampler, cs_uv, 0.0).r;
                step_lit *= cloud_shadow_factor(cs, get_cloud_shadow_fade(p));
            }
        }
        lit_w += step_lit * weight;
        all_w += weight;
    }
    // past the shadow map: the rest of the ray's fog, unshadowed
    if total_len > near {
        let d = max(air_fog_vl_airmass(y0, ray_dir, total_len) - am_prev, vec2<f32>(0.0));
        let far_w = (sig_r * isotropic_phase * d.x + sig_m * mie_phase * d.y) * exp(-(sig_r * am_prev.x + mie * am_prev.y));
        lit_w += far_w;
        all_w += far_w;
    }
    return select(1.0, lit_w / all_w, all_w > 1e-12);
}

fn compute_ssao(uv: vec2<f32>, normal: vec3<f32>, pos: vec3<f32>, dist: f32, dither: f32) -> f32 {
    if dist > 96.0 {
        return 1.0;
    }
    let radius = clamp(dist * 0.10, 0.45, 1.8);
    let proj_scale = vec2<f32>(abs(frame.projection[0][0]), abs(frame.projection[1][1])) * 0.5;
    let uv_radius = clamp(proj_scale * radius / max(dist, 0.5), 2.0 / frame.resolution, vec2<f32>(0.08));

    var occ_sum = 0.0;
    let dirs = 6;
    let steps = 2;
    let base_angle = dither * (tau / f32(dirs));
    for (var i = 0; i < dirs; i++) {
        let ang = base_angle + f32(i) * (tau / f32(dirs));
        let dir2 = vec2<f32>(cos(ang), sin(ang));
        var max_occ = 0.0;
        for (var s = 0; s < steps; s++) {
            let jitter = fract(dither + f32(i * steps + s) * golden_ratio);
            let frac = (f32(s) + 0.35 + 0.5 * jitter) / f32(steps);
            let s_uv = uv + dir2 * uv_radius * frac;
            if all(s_uv >= vec2<f32>(0.0)) && all(s_uv <= vec2<f32>(1.0)) {
                let s_depth = depth_at(s_uv);
                if s_depth > 0.0 {
                    let s_pos = view_position(s_uv, s_depth);
                    let delta = s_pos - pos;
                    let len = sqrt(max(dot(delta, delta), 1e-6));
                    let n_dot_d = dot(normal, delta / len);
                    let falloff = 1.0 - smoothstep(radius * 0.35, radius * 1.35, len);
                    let occ = max0(n_dot_d - 0.06) * falloff;
                    max_occ = max(max_occ, occ);
                }
            }
        }
        occ_sum += max_occ;
    }
    let raw_ao = clamp01(1.0 - (occ_sum / f32(dirs)) * 1.45 * ao_intensity);
    let dist_fade = 1.0 - smoothstep(48.0, 96.0, dist);
    return mix(1.0, raw_ao, dist_fade);
}


// photon's GTAO (2 slices, 3 horizon steps each, radius 2 blocks). Its horizon search steps through the depth
// buffer along one direction of a slice and returns the angle of the highest occluder seen from the viewer.
const GTAO_SLICES: i32 = 2;
const GTAO_STEPS: i32 = 3;
const GTAO_RADIUS: f32 = 2.0;
const GTAO_FALLOFF_START: f32 = 0.75;

fn gtao_project(p: vec3<f32>) -> vec2<f32> {
    let clip = frame.projection * (frame.view * vec4<f32>(p, 1.0));
    return vec2<f32>(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
}

fn gtao_horizon_angle(slice_dir: vec3<f32>, viewer_dir: vec3<f32>, uv0: vec2<f32>, pos: vec3<f32>, radius: f32, dither: f32) -> f32 {
    let step_size = (GTAO_RADIUS / f32(GTAO_STEPS)) * radius;
    let ray_step = gtao_project(pos + slice_dir * step_size) - uv0;
    let px = 1.0 / frame.resolution;
    var ray_pos = uv0 + ray_step * (dither + max(px.x, px.y) / max(length(ray_step), 1e-6));
    var max_cos = -1.0;
    for (var i = 0; i < GTAO_STEPS; i++) {
        let uv = clamp(ray_pos, vec2<f32>(0.0), vec2<f32>(1.0));
        let depth = depth_at(uv);
        if depth > 0.0 {
            let offset = view_position(uv, depth) - pos;
            let len_sq = max(dot(offset, offset), 1e-8);
            let norm = inverseSqrt(len_sq);
            let falloff = linear_step(GTAO_FALLOFF_START * GTAO_RADIUS, GTAO_RADIUS, len_sq * norm / radius);
            let cos_theta = mix(dot(viewer_dir, offset) * norm, -1.0, falloff);
            max_cos = max(max_cos, cos_theta);
        }
        ray_pos += ray_step;
    }
    return acos(clamp(max_cos, -1.0, 1.0));
}

fn gtao_integrate_arc(h: vec2<f32>, n: f32, cos_n: f32) -> f32 {
    let tmp = cos_n + 2.0 * h * sin(n) - cos(2.0 * h - n);
    return 0.25 * (tmp.x + tmp.y);
}

// x: the multibounced AO, y: ambient_sss (the share of the hemisphere behind the face the GTAO finds open)
fn compute_gtao(uv: vec2<f32>, view_normal: vec3<f32>, pos: vec3<f32>, dither: vec2<f32>) -> vec2<f32> {
    var ao = 0.0;
    var ambient_sss = 0.0;
    let viewer_dir = normalize(-pos);
    let up_ref = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(viewer_dir.y) > 0.98);
    let viewer_right = normalize(cross(up_ref, viewer_dir));
    let viewer_up = cross(viewer_dir, viewer_right);
    // photon shrinks the radius very close up
    let radius = max(0.25 + 0.75 * smoothstep(0.0, 81.0, dot(pos, pos)), 0.5);
    for (var i = 0; i < GTAO_SLICES; i++) {
        let slice_angle = (f32(i) + dither.x) * (pi / f32(GTAO_SLICES));
        let slice_dir = vec3<f32>(cos(slice_angle), sin(slice_angle), 0.0);
        let view_slice_dir = viewer_right * slice_dir.x + viewer_up * slice_dir.y;
        let ortho_dir = view_slice_dir - dot(view_slice_dir, viewer_dir) * viewer_dir;
        let axis = cross(view_slice_dir, viewer_dir);
        let projected_normal = view_normal - axis * dot(view_normal, axis);
        let len_sq = max(dot(projected_normal, projected_normal), 1e-8);
        let norm = inverseSqrt(len_sq);
        let sgn_gamma = sign(dot(ortho_dir, projected_normal));
        let cos_gamma = clamp01(dot(projected_normal, viewer_dir) * norm);
        let gamma = sgn_gamma * acos(cos_gamma);
        var h = vec2<f32>(
            gtao_horizon_angle(-view_slice_dir, viewer_dir, uv, pos, radius, dither.y),
            gtao_horizon_angle(view_slice_dir, viewer_dir, uv, pos, radius, dither.y),
        );
        ambient_sss += max0(h.y - half_pi) * rcp_pi;
        h = gamma + clamp(vec2<f32>(-1.0, 1.0) * h - gamma, vec2<f32>(-half_pi), vec2<f32>(half_pi));
        ao += gtao_integrate_arc(h, gamma, cos_gamma) * len_sq * norm;
    }
    let albedo = 0.2; // the surroundings' albedo, for photon's multibounce approximation
    ao = ao / f32(GTAO_SLICES);
    ambient_sss = ambient_sss / f32(GTAO_SLICES);
    ao = ao / (albedo * ao + (1.0 - albedo));
    return clamp(vec2<f32>(ao, ambient_sss), vec2<f32>(0.0), vec2<f32>(1.0));
}

fn post(input: PostInput) -> vec4<f32> {
    let full = vec2<i32>(frame.resolution);
    let hp = vec2<i32>(input.pixel);
    // the top-left pixel of the 2x2 this texel stands for, so the texel keeps one surface from frame to frame
    let p = min(hp * 2, full - 1);
    let uv = (vec2<f32>(p) + 0.5) / frame.resolution;
    let depth = textureLoad(scene_depth, p, 0);
    let is_sky = depth <= 0.0;
    let pos = view_position(uv, max(depth, 1e-7));
    let ray_dir = normalize(pos);
    let raw_dist = select(length(pos), 1e4, is_sky);
    let stored_dist = min(raw_dist, 65000.0);
    // blue noise walked along the golden-ratio sequence: a different dither every frame, which the history
    // below averages
    let dither = r1(frame.frame_index, textureLoad(noisetex, hp & vec2<i32>(511), 0).b);

    var shafts = 1.0;
    if vl && in_overworld() && frame.has_shadow != 0u {
        if frame.eye_in == 1u {
            shafts = compute_vl(ray_dir, raw_dist, dither);
        } else if frame.eye_in == 0u && !vl_weighted_shafts && !is_sky {
            shafts = compute_vl(ray_dir, raw_dist, dither);
        } else if frame.eye_in == 0u && vl_weighted_shafts {
            shafts = compute_vl_air(ray_dir, select(min(raw_dist, 65000.0), frame.render_distance, is_sky), dither, is_sky);
        }
    }
    var ao = 1.0;
    var sss = 0.0;
    if ssao && ao_intensity > 0.0 && !is_sky {
        let surf = surface_at(p);
        if surf.present {
            if gtao {
                // past 160 blocks the AO is nothing worth its taps
                if raw_dist < 160.0 {
                    let d2 = fract(dither * 7.0 + textureLoad(noisetex, (hp + vec2<i32>(131, 71)) & vec2<i32>(511), 0).g);
                    let g = compute_gtao(uv, surf.normal, pos, vec2<f32>(dither, d2));
                    ao = pow(g.x, ao_intensity);
                    sss = g.y;
                }
            } else {
                ao = compute_ssao(uv, surf.normal, pos, raw_dist, dither);
            }
        }
    }
    let current = vec3<f32>(shafts, ao, sss);

    // reproject this pixel's surface into last frame's half-res texture
    let prev_p = select(pos + frame.camera_motion, ray_dir * 1e4, is_sky);
    let expected = min(select(length(pos + frame.camera_motion), 1e4, is_sky), 65000.0);
    let pc = frame.previous_view_projection * vec4<f32>(prev_p, 1.0);
    let prev_uv = vec2<f32>(pc.x / pc.w * 0.5 + 0.5, 0.5 - pc.y / pc.w * 0.5);
    let valid = pc.w > 0.0 && all(prev_uv >= vec2<f32>(0.0)) && all(prev_uv <= vec2<f32>(1.0))
        && frame.delta_time > 0.0 && frame.reset_reasons == 0u;
    if !valid {
        return vec4<f32>(current.x, stored_dist, current.y, 1.0 + 0.9 * current.z);
    }
    // bilinear over the texels that saw the same surface (within a few percent of its distance)
    let dims = vec2<i32>(textureDimensions(vlao_tex_previous));
    let hp_prev = prev_uv * vec2<f32>(dims) - 0.5;
    let i = vec2<i32>(floor(hp_prev));
    let f = hp_prev - floor(hp_prev);
    let tolerance = 0.04 * expected + 0.15;
    var acc = vec4<f32>(0.0);
    var w_sum = 0.0;
    for (var k = 0; k < 4; k++) {
        let o = vec2<i32>(k & 1, k >> 1u);
        let s = textureLoad(vlao_tex_previous, clamp(i + o, vec2<i32>(0), dims - 1), 0);
        let w = select(1.0 - f.x, f.x, o.x == 1) * select(1.0 - f.y, f.y, o.y == 1);
        if abs(s.g - expected) < tolerance && s.a > 0.0 {
            // the alpha holds the age and, in its fraction, the ambient_sss
            let age_k = floor(s.a);
            acc += vec4<f32>(s.r, s.b, age_k, clamp01((s.a - age_k) / 0.9)) * w;
            w_sum += w;
        }
    }
    if w_sum < 0.05 {
        return vec4<f32>(current.x, stored_dist, current.y, 1.0 + 0.9 * current.z);
    }
    let hist = acc / w_sum;
    let age = min(hist.z, VLAO_FRAME_LIMIT);
    let blended = mix(vec3<f32>(hist.x, hist.y, hist.w), current, 1.0 / (age + 1.0));
    return vec4<f32>(blended.x, stored_dist, blended.y, floor(age) + 1.0 + 0.9 * blended.z);
}
