# Kotlin host for `rhttp-uniffi`

The smallest real host for this binding: it compiles the generated Kotlin
bindings, loads the cdylib through JNA, and measures end-to-end throughput
against a local server.

It exists because the Rust-only probe (`../../tests/throughput.rs`) can only
measure the binding layer, and the "≥ 80% of the Flutter Rust Bridge path"
question needs a host language on at least one side. This is that host.

## Requirements

- JDK 21 (Gradle 8.14 does not run on newer JDKs, and the toolchain here is
  `C:\Program Files\Android\openjdk\jdk-21.0.8`)
- Gradle 8.14 or newer — the repository's `android/gradle/wrapper` ships only
  `gradle-wrapper.properties`, so there is no wrapper jar to run; use an
  installed `gradle` or an unpacked distribution
- a built `rhttp_uniffi.dll` (Windows) or `librhttp_uniffi.so` (Linux)

## Run

```bat
cd packages\rhttp\rust
set RUSTFLAGS=--cfg reqwest_unstable
cargo build -p rhttp-uniffi --lib --release
cargo build -p rhttp-uniffi-bindgen --bin uniffi-bindgen --release
target\release\uniffi-bindgen.exe generate --metadata-no-deps -n -l kotlin ^
  -o uniffi\host\kotlin\build\generated\uniffi target\release\rhttp_uniffi.dll

cd uniffi\host\kotlin
gradle run -PnativeDir=D:/venera/unified/packages/rhttp/rust/target/release
```

`-PnativeDir` becomes `-Djna.library.path` for the JVM; without it JNA cannot find
the library and the run fails at class initialization.

`build/generated/uniffi` and `.gradle` are not committed — regenerate them.

## What it measures

Both paths download the same 64 MiB body, in 1024 chunks, from a server in the
same process on `127.0.0.1`:

| path | what it is |
|---|---|
| `uniffi` | `RhttpClient.streamGet` + `nextChunk()` — transport, uniffi FFI, JNA copy, coroutine bridge |
| `jdk` | `java.net.http.HttpClient` + `BodyHandlers.ofInputStream` — control, no FFI |

Two warmup rounds, then nine interleaved rounds; the median is reported with the
observed range. Interleaving matters: the sequential version let whichever path
ran later inherit a slow machine moment, which produced 302 MiB/s and 870 MiB/s
for the same code within one run.

Environment knobs, for studying that noise without a rebuild:
`BENCH_BODY_MIB` (default 64), `BENCH_WARMUP` (2), `BENCH_ROUNDS` (9).

## Numbers on this machine

```text
uniffi (Kotlin host)   median  588 / 700 / 792 MiB/s   (three runs)
JDK HttpClient         median  366 / 368 / 499 MiB/s   (same three runs)
```

Interpretation:

- the uniffi path was never slower than the JVM's own HTTP client;
- the spread *within* a path across runs (≈ 200 MiB/s) is larger than the gap
  *between* paths, so the honest claim is "the binding does not show up as a
  cost", not a percentage;
- these are loopback numbers on one laptop, not a property of uniffi.

**Not measured here:** the Flutter/Frb side. Comparing the two bindings end to
end needs a Dart host reading the same payload; this repository has no minimal
one yet.
