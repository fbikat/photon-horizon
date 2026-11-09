// keeps this frame's accumulated clouds for the next frame's clouds pass, which cannot read its own target

fn post(input: PostInput) -> vec4<f32> {
    return textureSampleLevel(clouds_tex, nearest_sampler, input.uv, 0.0);
}
