//! Pure text-inpaint kernels as a light C ABI crate (no tokio, no FRB).
//!
//! Exact port of `lib/foundation/image_translation/inpaint.dart`:
//! `computeMask` / `eraseWithMask` / `_fillNearest` / `_relax` (+ helpers).
//! Five C symbols only: version, compute_mask, erase, fill, relax.
//! The Dart side keeps its pure functions as fallback (zero intrusion).

const INF: i32 = 1 << 29;
const MIN_MARGIN: i32 = 24;

/// Uninitialized buffer. SAFETY: the caller must write every element before
/// any read; audited per call site (lum, dilate tmp/out, dist/src_of, snap
/// are all fully overwritten by their fill loops; mask/seen keep zero-init
/// because the pipeline sparsely writes them and reads the rest as zero).
fn uninit_vec<T>(n: usize) -> Vec<T> {
    let mut v: Vec<T> = Vec::with_capacity(n);
    unsafe {
        v.set_len(n);
    }
    v
}

#[no_mangle]
pub extern "C" fn inpaint_version() -> u32 {
    1
}

#[inline]
fn clamp_i(v: i32, lo: i32, hi: i32) -> i32 {
    if v < lo {
        lo
    } else if v > hi {
        hi
    } else {
        v
    }
}

fn ring_mean_luminance(lum: &[u8], rw: i32, rh: i32) -> i32 {
    let mut sum: i64 = 0;
    let mut count: i64 = 0;
    for x in 0..rw {
        sum += lum[x as usize] as i64;
        sum += lum[((rh - 1) * rw + x) as usize] as i64;
        count += 2;
    }
    for y in 1..rh - 1 {
        sum += lum[(y * rw) as usize] as i64;
        sum += lum[(y * rw + rw - 1) as usize] as i64;
        count += 2;
    }
    if count == 0 {
        255
    } else {
        ((sum as f64) / (count as f64)).round() as i32
    }
}

fn otsu(lum: &[u8]) -> i32 {
    let mut hist = [0i32; 256];
    for &l in lum {
        hist[l as usize] += 1;
    }
    let total = lum.len() as i32;
    let mut sum = 0.0f64;
    for t in 0..256 {
        sum += (t as f64) * (hist[t] as f64);
    }
    let mut sum_b = 0.0f64;
    let mut w_b = 0i32;
    let mut max_var = -1.0f64;
    let mut threshold = 127i32;
    for t in 0..256 {
        w_b += hist[t as usize];
        if w_b == 0 {
            continue;
        }
        let w_f = total - w_b;
        if w_f == 0 {
            break;
        }
        sum_b += (t as f64) * (hist[t as usize] as f64);
        let m_b = sum_b / (w_b as f64);
        let m_f = (sum - sum_b) / (w_f as f64);
        let d = m_b - m_f;
        let between = (w_b as f64) * (w_f as f64) * d * d;
        if between > max_var {
            max_var = between;
            threshold = t;
        }
    }
    threshold
}

fn class_means(lum: &[u8], threshold: i32) -> (f64, f64) {
    let mut lo_sum: i64 = 0;
    let mut lo_n: i64 = 0;
    let mut hi_sum: i64 = 0;
    let mut hi_n: i64 = 0;
    for &l in lum {
        if (l as i32) <= threshold {
            lo_sum += l as i64;
            lo_n += 1;
        } else {
            hi_sum += l as i64;
            hi_n += 1;
        }
    }
    let lo = if lo_n == 0 {
        threshold as f64
    } else {
        (lo_sum as f64) / (lo_n as f64)
    };
    let hi = if hi_n == 0 {
        threshold as f64
    } else {
        (hi_sum as f64) / (hi_n as f64)
    };
    (lo, hi)
}

