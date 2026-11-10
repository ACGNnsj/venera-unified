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

// ---------------------------------------------------------------------------
// Batch 2: offline 2x fusion + ACNet cross-platform tiling helpers.
//
// New symbols are stateless filters over caller-owned buffers; orchestration
// (tile grid, ONNX session, PNG) stays in Dart (acnet_ffi_pipeline.dart).
// YCrCb math mirrors UpscaleEngine.kt: BT.601 full-range 8-bit with
// round-half-away quantization, BORDER_REPLICATE tile fill, half-pixel
// centered bilinear chroma upsampling.
// ---------------------------------------------------------------------------

/// Round-half-away to u8 with clamping (matches Dart double.round for >= 0).
#[inline(always)]
fn quantize_u8(v: f32) -> u8 {
    v.round().clamp(0.0, 255.0) as u8
}

/// BT.601 full-range luma (OpenCV COLOR_BGR2YCrCb 8-bit integer path).
#[inline(always)]
fn bt601_y(r: f32, g: f32, b: f32) -> f32 {
    0.299 * r + 0.587 * g + 0.114 * b
}

/// Bilinear 2x upscale of RGBA into a fresh Vec (half-pixel centers,
/// edge-clamped). Kernel matches package:image linear for interior pixels.
fn bilinear_upscale_2x_rgba(src: &[u8], w: usize, h: usize) -> Vec<u8> {
    let (dw, dh) = (w * 2, h * 2);
    let mut dst = vec![0u8; dw * dh * 4];
    for dy in 0..dh {
        let sy = (dy as f32 + 0.5) * 0.5 - 0.5;
        let y0 = sy.floor().clamp(0.0, (h - 1) as f32) as usize;
        let y1 = (y0 + 1).min(h - 1);
        let fy = (sy - y0 as f32).clamp(0.0, 1.0);
        for dx in 0..dw {
            let sx = (dx as f32 + 0.5) * 0.5 - 0.5;
            let x0 = sx.floor().clamp(0.0, (w - 1) as f32) as usize;
            let x1 = (x0 + 1).min(w - 1);
            let fx = (sx - x0 as f32).clamp(0.0, 1.0);
            for c in 0..4 {
                let p00 = src[(y0 * w + x0) * 4 + c] as f32;
                let p10 = src[(y0 * w + x1) * 4 + c] as f32;
                let p01 = src[(y1 * w + x0) * 4 + c] as f32;
                let p11 = src[(y1 * w + x1) * 4 + c] as f32;
                let v = p00 * (1.0 - fx) * (1.0 - fy)
                    + p10 * fx * (1.0 - fy)
                    + p01 * (1.0 - fx) * fy
                    + p11 * fx * fy;
                dst[(dy * dw + dx) * 4 + c] = quantize_u8(v);
            }
        }
    }
    dst
}

/// Offline fast path: 2x bilinear upscale + full Anime4K v1 pipeline.
/// Returns 0 on success, negative on bad pointers/dimensions/lengths.
#[no_mangle]
pub unsafe extern "C" fn venera_anime4k_upscale_2x_rgba(
    src: *const u8,
    src_len: usize,
    w: i32,
    h: i32,
    unblur_strength: u32,
    refine_strength: u32,
    dst: *mut u8,
    dst_len: usize,
) -> i32 {
    if src.is_null() || dst.is_null() || w <= 0 || h <= 0 {
        return -1;
    }
    let (w, h) = (w as usize, h as usize);
    if src_len != w * h * 4 || dst_len != w * 2 * h * 2 * 4 {
        return -1;
    }
    let input = core::slice::from_raw_parts(src, src_len);
    let output = core::slice::from_raw_parts_mut(dst, dst_len);
    let upscaled = bilinear_upscale_2x_rgba(input, w, h);
    let result = run(&upscaled, w * 2, h * 2, unblur_strength, refine_strength);
    output.copy_from_slice(&result);
    0
}

