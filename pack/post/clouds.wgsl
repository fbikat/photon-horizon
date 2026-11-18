// photon's d1_clouds: the cumulus layer (include/sky/clouds/cumulus.glsl) and a cirrus sheet,
// raymarched at half resolution. rgb: scattering, a: transmittance

const clouds_scale: f32 = 10.0;
const clouds_cirrus_altitude: f32 = 6000.0;
// photon's 30 degree cloud wind angle
const clouds_wind_dir = vec2<f32>(0.8660254, 0.5);

struct CloudsParams {
    stratus_blend: f32,
    coverage: vec2<f32>,
    detail_weights: vec2<f32>,
    edge_sharpening: vec2<f32>,
    altitude_scale: f32,
    extinction: f32,
    scattering: f32,
    shadow: f32,
    cirrus_amount: f32,
}

var<private> cp: CloudsParams;

fn cumulus_radius() -> f32 { return planet_radius + clouds_cumulus_altitude; }
fn cumulus_thickness() -> f32 { return clouds_cumulus_altitude; }

// photon's include/weather/clouds.glsl get_clouds_parameters, layer 0 and cirrus
fn clouds_parameters(w: Weather) -> CloudsParams {
    var p: CloudsParams;
    let temp_w = dampen(linear_step(0.5, 1.0, 1.0 - w.temperature));
    p.stratus_blend = clamp01(temp_w * dampen(1.0 - w.wind));
    let temperature_weight = 1.0 - 0.15 * linear_step(0.6, 1.0, w.temperature);
    let humidity_weight = 0.4 * w.humidity + 0.5 * sqr(w.humidity);
    let stratus_sheet = sqr(p.stratus_blend);
    let local_variation = vec2<f32>(-0.1, 1.0) * (0.1 + 0.1 * w.wind);
    p.coverage = clamp(vec2<f32>(temperature_weight * humidity_weight) + local_variation + 0.3 * stratus_sheet,
        vec2<f32>(0.0), vec2<f32>(1.0)) * clouds_cumulus_coverage;
    let torn = linear_step(0.66, 0.9, w.wind) * (1.0 - p.stratus_blend);
    p.detail_weights = mix(vec2<f32>(0.33, 0.40) * (1.0 + 0.5 * torn), vec2<f32>(0.07, 0.10),
        vec2<f32>(sqr(p.stratus_blend), p.stratus_blend));
    p.edge_sharpening = mix(vec2<f32>(3.0, 12.0), vec2<f32>(2.0, 7.0), sqr(p.stratus_blend));
    let dynamic_thickness = mix(0.5, 1.0, smoothstep(0.4, 0.6, dot(p.coverage, vec2<f32>(0.25, 0.75))));
    p.altitude_scale = 0.8 / (dynamic_thickness * cumulus_thickness());
    p.shadow = 0.0;
    var ext = mix(0.05, 0.1, smoothstep(0.0, 0.3, abs(frame.sun_direction.y)))
        * (1.0 - 0.33 * frame.rain) * clouds_cumulus_density;
    ext *= 1.0 - 0.4 * linear_step(0.8, 1.0, p.coverage.y - p.coverage.y * p.stratus_blend);
    ext *= 1.0 - 0.5 * p.stratus_blend;
    p.extinction = ext;
    p.scattering = ext * mix(1.0, 0.66, frame.rain);
    let ct = 0.6 - 0.4 * sqr(linear_step(0.5, 0.9, w.temperature)) + 0.4 * (1.0 - linear_step(0.0, 0.2, w.temperature));
    let ch = 1.0 - 0.5 * linear_step(0.5, 0.75, w.humidity);
    p.cirrus_amount = clamp01(0.5 * ct * ch + 0.5 * frame.rain) * clouds_cirrus_coverage;
    return p;
}

// photon's 3-d worley volumes, baked as 8x8 tiles of 66x66 (a texel of wrapped border each)
fn worley_slice(xy: vec2<f32>, z: u32) -> vec2<f32> {
    let tile = vec2<f32>(f32(z % 8u), f32(z / 8u)) * 66.0;
    let p = tile + 1.0 + fract(xy) * 64.0;
    return textureSampleLevel(worley, worley_sampler, p / 528.0, 0.0).rg;
}
fn worley3d(p: vec3<f32>) -> vec2<f32> {
    let z = fract(p.z) * 64.0 - 0.5;
    let zf = floor(z);
    let z0 = u32(i32(zf) & 63);
    let z1 = (z0 + 1u) & 63u;
    return mix(worley_slice(p.xy, z0), worley_slice(p.xy, z1), z - zf);
}

