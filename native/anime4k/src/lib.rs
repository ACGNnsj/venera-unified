//! Anime4K v1 "Push Pixels" post-resize pipeline, exact port of the
//! unscaled kernels in anime4k_upscaler.dart (fill, luminance, Sobel edge
//! mask, multi-pass unblur, Sobel gradient, multi-pass gradient refine,
//! ARGB write-back). Bilinear resize, strength math, PNG and isolate/cache
//! stay in Dart; this crate owns the hot pixel loops behind one FFI call.
//!
//! Integer semantics mirror Dart exactly: all intermediates are
//! non-negative, so Rust truncating `/` matches Dart `~/`, and f64
//! `round()` matches on both sides (half away from zero).
//!
//! Two deliberate quirks are preserved, not fixed:
//! - unblur matches on `!compare`, refine on `compare`;
//! - after the refine loop only color (not luminance) is copied back.

#[inline(always)]
fn get_alpha(argb: i32) -> i32 {
    (argb >> 24) & 0xFF
}

#[inline(always)]
fn get_red(argb: i32) -> i32 {
    (argb >> 16) & 0xFF
}

#[inline(always)]
fn get_green(argb: i32) -> i32 {
    (argb >> 8) & 0xFF
}

#[inline(always)]
fn get_blue(argb: i32) -> i32 {
    argb & 0xFF
}

#[inline(always)]
fn to_argb(a: i32, r: i32, g: i32, b: i32) -> i32 {
    (a.clamp(0, 255) << 24)
        | (r.clamp(0, 255) << 16)
        | (g.clamp(0, 255) << 8)
        | b.clamp(0, 255)
}

#[inline(always)]
fn luminance(r: i32, g: i32, b: i32) -> i32 {
    ((r + r + g + g + g + b) / 6).clamp(0, 255)
}

#[inline(always)]
fn compare_lum3(d0: i32, d1: i32, d2: i32, l0: i32, l1: i32, l2: i32) -> bool {
    d0 < l0 && d0 < l1 && d0 < l2 && d1 < l0 && d1 < l1 && d1 < l2 && d2 < l0 && d2 < l1 && d2 < l2
}

#[inline(always)]
fn compare_lum4(
    d0: i32,
    d1: i32,
    d2: i32,
    l0: i32,
    l1: i32,
    l2: i32,
    l3: i32,
) -> bool {
    d0 < l0
        && d0 < l1
        && d0 < l2
        && d0 < l3
        && d1 < l0
        && d1 < l1
        && d1 < l2
        && d1 < l3
        && d2 < l0
        && d2 < l1
        && d2 < l2
        && d2 < l3
}

#[inline(always)]
fn average_gray(d0: i32, d1: i32, d2: i32) -> i32 {
    ((d0 + d1 + d2) / 3).clamp(0, 255)
}

#[inline(always)]
fn average_rgb(c0: i32, c1: i32, c2: i32) -> i32 {
    let ra = (get_red(c0) + get_red(c1) + get_red(c2)) / 3;
    let ga = (get_green(c0) + get_green(c1) + get_green(c2)) / 3;
    let ba = (get_blue(c0) + get_blue(c1) + get_blue(c2)) / 3;
    let aa = (get_alpha(c0) + get_alpha(c1) + get_alpha(c2)) / 3;
    to_argb(aa, ra, ga, ba)
}

#[inline(always)]
fn weighted_average_gray(d0: i32, d1: i32, alpha: i32) -> i32 {
    ((d0 * (255 - alpha) + d1 * alpha) / 255).clamp(0, 255)
}

#[inline(always)]
fn weighted_average_rgb(c0: i32, c1: i32, alpha: i32) -> i32 {
    let ra = (get_red(c0) * (255 - alpha) + get_red(c1) * alpha) / 255;
    let ga = (get_green(c0) * (255 - alpha) + get_green(c1) * alpha) / 255;
    let ba = (get_blue(c0) * (255 - alpha) + get_blue(c1) * alpha) / 255;
    let aa = (get_alpha(c0) * (255 - alpha) + get_alpha(c1) * alpha) / 255;
    to_argb(aa, ra, ga, ba)
}

