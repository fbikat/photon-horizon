// Photon lighting for entities, mobs, falling blocks, held items, and block entities

fn sample_cloud_shadow_ent(scene_pos: vec3<f32>) -> f32 {
    if !cloud_shadows || !clouds_cumulus || !in_overworld() {
        return 1.0;
    }
    let uv = project_cloud_shadow_uv(scene_pos);
    if any(uv < vec2<f32>(0.0)) || any(uv > vec2<f32>(1.0)) {
        return 1.0;
    }
    let cs = textureSampleLevel(cloud_shadow_tex, block_light_sampler, uv, 0.0).r;
    return cloud_shadow_factor(cs, get_cloud_shadow_fade(scene_pos));
}

fn entity(input: EntityInput) -> Surface {
    let t = get_times();
    let dither = interleaved_gradient_noise(input.screen * frame.resolution + temporal_noise_offset());

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

    // the layers vanilla draws at full brightness (spider and enderman eyes, the warden's glow)
    if input.full_light {
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
    // photon's LoV: dot(light_dir, -direction_world)
    let lov = dot(l, -ray);
    let light_levels = clamp(input.light, vec2<f32>(0.0), vec2<f32>(1.0));

    let cs = sample_cloud_shadow_ent(input.position);
    var sh: ShadowResult;
    sh.light = vec3<f32>(1.0);
    sh.sss_depth = 0.0;
    sh.fade = 1.0;
    sh.under_water = 0.0;
    if in_overworld() {
        sh = get_shadows(input.position, normal, nol, 0.0, light_levels.y, dither, cs);
    }

    let lres = get_diffuse_lighting(
        m,
        input.position,
        normal,
        normal,
        light_levels,
        1.0,
        sh,
        cs,
        nol,
        lov,
        t,
        input.colored_light,
        -1.0,
    );

    var color = purkinje_shift_apply(lres.total, light_levels);
    return Surface(vec4<f32>(rec2020_to_linear(color), input.albedo.a * input.tint.a));
}
