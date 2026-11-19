// Shared lighting, PCSS shadows, water caustics, SSS, colored blocklight, and GGX specular helpers for [material] and [entity]

struct Mat {
    albedo: vec3<f32>,
    sss_amount: f32,
    sheen_amount: f32,
    emission: f32,
    f0: f32,
    roughness: f32,
}

// vanilla's face shade, baked into a ray-traced terrain hit's tint (MaterialInput gives it apart); photon
// shades faces itself
fn vanilla_face_shade(n: vec3<f32>) -> f32 {
    let a = abs(n);
    // Faces off the axes are cross plants (grass, flowers, saplings), which vanilla draws unshaded
    // ("shade": false): there is no shade to undo. Comparing their equal x and z picked 0.6 or 0.8 pixel by
    // pixel, which speckled them and brightened their colour 1.6 to 3 times.
    if max_of(a) < 0.9 {
        return 1.0;
    }
    if a.y > a.x && a.y > a.z {
        return select(0.5, 1.0, n.y > 0.0);
    }
    return select(0.6, 0.8, a.z > a.x);
}

// Photon's block light colour: one warm colour (get_blocklight_color), or with colored_lights the [[lights]] grid's
// colour where a light of its own colour is near (Photon's LPV colours are off by default; the player's Java
// default is the single warm colour, so off here matches it).
fn block_light_tint(position: vec3<f32>) -> vec3<f32> {
    if !colored_lights {
        return get_blocklight_color() * blocklight_i;
    }
    let grid_c = block_light_color(position);
    return mix(get_blocklight_color(), linear_to_rec2020(grid_c.rgb), clamp01(grid_c.a * 1.6)) * blocklight_i;
}

// Dynamic and particle lights (input.colored_light): their own colour, or with colored_lights off the same
// brightness in the warm block light colour.
fn dynamic_light_tint(colored_light: vec3<f32>) -> vec3<f32> {
    let c = linear_to_rec2020(colored_light);
    if !colored_lights {
        return get_blocklight_color() * dot(c, luminance_weights);
    }
    return c;
}

fn get_blocklight_falloff(blocklight: f32, skylight: f32, ao: f32, t: Times) -> f32 {
    var falloff = pow8(blocklight) + 0.18 * sqr(blocklight) + 0.16 * dampen(blocklight);
    falloff *= mix(cube(ao), 1.0, clamp01(falloff));
    falloff *= mix(1.0, ao * dampen(abs(cos(2.0 * frame.time))) * 0.67 + 0.2, frame.darkness);
    falloff *= 1.0 - 0.2 * t.noon * skylight - 0.2 * skylight;
    falloff += min(2.7 * pow12(blocklight), 0.9);
    falloff *= smoothstep(0.0, 0.125, blocklight);
    return falloff;
}

// photon's include/fog/simple_fog.glsl biome_water_coeff (BIOME_WATER_COLOR): water's absorption, a third
// of it from the biome's water colour
fn biome_water_coeff(biome_water_color: vec3<f32>) -> vec3<f32> {
    let base = vec3<f32>(0.39, 0.14, 0.07) * water_absorption * rec709_to_rec2020;
    let forest = -0.15 * log(vec3<f32>(0.1245, 0.1797, 0.7108));
    let biome = -0.15 * log(biome_water_color + eps) - forest;
    return max(base + biome * 0.33, vec3<f32>(0.0));
}

// The sunlight that reaches under water, as photon's shadow pass writes it for water: what is left after
// 5 m of it (its distance_through_water), scaled to photon's brightness there. `shadow_texel` is
// shadow_color's: the water's texture times its biome tint; vanilla's water texture is a grey of linear 0.447.
fn water_sun_transmittance(shadow_texel: vec3<f32>) -> vec3<f32> {
    let biome = linear_to_rec2020(shadow_texel / 0.447);
    return select(water_sun_scale, 0.25, photon_caustics) * exp(-5.0 * biome_water_coeff(biome));
}

// photon's include/surface/water_normal.glsl
fn gerstner_wave(coord: vec2<f32>, wave_dir: vec2<f32>, t: f32, noise: f32, wavelength: f32) -> f32 {
    let k = tau / wavelength;
    let w = sqrt(9.8 * k);
    let x = w * t - k * (dot(wave_dir, coord) + noise);
    return sqr(sin(x) * 0.5 + 0.5);
}

