// Shared layout of the clouds buffers (photon's colortex9/10 raw clouds and colortex11/12 history)
//
// clouds_raw  (rgba32uint, 1/4 res): one ray per 4x4 block of pixels each frame, at a 4x4 checkerboard
//                                    offset, so 16 frames cover every pixel (CLOUDS_TEMPORAL_UPSCALING 4)
// clouds_hist (rgba32uint, 1/2 res): the temporally resolved clouds the composite reads
//
// x: half floats (scattering.r, scattering.g)    scattering in linear rec.2020
// y: half floats (scattering.b, transmittance)
// z: apparent distance to the clouds in blocks (f32 bits), negative where the texel is a hole: terrain
//    covers all of it with no clouds in front, so its value must not bleed into filtered neighbours
// w: raw: world_age() when it was drawn (f32 bits); hist: the fresh rays it holds + 1 (0: none)

const CLOUDS_NO_HIT: f32 = 1e6;
const CLOUDS_HOLE: f32 = -1e6;

var<private> CLOUDS_CHECKERBOARD: array<vec2<i32>, 16> = array<vec2<i32>, 16>(
    vec2<i32>(0, 0), vec2<i32>(2, 0), vec2<i32>(0, 2), vec2<i32>(2, 2),
    vec2<i32>(1, 1), vec2<i32>(3, 1), vec2<i32>(1, 3), vec2<i32>(3, 3),
    vec2<i32>(1, 0), vec2<i32>(3, 0), vec2<i32>(1, 2), vec2<i32>(3, 2),
    vec2<i32>(0, 1), vec2<i32>(2, 1), vec2<i32>(0, 3), vec2<i32>(2, 3),
);

fn clouds_checkerboard_offset(frame_index: u32) -> vec2<i32> {
    return CLOUDS_CHECKERBOARD[frame_index % 16u];
}

struct CloudTexel {
    scattering: vec3<f32>,
    transmittance: f32,
    distance: f32,
    extra: u32,
}

fn cloud_texel_empty() -> CloudTexel {
    return CloudTexel(vec3<f32>(0.0), 1.0, CLOUDS_NO_HIT, 0u);
}

fn cloud_texel_valid(c: CloudTexel) -> bool {
    return c.distance >= 0.0;
}

// IEEE half floats by hand for values >= 0 (pack2x16float needs a float16 capability the check refuses)
fn half_bits(v: f32) -> u32 {
    let x = clamp(v, 0.0, 65504.0);
    let b = bitcast<u32>(x);
    let e = i32((b >> 23u) & 0xffu) - 112;
    if e <= 0 {
        // half subnormals: steps of 2^-24 (rounding up to 1024 gives the smallest normal half)
        return u32(round(x * 16777216.0));
    }
    let m = b & 0x7fffffu;
    // round to nearest; a mantissa carry moves into the exponent as it should
    return ((u32(e) << 10u) | (m >> 13u)) + ((m >> 12u) & 1u);
}

fn half_value(h: u32) -> f32 {
    let e = (h >> 10u) & 0x1fu;
    let m = h & 0x3ffu;
    if e == 0u {
        return f32(m) * 5.9604645e-8;
    }
    return bitcast<f32>(((e + 112u) << 23u) | (m << 13u));
}

fn pack_half2(a: f32, b: f32) -> u32 {
    return half_bits(a) | (half_bits(b) << 16u);
}

fn unpack_half2(v: u32) -> vec2<f32> {
    return vec2<f32>(half_value(v & 0xffffu), half_value(v >> 16u));
}

fn pack_clouds(c: CloudTexel) -> vec4<u32> {
    let s = max(c.scattering, vec3<f32>(0.0));
    return vec4<u32>(
        pack_half2(s.r, s.g),
        pack_half2(s.b, clamp(c.transmittance, 0.0, 1.0)),
        bitcast<u32>(c.distance),
        c.extra,
    );
}

fn unpack_clouds(v: vec4<u32>) -> CloudTexel {
    let rg = unpack_half2(v.x);
    let ba = unpack_half2(v.y);
    var c: CloudTexel;
    c.scattering = max(vec3<f32>(rg, ba.x), vec3<f32>(0.0));
    c.transmittance = clamp(ba.y, 0.0, 1.0);
    c.distance = bitcast<f32>(v.z);
    c.extra = v.w;
    // a NaN from a cleared or broken texel reads as a hole
    if !(c.distance == c.distance) || any(c.scattering != c.scattering) {
        c.distance = CLOUDS_HOLE;
        c.scattering = vec3<f32>(0.0);
        c.transmittance = 1.0;
    }
    return c;
}
