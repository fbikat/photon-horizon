// Photon Shaders (c) 2021-2025 Benjamin Stott "SixthSurge", ported to Horizon's shader API.
// See LICENSE. The atmosphere mapping functions below come from Eric Bruneton's 2017 precomputed
// atmospheric scattering (BSD-3-Clause, copyright (c) 2017 Eric Bruneton, all rights reserved;
// redistributions must retain this notice and its disclaimer, see LICENSE).

const pi: f32 = 3.14159265359;
const tau: f32 = 6.28318530718;
const half_pi: f32 = 1.57079632679;
const rcp_pi: f32 = 0.31830988618;
const degree: f32 = 0.01745329252;
const golden_ratio: f32 = 1.61803398875;
const golden_angle: f32 = 2.39996322973;
const eps: f32 = 1e-6;
const isotropic_phase: f32 = 0.07957747155;

fn sqr(x: f32) -> f32 { return x * x; }
fn cube(x: f32) -> f32 { return x * x * x; }
fn pow4(x: f32) -> f32 { let y = x * x; return y * y; }
fn pow8(x: f32) -> f32 { let y = pow4(x); return y * y; }
fn pow12(x: f32) -> f32 { return pow8(x) * pow4(x); }
fn pow16(x: f32) -> f32 { let y = pow8(x); return y * y; }
fn pow1d5(x: f32) -> f32 { return x * sqrt(x); }
fn max0(x: f32) -> f32 { return max(x, 0.0); }
fn clamp01(x: f32) -> f32 { return clamp(x, 0.0, 1.0); }
fn clamp01v(x: vec3<f32>) -> vec3<f32> { return clamp(x, vec3<f32>(0.0), vec3<f32>(1.0)); }
fn max_of(v: vec3<f32>) -> f32 { return max(v.x, max(v.y, v.z)); }
fn min_of(v: vec3<f32>) -> f32 { return min(v.x, min(v.y, v.z)); }
fn linear_step(e0: f32, e1: f32, x: f32) -> f32 { return clamp01((x - e0) / (e1 - e0)); }
fn dampen(x0: f32) -> f32 { let x = clamp01(x0); return x * (2.0 - x); }
fn lift(x: f32, amount: f32) -> f32 { return (x + x * amount) / (1.0 + x * amount); }
fn cubic_smooth(x: f32) -> f32 { return x * x * (3.0 - 2.0 * x); }
fn pulse(x0: f32, center: f32, width: f32) -> f32 {
    let x = abs(x0 - center) / width;
    return select(1.0 - cubic_smooth(x), 0.0, x > 1.0);
}
fn pulse_periodic(x0: f32, center: f32, width: f32, period: f32) -> f32 {
    let x = (x0 - center + 0.5 * period) / period;
    return pulse(fract(x) * period - 0.5 * period, 0.0, width);
}
fn get_uv_from_unit_range(v: f32, res: f32) -> f32 { return v * (1.0 - 1.0 / res) + 0.5 / res; }
fn length_squared(v: vec3<f32>) -> f32 { return dot(v, v); }
fn fast_acos(x: f32) -> f32 { return acos(clamp(x, -1.0, 1.0)); }

