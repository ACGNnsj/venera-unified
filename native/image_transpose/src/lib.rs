//! Whole-image 90-degree transpose for u32 pixel buffers.
//!
//! Exact port of `Image.copyAndRotate90` in
//! `lib/foundation/image_processing.dart`:
//! out[i * h + (h - 1 - j)] = src[j * w + i], new dims (h, w).
//! Two C symbols: version + transpose. No new dependencies.

#[no_mangle]
pub extern "C" fn image_transpose_version() -> u32 {
    1
}

/// Transposes a w*h u32 pixel buffer 90 degrees. Exact port of
/// `copyAndRotate90`: no float math, index permutation only.
/// Returns 0 on success, -1 on bad pointers/dimensions.
#[no_mangle]
pub unsafe extern "C" fn image_transpose_u32(
    input: *const u32,
    width: i32,
    height: i32,
    output: *mut u32,
) -> i32 {
    if input.is_null() || output.is_null() {
        return -1;
    }
    if width <= 0 || height <= 0 {
        return -1;
    }
    let (w, h) = (width as usize, height as usize);
    let src = core::slice::from_raw_parts(input, w * h);
    let dst = core::slice::from_raw_parts_mut(output, w * h);
    for j in 0..h {
        for i in 0..w {
            dst[i * h + (h - 1 - j)] = src[j * w + i];
        }
    }
    0
}