// `octaves` of the 3: the finest are smaller than a pixel far away, where only the specular AA's widening can
// show them, so the far water leaves them out (material.wgsl water_normal)
fn get_water_height_lod(coord: vec2<f32>, flowing: bool, flow_dir: vec2<f32>, octaves: i32) -> f32 {
    let t = select(0.5, 0.7, flowing) * frame.time;
    let angle = 30.0 * degree;
    var wave_dir = select(vec2<f32>(cos(angle), sin(angle)), flow_dir, flowing);
    var rot = mat2x2<f32>(vec2<f32>(cos(golden_angle), sin(golden_angle)), vec2<f32>(-sin(golden_angle), cos(golden_angle)));
    if flowing {
        rot = mat2x2<f32>(vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0));
    }
    let persistence = 0.5;
    let norm = (1.0 - persistence) / (1.0 - pow(persistence, 3.0));
    var noise_coord = (coord + vec2<f32>(0.0, 0.25 * t)) * 0.007;
    var height = 0.0;
    var amplitude = 1.0;
    var frequency = 0.7;
    var wavelength = 1.0;
    for (var i = 0; i < octaves; i++) {
        let n = textureSampleLevel(noisetex, noisetex_sampler, noise_coord, 0.0).y;
        noise_coord *= 2.5;
        height += gerstner_wave(coord * frequency, wave_dir, t, n * 2.0, wavelength) * amplitude;
        amplitude *= persistence;
        frequency *= 1.7;
        wavelength *= 1.5;
        wave_dir = wave_dir * rot;
    }
    let variation = textureSampleLevel(noisetex, noisetex_sampler, (coord + vec2<f32>(0.0, 0.1 * t)) * 0.001, 0.0).y;
    height *= max(0.4, variation * 2.0 - 0.5);
    return height * norm;
}

fn get_water_height(coord: vec2<f32>, flowing: bool, flow_dir: vec2<f32>) -> f32 {
    return get_water_height_lod(coord, flowing, flow_dir, 3);
}

// The shadow at a point from one bilinear lookup of the shadow map at the normal-offset position, without
// get_shadows' blocker search and filter taps: for what only needs a yes or no, such as the sun's glint on water
// (1 where there is no shadow map under the point)
fn get_shadow_cheap(position: vec3<f32>, flat_normal: vec3<f32>, nol: f32) -> f32 {
    if frame.has_shadow == 0u {
        return 1.0;
    }
    let texel_blocks = max(frame.shadow_center_texel, 1e-4);
    let clip0 = (frame.shadow_view_proj * vec4<f32>(position, 1.0)).xyz;
    let bias = flat_normal * texel_blocks * distortion_factor(clip0.xy) * (1.5 + 2.0 * (1.0 - abs(nol)));
    let clip = (frame.shadow_view_proj * vec4<f32>(position + bias, 1.0)).xyz;
    let d = shadow_distort(clip.xy);
    if max(abs(d.x), abs(d.y)) >= 1.0 || clip.z >= 1.0 {
        return 1.0;
    }
    return textureSampleCompareLevel(shadow_map, shadow_sampler, shadow_uv(clip.xy), clip.z);
}


// Photon's water caustics (program/shadow.fsh get_water_caustics): the sunlight under water is the area ratio of a
// shadow texel's footprint on the surface to where it lands 5 m down once the wave normals have refracted it.
// Photon draws water into its shadow map and stores 0.25 * exp(-5 absorption) * 0.25 * ratio (read back x4), so a
// flat surface gives 0.25 exp(-5 absorption), what water_sun_transmittance keeps as its scale, and the ratio
// goes in caustic_mul. Horizon runs no pack code in its shadow pass: the material stage finds the surface the sun
// ray crossed (the translucent shadow map's depth, ShadowResult.water_dist), evaluates the same wave height
// field the water surface uses at three points a shadow texel apart, and takes the ratio there.
fn refract_safe(i: vec3<f32>, n: vec3<f32>, eta: f32) -> vec3<f32> {
    let noi = dot(n, i);
    let k = 1.0 - eta * eta * (1.0 - noi * noi);
    if k < 0.0 {
        return vec3<f32>(0.0);
    }
    return eta * i - (eta * noi + sqrt(k)) * n;
}

