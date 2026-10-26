//! Generates Kotlin/Swift bindings for `rhttp-uniffi`.
//!
//! Run through the workspace, so the toolchain and the registry cache are the
//! ones the library already uses:
//!
//! ```text
//! cargo run --bin uniffi-bindgen -- generate \
//!   --library target/debug/rhttp_uniffi.dll \
//!   --language kotlin --out-dir out/kotlin
//! ```
//!
//! `--library` mode reads the exported metadata out of the compiled cdylib, so
//! there is no `.udl` file to keep in sync with the Rust types.

fn main() {
    uniffi::uniffi_bindgen_main();
}
