# Dependency Audit

This is the current Venera Unified dependency review. Exact resolutions live in
[pubspec.lock](../../pubspec.lock), immutable Git/local-source provenance lives in
[git_dependencies.json](git_dependencies.json), and this document explains the maintenance
policy. It does not introduce a second set of version pins.

## Current inventory

The lockfile resolves three Git repositories into eight Git packages and six local
packages:

| Dependency | Current source and revision | Reason |
| --- | --- | --- |
| flutter_qjs | [flutter_qjs](https://github.com/CyrilPeng/flutter_qjs) at `295f77421eedff356a02e92987181b525970c780` | Venera engine fixes and reviewed platform source |
| flutter_inappwebview family | [flutter_inappwebview](https://github.com/venera-app/flutter_inappwebview) at `0aaf7a0bfc01d61a4d1453cefb57fb6783b6e676` | Venera WebView compatibility fixes across six packages |
| webdav_client | [webdav_client](https://github.com/venera-app/webdav_client) at `2f669c98fb81cff1c64fee93466a1475c77e4273` | Venera WebDAV behavior and Android network compatibility |

The QuickJS source audit records quickjs-ng core `d07f6b59c76e5b5c4c784c96e888ae85f779d512`
and retains the Venera-specific patches. Do not silently replace the Dart wrapper pin
while leaving the reviewed native core unchanged.

## Local packages

| Package | Current version | Maintenance boundary |
| --- | --- | --- |
| photo_view | 0.14.0 | Local null-safety, positioning and scale fixes |
| share_plus | 12.0.2 | Local Windows ARM64 and Venera sharing behavior |
| rhttp | 0.15.1 | Local Rust HTTP backend, profile portability and HTTP/3 policy |
| desktop_webview_window | 0.2.4 | Local Linux/WebKit compatibility and lifecycle fixes |
| venera_native | 1.0.0 | Venera native integrations and Linux compatibility |
| venera_saf | 1.0.0 | Venera scoped-storage behavior and cancellation fixes |

Keep each package's patch and license documentation with the source change. In particular,
review [rhttp local patches](../../packages/rhttp/LOCAL_PATCHES.md) when its Rust lockfile
changes; url `2.5.9` and form_urlencoded `1.2.3` are part of that reviewed source state.

## Hosted dependencies retained deliberately

The current lockfile retains dynamic_color `2.1.0`, pdfrx `2.11.0` with
pdfrx_engine `0.9.0`, flutter_reorderable_grid_view `5.7.0`, and
scrollable_positioned_list `0.3.8`. Upstream release notes or newer candidate versions
are not authorization to change these pins. Upgrade them only with a separate diff,
compatibility evidence and the relevant reader/platform tests.

## Required review flow

1. Change `pubspec.yaml` and regenerate `pubspec.lock` with the repository's Flutter/Dart
   toolchain; never mix an upstream lockfile into the fork without resolving local packages.
2. For every Git or path source, update [git_dependencies.json](git_dependencies.json)
   with immutable commit/content provenance, reviewed source directories, bundled assets,
   license text and checksums. See the [dependency policy](dependencies.en.md).
3. Review native and bundled source as well as Dart code. Keep QuickJS, pdfium, rhttp,
   WebView and platform patch records aligned with what actually ships.
4. Run:

   ```sh
   fvm dart tool/check_git_dependencies.dart
   python .github/scripts/check_structure_imports.py
   python .github/scripts/check_architecture_dependencies.py
   fvm flutter test test/tool/ci_workflow_contract_test.dart
   ```

5. Add focused tests for the changed behavior, then run the relevant full platform or
   reader suites. Record toolchain and any untested runtime surface.

A dirty package already present in a shared pub cache makes the resolved-source check
fail closed. Use a clean resolved cache or CI; do not edit the cache to make the audit
green, and do not mistake a network clone failure for a successful inventory comparison.
