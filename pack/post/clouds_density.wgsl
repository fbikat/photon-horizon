// Shared cloud shaping, weather parameters, and 3D/2D densities for clouds and before_world cloud shadows

const clouds_scale: f32 = 10.0;
const clouds_cumulus_thickness: f32 = 1200.0;
const clouds_altocumulus_altitude: f32 = 3200.0;
const clouds_altocumulus_thickness: f32 = 480.0;
// photon: altitude 400, thickness 400 * 32 (CLOUDS_CUMULUS_CONGESTUS_THICKNESS)
const clouds_congestus_altitude: f32 = 400.0;
const clouds_congestus_thickness: f32 = 12800.0;
const clouds_cirrus_altitude: f32 = 6000.0;
const clouds_cirrus_thickness: f32 = 1500.0;
const clouds_noctilucent_altitude: f32 = 80000.0;
// photon's CLOUDS_ALTOCUMULUS_DENSITY
const clouds_altocumulus_density_scale: f32 = 0.10;

// 30 deg cumulus wind (25 m/s * (cos 30, sin 30)), 60 deg altocumulus wind (25 m/s), 90 deg cirrus (40 m/s)
const clouds_wind_vel = vec2<f32>(21.650635, 12.5);
const clouds_ac_wind_vel = vec2<f32>(12.5, 21.650635);
const clouds_cirrus_wind = vec2<f32>(0.0, 40.0);

struct CloudsParams {
    stratus_blend: f32,
    coverage: vec2<f32>,
    detail_weights: vec2<f32>,
    edge_sharpening: vec2<f32>,
    altitude_scale: f32,
    extinction: f32,
    scattering: f32,
    l1_stratus_blend: f32,
    l1_coverage: vec2<f32>,
    congestus_blend: f32,
    cirrus_amount: f32,
    cirrocumulus_amount: f32,
    crepuscular_amount: f32,
    noctilucent_amount: f32,
    l0_shadow: f32,
}

var<private> cp: CloudsParams;

fn cumulus_radius() -> f32 { return planet_radius + clouds_cumulus_altitude; }
fn altocumulus_radius() -> f32 { return planet_radius + clouds_altocumulus_altitude; }
fn congestus_radius() -> f32 { return planet_radius + clouds_congestus_altitude; }
fn cirrus_radius() -> f32 { return planet_radius + clouds_cirrus_altitude; }
fn noctilucent_radius() -> f32 { return planet_radius + clouds_noctilucent_altitude; }

// photon's include/weather/clouds.glsl get_clouds_parameters
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

    // Cumulus congestus when hot, humid, windy, and not solid overcast
    let cong_t = linear_step(0.5, 1.0, w.temperature);
    let cong_h = linear_step(0.3, 0.9, w.humidity);
    let cong_w = sqr(w.wind);
    let l0_high = linear_step(0.45, 0.5, dot(p.coverage, vec2<f32>(0.66, 0.33)));
    p.congestus_blend = clamp01(1.5 * dampen(dampen(cong_t * cong_h * cong_w)) * (1.0 - l0_high));

    let torn = linear_step(0.66, 0.9, w.wind) * (1.0 - p.stratus_blend);
    p.detail_weights = mix(vec2<f32>(0.33, 0.40) * (1.0 + 0.5 * torn), vec2<f32>(0.07, 0.10),
        vec2<f32>(sqr(p.stratus_blend), p.stratus_blend));
    p.edge_sharpening = mix(vec2<f32>(3.0, 12.0), vec2<f32>(2.0, 7.0), sqr(p.stratus_blend));
    let dynamic_thickness = mix(0.5, 1.0, smoothstep(0.4, 0.6, dot(p.coverage, vec2<f32>(0.25, 0.75))));
    p.altitude_scale = 0.8 / (dynamic_thickness * clouds_cumulus_thickness);

    // Altocumulus / Altostratus parameters (layer 1)
    p.l1_stratus_blend = cubic_smooth(linear_step(0.5, 0.66, 1.0 - w.temperature));
    let cov_ac = (linear_step(0.4, 1.0, w.humidity) * 0.5 + 0.5)
        * linear_step(0.4, 0.66, w.wind) * linear_step(1.0, 0.8, w.temperature) * vec2<f32>(0.5, 1.5);
    let cov_as = vec2<f32>(linear_step(0.25, 0.45, w.wind * w.humidity));
    p.l1_coverage = clamp(mix(cov_ac, cov_as, p.l1_stratus_blend), vec2<f32>(0.0), vec2<f32>(1.0)) * clouds_cumulus_coverage;

    let l0_shadow = linear_step(0.7, 1.0, dot(p.l1_coverage, vec2<f32>(0.25, 0.75)) * (1.0 + p.l1_stratus_blend)) * dampen(day_factor());
    p.l0_shadow = l0_shadow;
    var ext = mix(0.05, 0.1, smoothstep(0.0, 0.3, abs(frame.sun_direction.y)))
        * (1.0 - 0.33 * frame.rain) * (1.0 - 0.6 * l0_shadow) * clouds_cumulus_density;
    ext *= 1.0 - 0.4 * linear_step(0.8, 1.0, p.coverage.y - p.coverage.y * p.stratus_blend);
    ext *= 1.0 - 0.5 * p.stratus_blend;
    p.extinction = ext;
    p.scattering = ext * mix(1.0, 0.66, frame.rain);

    let ct = 0.6 - 0.4 * sqr(linear_step(0.5, 0.9, w.temperature)) + 0.4 * (1.0 - linear_step(0.0, 0.2, w.temperature));
    let ch = 1.0 - 0.5 * linear_step(0.5, 0.75, w.humidity);
    p.cirrus_amount = clamp01(0.5 * ct * ch + 0.5 * frame.rain) * clouds_cirrus_coverage;
    // photon's clouds_cirrocumulus_amount: the small high puffs, with wind, more when humid, less when hot
    let cc_t = 1.0 - 0.3 * linear_step(0.5, 1.0, w.temperature);
    let cc_h = 0.5 + 0.5 * linear_step(0.4, 1.0, w.humidity);
    p.cirrocumulus_amount = 0.8 * dampen(cc_t * cc_h * pow1d5(w.wind)) * clouds_cirrus_coverage;

    p.crepuscular_amount = dampen(clamp01(2.0 * w.humidity))
        * linear_step(0.45, 0.7, (1.0 + 0.2 * sqr(p.stratus_blend)) * dot(p.coverage, vec2<f32>(0.66, 0.33)) + 0.09 * p.l1_coverage.y);

    // Noctilucent: visible subtly on some twilight evenings
    let noct_hash = hash1(floor(world_age() / 1200.0) * golden_ratio + 0.37);
    p.noctilucent_amount = dampen(linear_step(0.7, 1.0, noct_hash)) * clouds_cirrus_coverage;
    return p;
}

