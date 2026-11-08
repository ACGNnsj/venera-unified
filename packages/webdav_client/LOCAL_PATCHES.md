# Local webdav_client 1.2.2

Source: https://github.com/CyrilPeng/webdav_client at commit
`2f669c98fb81cff1c64fee93466a1475c77e4273`. The package identifies
https://github.com/flymzero/webdav_client as upstream. The original BSD-3-Clause
`LICENSE`, copyright notices and package version are retained. The Venera
Unified maintainers own the local copy and future upstream comparisons.

## Why the copy exists

The fork repository is gone. On 2026-11-09 the GitHub page for
`CyrilPeng/webdav_client` returned 404, `info/refs` returned 401 and
`git ls-remote` reported `repository ... not found`. A `flutter pub get` on a
clean pub cache therefore fails with:

```
Git error. Command: `git clone --mirror https://github.com/CyrilPeng/webdav_client ...`
fatal: could not read Username for 'https://github.com': No such device or address
```

Runners that still had a warm pub cache kept building, so the breakage only
surfaced when the Linux ARM64 job's cache was evicted. Vendoring the package
keeps the published behaviour while removing the deleted network dependency.

## Retained behaviour and files

The pinned fork carries the `newClient` adapter parameter used by the
application's HTTP transport, 301/302 redirect handling, uploads and multiple
authentication modes. All of that behaviour is retained unchanged. No logic was
edited: line endings are normalised to LF and the Dart sources go through the
project's formatter, which only rewrapped `lib/src/webdav_dio.dart`.

All eleven `lib/` files, `pubspec.yaml`, `LICENSE`, upstream README and
CHANGELOG are retained. Examples, images used by the upstream README, upstream
test projects, Git metadata and build outputs are omitted. The application
already tests its actual WebDAV request builder, client ownership, library
transport and backup/synchronization paths with synthetic local fixtures, so
the package's own example-driven tests are not carried over.

`UPSTREAM_MANIFEST.json` records SHA-256 hashes of the retained canonical LF Git
blobs and the hash of each local file after normalisation and formatting, so any
future edit to the copy shows up as a mismatch.

## Keeping it current

Any future comparison should diff this directory against
`https://github.com/flymzero/webdav_client` at 1.2.2 and against the last known
fork commit `2f669c98fb81cff1c64fee93466a1475c77e4273` if a mirror reappears.
Changes to `lib/` require the same review as application code.