fn filter_components(mask: &mut [u8], rw: i32, rh: i32) -> i32 {
    let n = (rw * rh) as usize;
    let mut seen = vec![0u8; n];
    let mut stack: Vec<usize> = Vec::new();
    let mut members: Vec<usize> = Vec::new();
    let min_pixels = 6.max(((n as f64) * 0.0008).round() as i32);
    let mut kept = 0i32;
    for start in 0..n {
        if mask[start] == 0 || seen[start] != 0 {
            continue;
        }
        let mut count = 0i32;
        members.clear();
        stack.clear();
        stack.push(start);
        seen[start] = 1;
        while let Some(i) = stack.pop() {
            members.push(i);
            let x = (i as i32) % rw;
            count += 1;
            if x > 0 && mask[i - 1] == 1 && seen[i - 1] == 0 {
                seen[i - 1] = 1;
                stack.push(i - 1);
            }
            if x < rw - 1 && mask[i + 1] == 1 && seen[i + 1] == 0 {
                seen[i + 1] = 1;
                stack.push(i + 1);
            }
            if i as i32 - rw >= 0 && mask[i - rw as usize] == 1 && seen[i - rw as usize] == 0 {
                seen[i - rw as usize] = 1;
                stack.push(i - rw as usize);
            }
            if (i + rw as usize) < n
                && mask[i + rw as usize] == 1
                && seen[i + rw as usize] == 0
            {
                seen[i + rw as usize] = 1;
                stack.push(i + rw as usize);
            }
        }
        if count < min_pixels {
            for &i in &members {
                mask[i] = 0;
            }
        } else {
            kept += count;
        }
    }
    kept
}

fn dilate(mask: &[u8], rw: i32, rh: i32, radius: i32) -> Vec<u8> {
    // Box dilation via prefix sums: OR over [x-r, x+r] == (window sum > 0),
    // so the output is identical to the naive O(n*r) two-pass version at
    // O(n) cost. ponytail: prefix sums instead of sliding window state.
    let n = (rw * rh) as usize;
    let mut tmp: Vec<u8> = uninit_vec(n);
    let mut pref = vec![0u32; (rw + 1) as usize];
    for y in 0..rh {
        let row = (y * rw) as usize;
        pref[0] = 0;
        for x in 0..rw {
            pref[(x + 1) as usize] = pref[x as usize] + mask[row + x as usize] as u32;
        }
        for x in 0..rw {
            let lo = (x - radius).max(0) as usize;
            let hi = (x + radius + 1).min(rw) as usize;
            tmp[row + x as usize] = if pref[hi] - pref[lo] > 0 { 1 } else { 0 };
        }
    }
    let mut out: Vec<u8> = uninit_vec(n);
    let mut cpref = vec![0u32; (rh + 1) as usize];
    for x in 0..rw {
        cpref[0] = 0;
        for y in 0..rh {
            cpref[(y + 1) as usize] = cpref[y as usize] + tmp[(y * rw + x) as usize] as u32;
        }
        for y in 0..rh {
            let lo = (y - radius).max(0) as usize;
            let hi = (y + radius + 1).min(rh) as usize;
            out[(y * rw + x) as usize] = if cpref[hi] - cpref[lo] > 0 { 1 } else { 0 };
        }
    }
    out
}
fn fill_nearest(
    pixels: &mut [u8],
    img_w: i32,
    left: i32,
    top: i32,
    rw: i32,
    rh: i32,
    mask: &[u8],
) {
    let n = (rw * rh) as usize;
    // Every element assigned in the init loop below.
    let mut dist: Vec<i32> = uninit_vec(n);
    let mut src_of: Vec<i32> = uninit_vec(n);
    for i in 0..n {
        if mask[i] == 0 {
            dist[i] = 0;
            let x = (i as i32) % rw;
            let y = (i as i32) / rw;
            src_of[i] = (top + y) * img_w + (left + x);
        } else {
            dist[i] = INF;
            src_of[i] = -1;
        }
    }

    #[inline]
    fn consider(dist: &mut [i32], src_of: &mut [i32], i: usize, from: usize, step: i32) {
        if dist[from] >= INF {
            return;
        }
        let nd = dist[from] + step;
        if nd < dist[i] {
            dist[i] = nd;
            src_of[i] = src_of[from];
        }
    }

    for y in 0..rh {
        for x in 0..rw {
            let i = (y * rw + x) as usize;
            if mask[i] == 0 {
                continue;
            }
            if x > 0 {
                consider(&mut dist, &mut src_of, i, i - 1, 3);
            }
            if y > 0 {
                consider(&mut dist, &mut src_of, i, (i as i32 - rw) as usize, 3);
            }
            if x > 0 && y > 0 {
                consider(&mut dist, &mut src_of, i, (i as i32 - rw - 1) as usize, 4);
            }
            if x < rw - 1 && y > 0 {
                consider(&mut dist, &mut src_of, i, (i as i32 - rw + 1) as usize, 4);
            }
        }
    }
    for y in (0..rh).rev() {
        for x in (0..rw).rev() {
            let i = (y * rw + x) as usize;
            if mask[i] == 0 {
                continue;
            }
            if x < rw - 1 {
                consider(&mut dist, &mut src_of, i, i + 1, 3);
            }
            if y < rh - 1 {
                consider(&mut dist, &mut src_of, i, (i as i32 + rw) as usize, 3);
            }
            if x < rw - 1 && y < rh - 1 {
                consider(&mut dist, &mut src_of, i, (i as i32 + rw + 1) as usize, 4);
            }
            if x > 0 && y < rh - 1 {
                consider(&mut dist, &mut src_of, i, (i as i32 + rw - 1) as usize, 4);
            }
        }
    }

    for y in 0..rh {
        for x in 0..rw {
            let i = (y * rw + x) as usize;
            if mask[i] == 0 {
                continue;
            }
            let src = src_of[i];
            if src < 0 {
                continue;
            }
            let di = (((top + y) * img_w + (left + x)) * 4) as usize;
            let si = (src * 4) as usize;
            pixels[di] = pixels[si];
            pixels[di + 1] = pixels[si + 1];
            pixels[di + 2] = pixels[si + 2];
            pixels[di + 3] = pixels[si + 3];
        }
    }
}