fn cumulus_local_coverage(pos0: vec2<f32>) -> f32 {
    let wind_velocity = clouds_wind_speed * clouds_wind_dir;
    let pos = pos0 + frame.camera_position.xz * clouds_scale + wind_velocity * world_age();
    let p1 = 0.000002 * pos;
    let p2 = 0.000027 * pos;
    let nx = textureSampleLevel(noisetex, noisetex_sampler, p1, 0.0).x;
    let nw = textureSampleLevel(noisetex, noisetex_sampler, p2, 0.0).w;
    var cu = 0.0;
    var st = 0.0;
    if cp.stratus_blend < 1.0 - eps {
        cu = mix(cp.coverage.x, cp.coverage.y, nx);
        cu = linear_step(1.0 - cu, 1.0, nw);
    }
    if cp.stratus_blend > eps {
        st = cubic_smooth(linear_step(0.9 - cp.coverage.x, 1.0, 2.0 * nx * cp.coverage.y));
        st = 0.5 * st + st * linear_step(0.3, 0.6, nw);
        st = st / (st + 1.0);
    }
    return mix(cu, st, cp.stratus_blend);
}

fn cumulus_altitude_shaping(density0: f32, af: f32) -> f32 {
    var density = density0;
    if cp.stratus_blend > eps {
        density = mix(density, clamp01(density * dampen(clamp01(2.0 * af) * linear_step(0.0, 0.1, af)
            * linear_step(0.0, 0.6, 1.0 - af))), cp.stratus_blend);
    }
    density -= smoothstep(0.2, 1.0, af) * (0.6 - 0.3 * cp.stratus_blend);
    density *= smoothstep(0.0, 0.2, af);
    return density;
}

fn cumulus_density(pos0: vec3<f32>) -> f32 {
    let r = length(pos0);
    if r < cumulus_radius() || r > cumulus_radius() + cumulus_thickness() {
        return 0.0;
    }
    var density = cumulus_local_coverage(pos0.xz);
    let af = (r - cumulus_radius()) * cp.altitude_scale;
    density = cumulus_altitude_shaping(density, af);
    if density < eps {
        return 0.0;
    }
    let wind_velocity = clouds_wind_speed * clouds_wind_dir;
    let wind = vec3<f32>(wind_velocity.x, 0.0, wind_velocity.y) * world_age();
    var pos = pos0;
    pos = vec3<f32>(pos.x + frame.camera_position.x * clouds_scale + wind.x, pos.y,
        pos.z + frame.camera_position.z * clouds_scale + wind.z);
    // keep the noise coordinates small: the volumes repeat anyway
    let w0 = worley3d(fract((pos + 0.2 * wind) * 0.0009)).x;
    let w1 = worley3d(fract((pos + 0.4 * wind) * 0.005)).y;
    let detail_fade = 0.20 * smoothstep(0.85, 1.0, 1.0 - af) - 0.35 * smoothstep(0.05, 0.5, af) + 0.6;
    density -= cp.detail_weights.x * sqr(w0) * dampen(clamp01(1.0 - density));
    density -= cp.detail_weights.y * sqr(w1) * dampen(clamp01(1.0 - density)) * detail_fade;
    density = max0(density);
    density = lift(density, mix(cp.edge_sharpening.x, cp.edge_sharpening.y, af));
    density *= 0.1 + 0.9 * smoothstep(0.2, 0.7, af);
    return density;
}

fn cumulus_optical_depth(origin: vec3<f32>, dir: vec3<f32>, dither: f32, steps: u32) -> f32 {
    let step_length = 0.1 * cumulus_thickness() / f32(steps);
    var pos = origin;
    var stp = vec4<f32>(dir, 1.0) * step_length;
    var od = 0.0;
    for (var i = 0u; i < steps; i++) {
        stp *= 2.0;
        od += cumulus_density(pos + stp.xyz * dither) * stp.w;
        pos += stp.xyz;
    }
    return od;
}