// the wave normal of get_water_normal for still water at world xz `coord`, with photon's influence for the
// shadow pass (skylight 1 - rain); `view_cos` is its smoothstep's |flat normal . view direction|
fn caustic_water_normal(coord: vec2<f32>, view_cos: f32) -> vec3<f32> {
    let h = 0.1;
    let w0 = get_water_height(coord, false, vec2<f32>(0.0));
    let w1 = get_water_height(coord + vec2<f32>(h, 0.0), false, vec2<f32>(0.0));
    let w2 = get_water_height(coord + vec2<f32>(0.0, h), false, vec2<f32>(0.0));
    var influence = mix(0.01, 0.04 + 0.15 * frame.rain, dampen(1.0 - frame.rain));
    influence *= smoothstep(0.0, 0.15, view_cos) * water_wave_strength;
    return normalize(vec3<f32>(-(w1 - w0) * influence, h, -(w2 - w0) * influence));
}

fn water_caustic_ratio(position: vec3<f32>, sh: ShadowResult) -> f32 {
    let ld = light_dir();
    if ld.y < 0.05 || sh.water_dist <= 0.0 {
        return 1.0;
    }
    // the surface point on the sun ray, in world coordinates
    let s = position + frame.camera_position + ld * sh.water_dist;
    let view_cos = abs(s.y - frame.camera_position.y) / max(length(s - frame.camera_position), 1e-3);
    // one shadow texel along the shadow map's two axes, carried along the light onto the flat surface
    let basis = cloud_shadow_basis(ld);
    let step_len = max(sh.texel, 1e-3);
    let vx = basis.right * step_len;
    let vy = basis.fwd * step_len;
    let ox = vx - ld * (vx.y / ld.y);
    let oy = vy - ld * (vy.y / ld.y);
    let eta = 1.0 / 1.333;
    // photon refracts the light direction itself (toward the sun) about the normal, 5 m down
    let n0 = caustic_water_normal(s.xz, view_cos);
    let nx = caustic_water_normal(s.xz + ox.xz, view_cos);
    let ny = caustic_water_normal(s.xz + oy.xz, view_cos);
    let new0 = refract_safe(ld, n0, eta) * 5.0;
    let dnx = ox + refract_safe(ld, nx, eta) * 5.0 - new0;
    let dny = oy + refract_safe(ld, ny, eta) * 5.0 - new0;
    let old_area = dot(ox, ox) * dot(oy, oy);
    let new_area = dot(dnx, dnx) * dot(dny, dny);
    if old_area <= 0.0 || new_area <= 0.0 {
        return 1.0;
    }
    // photon's 0.25 * inversesqrt(old / new), with its 0.25 and the x4 read-back cancelled, clamped as its 8-bit
    // shadow colour saturates
    return clamp(sqrt(new_area / old_area), 0.0, 16.0);
}

// Animated underwater light caustics pattern projected along light_dir()
fn get_water_caustics(world_pos: vec3<f32>) -> f32 {
    let t = frame.time * 0.25;
    let basis = cloud_shadow_basis(light_dir());
    let cpos = vec2<f32>(dot(world_pos, basis.right), dot(world_pos, basis.fwd));
    let d0 = vec2<f32>(0.8775826, 0.4794255);
    let d1 = vec2<f32>(-0.9899925, 0.1411200);
    let n0 = textureSampleLevel(noisetex, noisetex_sampler, (cpos + d0 * t) * 0.035, 0.0).y;
    let n1 = textureSampleLevel(noisetex, noisetex_sampler, (cpos + d1 * t) * 0.055, 0.0).y;
    let edge0 = 1.0 - abs(n0 * 2.0 - 1.0);
    let edge1 = 1.0 - abs(n1 * 2.0 - 1.0);
    let fil = pow(clamp01(edge0 * edge1 * 1.4), 2.2);
    return 0.55 + fil * 2.15;
}