// Neighbor slots: 0=tli 1=ti 2=tri 3=li 4=id 5=ri 6=bli 7=bi 8=bri.
const DI: [[usize; 3]; 8] = [
    [0, 1, 2],
    [1, 2, 5],
    [2, 5, 8],
    [5, 8, 7],
    [6, 7, 8],
    [3, 6, 7],
    [0, 3, 6],
    [0, 1, 3],
];
const LV: [[usize; 3]; 8] = [
    [4, 6, 7],
    [4, 3, 7],
    [4, 0, 3],
    [4, 1, 3],
    [4, 0, 1],
    [4, 1, 5],
    [4, 2, 5],
    [4, 7, 5],
];
const HAS_LV3: [bool; 8] = [true, false, true, false, true, false, true, false];
const LV3: [usize; 8] = [8, 4, 6, 4, 2, 4, 8, 4];

#[inline(always)]
fn sobel_magnitude(
    lum: &[u8],
    tli: usize,
    ti: usize,
    tri: usize,
    li: usize,
    ri: usize,
    bli: usize,
    bi: usize,
    bri: usize,
) -> u8 {
    let tl = lum[tli] as i32;
    let t = lum[ti] as i32;
    let tr = lum[tri] as i32;
    let l = lum[li] as i32;
    let r = lum[ri] as i32;
    let bl = lum[bli] as i32;
    let b = lum[bi] as i32;
    let br = lum[bri] as i32;
    let xsobel = (-tl + tr - l - l + r + r - bl + br).abs();
    let ysobel = (-tl - t - t - tr + bl + b + b + br).abs();
    ((xsobel * xsobel + ysobel * ysobel) as f64)
        .sqrt()
        .round()
        .clamp(0.0, 255.0) as u8
}

fn compute_edge_mask(lum: &[u8], w: usize, h: usize, mask: &mut [u8]) {
    for y in 0..h {
        let yn: usize = if y == 0 { 0 } else { w.wrapping_neg() };
        let yp: usize = if y == h - 1 { 0 } else { w };
        for x in 0..w {
            let id = y * w + x;
            let xn: usize = if x == 0 { 0 } else { 1usize.wrapping_neg() };
            let xp: usize = if x == w - 1 { 0 } else { 1 };
            mask[id] = sobel_magnitude(
                lum,
                id + yn + xn,
                id + yn,
                id + yn + xp,
                id + xn,
                id + xp,
                id + yp + xn,
                id + yp,
                id + yp + xp,
            );
        }
    }
}

fn compute_gradient(
    src_color: &[i32],
    src_lum: &[u8],
    dst_color: &mut [i32],
    dst_lum: &mut [u8],
    w: usize,
    h: usize,
) {
    for y in 0..h {
        let yn: usize = if y == 0 { 0 } else { w.wrapping_neg() };
        let yp: usize = if y == h - 1 { 0 } else { w };
        for x in 0..w {
            let id = y * w + x;
            let xn: usize = if x == 0 { 0 } else { 1usize.wrapping_neg() };
            let xp: usize = if x == w - 1 { 0 } else { 1 };
            let ti = id + yn;
            let tli = ti + xn;
            let tri = ti + xp;
            let li = id + xn;
            let ri = id + xp;
            let bi = id + yp;
            let bli = bi + xn;
            let bri = bi + xp;
            dst_lum[id] = sobel_magnitude(src_lum, tli, ti, tri, li, ri, bli, bi, bri);
            dst_color[id] = src_color[id];
        }
    }
}

