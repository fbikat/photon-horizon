// photon's include/sky/sky.glsl draw_sky: atmosphere, sun disc, moon phases, stars, galaxy, End black hole

fn draw_sun(ray_dir: vec3<f32>) -> vec3<f32> {
    let radius = sun_radius();
    let sun_luminance = 1.0 / (tau * (1.0 - cos(radius)));
    let nu = dot(ray_dir, sun_dir());
    let alpha = vec3<f32>(0.429, 0.522, 0.614);
    let center_to_edge = max0(radius - fast_acos(nu));
    let limb_darkening = pow(vec3<f32>(1.0 - sqr(1.0 - center_to_edge)), 0.5 * alpha);
    return sun_luminance * sun_color() * step(0.0, center_to_edge) * limb_darkening;
}

// photon's include/sky/sky.glsl draw_moon + horizon's frame.moon_phase (0 full .. 4 new .. 7 waxing gibbous)
fn draw_moon(ray_dir: vec3<f32>) -> vec4<f32> {
    let md = moon_dir();
    let radius = moon_angular_radius();
    let mov = dot(ray_dir, md);
    if mov < cos(radius) {
        return vec4<f32>(0.0);
    }
    let dist = clamp01(fast_acos(mov) / radius);
    let up_ref = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(md.y) > 0.999);
    let tangent = normalize(cross(up_ref, md));
    let bitangent = normalize(cross(tangent, md));
    let rel = ray_dir - md;
    let offset = fract(vec2<f32>(dot(rel, tangent), dot(rel, bitangent)) * 3.5 + 0.5);
    let noise = textureSampleLevel(noisetex, noisetex_sampler, 2.0 * offset, 0.0).xyz;
    let moon_tex = pow1d5(noise.x) * 0.75 + 0.6 * cube(noise.y) - 0.1 * noise.z;

    let moon_dist = intersect_sphere_ray(-md, ray_dir, sin(radius)).x;
    let moon_normal = normalize(ray_dir * max(moon_dist, 0.0) - md);
    let light_angle = 0.125 * tau * f32(frame.moon_phase & 7u);
    let left_dir = normalize(cross(up_ref, ray_dir));
    let l_dir = cos(light_angle) * (-ray_dir) + sin(light_angle) * left_dir;
    let moon_shadow = dampen(max0(dot(moon_normal, l_dir)));

    let edge_glow = pow8(dist);
    let base_tint = from_srgb(vec3<f32>(0.75, 0.83, 1.0));
    let lit_col = base_tint * vec3<f32>(1.0, 0.94, 1.0);
    let glow_col = base_tint * vec3<f32>(0.90, 1.0, 1.0);
    var c = max(
        moon_shadow * lit_col * (1.0 + 4.0 * edge_glow),
        0.5 * glow_col * (0.1 + 0.1 * edge_glow),
    ) * (0.2 + 0.8 * max0(moon_tex));
    c = 10.0 * moon_i * c * c;
    return vec4<f32>(c, 1.0);
}

fn unstable_star_field(coord: vec2<f32>, threshold: f32) -> vec3<f32> {
    let noise = hash4(coord);
    var star = linear_step(threshold, 1.0, noise.x);
    star = pow16(star) * stars_intensity;
    let color = blackbody(mix(4500.0, 8500.0, noise.y));
    star *= 1.0 - noise.z * cos(frame.time * 2.0 + tau * noise.w);
    return star * color;
}

fn stable_star_field(coord0: vec2<f32>, threshold: f32) -> vec3<f32> {
    let coord = abs(coord0) + 33.3 * step(vec2<f32>(0.0), coord0);
    let i = floor(coord);
    var f = coord - i;
    f = f * f * (3.0 - 2.0 * f);
    return unstable_star_field(i, threshold) * (1.0 - f.x) * (1.0 - f.y)
        + unstable_star_field(i + vec2<f32>(1.0, 0.0), threshold) * f.x * (1.0 - f.y)
        + unstable_star_field(i + vec2<f32>(0.0, 1.0), threshold) * f.y * (1.0 - f.x)
        + unstable_star_field(i + vec2<f32>(1.0, 1.0), threshold) * f.x * f.y;
}

