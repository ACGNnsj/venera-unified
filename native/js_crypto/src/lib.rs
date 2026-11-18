// SPDX-License-Identifier: GPL-3.0-or-later
//! Raw-block crypto for the JS convert bridge (lib/foundation/js_engine.dart).
//!
//! Mirrors native/zip_stream shape: plain extern C fns, negative error
//! classes, caller-allocated outputs, no allocator handshake. The Dart side
//! (lib/foundation/js_crypto_native.dart) falls back to the pure-Dart
//! implementation on any error, so per-source parity holds even where this
//! library is absent.
//!
//! V1 scope: hashes + HMAC + AES-ECB/CBC (raw blocks, no padding: exactly
//! the pointycastle processBlock loop semantics). AES-CFB/OFB and RSA stay
//! in Dart until latency data says otherwise.

use aes::cipher::generic_array::GenericArray;
use aes::cipher::{BlockDecrypt, BlockEncrypt, KeyInit};
use aes::{Aes128, Aes192, Aes256};

/// Must match JsCryptoNative version check.
#[no_mangle]
pub extern "C" fn js_crypto_version() -> u32 {
    1
}

#[inline]
unsafe fn in_bytes<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    Some(core::slice::from_raw_parts(ptr, len))
}

#[inline]
unsafe fn out_bytes<'a>(ptr: *mut u8, cap: usize) -> Option<&'a mut [u8]> {
    if ptr.is_null() {
        return None;
    }
    Some(core::slice::from_raw_parts_mut(ptr, cap))
}

// Error classes (-1 null pointer, -2 unsupported id, -3 crypto failure,
// -4 bad key/iv length, -5 bad data length, -6 output too small).

/// algo: 1 md5, 2 sha1, 3 sha256, 4 sha512. Returns digest bytes written.
#[no_mangle]
pub unsafe extern "C" fn js_crypto_hash(
    algo: u32,
    data_ptr: *const u8,
    data_len: usize,
    out_ptr: *mut u8,
    out_cap: usize,
) -> i32 {
    let data = match in_bytes(data_ptr, data_len) {
        Some(d) => d,
        None => return -1,
    };
    let out = match out_bytes(out_ptr, out_cap) {
        Some(o) => o,
        None => return -1,
    };
    macro_rules! emit {
        ($digest:expr) => {{
            let d = $digest;
            if out.len() < d.len() {
                return -6;
            }
            out[..d.len()].copy_from_slice(&d);
            return d.len() as i32;
        }};
    }
    match algo {
        1 => {
            use md5::Digest as _;
            emit!(md5::Md5::digest(data))
        }
        2 => {
            use sha1::Digest as _;
            emit!(sha1::Sha1::digest(data))
        }
        3 => {
            use sha2::Digest as _;
            emit!(sha2::Sha256::digest(data))
        }
        4 => {
            use sha2::Digest as _;
            emit!(sha2::Sha512::digest(data))
        }
        _ => -2,
    }
}

/// hash_id: same ids as js_crypto_hash. Returns MAC bytes written.
#[no_mangle]
pub unsafe extern "C" fn js_crypto_hmac(
    hash_id: u32,
    key_ptr: *const u8,
    key_len: usize,
    data_ptr: *const u8,
    data_len: usize,
    out_ptr: *mut u8,
    out_cap: usize,
) -> i32 {
    use hmac::Mac as _;
    let key = match in_bytes(key_ptr, key_len) {
        Some(k) => k,
        None => return -1,
    };
    let data = match in_bytes(data_ptr, data_len) {
        Some(d) => d,
        None => return -1,
    };
    let out = match out_bytes(out_ptr, out_cap) {
        Some(o) => o,
        None => return -1,
    };
    macro_rules! emit {
        ($mac:ty) => {{
            let mut m = match <$mac>::new_from_slice(key) {
                Ok(m) => m,
                Err(_) => return -3,
            };
            m.update(data);
            let d = m.finalize().into_bytes();
            if out.len() < d.len() {
                return -6;
            }
            out[..d.len()].copy_from_slice(&d);
            return d.len() as i32;
        }};
    }
    match hash_id {
        1 => emit!(hmac::Hmac<md5::Md5>),
        2 => emit!(hmac::Hmac<sha1::Sha1>),
        3 => emit!(hmac::Hmac<sha2::Sha256>),
        4 => emit!(hmac::Hmac<sha2::Sha512>),
        _ => -2,
    }
}