// photon's 3-d worley volumes, baked as 8x8 tiles of 66x66 (.r = bubbly, .g = swirley)
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
    let wind_velocity = clouds_wind_vel;
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

fn cumulus_density(pos0: vec3<f32>, detailed: bool) -> f32 {
    let r = length(pos0);
    if r < cumulus_radius() || r > cumulus_radius() + clouds_cumulus_thickness {
        return 0.0;
    }
    let af = (r - cumulus_radius()) * cp.altitude_scale;
    if af >= 1.0 {
        return 0.0;
    }
    var density = cumulus_altitude_shaping(cumulus_local_coverage(pos0.xz), af);
    if density < eps {
        return 0.0;
    }
    let wind_velocity = clouds_wind_vel;
    var pos = pos0;
    pos.x += frame.camera_position.x * clouds_scale + wind_velocity.x * world_age();
    pos.z += frame.camera_position.z * clouds_scale + wind_velocity.y * world_age();

    var w0 = 0.5;
    var w1 = 0.5;
    if detailed {
        let wind = vec3<f32>(wind_velocity.x * world_age(), 0.0, wind_velocity.y * world_age());
        let a = worley3d((pos + 0.2 * wind) * 0.0009);
        let b = worley3d((pos + 0.4 * wind) * 0.005);
        w0 = a.r;
        w1 = b.g;
    }
    // photon's cumulus.glsl: both worley layers squared, the second faded with the altitude
    let fade = 0.20 * smoothstep(0.85, 1.0, 1.0 - af) - 0.35 * smoothstep(0.05, 0.5, af) + 0.6;
    density -= cp.detail_weights.x * sqr(w0) * dampen(clamp01(1.0 - density));
    density -= cp.detail_weights.y * sqr(w1) * dampen(clamp01(1.0 - density)) * fade;
    density = max0(density);
    density = lift(clamp01(density), mix(cp.edge_sharpening.x, cp.edge_sharpening.y, af));
    density *= 0.1 + 0.9 * smoothstep(0.2, 0.7, af);
    return density;
}