fn sss_approx(albedo: vec3<f32>, sss_amount: f32, sheen_amount: f32, sss_depth: f32, lov: f32) -> vec3<f32> {
    if sss_amount < eps {
        return vec3<f32>(0.0);
    }
    let sss_density = 14.0;
    let sss_scale = 5.0 * sss_intensity;
    var coeff = albedo / sqrt(dot(albedo, luminance_weights) + eps);
    coeff = 0.75 * clamp01v(coeff);
    coeff = (1.0 - coeff) * sss_density / sss_amount;
    let phase = mix(isotropic_phase, henyey_greenstein_phase(-lov, 0.7), 0.33);
    var sss = sss_scale * phase * exp2(-coeff * sss_depth) * dampen(sss_amount) * pi;
    let sheen = (0.8 * sss_intensity) / (albedo + eps) * exp2(-coeff * sss_depth)
        * henyey_greenstein_phase(-lov, 0.5) * linear_step(-0.8, -0.2, -lov);
    sss += sheen * sheen_amount;
    return sss;
}

// shadows (photon's include/lighting/shadows/pcss.glsl on horizon's map)
fn shadow_uv(clip_xy: vec2<f32>) -> vec2<f32> {
    let d = shadow_distort(clip_xy);
    return vec2<f32>(d.x * 0.5 + 0.5, 0.5 - d.y * 0.5);
}

fn distortion_factor(clip_xy: vec2<f32>) -> f32 {
    let k = frame.shadow_distortion;
    return length(clip_xy) * k + 1.0 - k;
}

struct ShadowResult {
    light: vec3<f32>,
    sss_depth: f32,
    fade: f32,
    under_water: f32,
    // blocks along the light from the point to the water surface above it (0: not under water), and the shadow
    // map's texel size in blocks there: what water_caustic_ratio needs
    water_dist: f32,
    texel: f32,
}