#[inline(always)]
fn neighbors(id: usize, w: usize, h: usize, x: usize, y: usize) -> [usize; 9] {
    let yn: usize = if y == 0 { 0 } else { w.wrapping_neg() };
    let yp: usize = if y == h - 1 { 0 } else { w };
    let xn: usize = if x == 0 { 0 } else { 1usize.wrapping_neg() };
    let xp: usize = if x == w - 1 { 0 } else { 1 };
    let ti = id + yn;
    let bi = id + yp;
    [
        ti + xn,
        ti,
        ti + xp,
        id + xn,
        id,
        id + xp,
        bi + xn,
        bi,
        bi + xp,
    ]
}

fn unblur_pass(
    src_color: &[i32],
    src_lum: &[u8],
    edge: &[u8],
    dst_color: &mut [i32],
    dst_lum: &mut [u8],
    w: usize,
    h: usize,
    strength: i32,
) {
    let strength = strength.clamp(0, 255);
    for y in 0..h {
        for x in 0..w {
            let id = y * w + x;
            if edge[id] >= 100 {
                dst_color[id] = src_color[id];
                dst_lum[id] = src_lum[id];
                continue;
            }
            let nb = neighbors(id, w, h, x, y);
            let mut lightest_color = src_color[id];
            let mut lightest_lum = src_lum[id] as i32;
            for k in 0..8 {
                let d = DI[k];
                let v = LV[k];
                let d0 = src_lum[nb[d[0]]] as i32;
                let d1 = src_lum[nb[d[1]]] as i32;
                let d2 = src_lum[nb[d[2]]] as i32;
                let lv0 = src_lum[nb[v[0]]] as i32;
                let lv1 = src_lum[nb[v[1]]] as i32;
                let lv2 = src_lum[nb[v[2]]] as i32;
                let matched = if HAS_LV3[k] {
                    !compare_lum4(d0, d1, d2, lv0, lv1, lv2, src_lum[nb[LV3[k]]] as i32)
                } else {
                    !compare_lum3(d0, d1, d2, lv0, lv1, lv2)
                };
                if matched {
                    let new_color = weighted_average_rgb(
                        src_color[id],
                        average_rgb(src_color[nb[d[0]]], src_color[nb[d[1]]], src_color[nb[d[2]]]),
                        strength,
                    );
                    let new_lum = luminance(get_red(new_color), get_green(new_color), get_blue(new_color));
                    if new_lum > lightest_lum {
                        lightest_lum = new_lum;
                        lightest_color = new_color;
                    }
                }
            }
            dst_color[id] = lightest_color;
            dst_lum[id] = lightest_lum.clamp(0, 255) as u8;
        }
    }
}

fn refine_pass(
    src_color: &[i32],
    src_lum: &[u8],
    dst_color: &mut [i32],
    dst_lum: &mut [u8],
    w: usize,
    h: usize,
    strength: i32,
) {
    let strength = strength.clamp(0, 255);
    for y in 0..h {
        for x in 0..w {
            let id = y * w + x;
            let nb = neighbors(id, w, h, x, y);
            let mut pushed = false;
            for k in 0..8 {
                let d = DI[k];
                let v = LV[k];
                let d0 = src_lum[nb[d[0]]] as i32;
                let d1 = src_lum[nb[d[1]]] as i32;
                let d2 = src_lum[nb[d[2]]] as i32;
                let lv0 = src_lum[nb[v[0]]] as i32;
                let lv1 = src_lum[nb[v[1]]] as i32;
                let lv2 = src_lum[nb[v[2]]] as i32;
                let matched = if HAS_LV3[k] {
                    compare_lum4(d0, d1, d2, lv0, lv1, lv2, src_lum[nb[LV3[k]]] as i32)
                } else {
                    compare_lum3(d0, d1, d2, lv0, lv1, lv2)
                };
                if matched {
                    dst_lum[id] = weighted_average_gray(
                        src_lum[id] as i32,
                        average_gray(d0, d1, d2),
                        strength,
                    ) as u8;
                    dst_color[id] = weighted_average_rgb(
                        src_color[id],
                        average_rgb(src_color[nb[d[0]]], src_color[nb[d[1]]], src_color[nb[d[2]]]),
                        strength,
                    );
                    pushed = true;
                    break;
                }
            }
            if !pushed {
                dst_lum[id] = src_lum[id];
                dst_color[id] = src_color[id];
            }
        }
    }
}

