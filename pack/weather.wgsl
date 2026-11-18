// photon's gbuffers_weather: rain and snow lit by the weather colour

fn weather(input: WeatherInput) -> vec4<f32> {
    let k = smoothstep(-0.1, 0.5, frame.sun_direction.y);
    var color: vec3<f32>;
    if input.snow {
        color = mix(0.5, 1.6, k) * sunlight_color * vec3<f32>(0.49, 0.65, 1.0);
    } else {
        color = mix(0.033, 0.66, k) * sunlight_color * vec3<f32>(0.49, 0.65, 1.0);
    }
    if !in_overworld() {
        color = linear_to_rec2020(input.color.rgb);
    }
    let blocklight_color = get_blocklight_color() * blocklight_i;
    color = color * (0.2 + 0.8 * input.light.y) + blocklight_color * sqr(input.light.x);
    let alpha = select(0.4, 0.6, input.snow) * input.color.a;
    return vec4<f32>(rec2020_to_linear(color * 2.0), alpha);
}