fn draw_stars(ray_dir: vec3<f32>, galaxy_luminance: f32) -> vec3<f32> {
    let threshold = 1.0 - 0.05 * stars_coverage * smoothstep(-0.2, 0.05, -frame.sun_direction.y)
        - 0.5 * cube(galaxy_luminance);
    var coord = ray_dir.xy / (abs(ray_dir.z) + length(ray_dir.xy)) + 41.21 * sign(ray_dir.z);
    coord *= 600.0;
    return stable_star_field(coord, threshold);
}

// stars and galaxy turn with the sun, as photon's shadowModelViewInverse trick
fn celestial(ray_dir: vec3<f32>) -> vec3<f32> {
    let s = frame.sun_direction;
    let up = normalize(s);
    let side = normalize(cross(vec3<f32>(0.0, 0.0, 1.0), up) + vec3<f32>(1e-5, 0.0, 0.0));
    let fwd = cross(up, side);
    return vec3<f32>(dot(ray_dir, side), dot(ray_dir, fwd), dot(ray_dir, up));
}

fn sky(input: SkyInput) -> vec4<f32> {
    let ray_dir = normalize(input.direction);
    if in_end() {
        var end_col = end_sky_color(ray_dir);
        let cel_end = vec3<f32>(ray_dir.x, ray_dir.z, ray_dir.y);
        let stars_fade = exp2(-0.12 * max0(1.0 - ray_dir.y)) * linear_step(-0.2, 0.0, ray_dir.y);
        let bh = draw_end_black_hole(ray_dir);
        end_col += draw_stars(cel_end, 0.0) * vec3<f32>(0.78, 0.68, 1.0) * 0.65 * stars_fade * (1.0 - bh.a);
        end_col = end_col * (1.0 - bh.a * 0.92) + bh.rgb;
        return vec4<f32>(rec2020_to_linear(end_col), 1.0);
    }
    if in_nether() {
        return vec4<f32>(rec2020_to_linear(nether_sky_color(ray_dir)), 1.0);
    }
    if !in_overworld() {
        return input.color;
    }
    let atmosphere = atmosphere_scattering_both(ray_dir, sun_color(), moon_color());
    var sky_col = vec3<f32>(0.0);

    let cel = celestial(ray_dir);
    var galaxy_luminance = 0.0;
    if galaxy {
        let intensity = 0.05 + linear_step(-0.1, 0.25, -frame.sun_direction.y);
        let lon = atan2(cel.x, cel.z);
        let lat = fast_acos(-cel.y);
        var g = textureSampleLevel(galaxy_tex, galaxy_tex_sampler, vec2<f32>(lon / tau + 0.5, lat / pi), 0.0).rgb;
        g = srgb_eotf_inv(g) * rec709_to_rec2020;
        g *= intensity * vec3<f32>(0.75, 0.66, 1.0) * galaxy_intensity;
        galaxy_luminance = dot(g, luminance_weights);
        sky_col += max(mix(vec3<f32>(galaxy_luminance), g, 2.0), vec3<f32>(0.0));
    }
    sky_col += draw_stars(cel, galaxy_luminance);
    sky_col += draw_sun(ray_dir);
    let moon = draw_moon(ray_dir);
    sky_col = sky_col * (1.0 - moon.a) + moon.rgb;

    sky_col *= atmosphere_transmittance(ray_dir.y, planet_radius) * (1.0 - frame.rain);
    sky_col += atmosphere;

    // cave sky fix: fade the lower sky to black underground
    let underground = biome_cave() * smoothstep(-0.1, 0.1, 0.4 - ray_dir.y);
    sky_col = mix(sky_col, vec3<f32>(0.0), underground);

    return vec4<f32>(rec2020_to_linear(sky_col), 1.0);
}
