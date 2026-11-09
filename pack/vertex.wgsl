// photon's include/vertex/displacement.glsl: wind on plants and leaves

// cos and sin of photon's 30 degree wind angle
const wind_dir_30 = vec2<f32>(0.8660254, 0.5);

fn value_noise_2d(p: vec2<f32>) -> f32 {
    let i = floor(p);
    var f = p - i;
    f = f * f * (3.0 - 2.0 * f);
    let a = hash2(i).x;
    let b = hash2(i + vec2<f32>(1.0, 0.0)).x;
    let c = hash2(i + vec2<f32>(0.0, 1.0)).x;
    let d = hash2(i + vec2<f32>(1.0, 1.0)).x;
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

fn get_wind_displacement(world_pos0: vec3<f32>, wind_speed: f32, wind_strength0: f32, tall_top: bool) -> vec3<f32> {
    let wind_dir = wind_dir_30;
    let wind_strength = wind_strength0 * (0.5 + get_weather().wind);
    let t = wind_speed * frame.time;
    // horizon's shadow pass binds no pack textures, so photon's noisetex read is value noise here
    var gust_amount = value_noise_2d(0.5 * (world_pos0.xz + wind_dir * t));
    gust_amount *= gust_amount;
    var gust = vec3<f32>(wind_dir.x * gust_amount, 0.1 * gust_amount, wind_dir.y * gust_amount);
    let p = 32.0 * world_pos0 + 3.0 * t + vec3<f32>(0.0, golden_angle, 2.0 * golden_angle);
    var wobble = sin(p) + 0.5 * sin(2.0 * p) + 0.25 * sin(4.0 * p);
    if tall_top {
        gust *= 2.0;
        wobble *= 0.5;
    }
    return wind_strength * (gust + 0.1 * wobble);
}

fn vertex(input: VertexInput) -> vec3<f32> {
    let m = input.material;
    let plant = m == 2u || m == 3u || m == 4u;
    if !((plant && waving_plants) || (m == 5u && waving_leaves)) || !in_overworld() {
        return input.position;
    }
    // world position wrapped so the sines keep their precision far out
    let world_pos = input.position + fract(frame.camera_position / 256.0) * 256.0;
    let skylight = input.light.y;
    let wind_strength = sqr(skylight) * (0.25 + 0.66 * frame.rain);
    let to_player = -input.position;
    let player = -6.0 * to_player.xz * exp2(-length(to_player * vec3<f32>(6.0, 2.0, 6.0)));
    let player_displacement = vec3<f32>(player.x, 0.0, player.y);
    let is_top = input.uv.y < 0.5;
    switch m {
        case 2u, 3u: {
            return input.position + (get_wind_displacement(world_pos, 0.3, wind_strength, false) + player_displacement) * select(0.0, 1.0, is_top);
        }
        case 4u: {
            return input.position + get_wind_displacement(world_pos, 0.3, wind_strength, is_top) + player_displacement;
        }
        default: {
            return input.position + get_wind_displacement(world_pos, 0.3, wind_strength * 0.5, false);
        }
    }
}