fn run(rgba: &[u8], w: usize, h: usize, unblur_strength: u32, refine_strength: u32) -> Vec<u8> {
    let n = w * h;
    let mut a_color = vec![0i32; n];
    let mut a_lum = vec![0u8; n];
    for i in 0..n {
        let r = rgba[i * 4] as i32;
        let g = rgba[i * 4 + 1] as i32;
        let b = rgba[i * 4 + 2] as i32;
        let a = rgba[i * 4 + 3] as i32;
        a_color[i] = to_argb(a, r, g, b);
        a_lum[i] = luminance(r, g, b) as u8;
    }
    let mut edge = vec![0u8; n];
    compute_edge_mask(&a_lum, w, h, &mut edge);

    let mut b_color = vec![0i32; n];
    let mut b_lum = vec![0u8; n];
    let mut remaining = unblur_strength;
    let mut forward = true;
    while remaining > 0 {
        let current = remaining.min(255) as i32;
        remaining -= current as u32;
        if forward {
            unblur_pass(&a_color, &a_lum, &edge, &mut b_color, &mut b_lum, w, h, current);
        } else {
            unblur_pass(&b_color, &b_lum, &edge, &mut a_color, &mut a_lum, w, h, current);
        }
        forward = !forward;
    }
    if !forward {
        a_color.copy_from_slice(&b_color);
        a_lum.copy_from_slice(&b_lum);
    }

    compute_gradient(&a_color, &a_lum, &mut b_color, &mut b_lum, w, h);
    a_color.copy_from_slice(&b_color);
    a_lum.copy_from_slice(&b_lum);

    remaining = refine_strength;
    forward = true;
    while remaining > 0 {
        let current = remaining.min(255) as i32;
        remaining -= current as u32;
        if forward {
            refine_pass(&a_color, &a_lum, &mut b_color, &mut b_lum, w, h, current);
        } else {
            refine_pass(&b_color, &b_lum, &mut a_color, &mut a_lum, w, h, current);
        }
        forward = !forward;
    }
    if !forward {
        a_color.copy_from_slice(&b_color);
    }

    let mut out = vec![0u8; n * 4];
    for i in 0..n {
        let c = a_color[i];
        out[i * 4] = get_red(c) as u8;
        out[i * 4 + 1] = get_green(c) as u8;
        out[i * 4 + 2] = get_blue(c) as u8;
        out[i * 4 + 3] = get_alpha(c) as u8;
    }
    out
}

/// Upscale-stage Anime4K v1 pipeline over RGBA bytes.
/// Returns 0 on success, negative on bad pointers/dimensions/length.
#[no_mangle]
pub unsafe extern "C" fn anime4k_upscale_v1(
    rgba: *const u8,
    len: usize,
    w: i32,
    h: i32,
    unblur_strength: u32,
    refine_strength: u32,
    out: *mut u8,
) -> i32 {
    if rgba.is_null() || out.is_null() || w <= 0 || h <= 0 {
        return -1;
    }
    let n = w as usize * h as usize;
    if len != n * 4 {
        return -1;
    }
    let input = core::slice::from_raw_parts(rgba, len);
    let output = core::slice::from_raw_parts_mut(out, len);
    let result = run(input, w as usize, h as usize, unblur_strength, refine_strength);
    output.copy_from_slice(&result);
    0
}

/// Binding version handshake: 1.
#[no_mangle]
pub unsafe extern "C" fn anime4k_version() -> i32 {
    1
}
