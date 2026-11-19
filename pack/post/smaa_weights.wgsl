// SMAA 1x, pass 2 of 3: blending weights. For each edge, search both ways to its ends, read the crossing edges
// there (the pattern: L, Z or U shaped) and take the area the revectorized line covers in this pixel.
// SMAA looks the area up in a precomputed texture (AreaTex); its generator's area function is evaluated here
// directly instead, for SMAA 1x's single subsample (offset 0), without diagonal or corner detection.
//
// r: this pixel blends toward the one above, g: the one above blends toward this one (top edge)
// b: this pixel blends toward the one on its left, a: the left one toward this one (left edge)

const SMAA_MAX_SEARCH: i32 = 24;
const SMAA_SMOOTH_MAX_DISTANCE: f32 = 32.0;

fn smaa_edge(p: vec2<i32>, size: vec2<i32>) -> vec2<f32> {
    if any(p < vec2<i32>(0)) || any(p >= size) {
        return vec2<f32>(0.0);
    }
    return textureLoad(smaa_edges, p, 0).rg;
}

// AreaTex.py's area(): the area between the edge (y = 0) and the line p1 -> p2 over the pixel [x, x + 1],
// as (below, above): below the edge is this pixel's side, above it the neighbour's
fn smaa_area_line(p1: vec2<f32>, p2: vec2<f32>, x: f32) -> vec2<f32> {
    let x1 = x;
    let x2 = x + 1.0;
    let inside = (x1 >= p1.x && x1 < p2.x) || (x2 > p1.x && x2 <= p2.x);
    if !inside {
        return vec2<f32>(0.0);
    }
    let d = p2 - p1;
    let y1 = p1.y + d.y * (x1 - p1.x) / d.x;
    let y2 = p1.y + d.y * (x2 - p1.x) / d.x;
    if (y1 >= 0.0) == (y2 >= 0.0) || abs(y1) < 1e-4 || abs(y2) < 1e-4 {
        let a = 0.5 * (y1 + y2);
        return select(vec2<f32>(0.0, a), vec2<f32>(-a, 0.0), a < 0.0);
    }
    // the line crosses the edge inside the pixel: two triangles of opposite sides
    let xc = -p1.y * d.x / d.y + p1.x;
    let t1 = select(0.0, 0.5 * y1 * (xc - x1), xc > p1.x);
    let t2 = select(0.0, 0.5 * y2 * (x2 - xc), xc < p2.x);
    return vec2<f32>(max(-t1, 0.0) + max(-t2, 0.0), max(t1, 0.0) + max(t2, 0.0));
}

fn smaa_smooth_area(d: f32, a1: vec2<f32>, a2: vec2<f32>) -> vec2<f32> {
    let b1 = sqrt(a1 * 2.0) * 0.5;
    let b2 = sqrt(a2 * 2.0) * 0.5;
    let p = clamp(d / SMAA_SMOOTH_MAX_DISTANCE, 0.0, 1.0);
    return mix(b1, a1, p) + mix(b2, a2, p);
}

// AreaTex.py's areaortho() at offset 0. pattern bits: 1 a crossing edge below at the left end, 2 below at the
// right end, 4 above at the left end, 8 above at the right end
fn smaa_area_ortho(pattern: u32, left: f32, right: f32) -> vec2<f32> {
    let d = left + right + 1.0;
    let o1 = 0.5;
    let o2 = -0.5;
    let h = d * 0.5;
    switch pattern {
        case 1u: {
            return select(vec2<f32>(0.0), smaa_area_line(vec2<f32>(0.0, o2), vec2<f32>(h, 0.0), left), left <= right);
        }
        case 2u: {
            return select(vec2<f32>(0.0), smaa_area_line(vec2<f32>(h, 0.0), vec2<f32>(d, o2), left), left >= right);
        }
        case 3u: {
            return smaa_smooth_area(d, smaa_area_line(vec2<f32>(0.0, o2), vec2<f32>(h, 0.0), left),
                smaa_area_line(vec2<f32>(h, 0.0), vec2<f32>(d, o2), left));
        }
        case 4u: {
            return select(vec2<f32>(0.0), smaa_area_line(vec2<f32>(0.0, o1), vec2<f32>(h, 0.0), left), left <= right);
        }
        case 6u, 7u, 14u: {
            return smaa_area_line(vec2<f32>(0.0, o1), vec2<f32>(d, o2), left);
        }
        case 8u: {
            return select(vec2<f32>(0.0), smaa_area_line(vec2<f32>(h, 0.0), vec2<f32>(d, o1), left), left >= right);
        }
        case 9u, 11u, 13u: {
            return smaa_area_line(vec2<f32>(0.0, o2), vec2<f32>(d, o1), left);
        }
        case 12u: {
            return smaa_smooth_area(d, smaa_area_line(vec2<f32>(0.0, o1), vec2<f32>(h, 0.0), left),
                smaa_area_line(vec2<f32>(h, 0.0), vec2<f32>(d, o1), left));
        }
        default: {
            // 0: no crossing; 5, 10, 15: a crossing both ways at an end, which says nothing about the slope
            return vec2<f32>(0.0);
        }
    }
}