/// ACNet step 1: split RGBA into full-range BT.601 Y / Cr / Cb planes.
/// Returns 0 on success, 1 on null/bad dims, 2 on length mismatch.
#[no_mangle]
pub unsafe extern "C" fn venera_acnet_rgb_to_ycrcb(
    rgba: *const u8,
    len: usize,
    w: i32,
    h: i32,
    y_out: *mut u8,
    cr_out: *mut u8,
    cb_out: *mut u8,
) -> u8 {
    if rgba.is_null()
        || y_out.is_null()
        || cr_out.is_null()
        || cb_out.is_null()
        || w <= 0
        || h <= 0
    {
        return 1;
    }
    let n = w as usize * h as usize;
    if len != n * 4 {
        return 2;
    }
    let src = core::slice::from_raw_parts(rgba, len);
    let y = core::slice::from_raw_parts_mut(y_out, n);
    let cr = core::slice::from_raw_parts_mut(cr_out, n);
    let cb = core::slice::from_raw_parts_mut(cb_out, n);
    for i in 0..n {
        let r = src[i * 4] as f32;
        let g = src[i * 4 + 1] as f32;
        let b = src[i * 4 + 2] as f32;
        let yy = bt601_y(r, g, b);
        y[i] = quantize_u8(yy);
        cr[i] = quantize_u8((r - yy) * 0.713 + 128.0);
        cb[i] = quantize_u8((b - yy) * 0.564 + 128.0);
    }
    0
}

/// ACNet step 2: extract one constant-size NCHW float32 tile with
/// BORDER_REPLICATE fill. `planar` is channel-major (each plane w*h).
/// Returns 0 on success, 1 on null/bad dims, 2 on out-of-range grid.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn venera_upscale_extract_tile_f32(
    planar: *const u8,
    w: i32,
    h: i32,
    channels: u32,
    x: i32,
    y: i32,
    core_w: u32,
    core_h: u32,
    tile_in: u32,
    pad: u32,
    out: *mut f32,
) -> u8 {
    if planar.is_null()
        || w <= 0
        || h <= 0
        || channels == 0
        || tile_in == 0
        || x < 0
        || y < 0
        || out.is_null()
    {
        return 1;
    }
    let (w, h) = (w as usize, h as usize);
    let (channels, tile_in, pad) = (channels as usize, tile_in as usize, pad as usize);
    let (x, y) = (x as usize, y as usize);
    let (core_w, core_h) = (core_w as usize, core_h as usize);
    if x >= w || y >= h || core_w == 0 || core_h == 0 {
        return 2;
    }
    let src = core::slice::from_raw_parts(planar, channels * w * h);
    let dst = core::slice::from_raw_parts_mut(out, channels * tile_in * tile_in);
    for ty in 0..tile_in {
        for tx in 0..tile_in {
            // Signed shift-then-clamp == OpenCV BORDER_REPLICATE.
            let ey = ((y + ty) as isize - pad as isize).clamp(0, h as isize - 1) as usize;
            let ex = ((x + tx) as isize - pad as isize).clamp(0, w as isize - 1) as usize;
            for c in 0..channels {
                dst[(c * tile_in + ty) * tile_in + tx] =
                    src[c * w * h + ey * w + ex] as f32 / 255.0;
            }
        }
    }
    0
}

/// ACNet step 3: center-crop the model output tile, apply intensity around
/// neutral gray, quantize, and write the ROI. `tile` is NCHW float32 with
/// spatial size tile_in*scale; `out_planar` is channel-major u8.
/// Returns 0 on success, 1 on null/bad dims.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn venera_upscale_commit_tile_f32(
    tile: *const f32,
    channels: u32,
    tile_in: u32,
    pad: u32,
    scale: u32,
    dst_x: u32,
    dst_y: u32,
    core_w: u32,
    core_h: u32,
    intensity: f32,
    out_w: u32,
    out_h: u32,
    out_planar: *mut u8,
) -> u8 {
    if tile.is_null() || out_planar.is_null() || channels == 0 || tile_in == 0 || scale == 0 {
        return 1;
    }
    let (channels, tile_in, pad, scale) =
        (channels as usize, tile_in as usize, pad as usize, scale as usize);
    let (dst_x, dst_y) = (dst_x as usize, dst_y as usize);
    let (core_w, core_h) = (core_w as usize, core_h as usize);
    let (out_w, out_h) = (out_w as usize, out_h as usize);
    if out_w == 0 || out_h == 0 || core_w == 0 || core_h == 0 {
        return 1;
    }
    let out_spatial = tile_in * scale;
    let src = core::slice::from_raw_parts(tile, channels * out_spatial * out_spatial);
    let dst = core::slice::from_raw_parts_mut(out_planar, channels * out_w * out_h);
    for c in 0..channels {
        for oy in 0..core_h * scale {
            let gy = dst_y * scale + oy;
            if gy >= out_h {
                continue;
            }
            for ox in 0..core_w * scale {
                let gx = dst_x * scale + ox;
                if gx >= out_w {
                    continue;
                }
                let v = src[(c * out_spatial + pad * scale + oy) * out_spatial
                    + pad * scale
                    + ox];
                dst[c * out_w * out_h + gy * out_w + gx] =
                    quantize_u8(((v - 0.5) * intensity + 0.5) * 255.0);
            }
        }
    }
    0
}