fn get_shadows(position: vec3<f32>, flat_normal: vec3<f32>, nol: f32, sss_amount: f32, skylight: f32, dither: f32, cloud_shadow: f32) -> ShadowResult {
    var r: ShadowResult;
    r.light = vec3<f32>(1.0);
    r.sss_depth = 0.0;
    r.fade = 1.0;
    r.under_water = 0.0;
    r.water_dist = 0.0;
    r.texel = 0.0;
    if frame.has_shadow == 0u {
        return r;
    }
    let dist_blocks = frame.shadow_distance;
    let res = frame.shadow_resolution;
    let texel_blocks = max(frame.shadow_center_texel, 1e-4);

    // normal offset bias, larger at grazing light and far from the map's centre
    let clip0 = (frame.shadow_view_proj * vec4<f32>(position, 1.0)).xyz;
    let df0 = distortion_factor(clip0.xy);
    var bias = flat_normal * texel_blocks * df0 * (1.5 + 2.0 * (1.0 - abs(nol)));
    if sss_amount > eps {
        // Plants and leaves are lit from behind through subsurface scattering, so their face's normal
        // (toward the camera) often points away from the light, and the thin blade is itself in the shadow
        // map: offsetting along that normal compared against the blade's own depth, which showed as moire
        // stripes crawling over it as it waved. Offset toward the light instead.
        let ld = light_dir();
        let n_lit = select(flat_normal, -flat_normal, dot(flat_normal, ld) < 0.0);
        bias = (1.5 * n_lit + 2.0 * ld) * texel_blocks * df0;
    }
    r.texel = texel_blocks * df0;
    let p = position + bias;
    let clip = (frame.shadow_view_proj * vec4<f32>(p, 1.0)).xyz;
    let edge = max(abs(shadow_distort(clip.xy).x), abs(shadow_distort(clip.xy).y));
    r.fade = linear_step(0.85, 1.0, edge);
    if r.fade >= 1.0 || clip.z >= 1.0 {
        r.fade = 1.0;
        return r;
    }
    let ref_z = clip.z;
    let z_per_block = length(vec3<f32>(frame.shadow_view_proj[0][2], frame.shadow_view_proj[1][2], frame.shadow_view_proj[2][2]));
    let isize = vec2<i32>(i32(res), i32(res));

    // blocker search, in the map with water and glass drawn in (photon's shadowtex0): under water the
    // surface is always the blocker. In the opaque map a point under water found none, or only itself at
    // some dither rotations, and took the early return's untinted sunlight: bright speckles across the
    // sea floor once water dims and tints the light reaching it.
    var penumbra = 0.5 / sqrt(2.0) * shadow_penumbra_scale * (1.0 + 7.0 * sss_amount) / res * 2.0;
    if shadow_vps {
        let steps = select(3, 9, sss_amount > eps);
        let radius = 0.5 / dist_blocks * (0.5 + 0.5 * linear_step(0.2, 0.4, light_dir().y));
        var depth_sum = 0.0;
        var weight_sum = 0.0;
        var sss_sum = 0.0;
        for (var i = 0; i < steps; i++) {
            let off = vogel_disc_sample(i, steps, dither * tau) * radius;
            let uv = shadow_uv(clip.xy + off);
            let texel = clamp(vec2<i32>(uv * res), vec2<i32>(0), isize - 1);
            let d = textureLoad(shadow_map_translucent, texel, 0);
            let w = step(d, ref_z);
            depth_sum += w * d;
            weight_sum += w;
            sss_sum += max0(ref_z - d);
        }
        r.sss_depth = sss_sum / (z_per_block * f32(steps));
        if nol < 1e-3 {
            r.light = vec3<f32>(0.0);
            return r;
        }
        if weight_sum == 0.0 {
            return r;
        }
        let blocker = depth_sum / weight_sum;
        let blocks_between = (ref_z - blocker) / z_per_block;
        // photon widens the penumbra inside cloud shadows (5 - 4 * cloud_shadows): a soft, overcast look
        penumbra = min(0.04 * shadow_penumbra_scale * blocks_between * (5.0 - 4.0 * cloud_shadow), 0.5) / dist_blocks;
    } else if nol < 1e-3 && sss_amount < eps {
        r.light = vec3<f32>(0.0);
        return r;
    }

    // vogel pcf with photon's sharpening
    let min_radius = 2.0 / res * distortion_factor(clip.xy);
    let filter_radius = max(penumbra, min_radius);
    let filter_scale = sqr(filter_radius / min_radius);
    let count = clamp(6 + i32(filter_scale), 4, max(shadow_pcf_steps, 4));
    var lit = 0.0;
    var color_sum = vec3<f32>(0.0);
    var water_sum = 0.0;
    var water_dist_sum = 0.0;
    let check_trans = colored_shadows || water_caustics;
    for (var i = 0; i < count; i++) {
        let off = vogel_disc_sample(i, count, dither * tau) * filter_radius;
        let uv = shadow_uv(clip.xy + off);
        let s = textureSampleCompareLevel(shadow_map, shadow_sampler, uv, ref_z);
        lit += s;
        if check_trans && i < 4 {
            let st = textureSampleCompareLevel(shadow_map_translucent, shadow_sampler, uv, ref_z);
            let texel = clamp(vec2<i32>(uv * vec2<f32>(textureDimensions(shadow_color))), vec2<i32>(0), vec2<i32>(textureDimensions(shadow_color)) - 1);
            let c = textureLoad(shadow_color, texel, 0);
            let is_water_occl = c.a >= 0.999;
            if is_water_occl && st < 0.5 && s > 0.5 {
                water_sum += 1.0;
                if photon_caustics {
                    let wtexel = clamp(vec2<i32>(uv * res), vec2<i32>(0), isize - 1);
                    water_dist_sum += max0(ref_z - textureLoad(shadow_map_translucent, wtexel, 0)) / z_per_block;
                }
            }
            if colored_shadows {
                let water_tint = select(vec3<f32>(1.0), water_sun_transmittance(c.rgb), water_sun_absorption);
                let tint = select(linear_to_rec2020(c.rgb), water_tint, is_water_occl);
                color_sum += mix(tint, vec3<f32>(1.0), st);
            }
        }
    }
    r.under_water = water_sum * 0.25;
    r.water_dist = water_dist_sum / max(water_sum, 1.0);
    let color = select(vec3<f32>(1.0), color_sum * 0.25, colored_shadows);
    let sharpen = 0.4 * max0((min_radius - penumbra) / min_radius);
    let shadow = linear_step(sharpen, 1.0 - sharpen, lit / f32(count));
    r.light = shadow * color;
    return r;
}

struct LightingResult {
    total: vec3<f32>,
    direct_sun: vec3<f32>,
    // the dimension's ambient light (the Overworld's skylight, the End's, the Nether's): the part photon's GTAO
    // darkens, which the post pass applies from the surface data the material stage packs
    ambient: vec3<f32>,
}

