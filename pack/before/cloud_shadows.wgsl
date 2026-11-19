// [[before_world]] compute pass: renders volumetric cloud shadow map into cloud_shadow_tex, draws the low-res sky
// map with clouds into its corner tiles (photon's d0_sky_map), and its corner workgroup projects that sky onto
// spherical harmonics for the skylight (SH_SKYLIGHT)

var<workgroup> sky_sh_part: array<array<vec3<f32>, 9>, 64>;

// the sky as d4a_generate_sky_sh reads it without the sky map's clouds (sky_map_clouds off, or the map not drawn
// yet): the atmosphere, the analytic fog over it and the boost. Overcast, the sky goes to the weather colour, as
// get_sky_color does (2x: a uniform sky of L gives pi L facing up, the ambient tau L). With the map, project_sky_sh
// reads it, clouds and all, as photon does.
fn sky_sh_radiance(dir: vec3<f32>) -> vec3<f32> {
    var sky = atmosphere_scattering_both(dir, sun_color(), moon_color());
    let fog = air_fog_analytic(frame.camera_position.y, frame.render_distance, dir, eye_skylight(), true);
    sky = sky * fog.transmittance + fog.direct + fog.ambient;
    sky = mix(sky, 2.0 * get_weather_color(), frame.rain);
    return sky * get_skylight_boost();
}


// the sky map as the last frame left it (this pass writes this frame's texels as the SH workgroup reads, so it
// reads the previous one); alpha 0 where it has never been written
fn sky_map_previous(d: vec3<f32>) -> vec4<f32> {
    let k = sky_map_taps(d);
    return textureLoad(cloud_shadow_tex_previous, k.t00, 0) * k.w.x
        + textureLoad(cloud_shadow_tex_previous, k.t10, 0) * k.w.y
        + textureLoad(cloud_shadow_tex_previous, k.t01, 0) * k.w.z
        + textureLoad(cloud_shadow_tex_previous, k.t11, 0) * k.w.w;
}

// photon's draw_sky for the sky map: the atmosphere, the clouds and aurora over it (drawn from the ground, as
// photon's map is), the underground fade, then the analytic fog. No sun, moon or stars: the reflections add
// the sun's highlight themselves and the SH has no use for the discs.
fn sky_map_radiance(dir: vec3<f32>, dither: f32) -> vec3<f32> {
    let clear_sky = atmosphere_scattering_both(dir, sun_color(), moon_color());
    var sky = clear_sky;
    if clouds_cumulus || clouds_cirrus || aurora != 0u {
        let viewer = vec3<f32>(0.0, planet_radius, 0.0);
        var res = draw_cumulus(viewer, dir, clear_sky, -1.0, dither);
        if res.transmittance > 0.02 || viewer.y > altocumulus_radius() {
            res = blend_layers(res, draw_altocumulus(viewer, dir, clear_sky, -1.0, dither));
        }
        if cp.congestus_blend > eps {
            let cu_con = draw_congestus(viewer, dir, clear_sky, -1.0, dither);
            let df = mix(1.0, cu_con.transmittance, linear_step(0.75, 1.0, res.apparent_distance / 30000.0));
            res.scattering *= df;
            res.transmittance += (1.0 - res.transmittance) * (1.0 - df);
            res.apparent_distance = mix(cu_con.apparent_distance, res.apparent_distance, df);
            res = blend_layers(res, cu_con);
        }
        res = blend_layers(res, draw_cirrus(viewer, dir, clear_sky, dither));
        res = blend_layers(res, draw_noctilucent(viewer, dir, clear_sky));
        res.scattering += draw_aurora(dir, dither) * res.transmittance;
        sky = clear_sky * res.transmittance + max(res.scattering, vec3<f32>(0.0));
    }
    sky = mix(sky, vec3<f32>(0.0), biome_cave() * smoothstep(-0.1, 0.1, 0.4 - dir.y));
    let fog = air_fog_analytic(frame.camera_position.y, frame.render_distance, dir, eye_skylight(), true);
    return sky * fog.transmittance + fog.direct + fog.ambient;
}