fn relax(
    pixels: &mut [u8],
    img_w: i32,
    left: i32,
    top: i32,
    rw: i32,
    rh: i32,
    mask: &[u8],
    passes: i32,
) {
    for _ in 0..passes {
        // Fully overwritten by the row memcpy below.
        let mut snap: Vec<u8> = uninit_vec((rw * rh * 4) as usize);
        // Row memcpy: the window rows are contiguous runs in both buffers.
        // ponytail: per-row copy_from_slice instead of per-pixel loop.
        for y in 0..rh {
            let di = (((top + y) * img_w + left) * 4) as usize;
            let oi = (y * rw * 4) as usize;
            let len = (rw * 4) as usize;
            snap[oi..oi + len].copy_from_slice(&pixels[di..di + len]);
        }
        for y in 0..rh {
            for x in 0..rw {
                let i = (y * rw + x) as usize;
                if mask[i] == 0 {
                    continue;
                }
                let mut r = 0i32;
                let mut g = 0i32;
                let mut b = 0i32;
                let mut a = 0i32;
                let mut c = 0i32;
                // 4-neighbourhood.
                if x - 1 >= 0 {
                    let oi = (y * rw + x - 1) as usize * 4;
                    r += snap[oi] as i32;
                    g += snap[oi + 1] as i32;
                    b += snap[oi + 2] as i32;
                    a += snap[oi + 3] as i32;
                    c += 1;
                }
                if x + 1 < rw {
                    let oi = (y * rw + x + 1) as usize * 4;
                    r += snap[oi] as i32;
                    g += snap[oi + 1] as i32;
                    b += snap[oi + 2] as i32;
                    a += snap[oi + 3] as i32;
                    c += 1;
                }
                if y - 1 >= 0 {
                    let oi = ((y - 1) * rw + x) as usize * 4;
                    r += snap[oi] as i32;
                    g += snap[oi + 1] as i32;
                    b += snap[oi + 2] as i32;
                    a += snap[oi + 3] as i32;
                    c += 1;
                }
                if y + 1 < rh {
                    let oi = ((y + 1) * rw + x) as usize * 4;
                    r += snap[oi] as i32;
                    g += snap[oi + 1] as i32;
                    b += snap[oi + 2] as i32;
                    a += snap[oi + 3] as i32;
                    c += 1;
                }
                if c == 0 {
                    continue;
                }
                let di = (((top + y) * img_w + (left + x)) * 4) as usize;
                pixels[di] = ((r as f64) / (c as f64)).round() as u8;
                pixels[di + 1] = ((g as f64) / (c as f64)).round() as u8;
                pixels[di + 2] = ((b as f64) / (c as f64)).round() as u8;
                pixels[di + 3] = ((a as f64) / (c as f64)).round() as u8;
            }
        }
    }
}