fn get_diffuse_lighting(
    m: Mat,
    position: vec3<f32>,
    normal: vec3<f32>,
    flat_normal: vec3<f32>,
    light_levels: vec2<f32>,
    ao: f32,
    sh: ShadowResult,
    cloud_shadow: f32,
    nol: f32,
    lov: f32,
    t: Times,
    colored_light: vec3<f32>,
    gtao_sss: f32,
) -> LightingResult {
    var lighting = vec3<f32>(0.0);
    var sun_part = vec3<f32>(0.0);
    var ambient_part = vec3<f32>(0.0);
    // Photon's ambient_sss is the share of the hemisphere behind a face its GTAO finds open: skylight that
    // comes through a leaf or blade. The GTAO runs after shading here, so gtao_sss is last frame's, from the
    // GTAO pass (post/vlao.wgsl) reprojected to this pixel; where there is none (a disocclusion, off screen,
    // GTAO off, entities: gtao_sss < 0) this takes a typical open-air value (photon's runs 0 to 0.5), closed in
    // by the corner AO.
    let ambient_sss = select(0.0, select(0.25 * ao, gtao_sss, gtao_sss >= 0.0), foliage_ambient_sss && m.sss_amount > eps);
    let directional = (0.9 + 0.1 * normal.x) * (0.8 + 0.2 * abs(flat_normal.y)) + 2.0 * ambient_sss * m.sss_amount;
    let sss_blocked = light_levels.y < 0.1;
    let overworld = in_overworld();

    var caustic_mul = 1.0;
    if water_caustics && overworld {
        if photon_caustics {
            // past 48 to 80 blocks a shadow texel is smaller than a pixel and the pattern only aliases: its mean, 1
            let reach = 1.0 - smoothstep(48.0, 80.0, length(position));
            if sh.under_water > 0.01 && reach > 0.01 {
                caustic_mul = mix(1.0, mix(1.0, water_caustic_ratio(position, sh), reach), sh.under_water);
            }
        } else {
            let distant_water = select(0.0, sh.fade * smoothstep(0.25, 0.75, light_levels.y), frame.eye_in == 1u);
            let c_mask = max(sh.under_water, distant_water);
            if c_mask > 0.01 {
                caustic_mul = mix(1.0, get_water_caustics(position + frame.camera_position), c_mask);
            }
        }
    }

    if overworld && frame.has_shadow != 0u {
        let diffuse = vec3<f32>(lift(max0(nol), 0.25 / shading_strength) * (1.0 - 0.5 * m.sss_amount));
        let shadows = sh.light * cloud_shadow;
        let bounced = 0.033 * (1.0 - shadows) * (1.0 - 0.1 * max0(normal.y))
            * pow1d5(ao + eps) * pow4(light_levels.y) * bounced_light_i;
        var sss = sss_approx(m.albedo, m.sss_amount, m.sheen_amount, mix(sh.sss_depth, 0.0, sh.fade), lov)
            * select(1.0, 0.0, sss_blocked) * cloud_shadow;
        sss *= mix(1.0, (ao + pi * ambient_sss) * (clamp01(nol) * 0.8 + 0.2), clamp01(sh.fade));
        let shadow_mix = mix(shadows, vec3<f32>(sqr(light_levels.y) * cloud_shadow), sh.fade);
        let lc = get_light_color() * caustic_mul;
        sun_part = (diffuse * shadow_mix + sss) * lc;
        lighting += sun_part + bounced * get_light_color();
    } else if overworld {
        let sss = 0.08 * 5.0 * sss_intensity * pi
            + 0.5 * m.sheen_amount / (m.albedo + eps) * henyey_greenstein_phase(-lov, 0.5) * linear_step(-0.8, -0.2, -lov);
        let shadows = sqr(light_levels.y);
        var diffuse = vec3<f32>(lift(max0(nol), 0.5 / shading_strength) * 0.6 + 0.4) * (shadows * 0.8 + 0.2);
        diffuse = diffuse + max(sss * lift(m.sss_amount, 5.0), vec3<f32>(0.0));
        diffuse *= directional * ao * pow4(light_levels.y) * (dampen(light_dir().y) * 0.5 + 0.5) * cloud_shadow;
        sun_part = diffuse * get_light_color() * caustic_mul;
        lighting += sun_part;
    }

    // skylight / dimension ambient (photon's get_sky_lighting)
    if overworld {
        var sky_up: vec3<f32>;
        var skylight: vec3<f32>;
        if sh_skylight {
            var sky_sh: array<vec3<f32>, 9>;
            for (var i = 0u; i < 9u; i++) {
                sky_sh[i] = textureLoad(cloud_shadow_tex, sky_sh_texel(i), 0).rgb;
            }
            sky_up = textureLoad(cloud_shadow_tex, sky_sh_texel(SKY_SH_UP), 0).rgb;
            skylight = mix(sky_up, sh_irradiance(sky_sh, normal, ao), sqr(light_levels.y));
        } else {
            sky_up = get_sky_color() * get_skylight_boost();
            skylight = sky_up * ao;
        }
        sky_up *= skylight_i;
        skylight *= skylight_i;
        skylight = mix(skylight, 0.5 * sky_up * ao, m.sss_amount);
        ambient_part += skylight * sqr(light_levels.y);
        skylight += ambient_sss * sky_up * m.sss_amount * 2.0;
        lighting += skylight * sqr(light_levels.y);
    } else if in_end() {
        let end_ld = normalize(vec3<f32>(0.0, 0.5299989, -0.8479983));
        let end_nol = max0(dot(normal, end_ld)) * 0.65 + 0.35;
        let end_ambient = vec3<f32>(0.36, 0.28, 0.56) * directional * end_nol * ao * 1.15;
        ambient_part += end_ambient;
        lighting += end_ambient;
    } else if in_nether() {
        let fog = max(linear_to_rec2020(frame.fog_color), vec3<f32>(0.04, 0.015, 0.008));
        let lava_bounce = mix(0.85, 1.2, clamp01(-normal.y * 0.5 + 0.5));
        let nether_ambient = 16.0 * directional * lava_bounce * mix(fog, vec3<f32>(dot(fog, luminance_weights)), 0.45) * 0.055 * ao;
        ambient_part += nether_ambient;
        lighting += nether_ambient;
    } else {
        let fog = linear_to_rec2020(frame.fog_color);
        let other_ambient = 16.0 * directional * mix(fog, vec3<f32>(dot(fog, luminance_weights)), 0.5) * 0.05 * ao;
        ambient_part += other_ambient;
        lighting += other_ambient;
    }

    // colored block light (from [[lights]] grid blended cleanly with warm torch default) + dynamic/particle lights
    let blocklight_col = block_light_tint(position);
    let falloff = get_blocklight_falloff(light_levels.x, light_levels.y, ao, t);
    lighting += falloff * directional * 6.0 * blocklight_col;
    lighting += dynamic_light_tint(colored_light) * 6.0 * blocklight_i;

    lighting += m.emission * 40.0 * emission_strength;

    if overworld {
        lighting += 0.15 * cave_lighting_i * directional * ao * (1.0 - sqr(light_levels.y)) * (1.0 - 0.7 * frame.darkness);
    }
    lighting += frame.night_vision * 1.5 * directional * ao;
    let inv_pi = m.albedo * rcp_pi;
    return LightingResult(max(lighting, vec3<f32>(0.0)) * inv_pi, max(sun_part, vec3<f32>(0.0)) * inv_pi, max(ambient_part, vec3<f32>(0.0)) * inv_pi);
}

