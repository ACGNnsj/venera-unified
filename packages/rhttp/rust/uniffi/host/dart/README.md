# Dart host

A standalone Dart package that drives the Flutter Rust Bridge bindings, so the
FRB path can be measured on the same machine and with the same loopback payload
as the uniffi path in `../kotlin`.

It imports the generated bindings out of the vendored package by relative path.
That works because those files never import `package:rhttp/...` — they use
relative imports plus `flutter_rust_bridge` and `freezed_annotation`, which this
package depends on. Nothing is copied, so the probe cannot drift from the
bindings the app actually ships.

## Running

The native library has to exist first:

```text
cargo build -p rhttp --lib        (in packages/rhttp/rust; RUSTFLAGS=--cfg reqwest_unstable)
```

Then:

```text
dart pub get --offline
dart run bin/bench.dart
```

`RHTTP_DLL` overrides the library path (default `rust/target/debug/rhttp.dll`,
relative to the working directory). `BENCH_BODY_MIB` (64), `BENCH_WARMUP` (2) and
`BENCH_ROUNDS` (9) size the measurement.

Run it with plain `dart run`, not `flutter test` inside `unified/`: the app's
native-assets hook fetches pdfium while building and fails when the network is
blocked.

## What it measures

Two paths over one Dart `HttpServer` payload of `BENCH_BODY_MIB` written in 64 KiB
chunks:

- `makeHttpRequestReceiveStream(...)` — the generated stream the app's
  `Rhttp.requestStream` wraps, consumed with `await for`;
- `dart:io` `HttpClient` — the same body with no FFI.

Both are warmed for `BENCH_WARMUP` rounds, then measured in `BENCH_ROUNDS`
interleaved rounds (median reported). Interleaving matters more than averaging:
loopback throughput on this machine swings by several times between runs, so a
path measured only in its own window reports the machine's mood.

The process ends with an explicit `exit(0)`: the FRB runtime keeps native threads
alive after `main` returns, so without it the run never terminates and a caller
waiting on it hangs.

Numbers and their reading live in `../../README.md` (sections *Dart host (FRB
path)* and *Against the original acceptance line*).