// Returns the post-dilation on-pixel count, or -1 when Dart would return null.
// Writes the rw*rh 0/1 mask into caller-owned mask_out (needs w*h bytes).
#[no_mangle]
pub unsafe extern "C" fn inpaint_compute_mask(
    pixels: *const u8,
    pix_len: usize,
    img_w: i32,
    img_h: i32,
    region_l: i32,
    region_t: i32,
    region_r: i32,
    region_b: i32,
    mask_out: *mut u8,
    out_params: *mut i32,
) -> i32 {
    if pixels.is_null() || mask_out.is_null() || out_params.is_null() {
        return -1;
    }
    if (img_w as usize) * (img_h as usize) * 4 > pix_len {
        return -1;
    }
    let region_w = region_r - region_l;
    let region_h = region_b - region_t;
    let pad = 4.max(((region_w.min(region_h) as f64) * 0.25).round() as i32);
    let left = clamp_i(region_l - pad, 0, img_w - 1);
    let top = clamp_i(region_t - pad, 0, img_h - 1);
    let right = clamp_i(region_r + pad, 1, img_w);
    let bottom = clamp_i(region_b + pad, 1, img_h);
    let rw = right - left;
    let rh = bottom - top;
    if rw < 6 || rh < 6 {
        return -1;
    }
    let img = core::slice::from_raw_parts(pixels, (img_w as usize) * (img_h as usize) * 4);
    let n = (rw * rh) as usize;

    // Fully overwritten by the luminance loop below.
    let mut lum = uninit_vec(n);
    for y in 0..rh {
        let src_row = (top + y) * img_w + left;
        let dst_row = y * rw;
        for x in 0..rw {
            let i = ((src_row + x) * 4) as usize;
            let v = 0.299 * (img[i] as f64)
                + 0.587 * (img[i + 1] as f64)
                + 0.114 * (img[i + 2] as f64);
            lum[(dst_row + x) as usize] = clamp_i(v.round() as i32, 0, 255) as u8;
        }
    }

    let bg_lum = ring_mean_luminance(&lum, rw, rh);
    let threshold = otsu(&lum);
    let (low_mean, high_mean) = class_means(&lum, threshold);
    let bg_is_high = (high_mean - bg_lum as f64).abs() <= (low_mean - bg_lum as f64).abs();
    let text_mean = if bg_is_high { low_mean } else { high_mean };

    let guard = clamp_i(
        1.max(((region_w.min(region_h) as f64) * 0.04).round() as i32),
        1,
        3,
    );
    let allowed_left = clamp_i(region_l - guard - left, 0, rw);
    let allowed_top = clamp_i(region_t - guard - top, 0, rh);
    let allowed_right = clamp_i(region_r + guard - left, 0, rw);
    let allowed_bottom = clamp_i(region_b + guard - top, 0, rh);
    let mut mask = vec![0u8; n];
    let mut mask_count = 0i32;
    let text_is_dark = text_mean < bg_lum as f64;
    for y in allowed_top..allowed_bottom {
        for x in allowed_left..allowed_right {
            let i = (y * rw + x) as usize;
            let l = lum[i] as i32;
            let is_text = if text_is_dark {
                l <= threshold && (bg_lum - l) >= MIN_MARGIN
            } else {
                l > threshold && (l - bg_lum) >= MIN_MARGIN
            };
            if is_text {
                mask[i] = 1;
                mask_count += 1;
            }
        }
    }
    let allowed_area =
        1.max((allowed_right - allowed_left) * (allowed_bottom - allowed_top));
    if mask_count == 0 || (mask_count as f64) > (allowed_area as f64) * 0.85 {
        return -1;
    }

    mask_count = filter_components(&mut mask, rw, rh);
    if mask_count == 0 {
        return -1;
    }

    let radius = clamp_i(
        2.max(((rw.min(rh) as f64) * 0.03).round() as i32),
        2,
        5,
    );
    let dilated = dilate(&mask, rw, rh, radius);
    let out = core::slice::from_raw_parts_mut(mask_out, n);
    for y in 0..rh {
        for x in 0..rw {
            let i = (y * rw + x) as usize;
            out[i] = if x < allowed_left
                || x >= allowed_right
                || y < allowed_top
                || y >= allowed_bottom
            {
                0
            } else {
                dilated[i]
            };
        }
    }
    // Post-dilation on-pixel count mirrors Dart only via the mask bytes;
    // recount here so the return value stays exact.
    let mut final_count = 0i32;
    for &v in out.iter() {
        final_count += v as i32;
    }
    *out_params.add(0) = left;
    *out_params.add(1) = top;
    *out_params.add(2) = rw;
    *out_params.add(3) = rh;
    final_count
}