fn altocumulus_density(pos0: vec3<f32>, detailed: bool) -> f32 {
    let r = length(pos0);
    if r < altocumulus_radius() || r > altocumulus_radius() + clouds_altocumulus_thickness {
        return 0.0;
    }
    let dyn_thick = mix(0.5, 1.0, smoothstep(0.4, 0.6, cp.l1_coverage.y));
    let af = 0.8 * (r - altocumulus_radius()) / (clouds_altocumulus_thickness * dyn_thick);
    if af >= 1.0 {
        return 0.0;
    }
    let wind_vel = clouds_ac_wind_vel;
    let pos_xz = pos0.xz + frame.camera_position.xz * clouds_scale + wind_vel * world_age();
    let nx = textureSampleLevel(noisetex, noisetex_sampler, 0.000005 * pos_xz + 0.01, 0.0).x;
    let nw = textureSampleLevel(noisetex, noisetex_sampler, 0.000047 * pos_xz + 0.30, 0.0).w;
    let nd = textureSampleLevel(noisetex, noisetex_sampler, 0.000100 * pos_xz + 0.60, 0.0).w;

    var d_ac = mix(cp.l1_coverage.x, cp.l1_coverage.y, dampen(nx));
    d_ac = linear_step(sqr(1.0 - d_ac), 1.0, nw);
    d_ac -= 1.9 * sqr(1.0 - nd) * dampen(clamp01(1.0 - d_ac));
    d_ac -= smoothstep(0.2, 1.0, af) * 0.6;
    d_ac *= smoothstep(0.0, 0.2, af);

    var d_as = cubic_smooth(linear_step(0.9 - cp.l1_coverage.x, 1.0, 2.0 * nx * cp.l1_coverage.y));
    d_as = 0.5 * d_as + d_as * linear_step(0.3, 0.6, nw);
    d_as = 0.5 * d_as + d_as * linear_step(0.3, 0.7, nd);
    d_as = d_as / (d_as + 1.0);
    d_as *= dampen(clamp01(2.0 * af) * linear_step(0.0, 0.1, af) * linear_step(0.0, 0.6, 1.0 - af));
    var density = mix(d_ac, clamp01(d_as), cp.l1_stratus_blend);
    if density < eps {
        return 0.0;
    }
    var w = 0.5;
    if detailed {
        let wind = vec3<f32>(wind_vel.x * world_age(), 0.0, wind_vel.y * world_age());
        let pos3 = vec3<f32>(pos_xz.x, pos0.y, pos_xz.y);
        w = worley3d((pos3 + 0.2 * wind) * 0.003).g;
    }
    // CLOUDS_ALTOCUMULUS_DETAIL_STRENGTH 1.5
    density -= 0.2 * 1.5 * sqr(w) * dampen(clamp01(1.0 - density)) * (1.0 - 0.85 * cp.l1_stratus_blend);
    let sharp = mix(vec2<f32>(3.0, 14.0), vec2<f32>(2.0, 7.0), cp.l1_stratus_blend);
    density = max0(density);
    density = lift(density, mix(sharp.x, sharp.y, af));
    density *= 0.1 + 0.9 * smoothstep(0.2, 0.7, af);
    return density;
}

fn congestus_density(pos0: vec3<f32>, detailed: bool) -> f32 {
    let r = length(pos0);
    if r < congestus_radius() || r > congestus_radius() + clouds_congestus_thickness {
        return 0.0;
    }
    let af = (r - congestus_radius()) / clouds_congestus_thickness;
    let dist_f = linear_step(30000.0, 50000.0, length(pos0.xz));
    let wind_vel = clouds_wind_vel;
    let pxz = pos0.xz + frame.camera_position.xz * clouds_scale + wind_vel * (world_age() + 50.0 * sqr(af));
    let n = textureSampleLevel(noisetex, noisetex_sampler, 0.000003 * pxz, 0.0).w;
    var density = 1.5 * sqr(linear_step(0.75 - 0.15 * clamp01(cp.congestus_blend * clouds_cumulus_coverage), 1.0, sqrt(n)));
    density -= sqr(linear_step(0.3, 1.0, af)) * clamp01(1.0 - 0.2 * cp.congestus_blend);
    density *= smoothstep(0.0, 0.1, af) * smoothstep(0.0, 0.1, 1.0 - af);
    density *= 4.0 * dist_f * (1.0 - dist_f) * linear_step(0.0, 0.3, cp.congestus_blend);
    if density < eps {
        return 0.0;
    }
    var w0 = 0.5;
    var w1 = 0.5;
    if detailed {
        let wind = vec3<f32>(wind_vel.x * world_age(), 0.0, wind_vel.y * world_age());
        let p3 = vec3<f32>(pos0.x + frame.camera_position.x * clouds_scale, pos0.y, pos0.z + frame.camera_position.z * clouds_scale);
        w0 = worley3d((p3 + 0.2 * wind) * 0.00005).g;
        w1 = worley3d((p3 + 0.4 * wind) * 0.00023).g;
    }
    let fade = 0.20 * smoothstep(0.85, 1.0, 1.0 - af) - 0.35 * smoothstep(0.05, 0.5, af) + 0.8;
    density -= 7.0 * sqr(clamp01(1.0 - density)) * cube(w0) * sqr(af);
    density -= 0.2 * sqr(w1) * dampen(clamp01(1.0 - density)) * dampen(dampen(clamp01(fade + 0.5 * sqr(af))));
    density = max0(density);
    density = lift(clamp01(density), mix(2.0, 10.0, af));
    density *= sqr(linear_step(0.0, 0.5, af));
    return density;
}
