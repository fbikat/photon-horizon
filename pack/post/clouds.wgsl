// photon's d1_clouds + aurora + crepuscular rays, one ray per 4x4 pixels a frame into clouds_raw:
// Cumulus, Altocumulus, Cumulus Congestus, Cirrus, Noctilucent, Aurora, Crepuscular Rays

// cloud_shadow_tex through a cubic B-spline (4 bilinear taps): far from the camera one texel of the map
// spans hundreds of blocks, and the rays' bilinear reads showed its texels as stepped, flat-topped shafts
fn cloud_shadow_smooth(uv: vec2<f32>) -> vec2<f32> {
    let size = vec2<f32>(textureDimensions(cloud_shadow_tex));
    let p = uv * size - 0.5;
    let i = floor(p);
    let f = p - i;
    let f2 = f * f;
    let f3 = f2 * f;
    let w0 = (1.0 / 6.0) * (-f3 + 3.0 * f2 - 3.0 * f + 1.0);
    let w1 = (1.0 / 6.0) * (3.0 * f3 - 6.0 * f2 + 4.0);
    let w2 = (1.0 / 6.0) * (-3.0 * f3 + 3.0 * f2 + 3.0 * f + 1.0);
    let w3 = (1.0 / 6.0) * f3;
    let g0 = w0 + w1;
    let g1 = w2 + w3;
    let h0 = (i - 0.5 + w1 / g0) / size;
    let h1 = (i + 1.5 + w3 / g1) / size;
    let a = textureSampleLevel(cloud_shadow_tex, linear_sampler, vec2<f32>(h0.x, h0.y), 0.0).rg;
    let b = textureSampleLevel(cloud_shadow_tex, linear_sampler, vec2<f32>(h1.x, h0.y), 0.0).rg;
    let c = textureSampleLevel(cloud_shadow_tex, linear_sampler, vec2<f32>(h0.x, h1.y), 0.0).rg;
    let d = textureSampleLevel(cloud_shadow_tex, linear_sampler, vec2<f32>(h1.x, h1.y), 0.0).rg;
    return g0.y * (g0.x * a + g1.x * b) + g1.y * (g0.x * c + g1.x * d);
}

// Photon's sky/crepuscular_rays.glsl driven by cloud_shadow_tex
fn draw_crepuscular_rays(ray_dir: vec3<f32>, dither: f32) -> vec3<f32> {
    if !crepuscular_rays || !clouds_cumulus || !cloud_shadows || cp.crepuscular_amount < eps {
        return vec3<f32>(0.0);
    }
    let ld = light_dir();
    if ld.y < -0.02 {
        return vec3<f32>(0.0);
    }
    let steps = u32(mix(20.0, 12.0, dampen(abs(ray_dir.y))));
    let max_len = 4096.0;
    let r = planet_radius + frame.camera_position.y * clouds_scale;
    let outer_r = cumulus_radius() + clouds_cumulus_thickness * 0.5;
    let dists = intersect_spherical_shell(vec3<f32>(0.0, r, 0.0), ray_dir, planet_radius, outer_r) / clouds_scale;
    if dists.y < 0.0 {
        return vec3<f32>(0.0);
    }
    let ray_len = clamp(dists.y - dists.x, 0.0, max_len);
    let step_len = ray_len / f32(steps);
    let ext = 2.0 * dampen(cp.crepuscular_amount) * (vec3<f32>(0.0004, 0.00084, 0.0020) * rec709_to_rec2020 + vec3<f32>(0.00072));
    let step_od = ext * step_len;
    let step_t = exp(-step_od);
    let ray_origin_w = ray_dir * dists.x;
    let ray_origin_p = vec3<f32>(0.0, planet_radius, 0.0) + ray_origin_w;

    var sc = vec3<f32>(0.0);
    var trans = vec3<f32>(1.0);
    for (var i = 0u; i < steps; i++) {
        let d = step_len * (f32(i) + dither);
        let wp = ray_origin_w + ray_dir * d;
        let pp = ray_origin_p + ray_dir * d;
        let c_uv = clamp(project_cloud_shadow_uv(wp), vec2<f32>(0.0), vec2<f32>(1.0));
        let cs = dot(cloud_shadow_smooth(c_uv), vec2<f32>(0.5));
        let a = linear_step(sqr(planet_radius - 100.0), sqr(planet_radius), length_squared(pp));
        let b = 1.0 - exp2(-0.002 * d);
        sc += cube(cs) * trans * (a * b);
        trans *= step_t;
    }

    var lc = sunlight_color * atmosphere_transmittance(ld.y, planet_radius);
    lc = atmosphere_post_processing(lc) * select(sun_color(), moon_color(), is_night());
    let ts = get_times();
    let lov = dot(ray_dir, ld);
    let phase = mix(0.5, 1.5, ts.sunrise + ts.sunset) * henyey_greenstein_phase(lov, 0.5)
        + 0.5 * henyey_greenstein_phase(lov, -0.2);
    let step_frac = (vec3<f32>(1.0) - step_t) / max(step_od, vec3<f32>(eps));
    return sc * ext * step_frac * lc * step_len * cp.crepuscular_amount * (6.0 * phase);
}

