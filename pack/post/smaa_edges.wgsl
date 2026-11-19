// SMAA 1x, pass 1 of 3 (Jimenez et al., "SMAA: Enhanced Subpixel Morphological Antialiasing", MIT):
// luma edge detection with local contrast adaptation. r: an edge on the pixel's left side, g: on its top.

const SMAA_THRESHOLD: f32 = 0.08;
// SMAA_LOCAL_CONTRAST_ADAPTATION_FACTOR: an edge much weaker than its strongest neighbour is dropped
const SMAA_CONTRAST_ADAPTATION: f32 = 2.0;

fn smaa_luma_at(p: vec2<i32>, size: vec2<i32>) -> f32 {
    let c = max(textureLoad(previous, clamp(p, vec2<i32>(0), size - 1), 0).rgb, vec3<f32>(0.0));
    // perceptual, as FXAA's: the picture is still linear HDR light here
    return dot(sqrt(c / (1.0 + c)), vec3<f32>(0.299, 0.587, 0.114));
}

fn post(input: PostInput) -> vec4<f32> {
    if anti_aliasing != 2u {
        return vec4<f32>(0.0);
    }
    let size = vec2<i32>(textureDimensions(previous));
    let p = vec2<i32>(input.pixel);
    let l = smaa_luma_at(p, size);
    let l_left = smaa_luma_at(p + vec2<i32>(-1, 0), size);
    let l_top = smaa_luma_at(p + vec2<i32>(0, -1), size);
    let delta = abs(vec2<f32>(l) - vec2<f32>(l_left, l_top));
    var edges = step(vec2<f32>(SMAA_THRESHOLD), delta);
    if edges.x + edges.y == 0.0 {
        return vec4<f32>(0.0);
    }
    let l_right = smaa_luma_at(p + vec2<i32>(1, 0), size);
    let l_bottom = smaa_luma_at(p + vec2<i32>(0, 1), size);
    let l_left2 = smaa_luma_at(p + vec2<i32>(-2, 0), size);
    let l_top2 = smaa_luma_at(p + vec2<i32>(0, -2), size);
    var max_delta = max(delta, abs(vec2<f32>(l) - vec2<f32>(l_right, l_bottom)));
    max_delta = max(max_delta, abs(vec2<f32>(l_left, l_top) - vec2<f32>(l_left2, l_top2)));
    let final_delta = max(max_delta.x, max_delta.y);
    edges *= step(vec2<f32>(final_delta), SMAA_CONTRAST_ADAPTATION * delta);
    return vec4<f32>(edges, 0.0, 1.0);
}
