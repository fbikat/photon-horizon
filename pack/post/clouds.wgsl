// photon's d1_clouds + aurora + crepuscular rays:
// Cumulus, Altocumulus, Cumulus Congestus, Cirrus, Noctilucent, Aurora, Crepuscular Rays

var<private> AURORA_BOT: array<vec3<f32>, 13> = array<vec3<f32>, 13>(
    vec3<f32>(0.00, 1.00, 0.25),
    vec3<f32>(0.00, 1.00, 0.25),
    vec3<f32>(1.00, 0.00, 0.00),
    vec3<f32>(1.00, 0.25, 1.00),
    vec3<f32>(1.00, 0.50, 1.00),
    vec3<f32>(1.00, 0.50, 1.00),
    vec3<f32>(1.00, 0.10, 0.00),
    vec3<f32>(1.00, 1.00, 1.00),
    vec3<f32>(1.00, 1.00, 0.00),
    vec3<f32>(1.00, 0.25, 1.00),
    vec3<f32>(1.20, 0.84, 1.20),
    vec3<f32>(0.00, 1.00, 0.25),
    vec3<f32>(2.00, 0.80, 0.00),
);
var<private> AURORA_TOP: array<vec3<f32>, 13> = array<vec3<f32>, 13>(
    vec3<f32>(0.50, 0.70, 1.00),
    vec3<f32>(0.50, 0.70, 1.00),
    vec3<f32>(1.00, 0.50, 0.70),
    vec3<f32>(0.25, 0.25, 1.00),
    vec3<f32>(0.50, 0.70, 1.00),
    vec3<f32>(0.50, 0.70, 1.00),
    vec3<f32>(1.00, 1.00, 0.25),
    vec3<f32>(1.00, 0.00, 0.00),
    vec3<f32>(0.10, 0.50, 1.00),
    vec3<f32>(0.00, 1.00, 0.25),
    vec3<f32>(0.90, 0.30, 0.90),
    vec3<f32>(0.90, 0.30, 0.90),
    vec3<f32>(1.00, 0.50, 0.00),
);

struct CloudsResult {
    scattering: vec3<f32>,
    transmittance: f32,
    apparent_distance: f32,
}

fn clouds_not_hit() -> CloudsResult {
    return CloudsResult(vec3<f32>(0.0), 1.0, 1e6);
}

fn blend_layers(old_layer: CloudsResult, new_layer: CloudsResult) -> CloudsResult {
    let new_in_front = new_layer.apparent_distance < old_layer.apparent_distance;
    let s_behind = select(new_layer.scattering, old_layer.scattering, new_in_front);
    let s_front = select(old_layer.scattering, new_layer.scattering, new_in_front);
    let t_front = select(old_layer.transmittance, new_layer.transmittance, new_in_front);
    return CloudsResult(
        s_front + t_front * s_behind,
        old_layer.transmittance * new_layer.transmittance,
        min(old_layer.apparent_distance, new_layer.apparent_distance),
    );
}

fn clouds_phase_single(c: f32) -> f32 {
    return 0.8 * max(klein_nishina_phase(c, 2600.0), henyey_greenstein_phase(c, 0.8))
        + 0.2 * henyey_greenstein_phase(c, -0.2);
}
fn clouds_phase_multi(c: f32, g: vec3<f32>) -> f32 {
    return 0.65 * henyey_greenstein_phase(c, g.x)
        + 0.10 * henyey_greenstein_phase(c, g.y)
        + 0.25 * henyey_greenstein_phase(c, -g.z);
}
fn clouds_powder(density: f32, c: f32) -> f32 {
    let powder = pi * density / (density + 0.15);
    return mix(powder, 1.0, 0.8 * sqr(c * 0.5 + 0.5));
}

fn clouds_aerial_perspective(s: vec3<f32>, clouds_t: f32, viewer: vec3<f32>, end: vec3<f32>, ray_dir: vec3<f32>, clear_sky: vec3<f32>) -> vec3<f32> {
    var air_t: vec3<f32>;
    if length_squared(viewer) < length_squared(end) {
        air_t = clamp01v(atmosphere_transmittance_ray(viewer, ray_dir) / max(atmosphere_transmittance_ray(end, ray_dir), vec3<f32>(1e-6)));
    } else {
        air_t = clamp01v(atmosphere_transmittance_ray(end, -ray_dir) / max(atmosphere_transmittance_ray(viewer, -ray_dir), vec3<f32>(1e-6)));
    }
    let sky = mix(clear_sky, get_sky_color() / tau, frame.rain);
    air_t = mix(air_t, vec3<f32>(air_t.x), 0.8 * frame.rain);
    return mix((1.0 - clouds_t) * sky, s, air_t);
}

