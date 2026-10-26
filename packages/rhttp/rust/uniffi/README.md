# rhttp-uniffi

uniffi bindings for `rhttp-core`, so Kotlin, Swift (and eventually C#) hosts can
share the HTTP stack that the Flutter app uses through Flutter Rust Bridge.

The crate contains no Flutter Rust Bridge type. Everything below re-exports the
pure-Rust `rhttp-core` crates.

## Exported surface

| Item | Kind | Notes |
|---|---|---|
| `RhttpClient` | object | `new(ClientOptions)`, `fetchText(url)`, `fetchBytes(url)`, `cancelAll()` |
| `RhttpError` | error enum | `Network{message}`, `Status{statusCode,message}`, `Cancelled`, `InvalidSettings{message}` |
| `ClientOptions` | record | full mirror of `ClientSettings` |
| `defaultClientOptions()` | function | the core defaults (`HttpVersionPref.All`, `throwOnStatusCode = true`) |
| `DnsResolverCallback` | foreign trait | host-implemented dynamic DNS |

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

On this machine the DSH shell runs under a low-integrity token, so Cargo cannot
complete TLS against any registry (`schannel: AcquireCredentialsHandle failed:
SEC_E_NO_CREDENTIALS`). Launch Windows Cargo through WSL interop instead:

```bat
:: D:\venera\.scratch\test-uniffi.bat
@echo off
cd /d D:\venera\unified\packages\rhttp\rust
set RUSTFLAGS=--cfg reqwest_unstable
cargo test -p rhttp-uniffi
```

```text
wsl: cmd.exe /c "D:\venera\.scratch\test-uniffi.bat"   (translatePaths: false)
```

`RUSTFLAGS` must be set inside the batch file; exporting it from WSL does not
reach the Windows `cargo.exe`.

Current suite: 6 tests — settings round-trip, core defaults, dynamic DNS bridge,
plus an end-to-end request, a status-error mapping and a timeout check against a
loopback `TcpListener`.

## Not implemented yet

- **Streaming downloads** — `CoreResponseBody::Stream` is not exposed. Needs a
  callback interface or a `nextChunk()` poller (ticket 06, step 5.2).
- **Generated bindings** — `uniffi-bindgen` is not installed; no Kotlin/Swift
  output is checked in (step 5.3).
- **Cross targets** — Android (`aarch64-linux-android`) and Windows
  (`x86_64-pc-windows-msvc`) artifacts are not built or benchmarked yet
  (step 5.4). Throughput acceptance is ≥ 80% of the current FRB adapter.

Do not add this crate to the Flutter app's Dart dependencies; it exists only for
non-Flutter hosts.
