//! Streaming ZIP writer kernel as a light C ABI crate (no tokio, no FRB).
//!
//! Replaces the in-memory archive-package encode in the zip_writer fallback
//! path (and the EPUB staging directory) with an open/add/close handle
//! behind four C symbols: version, open, add, close. Entries stream one at a
//! time; at most one file's bytes sit in memory. The Dart caller passes
//! mimetype with method 0 (stored) to satisfy the EPUB container spec.
//! Deterministic output: fixed DOS timestamp, UTF-8 flag set. No zip64 here.

use std::collections::HashMap;
use std::fs::File;
use std::io::Write;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Mutex, OnceLock};

use flate2::write::DeflateEncoder;
use flate2::{Compression, Crc};

struct CentralEntry {
    name: Vec<u8>,
    crc: u32,
    compressed_size: u32,
    size: u32,
    header_offset: u32,
    method: u16,
}

struct Session {
    file: File,
    offset: u64,
    central: Vec<CentralEntry>,
}

fn slots() -> &'static Mutex<HashMap<i64, Session>> {
    static SLOTS: OnceLock<Mutex<HashMap<i64, Session>>> = OnceLock::new();
    SLOTS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn next_id() -> i64 {
    static NEXT: AtomicI64 = AtomicI64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

// Fixed DOS timestamp (2020-01-01 00:00:00), like the Dart fallback.
const DOS_TIME: u16 = 0x0000;
const DOS_DATE: u16 = 0x5021;

fn write_u16(session: &mut Session, v: u16) -> std::io::Result<()> {
    session.offset += 2;
    session.file.write_all(&v.to_le_bytes())
}

fn write_u32(session: &mut Session, v: u32) -> std::io::Result<()> {
    session.offset += 4;
    session.file.write_all(&v.to_le_bytes())
}

fn write_all(session: &mut Session, bytes: &[u8]) -> std::io::Result<()> {
    session.offset += bytes.len() as u64;
    session.file.write_all(bytes)
}

#[no_mangle]
pub extern "C" fn zip_stream_version() -> u32 {
    1
}

/// Open path for streaming writes. Returns a positive handle, or a negative
/// error class: -1 null pointer, -3 I/O error, -5 bad path.
#[no_mangle]
pub unsafe extern "C" fn zip_stream_open(path: *const u8, path_len: usize) -> i64 {
    if path.is_null() {
        return -1;
    }
    let bytes = core::slice::from_raw_parts(path, path_len);
    let path = match core::str::from_utf8(bytes) {
        Ok(p) if !p.is_empty() => p,
        _ => return -5,
    };
    let file = match File::create(path) {
        Ok(f) => f,
        Err(_) => return -3,
    };
    let id = next_id();
    match slots().lock() {
        Ok(mut guard) => guard.insert(
            id,
            Session {
                file,
                offset: 0,
                central: Vec::new(),
            },
        ),
        Err(_) => return -3,
    };
    id
}

/// Append one entry. Method is 0 (stored) or 8 (deflated), level 0-9.
/// Returns 0 on success; negative error class: -1 null pointer, -2 bad
/// handle, -3 I/O error, -4 bad method, -5 bad name/data size, -6 over 4 GiB.
#[no_mangle]
pub unsafe extern "C" fn zip_stream_add(
    handle: i64,
    name_ptr: *const u8,
    name_len: usize,
    data_ptr: *const u8,
    data_len: usize,
    method: u32,
    level: u8,
) -> i32 {
    if name_ptr.is_null() || (data_ptr.is_null() && data_len > 0) {
        return -1;
    }
    if method != 0 && method != 8 {
        return -4;
    }
    let name = core::slice::from_raw_parts(name_ptr, name_len);
    if name.is_empty() || name.len() > 0xffff {
        return -5;
    }
    let data = core::slice::from_raw_parts(data_ptr, data_len);
    if data.len() > u32::MAX as usize {
        return -5;
    }
    let mut guard = match slots().lock() {
        Ok(g) => g,
        Err(_) => return -3,
    };
    let session = match guard.get_mut(&handle) {
        Some(s) => s,
        None => return -2,
    };
    let mut crc = Crc::new();
    crc.update(data);
    let sum = crc.sum();
    let payload: Vec<u8> = if method == 0 {
        data.to_vec()
    } else {
        let mut enc = DeflateEncoder::new(
            Vec::new(),
            Compression::new(level.clamp(0, 9) as u32),
        );
        if enc.write_all(data).is_err() {
            return -3;
        }
        match enc.finish() {
            Ok(v) => v,
            Err(_) => return -3,
        }
    };
    if payload.len() > u32::MAX as usize {
        return -5;
    }
    if session.offset > u32::MAX as u64 {
        return -6;
    }
    let header_offset = session.offset as u32;
    let written: std::io::Result<()> = (|| {
        write_u32(session, 0x04034b50)?;
        write_u16(session, 20)?;
        write_u16(session, 0x0800)?;
        write_u16(session, method as u16)?;
        write_u16(session, DOS_TIME)?;
        write_u16(session, DOS_DATE)?;
        write_u32(session, sum)?;
        write_u32(session, payload.len() as u32)?;
        write_u32(session, data.len() as u32)?;
        write_u16(session, name.len() as u16)?;
        write_u16(session, 0)?;
        write_all(session, name)?;
        write_all(session, &payload)?;
        Ok(())
    })();
    if written.is_err() {
        return -3;
    }
    session.central.push(CentralEntry {
        name: name.to_vec(),
        crc: sum,
        compressed_size: payload.len() as u32,
        size: data.len() as u32,
        header_offset,
        method: method as u16,
    });
    0
}

/// Write the central directory plus end record, flush, release the handle.
/// Returns 0 on success; -2 bad handle, -3 I/O error.
#[no_mangle]
pub unsafe extern "C" fn zip_stream_close(handle: i64) -> i32 {
    let mut session = {
        let mut guard = match slots().lock() {
            Ok(g) => g,
            Err(_) => return -3,
        };
        match guard.remove(&handle) {
            Some(s) => s,
            None => return -2,
        }
    };
    if session.central.len() > 0xffff {
        return -3;
    }
    let written: std::io::Result<()> = (|| {
        let central_offset = session.offset;
        // Index-based: entry borrows must not overlap the writer borrows.
        for index in 0..session.central.len() {
            let (method, crc, compressed_size, size, name, header_offset) = {
                let entry = &session.central[index];
                (
                    entry.method,
                    entry.crc,
                    entry.compressed_size,
                    entry.size,
                    entry.name.clone(),
                    entry.header_offset,
                )
            };
            write_u32(&mut session, 0x02014b50)?;
            write_u16(&mut session, 20)?;
            write_u16(&mut session, 20)?;
            write_u16(&mut session, 0x0800)?;
            write_u16(&mut session, method)?;
            write_u16(&mut session, DOS_TIME)?;
            write_u16(&mut session, DOS_DATE)?;
            write_u32(&mut session, crc)?;
            write_u32(&mut session, compressed_size)?;
            write_u32(&mut session, size)?;
            write_u16(&mut session, name.len() as u16)?;
            write_u16(&mut session, 0)?;
            write_u16(&mut session, 0)?;
            write_u16(&mut session, 0)?;
            write_u16(&mut session, 0)?;
            write_u32(&mut session, 0)?;
            write_u32(&mut session, header_offset)?;
            write_all(&mut session, &name)?;
        }
        let central_size = session.offset - central_offset;
        write_u32(&mut session, 0x06054b50)?;
        write_u16(&mut session, 0)?;
        write_u16(&mut session, 0)?;
        write_u16(&mut session, session.central.len() as u16)?;
        write_u16(&mut session, session.central.len() as u16)?;
        write_u32(&mut session, central_size as u32)?;
        write_u32(&mut session, central_offset as u32)?;
        write_u16(&mut session, 0)?;
        session.file.flush()?;
        Ok(())
    })();
    if written.is_err() {
        return -3;
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::read::DeflateDecoder;
    use std::io::Read;

    fn temp_output(name: &str) -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("venera_zip_stream_{}_{}", std::process::id(), name));
        let _ = std::fs::remove_file(&p);
        p
    }

    fn le_u16(bytes: &[u8], at: usize) -> u16 {
        u16::from_le_bytes([bytes[at], bytes[at + 1]])
    }

    fn le_u32(bytes: &[u8], at: usize) -> u32 {
        u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
    }

    #[test]
    fn stored_first_then_deflated_round_trip() {
        let path = temp_output("roundtrip.zip");
        let path_str = path.to_string_lossy().into_owned();
        let handle = unsafe { zip_stream_open(path_str.as_ptr(), path_str.len()) };
        assert!(handle > 0);
        let mimetype = b"application/epub+zip";
        assert_eq!(
            unsafe {
                zip_stream_add(handle, mimetype.as_ptr(), mimetype.len(), mimetype.as_ptr(), mimetype.len(), 0, 0)
            },
            0
        );
        let payload: Vec<u8> = (0..4096u32).map(|i| (i % 251) as u8).collect();
        let name = b"OEBPS/images/img0.jpg";
        assert_eq!(
            unsafe {
                zip_stream_add(handle, name.as_ptr(), name.len(), payload.as_ptr(), payload.len(), 8, 6)
            },
            0
        );
        assert_eq!(unsafe { zip_stream_close(handle) }, 0);
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(&bytes[0..4], &[0x50, 0x4B, 0x03, 0x04]);
        assert_eq!(le_u16(&bytes, 8), 0);
        let name_len = le_u16(&bytes, 26) as usize;
        assert_eq!(&bytes[30..30 + name_len], b"mimetype");
        let mut crc = Crc::new();
        crc.update(mimetype);
        assert_eq!(le_u32(&bytes, 14), crc.sum());
        let first_len = 30 + name_len + mimetype.len();
        assert_eq!(&bytes[first_len..first_len + 4], &[0x50, 0x4B, 0x03, 0x04]);
        assert_eq!(le_u16(&bytes, first_len + 8), 8);
        let second_name_len = le_u16(&bytes, first_len + 26) as usize;
        let comp_len = le_u32(&bytes, first_len + 18) as usize;
        let comp_at = first_len + 30 + second_name_len;
        let mut decoder = DeflateDecoder::new(&bytes[comp_at..comp_at + comp_len]);
        let mut back = Vec::new();
        decoder.read_to_end(&mut back).unwrap();
        assert_eq!(back, payload);
        let eocd = bytes.len() - 22;
        assert_eq!(&bytes[eocd..eocd + 4], &[0x50, 0x4B, 0x05, 0x06]);
        assert_eq!(le_u16(&bytes, eocd + 8), 2);
        assert_eq!(le_u16(&bytes, eocd + 10), 2);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn error_classes() {
        assert_eq!(unsafe { zip_stream_add(0, [1u8].as_ptr(), 1, [2u8].as_ptr(), 1, 8, 6) }, -2);
        assert_eq!(unsafe { zip_stream_close(0) }, -2);
        let path = temp_output("errors.zip");
        let path_str = path.to_string_lossy().into_owned();
        let handle = unsafe { zip_stream_open(path_str.as_ptr(), path_str.len()) };
        assert!(handle > 0);
        assert_eq!(unsafe { zip_stream_add(handle, [1u8].as_ptr(), 1, [2u8].as_ptr(), 1, 7, 6) }, -4);
        assert_eq!(unsafe { zip_stream_close(handle) }, 0);
        let _ = std::fs::remove_file(&path);
    }
}