/// mode: 1 ECB, 2 CBC. encrypt: 1 encrypt, 0 decrypt. Raw block chaining,
/// no padding: in_len must be a nonzero multiple of 16. ECB ignores the
/// iv pointers (may be null). Returns bytes written (= in_len).
#[no_mangle]
pub unsafe extern "C" fn js_crypto_aes(
    mode: u32,
    encrypt: u32,
    key_ptr: *const u8,
    key_len: usize,
    iv_ptr: *const u8,
    iv_len: usize,
    in_ptr: *const u8,
    in_len: usize,
    out_ptr: *mut u8,
    out_cap: usize,
) -> i32 {
    let key = match in_bytes(key_ptr, key_len) {
        Some(k) => k,
        None => return -1,
    };
    let input = match in_bytes(in_ptr, in_len) {
        Some(d) => d,
        None => return -1,
    };
    let out = match out_bytes(out_ptr, out_cap) {
        Some(o) => o,
        None => return -1,
    };
    if input.is_empty() || input.len() % 16 != 0 {
        return -5;
    }
    if out.len() < input.len() {
        return -6;
    }
    let out = &mut out[..input.len()];
    let enc = encrypt != 0;
    match (mode, key.len()) {
        (1, 16) => raw_ecb::<Aes128>(key, input, out, enc),
        (1, 24) => raw_ecb::<Aes192>(key, input, out, enc),
        (1, 32) => raw_ecb::<Aes256>(key, input, out, enc),
        (2, 16) => {
            let iv = match in_bytes(iv_ptr, iv_len) {
                Some(v) => v,
                None => return -1,
            };
            if iv.len() != 16 {
                return -4;
            }
            raw_cbc::<Aes128>(key, iv, input, out, enc)
        }
        (2, 24) => {
            let iv = match in_bytes(iv_ptr, iv_len) {
                Some(v) => v,
                None => return -1,
            };
            if iv.len() != 16 {
                return -4;
            }
            raw_cbc::<Aes192>(key, iv, input, out, enc)
        }
        (2, 32) => {
            let iv = match in_bytes(iv_ptr, iv_len) {
                Some(v) => v,
                None => return -1,
            };
            if iv.len() != 16 {
                return -4;
            }
            raw_cbc::<Aes256>(key, iv, input, out, enc)
        }
        (1 | 2, _) => -4,
        _ => -2,
    }
}

fn raw_ecb<C>(key: &[u8], input: &[u8], out: &mut [u8], enc: bool) -> i32
where
    C: KeyInit + BlockEncrypt + BlockDecrypt,
{
    let cipher = match C::new_from_slice(key) {
        Ok(c) => c,
        Err(_) => return -4,
    };
    for (src, dst) in input.chunks_exact(16).zip(out.chunks_exact_mut(16)) {
        let mut block = GenericArray::clone_from_slice(src);
        if enc {
            cipher.encrypt_block(&mut block);
        } else {
            cipher.decrypt_block(&mut block);
        }
        dst.copy_from_slice(&block);
    }
    input.len() as i32
}

fn raw_cbc<C>(key: &[u8], iv: &[u8], input: &[u8], out: &mut [u8], enc: bool) -> i32
where
    C: KeyInit + BlockEncrypt + BlockDecrypt,
{
    let cipher = match C::new_from_slice(key) {
        Ok(c) => c,
        Err(_) => return -4,
    };
    let mut prev = [0u8; 16];
    prev.copy_from_slice(&iv[..16]);
    if enc {
        for (src, dst) in input.chunks_exact(16).zip(out.chunks_exact_mut(16)) {
            let mut block = GenericArray::clone_from_slice(src);
            for i in 0..16 {
                block[i] ^= prev[i];
            }
            cipher.encrypt_block(&mut block);
            dst.copy_from_slice(&block);
            prev.copy_from_slice(dst);
        }
    } else {
        for (src, dst) in input.chunks_exact(16).zip(out.chunks_exact_mut(16)) {
            let mut block = GenericArray::clone_from_slice(src);
            cipher.decrypt_block(&mut block);
            for i in 0..16 {
                dst[i] = block[i] ^ prev[i];
            }
            prev.copy_from_slice(src);
        }
    }
    input.len() as i32
}