fn cloud_multi_scattering(
    density: f32, light_od: f32, sky_od: f32, ground_od: f32,
    step_t: f32, c: f32, bounced: f32,
    scatter0: f32, extinct0: f32, falloff0: f32, od_scale: f32, ext_decay: f32, g_decay: f32, stratus_mul: f32,
) -> vec2<f32> {
    var s = vec2<f32>(0.0);
    var scatter = scatter0;
    var extinct = extinct0;
    let integral = (1.0 - step_t) / max(extinct0, eps);
    var powder = clouds_powder(density * stratus_mul, c);
    var phase = clouds_phase_single(c);
    var g = pow(vec3<f32>(0.6, 0.9, 0.3), vec3<f32>(1.0 + light_od));
    for (var i = 0u; i < 8u; i++) {
        s.x += scatter * exp(-extinct * light_od * od_scale) * phase;
        s.x += scatter * exp(-extinct * ground_od * od_scale) * isotropic_phase * bounced;
        s.y += scatter * exp(-extinct * sky_od * od_scale) * isotropic_phase;
        scatter *= falloff0 * powder;
        extinct *= ext_decay;
        g *= g_decay;
        powder = mix(powder, sqrt(powder), 0.5);
        phase = clouds_phase_multi(c, g);
    }
    return s * integral;
}

fn cumulus_optical_depth(origin: vec3<f32>, dir: vec3<f32>, dither: f32, steps: u32) -> f32 {
    let step_len = 0.25 * (1.0 + cp.stratus_blend) * clouds_cumulus_thickness / f32(steps);
    var pos = origin;
    var ray_step = vec4<f32>(dir, 1.0) * step_len;
    var od = 0.0;
    for (var i = 0u; i < steps; i++) {
        ray_step *= 2.0;
        od += cumulus_density(pos + ray_step.xyz * dither, true) * ray_step.w;
        pos += ray_step.xyz;
    }
    return od;
}

