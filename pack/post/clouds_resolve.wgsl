// photon's d2_clouds_upscaling: resolves the 1/16 checkerboard clouds into a half-res history.
//
// Each half-res texel gets a fresh ray every 4 frames (the 4x4 checkerboard of clouds_raw lands in each of
// its 2x2 pixels once per 16 frames). Between those it carries its reprojected history. The texel's age
// counts the fresh rays it holds (up to CLOUDS_SAMPLE_LIMIT), and a new ray is weighted 1 / (age + 1),
// which averages the ray-march noise away instead of keeping a fixed share of it every frame.

const CLOUDS_SAMPLE_LIMIT: f32 = 12.0;

fn clouds_wind_blocks(altitude_r: f32) -> vec2<f32> {
    // photon's reproject_clouds: the layer is picked from the cloud's altitude, and a cloud drifts against
    // the wind its density is offset by (density(pos + wind * world_age))
    var w = clouds_wind_vel;
    if altitude_r > planet_radius + clouds_cirrus_altitude - 0.5 * clouds_cirrus_thickness {
        w = clouds_cirrus_wind;
    } else if altitude_r > planet_radius + clouds_altocumulus_altitude {
        w = clouds_ac_wind_vel;
    }
    return w / clouds_scale;
}

fn load_raw(t: vec2<i32>) -> CloudTexel {
    let dims = vec2<i32>(textureDimensions(clouds_raw));
    return unpack_clouds(textureLoad(clouds_raw, clamp(t, vec2<i32>(0), dims - 1), 0));
}

fn load_hist_previous(t: vec2<i32>) -> CloudTexel {
    let dims = vec2<i32>(textureDimensions(clouds_hist_previous));
    return unpack_clouds(textureLoad(clouds_hist_previous, clamp(t, vec2<i32>(0), dims - 1), 0));
}

// bilinear upsample of the raw clouds at half-res texel h, over the texels that aren't holes
fn raw_bilinear(h: vec2<i32>) -> CloudTexel {
    // the texel's centre (pixel 2h + 1) in raw texels, whose centres sit at pixel 4t + 2
    let p = (vec2<f32>(h) + 0.5) * 0.5 - 0.5;
    let i = vec2<i32>(floor(p));
    let f = p - floor(p);
    var acc = vec4<f32>(0.0);
    var w_sum = 0.0;
    var d_min = CLOUDS_NO_HIT;
    for (var k = 0; k < 4; k++) {
        let o = vec2<i32>(k & 1, k >> 1u);
        let c = load_raw(i + o);
        if cloud_texel_valid(c) {
            let w = max(select(1.0 - f.x, f.x, o.x == 1) * select(1.0 - f.y, f.y, o.y == 1), 1e-3);
            acc += vec4<f32>(c.scattering, c.transmittance) * w;
            w_sum += w;
            d_min = min(d_min, c.distance);
        }
    }
    var out = cloud_texel_empty();
    if w_sum > 0.0 {
        out.scattering = acc.rgb / w_sum;
        out.transmittance = acc.a / w_sum;
        out.distance = d_min;
    } else {
        out.distance = CLOUDS_HOLE;
    }
    return out;
}

fn catmull_rom_weights(f: f32) -> vec4<f32> {
    let f2 = f * f;
    let f3 = f2 * f;
    return vec4<f32>(
        -0.5 * f3 + f2 - 0.5 * f,
        1.5 * f3 - 2.5 * f2 + 1.0,
        -1.5 * f3 + 2.0 * f2 + 0.5 * f,
        0.5 * f3 - 0.5 * f2,
    );
}

struct HistSample {
    value: vec4<f32>,
    distance: f32,
    age: f32,
    ok: bool,
}

// Catmull-Rom over 4x4 history texels where all of them hold clouds (a bilinear fetch blurs the history a
// little more every frame the camera turns); bilinear over the valid texels of the centre 2x2 next to holes
fn sample_hist(prev_uv: vec2<f32>) -> HistSample {
    let dims = vec2<f32>(textureDimensions(clouds_hist_previous));
    let p = prev_uv * dims - 0.5;
    let i = vec2<i32>(floor(p));
    let f = p - floor(p);
    let wx = catmull_rom_weights(f.x);
    let wy = catmull_rom_weights(f.y);
    var cr = vec4<f32>(0.0);
    var all_valid = true;
    var bl = vec4<f32>(0.0);
    var bl_w = 0.0;
    var dist = 0.0;
    var age = 0.0;
    for (var k = 0; k < 16; k++) {
        let o = vec2<i32>(k & 3, k >> 2u);
        let c = load_hist_previous(i + o - 1);
        let valid = cloud_texel_valid(c) && c.extra > 0u;
        let v = vec4<f32>(c.scattering, c.transmittance);
        if valid {
            cr += v * (wx[o.x] * wy[o.y]);
        } else {
            all_valid = false;
        }
        if valid && all(o >= vec2<i32>(1)) && all(o <= vec2<i32>(2)) {
            let w = max(select(1.0 - f.x, f.x, o.x == 2) * select(1.0 - f.y, f.y, o.y == 2), 1e-3);
            bl += v * w;
            bl_w += w;
            dist += c.distance * w;
            age += (f32(c.extra) - 1.0) * w;
        }
    }
    var s: HistSample;
    s.ok = bl_w > 0.0;
    if !s.ok {
        return s;
    }
    s.value = select(bl / bl_w, cr, all_valid);
    s.value = vec4<f32>(max(s.value.rgb, vec3<f32>(0.0)), clamp(s.value.a, 0.0, 1.0));
    s.distance = dist / bl_w;
    s.age = age / bl_w;
    return s;
}

