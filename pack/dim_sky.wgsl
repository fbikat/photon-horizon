// Photon-inspired Nether and End sky gradients and cosmic nebula helpers

fn end_sky_color(ray_dir: vec3<f32>) -> vec3<f32> {
    let horizon = pow(1.0 - abs(ray_dir.y), 2.5);
    var col = mix(vec3<f32>(0.010, 0.004, 0.022), vec3<f32>(0.048, 0.018, 0.088), horizon);
    let end_light_dir = normalize(vec3<f32>(0.0, 0.6, -0.8));
    let sun_glow = pow(max0(dot(ray_dir, end_light_dir)), 10.0);
    col += vec3<f32>(0.085, 0.036, 0.165) * sun_glow;
    let band_axis = normalize(vec3<f32>(0.25, 0.88, -0.40));
    let band = exp(-7.5 * sqr(dot(ray_dir, band_axis)));
    let uv_neb = vec2<f32>(atan2(ray_dir.z, ray_dir.x) * rcp_pi * 0.5 + 0.5, ray_dir.y * 0.5 + 0.5);
    let n1 = textureSampleLevel(noisetex, noisetex_sampler, uv_neb * 2.5, 0.0).x;
    let n2 = textureSampleLevel(noisetex, noisetex_sampler, uv_neb * 6.0 + vec2<f32>(0.17, 0.43), 0.0).y;
    let nebula = band * smoothstep(0.25, 0.9, n1 * 0.7 + n2 * 0.3);
    col += mix(vec3<f32>(0.16, 0.06, 0.34), vec3<f32>(0.08, 0.22, 0.38), n2) * nebula * 0.45;
    return col;
}

fn nether_sky_color(ray_dir: vec3<f32>) -> vec3<f32> {
    let fog = max(linear_to_rec2020(frame.fog_color), vec3<f32>(0.025, 0.008, 0.004));
    let glow = smoothstep(0.5, -0.4, ray_dir.y);
    let n = textureSampleLevel(noisetex, noisetex_sampler,
        vec2<f32>(atan2(ray_dir.z, ray_dir.x) * rcp_pi + frame.time * 0.004, ray_dir.y * 0.6), 0.0).x;
    let base = fog * mix(0.45, 0.95, glow) * (0.85 + 0.3 * n);
    return base + vec3<f32>(0.09, 0.018, 0.003) * sqr(glow);
}