fn draw_cumulus(viewer: vec3<f32>, ray_dir: vec3<f32>, clear_sky: vec3<f32>, dist_terrain: f32, dither: f32) -> CloudsResult {
    if cp.coverage.y < eps || !clouds_cumulus {
        return clouds_not_hit();
    }
    var steps_h = array<u32, 3>(18u, 34u, 52u);
    var steps_z = array<u32, 3>(9u, 17u, 26u);
    let q = min(clouds_quality, 2u);
    let primary_steps = u32(mix(f32(steps_h[q]), f32(steps_z[q]), abs(ray_dir.y)));
    let max_ray_length = 2e4;
    let min_t = 0.075;
    let r = length(viewer);
    let dists = intersect_spherical_shell(viewer, ray_dir, cumulus_radius(), cumulus_radius() + clouds_cumulus_thickness);
    let planet_hit = intersect_sphere_ray(viewer, ray_dir, min(r - 10.0, planet_radius)).y >= 0.0;
    let terrain_hit = dist_terrain >= 0.0 && r < cumulus_radius() && dist_terrain < dists.x;
    if dists.y < 0.0 || (planet_hit && r < cumulus_radius()) || terrain_hit {
        return clouds_not_hit();
    }
    var ray_length = select(dists.y, dist_terrain, dist_terrain >= 0.0);
    ray_length = clamp(ray_length - dists.x, 0.0, max_ray_length);
    let step_length = ray_length / f32(primary_steps);
    let ray_step = ray_dir * step_length;
    let origin = viewer + ray_dir * (dists.x + step_length * dither);
    var scattering = vec2<f32>(0.0);
    var t = 1.0;
    var dist_sum = 0.0;
    var w_sum = 0.0;
    let moonlit = frame.sun_direction.y < -0.04;
    let ld = select(sun_dir(), moon_dir(), moonlit);
    let c = dot(ray_dir, ld);
    let bounced = 0.4 * ld.y * rcp_pi;
    let falloff = 0.55 * mix(lift(clamp01(cp.scattering / 0.1), 0.33), 1.0, c * 0.5 + 0.5);
    for (var i = 0u; i < primary_steps; i++) {
        if t < min_t {
            break;
        }
        let pos = origin + ray_step * f32(i);
        let af = (length(pos) - cumulus_radius()) / clouds_cumulus_thickness;
        var density = cumulus_density(pos, true);
        if density < eps {
            continue;
        }
        let d_sample = distance(origin, pos);
        density *= smoothstep(1.0, 0.95, d_sample / max_ray_length);
        let step_t = exp(-density * cp.extinction * step_length);
        let light_od = cumulus_optical_depth(pos, ld, dither, 5u);
        let sky_od = cumulus_optical_depth(pos, vec3<f32>(0.0, 1.0, 0.0), fract(dither + 0.5), 2u);
        let ground_od = mix(density, 1.0, clamp01(af * 2.0 - 1.0)) * af * clouds_cumulus_thickness;
        scattering += cloud_multi_scattering(density, light_od, sky_od, ground_od, step_t, c, bounced,
            cp.scattering, cp.extinction, falloff, 1.0, 0.4, 0.8, 1.0 + cp.stratus_blend) * t;
        t *= step_t;
        dist_sum += d_sample * density;
        w_sum += density;
    }
    var light_color = sunlight_color * atmosphere_transmittance_ray(origin, ld);
    light_color = atmosphere_post_processing(light_color) * select(sun_color(), moon_color(), moonlit);
    let clouds_t = linear_step(min_t, 1.0, t);
    var s = scattering.x * light_color + scattering.y * get_sky_color();
    s = clouds_aerial_perspective(s, clouds_t, viewer, origin, ray_dir, clear_sky);
    let app_dist = select((dist_sum / w_sum) + distance(viewer, origin), 1e6, w_sum == 0.0);
    return CloudsResult(s, clouds_t, app_dist);
}

fn altocumulus_optical_depth(origin: vec3<f32>, dir: vec3<f32>, dither: f32, steps: u32) -> f32 {
    let ts = get_times();
    let step_len = (0.25 + 0.25 * (ts.sunrise + ts.sunset)) * clouds_altocumulus_thickness / f32(steps);
    var pos = origin;
    var ray_step = vec4<f32>(dir, 1.0) * step_len;
    var od = 0.0;
    for (var i = 0u; i < steps; i++) {
        ray_step *= 2.0;
        od += altocumulus_density(pos + ray_step.xyz * dither, true) * ray_step.w;
        pos += ray_step.xyz;
    }
    return od;
}

