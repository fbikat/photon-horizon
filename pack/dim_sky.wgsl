// Photon-inspired Nether and End sky gradients, cosmic nebula, and End black hole

const end_light_dir = vec3<f32>(0.0, 0.5299989, -0.8479983);

fn end_sky_color(ray_dir: vec3<f32>) -> vec3<f32> {
    let horizon = pow(1.0 - abs(ray_dir.y), 2.5);
    var col = mix(vec3<f32>(0.010, 0.004, 0.022), vec3<f32>(0.048, 0.018, 0.088), horizon);
    let end_sun_col = vec3<f32>(1.0, 0.5, 0.25) * rec709_to_rec2020;
    let amb_col = vec3<f32>(0.36, 0.28, 0.56);
    let mie = henyey_greenstein_phase(dot(ray_dir, end_light_dir), 0.6);
    col += 0.10 * (amb_col * 0.35 + 0.5 * end_sun_col) * mie;
    let band_axis = normalize(vec3<f32>(0.25, 0.88, -0.40));
    let band = exp(-7.5 * sqr(dot(ray_dir, band_axis)));
    let uv_neb = vec2<f32>(atan2(ray_dir.z, ray_dir.x) * rcp_pi * 0.5 + 0.5, ray_dir.y * 0.5 + 0.5);
    let n1 = textureSampleLevel(noisetex, noisetex_sampler, uv_neb * 2.5, 0.0).x;
    let n2 = textureSampleLevel(noisetex, noisetex_sampler, uv_neb * 6.0 + vec2<f32>(0.17, 0.43), 0.0).y;
    let nebula = band * smoothstep(0.25, 0.9, n1 * 0.7 + n2 * 0.3);
    col += mix(vec3<f32>(0.16, 0.06, 0.34), vec3<f32>(0.08, 0.22, 0.38), n2) * nebula * 0.45;
    return col;
}

// Photon's sky/sky.glsl WORLD_END black hole / solar singularity with Einstein ring & plasma accretion disk
fn draw_end_black_hole(ray_dir: vec3<f32>) -> vec4<f32> {
    let nu = dot(ray_dir, end_light_dir);
    if nu < 0.72 {
        return vec4<f32>(0.0, 0.0, 0.0, 0.0);
    }
    let bh_radius = 0.044;
    let r = fast_acos(nu);
    let tangent = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), end_light_dir));
    let bitangent = normalize(cross(tangent, end_light_dir));
    let rel = ray_dir - end_light_dir;
    let q = vec2<f32>(dot(rel, tangent), dot(rel, bitangent));

    // Swirling radial solar flare (Photon's sky.glsl lines 330-340)
    let theta = fract((atan2(q.y, q.x) + pi) / tau + 0.015 * frame.time - 0.33 * r);
    let n_flare = textureSampleLevel(noisetex, noisetex_sampler, vec2<f32>(theta, r * 1.5 - 0.025 * frame.time), 0.0).x;
    let flare = pow(max0(n_flare), 5.0) * exp(-22.0 * max0(r - bh_radius));

    // Tilted accretion disc with gravitational lensing warp around the shadow
    let rot_a = 0.38;
    let c_a = cos(rot_a);
    let s_a = sin(rot_a);
    let qr = vec2<f32>(q.x * c_a - q.y * s_a, q.x * s_a + q.y * c_a);
    let warp_y = qr.y / max(1.0 - 0.55 * exp(-28.0 * max0(r - bh_radius * 0.8)), 0.2);
    let r_disc = length(vec2<f32>(qr.x * 0.85, warp_y * 4.2));
    let disc_ang = fract((atan2(qr.y * 4.2, qr.x) + pi) / tau + 0.06 * frame.time - 2.2 * r_disc);
    let disc_noise = textureSampleLevel(noisetex, noisetex_sampler, vec2<f32>(disc_ang * 2.0, r_disc * 6.0 - 0.04 * frame.time), 0.0).y;
    let disc_band = smoothstep(bh_radius * 0.9, bh_radius * 1.35, r_disc) * exp(-18.0 * max0(r_disc - bh_radius * 1.35));
    let doppler = 1.0 + 0.35 * clamp(qr.x / max(r_disc, 0.02), -1.0, 1.0);
    let accretion = disc_band * (0.45 + 0.95 * sqr(disc_noise)) * doppler;

    // Einstein photon ring + event horizon core
    let ring = exp(-12000.0 * sqr(r - bh_radius * 1.04)) * 2.2;
    let hole_mask = smoothstep(bh_radius * 1.03, bh_radius * 0.96, r);

    let end_sun = vec3<f32>(1.0, 0.5, 0.25) * rec709_to_rec2020;
    let violet = vec3<f32>(0.62, 0.28, 1.0) * rec709_to_rec2020;
    let plasma_col = mix(violet, end_sun, clamp01(accretion * 0.8 + ring * 0.4));

    let glow = end_sun * (flare * 0.45 + ring * 0.8) + plasma_col * (accretion * 1.65);
    return vec4<f32>(glow * (1.0 - hole_mask * 0.96), hole_mask);
}

fn nether_sky_color(ray_dir: vec3<f32>) -> vec3<f32> {
    let fog = max(linear_to_rec2020(frame.fog_color), vec3<f32>(0.025, 0.008, 0.004));
    let glow = smoothstep(0.5, -0.4, ray_dir.y);
    let n = textureSampleLevel(noisetex, noisetex_sampler,
        vec2<f32>(atan2(ray_dir.z, ray_dir.x) * rcp_pi + frame.time * 0.004, ray_dir.y * 0.6), 0.0).x;
    let base = fog * mix(0.45, 0.95, glow) * (0.85 + 0.3 * n);
    return base + vec3<f32>(0.09, 0.018, 0.003) * sqr(glow);
}
