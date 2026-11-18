// Photon lighting for entities, mobs, falling blocks, held items, and block entities

fn entity(input: EntityInput) -> Surface {
    let t = get_times();
    let dither = interleaved_gradient_noise(input.screen * frame.resolution + f32(frame.frame_index % 64u) * 5.588238);

    // Combine albedo, tint, and vanilla's hurt / TNT / creeper overlay flash in linear light
    let base_709 = input.albedo.rgb * input.tint.rgb;
    let flashed_709 = mix(base_709, input.overlay.rgb, input.overlay.a);
    let albedo = linear_to_rec2020(clamp01v(flashed_709));

    var m: Mat;
    m.albedo = albedo;
    m.sss_amount = 0.0;
    m.sheen_amount = 0.0;
    m.emission = 0.0;
    m.f0 = 0.02;
    m.roughness = 1.0;

    if input.emission > 0.5 {
        m.emission = 0.45;
    }
    if input.overlay.a > 0.05 && min_of(input.overlay.rgb) > 0.7 {
        // Swelling creeper / primed TNT white flash should clearly glow
        m.emission = max(m.emission, input.overlay.a * 0.35);
    }

    let normal = normalize(input.normal);
    let ray = normalize(input.position);
    let l = light_dir();
    let nol = dot(normal, l);
    let lov = dot(l, ray);
    let light_levels = clamp(input.light, vec2<f32>(0.0), vec2<f32>(1.0));

    var sh: ShadowResult;
    sh.light = vec3<f32>(1.0);
    sh.sss_depth = 0.0;
    sh.fade = 1.0;
    if in_overworld() {
        sh = get_shadows(input.position, normal, nol, 0.0, light_levels.y, dither);
    }

    var color = get_diffuse_lighting(
        m,
        input.position,
        normal,
        normal,
        light_levels,
        1.0,
        sh,
        nol,
        lov,
        t,
        input.colored_light,
    );

    color = purkinje_shift_apply(color, light_levels);
    return Surface(vec4<f32>(rec2020_to_linear(color), input.albedo.a * input.tint.a));
}