fn draw_altocumulus(viewer: vec3<f32>, ray_dir: vec3<f32>, clear_sky: vec3<f32>, dist_terrain: f32, dither: f32) -> CloudsResult {
    if cp.l1_coverage.y < eps || !clouds_cumulus || clouds_quality < 1u {
        return clouds_not_hit();
    }
    let primary_steps = u32(mix(12.0, 7.0, abs(ray_dir.y)));
    let max_ray_length = 2e4;
    let min_t = 0.075;
    let r = length(viewer);
    let dists = intersect_spherical_shell(viewer, ray_dir, altocumulus_radius(), altocumulus_radius() + clouds_altocumulus_thickness);
    let planet_hit = intersect_sphere_ray(viewer, ray_dir, min(r - 10.0, planet_radius)).y >= 0.0;
    let terrain_hit = dist_terrain >= 0.0 && r < altocumulus_radius() && dist_terrain < dists.x;
    if dists.y < 0.0 || (planet_hit && r < altocumulus_radius()) || terrain_hit {
        return clouds_not_hit();
    }
    var ray_length = select(dists.y, dist_terrain, dist_terrain >= 0.0);
    ray_length = clamp(ray_length - dists.x, 0.0, max_ray_length);
    let step_length = ray_length / f32(primary_steps);
    let ray_step = ray_dir * step_length;
    let origin = viewer + ray_dir * (dists.x + step_length * dither);
    var scattering = vec2<f32>(0.0);
    var t = 1.0;
    var dist_sum = 0.0;
    var w_sum = 0.0;
    let ext_ac = mix(0.08, 0.16, day_factor()) * clouds_cumulus_density * (2.0 - cp.l1_stratus_blend);
    let sca_ac = ext_ac * mix(1.0, 0.75, frame.rain);
    let moonlit = frame.sun_direction.y < -0.045;
    let ld = select(sun_dir(), moon_dir(), moonlit);
    let c = dot(ray_dir, ld);
    let bounced = 0.4 * ld.y * rcp_pi;
    let falloff = 0.5 * mix(lift(clamp01(sca_ac / 0.05), 0.33), 1.0, c * 0.5 + 0.5);
    for (var i = 0u; i < primary_steps; i++) {
        if t < min_t {
            break;
        }
        let pos = origin + ray_step * f32(i);
        let af = (length(pos) - altocumulus_radius()) / clouds_altocumulus_thickness;
        var density = altocumulus_density(pos, true);
        if density < eps {
            continue;
        }
        let d_sample = distance(origin, pos);
        density *= smoothstep(1.0, 0.95, d_sample / max_ray_length);
        let step_t = exp(-density * ext_ac * step_length);
        let light_od = altocumulus_optical_depth(pos, ld, dither, 4u);
        let sky_od = altocumulus_optical_depth(pos, vec3<f32>(0.0, 1.0, 0.0), fract(dither + 0.5), 2u);
        let ground_od = mix(density, 1.0, clamp01(af * 2.0 - 1.0)) * af * clouds_altocumulus_thickness;
        scattering += cloud_multi_scattering(density, light_od, sky_od, ground_od, step_t, c, bounced,
            sca_ac, ext_ac, falloff, 1.0, 0.45, 0.7, 1.5 + 3.5 * cp.l1_stratus_blend) * t;
        t *= step_t;
        dist_sum += d_sample * density;
        w_sum += density;
    }
    var light_color = sunlight_color * atmosphere_transmittance_ray(origin, ld);
    light_color = atmosphere_post_processing(light_color) * select(sun_color(), moon_color(), moonlit);
    let high_cov = linear_step(0.5, 0.6, cp.l1_coverage.x);
    light_color *= 1.0 + 0.4 * high_cov * dampen(get_times().noon);
    let clouds_t = linear_step(min_t, 1.0, t);
    var s = scattering.x * light_color + scattering.y * get_sky_color();
    s = clouds_aerial_perspective(s, clouds_t, viewer, origin, ray_dir, clear_sky);
    let app_dist = select((dist_sum / w_sum) + distance(viewer, origin), 1e6, w_sum == 0.0);
    return CloudsResult(s, clouds_t, app_dist);
}

fn congestus_optical_depth(origin: vec3<f32>, dir: vec3<f32>, dither: f32, steps: u32) -> f32 {
    let step_len = 0.1 * clouds_congestus_thickness / f32(steps);
    var pos = origin;
    var ray_step = vec4<f32>(dir, 1.0) * step_len;
    var od = 0.0;
    for (var i = 0u; i < steps; i++) {
        ray_step *= 2.0;
        od += congestus_density(pos + ray_step.xyz * dither, true) * ray_step.w;
        pos += ray_step.xyz;
    }
    return od;
}