fn clouds_phase_single(c: f32) -> f32 {
    let a = klein_nishina_phase(c, 2600.0);
    let b = henyey_greenstein_phase(c, 0.8);
    return 0.8 * max(a, b) + 0.2 * henyey_greenstein_phase(c, -0.2);
}
fn clouds_phase_multi(c: f32, g: vec3<f32>) -> f32 {
    return 0.65 * henyey_greenstein_phase(c, g.x) + 0.10 * henyey_greenstein_phase(c, g.y)
        + 0.25 * henyey_greenstein_phase(c, -g.z);
}
fn clouds_powder(density: f32, c: f32) -> f32 {
    let powder = pi * density / (density + 0.15);
    return mix(powder, 1.0, 0.8 * sqr(c * 0.5 + 0.5));
}

fn cumulus_scattering(density: f32, light_od: f32, sky_od: f32, ground_od: f32, step_t: f32, c: f32, bounced: f32) -> vec2<f32> {
    var s = vec2<f32>(0.0);
    var scatter = cp.scattering;
    var extinct = cp.extinction;
    let integral = (1.0 - step_t) / cp.extinction;
    var powder = clouds_powder(density + density * cp.stratus_blend, c);
    let falloff = 0.55 * mix(lift(clamp01(cp.scattering / 0.1), 0.33), 1.0, c * 0.5 + 0.5);
    var phase = clouds_phase_single(c);
    var g = pow(vec3<f32>(0.6, 0.9, 0.3), vec3<f32>(1.0 + light_od));
    for (var i = 0u; i < 8u; i++) {
        s.x += scatter * exp(-extinct * light_od) * phase;
        s.x += scatter * exp(-extinct * ground_od) * isotropic_phase * bounced;
        s.y += scatter * exp(-extinct * sky_od) * isotropic_phase;
        scatter *= falloff * powder;
        extinct *= 0.4;
        g *= 0.8;
        powder = mix(powder, sqrt(powder), 0.5);
        phase = clouds_phase_multi(c, g);
    }
    return s * integral;
}

struct CloudsResult {
    scattering: vec3<f32>,
    transmittance: f32,
}

fn draw_cumulus(viewer: vec3<f32>, ray_dir: vec3<f32>, clear_sky: vec3<f32>, dist_terrain: f32, dither: f32) -> CloudsResult {
    var res: CloudsResult;
    res.scattering = vec3<f32>(0.0);
    res.transmittance = 1.0;
    if cp.coverage.y < eps || !clouds_cumulus {
        return res;
    }
    var steps_h = array<u32, 3>(20u, 40u, 60u);
    var steps_z = array<u32, 3>(10u, 20u, 30u);
    let q = min(clouds_quality, 2u);
    let primary_steps = u32(mix(f32(steps_h[q]), f32(steps_z[q]), abs(ray_dir.y)));
    let max_ray_length = 2e4;
    let min_t = 0.075;
    let r = length(viewer);
    let dists = intersect_spherical_shell(viewer, ray_dir, cumulus_radius(), cumulus_radius() + cumulus_thickness());
    let planet_hit = intersect_sphere_ray(viewer, ray_dir, min(r - 10.0, planet_radius)).y >= 0.0;
    let terrain_hit = dist_terrain >= 0.0 && r < cumulus_radius() && dist_terrain < dists.x;
    if dists.y < 0.0 || (planet_hit && r < cumulus_radius()) || terrain_hit {
        return res;
    }
    var ray_length = select(dists.y, dist_terrain, dist_terrain >= 0.0);
    ray_length = clamp(ray_length - dists.x, 0.0, max_ray_length);
    let step_length = ray_length / f32(primary_steps);
    let ray_step = ray_dir * step_length;
    let origin = viewer + ray_dir * (dists.x + step_length * dither);
    var scattering = vec2<f32>(0.0);
    var t = 1.0;
    let moonlit = frame.sun_direction.y < -0.04;
    let ld = select(sun_dir(), moon_dir(), moonlit);
    let c = dot(ray_dir, ld);
    let bounced = 0.4 * ld.y * rcp_pi;
    for (var i = 0u; i < primary_steps; i++) {
        if t < min_t {
            break;
        }
        let pos = origin + ray_step * f32(i);
        let af = (length(pos) - cumulus_radius()) / cumulus_thickness();
        var density = cumulus_density(pos);
        if density < eps {
            continue;
        }
        density *= smoothstep(1.0, 0.95, distance(origin, pos) / max_ray_length);
        let step_od = density * cp.extinction * step_length;
        let step_t = exp(-step_od);
        let light_od = cumulus_optical_depth(pos, ld, dither, 6u);
        let sky_od = cumulus_optical_depth(pos, vec3<f32>(0.0, 1.0, 0.0), fract(dither + 0.5), 2u);
        let ground_od = mix(density, 1.0, clamp01(af * 2.0 - 1.0)) * af * cumulus_thickness();
        scattering += cumulus_scattering(density, light_od, sky_od, ground_od, step_t, c, bounced) * t;
        t *= step_t;
    }
    var light_color = sunlight_color * atmosphere_transmittance_ray(origin, ld);
    light_color = atmosphere_post_processing(light_color);
    light_color *= select(sun_color(), moon_color(), moonlit);
    let clouds_t = linear_step(min_t, 1.0, t);
    var s = scattering.x * light_color + scattering.y * get_sky_color();
    s = clouds_aerial_perspective(s, clouds_t, viewer, origin, ray_dir, clear_sky);
    res.scattering = s;
    res.transmittance = clouds_t;
    return res;
}

