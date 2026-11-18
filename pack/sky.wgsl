// photon's include/sky/sky.glsl draw_sky: atmosphere, sun disc, stars and galaxy

fn draw_sun(ray_dir: vec3<f32>) -> vec3<f32> {
    let radius = sun_radius();
    let sun_luminance = 1.0 / (tau * (1.0 - cos(radius)));
    let nu = dot(ray_dir, sun_dir());
    let alpha = vec3<f32>(0.429, 0.522, 0.614);
    let center_to_edge = max0(radius - fast_acos(nu));
    let limb_darkening = pow(vec3<f32>(1.0 - sqr(1.0 - center_to_edge)), 0.5 * alpha);
    return sun_luminance * sun_color() * step(0.0, center_to_edge) * limb_darkening;
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
    if !in_overworld() {
        // the nether and end keep their vanilla look in linear BT.709
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

    sky_col *= atmosphere_transmittance(ray_dir.y, planet_radius) * (1.0 - frame.rain);
    sky_col += atmosphere;

    // cave sky fix: fade the lower sky to black underground
    let underground = biome_cave() * smoothstep(-0.1, 0.1, 0.4 - ray_dir.y);
    sky_col = mix(sky_col, vec3<f32>(0.0), underground);

    return vec4<f32>(rec2020_to_linear(sky_col), 1.0);
}