fn draw_congestus(viewer: vec3<f32>, ray_dir: vec3<f32>, clear_sky: vec3<f32>, dist_terrain: f32, dither: f32) -> CloudsResult {
    if !clouds_cumulus || clouds_quality < 2u || cp.congestus_blend < eps || dist_terrain >= 0.0 {
        return clouds_not_hit();
    }
    let primary_steps = 12u;
    let min_t = 0.075;
    let r = length(viewer);
    let sd = intersect_spherical_shell(viewer, ray_dir, congestus_radius(), congestus_radius() + clouds_congestus_thickness);
    // intersect cylindrical shell centered vertically (viewer xz = 0)
    let len_xz = max(length(ray_dir.xz), eps);
    let cd = vec2<f32>(30000.0, 50000.0) / len_xz;
    let dists = vec2<f32>(max(sd.x, cd.x), min(sd.y, cd.y));
    let planet_hit = intersect_sphere_ray(viewer, ray_dir, min(r - 10.0, planet_radius)).y >= 0.0;
    if dists.y < dists.x || (planet_hit && r < congestus_radius()) {
        return clouds_not_hit();
    }
    let ray_length = dists.y - dists.x;
    let step_length = ray_length / f32(primary_steps);
    let ray_step = ray_dir * step_length;
    let origin = viewer + ray_dir * (dists.x + step_length * dither);
    var scattering = vec2<f32>(0.0);
    var t = 1.0;
    var dist_sum = 0.0;
    var w_sum = 0.0;
    let ext_c = 0.08 * clouds_cumulus_density;
    let sca_c = ext_c * (1.0 - 0.2 * frame.rain);
    let moonlit = frame.sun_direction.y < -0.04;
    let ld = select(sun_dir(), moon_dir(), moonlit);
    let c = dot(ray_dir, ld);
    let bounced = 0.4 * ld.y * rcp_pi;
    let falloff = 0.55 * mix(lift(clamp01(sca_c / 0.1), 0.33), 1.0, c * 0.5 + 0.5);
    for (var i = 0u; i < primary_steps; i++) {
        if t < min_t {
            break;
        }
        let pos = origin + ray_step * f32(i);
        let af = (length(pos) - congestus_radius()) / clouds_congestus_thickness;
        let density = congestus_density(pos, true);
        if density < eps {
            continue;
        }
        let step_t = exp(-density * ext_c * step_length);
        let light_od = congestus_optical_depth(pos, ld, dither, 4u);
        let sky_od = congestus_optical_depth(pos, vec3<f32>(0.0, 1.0, 0.0), fract(dither + 0.5), 2u);
        let ground_od = mix(density, 1.0, clamp01(af * 2.0 - 1.0)) * af * clouds_congestus_thickness;
        scattering += cloud_multi_scattering(density, light_od, sky_od, ground_od, step_t, c, bounced,
            sca_c, ext_c, falloff, 0.33, 0.4, 0.5, 2.0) * t;
        t *= step_t;
        let d_sample = distance(origin, pos);
        dist_sum += d_sample * density;
        w_sum += density;
    }
    var light_color = sunlight_color * atmosphere_transmittance_ray(origin, ld);
    light_color = atmosphere_post_processing(light_color) * select(sun_color(), moon_color(), moonlit);
    let clouds_t = linear_step(min_t, 1.0, t);
    var s = scattering.x * light_color + scattering.y * get_sky_color();
    s = clouds_aerial_perspective(s, clouds_t, viewer, origin, ray_dir, clear_sky);
    let horizon_fade = mix(dampen(linear_step(0.0, 0.08, ray_dir.y)), 1.0,
        smoothstep(sqr(congestus_radius()), sqr(congestus_radius() + 0.1 * clouds_congestus_thickness), length_squared(viewer)));
    s = mix(clear_sky * (1.0 - clouds_t), s, horizon_fade);
    let app_dist = select((dist_sum / w_sum) + distance(viewer, origin), 1e6, w_sum == 0.0);
    return CloudsResult(s, clouds_t, app_dist);
}

fn perlin_gradient(coord: vec2<f32>) -> vec2<f32> {
    let i = floor(coord);
    let f = coord - i;
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    let g0 = hash2(i);
    let g1 = hash2(i + vec2<f32>(1.0, 0.0));
    let g2 = hash2(i + vec2<f32>(0.0, 1.0));
    let g3 = hash2(i + vec2<f32>(1.0, 1.0));
    let v0 = dot(g0, f);
    let v1 = dot(g1, f - vec2<f32>(1.0, 0.0));
    let v2 = dot(g2, f - vec2<f32>(0.0, 1.0));
    let v3 = dot(g3, f - vec2<f32>(1.0, 1.0));
    return g0 + u.x * (g1 - g0) + u.y * (g2 - g0) + u.x * u.y * (g0 - g1 - g2 + g3)
        + du * (u.yx * (v0 - v1 - v2 + v3) + vec2<f32>(v1, v2) - v0);
}
fn curl2d(coord: vec2<f32>) -> vec2<f32> {
    let g = perlin_gradient(coord);
    return vec2<f32>(g.y, -g.x);
}