// photon's include/sky/clouds/cirrus.glsl (the cirrus part; cirrocumulus is not ported)
const clouds_cirrus_thickness: f32 = 1500.0;
// photon's 90 degree, 40 m/s cirrus wind
const clouds_cirrus_wind = vec2<f32>(0.0, 40.0);

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

fn cirrus_radius() -> f32 { return planet_radius + clouds_cirrus_altitude; }

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

fn draw_cirrus(viewer: vec3<f32>, ray_dir: vec3<f32>, clear_sky: vec3<f32>, dither: f32) -> CloudsResult {
    var res: CloudsResult;
    res.scattering = vec3<f32>(0.0);
    res.transmittance = 1.0;
    if !clouds_cirrus || cp.cirrus_amount < eps {
        return res;
    }
    let r = length(viewer);
    let dists = intersect_sphere_ray(viewer, ray_dir, cirrus_radius());
    let planet_hit = intersect_sphere_ray(viewer, ray_dir, min(r - 10.0, planet_radius)).y >= 0.0;
    if dists.y < 0.0 || (planet_hit && r < cirrus_radius()) {
        return res;
    }
    let sphere_pos = viewer + ray_dir * select(dists.x, dists.y, r < cirrus_radius());
    let moonlit = frame.sun_direction.y < -0.049;
    let ld = select(sun_dir(), moon_dir(), moonlit);
    let c = dot(ray_dir, ld);
    let density = cirrus_density(sphere_pos.xz, 0.5);
    if density < eps {
        return res;
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
    res.scattering = clouds_aerial_perspective(sc, view_t, viewer, sphere_pos, ray_dir, clear_sky);
    res.transmittance = view_t;
    return res;
}

fn post(input: PostInput) -> vec4<f32> {
    if !in_overworld() || (!clouds_cumulus && !clouds_cirrus) {
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

    let cu = draw_cumulus(viewer, ray_dir, clear_sky, dist_terrain, dither);
    var ci: CloudsResult;
    ci.scattering = vec3<f32>(0.0);
    ci.transmittance = 1.0;
    if depth <= 0.0 {
        ci = draw_cirrus(viewer, ray_dir, clear_sky, dither);
    }
    // the layer nearer the viewer lies in front
    var scattered: vec3<f32>;
    var transmittance: f32;
    if viewer.y > cirrus_radius() {
        scattered = ci.scattering + ci.transmittance * cu.scattering;
        transmittance = cu.transmittance * ci.transmittance;
    } else {
        scattered = cu.scattering + cu.transmittance * ci.scattering;
        transmittance = cu.transmittance * ci.transmittance;
    }
    let current = vec4<f32>(rec2020_to_linear(scattered), transmittance);

    // temporal accumulation in place of photon's taa: clouds are far, so reproject by direction
    let prev_clip = frame.previous_view_projection * vec4<f32>(ray_dir * 1e4, 1.0);
    let prev_uv = vec2<f32>(prev_clip.x / prev_clip.w * 0.5 + 0.5, 0.5 - prev_clip.y / prev_clip.w * 0.5);
    let on_screen = prev_clip.w > 0.0 && all(prev_uv >= vec2<f32>(0.0)) && all(prev_uv <= vec2<f32>(1.0));
    if !on_screen || frame.delta_time <= 0.0 || depth > 0.0 {
        return current;
    }
    let history = textureSampleLevel(clouds_hist, linear_sampler, prev_uv, 0.0);
    return mix(history, current, 0.15);
}