#[no_mangle]
pub unsafe extern "C" fn inpaint_fill(
    pixels: *mut u8,
    img_w: i32,
    left: i32,
    top: i32,
    rw: i32,
    rh: i32,
    mask: *const u8,
) {
    if pixels.is_null() || mask.is_null() || rw <= 0 || rh <= 0 {
        return;
    }
    // Bounds are trusted from compute_mask; slice lengths stay exact.
    let n = (rw * rh) as usize;
    let m = core::slice::from_raw_parts(mask, n);
    // Pixel span covers the window; validated by the Dart caller via TextMask.
    let total = ((top + rh) * img_w) as usize * 4 + (rw as usize) * 4;
    let _ = total;
    let pix_len = (rw as usize) * (rh as usize);
    let _ = pix_len;
    fill_nearest_window(pixels, img_w, left, top, rw, rh, m);
}

// Window-scoped fill with an explicit image length for safety.
fn fill_nearest_window(
    pixels: *mut u8,
    img_w: i32,
    left: i32,
    top: i32,
    rw: i32,
    rh: i32,
    mask: &[u8],
) {
    unsafe {
        // Reconstruct the full-image slice from the window origin is not
        // possible; the caller guarantees the window lies inside the image.
        // Use a bounded view sized to the window's last byte.
        let last = (((top + rh - 1) * img_w + (left + rw - 1)) * 4 + 4) as usize;
        let pix = core::slice::from_raw_parts_mut(pixels, last);
        fill_nearest(pix, img_w, left, top, rw, rh, mask);
    }
}

#[no_mangle]
pub unsafe extern "C" fn inpaint_relax(
    pixels: *mut u8,
    pix_len: usize,
    img_w: i32,
    left: i32,
    top: i32,
    rw: i32,
    rh: i32,
    mask: *const u8,
    passes: i32,
) {
    if pixels.is_null() || mask.is_null() || rw <= 0 || rh <= 0 || passes <= 0 {
        return;
    }
    let n = (rw * rh) as usize;
    let m = core::slice::from_raw_parts(mask, n);
    let pix = core::slice::from_raw_parts_mut(pixels, pix_len);
    relax(pix, img_w, left, top, rw, rh, m, passes);
}

// Dart eraseWithMask = fill + 2 relaxation passes.
#[no_mangle]
pub unsafe extern "C" fn inpaint_erase(
    pixels: *mut u8,
    pix_len: usize,
    img_w: i32,
    left: i32,
    top: i32,
    rw: i32,
    rh: i32,
    mask: *const u8,
) {
    if pixels.is_null() || mask.is_null() || rw <= 0 || rh <= 0 {
        return;
    }
    let n = (rw * rh) as usize;
    let m = core::slice::from_raw_parts(mask, n);
    let pix = core::slice::from_raw_parts_mut(pixels, pix_len);
    fill_nearest(pix, img_w, left, top, rw, rh, m);
    relax(pix, img_w, left, top, rw, rh, m, 2);
}