// hashes from photon's random.glsl
fn hash1(p0: f32) -> f32 {
    var p = fract(p0 * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}
fn hash2(p: vec2<f32>) -> vec2<f32> {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * vec3<f32>(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}
fn hash4(p: vec2<f32>) -> vec4<f32> {
    var p4 = fract(vec4<f32>(p.x, p.y, p.x, p.y) * vec4<f32>(0.1031, 0.1030, 0.0973, 0.1099));
    p4 += dot(p4, p4.wzxy + 33.33);
    return fract((p4.xxyz + p4.yzzw) * p4.zywx);
}
fn noise_1d(x: f32) -> f32 {
    let i = floor(x);
    let f = cubic_smooth(x - i);
    return mix(hash1(i), hash1(i + 1.0), f);
}
fn interleaved_gradient_noise(pos: vec2<f32>) -> f32 {
    return fract(52.9829189 * fract(0.06711056 * pos.x + 0.00583715 * pos.y));
}
fn r1(n: u32, seed: f32) -> f32 { return fract(seed + f32(n % 4096u) * 0.61803398875); }
// Photon re-rolls its dither every frame because its TAA always averages it. Nothing does here (no TAA: Horizon
// has no projection jitter), and a per-frame dither in shadows and screen-space rays would show as crawling grain:
// the pattern stays still. (Passes with their own history use r1 over frame_index instead.)
fn temporal_noise_offset() -> f32 { return 0.0; }
// the auto exposure (EV) lives in a spare texel column of bloom_5, written by the bloom_mip5 pass
const EXPOSURE_TEXEL = vec2<i32>(120, 0);
// the frame's light and sky colours, once a frame in two corner texels of cloud_shadow_tex (written by
// the cloud shadow pass; the corners map hundreds of thousands of blocks out, where nothing samples)
const FRAME_LIGHT_TEXEL = vec2<i32>(511, 511);
const FRAME_SKY_TEXEL = vec2<i32>(510, 511);

// photon's SH_SKYLIGHT: the sky projected onto order-2 spherical harmonics once a frame, by the cloud shadow
// pass's corner workgroup, and kept in ten more corner texels: the 9 coefficients, then the irradiance facing up
const SKY_SH_UP: u32 = 9u;
// the biome categories of biome_weights_now, eased over time by the cloud shadow pass (Biomes.w0, then w1)
const BIOME_TEXEL_0 = vec2<i32>(506, 508);
const BIOME_TEXEL_1 = vec2<i32>(507, 508);
// photon's lightning flash (LIGHTNING_FLASH): x the sky's eased brightness, y the flash, 1 when vanilla's sky
// colour jumps toward its flash colour in a thunderstorm and fading over 0.75 s (by the cloud shadow pass)
const LIGHTNING_TEXEL = vec2<i32>(508, 508);
// photon's sky map (d0_sky_map, 191x108, Sebastien Hillaire's projection from "A Scalable and Production Ready
// Sky and Atmosphere Rendering Technique", section 5.3), here 192x96 in four 96x48 tiles in the corners of
// cloud_shadow_tex: the shadow map's mapping only reaches the circle inscribed in the texture, and a tile at each
// corner lies outside it (the SH and frame texels stay in the top right corner, above its tile). Every tile has
// a 1 texel border holding its neighbours' texels (azimuth wrapping, the poles' rows repeated), so one hardware
// bilinear read in a tile (sky_map_uv, in lighting.wgsl) does what four texel loads and weights would.
// Tile (tx, ty) covers sky map texels 96 tx .. 96 tx + 95, 48 ty .. 48 ty + 47; its 98x50 block of the texture
// starts at SKY_MAP_ORIGIN_X[tx], SKY_MAP_ORIGIN_Y[ty].
const SKY_MAP_W: i32 = 192;
const SKY_MAP_H: i32 = 96;
fn sky_map_origin(tile: vec2<i32>) -> vec2<i32> {
    return vec2<i32>(select(0, 414, tile.x == 1), select(0, 457, tile.y == 1));
}
fn is_sky_map_texel(t: vec2<i32>) -> bool {
    return (t.x < 98 || t.x >= 414) && (t.y < 50 || (t.y >= 457 && t.y < 507));
}
// the sky map texel a texel of a tile's block holds (its border included), the tile's own texels then
// those it copies
fn sky_map_index(t: vec2<i32>) -> vec2<i32> {
    let tile = vec2<i32>(select(0, 1, t.x >= 414), select(0, 1, t.y >= 457));
    let local = t - sky_map_origin(tile) - 1;
    let ix = ((tile.x * 96 + local.x) % SKY_MAP_W + SKY_MAP_W) % SKY_MAP_W;
    let iy = clamp(tile.y * 48 + local.y, 0, SKY_MAP_H - 1);
    return vec2<i32>(ix, iy);
}
// the sky map texel (ix, iy) as a texel of the texture, in the interior of its tile
fn sky_map_texel(ix: i32, iy: i32) -> vec2<i32> {
    let tile = vec2<i32>(ix / 96, iy / 48);
    return sky_map_origin(tile) + 1 + vec2<i32>(ix - tile.x * 96, iy - tile.y * 48);
}
// photon's unproject_sky for the centre of texel (ix, iy) (no azimuth padding: the tiles' borders wrap instead)
fn sky_map_dir(ix: i32, iy: i32) -> vec3<f32> {
    let c = (vec2<f32>(f32(ix), f32(iy)) + 0.5) / vec2<f32>(f32(SKY_MAP_W), f32(SKY_MAP_H));
    let y = select(-sqr(1.0 - 2.0 * c.y), sqr(2.0 * c.y - 1.0), c.y >= 0.5);
    let azimuth = c.x * tau - pi;
    let altitude = y * half_pi;
    return vec3<f32>(cos(altitude) * sin(azimuth), sin(altitude), -cos(altitude) * cos(azimuth));
}
// photon's project_sky: where direction d lies in the sky map, in texels (0..192, 0..96, texel i spanning i .. i + 1)
fn sky_map_coord(d: vec3<f32>) -> vec2<f32> {
    let xz = vec2<f32>(d.x, d.z);
    let proj = xz / max(length(xz), 1e-6);
    let azimuth = pi + atan2(proj.x, -proj.y);
    // acos by photon's fast_acos polynomial (error 7e-5): this runs per reflecting pixel
    let ay = min(abs(d.y), 1.0);
    let acos_abs = sqrt(1.0 - ay) * (1.5707288 + ay * (-0.2121144 + ay * (0.0742610 - 0.0187293 * ay)));
    let altitude = select(half_pi - acos_abs, acos_abs - half_pi, d.y < 0.0);
    let v = 0.5 + 0.5 * sign(altitude) * sqrt(2.0 * rcp_pi * abs(altitude));
    return vec2<f32>(azimuth / tau * f32(SKY_MAP_W), v * f32(SKY_MAP_H));
}
// the four texels (as texture coordinates) of a bilinear read at sky_map_coord(d), and their weights
struct SkyMapTaps {
    t00: vec2<i32>,
    t10: vec2<i32>,
    t01: vec2<i32>,
    t11: vec2<i32>,
    w: vec4<f32>,
}
fn sky_map_taps(d: vec3<f32>) -> SkyMapTaps {
    let p = sky_map_coord(d) - 0.5;
    let i = vec2<i32>(floor(p));
    let f = p - floor(p);
    let x0 = ((i.x % SKY_MAP_W) + SKY_MAP_W) % SKY_MAP_W;
    let x1 = (x0 + 1) % SKY_MAP_W;
    let y0 = clamp(i.y, 0, SKY_MAP_H - 1);
    let y1 = clamp(i.y + 1, 0, SKY_MAP_H - 1);
    return SkyMapTaps(
        sky_map_texel(x0, y0), sky_map_texel(x1, y0), sky_map_texel(x0, y1), sky_map_texel(x1, y1),
        vec4<f32>((1.0 - f.x) * (1.0 - f.y), f.x * (1.0 - f.y), (1.0 - f.x) * f.y, f.x * f.y),
    );
}
fn sky_sh_texel(i: u32) -> vec2<i32> { return vec2<i32>(504 + i32(i % 8u), 509 - i32(i / 8u)); }
fn is_sky_sh_texel(t: vec2<i32>) -> bool {
    return t.x >= 504 && (t.y == 509 || (t.y == 508 && t.x <= 505));
}
// photon's include/utility/spherical_harmonics.glsl basis, constants and band order as there
fn sh_basis(d: vec3<f32>) -> array<f32, 9> {
    return array<f32, 9>(
        0.2820947918,
        0.4886025119 * d.x,
        0.4886025119 * d.z,
        0.4886025119 * d.y,
        1.0925484310 * d.x * d.y,
        1.0925484310 * d.y * d.z,
        0.3153915653 * (3.0 * d.z * d.z - 1.0),
        0.7725484040 * d.x * d.z,
        0.3862742020 * (d.x * d.x - d.y * d.y),
    );
}
// the irradiance from coefficients `sh` on a face looking along n, with `visibility` of the sky (the cone
// photon takes for its GTAO's; "Practical Real-Time Strategies for Accurate Indirect Occlusion", section 5)
fn sh_irradiance(sh: array<vec3<f32>, 9>, n: vec3<f32>, visibility: f32) -> vec3<f32> {
    let sin_sq = clamp01(visibility);
    let cos_sq = 1.0 - sin_sq;
    let kernel = vec3<f32>(
        0.5 * sqrt(pi) * sin_sq,
        (sqrt(3.0 * pi) / 3.0) * (1.0 - cos_sq * sqrt(cos_sq)),
        (sqrt(5.0 * pi) / 16.0) * sin_sq * (2.0 + 6.0 * cos_sq),
    );
    let mul = sqrt(4.0 * pi / vec3<f32>(1.0, 3.0, 5.0)) * kernel;
    let b = sh_basis(n);
    let e = mul.x * b[0] * sh[0]
        + mul.y * (b[1] * sh[1] + b[2] * sh[2] + b[3] * sh[3])
        + mul.z * (b[4] * sh[4] + b[5] * sh[5] + b[6] * sh[6] + b[7] * sh[7] + b[8] * sh[8]);
    return max(e, vec3<f32>(0.0));
}
fn vogel_disc_sample(i: i32, count: i32, rotation: f32) -> vec2<f32> {
    let r = sqrt(f32(i) + 0.5) / sqrt(f32(count));
    let theta = f32(i) * 2.4 + rotation;
    return r * vec2<f32>(cos(theta), sin(theta));
}

// colour: photon works in linear rec.2020; matrices act as `v * m`, like photon's glsl
const rec709_to_rec2020 = mat3x3<f32>(
    vec3<f32>(0.6274257, 0.3292891, 0.0433502),
    vec3<f32>(0.0690274, 0.9195786, 0.0113614),
    vec3<f32>(0.0163664, 0.0880289, 0.8956843));
const rec2020_to_rec709 = mat3x3<f32>(
    vec3<f32>(1.6603441, -0.5875716, -0.0728802),
    vec3<f32>(-0.1243787, 1.1328371, -0.0083587),
    vec3<f32>(-0.0181127, -0.1005838, 1.1186213));
const rec2020_to_xyz = mat3x3<f32>(
    vec3<f32>(0.6369736, 0.1446172, 0.1688585),
    vec3<f32>(0.2627066, 0.6779996, 0.0592938),
    vec3<f32>(0.0, 0.0280728, 1.0608437));
const xyz_to_rec2020 = mat3x3<f32>(
    vec3<f32>(1.7166084, -0.3556621, -0.2533601),
    vec3<f32>(-0.6666829, 1.6164776, 0.0157685),
    vec3<f32>(0.0176422, -0.0427763, 0.94222867));
const luminance_weights = vec3<f32>(0.2627, 0.6780, 0.0593);
const luminance_weights_rec709 = vec3<f32>(0.2126, 0.7152, 0.0722);

fn srgb_eotf_inv(s: vec3<f32>) -> vec3<f32> { return s * (s * (s * 0.305306011 + 0.682171111) + 0.012522878); }
fn from_srgb(x: vec3<f32>) -> vec3<f32> { return pow(max(x, vec3<f32>(0.0)), vec3<f32>(2.2)) * rec709_to_rec2020; }
fn linear_to_rec2020(c: vec3<f32>) -> vec3<f32> { return max(c, vec3<f32>(0.0)) * rec709_to_rec2020; }
fn rec2020_to_linear(c: vec3<f32>) -> vec3<f32> { return max(c * rec2020_to_rec709, vec3<f32>(0.0)); }

fn blackbody(t: f32) -> vec3<f32> {
    let lambda = vec3<f32>(660.0, 550.0, 440.0);
    let lambda2 = lambda * lambda;
    let lambda5 = lambda2 * lambda2 * lambda;
    let h = 6.63e-16;
    let k = 1.38e-5;
    let c = 3.0e17;
    let a = lambda5 / (2.0 * h * c * c);
    let b = (h * c) / (k * lambda);
    let d = exp(b / t);
    let rgb = a * d - a;
    return min_of(rgb) / rgb;
}

// photon's custom uniforms (shaders.properties)
struct Times {
    sunrise: f32,
    noon: f32,
    sunset: f32,
    midnight: f32,
}
fn get_times() -> Times {
    let s = frame.sun_direction;
    let me_fade = select(1.7, 0.37 + 1.2 * max(0.0, -s.y), s.y < 0.18);
    let me_weight = sqr(clamp01(1.0 - me_fade * abs(s.y - 0.18)));
    var t: Times;
    t.sunrise = select(0.0, 1.0, s.x > 0.0) * me_weight;
    t.noon = select(0.0, 1.0, s.y > 0.0) * (1.0 - me_weight);
    t.midnight = select(0.0, 1.0, s.y < 0.0) * (1.0 - me_weight);
    t.sunset = select(0.0, 1.0, s.x < 0.0) * me_weight;
    return t;
}
fn is_night() -> bool { return frame.sun_direction.y < -0.0; }
fn sun_dir() -> vec3<f32> { return frame.sun_direction; }
fn moon_dir() -> vec3<f32> { return frame.moon_direction; }
fn light_dir() -> vec3<f32> { return select(frame.sun_direction, frame.moon_direction, is_night()); }
fn day_factor() -> f32 { return cubic_smooth(clamp01(abs(frame.sun_direction.y) / 0.3)); }
fn eye_skylight() -> f32 { return frame.eye_light_smooth.y; }
fn biome_cave() -> f32 {
    let altitude = frame.camera_position.y;
    return clamp01((63.0 - altitude) / 13.0) * (1.0 - frame.eye_light_smooth.y);
}
// Photon's world_age uniform: ((worldDay % 128) * 24000 + worldTime) / 20 seconds of game time (shaders.properties),
// which drives the weather noise, the cloud wind offsets and the noctilucent hash, so Java and this port agree
// on the clouds at the same world time and a restart does not change them. Horizon gives no world day, only
// the moon phase (day % 8, vanilla's) and the time of day (0 = vanilla's dayTime 0), so the day wraps every 8
// days here instead of 128: exact parity needs a world-day field from the engine. Time frozen (daylight cycle
// off) freezes the clouds, as in Java. Continuous animations Photon drives by frameTimeCounter (waves, ripples,
// aurora shimmer) stay on frame.time.
const WORLD_AGE_ON_GAME_TIME: bool = true;
fn world_age() -> f32 {
    if !WORLD_AGE_ON_GAME_TIME {
        return frame.time + frame.game_time * 1200.0;
    }
    return (f32(frame.moon_phase % 8u) * 24000.0 + frame.day_time * 24000.0) / 20.0;
}
fn biome_may_snow() -> f32 { return select(0.0, 1.0, frame.precipitation == 2u || frame.temperature < 0.15); }
fn in_overworld() -> bool { return frame.dimension == 0; }
fn in_nether() -> bool { return frame.dimension == -1; }
fn in_end() -> bool { return frame.dimension == 1; }

// atmosphere (photon's include/sky/atmosphere.glsl)
// photon's vec3(1.051, 0.985, 0.940) * rec709_to_rec2020
const sunlight_color = vec3<f32>(1.0245228, 0.9890134, 0.9458524);
const planet_radius: f32 = 6371e3;
const atmosphere_inner_radius: f32 = 6370e3;
const atmosphere_outer_radius: f32 = 6481e3;
const atmosphere_thickness: f32 = 111e3;
const min_mu_s: f32 = -0.35;
const air_scale_heights = vec2<f32>(8.4e3, 1.25e3);

const sun_angular_radius_deg: f32 = 2.0;
const stars_coverage: f32 = 0.5;
const atmosphere_saturation_boost: f32 = 1.0;
const shadow_penumbra_scale: f32 = 1.0;
const clouds_cumulus_altitude: f32 = 1200.0;
const clouds_wind_speed: f32 = 25.0;

fn moon_angular_radius() -> f32 { return 3.0 * degree; }
fn sun_radius() -> f32 { return sun_angular_radius_deg * degree; }

fn intersect_sphere_mu(mu: f32, r: f32, sphere_radius: f32) -> vec2<f32> {
    let disc = r * r * (mu * mu - 1.0) + sphere_radius * sphere_radius;
    if disc < 0.0 {
        return vec2<f32>(-1.0);
    }
    let d = sqrt(disc);
    return -r * mu + vec2<f32>(-d, d);
}
fn intersect_sphere_ray(o: vec3<f32>, d: vec3<f32>, sphere_radius: f32) -> vec2<f32> {
    let b = dot(o, d);
    let disc = b * b - dot(o, o) + sphere_radius * sphere_radius;
    if disc < 0.0 {
        return vec2<f32>(-1.0);
    }
    let s = sqrt(disc);
    return -b + vec2<f32>(-s, s);
}
fn intersect_spherical_shell(o: vec3<f32>, d: vec3<f32>, inner: f32, outer: f32) -> vec2<f32> {
    let i = intersect_sphere_ray(o, d, inner);
    let u = intersect_sphere_ray(o, d, outer);
    let r = length(o);
    let inner_hit = i.y >= 0.0;
    let outer_hit = u.y >= 0.0;
    if r < inner {
        // below the shell: from the inner sphere's exit to the outer's
        return vec2<f32>(i.y, u.y);
    }
    if r < outer {
        // inside the shell
        return vec2<f32>(0.0, select(u.y, i.x, inner_hit && i.x > 0.0));
    }
    if !outer_hit {
        return vec2<f32>(-1.0);
    }
    return vec2<f32>(u.x, select(u.y, i.x, inner_hit && i.x > 0.0));
}

fn henyey_greenstein_phase(nu: f32, g: f32) -> f32 {
    let gg = g * g;
    return (isotropic_phase - isotropic_phase * gg) / pow1d5(1.0 + gg - 2.0 * g * nu);
}
fn klein_nishina_phase(nu: f32, e: f32) -> f32 {
    return e / (tau * (e - e * nu + 1.0) * log(2.0 * e + 1.0));
}
fn klein_nishina_phase_area(nu: f32, e: f32, radius: f32) -> f32 {
    let rr = max(radius, eps);
    var mu = nu * cos(rr) + sqrt(max(0.0, 1.0 - nu * nu)) * sin(rr);
    if nu > cos(rr) {
        mu = 1.0;
    }
    return e / (tau * (e - e * mu + 1.0) * log(2.0 * e + 1.0));
}
fn nvidia_phase_area(nu: f32, g: f32, a: f32, radius: f32) -> f32 {
    let rr = max(radius, eps);
    var mu = nu * cos(rr) + sqrt(max(0.0, 1.0 - nu * nu)) * sin(rr);
    if nu > cos(rr) {
        mu = 1.0;
    }
    let gg = g * g;
    return ((1.0 - gg) * (1.0 + a * mu * mu))
        / (pi * pow1d5(1.0 + gg - 2.0 * g * mu) * 4.0 * (1.0 + (a * (1.0 + 2.0 * gg)) / 3.0));
}
fn atmosphere_mie_phase_sun(nu: f32) -> vec3<f32> {
    let r = nvidia_phase_area(nu, 0.85, 1.0, sun_radius());
    let g = nvidia_phase_area(nu, 0.86, 1.0, sun_radius());
    let b = nvidia_phase_area(nu, 0.87, 1.0, sun_radius());
    return vec3<f32>(r, g, b) * 0.2;
}
fn atmosphere_mie_phase_moon(nu: f32) -> vec3<f32> {
    // photon's small difference between the phases: the anisotropy is 4% lower at the full moon (phase 0) than
    // at the new moon (phase 4)
    var t = f32(frame.moon_phase & 7u) / 4.0;
    t = select(t, 2.0 - t, t > 1.0);
    t = sqr(1.0 - t) * 0.04 + 0.96;
    let r = nvidia_phase_area(nu, 0.895 * t, 1.0, 2.0 * moon_angular_radius());
    let g = nvidia_phase_area(nu, 0.90 * t, 1.0, 2.0 * moon_angular_radius());
    let b = nvidia_phase_area(nu, 0.905 * t, 1.0, 2.0 * moon_angular_radius());
    return vec3<f32>(r, g, b) * 1.02;
}

fn atmosphere_post_processing(atmosphere: vec3<f32>) -> vec3<f32> {
    let blue_hour = exp(-150.0 * sqr(frame.sun_direction.y + 0.07283));
    let boost_amount = 0.10 + 0.20 * blue_hour;
    let lum = dot(atmosphere, luminance_weights);
    // photon's ATMOSPHERE_RAIN_DESATURATION is off by default: rain doesn't desaturate the atmosphere
    return mix(vec3<f32>(lum), atmosphere, 1.0 + atmosphere_saturation_boost * boost_amount);
}

fn scattering_mu_s_coord(mu_s: f32) -> f32 {
    let h = sqrt(atmosphere_outer_radius * atmosphere_outer_radius - atmosphere_inner_radius * atmosphere_inner_radius);
    let d_min = atmosphere_thickness;
    let d_max = h;
    let d = intersect_sphere_mu(mu_s, atmosphere_inner_radius, atmosphere_outer_radius).y;
    let a = (d - d_min) / (d_max - d_min);
    let dd = intersect_sphere_mu(min_mu_s, atmosphere_inner_radius, atmosphere_outer_radius).y;
    let aa = (dd - d_min) / (d_max - d_min);
    return get_uv_from_unit_range(max0(1.0 - a / aa) / (1.0 + a), 32.0);
}
fn scattering_mu_coord(mu0: f32) -> f32 {
    var mu = mu0;
    if mu > 0.0 {
        mu *= sqrt(sqrt(mu));
    }
    let r = planet_radius;
    let h = sqrt(atmosphere_outer_radius * atmosphere_outer_radius - atmosphere_inner_radius * atmosphere_inner_radius);
    let rho = sqrt(max0(planet_radius * planet_radius - atmosphere_inner_radius * atmosphere_inner_radius));
    let rmu = r * mu;
    let disc = rmu * rmu - r * r + atmosphere_inner_radius * atmosphere_inner_radius;
    if mu < 0.0 && disc >= 0.0 {
        let d = -rmu - sqrt(max0(disc));
        let d_min = r - atmosphere_inner_radius;
        let d_max = rho;
        var u = select((d - d_min) / (d_max - d_min), 0.0, d_max == d_min);
        u = get_uv_from_unit_range(u, 32.0);
        return 0.5 - 0.5 * u;
    }
    let d = -rmu + sqrt(disc + h * h);
    let d_min = atmosphere_outer_radius - r;
    let d_max = rho + h;
    let u = get_uv_from_unit_range((d - d_min) / (d_max - d_min), 32.0);
    return 0.5 + 0.5 * u;
}
fn scattering_nu_coord(nu: f32, mu: f32, mu_s: f32) -> f32 {
    let half_range = sqrt(max0((1.0 - mu * mu) * (1.0 - mu_s * mu_s)));
    let nu_min = mu * mu_s - half_range;
    let nu_max = mu * mu_s + half_range;
    let u = select((nu - nu_min) / (nu_max - nu_min), nu_min, nu_min == nu_max);
    return get_uv_from_unit_range(clamp01(u), 16.0);
}
// one bilinear read of slice z of the 3-d lut, baked as 8x4 tiles of 32x64 rgbm texels
fn scattering_slice(u: f32, v: f32, z: f32) -> vec3<f32> {
    let tile = vec2<f32>(f32(u32(z) % 8u) * 32.0, f32(u32(z) / 8u) * 64.0);
    let texel = tile + clamp(vec2<f32>(u * 32.0, v * 64.0), vec2<f32>(0.5), vec2<f32>(31.5, 63.5));
    let c = textureSampleLevel(scattering, scattering_sampler, texel / 256.0, 0.0);
    return c.rgb * exp2(c.a * 25.0 - 25.0);
}
fn scattering_lookup(u_nu: f32, u_mu: f32, u_mu_s: f32) -> vec3<f32> {
    let z = clamp(u_mu_s * 32.0 - 0.5, 0.0, 31.0);
    let z0 = floor(z);
    let z1 = min(z0 + 1.0, 31.0);
    return mix(scattering_slice(u_nu, u_mu, z0), scattering_slice(u_nu, u_mu, z1), z - z0);
}

fn atmosphere_scattering_both(ray_dir: vec3<f32>, sun_color: vec3<f32>, moon_color: vec3<f32>) -> vec3<f32> {
    let sd = sun_dir();
    let md = moon_dir();
    var mu = ray_dir.y;
    // photon clamps rays below the horizon to it unless SKY_GROUND: then they see the scattering against the
    // planet's surface, darker, which the table holds (scattering_mu_coord's lower half)
    if !sky_ground {
        let horizon_mu = mix(-0.01, 0.03,
            clamp01(smoothstep(-0.05, 0.1, sd.y) + smoothstep(0.05, 0.1, md.y)));
        mu = max(mu, horizon_mu);
    }
    let nu_sun = dot(ray_dir, sd);
    let nu_moon = dot(ray_dir, md);
    let u_mu = scattering_mu_coord(mu);
    let u_nu_sun = scattering_nu_coord(nu_sun, mu, sd.y);
    let u_nu_moon = scattering_nu_coord(nu_moon, mu, md.y);
    let u_mu_sun = scattering_mu_s_coord(sd.y);
    let u_mu_moon = scattering_mu_s_coord(md.y);
    let sc = scattering_lookup(u_nu_sun * 0.5, u_mu, u_mu_sun);
    let sm = scattering_lookup(u_nu_sun * 0.5 + 0.5, u_mu, u_mu_sun);
    let mc = scattering_lookup(u_nu_moon * 0.5, u_mu, u_mu_moon);
    let mm = scattering_lookup(u_nu_moon * 0.5 + 0.5, u_mu, u_mu_moon);
    let atmosphere = (sc + sm * atmosphere_mie_phase_sun(nu_sun)) * sun_color
        + (mc + mm * atmosphere_mie_phase_moon(nu_moon)) * moon_color;
    return atmosphere_post_processing(atmosphere);
}

fn chapman_function_approx(x: f32, cos_theta: f32) -> f32 {
    let c = sqrt(half_pi * x);
    if cos_theta >= 0.0 {
        return c / ((c - 1.0) * cos_theta + 1.0);
    }
    let sin_theta = sqrt(clamp01(1.0 - cos_theta * cos_theta));
    return c / ((c - 1.0) * cos_theta - 1.0) + 2.0 * c * exp(x - x * sin_theta) * sqrt(sin_theta);
}
fn atmosphere_transmittance(mu: f32, r: f32) -> vec3<f32> {
    if intersect_sphere_mu(mu, max(r, planet_radius + 10.0), planet_radius).x >= 0.0 {
        return vec3<f32>(0.0);
    }
    let rcp_h = 1.0 / air_scale_heights;
    let density = exp(r * -rcp_h + planet_radius * rcp_h);
    var airmass = air_scale_heights * density;
    airmass.x *= chapman_function_approx(r * rcp_h.x, mu);
    airmass.y *= chapman_function_approx(r * rcp_h.y, mu);
    let rayleigh = vec3<f32>(8.059375432e-06, 1.671209429e-05, 4.080133294e-05) * rec709_to_rec2020;
    let mie = vec3<f32>(1.666442358e-06, 1.812685127e-06, 1.958927896e-06) * rec709_to_rec2020;
    let ozone = vec3<f32>(8.304280072e-07, 1.314911970e-06, 5.440679729e-08) * rec709_to_rec2020;
    return clamp01v(exp(-(rayleigh * airmass.x + mie * airmass.y + ozone * airmass.x)));
}
fn atmosphere_transmittance_ray(o: vec3<f32>, d: vec3<f32>) -> vec3<f32> {
    let r = length(o);
    return atmosphere_transmittance(dot(o, d) / r, r);
}

// light colours (photon's include/lighting/colors/light_color.glsl)
fn get_sun_exposure() -> f32 {
    let t = get_times();
    let blue_hour = linear_step(0.05, 1.0, exp(-190.0 * sqr(frame.sun_direction.y + 0.09604)));
    return 7.0 * sun_i * (1.0 + 0.5 * (t.sunset + t.sunrise) + 40.0 * blue_hour);
}
fn get_sun_tint() -> vec3<f32> {
    let blue_hour = linear_step(0.05, 1.0, exp(-190.0 * sqr(frame.sun_direction.y + 0.09604)));
    let me = mix(vec3<f32>(1.0), vec3<f32>(1.05, 0.84, 0.93) * 1.2, sqr(pulse(frame.sun_direction.y, 0.17, 0.40)));
    let bh = mix(vec3<f32>(1.0), vec3<f32>(0.95, 0.80, 1.0), blue_hour);
    return me * bh;
}
fn get_moon_exposure() -> f32 {
    let time_boost = 1.0 + 0.33 / clamp01(1.25 * max(-frame.sun_direction.y, 0.1));
    let phase = frame.moon_phase & 7u;
    var phase_brightness = 1.0;
    if phase == 1u || phase == 6u {
        phase_brightness = 0.875;
    } else if phase == 2u || phase == 5u {
        phase_brightness = 0.75;
    } else if phase == 3u {
        phase_brightness = 0.625;
    } else if phase == 4u {
        phase_brightness = 0.5;
    }
    return 0.66 * moon_i * phase_brightness * time_boost;
}
fn get_blocklight_color() -> vec3<f32> {
    let warm = from_srgb(vec3<f32>(1.0, 0.75, 0.63));
    return mix(vec3<f32>(0.92), warm, blocklight_warmth);
}

// Orthonormal light-aligned distortion mapping for cloud_shadow_tex (Photon's cloud_shadows.glsl)
const cloud_shadow_extent: f32 = 256.0;
struct LightBasis {
    right: vec3<f32>,
    fwd: vec3<f32>,
}
fn cloud_shadow_basis(ld: vec3<f32>) -> LightBasis {
    let up_ref = select(vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(1.0, 0.0, 0.0), abs(ld.z) > 0.95);
    let right = normalize(cross(up_ref, ld));
    let fwd = cross(ld, right);
    return LightBasis(right, fwd);
}
fn project_cloud_shadow_uv(scene_pos: vec3<f32>) -> vec2<f32> {
    let basis = cloud_shadow_basis(light_dir());
    let lp = vec2<f32>(dot(scene_pos, basis.right), dot(scene_pos, basis.fwd)) / cloud_shadow_extent;
    return (lp / (1.0 + length(lp))) * 0.5 + 0.5;
}
fn unproject_cloud_shadow_pos(uv: vec2<f32>) -> vec3<f32> {
    let p0 = uv * 2.0 - 1.0;
    let raw_len = length(p0);
    let len = min(raw_len, 0.992);
    let dir0 = select(vec2<f32>(0.0), p0 / max(raw_len, 1e-6), raw_len >= 1e-6);
    let lp = (dir0 * len / (1.0 - len)) * cloud_shadow_extent;
    let basis = cloud_shadow_basis(light_dir());
    return basis.right * lp.x + basis.fwd * lp.y;
}
fn get_cloud_shadow_fade(scene_pos: vec3<f32>) -> f32 {
    let r = planet_radius + (scene_pos.y + frame.camera_position.y - 63.0) * 10.0;
    let alt_frac = linear_step(planet_radius + clouds_cumulus_altitude, planet_radius + 2.0 * clouds_cumulus_altitude, r);
    return smoothstep(0.05, 0.15, light_dir().y) * clamp01(1.0 - alt_frac);
}
// photon's CLOUD_SHADOWS_INTENSITY (settings.glsl): the cloud shadow map only takes 80% of the light away
const CLOUD_SHADOWS_INTENSITY: f32 = 0.8;
fn cloud_shadow_factor(cs: f32, fade: f32) -> f32 {
    return (cs * fade + (1.0 - fade)) * CLOUD_SHADOWS_INTENSITY + (1.0 - CLOUD_SHADOWS_INTENSITY);
}
fn get_moon_tint() -> vec3<f32> { return from_srgb(vec3<f32>(0.75, 0.83, 1.0)); }
fn sun_color() -> vec3<f32> { return get_sun_exposure() * get_sun_tint(); }
fn moon_color() -> vec3<f32> { return get_moon_exposure() * get_moon_tint(); }

fn get_light_color() -> vec3<f32> {
    let ld = light_dir();
    var c = sunlight_color * atmosphere_transmittance(ld.y, planet_radius);
    c = atmosphere_post_processing(c);
    c *= select(sun_color(), moon_color(), is_night());
    c *= clamp01(50.0 * ld.y);
    c *= 1.0 - 0.25 * pulse(abs(ld.y), 0.15, 0.11);
    return c;
}

fn get_weather_color() -> vec3<f32> {
    let k = smoothstep(-0.1, 0.5, frame.sun_direction.y);
    let rain = mix(0.033, 0.66, k) * sunlight_color * vec3<f32>(0.49, 0.65, 1.0);
    let snow = mix(0.060, 1.60, k) * sunlight_color * vec3<f32>(0.49, 0.65, 1.0);
    // photon's get_sandstorm_color, mixed in where a desert's sand blows (biome_may_sandstorm)
    let sand = mix(0.033, 0.66, k) * sunlight_color * vec3<f32>(1.0, 0.83, 0.60);
    let may_sandstorm = select(0.0, 1.0, desert_sandstorm && frame.precipitation == 0u && frame.temperature > 1.0);
    return mix(mix(rain, snow, biome_may_snow()), sand, may_sandstorm);
}

// photon's d0_sky_map get_ambient_color: the sky towards (0, 1, -0.8)
fn get_sky_color() -> vec3<f32> {
    let dir = normalize(vec3<f32>(0.0, 1.0, -0.8));
    var c = atmosphere_scattering_both(dir, sun_color(), moon_color());
    c = tau * c * 1.13;
    return mix(c, tau * get_weather_color(), frame.rain);
}
fn get_skylight_boost() -> f32 {
    let early_night = linear_step(0.05, 1.0, exp(-25.0 * sqr(frame.sun_direction.y + 0.3)));
    return 1.0 + 0.5 * early_night;
}

// photon's include/misc/purkinje_shift.glsl
fn purkinje_shift_apply(rgb: vec3<f32>, light_levels: vec2<f32>) -> vec3<f32> {
    if !purkinje_shift || !in_overworld() {
        return rgb;
    }
    var k = 0.05;
    k = k - k * smoothstep(-0.12, -0.06, frame.sun_direction.y) * light_levels.y;
    k *= clamp01(1.0 - light_levels.x);
    k *= clamp01(0.3 + 0.7 * cube(max(light_levels.y, eye_skylight())));
    if k < eps {
        return rgb;
    }
    let tint = vec3<f32>(0.5, 0.7, 1.0) * rec709_to_rec2020;
    let rod_response = vec3<f32>(7.15e-5, 4.81e-1, 3.28e-1) * rec709_to_rec2020;
    let xyz = rgb * rec2020_to_xyz;
    let scotopic = xyz * (1.33 * (1.0 + (xyz.y + xyz.z) / max(xyz.x, eps)) - 1.68);
    let purkinje = dot(rod_response, scotopic * xyz_to_rec2020);
    return max(mix(rgb, purkinje * tint, exp2(-purkinje / k)), vec3<f32>(0.0));
}

// photon's analytic overworld air fog (include/fog/overworld/analytic.glsl) with the coefficients of
// include/weather/fog.glsl get_fog_parameters. Both kinds of fog thin out with height (photon's
// AIR_FOG_*_FALLOFF: full up to sea level + 30 / + 7 blocks, halving every 30 / 7 blocks above), so the mist
// and the rain fog lie in the valleys; and while it rains the sun lights the fog at a tenth of its strength,
// so rain greys the distance instead of laying a sunlit veil over everything.
struct AirFog {
    // light from the sun or moon scattered toward the camera: what the light shafts shadow
    direct: vec3<f32>,
    // skylight scattered toward the camera
    ambient: vec3<f32>,
    transmittance: vec3<f32>,
}

fn air_fog_analytic_airmass(origin_y: f32, ray_dir: vec3<f32>, ray_length: f32) -> vec2<f32> {
    // the integral along the ray of exp2(-(y - start) / half_life), x rayleigh and y mie
    let half_life = vec2<f32>(30.0, 7.0);
    let start = vec2<f32>(30.0, 7.0) + 63.0;
    let mul = -1.0 / half_life;
    let a = (origin_y - start) * mul;
    let p2 = exp2(min(a, vec2<f32>(80.0)));
    var airmass = ray_length * p2;
    if abs(ray_dir.y) > 1e-4 {
        let p1 = exp2(min(ray_length * ray_dir.y * mul + a, vec2<f32>(80.0)));
        airmass = (p1 - p2) / (log(2.0) * mul * ray_dir.y);
    }
    return clamp(airmass, vec2<f32>(0.0), vec2<f32>(ray_length)) * (0.5 * air_fog_density);
}

// Photon's raymarched fog (include/fog/overworld/raymarched.glsl air_fog_density), the one the light shafts use and
// the analytic one only stands in for when they are off: exp2(min((start - y) / half_life, 0)), which is 1 below the
// falloff start (sea level + 7 for the mie, + 30 for the rayleigh; the analytic fog's is not clamped, about twice
// as dense at sea level and as dense underground), times linear_step(39, 63, y) (it fades away below sea level), and
// nothing above y = 320, the top of the volume. The airmass along a straight ray, x rayleigh and y mie, is closed
// form band by band: F(y) below is the density's integral up to height y.
fn air_fog_vl_integral(y: f32, start: f32, half_life: f32) -> f32 {
    // 39 to 63: the ramp (y - 39) / 24, 12 at its top
    var r = (clamp(y, 39.0, 63.0) - 39.0);
    r = r * r / 48.0;
    // 63 to the falloff start: 1
    r += clamp(y, 63.0, start) - 63.0;
    // start to 320: exp2(-(y - start) / half_life)
    let top = clamp(y, start, 320.0) - start;
    r += half_life / 0.69314718 * (1.0 - exp2(-top / half_life));
    return r;
}
fn air_fog_vl_density(y: f32, start: f32, half_life: f32) -> f32 {
    return exp2(min((start - y) / half_life, 0.0)) * linear_step(39.0, 63.0, y) * select(0.0, 1.0, y < 320.0);
}
fn air_fog_vl_airmass(origin_y: f32, ray_dir: vec3<f32>, ray_length: f32) -> vec2<f32> {
    // rayleigh: falloff start 93 (sea level + 30), half life 30; mie: start 70, half life 7
    let dy = ray_dir.y;
    let y1 = origin_y + dy * ray_length;
    // along a ray this flat the density hardly changes: the density at the origin times the length
    let flat_ray = abs(dy) < 1e-3;
    let safe_dy = select(dy, 1.0, flat_ray);
    let flat_r = ray_length * air_fog_vl_density(origin_y, 93.0, 30.0);
    let flat_m = ray_length * air_fog_vl_density(origin_y, 70.0, 7.0);
    let slope_r = (air_fog_vl_integral(y1, 93.0, 30.0) - air_fog_vl_integral(origin_y, 93.0, 30.0)) / safe_dy;
    let slope_m = (air_fog_vl_integral(y1, 70.0, 7.0) - air_fog_vl_integral(origin_y, 70.0, 7.0)) / safe_dy;
    let am = vec2<f32>(select(slope_r, flat_r, flat_ray), select(slope_m, flat_m, flat_ray));
    return max(am, vec2<f32>(0.0)) * (0.5 * air_fog_density);
}
// whether the air fog is photon's VL one: the shafts' fog, whose sun light only the shadow map shadows
fn air_fog_vl_active() -> bool {
    return vl && vl_weighted_shafts && in_overworld() && frame.has_shadow != 0u && frame.eye_in == 0u;
}
fn air_fog_airmass(origin_y: f32, ray_dir: vec3<f32>, ray_length: f32) -> vec2<f32> {
    if air_fog_vl_active() {
        return air_fog_vl_airmass(origin_y, ray_dir, ray_length);
    }
    return air_fog_analytic_airmass(origin_y, ray_dir, ray_length);
}

// photon's biome_* uniforms (shaders.properties: Iris's biome categories, eased over 30 s). Horizon gives no biome
// id, so the categories come from the biome's temperature, downfall and precipitation, which vanilla's biomes
// keep apart: arid (no precipitation, hot: desert, badlands, savanna), snowy (snowing or freezing; photon files
// snowy taiga under taiga), taiga, jungle, swamp (and mangrove swamp), and the pale garden, whose climate is the
// dark forest's but whose sky is grey. x: arid, y: snowy, z: taiga, w: jungle; then x: swamp, y: pale garden.
struct Biomes {
    w0: vec4<f32>,
    w1: vec4<f32>,
}
fn biome_weights_now() -> Biomes {
    let t = frame.temperature;
    let d = frame.downfall;
    let arid = frame.precipitation == 0u && t > 1.0;
    let snowy = !arid && (frame.precipitation == 2u || t < 0.15);
    let taiga = !snowy && t >= 0.2 && t <= 0.35 && d >= 0.7;
    let jungle = t >= 0.93 && t <= 1.0 && d >= 0.75;
    let swamp = abs(t - 0.8) < 0.03 && d >= 0.85;
    let sky = frame.sky_color;
    let grey_sky = max_of(sky) > 0.02 && (max_of(sky) - min_of(sky)) / max_of(sky) < 0.1;
    let pale = abs(t - 0.7) < 0.03 && abs(d - 0.8) < 0.03 && grey_sky && frame.rain < 0.1;
    return Biomes(vec4<f32>(f32(arid), f32(snowy), f32(taiga), f32(jungle)), vec4<f32>(f32(swamp), f32(pale), 0.0, 0.0));
}
// photon's include/weather/fog.glsl: each category's AIR_FOG_RAYLEIGH_R/G/B at its density, by weight
fn biome_rayleigh(b: Biomes) -> vec3<f32> {
    if !biome_fog {
        return from_srgb(vec3<f32>(0.31, 0.67, 1.0)) * 0.0005;
    }
    let temperate = max0(1.0 - dot(b.w0, vec4<f32>(1.0)) - b.w1.x - b.w1.y);
    return from_srgb(vec3<f32>(0.31, 0.67, 1.0)) * 0.0005 * temperate
        + from_srgb(vec3<f32>(0.65, 0.80, 1.0)) * 0.0003 * b.w0.x
        + from_srgb(vec3<f32>(0.50, 0.81, 1.0)) * 0.0010 * b.w0.y
        + from_srgb(vec3<f32>(0.31, 0.85, 1.0)) * 0.0006 * b.w0.z
        + from_srgb(vec3<f32>(0.40, 0.95, 1.0)) * 0.0013 * b.w0.w
        + from_srgb(vec3<f32>(0.67, 1.00, 0.94)) * 0.0014 * b.w1.x
        + from_srgb(vec3<f32>(0.90, 0.80, 1.00)) * 0.03 * b.w1.y;
}

fn air_fog_analytic(origin_y: f32, ray_length: f32, ray_dir: vec3<f32>, skylight: f32, sky: bool) -> AirFog {
    return air_fog_analytic_lit(origin_y, ray_length, ray_dir, skylight, sky, get_light_color(), get_sky_color(),
        biome_rayleigh(biome_weights_now()));
}

// `rayleigh_clear`: the biome's clear-weather Rayleigh coefficient (biome_rayleigh)
// `sky`: the ray ends in the sky, whose ambient fog light is not dimmed by skylight (VL fog only)
fn air_fog_analytic_lit(origin_y: f32, ray_length: f32, ray_dir: vec3<f32>, skylight: f32, sky: bool,
        light_color: vec3<f32>, sky_color: vec3<f32>, rayleigh_clear: vec3<f32>) -> AirFog {
    let w = get_weather();
    let t = get_times();
    let rain = select(0.0, frame.rain, frame.precipitation == 1u);
    let snow = select(0.0, frame.rain, frame.precipitation == 2u);

    // rayleigh: thicker when warm and humid; in rain photon's AIR_FOG_RAYLEIGH_*_RAIN, the temperate one
    let rayleigh_rain = from_srgb(vec3<f32>(0.31, 0.67, 1.0)) * 0.0005;
    let rayleigh = mix(rayleigh_clear * (1.0 + w.humidity * w.temperature), rayleigh_rain, rain);
    // mie: AIR_FOG_MIE_DENSITY_MORNING / NOON / EVENING / MIDNIGHT / BLUE_HOUR, then RAIN and SNOW
    let s_y = frame.sun_direction.y;
    let blue_hour = linear_step(0.05, 1.0, exp(-190.0 * sqr(s_y + 0.07283)));
    var mie = 0.0070 * t.sunrise + 0.0001 * t.noon + 0.0050 * t.sunset + 0.0050 * t.midnight + 0.0020 * blue_hour;
    mie = mix(mie + 8.0 * 0.0001 * sqr(clamp01(w.humidity / 0.8)), 0.030, rain);
    mie = mix(mie, 0.015, snow);
    // photon's AIR_FOG_CLOUDY_NOISE: its raymarched mist is 4 x noise^2 as dense where a drifting 1000-block noise
    // says; this fog is a closed form, so it takes the noise's average at three points along the ray
    if air_fog_cloudy_noise {
        let wind = vec2<f32>(0.0003, 0.00021) * frame.time;
        let reach = min(ray_length, 300.0);
        var cloudy = 0.0;
        for (var k = 0; k < 3; k++) {
            let p = frame.camera_position.xz + ray_dir.xz * reach * (f32(k) + 0.5) / 3.0;
            cloudy += sqr(textureSampleLevel(noisetex, noisetex_sampler, 0.001 * p + wind, 0.0).w);
        }
        mie *= 4.0 * cloudy / 3.0;
    }
    let mie_albedo = mix(0.9, 0.5, rain);
    // photon's DESERT_SANDSTORM (include/weather/fog.glsl): the rain that a desert or badlands doesn't get blows
    // as dust, more scattering than extinction and the blue dimmed most, so it hangs low and orange
    let sand = select(0.0, frame.rain, desert_sandstorm && frame.precipitation == 0u && frame.temperature > 1.0);
    let sand_scattering = 0.1 * sand;
    let sand_extinction = 0.2 * vec3<f32>(0.2, 0.27, 0.45) * sand;

    let airmass = air_fog_airmass(origin_y, ray_dir, ray_length);
    let od = rayleigh * airmass.x + vec3<f32>(mie * airmass.y) + sand_extinction * airmass.y;
    let transmittance = exp(-od);
    let integral = (1.0 - transmittance) / max(od, vec3<f32>(eps));
    let rayleigh_s = integral * airmass.x * rayleigh;
    let mie_s = integral * airmass.y * (mie * mie_albedo + sand_scattering);

    // multiple scattering: four orders, each half as strong and less forward than the last
    let lov = dot(ray_dir, light_dir());
    var direct = vec3<f32>(0.0);
    var amount = 1.0;
    var anisotropy = 1.0;
    for (var i = 0; i < 4; i++) {
        let phase = 0.7 * henyey_greenstein_phase(lov, 0.5 * anisotropy)
            + 0.3 * henyey_greenstein_phase(lov, -0.2 * anisotropy);
        direct += amount * (rayleigh_s * isotropic_phase + mie_s * phase);
        amount *= 0.5;
        anisotropy *= 0.7;
    }
    direct *= light_color * (1.0 - 0.9 * frame.rain);
    var ambient = 2.0 * (rayleigh_s + mie_s) * isotropic_phase * sky_color;

    // fog scatters the light it is in; brightened a little around sunrise and sunset (photon: "looks nice")
    let lit = max(skylight, eye_skylight());
    let evening_glow = 0.75 * linear_step(0.05, 1.0, exp(-300.0 * sqr(s_y + 0.02)));
    // with the shafts on (photon's VL fog) the sun's light is never scaled by skylight, only shadowed, and the
    // ambient light is, but not in the sky; photon's analytic fog scales both (it only draws with the shafts off)
    let vl_fog = air_fog_vl_active();
    let k_direct = select(lit, 1.0, vl_fog) * (1.0 + evening_glow);
    let k_ambient = select(lit, select(lit, 1.0, sky), vl_fog) * (1.0 + evening_glow);
    return AirFog(max(direct * k_direct, vec3<f32>(0.0)), max(ambient * k_ambient, vec3<f32>(0.0)), transmittance);
}

// tone mapping operators (photon's include/post_processing/tonemap_operators.glsl)
fn tonemap_lottes(rgb: vec3<f32>) -> vec3<f32> {
    let a = 1.5;
    let d = 0.91;
    let hdr_max = 8.0;
    let mid_in = 0.26;
    let mid_out = 0.32;
    let b = (-pow(mid_in, a) + pow(hdr_max, a) * mid_out)
        / ((pow(hdr_max, a * d) - pow(mid_in, a * d)) * mid_out);
    let c = (pow(hdr_max, a * d) * pow(mid_in, a) - pow(hdr_max, a) * pow(mid_in, a * d) * mid_out)
        / ((pow(hdr_max, a * d) - pow(mid_in, a * d)) * mid_out);
    let x = max(rgb, vec3<f32>(0.0));
    return pow(x, vec3<f32>(a)) / (pow(x, vec3<f32>(a * d)) * b + c);
}
fn tonemap_hejl_2015(rgb: vec3<f32>) -> vec3<f32> {
    let vh = vec4<f32>(rgb, 5.0);
    let va = 1.425 * vh + 0.05;
    let vf = ((vh * va + 0.004) / (vh * (va + 0.55) + 0.0491)) - 0.0821;
    return vf.rgb / vf.www;
}
fn uc2_partial(x: vec3<f32>) -> vec3<f32> {
    let a = 0.15;
    let b = 0.50;
    let c = 0.10;
    let d = 0.20;
    let e = 0.02;
    let f = 0.30;
    return ((x * (a * x + c * b) + d * e) / (x * (a * x + b) + d * f)) - e / f;
}
fn tonemap_uncharted_2(rgb: vec3<f32>) -> vec3<f32> {
    return uc2_partial(rgb * 2.0) / uc2_partial(vec3<f32>(11.2));
}
fn tonemap_tech(rgb: vec3<f32>) -> vec3<f32> {
    var a = rgb * min(vec3<f32>(1.0), 1.0 - exp(-1.0 / 0.038 * rgb));
    a = mix(a, rgb, rgb * rgb);
    return a / (a + 0.6);
}
fn tonemap_reinhard_jodie(rgb: vec3<f32>) -> vec3<f32> {
    let reinhard = rgb / (rgb + 1.0);
    return mix(rgb / (dot(rgb, luminance_weights) + 1.0), reinhard, reinhard);
}
fn tonemap_aces_fit(rgb0: vec3<f32>) -> vec3<f32> {
    // narkowicz's fit of the rrt+odt; photon's aces_fit runs ap0/ap1 sweeteners on top
    let rgb = rgb0 * 1.6 * 0.6;
    return clamp01v((rgb * (2.51 * rgb + 0.03)) / (rgb * (2.43 * rgb + 0.59) + 0.14));
}
fn apply_tonemap(rgb: vec3<f32>) -> vec3<f32> {
    switch tonemap_operator {
        case 1u: { return tonemap_aces_fit(rgb); }
        case 2u: { return tonemap_hejl_2015(rgb); }
        case 3u: { return tonemap_uncharted_2(rgb); }
        case 4u: { return tonemap_tech(rgb); }
        case 5u: { return tonemap_reinhard_jodie(rgb); }
        default: { return tonemap_lottes(rgb); }
    }
}

// photon's weather system (include/weather/core.glsl); world_age comes from horizon's clock
struct Weather {
    temperature: f32,
    humidity: f32,
    wind: f32,
}
fn get_weather() -> Weather {
    let t = get_times();
    let age = world_age();
    var w: Weather;
    var temperature = noise_1d(age * (0.37 * golden_ratio / 600.0) + 2.5);
    temperature -= 0.2 * t.sunrise + 0.2 * t.midnight;
    temperature *= 1.0 + (frame.temperature - 0.6) * 0.1;
    w.temperature = clamp01(temperature);
    var humidity = mix(0.2, 0.8, noise_1d(age * (0.37 * golden_ratio / 600.0) + 46.618));
    humidity *= 1.0 + (frame.downfall + 0.2) * 0.1;
    humidity += frame.wetness;
    w.humidity = clamp01(humidity);
    var wind = noise_1d(age * (0.5 * golden_ratio / 600.0) + 83.236);
    wind += 0.33 * frame.wetness;
    w.wind = clamp01(wind);
    return w;
}
