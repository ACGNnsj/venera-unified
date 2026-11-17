//! Horizontal white-border insets for RGBA page buffers.
//!
//! Exact port of `horizontalWhiteBorderInsets` in
//! `lib/features/reader/white_border_crop.dart`: scan each row from both
//! edges while every seen pixel is near-white (alpha 0 counts as white;
//! otherwise alpha 255 with r, g, b >= 253), keep the per-edge minimum, then
//! apply the quarter-width cap, the 1%-width minimum and the 0.2% padding.
//! Two C symbols: version + insets. No new dependencies.

#[no_mangle]
pub extern "C" fn white_border_version() -> u32 {
    1
}

#[inline]
fn is_white(pixels: &[u8], offset: usize) -> bool {
    if pixels[offset + 3] == 0 {
        return true;
    }
    pixels[offset + 3] == 255
        && pixels[offset] >= 253
        && pixels[offset + 1] >= 253
        && pixels[offset + 2] >= 253
}

/// Scans a w*h RGBA buffer for horizontal white-border insets. Exact port of
/// `horizontalWhiteBorderInsets`: `(0, 0)` (written through the out pointers)
/// on short/narrow buffers and length mismatches, matching the Dart guard;
/// returns 0 on success and -1 only on null pointers or hostile dimensions.
#[no_mangle]
pub unsafe extern "C" fn white_border_insets(
    input: *const u8,
    len: usize,
    width: i32,
    height: i32,
    out_left: *mut i32,
    out_right: *mut i32,
) -> i32 {
    if input.is_null() || out_left.is_null() || out_right.is_null() {
        return -1;
    }
    if width < 32 || height < 1 {
        return -1;
    }
    let (w, h) = (width as usize, height as usize);
    let need = w.checked_mul(h).and_then(|n| n.checked_mul(4));
    if need != Some(len) {
        // Mirror the Dart guard: a mismatched buffer means "no crop".
        out_left.write(0);
        out_right.write(0);
        return 0;
    }
    let px = core::slice::from_raw_parts(input, len);
    // w ~/ 4 in Dart; w >= 32 here so the cast cannot overflow.
    let maximum = w as i32 / 4;
    let padding = ((w as f64 * 0.002).ceil() as i32).clamp(2, maximum);
    let minimum = ((w as f64 * 0.01).ceil() as i32).clamp(4, maximum);
    let mut left = maximum + 1;
    let mut right = maximum + 1;
    for y in 0..h {
        let mut x = 0;
        while x < left {
            if !is_white(px, (y * w + x as usize) * 4) {
                left = x;
                break;
            }
            x += 1;
        }
        let mut xr = 0;
        while xr < right {
            if !is_white(px, (y * w + (w - xr as usize - 1)) * 4) {
                right = xr;
                break;
            }
            xr += 1;
        }
        if left == 0 && right == 0 {
            break;
        }
    }
    // padding <= minimum whenever an inset survives (0.2% < 1% below the
    // quarter-width cap, and both clamps share the same bounds), so the
    // subtraction cannot underflow; keep the exact Dart expression.
    let keep = |inset: i32| {
        if inset > maximum || inset < minimum {
            0
        } else {
            inset - padding
        }
    };
    out_left.write(keep(left));
    out_right.write(keep(right));
    0
}