/// ACNet step 4: merge super-resolved Y with bilinear-upsampled chroma into
/// RGBA (BT.601 inverse, alpha 255). `y_up` is (w*scale)*(h*scale);
/// `cr_orig`/`cb_orig` are w*h; `out_rgba` is (w*scale)*(h*scale)*4.
/// Returns 0 on success, 1 on null/bad dims.
#[no_mangle]
pub unsafe extern "C" fn venera_acnet_merge_ycrcb_to_rgba(
    y_up: *const u8,
    cr_orig: *const u8,
    cb_orig: *const u8,
    w: u32,
    h: u32,
    scale: u32,
    out_rgba: *mut u8,
) -> u8 {
    if y_up.is_null()
        || cr_orig.is_null()
        || cb_orig.is_null()
        || out_rgba.is_null()
        || w == 0
        || h == 0
        || scale == 0
    {
        return 1;
    }
    let (w, h, scale) = (w as usize, h as usize, scale as usize);
    let (ow, oh) = (w * scale, h * scale);
    let y = core::slice::from_raw_parts(y_up, ow * oh);
    let cr = core::slice::from_raw_parts(cr_orig, w * h);
    let cb = core::slice::from_raw_parts(cb_orig, w * h);
    let out = core::slice::from_raw_parts_mut(out_rgba, ow * oh * 4);
    for dy in 0..oh {
        // Half-pixel centered bilinear sample position in chroma texels.
        let sy = (dy as f32 + 0.5) / scale as f32 - 0.5;
        let y0 = sy.floor().clamp(0.0, (h - 1) as f32);
        let y1 = (y0 + 1.0).min((h - 1) as f32);
        let fy = (sy - y0).clamp(0.0, 1.0);
        for dx in 0..ow {
            let sx = (dx as f32 + 0.5) / scale as f32 - 0.5;
            let x0 = sx.floor().clamp(0.0, (w - 1) as f32);
            let x1 = (x0 + 1.0).min((w - 1) as f32);
            let fx = (sx - x0).clamp(0.0, 1.0);
            let (x0, x1, y0, y1) = (x0 as usize, x1 as usize, y0 as usize, y1 as usize);
            let crv = cr[y0 * w + x0] as f32 * (1.0 - fx) * (1.0 - fy)
                + cr[y0 * w + x1] as f32 * fx * (1.0 - fy)
                + cr[y1 * w + x0] as f32 * (1.0 - fx) * fy
                + cr[y1 * w + x1] as f32 * fx * fy;
            let cbv = cb[y0 * w + x0] as f32 * (1.0 - fx) * (1.0 - fy)
                + cb[y0 * w + x1] as f32 * fx * (1.0 - fy)
                + cb[y1 * w + x0] as f32 * (1.0 - fx) * fy
                + cb[y1 * w + x1] as f32 * fx * fy;
            let yy = y[dy * ow + dx] as f32;
            let o = (dy * ow + dx) * 4;
            out[o] = quantize_u8(yy + 1.403 * (crv - 128.0));
            out[o + 1] =
                quantize_u8(yy - 0.714 * (crv - 128.0) - 0.344 * (cbv - 128.0));
            out[o + 2] = quantize_u8(yy + 1.773 * (cbv - 128.0));
            out[o + 3] = 255;
        }
    }
    0
}

#[cfg(test)]
mod batch2_tests {
    use super::*;

