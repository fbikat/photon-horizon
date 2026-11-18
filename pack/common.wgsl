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
fn world_age() -> f32 { return frame.time + frame.game_time * 1200.0; }
fn biome_may_snow() -> f32 { return select(0.0, 1.0, frame.precipitation == 2u || frame.temperature < 0.15); }
fn in_overworld() -> bool { return frame.dimension == 0; }

// atmosphere (photon's include/sky/atmosphere.glsl)
// photon's vec3(1.051, 0.985, 0.940) * rec709_to_rec2020
const sunlight_color = vec3<f32>(1.0245228, 0.9890134, 0.9458524);
const planet_radius: f32 = 6371e3;
const atmosphere_inner_radius: f32 = 6370e3;
const atmosphere_outer_radius: f32 = 6481e3;
const atmosphere_thickness: f32 = 111e3;
const min_mu_s: f32 = -0.35;
const air_scale_heights = vec2<f32>(8.4e3, 1.25e3);

fn moon_angular_radius() -> f32 { return 3.0 * degree; }
fn sun_radius() -> f32 { return sun_angular_radius * degree; }

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
    let r = nvidia_phase_area(nu, 0.895, 1.0, 2.0 * moon_angular_radius());
    let g = nvidia_phase_area(nu, 0.90, 1.0, 2.0 * moon_angular_radius());
    let b = nvidia_phase_area(nu, 0.905, 1.0, 2.0 * moon_angular_radius());
    return vec3<f32>(r, g, b) * 1.02;
}

fn atmosphere_post_processing(atmosphere: vec3<f32>) -> vec3<f32> {
    let blue_hour = exp(-150.0 * sqr(frame.sun_direction.y + 0.07283));
    let boost_amount = 0.10 + 0.20 * blue_hour;
    let lum = dot(atmosphere, luminance_weights);
    return mix(vec3<f32>(lum), atmosphere,
        (1.0 + atmosphere_saturation_boost * boost_amount) * (1.0 - frame.rain));
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
    let horizon_mu = mix(-0.01, 0.03,
        clamp01(smoothstep(-0.05, 0.1, sd.y) + smoothstep(0.05, 0.1, md.y)));
    mu = max(mu, horizon_mu);
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
    return 0.66 * moon_i * time_boost;
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
    return mix(rain, snow, biome_may_snow());
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

// photon's analytic overworld air fog (include/fog/overworld/analytic.glsl), simplified to one
// exponential layer per scattering type with the same coefficients
fn air_fog_analytic(ray_length: f32, ray_dir: vec3<f32>, skylight: f32) -> array<vec3<f32>, 2> {
    let rayleigh = vec3<f32>(8.059375432e-06, 1.671209429e-05, 4.080133294e-05) * rec709_to_rec2020;
    let height = frame.camera_position.y;
    let fade = exp2(-0.04 * max0(height - 63.0)) ;
    let mie_density = (0.0005 + 0.008 * frame.rain) * air_fog_density * mix(0.25, 1.0, fade);
    let rayleigh_density = 25.0 * air_fog_density;
    let ext = rayleigh * rayleigh_density + vec3<f32>(mie_density);
    let od = ext * ray_length;
    let transmittance = exp(-od);
    let lc = get_light_color();
    let sky = get_sky_color();
    let nu = dot(ray_dir, light_dir());
    let mie_phase = 0.7 * henyey_greenstein_phase(nu, 0.7) + 0.3 * henyey_greenstein_phase(nu, -0.2);
    let scatter = (rayleigh * rayleigh_density) * (lc * isotropic_phase * 3.0 + sky * isotropic_phase)
        + vec3<f32>(mie_density) * (lc * mie_phase + sky * isotropic_phase);
    let integral = (1.0 - transmittance) / max(ext, vec3<f32>(1e-9));
    return array<vec3<f32>, 2>(scatter * integral * mix(0.3, 1.0, skylight), transmittance);
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