fn cirrus_density(sphere_xz: vec2<f32>, af: f32) -> f32 {
    let age = world_age();
    let coord = sphere_xz + frame.camera_position.xz * clouds_scale + clouds_cirrus_wind * age;
    let curl = curl2d(0.00002 * coord) * 0.5 + curl2d(0.00004 * coord) * 0.25 + curl2d(0.00008 * coord) * 0.125;
    let height_shaping = 1.0 - abs(1.0 - 2.0 * af);
    var d = 0.7 * textureSampleLevel(noisetex, noisetex_sampler, 0.000001 * coord + 0.0032 * curl, 0.0).x
        + 0.3 * textureSampleLevel(noisetex, noisetex_sampler, 0.000008 * coord + 0.0064 * curl, 0.0).x;
    d = linear_step(0.7 - cp.cirrus_amount, 1.0, d);
    var detail_coord = coord;
    var amplitude = 0.2;
    var frequency = 0.00002;
    var curl_strength = 0.08;
    for (var i = 0; i < 4; i++) {
        let detail = textureSampleLevel(noisetex, noisetex_sampler, detail_coord * frequency + curl * curl_strength, 0.0).x;
        d -= detail * amplitude;
        amplitude *= 0.6;
        frequency *= 2.0;
        curl_strength *= 4.0;
        detail_coord += 0.3 * clouds_cirrus_wind * age;
    }
    return mix(1.0, 0.75, day_factor()) * cube(max0(d)) * sqr(height_shaping) * 0.5;
}

fn cirrus_optical_depth(origin: vec3<f32>, dir: vec3<f32>, dither: f32) -> f32 {
    let steps = 4u;
    let growth = 1.5;
    let inner = intersect_sphere_ray(origin, dir, cirrus_radius() - 0.5 * clouds_cirrus_thickness);
    let outer = intersect_sphere_ray(origin, dir, cirrus_radius() + 0.5 * clouds_cirrus_thickness);
    let ray_length = min(select(outer.y, inner.x, inner.y >= 0.0), 1e3);
    let coeff = (growth - 1.0) / (pow(growth, f32(steps)) - 1.0) / growth;
    var pos = origin;
    var stp = vec4<f32>(dir, 1.0) * ray_length * coeff;
    var od = 0.0;
    for (var i = 0u; i < steps; i++) {
        stp *= growth;
        let p = pos + stp.xyz * dither;
        let r = length(p);
        let af = (r - cirrus_radius()) / clouds_cirrus_thickness + 0.5;
        if af >= 0.0 && af <= 1.0 {
            let sp = p * (cirrus_radius() / r);
            od += cirrus_density(sp.xz, af) * stp.w;
        }
        pos += stp.xyz;
    }
    return od;
}

fn draw_cirrus(viewer: vec3<f32>, ray_dir: vec3<f32>, clear_sky: vec3<f32>, dither: f32) -> CloudsResult {
    if !clouds_cirrus || cp.cirrus_amount < eps {
        return clouds_not_hit();
    }
    let r = length(viewer);
    let dists = intersect_sphere_ray(viewer, ray_dir, cirrus_radius());
    let planet_hit = intersect_sphere_ray(viewer, ray_dir, min(r - 10.0, planet_radius)).y >= 0.0;
    if dists.y < 0.0 || (planet_hit && r < cirrus_radius()) {
        return clouds_not_hit();
    }
    let dist_s = select(dists.x, dists.y, r < cirrus_radius());
    let sphere_pos = viewer + ray_dir * dist_s;
    let moonlit = frame.sun_direction.y < -0.049;
    let ld = select(sun_dir(), moon_dir(), moonlit);
    let c = dot(ray_dir, ld);
    let density = cirrus_density(sphere_pos.xz, 0.5);
    if density < eps {
        return clouds_not_hit();
    }
    let light_od = cirrus_optical_depth(sphere_pos, ld, dither);
    let view_od = 0.5 * density * 0.15 * clouds_cirrus_thickness / (abs(ray_dir.y) + eps);
    let view_t = exp(-view_od);

    var s = vec2<f32>(0.0);
    var phase = clouds_phase_single(c);
    var g = vec3<f32>(0.6, 0.9, 0.3);
    var powder = 8.0 * (1.0 - exp(-40.0 * density));
    powder = mix(powder, 1.0, pow1d5(c * 0.5 + 0.5));
    var scatter = 0.15;
    var extinct = 0.15 * (1.0 + 0.5 * max0(smoothstep(0.0, 0.15, abs(frame.sun_direction.y)) - smoothstep(0.5, 0.7, cp.cirrus_amount)));
    for (var i = 0u; i < 4u; i++) {
        s.x += scatter * exp(-extinct * light_od) * phase * powder;
        s.y += scatter * exp(-0.33 * clouds_cirrus_thickness * extinct * density) * isotropic_phase;
        scatter *= 0.5;
        extinct *= 0.25;
        g *= 0.5;
        powder = mix(powder, sqrt(powder), 0.5);
        phase = clouds_phase_multi(c, g);
    }
    s *= (1.0 - view_t) / 0.15;

    var light_color = sunlight_color * atmosphere_transmittance_ray(sphere_pos, ld);
    light_color = atmosphere_post_processing(light_color) * select(sun_color(), moon_color(), moonlit);
    let sc = s.x * light_color + s.y * get_sky_color() * 1.41;
    let scattered = clouds_aerial_perspective(sc, view_t, viewer, sphere_pos, ray_dir, clear_sky);
    return CloudsResult(scattered, view_t, dist_s);
}