fn post(input: PostInput) -> vec4<f32> {
    if anti_aliasing != 2u {
        return vec4<f32>(0.0);
    }
    let size = vec2<i32>(textureDimensions(smaa_edges));
    let p = vec2<i32>(input.pixel);
    let e = smaa_edge(p, size);
    var w = vec4<f32>(0.0);

    // an edge on top of this pixel: a horizontal run along the row
    if e.g > 0.5 {
        var dl = 0;
        for (var i = 1; i <= SMAA_MAX_SEARCH; i++) {
            if smaa_edge(p + vec2<i32>(-i, 0), size).g < 0.5 {
                break;
            }
            dl = i;
        }
        var dr = 0;
        for (var i = 1; i <= SMAA_MAX_SEARCH; i++) {
            if smaa_edge(p + vec2<i32>(i, 0), size).g < 0.5 {
                break;
            }
            dr = i;
        }
        // crossing (vertical) edges at the run's ends: below is this pixel's row, above the row above it
        let xl = p.x - dl;
        let xr = p.x + dr + 1;
        let l_below = smaa_edge(vec2<i32>(xl, p.y), size).r > 0.5;
        let l_above = smaa_edge(vec2<i32>(xl, p.y - 1), size).r > 0.5;
        let r_below = smaa_edge(vec2<i32>(xr, p.y), size).r > 0.5;
        let r_above = smaa_edge(vec2<i32>(xr, p.y - 1), size).r > 0.5;
        let pattern = select(0u, 1u, l_below) | select(0u, 2u, r_below) | select(0u, 4u, l_above) | select(0u, 8u, r_above);
        w = vec4<f32>(smaa_area_ortho(pattern, f32(dl), f32(dr)), w.zw);
    }
    // an edge on this pixel's left: a vertical run down the column, its "below" side this pixel's column
    if e.r > 0.5 {
        var dt = 0;
        for (var i = 1; i <= SMAA_MAX_SEARCH; i++) {
            if smaa_edge(p + vec2<i32>(0, -i), size).r < 0.5 {
                break;
            }
            dt = i;
        }
        var db = 0;
        for (var i = 1; i <= SMAA_MAX_SEARCH; i++) {
            if smaa_edge(p + vec2<i32>(0, i), size).r < 0.5 {
                break;
            }
            db = i;
        }
        let yt = p.y - dt;
        let yb = p.y + db + 1;
        let t_mine = smaa_edge(vec2<i32>(p.x, yt), size).g > 0.5;
        let t_other = smaa_edge(vec2<i32>(p.x - 1, yt), size).g > 0.5;
        let b_mine = smaa_edge(vec2<i32>(p.x, yb), size).g > 0.5;
        let b_other = smaa_edge(vec2<i32>(p.x - 1, yb), size).g > 0.5;
        let pattern = select(0u, 1u, t_mine) | select(0u, 2u, b_mine) | select(0u, 4u, t_other) | select(0u, 8u, b_other);
        w = vec4<f32>(w.xy, smaa_area_ortho(pattern, f32(dt), f32(db)));
    }
    return w;
}
