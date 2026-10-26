# rhttp-uniffi

uniffi bindings for `rhttp-core`, so Kotlin, Swift (and eventually C#) hosts can
share the HTTP stack that the Flutter app uses through Flutter Rust Bridge.

The crate contains no Flutter Rust Bridge type. Everything below re-exports the
pure-Rust `rhttp-core` crates.

## Exported surface

| Item | Kind | Notes |
|---|---|---|
| `RhttpClient` | object | `new(ClientOptions)`, `sendText(request)`, `sendBytes(request)`, `sendStream(request)`, `fetchText(url)`, `fetchBytes(url)`, `streamGet(url)`, `cancelAll()` |
| `ResponseStream` | object | `head()`, `nextChunk()`, `cancel()` |
| `RhttpError` | error enum | `Network{detail}`, `Status{statusCode, detail}`, `Cancelled`, `InvalidSettings{detail}` |
| `ClientOptions` | record | full mirror of `ClientSettings` |
| `defaultClientOptions()` | function | the core defaults (`HttpVersionPref.All`, `throwOnStatusCode = true`) |
| `HttpRequest` | record | `url`, `method` (null ⇒ `GET`), `headers`, `query`, `body` |
| `RequestBody` | enum | `Text{text}`, `Bytes{bytes}`, `Form{fields}`, `Multipart{payload}`, `Stream{source}` |
| `MultipartPayload` / `MultipartPart` / `MultipartValue` | record / record / enum | parts are `Text{text}`, `Bytes{bytes}`, or `File{path}` |
| `RhttpHeader` / `RhttpField` | record | `name`, `value` — headers use the first, query and form pairs the second |
| `ResponseHead` | record | `statusCode`, `headers`, `remoteIp` |
| `DnsResolverCallback` | foreign trait | host-implemented dynamic DNS |
| `RequestBodySource` | foreign trait | host-implemented chunk source for streamed uploads |

The error field is `detail` rather than `message` on purpose: uniffi generates an
exception class per variant, and a field named `message` collides with
`Throwable.message` in Kotlin — the generated file then does not compile.

### `ClientOptions`

Every `rhttp_core::ClientSettings` field is reachable:

- `userAgent`
- `httpVersionPref` — `Http10` / `Http11` / `Http2` / `Http3` / `All`
- `throwOnStatusCode`
- `cookieSettings` — `storeCookies`
- `timeoutSettings` — `timeout`, `connectTimeout`, `keepAliveTimeout`, `keepAlivePing` (`std::time::Duration`)
- `proxySettings` — `NoProxy` or `CustomProxyList(proxies: [{url, condition}])`
- `redirectSettings` — `NoRedirect` or `LimitedRedirects{maxRedirects}`
- `tlsSettings` — `trustRootCertificates`, `trustedRootCertificates` (PEM bytes), `verifyCertificates`, `clientCertificate`, `minTlsVersion`, `maxTlsVersion`, `sni`
- `dnsSettings` — `StaticDns{overrides, fallback}` or `DynamicDns{resolver}`

Durations arrive as `std::time::Duration` and are converted to
`chrono::Duration` for the core; values outside `chrono`'s range surface as
`RhttpError::InvalidSettings`.

## Requests and uploads

`HttpRequest` is the single request shape, shared by the buffered entry points
(`sendText`, `sendBytes`) and the streaming one (`sendStream`). Bodies:

```text
RequestBody::Text{text}          → builder.body(text)
RequestBody::Bytes{bytes}        → builder.body(bytes)
RequestBody::Form{fields}        → application/x-www-form-urlencoded
RequestBody::Multipart{payload}  → multipart/form-data
```

Multipart parts may be text, bytes, or a **path on the host filesystem**; a file
part is streamed from disk as the request is sent, so a large upload is never
staged in this binding. `fileName` and `contentType` map to the part's
`Content-Disposition` and `Content-Type`.

Form fields land in a `HashMap` in the core, so their order on the wire is not
part of the contract — only that they are form-encoded.

Streamed uploads (`RequestBody::Stream{source}`) cover the bodies that do not fit
in memory. The host implements the `RequestBodySource` foreign trait — one
`suspend`/`async` `nextChunk()` per call, `null` at the end — and the transport
pulls a chunk only when it is ready to write one, so a slow producer applies
backpressure instead of being buffered. Chunk boundaries are the host's business;
they do not have to match the socket writes. Because the total length is unknown
up front these requests go out with `Transfer-Encoding: chunked` rather than a
`Content-Length`; prefer `Bytes` when the body is already in memory.

## Streaming downloads

uniffi has no async iterator, so the body is modelled as a puller instead of a
push callback:

```text
sendStream(request) ──► ResponseStream ──► [chunk, chunk, ..., null]
                        head()            nextChunk()           cancel()
```

- `sendStream(request)` resolves once the **response head** has arrived, so a
  status error surfaces there (`RhttpError::Status`) rather than at the first
  chunk.
- `nextChunk()` returns the next chunk, or `null` at the end of the body.
- Chunk delivery is bounded (four chunks between the transport and the host), so
  a host that stops calling `nextChunk` applies backpressure instead of
  buffering the whole file.
- Kotlin wraps the loop in `flow { … }` on `Dispatchers.IO`; Swift in an
  `AsyncSequence`. Both `nextChunk` and `sendStream` are `suspend`/`async` because
  the crate exports with `async_runtime = "tokio"`.

No Rust thread ever calls back into host code, so a slow or buggy host cannot
re-enter the transport — this is the main reason the stream is a puller rather
than a foreign callback trait.

### Cancellation

Cancellation is reported as `RhttpError::Cancelled`, never as a normal end, so an
interrupted download is not mistaken for a complete one. Two levels:

- `stream.cancel()` (or dropping the handle) stops that one transfer. It is safe
  to call while `nextChunk()` is pending; the pending call resolves immediately.
- `client.cancelAll()` also stops bodies that already started, not just requests
  still waiting for headers.

## Dynamic DNS

`rhttp_core` resolves through an async `DnsResolver` trait, which uniffi cannot
export directly. `DnsResolverCallback` is the foreign counterpart and the
adapter bridges the two with `tokio::task::spawn_blocking`:

- the host implementation runs on a blocking worker, never on the async
  executor, so it may block briefly;
- if the host callback panics, the adapter answers "no records" and lets reqwest
  report a normal DNS error — the process must not abort (`panic = "abort"`).

## Build and test

`RUSTFLAGS=--cfg reqwest_unstable` is mandatory: the core enables reqwest's
HTTP/3 support, and reqwest refuses to compile without that cfg.

Cargo called straight from the DSH shell fails at TLS on this machine
(`schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS`), so builds go
through WSL interop. Two environment details matter:

- `TMP`, `TEMP` and `TMPDIR` must point at a writable directory inside the
  workspace. WSL hands the Windows process `TMP=/tmp`, and the multipart test
  writes a fixture through `std::env::temp_dir()`; without the override it fails
  with `拒绝访问 (os error 5)`.
- the `.bat` helpers must be CRLF; with LF-only endings `cmd.exe` eats the first
  characters of each line.

```bat
:: D:\venera\.scratch\test-uniffi.bat
@echo off
cd /d D:\venera\unified\packages\rhttp\rust
set "RUSTFLAGS=--cfg reqwest_unstable"
set "TMP=D:\venera\.scratch\tmp"
set "TEMP=D:\venera\.scratch\tmp"
set "TMPDIR=D:\venera\.scratch\tmp"
cargo test -p rhttp-uniffi
```

```text
wsl: cmd.exe /c "D:\venera\.scratch\test-uniffi.bat"   (translatePaths: false)
```

`RUSTFLAGS` must be set inside the batch file; exporting it from WSL does not
reach the Windows `cargo.exe`.

Current suite: 22 tests. Settings round-trip, core defaults, the dynamic DNS
bridge; the request mapping (method default, headers, query, every body variant,
multipart metadata, a stream body drained into the core stream); an upload seen by
a capture server (text body, form encoding, a multipart part with a real file, a
host stream whose chunks must arrive in order and be chunk-encoded), a streamed
request that carries a body; a status error, a timeout; and four streaming checks
(incremental delivery, single-stream cancel, client-wide cancel of a started
body, status error at stream open). Everything runs against loopback listeners,
so the suite needs no network. `tests/throughput.rs` adds a twenty-third test that
is `#[ignore]`d: it moves ~1 GiB to measure, and asserts nothing about speed.

## Generating bindings

`bindgen/` is a workspace member that exists only to host the generator; the
`cli` feature never reaches the library crate.

```bat
cd packages\rhttp\rust
set RUSTFLAGS=--cfg reqwest_unstable
cargo build -p rhttp-uniffi-bindgen --bin uniffi-bindgen
cargo build -p rhttp-uniffi --lib

target\debug\uniffi-bindgen.exe generate --metadata-no-deps -n ^
  -l kotlin -o <out>\kotlin target\debug\rhttp_uniffi.dll
target\debug\uniffi-bindgen.exe generate --metadata-no-deps -n ^
  -l swift -o <out>\swift target\debug\rhttp_uniffi.dll
```

Two flags are not optional here:

- `--metadata-no-deps` — without it the generator's internal `cargo metadata`
  resolves every target triple and tries to fetch wasm-only crates, which the
  sandboxed shell could not write into the cargo cache.
- `-n` — ktlint and swiftformat are not installed.

Generated output is not checked in; regenerate it from the source you are
actually shipping. `host/kotlin` does exactly that as part of its run (see
*Kotlin host*).

## Cross targets

Artifacts produced so far:

| Target | Artifact |
|---|---|
| `x86_64-pc-windows-msvc` | `rhttp_uniffi.dll` |
| `aarch64-linux-android` | `librhttp_uniffi.so`, 4.5 MiB, 82 exported functions |
| `armv7-linux-androideabi` | `librhttp_uniffi.so`, 3.1 MiB |
| `x86_64-linux-android` | `librhttp_uniffi.so`, 5.1 MiB |

CI builds the three Android targets — the `rhttp-android` job in
`.github/workflows/analyze.yml` reads `ndkVersion` from `android/app/build.gradle`
so the checker cannot drift from the app, then cross-compiles one target per
matrix leg and asserts the `.so` exists and is ELF.

`cargo ndk` is not installed here and is not needed: the NDK's own clang
wrappers do the job once `CC_*`, `AR_*` and `CARGO_TARGET_*_LINKER` point at
them. With NDK 28.0.13004108 and API level 24:

```bat
set BIN=%NDK%\toolchains\llvm\prebuilt\windows-x86_64\bin
set CC_aarch64_linux_android=%BIN%\aarch64-linux-android24-clang.cmd
set AR_aarch64_linux_android=%BIN%\llvm-ar.exe
set CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=%BIN%\aarch64-linux-android24-clang.cmd
cargo build -p rhttp-uniffi --lib --release --locked --target aarch64-linux-android
```

Swap the triple (`armv7a-linux-androideabi24`, `x86_64-linux-android24`) for the
other two ABIs. Two things bite on Windows:

- **`TMP` must be writable by the whole process tree.** `ring` compiles
  pregenerated `.S` files, and clang preprocesses those through a temp file.
  Under a sandboxed shell a child of cargo can be refused writes to `%TEMP%`
  even though the shell itself can write there — the giveaway is
  `clang: error: unable to make temporary file: Permission denied` only on the
  assembly files. Pointing `TMP`, `TEMP` and `TMPDIR` at a directory inside the
  workspace fixes it.
- **`.bat` helpers need CRLF.** With LF-only line endings `cmd.exe` drops the
  first bytes of each line, so `cd /d …` runs as `/d …` and `set X=…` runs as
  `=…`. The symptom looks like a missing directory rather than a broken script.

## Kotlin host

`host/kotlin` is a Gradle project that compiles the generated bindings and runs
them against a local server — the first real host for this binding, and the
smallest thing that can produce an end-to-end number.

```text
target\release\rhttp_uniffi.dll         native library (JNA loads it)
uniffi-bindgen generate -l kotlin …     writes build/generated/uniffi
gradle run -PnativeDir=<dir of the dll>
```

It measures two paths over the same 64 MiB, 1024-chunk loopback payload: the
generated `RhttpClient.streamGet` pull loop through JNA, and `java.net.http`
reading the same body with no FFI. Both are warmed for two rounds, then measured
in nine interleaved rounds so a slow moment hits both.

```text
uniffi (Kotlin host)   median  588 / 700 / 792 MiB/s   (three runs)
JDK HttpClient         median  366 / 368 / 499 MiB/s   (same three runs)
```

The uniffi path was never the slower one, and the spread between runs of a single
path is larger than the gap between paths. Read that as: **the binding is not the
bottleneck**; the number is this laptop's loopback, not a property of uniffi.

The Flutter/Frb side of the same question is measured in the next section, with
its own host.

## Dart host (FRB path)

`host/dart` is the mirror image of `host/kotlin`: a standalone Dart package that
imports the Flutter Rust Bridge bindings from the vendored package by relative
path — the generated files never import `package:rhttp/...`, so they can be
reached from outside that package — and reads the same loopback body twice, once
through `makeHttpRequestReceiveStream` (the layer the app uses today) and once
through `dart:io` with no FFI at all.

```text
dart pub get --offline
dart run bin/bench.dart        # RHTTP_DLL points at the built rhttp.dll
```

It runs as a plain `dart run`, not `flutter test` inside `unified/`: the app's
native-assets hook fetches pdfium at build time and fails outright when the
network is blocked.

Loopback throughput on this machine moves by more than 5× between runs depending
on what else is loaded, so the useful figure is each path against its own
baseline in the same run:

| run | frb | dart:io baseline | frb / baseline |
|---|---|---|---|
| 1 | 111.8 | 488.3 | 0.23 |
| 2 | 120.7 | 516.2 | 0.23 |
| 3 | 48.0 | 111.4 | 0.43 |
| 4 | 49.3 | 89.4 | 0.55 |
| 5 | 147.3 | 396.5 | 0.37 |

MiB/s, median of nine interleaved rounds after two warmups, 64 MiB in 1024
chunks. The Kotlin host on the same metric: uniffi 588 / 700 / 792 against a JDK
baseline of 366 / 368 / 499, i.e. **1.6× / 1.9× / 1.6×** of its own baseline.

Read together: pulling a chunk on demand costs little (the uniffi path keeps up
with, and here beats, the host's own HTTP client), while the FRB push path pays
roughly one port hop per chunk and lands at a fraction of the Dart baseline. For
a network-bound reader that is invisible; it is simply what the app pays today.

### Against the original acceptance line

The ticket's line was "uniffi ≥ 80% of the FRB figure". In a quiet window the two
absolute medians are ≈700 MiB/s (uniffi, Kotlin host) and ≈112 MiB/s (FRB, Dart
host), so uniffi lands around six times the FRB figure — the bar is met with room
to spare. These are different hosts, so the normalized comparison above is the
more defensible one, and it points the same way.

## Throughput inside Rust

Measured with
`cargo test -p rhttp-uniffi --release --test throughput -- --ignored --nocapture`:
a 64 MiB body in 1024 chunks over loopback, five rounds. Each round measures the
bare core twice and the uniffi path once, because loopback throughput on this
machine swings by more than 10% between runs — a plain core-vs-uniffi ratio
cannot resolve a per-chunk cost hidden inside that wobble. The second core run is
the control: same code, no binding involved.

```text
core (no binding) :  831.3 MiB/s
uniffi pull       :  827.3 MiB/s
core again        :  737.2 MiB/s   (control)
control drift     :  -11.3%        (same code, nothing changed)
uniffi vs core    :   -0.5%
```

The uniffi figure lands inside the control's drift, so the binding layer costs
less than this probe can resolve. An earlier run of the same probe, before the
control existed, reported 99.4% and a `+1.25 µs/chunk` delta; that was run-to-run
noise being read as a number, which is exactly what the control is there to
prevent.

## Hosts

- `host/kotlin` — Gradle project that compiles the Kotlin bindings and measures
  the uniffi path against `java.net.http`.
- `host/dart` — standalone Dart package that drives the Flutter Rust Bridge
  bindings and measures that path against `dart:io`.

Do not add this crate to the Flutter app's Dart dependencies; it exists only for
non-Flutter hosts. `host/dart` imports the app's generated bindings read-only and
is not part of the Flutter package's dependency graph.