// Photon's noctilucent.glsl: high mesospheric twilight clouds
fn draw_noctilucent(viewer: vec3<f32>, ray_dir: vec3<f32>, clear_sky: vec3<f32>) -> CloudsResult {
    if !clouds_cirrus || clouds_quality < 1u || cp.noctilucent_amount < eps {
        return clouds_not_hit();
    }
    let vis = pulse(frame.sun_direction.y, -0.10, 0.10);
    if vis < eps {
        return clouds_not_hit();
    }
    let r = length(viewer);
    let dists = intersect_sphere_ray(viewer, ray_dir, noctilucent_radius());
    let planet_hit = intersect_sphere_ray(viewer, ray_dir, min(r - 10.0, planet_radius)).y >= 0.0;
    if dists.y < 0.0 || (planet_hit && r < noctilucent_radius()) {
        return clouds_not_hit();
    }
    let dist_s = select(dists.x, dists.y, r < cirrus_radius());
    let sphere_pos = viewer + ray_dir * dist_s;
    let coord = sphere_pos.xz * 0.25;
    let curl = curl2d(0.00002 * coord) * 0.5 + curl2d(0.00004 * coord) * 0.25 + curl2d(0.00008 * coord) * 0.125;
    var d = dampen(textureSampleLevel(noisetex, noisetex_sampler, 0.000001 * coord + 0.02 * curl, 0.0).y);
    var amp = 0.3;
    var freq = 0.00001;
    var c_str = 0.05;
    for (var i = 0; i < 4; i++) {
        d += textureSampleLevel(noisetex, noisetex_sampler, coord * freq + curl * c_str, 0.0).y * amp;
        amp *= 0.5;
        freq *= 1.5;
        c_str *= 4.0;
    }
    var hl = dampen(textureSampleLevel(noisetex, noisetex_sampler, 0.000004 * coord + 0.02 * curl, 0.0).y);
    hl -= (1.0 - textureSampleLevel(noisetex, noisetex_sampler, 0.000014 * coord + 0.05 * curl, 0.0).y) * 0.15;
    d += 2.0 * pow8(max0(hl));
    let density = sqr(max0(d)) * cp.noctilucent_amount;
    let trans = exp(-0.001 * density);
    let phase = henyey_greenstein_phase(dot(ray_dir, sun_dir()), 0.8);
    var sc = vis * (0.35 * vec3<f32>(1.5, 2.0, 9.0)) * density * phase;
    sc = clouds_aerial_perspective(sc, trans, viewer, sphere_pos, ray_dir, clear_sky);
    return CloudsResult(sc, trans, dist_s);
}