// one texel of the sky map: a quarter of them a frame (a checkerboard of 8x8 blocks), eased into the old value, so the
// clouds' dither averages out and the cost stays tiny; all of them when there is no old value yet
fn update_sky_map(texel: vec2<i32>) {
    let prev = textureLoad(cloud_shadow_tex_previous, texel, 0);
    if !in_overworld() || !sky_map_clouds {
        textureStore(cloud_shadow_tex, texel, vec4<f32>(0.0, 0.0, 0.0, 0.0));
        return;
    }
    let idx = sky_map_index(texel);
    let fresh = frame.reset_reasons != 0u || any(prev != prev) || prev.a < 0.5;
    // in blocks of 8x8 texels (one workgroup), so the idle texels do not sit in warps that draw: with a texel
    // checkerboard every warp paid for the clouds
    let turn = u32((texel.x >> 3u) + 2 * (texel.y >> 3u)) % 4u == frame.frame_index % 4u;
    if !fresh && !turn {
        textureStore(cloud_shadow_tex, texel, prev);
        return;
    }
    cp = clouds_parameters(get_weather());
    let dir = sky_map_dir(idx.x, idx.y);
    let dither = interleaved_gradient_noise(vec2<f32>(idx) + f32(frame.frame_index / 4u % 64u) * vec2<f32>(5.588238, 3.1));
    var c = sky_map_radiance(dir, dither);
    if any(c != c) {
        c = select(prev.rgb, vec3<f32>(0.0), fresh);
    }
    c = clamp(c, vec3<f32>(0.0), vec3<f32>(60000.0));
    textureStore(cloud_shadow_tex, texel, vec4<f32>(select(mix(prev.rgb, c, 0.4), c, fresh), 1.0));
}

// 256 directions over the upper hemisphere, as photon: 4 an invocation, summed by band in workgroup memory.
// Every invocation of every workgroup reaches the barrier; only the corner one (cells 504..511) does the work.
fn project_sky_sh(input: ComputeInput) {
    let corner = all(input.cell.xy >= vec2<u32>(504u)) && in_overworld() && sh_skylight;
    var part = array<vec3<f32>, 9>();
    if corner {
        for (var k = 0u; k < 4u; k++) {
            let i = input.local + 64u * k;
            let xi = fract(vec2<f32>(0.5) + f32(i) * vec2<f32>(0.7548776662, 0.5698402910));
            let phi = tau * xi.x;
            let cos_t = xi.y;
            let sin_t = sqrt(max(1.0 - cos_t * cos_t, 0.0));
            let dir = vec3<f32>(cos(phi) * sin_t, cos_t, sin(phi) * sin_t);
            var sky_rad = vec3<f32>(0.0);
            var drawn = false;
            if sky_map_clouds {
                let m = sky_map_previous(dir);
                drawn = m.a > 0.5;
                sky_rad = m.rgb * get_skylight_boost() / max(m.a, 0.5);
            }
            if !drawn {
                sky_rad = sky_sh_radiance(dir);
            }
            let radiance = sky_rad * (tau / 256.0);
            let b = sh_basis(dir);
            part[0] += radiance * b[0];
            part[1] += radiance * b[1];
            part[2] += radiance * b[2];
            part[3] += radiance * b[3];
            part[4] += radiance * b[4];
            part[5] += radiance * b[5];
            part[6] += radiance * b[6];
            part[7] += radiance * b[7];
            part[8] += radiance * b[8];
        }
    }
    sky_sh_part[input.local % 64u] = part;
    workgroupBarrier();
    if !corner || input.local > SKY_SH_UP {
        return;
    }
    var sh = array<vec3<f32>, 9>();
    for (var n = 0u; n < 64u; n++) {
        let p = sky_sh_part[n];
        sh[0] += p[0];
        sh[1] += p[1];
        sh[2] += p[2];
        sh[3] += p[3];
        sh[4] += p[4];
        sh[5] += p[5];
        sh[6] += p[6];
        sh[7] += p[7];
        sh[8] += p[8];
    }
    var value: vec3<f32>;
    if input.local == SKY_SH_UP {
        value = sh_irradiance(sh, vec3<f32>(0.0, 1.0, 0.0), 1.0);
    } else {
        value = sh[input.local];
    }
    textureStore(cloud_shadow_tex, sky_sh_texel(input.local), vec4<f32>(value, 1.0));
}