// ggx sun highlight (photon's include/lighting/specular_lighting.glsl get_specular_highlight)
fn d_ggx(noh: f32, alpha_sq: f32) -> f32 {
    let f = (noh * alpha_sq - noh) * noh + 1.0;
    return alpha_sq / (pi * f * f);
}

fn v2_smith_ggx(nol: f32, nov: f32, alpha_sq: f32) -> f32 {
    let ggxl = nov * sqrt((-nol * alpha_sq + nol) * nol + alpha_sq);
    let ggxv = nol * sqrt((-nov * alpha_sq + nov) * nov + alpha_sq);
    return 0.5 / max(ggxl + ggxv, eps);
}

fn fresnel_schlick(cos_theta: f32, f0: f32) -> f32 {
    let f = 1.0 - clamp01(cos_theta);
    let f2 = f * f;
    return clamp(f0 + (1.0 - f0) * (f2 * f2 * f), 0.0, 1.0);
}

fn fresnel_dielectric(cos_theta: f32, n: f32) -> f32 {
    let c = clamp(cos_theta, 0.0, 1.0);
    let g2 = max(n * n + c * c - 1.0, 0.0);
    let g = sqrt(g2);
    let a = (g - c) / max(g + c, eps);
    let b = (c * (g + c) - 1.0) / max(c * (g - c) + 1.0, eps);
    return clamp(0.5 * a * a * (1.0 + b * b), 0.0, 1.0);
}

