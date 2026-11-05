//! JPEG encode kernel as a light C ABI crate (no tokio, no FRB).
//!
//! Replaces `_encodePdfPage`'s `image.encodeJpg(q92)` with the
//! `jpeg-encoder` codec (pure Rust, optional AVX2 path) behind three C
//! symbols: version, encode_bgra, free. The Dart side keeps its
//! package:image path as fallback (zero intrusion).

use jpeg_encoder::{ColorType, Encoder};

#[no_mangle]
pub extern "C" fn jpg_encode_version() -> u32 {
    1
}

/// Encode straight BGRA pixels (as rendered by pdfrx) to a JPEG blob.
///
/// Returns the output length (>= 0) on success; negative = error class:
/// -1 null pointer, -2 bad dimensions, -3 input length mismatch,
/// -4 encoder failure. The blob is callee-allocated; the caller must copy
/// it out and release it with [`jpg_encode_free`].
#[no_mangle]
pub unsafe extern "C" fn jpg_encode_bgra(
    input: *const u8,
    input_len: usize,
    width: u32,
    height: u32,
    quality: u8,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> i64 {
    if input.is_null() || out_data.is_null() || out_len.is_null() {
        return -1;
    }
    // jpeg-encoder takes u16 extents; PDF render caps the long edge at 3000.
    if width == 0 || height == 0 || width > 65535 || height > 65535 {
        return -2;
    }
    let expect = (width as usize) * (height as usize) * 4;
    if input_len != expect {
        return -3;
    }
    let q = quality.clamp(1, 100);
    let src = core::slice::from_raw_parts(input, input_len);
    let mut out: Vec<u8> = Vec::new();
    // ponytail: Bgra direct, no RGBA staging copy; crate converts in-encoder.
    let ok = Encoder::new(&mut out, q)
        .encode(src, width as u16, height as u16, ColorType::Bgra)
        .is_ok();
    if !ok {
        return -4;
    }
    // Sanity: a JPEG blob is never empty; guards a partial writer state.
    if out.is_empty() {
        return -4;
    }
    let len = out.len();
    *out_data = out.as_mut_ptr();
    *out_len = len;
    core::mem::forget(out);
    len as i64
}

/// Release a blob from [`jpg_encode_bgra`]. No-op on null.
#[no_mangle]
pub unsafe extern "C" fn jpg_encode_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    drop(Vec::from_raw_parts(ptr, len, len));
}

// Self-check: gradient round-trip sanity without I/O.
#[cfg(test)]
mod tests {
    #[test]
    fn bgra_round_trip_nonempty() {
        let (w, h) = (64u32, 48u32);
        let mut bgra = vec![0u8; (w as usize) * (h as usize) * 4];
        for y in 0..h as usize {
            for x in 0..w as usize {
                let i = (y * w as usize + x) * 4;
                bgra[i] = (x * 255 / w as usize) as u8;
                bgra[i + 1] = (y * 255 / h as usize) as u8;
                bgra[i + 2] = 128;
                bgra[i + 3] = 255;
            }
        }
        let mut out_data: *mut u8 = core::ptr::null_mut();
        let mut out_len: usize = 0;
        let rc = unsafe {
            super::jpg_encode_bgra(
                bgra.as_ptr(),
                bgra.len(),
                w,
                h,
                92,
                &mut out_data,
                &mut out_len,
            )
        };
        assert!(rc > 0);
        assert_eq!(rc as usize, out_len);
        let blob = unsafe { core::slice::from_raw_parts(out_data, out_len) };
        // SOI marker + non-trivial payload.
        assert_eq!(&blob[0..2], &[0xFF, 0xD8]);
        assert!(out_len > 1000);
        unsafe {
            super::jpg_encode_free(out_data, out_len);
        }
        // Error classes: null, dims, length.
        assert_eq!(
            unsafe {
                super::jpg_encode_bgra(
                    core::ptr::null(),
                    0,
                    w,
                    h,
                    92,
                    &mut out_data,
                    &mut out_len,
                )
            },
            -1
        );
        assert_eq!(
            unsafe {
                super::jpg_encode_bgra(
                    bgra.as_ptr(),
                    bgra.len(),
                    0,
                    h,
                    92,
                    &mut out_data,
                    &mut out_len,
                )
            },
            -2
        );
        assert_eq!(
            unsafe {
                super::jpg_encode_bgra(
                    bgra.as_ptr(),
                    7,
                    w,
                    h,
                    92,
                    &mut out_data,
                    &mut out_len,
                )
            },
            -3
        );
    }
}