// Photon's sky/aurora.glsl: night-time northern lights curtain raymarch
fn draw_aurora(ray_dir: vec3<f32>, dither: f32) -> vec3<f32> {
    if aurora == 0u {
        return vec3<f32>(0.0);
    }
    let night = smoothstep(0.0, 0.2, -frame.sun_direction.y);
    let biome_mask = select(1.0, biome_may_snow(), aurora == 1u);
    let amount = night * biome_mask;
    if amount < 0.01 || ray_dir.y <= 0.01 {
        return vec3<f32>(0.0);
    }
    let bottom = 1000.0;
    let top = 3000.0;
    let radius = 20000.0;
    let rcp_y = 1.0 / ray_dir.y;
    let d_start = bottom * rcp_y;
    let d_end = min(radius / max(length(ray_dir.xz), eps), top * rcp_y);
    if d_start >= d_end {
        return vec3<f32>(0.0);
    }
    let steps = 40u;
    let step_len = (d_end - d_start) / f32(steps);
    var ray_pos = ray_dir * (d_start + step_len * dither);
    let ray_step = ray_dir * step_len;

    let pal_idx = u32(floor(frame.time / 240.0)) % 13u;
    let bot_c = AURORA_BOT[pal_idx] * rec709_to_rec2020;
    let top_c = AURORA_TOP[pal_idx] * rec709_to_rec2020;

    let w0 = 0.005 * vec2<f32>(0.7, 0.1) * frame.time;
    let w1 = 0.008 * vec2<f32>(-0.1, -0.7) * frame.time;
    var emission = vec3<f32>(0.0);
    for (var i = 0u; i < steps; i++) {
        let af = linear_step(bottom, top, ray_pos.y);
        let h_fade = cube(1.0 - af) * linear_step(0.0, 0.025, af);
        let a0 = textureSampleLevel(noisetex, noisetex_sampler, ray_pos.xz * 0.00003 + w0, 0.0).y;
        let a1 = textureSampleLevel(noisetex, noisetex_sampler, ray_pos.xz * 0.00003 + w1, 0.0).y;
        let shape = linear_step(1.0, 2.0, a0 + a1) * h_fade;
        let col = mix(bot_c, top_c, clamp01(dampen(af)));
        let d_xz = length(ray_pos.xz);
        let d_fade = (1.0 - cube(d_xz / radius)) * (1.0 - exp2(-0.001 * d_xz));
        emission += col * (shape * d_fade * step_len);
        ray_pos += ray_step;
    }
    return 0.001 * emission * amount;
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
        let cs = dot(textureSampleLevel(cloud_shadow_tex, linear_sampler, c_uv, 0.0).rg, vec2<f32>(0.5));
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

fn post(input: PostInput) -> vec4<f32> {
    if !in_overworld() || (!clouds_cumulus && !clouds_cirrus && aurora == 0u && !crepuscular_rays) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    cp = clouds_parameters(get_weather());
    let depth = depth_at(input.uv);
    let pos = view_position(input.uv, max(depth, 1e-7));
    let ray_dir = normalize(pos);
    let dist_terrain = select(length(pos) * clouds_scale, -1.0, depth <= 0.0);
    let viewer = vec3<f32>(0.0, clouds_scale * (frame.camera_position.y - 63.0) + planet_radius, 0.0);
    let dither = interleaved_gradient_noise(input.pixel + f32(frame.frame_index % 64u) * 5.588238);
    let clear_sky = atmosphere_scattering_both(ray_dir, sun_color(), moon_color());

    var res = draw_cumulus(viewer, ray_dir, clear_sky, dist_terrain, dither);
    let ac = draw_altocumulus(viewer, ray_dir, clear_sky, dist_terrain, dither);
    res = blend_layers(res, ac);
    if depth <= 0.0 {
        let cu_con = draw_congestus(viewer, ray_dir, clear_sky, dist_terrain, dither);
        if cp.congestus_blend > eps && clouds_quality >= 2u {
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

    let current = vec4<f32>(rec2020_to_linear(res.scattering), res.transmittance);

    // temporal accumulation in place of per-subpixel jitter on clouds
    let prev_clip = frame.previous_view_projection * vec4<f32>(ray_dir * 1e4, 1.0);
    let prev_uv = vec2<f32>(prev_clip.x / prev_clip.w * 0.5 + 0.5, 0.5 - prev_clip.y / prev_clip.w * 0.5);
    let on_screen = prev_clip.w > 0.0 && all(prev_uv >= vec2<f32>(0.0)) && all(prev_uv <= vec2<f32>(1.0));
    if !on_screen || frame.delta_time <= 0.0 || frame.reset_reasons != 0u || (depth > 0.0 && current.a >= 0.999) {
        return current;
    }
    let history = textureSampleLevel(clouds_tex_previous, linear_sampler, prev_uv, 0.0);
    let alpha_diff = abs(history.a - current.a);
    let blend = select(0.15, clamp(0.35 + alpha_diff * 0.65, 0.35, 1.0), depth > 0.0);
    return mix(history, current, blend);
}