// GGX spherical area light approximation from Horizon: Zero Dawn (photon's get_NoH_squared): (N.H)^2 with H bent
// toward the closest point of the light's disc to the reflection vector, so the highlight is the sun's disc, not a point
fn get_noh_squared(nol: f32, nov: f32, lov: f32, light_radius: f32) -> f32 {
    let radius_cos = cos(light_radius);
    let radius_tan = tan(light_radius);
    // early out if R falls within the disc
    let rol = 2.0 * nol * nov - lov;
    if rol >= radius_cos {
        return 1.0;
    }
    let r_over_length_t = radius_cos * radius_tan * inverseSqrt(max(1.0 - rol * rol, 1e-6));
    var not_r = r_over_length_t * (nov - rol * nol);
    var vot_r = r_over_length_t * (2.0 * nov * nov - 1.0 - rol * lov);
    // dot(cross(N, L), V)
    let triple = sqrt(clamp01(1.0 - nol * nol - nov * nov - lov * lov + 2.0 * nol * nov * lov));
    // one Newton iteration to improve the bent light direction
    let nob_r = r_over_length_t * triple;
    let vob_r = r_over_length_t * (2.0 * triple * nov);
    let nol_vt_r = nol * radius_cos + nov + not_r;
    let lov_vt_r = lov * radius_cos + 1.0 + vot_r;
    let p = nob_r * lov_vt_r;
    let q = nol_vt_r * lov_vt_r;
    let s = vob_r * nol_vt_r;
    let x_num = q * (-0.5 * p + 0.25 * vob_r * nol_vt_r);
    let x_denom = p * p + s * (s - 2.0 * p)
        + nol_vt_r * ((nol * radius_cos + nov) * lov_vt_r * lov_vt_r
            + q * (-0.5 * (lov_vt_r + lov * radius_cos) - 0.5));
    let two_x_1 = 2.0 * x_num / max(x_denom * x_denom + x_num * x_num, 1e-12);
    let sin_theta = two_x_1 * x_denom;
    let cos_theta = 1.0 - two_x_1 * x_num;
    not_r = cos_theta * not_r + sin_theta * nob_r;
    vot_r = cos_theta * vot_r + sin_theta * vob_r;
    // (N.H)^2 from the bent light direction
    let new_nol = nol * radius_cos + not_r;
    let new_lov = lov * radius_cos + vot_r;
    let noh = nov + new_nol;
    let hoh = 2.0 * new_lov + 2.0;
    return clamp01(noh * noh / max(hoh, 1e-6));
}

// `lov`: dot(light, toward the viewer). The result is capped at photon's specular_max_value (4) so a glint can't
// overload the bloom; `alpha_extra` widens the lobe (alpha^2 added, see material.wgsl's specular AA).
fn specular_highlight(roughness: f32, f0: f32, nol: f32, nov: f32, lov: f32, loh: f32, light_color: vec3<f32>, alpha_extra: f32) -> vec3<f32> {
    if nol <= 0.0 || nov <= 0.0 {
        return vec3<f32>(0.0);
    }
    let alpha = max(roughness, 0.002);
    let alpha_sq = min(alpha * alpha + alpha_extra, 1.0);
    let light_radius = select(sun_radius(), moon_angular_radius(), is_night());
    let nh2 = get_noh_squared(nol, nov, lov, light_radius);
    let f = (nh2 * alpha_sq - nh2) + 1.0;
    let d = alpha_sq / (pi * f * f);
    let g2 = v2_smith_ggx(max(nol, 1e-2), max(nov, 1e-2), alpha_sq);
    let fr = fresnel_schlick(loh, f0);
    return light_color * min(nol * d * g2 * fr, 4.0);
}
