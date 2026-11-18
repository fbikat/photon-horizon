// [[before_world]] compute pass: renders volumetric cloud shadow map into cloud_shadow_tex

fn compute(input: ComputeInput) {
    if !input.in_bounds {
        return;
    }
    let texel = vec2<i32>(input.cell.xy);
    if !cloud_shadows || !in_overworld() || (!clouds_cumulus && !clouds_cirrus) {
        textureStore(cloud_shadow_tex, texel, vec4<f32>(1.0, 1.0, 0.0, 1.0));
        return;
    }
    let ld = light_dir();
    if ld.y < -0.02 {
        textureStore(cloud_shadow_tex, texel, vec4<f32>(1.0, 1.0, 0.0, 1.0));
        return;
    }

    cp = clouds_parameters(get_weather());
    let uv = (vec2<f32>(input.cell.xy) + 0.5) / vec2<f32>(input.size.xy);
    let scene_p = unproject_cloud_shadow_pos(uv);
    let origin = vec3<f32>(scene_p.x, scene_p.y + frame.camera_position.y - 63.0, scene_p.z) * clouds_scale
        + vec3<f32>(0.0, planet_radius, 0.0);

    var shadow = 1.0;
    var shadow_cu = 1.0;
    let dist_fade_strength = 0.00000001 * pulse(ld.y, -0.01, 0.2);

    if clouds_cumulus && cp.coverage.y > eps {
        let ext = 0.25 * cp.extinction;
        let t = intersect_sphere_ray(origin, ld, cumulus_radius() + 0.25 * clouds_cumulus_thickness).y;
        if t > 0.0 {
            let pos = origin + ld * t;
            let df = exp2(-dist_fade_strength * length(pos.xz));
            let d = cumulus_density(pos, false);
            shadow *= exp(-df * ext * clouds_cumulus_thickness / (abs(ld.y) + eps) * d);
            shadow_cu = shadow;
        }
        if clouds_quality >= 1u && cp.l1_coverage.y > eps {
            let ext_ac = mix(0.05, 0.1, day_factor()) * clouds_cumulus_density * (1.0 - 0.33 * frame.rain);
            let t_ac = intersect_sphere_ray(origin, ld, altocumulus_radius() + 0.5 * clouds_altocumulus_thickness).y;
            if t_ac > 0.0 {
                let pos_ac = origin + ld * t_ac;
                let df_ac = exp2(-dist_fade_strength * length(pos_ac.xz));
                let d_ac = altocumulus_density(pos_ac, false);
                shadow *= exp(-df_ac * ext_ac * clouds_altocumulus_thickness / (abs(ld.y) + eps) * d_ac);
            }
        }
    }

    textureStore(cloud_shadow_tex, texel, vec4<f32>(shadow, shadow_cu, 0.0, 1.0));
}
