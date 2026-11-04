//! Pure OCR pre/post-processing kernels as a light C ABI crate.
//!
//! Exact port of the hot pure functions in
//! `lib/foundation/image_translation/ocr_worker.dart`:
//! `_resizeRegion` (bilinear RGBA) / `_detPreprocess` (fused scale+resize+
//! ImageNet normalize, bitwise identical to the two-step Dart version) /
//! `_ctcDecode` argmax+dedup / `_detectBoxes` IoU dedup. ORT inference stays
//! in Dart (ort_ffi); this crate never sees a model. Five C symbols only:
//! version, resize, det_preprocess, ctc ids, dedup.
//! The Dart side keeps its pure functions as fallback (zero intrusion).

#[no_mangle]
pub extern "C" fn ocr_preprocess_version() -> u32 {
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

/// Bilinear resample of one RGBA region. Exact port of `_resizeRegion`:
/// the unclamped `floor()` feeds the weight while the clamped value feeds
/// the tap, and the per-channel blend runs in f64 like Dart `/`.
/// Returns 0 on success, -1 on bad pointers/dimensions.
#[no_mangle]
pub unsafe extern "C" fn ocr_resize_region(
    pixels: *const u8,
    pix_len: usize,
    src_w: i32,
    region_l: i32,
    region_t: i32,
    region_r: i32,
    region_b: i32,
    out: *mut u8,
    out_w: i32,
    out_h: i32,
) -> i32 {
    if pixels.is_null() || out.is_null() {
        return -1;
    }
    let sw = region_r - region_l;
    let sh = region_b - region_t;
    if sw <= 0 || sh <= 0 || out_w <= 0 || out_h <= 0 || src_w <= 0 {
        return -1;
    }
    if region_l < 0 || region_t < 0 || region_r > src_w {
        return -1;
    }
    if (region_b as usize) * (src_w as usize) * 4 > pix_len {
        return -1;
    }
    let src = core::slice::from_raw_parts(
        pixels,
        (region_b as usize) * (src_w as usize) * 4,
    );
    let dst = core::slice::from_raw_parts_mut(
        out,
        (out_w as usize) * (out_h as usize) * 4,
    );
    let swf = sw as f64;
    let shf = sh as f64;
    let owf = out_w as f64;
    let ohf = out_h as f64;
    let src_wd = src_w as isize;
    // Hoisted tap maps: identical fx/fy values, computed once per row/col.
    // ponytail: O(w+h) index math instead of O(w*h) redundant floors.
    let mut x0m: Vec<i32> = Vec::with_capacity(out_w as usize);
    let mut x1m: Vec<i32> = Vec::with_capacity(out_w as usize);
    let mut wxm: Vec<f64> = Vec::with_capacity(out_w as usize);
    for x in 0..out_w {
        let fx = (x as f64 + 0.5) * swf / owf - 0.5;
        x0m.push(clamp_i(fx.floor() as i32, 0, sw - 1));
        x1m.push(clamp_i(x0m[x as usize] + 1, 0, sw - 1));
        wxm.push(fx - fx.floor());
    }
    for y in 0..out_h {
        let fy = (y as f64 + 0.5) * shf / ohf - 0.5;
        let y0 = clamp_i(fy.floor() as i32, 0, sh - 1);
        let y1 = clamp_i(y0 + 1, 0, sh - 1);
        let wy = fy - fy.floor();
        for x in 0..out_w {
            let x0 = x0m[x as usize];
            let x1 = x1m[x as usize];
            let wx = wxm[x as usize];
            let di = ((y * out_w + x) * 4) as usize;
            for c in 0..4 {
                let p00 = src[(((region_t + y0) as isize * src_wd
                    + (region_l + x0) as isize)
                    * 4
                    + c) as usize];
                let p01 = src[(((region_t + y0) as isize * src_wd
                    + (region_l + x1) as isize)
                    * 4
                    + c) as usize];
                let p10 = src[(((region_t + y1) as isize * src_wd
                    + (region_l + x0) as isize)
                    * 4
                    + c) as usize];
                let p11 = src[(((region_t + y1) as isize * src_wd
                    + (region_l + x1) as isize)
                    * 4
                    + c) as usize];
                let top = p00 as f64 + (p01 as f64 - p00 as f64) * wx;
                let bottom = p10 as f64 + (p11 as f64 - p10 as f64) * wx;
                dst[di + c as usize] =
                    clamp_i((top + (bottom - top) * wy).round() as i32, 0, 255)
                        as u8;
            }
        }
    }
    0
}

/// Fused DBNet preprocessing: scale + round32 in-crate, then one pass that
/// bilinear-blends each RGB tap in f64, rounds to the same u8 `_resizeRegion`
/// would store, and normalizes straight into the planar f32 tensor. Bitwise
/// identical to resize-then-normalize with no intermediate RGBA buffer.
/// Writes inW/inH into `out_dims` (needs 2 int32s), returns the tensor
/// element count, or -1 on bad pointers/dimensions/capacity.
#[no_mangle]
pub unsafe extern "C" fn ocr_det_preprocess(
    pixels: *const u8,
    pix_len: usize,
    src_w: i32,
    src_h: i32,
    tensor_out: *mut f32,
    tensor_cap: usize,
    out_dims: *mut i32,
) -> i32 {
    if pixels.is_null() || tensor_out.is_null() || out_dims.is_null() {
        return -1;
    }
    if src_w <= 0 || src_h <= 0 {
        return -1;
    }
    if (src_h as usize) * (src_w as usize) * 4 > pix_len {
        return -1;
    }
    let max_side = 1280.0f64;
    let scale = 1.0f64.min(max_side / ((src_w.max(src_h)) as f64));
    let round32 = |v: f64| 32.max((v / 32.0).round() as i32 * 32);
    let in_w = round32(src_w as f64 * scale);
    let in_h = round32(src_h as f64 * scale);
    let plane = (in_w as usize) * (in_h as usize);
    if tensor_cap < plane * 3 {
        return -1;
    }
    let src = core::slice::from_raw_parts(
        pixels,
        (src_h as usize) * (src_w as usize) * 4,
    );
    let dst = core::slice::from_raw_parts_mut(tensor_out, plane * 3);
    let dims = core::slice::from_raw_parts_mut(out_dims, 2);
    dims[0] = in_w;
    dims[1] = in_h;
    const MEAN: [f64; 3] = [0.485, 0.456, 0.406];
    const STD: [f64; 3] = [0.229, 0.224, 0.225];
    let swf = src_w as f64;
    let shf = src_h as f64;
    let owf = in_w as f64;
    let ohf = in_h as f64;
    let src_wd = src_w as isize;
    let mut x0m: Vec<i32> = Vec::with_capacity(in_w as usize);
    let mut x1m: Vec<i32> = Vec::with_capacity(in_w as usize);
    let mut wxm: Vec<f64> = Vec::with_capacity(in_w as usize);
    for x in 0..in_w {
        let fx = (x as f64 + 0.5) * swf / owf - 0.5;
        x0m.push(clamp_i(fx.floor() as i32, 0, src_w - 1));
        x1m.push(clamp_i(x0m[x as usize] + 1, 0, src_w - 1));
        wxm.push(fx - fx.floor());
    }
    for y in 0..in_h {
        let fy = (y as f64 + 0.5) * shf / ohf - 0.5;
        let y0 = clamp_i(fy.floor() as i32, 0, src_h - 1);
        let y1 = clamp_i(y0 + 1, 0, src_h - 1);
        let wy = fy - fy.floor();
        for x in 0..in_w {
            let x0 = x0m[x as usize];
            let x1 = x1m[x as usize];
            let wx = wxm[x as usize];
            let di = (y * in_w + x) as usize;
            for c in 0..3 {
                let p00 = src[((y0 as isize * src_wd + x0 as isize) * 4 + c)
                    as usize];
                let p01 = src[((y0 as isize * src_wd + x1 as isize) * 4 + c)
                    as usize];
                let p10 = src[((y1 as isize * src_wd + x0 as isize) * 4 + c)
                    as usize];
                let p11 = src[((y1 as isize * src_wd + x1 as isize) * 4 + c)
                    as usize];
                let top = p00 as f64 + (p01 as f64 - p00 as f64) * wx;
                let bottom = p10 as f64 + (p11 as f64 - p10 as f64) * wx;
                // Same u8 rounding _resizeRegion stores, then ImageNet norm.
                let v =
                    clamp_i((top + (bottom - top) * wy).round() as i32, 0, 255)
                        as f64;
                dst[c as usize * plane + di] =
                    ((v / 255.0 - MEAN[c as usize]) / STD[c as usize]) as f32;
            }
        }
    }
    (plane * 3) as i32
}

/// Argmax + blank/repeat dedup over CTC logits. Exact port of the numeric
/// half of `_ctcDecode`: emits surviving class ids in order, returns their
/// count (or -1 on bad pointers/dimensions). The caller maps ids through
/// its charset (strings stay in Dart); f32 comparison extends to f64
/// losslessly, so the argmax agrees with Float32List `>` bit for bit.
#[no_mangle]
pub unsafe extern "C" fn ocr_ctc_decode_ids(
    probs: *const f32,
    steps: i32,
    classes: i32,
    charset_len: i32,
    out_ids: *mut i32,
) -> i32 {
    if probs.is_null() || out_ids.is_null() {
        return -1;
    }
    if steps <= 0 || classes <= 0 || charset_len <= 0 {
        return -1;
    }
    let probs =
        core::slice::from_raw_parts(probs, (steps as usize) * (classes as usize));
    let out = core::slice::from_raw_parts_mut(out_ids, steps as usize);
    let mut prev = 0i32;
    let mut n = 0usize;
    for t in 0..steps as usize {
        let row = t * classes as usize;
        let mut best = 0i32;
        let mut best_score = probs[row];
        for c in 1..classes as usize {
            let score = probs[row + c];
            if score > best_score {
                best_score = score;
                best = c as i32;
            }
        }
        if best != 0 && best != prev && best < charset_len {
            out[n] = best;
            n += 1;
        }
        prev = best;
    }
    n as i32
}

#[inline]
fn iou(a: &[i32; 4], b: &[i32; 4]) -> f64 {
    let left = a[0].max(b[0]);
    let top = a[1].max(b[1]);
    let right = a[2].min(b[2]);
    let bottom = a[3].min(b[3]);
    if left >= right || top >= bottom {
        return 0.0;
    }
    let inter = ((right - left) * (bottom - top)) as f64;
    let area_a = ((a[2] - a[0]) * (a[3] - a[1])) as f64;
    let area_b = ((b[2] - b[0]) * (b[3] - b[1])) as f64;
    inter / (area_a + area_b - inter)
}

/// IoU dedup over tile boxes. Exact port of the `_detectBoxes` accumulation
/// (`iou > 0.5` suppresses, first box wins): reads n boxes as packed
/// l,t,r,b int32s, writes the kept boxes back in order, returns the kept
/// count (or -1 on bad pointers/dimensions).
#[no_mangle]
pub unsafe extern "C" fn ocr_dedup_boxes(
    in_boxes: *const i32,
    n: i32,
    out_boxes: *mut i32,
) -> i32 {
    if in_boxes.is_null() || out_boxes.is_null() {
        return -1;
    }
    if n < 0 {
        return -1;
    }
    let n = n as usize;
    let src = core::slice::from_raw_parts(in_boxes, n * 4);
    let dst = core::slice::from_raw_parts_mut(out_boxes, n * 4);
    let mut kept = 0usize;
    for i in 0..n {
        let b = [src[i * 4], src[i * 4 + 1], src[i * 4 + 2], src[i * 4 + 3]];
        let mut drop = false;
        for k in 0..kept {
            let a = [
                dst[k * 4],
                dst[k * 4 + 1],
                dst[k * 4 + 2],
                dst[k * 4 + 3],
            ];
            if iou(&a, &b) > 0.5 {
                drop = true;
                break;
            }
        }
        if !drop {
            dst[kept * 4] = b[0];
            dst[kept * 4 + 1] = b[1];
            dst[kept * 4 + 2] = b[2];
            dst[kept * 4 + 3] = b[3];
            kept += 1;
        }
    }
    kept as i32
}