// The farthest depth (reversed: the smallest value) of the 4x4 pixels a raw texel stands for, as photon's
// depth_max_4x4: a texel that sees any sky draws the clouds there, so a leaf in front of the sky never
// punches a hole in them, and the composite decides per pixel whether the clouds are in front
fn depth_far_4x4(texel: vec2<i32>) -> f32 {
    let px = 1.0 / frame.resolution;
    let base = vec2<f32>(texel * 4);
    let a = textureGather(scene_depth, nearest_sampler, (base + vec2<f32>(1.0, 1.0)) * px);
    let b = textureGather(scene_depth, nearest_sampler, (base + vec2<f32>(3.0, 1.0)) * px);
    let c = textureGather(scene_depth, nearest_sampler, (base + vec2<f32>(1.0, 3.0)) * px);
    let d = textureGather(scene_depth, nearest_sampler, (base + vec2<f32>(3.0, 3.0)) * px);
    let m = min(min(a, b), min(c, d));
    return min(min(m.x, m.y), min(m.z, m.w));
}

// photon's d1_clouds: one ray per 4x4 block each frame, at this frame's checkerboard offset
fn compute(input: ComputeInput) {
    let dims = vec2<i32>(textureDimensions(clouds_raw));
    let texel = vec2<i32>(input.cell.xy);
    if !input.in_bounds || any(texel >= dims) {
        return;
    }
    var out = cloud_texel_empty();
    out.extra = bitcast<u32>(world_age());
    if !in_overworld() || (!clouds_cumulus && !clouds_cirrus && aurora == 0u && !crepuscular_rays) {
        textureStore(clouds_raw, texel, pack_clouds(out));
        return;
    }
    cp = clouds_parameters(get_weather());
    let resolution = frame.resolution;
    let pixel = min(texel * 4 + clouds_checkerboard_offset(frame.frame_index), vec2<i32>(resolution) - 1);
    let uv = (vec2<f32>(pixel) + 0.5) / resolution;
    let depth = depth_far_4x4(texel);
    let is_sky = depth <= 0.0;
    let pos = view_position(uv, max(depth, 1e-7));
    let ray_dir = normalize(view_position(uv, 1e-7));
    let dist_terrain = select(length(pos) * clouds_scale, -1.0, is_sky);
    let viewer = vec3<f32>(0.0, clouds_scale * (frame.camera_position.y - 63.0) + planet_radius, 0.0);
    // photon's dither: blue noise at the ray's pixel (noisetex.b), walked along the golden-ratio sequence
    // once per checkerboard cycle, so the rays the resolve averages in a texel spread evenly. Interleaved
    // gradient noise here left its diagonal stripes in the accumulated clouds.
    let blue = textureLoad(noisetex, pixel & vec2<i32>(511), 0).b;
    let dither = r1(frame.frame_index / 16u, blue);
    let clear_sky = atmosphere_scattering_both(ray_dir, sun_color(), moon_color());

    var res = draw_cumulus(viewer, ray_dir, clear_sky, dist_terrain, dither);
    // from below the altocumulus deck it lies behind the cumulus: skip it where the cumulus is opaque
    if res.transmittance > 0.02 || viewer.y > altocumulus_radius() {
        let ac = draw_altocumulus(viewer, ray_dir, clear_sky, dist_terrain, dither);
        res = blend_layers(res, ac);
    }
    if is_sky {
        let cu_con = draw_congestus(viewer, ray_dir, clear_sky, dist_terrain, dither);
        if cp.congestus_blend > eps {
            let df = mix(1.0, cu_con.transmittance, linear_step(0.75, 1.0, res.apparent_distance / 30000.0));
            res.scattering *= df;
            res.transmittance += (1.0 - res.transmittance) * (1.0 - df);
            res.apparent_distance = mix(cu_con.apparent_distance, res.apparent_distance, df);
            res = blend_layers(res, cu_con);
        }
        let ci = draw_cirrus(viewer, ray_dir, clear_sky, dither);
        res = blend_layers(res, ci);
        let nl = draw_noctilucent(viewer, ray_dir, clear_sky);
        res = blend_layers(res, nl);
        res.scattering += draw_aurora(ray_dir, dither) * res.transmittance;
        res.scattering += draw_crepuscular_rays(ray_dir, dither);
    }

    out.scattering = max(res.scattering, vec3<f32>(0.0));
    out.transmittance = res.transmittance;
    out.distance = min(res.apparent_distance / clouds_scale, CLOUDS_NO_HIT);
    // terrain all over the block and nothing in front of it: a hole, kept out of filtered neighbours
    if !is_sky && res.transmittance >= 0.999 {
        out.distance = CLOUDS_HOLE;
    }
    textureStore(clouds_raw, texel, pack_clouds(out));
}