fn compute(input: ComputeInput) {
    let hdims = vec2<i32>(textureDimensions(clouds_hist));
    let h = vec2<i32>(input.cell.xy);
    if !input.in_bounds || any(h >= hdims) {
        return;
    }
    var hole = cloud_texel_empty();
    hole.distance = CLOUDS_HOLE;
    if !in_overworld() || (!clouds_cumulus && !clouds_cirrus && aurora == 0u && !crepuscular_rays) {
        textureStore(clouds_hist, h, pack_clouds(hole));
        return;
    }
    let res = frame.resolution;
    // the farthest of the texel's 2x2 pixels, as the raw pass: a texel that sees any sky keeps its clouds
    let uv = (vec2<f32>(h * 2) + 1.0) / res;
    let g = textureGather(scene_depth, nearest_sampler, uv);
    let depth = min(min(g.x, g.y), min(g.z, g.w));
    let is_sky = depth <= 0.0;
    let ray_dir = normalize(view_position(uv, 1e-7));
    let terrain_dist = select(length(view_position(uv, max(depth, 1e-7))), 1e7, is_sky);

    let rdims = vec2<i32>(textureDimensions(clouds_raw));
    let src = h / 2;
    let off = clouds_checkerboard_offset(frame.frame_index);
    let fresh = all(off / 2 == h % 2) && all(src < rdims);
    var current: CloudTexel;
    if fresh {
        current = load_raw(src);
    } else {
        current = raw_bilinear(h);
    }

    // terrain covers the texel and the clouds lie behind it: nothing to keep
    if !is_sky && (!cloud_texel_valid(current) || terrain_dist < current.distance) {
        textureStore(clouds_hist, h, pack_clouds(hole));
        return;
    }
    let closest = min(max(current.distance, 1.0), CLOUDS_NO_HIT);

    // reproject the cloud, not the pixel: it sits at `closest` along the ray and drifts with its layer's wind
    let viewer = vec3<f32>(0.0, clouds_scale * (frame.camera_position.y - 63.0) + planet_radius, 0.0);
    let wind = clouds_wind_blocks(length(viewer + ray_dir * (closest * clouds_scale)));
    let age_then = bitcast<f32>(textureLoad(clouds_raw_previous, vec2<i32>(0, 0), 0).w);
    let d_age = clamp(world_age() - age_then, 0.0, 0.5);
    let p_prev = ray_dir * closest + frame.camera_motion + vec3<f32>(wind.x, 0.0, wind.y) * d_age;
    let pc = frame.previous_view_projection * vec4<f32>(p_prev, 1.0);
    let prev_uv = vec2<f32>(pc.x / pc.w * 0.5 + 0.5, 0.5 - pc.y / pc.w * 0.5);

    var disocclusion = pc.w <= 0.0 || any(prev_uv < vec2<f32>(0.0)) || any(prev_uv > vec2<f32>(1.0))
        || frame.delta_time <= 0.0 || frame.reset_reasons != 0u;
    var hist: HistSample;
    hist.ok = false;
    if !disocclusion {
        hist = sample_hist(prev_uv);
        disocclusion = !hist.ok;
    }

    // clamp the history to this frame's neighbourhood (photon's soft min/max of the raw 3x3, "Hybrid
    // Reconstruction Antialiasing"). Photon does it only when moving fast and leaves the rest to its TAA;
    // here nothing follows, and the clouds' detail drifts faster than the wind the reprojection follows
    // (photon's worley layers move at 1.2 and 1.4 times it), which left trails over clear sky.
    if !disocclusion {
        let centre = load_raw(min(src, rdims - 1));
        let e = select(vec4<f32>(current.scattering, current.transmittance),
            vec4<f32>(centre.scattering, centre.transmittance), cloud_texel_valid(centre));
        var cross_min = e;
        var cross_max = e;
        var corner_min = e;
        var corner_max = e;
        for (var k = 0; k < 9; k++) {
            let o = vec2<i32>(k % 3, k / 3) - 1;
            let c = load_raw(src + o);
            let v = select(e, vec4<f32>(c.scattering, c.transmittance), cloud_texel_valid(c));
            if o.x == 0 || o.y == 0 {
                cross_min = min(cross_min, v);
                cross_max = max(cross_max, v);
            } else {
                corner_min = min(corner_min, v);
                corner_max = max(corner_max, v);
            }
        }
        let mn = 0.5 * (cross_min + min(cross_min, corner_min));
        let mx = 0.5 * (cross_max + max(cross_max, corner_max));
        hist.value = clamp(hist.value, mn, mx);
    }

    var out: CloudTexel;
    let cur_v = vec4<f32>(current.scattering, current.transmittance);
    var result: vec4<f32>;
    var dist: f32;
    var age: f32;
    if disocclusion {
        // a guess from the neighbouring rays counts as no sample: the next fresh ray replaces it
        result = cur_v;
        dist = current.distance;
        age = select(0.0, 1.0, fresh);
    } else if !fresh {
        result = hist.value;
        dist = min(current.distance, hist.distance);
        age = hist.age;
    } else {
        let w = 1.0 - 1.0 / (min(hist.age, CLOUDS_SAMPLE_LIMIT) + 1.0);
        result = mix(cur_v, hist.value, w);
        dist = mix(current.distance, hist.distance, w);
        age = min(hist.age + 1.0, CLOUDS_SAMPLE_LIMIT);
    }
    out.scattering = result.rgb;
    out.transmittance = result.a;
    out.distance = max(dist, 0.0);
    // stored as samples + 1: a cleared or hole texel's 0 reads as "no history"
    out.extra = u32(round(age)) + 1u;
    textureStore(clouds_hist, h, pack_clouds(out));
}