    #[test]
    fn neutral_gray_roundtrips_through_ycrcb() {
        // 2x2 opaque mid-gray: Y == 128 and Cr == Cb == 128 exactly.
        let rgba = vec![128u8, 128, 128, 255].repeat(4);
        let mut y = vec![0u8; 4];
        let mut cr = vec![0u8; 4];
        let mut cb = vec![0u8; 4];
        let rc = unsafe {
            venera_acnet_rgb_to_ycrcb(
                rgba.as_ptr(),
                rgba.len(),
                2,
                2,
                y.as_mut_ptr(),
                cr.as_mut_ptr(),
                cb.as_mut_ptr(),
            )
        };
        assert_eq!(rc, 0);
        assert_eq!(y, vec![128u8; 4]);
        assert_eq!(cr, vec![128u8; 4]);
        assert_eq!(cb, vec![128u8; 4]);
    }

    #[test]
    fn extract_tile_replicates_borders() {
        // 4x4 plane 0..16; grid origin (0,0), core 2x2, tile 4, pad 1:
        // (-1,-1) clamps to (0,0); (3,3) relative maps to (2,2).
        let plane: Vec<u8> = (0u8..16).collect();
        let mut out = vec![0f32; 16];
        let rc = unsafe {
            venera_upscale_extract_tile_f32(
                plane.as_ptr(),
                4,
                4,
                1,
                0,
                0,
                2,
                2,
                4,
                1,
                out.as_mut_ptr(),
            )
        };
        assert_eq!(rc, 0);
        assert_eq!(out[0], 0.0);
        assert_eq!(out[1 * 4 + 1], 0.0);
        assert_eq!(out[2 * 4 + 2], 5.0 / 255.0);
        assert_eq!(out[3 * 4 + 3], 10.0 / 255.0);
    }

    #[test]
    fn commit_tile_identity_at_unit_intensity() {
        // tile_in 4, scale 1, pad 1, core 2x2 at dst (0,0), 2x2 output:
        // center crop rows/cols 1..3 -> tile[5], tile[6], tile[9], tile[10].
        let tile: Vec<f32> = (0..16).map(|i| i as f32 / 15.0).collect();
        let mut out = vec![0u8; 4];
        let rc = unsafe {
            venera_upscale_commit_tile_f32(
                tile.as_ptr(),
                1,
                4,
                1,
                1,
                0,
                0,
                2,
                2,
                1.0,
                2,
                2,
                out.as_mut_ptr(),
            )
        };
        assert_eq!(rc, 0);
        let expect = [tile[5], tile[6], tile[9], tile[10]]
            .map(|v| (v * 255.0).round().clamp(0.0, 255.0) as u8);
        assert_eq!(out, expect);
    }

    #[test]
    fn merge_white_pixel_is_opaque_white() {
        let (y, cr, cb) = (vec![255u8], vec![128u8], vec![128u8]);
        let mut out = vec![0u8; 4];
        let rc = unsafe {
            venera_acnet_merge_ycrcb_to_rgba(
                y.as_ptr(),
                cr.as_ptr(),
                cb.as_ptr(),
                1,
                1,
                1,
                out.as_mut_ptr(),
            )
        };
        assert_eq!(rc, 0);
        assert_eq!(out, vec![255u8, 255, 255, 255]);
    }

    #[test]
    fn upscale_2x_keeps_flat_color_and_size() {
        // 1x1 pure red -> 2x2 pure red (flat field passes Push unchanged).
        let src = vec![255u8, 0, 0, 255];
        let mut dst = vec![0u8; 16];
        let rc = unsafe {
            venera_anime4k_upscale_2x_rgba(
                src.as_ptr(),
                src.len(),
                1,
                1,
                79,
                255,
                dst.as_mut_ptr(),
                dst.len(),
            )
        };
        assert_eq!(rc, 0);
        assert_eq!(dst, vec![255u8, 0, 0, 255].repeat(4));
    }

    #[test]
    fn c_abi_rejects_bad_args() {
        let mut b = vec![0u8; 4];
        assert_eq!(
            unsafe {
                venera_acnet_rgb_to_ycrcb(
                    core::ptr::null(),
                    4,
                    1,
                    1,
                    b.as_mut_ptr(),
                    b.as_mut_ptr(),
                    b.as_mut_ptr(),
                )
            },
            1
        );
        assert_eq!(
            unsafe {
                venera_acnet_merge_ycrcb_to_rgba(
                    core::ptr::null(),
                    b.as_ptr(),
                    b.as_ptr(),
                    1,
                    1,
                    1,
                    b.as_mut_ptr(),
                )
            },
            1
        );
    }
}