fn compute(input: ComputeInput) {
    project_sky_sh(input);
    if !input.in_bounds {
        return;
    }
    let texel = vec2<i32>(input.cell.xy);
    if is_sky_sh_texel(texel) {
        return;
    }
    if is_sky_map_texel(texel) {
        update_sky_map(texel);
        return;
    }
    // the biome categories for the fog, eased as photon eases its biome uniforms (30 s), at once after a jump
    if all(texel == BIOME_TEXEL_0) || all(texel == BIOME_TEXEL_1) {
        let now = biome_weights_now();
        let goal = select(now.w1, now.w0, all(texel == BIOME_TEXEL_0));
        let prev = textureLoad(cloud_shadow_tex_previous, texel, 0);
        let fresh = frame.reset_reasons != 0u || any(prev != prev) || any(prev < vec4<f32>(0.0)) || any(prev > vec4<f32>(1.0));
        let k = select(1.0 - exp(-frame.delta_time / 10.0), 1.0, fresh);
        textureStore(cloud_shadow_tex, texel, mix(prev, goal, k));
        return;
    }
    // photon finds lightning by vanilla's sky colour turning to its flash colour; Horizon moves it 22% there, too
    // little to pass photon's test on a night sky, so a jump in the sky's brightness over its recent level, in a
    // thunderstorm, is the flash: on at once, gone over 0.75 s like photon's smooth(.., 0, 0.75)
    if all(texel == LIGHTNING_TEXEL) {
        let prev = textureLoad(cloud_shadow_tex_previous, texel, 0);
        let lum = dot(frame.sky_color, vec3<f32>(0.3, 0.59, 0.11));
        let fresh = frame.reset_reasons != 0u || any(prev != prev);
        let avg = select(prev.x, lum, fresh);
        // the frame's sky colour is linear: a night sky near 0 goes to about 0.02 in the flash
        let strike = lightning_flash && frame.thunder > 0.01 && lum - avg > 0.008 + 0.3 * avg;
        let flash = max(select(0.0, 1.0, strike), select(prev.y, 0.0, fresh) * exp(-frame.delta_time / 0.25));
        // the level the jump is measured from follows the sky (1 s), but not the flash itself
        let new_avg = select(mix(avg, lum, 1.0 - exp(-frame.delta_time)), avg, flash > 0.05);
        textureStore(cloud_shadow_tex, texel, vec4<f32>(new_avg, flash, 0.0, 1.0));
        return;
    }
    if all(texel == FRAME_LIGHT_TEXEL) {
        textureStore(cloud_shadow_tex, texel, vec4<f32>(get_light_color(), 1.0));
        return;
    }
    if all(texel == FRAME_SKY_TEXEL) {
        textureStore(cloud_shadow_tex, texel, vec4<f32>(get_sky_color(), 1.0));
        return;
    }
    if !cloud_shadows || !in_overworld() || (!clouds_cumulus && !clouds_cirrus) {
        textureStore(cloud_shadow_tex, texel, vec4<f32>(1.0, 1.0, 0.0, 1.0));
        return;
    }
    let ld = light_dir();
    if ld.y < -0.02 {
        textureStore(cloud_shadow_tex, texel, vec4<f32>(1.0, 1.0, 0.0, 1.0));
        return;
    }

    cp = clouds_parameters(get_weather());
    let uv = (vec2<f32>(input.cell.xy) + 0.5) / vec2<f32>(input.size.xy);
    let scene_p = unproject_cloud_shadow_pos(uv);
    let origin = vec3<f32>(scene_p.x, scene_p.y + frame.camera_position.y - 63.0, scene_p.z) * clouds_scale
        + vec3<f32>(0.0, planet_radius, 0.0);

    var shadow = 1.0;
    var shadow_cu = 1.0;
    let dist_fade_strength = 0.00000001 * pulse(ld.y, -0.01, 0.2);

    if clouds_cumulus && cp.coverage.y > eps {
        let ext = 0.25 * cp.extinction;
        let t = intersect_sphere_ray(origin, ld, cumulus_radius() + 0.25 * clouds_cumulus_thickness).y;
        if t > 0.0 {
            let pos = origin + ld * t;
            let df = exp2(-dist_fade_strength * length(pos.xz));
            let d = cumulus_density(pos, false);
            shadow *= exp(-df * ext * clouds_cumulus_thickness / (abs(ld.y) + eps) * d);
            shadow_cu = shadow;
        }
        if clouds_quality >= 1u && cp.l1_coverage.y > eps {
            let ext_ac = mix(0.05, 0.1, day_factor()) * clouds_altocumulus_density_scale * (1.0 - 0.33 * frame.rain);
            let t_ac = intersect_sphere_ray(origin, ld, altocumulus_radius() + 0.5 * clouds_altocumulus_thickness).y;
            if t_ac > 0.0 {
                let pos_ac = origin + ld * t_ac;
                let df_ac = exp2(-dist_fade_strength * length(pos_ac.xz));
                let d_ac = altocumulus_density(pos_ac, false);
                shadow *= exp(-df_ac * ext_ac * clouds_altocumulus_thickness / (abs(ld.y) + eps) * d_ac);
            }
        }
    }

    textureStore(cloud_shadow_tex, texel, vec4<f32>(shadow, shadow_cu, 0.0, 1.0));
}
